#!/usr/bin/env bash

set -Eeuo pipefail

# ==========================================
# COLORS
# ==========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*" >&2; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $*" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

trap 'error "Deployment failed on line $LINENO"' ERR

# ==========================================
# LOAD ENV
# ==========================================
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

# ==========================================
# VARIABLES
# ==========================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
K8S_DIR="${ROOT_DIR}/infrastructure/k8s"

NAMESPACE="${NAMESPACE:-expensy}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
INGRESS_NAMESPACE="${INGRESS_NAMESPACE:-ingress-nginx}"

REDIS_IMAGE="${REDIS_IMAGE:-redis:7-alpine}"
MONGO_IMAGE="${MONGO_IMAGE:-mongo:7}"

BACKEND_IMAGE="${BACKEND_IMAGE:-}"
FRONTEND_IMAGE="${FRONTEND_IMAGE:-}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

DNS_RESOURCE_GROUP="${DNS_RESOURCE_GROUP:-dns-rg}"
DNS_ZONE="${DNS_ZONE:-azure.ironlabs.online}"
DNS_RECORD="${DNS_RECORD:-baba}"
TTL="${TTL:-300}"

PROM_RELEASE="kube-prometheus-stack"
INGRESS_RELEASE="ingress-nginx"
CERT_MANAGER_RELEASE="cert-manager"

# ==========================================
# VALIDATION
# ==========================================
required_vars=(
  BACKEND_IMAGE
  FRONTEND_IMAGE
)

for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    error "Missing required env variable: ${var}"
    exit 1
  fi
done

# ==========================================
# HELPERS
# ==========================================
check_command() {
  command -v "$1" >/dev/null 2>&1
}

ensure_namespace() {
  local ns="$1"

  if kubectl get ns "$ns" >/dev/null 2>&1; then
    success "Namespace '$ns' already exists"
  else
    info "Creating namespace '$ns'"
    kubectl create namespace "$ns"
  fi
}

wait_for_release_unlock() {
  local release="$1"
  local namespace="$2"

  info "Checking Helm release lock: $release"

  for i in {1..30}; do
    status=$(helm status "$release" -n "$namespace" -o json 2>/dev/null | jq -r '.info.status' || true)

    if [[ "$status" != pending-* ]]; then
      success "Helm release unlocked"
      return 0
    fi

    warn "Release locked ($status). Waiting... ($i/30)"
    sleep 10
  done

  warn "Release still locked. Cleaning Helm secrets..."

  kubectl delete secret -n "$namespace" \
    -l owner=helm,name="$release" \
    --ignore-not-found=true || true
}

create_or_update_secret() {
  local namespace="$1"
  local secret_name="$2"

  shift 2

  kubectl create secret generic "$secret_name" \
    -n "$namespace" \
    "$@" \
    --dry-run=client -o yaml | kubectl apply -f -
}

apply_manifest_dir() {
  local dir="$1"

  [[ -d "$dir" ]] || return 0

  for file in "$dir"/*.yaml; do
    [[ -f "$file" ]] || continue

    info "Applying $(basename "$file")"

    envsubst < "$file" | kubectl apply -f -
  done
}

install_kubectl() {
  if check_command kubectl; then
    success "kubectl already installed"
    return
  fi

  info "Installing kubectl..."
  curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"

  chmod +x kubectl
  sudo mv kubectl /usr/local/bin/

  success "kubectl installed"
}

install_helm() {
  if check_command helm; then
    success "helm already installed"
    return
  fi

  info "Installing helm..."
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

  success "helm installed"
}

ensure_helm_repo() {
  local name="$1"
  local url="$2"

  if helm repo list | grep -q "^${name}"; then
    success "Helm repo '$name' already exists"
  else
    helm repo add "$name" "$url"
  fi
}

wait_for_external_ip() {
  local svc="$1"
  local ns="$2"
  local ip=""

  info "Waiting for external IP..."

  for i in {1..60}; do
    ip=$(kubectl get svc "$svc" \
      -n "$ns" \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' \
      2>/dev/null || true)

    if [[ -n "$ip" ]]; then
      echo "$ip"
      return 0
    fi

    sleep 10
  done

  return 1
}


# ==========================================
# INSTALL TOOLS
# ==========================================
install_kubectl
install_helm


# ==========================================
# SHOW CONFIG
# ==========================================
echo ""
info "Deployment Configuration"

echo "Namespace: ${NAMESPACE}"
echo "Backend Image: ${BACKEND_IMAGE}:${IMAGE_TAG}"
echo "Frontend Image: ${FRONTEND_IMAGE}:${IMAGE_TAG}"


# ==========================================
# VERIFY CLUSTER
# ==========================================
echo ""
info "Connected Cluster"

kubectl get nodes

# ==========================================
# ENSURE NAMESPACES
# ==========================================
ensure_namespace "$NAMESPACE"
ensure_namespace "$INGRESS_NAMESPACE"
ensure_namespace "$MONITORING_NAMESPACE"
ensure_namespace "cert-manager"


# ==========================================
# HELM REPOS
# ==========================================
ensure_helm_repo ingress-nginx https://kubernetes.github.io/ingress-nginx
ensure_helm_repo jetstack https://charts.jetstack.io
ensure_helm_repo prometheus-community https://prometheus-community.github.io/helm-charts

helm repo update


# ==========================================
# INSTALL INGRESS
# ==========================================
echo ""
info "Installing ingress-nginx"

wait_for_release_unlock "$INGRESS_RELEASE" "$INGRESS_NAMESPACE"

helm upgrade --install "$INGRESS_RELEASE" \
  ingress-nginx/ingress-nginx \
  --namespace "$INGRESS_NAMESPACE" \
  --create-namespace \
  --set controller.replicaCount=2 \
  --set controller.service.type=LoadBalancer \
  --set controller.admissionWebhooks.enabled=true \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz \
  --wait \
  --timeout 20m

success "ingress-nginx ready"


# ==========================================
# WAIT FOR INGRESS
# ==========================================
kubectl wait \
  --namespace "$INGRESS_NAMESPACE" \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=300s


# ==========================================
# INSTALL CERT MANAGER
# ==========================================
echo ""
info "Installing cert-manager"

wait_for_release_unlock "$CERT_MANAGER_RELEASE" "cert-manager"

helm upgrade --install "$CERT_MANAGER_RELEASE" \
  jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set installCRDs=true \
  --wait \
  --timeout 15m

success "cert-manager ready"


# ==========================================
# WAIT FOR EXTERNAL IP
# ==========================================
EXTERNAL_IP=$(
  wait_for_external_ip \
    ingress-nginx-controller \
    "$INGRESS_NAMESPACE"
) || true

if [[ -z "${EXTERNAL_IP:-}" ]]; then
  warn "External IP not assigned yet"
else
  success "Ingress External IP: ${EXTERNAL_IP}"
fi


# ==========================================
# APPLY APP RESOURCES
# ==========================================
echo ""
info "Deploying application"

kubectl config set-context --current --namespace="$NAMESPACE"

apply_manifest_dir "${K8S_DIR}/secrets"
apply_manifest_dir "${K8S_DIR}/configmaps"
apply_manifest_dir "${K8S_DIR}/mongo"
apply_manifest_dir "${K8S_DIR}/redis"
apply_manifest_dir "${K8S_DIR}/backend"
apply_manifest_dir "${K8S_DIR}/frontend"
apply_manifest_dir "${K8S_DIR}/ingress"


# ==========================================
# WAIT FOR ROLLOUTS
# ==========================================
echo ""
info "Waiting for backend rollout"
kubectl rollout status deployment/backend -n "$NAMESPACE" --timeout=300s

echo ""
info "Waiting for frontend rollout"
kubectl rollout status deployment/frontend -n "$NAMESPACE" --timeout=300s


# ==========================================
# SHOW RESOURCES
# ==========================================
echo ""
success "Manifests deployment completed successfully 🚀"

echo ""
kubectl get all -n "$NAMESPACE"
echo ""


# ==========================================
# CREATE OR UPDATE DNS RECORD (A RECORD)
# ==========================================
echo ""
echo "▶️ Checking if DNS record exists..."
if [[ -n "${EXTERNAL_IP:-}" ]]; then

  echo ""
  info "Ensuring DNS record"

  if ! az network dns record-set a show \
    --resource-group "$DNS_RESOURCE_GROUP" \
    --zone-name "$DNS_ZONE" \
    --name "$DNS_RECORD" >/dev/null 2>&1; then

    az network dns record-set a create \
      --resource-group "$DNS_RESOURCE_GROUP" \
      --zone-name "$DNS_ZONE" \
      --name "$DNS_RECORD" \
      --ttl "$TTL" \
      --output none
  fi

  EXISTING_IPS=$(
    az network dns record-set a show \
      --resource-group "$DNS_RESOURCE_GROUP" \
      --zone-name "$DNS_ZONE" \
      --name "$DNS_RECORD" \
      --query "arecords[].ipv4Address" \
      --output tsv 2>/dev/null || true
  )

  if ! echo "$EXISTING_IPS" | grep -q "$EXTERNAL_IP"; then

    for ip in $EXISTING_IPS; do
      az network dns record-set a remove-record \
        --resource-group "$DNS_RESOURCE_GROUP" \
        --zone-name "$DNS_ZONE" \
        --record-set-name "$DNS_RECORD" \
        --ipv4-address "$ip" || true
    done

    az network dns record-set a add-record \
      --resource-group "$DNS_RESOURCE_GROUP" \
      --zone-name "$DNS_ZONE" \
      --record-set-name "$DNS_RECORD" \
      --ipv4-address "$EXTERNAL_IP"
  fi

  success "DNS configured"
fi


# ==========================================
# GRAFANA SECRET
# ==========================================
echo ""
info "Ensuring Grafana admin secret"

create_or_update_secret \
  "$MONITORING_NAMESPACE" \
  grafana-admin-secret \
  --from-literal=admin-user=admin \
  --from-literal=admin-password=admin123

success "Grafana secret ready"


# ==========================================
# INSTALL KUBE PROMETHEUS STACK
# ==========================================
echo ""
info "Installing kube-prometheus-stack"

wait_for_release_unlock "$PROM_RELEASE" "$MONITORING_NAMESPACE"

helm upgrade --install "$PROM_RELEASE" \
  prometheus-community/kube-prometheus-stack \
  --namespace "$MONITORING_NAMESPACE" \
  --create-namespace \
  -f "${K8S_DIR}/monitoring/values.yaml" \
  --wait \
  --wait-for-jobs \
  --timeout 30m \
  --atomic

success "kube-prometheus-stack ready"


# ==========================================
# WAIT FOR CRDs
# ==========================================
echo ""
info "Waiting for Prometheus CRDs"

CRDS=(
  "servicemonitors.monitoring.coreos.com"
  "prometheusrules.monitoring.coreos.com"
  "podmonitors.monitoring.coreos.com"
)

for CRD in "${CRDS[@]}"; do

  until kubectl get crd "$CRD" >/dev/null 2>&1; do
    sleep 5
  done

  kubectl wait \
    --for=condition=Established \
    --timeout=180s \
    "crd/${CRD}"
done

success "CRDs ready"


# ==========================================
# APPLY MONITORING RESOURCES
# ==========================================
echo ""
info "Applying monitoring resources"

apply_manifest_dir "${K8S_DIR}/monitoring/servicemonitors"
apply_manifest_dir "${K8S_DIR}/monitoring/ingress"


# ==========================================
# VERIFY MONITORING
# ==========================================
echo ""
info "Monitoring Pods"

kubectl get pods -n "$MONITORING_NAMESPACE"


# ==========================================
# FINAL OUTPUT
# ==========================================
echo ""
success "Deployment completed successfully 🚀"

echo ""
kubectl get all -n "$NAMESPACE"

echo ""

if [[ -n "${EXTERNAL_IP:-}" ]]; then
  success "Application URL"
  echo "http://${EXTERNAL_IP}"
  echo "http://${DNS_RECORD}.${DNS_ZONE}"
fi
