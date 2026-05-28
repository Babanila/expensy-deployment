#!/bin/bash

set -Eeuo pipefail

# ==========================================
# COLORS
# ==========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'


info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }


# ==========================================
# LOAD ENV
# ==========================================
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi


# ==========================================
# VARIABLES
# ==========================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
K8S_DIR="${ROOT_DIR}/infrastructure/k8s"

NAMESPACE="${NAMESPACE:-expensy}"
REDIS_IMAGE="${REDIS_IMAGE:-redis:7-alpine}"
MONGO_IMAGE="${MONGO_IMAGE:-mongo:7}"
BACKEND_IMAGE="${BACKEND_IMAGE}"
FRONTEND_IMAGE="${FRONTEND_IMAGE}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
INGRESS_NAMESPACE="ingress-nginx"

# DNS VARIABLES
DNS_RESOURCE_GROUP="${DNS_RESOURCE_GROUP:-dns-rg}"
DNS_ZONE="${DNS_ZONE:-azure.ironlabs.online}"
DNS_RECORD="${DNS_RECORD:-baba}"
TTL=300

# PROMETHEUS & GRAFANA
MONITORING_NAMESPACE="monitoring"


# ==========================================
# VALIDATE REQUIRED VARIABLES
# ==========================================
required_vars=(
  NAMESPACE
  BACKEND_IMAGE
  FRONTEND_IMAGE
  IMAGE_TAG
)

for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    error "Required environment variable missing: ${var}"
    exit 1
  fi
done


# ==========================================
# SHOW DEPLOYMENT VARIABLES
# ==========================================
echo ""
info "Deployment Configuration"

echo "Environment: ${ENVIRONMENT:-unknown}"
echo "Namespace: ${NAMESPACE}"
echo "Backend Image: ${BACKEND_IMAGE}:${IMAGE_TAG}"
echo "Frontend Image: ${FRONTEND_IMAGE}:${IMAGE_TAG}"
echo "Mongo Image: ${MONGO_IMAGE}"
echo "Redis Image: ${REDIS_IMAGE}"


# HELPERS FUNCTIONS
check_command() {
  command -v "$1" >/dev/null 2>&1
}

apply_manifest_dir() {
  local dir="$1"

  for file in "$dir"/*.yaml; do
    [ -f "$file" ] || continue

    echo ""
    info "Rendering $(basename "$file")"
    rendered_manifest=$(envsubst < "$file")

    echo "$rendered_manifest"

    echo ""
    info "Applying $(basename "$file")"
    echo "$rendered_manifest" | kubectl apply -f -
  done
}

# CLEAN OLD NON-HELM INGRESS RESOURCES
cleanup_old_ingress() {
  warn "Cleaning old ingress-nginx resources..."

  # Namespace resources
  kubectl delete namespace "${INGRESS_NAMESPACE}" --ignore-not-found=true --wait=true || true

  # Cluster-scoped resources
  kubectl delete clusterrole ingress-nginx --ignore-not-found=true || true
  kubectl delete clusterrolebinding ingress-nginx --ignore-not-found=true || true
  kubectl delete validatingwebhookconfiguration ingress-nginx-admission --ignore-not-found=true || true
  kubectl delete mutatingwebhookconfiguration ingress-nginx-admission --ignore-not-found=true || true
  kubectl delete ingressclass nginx --ignore-not-found=true || true

  # Optional cleanup
  kubectl delete crd ingressclasses.networking.k8s.io --ignore-not-found=true || true

  echo ""
  info "Waiting for ingress-nginx cleanup..."
  sleep 15
  success "Old ingress-nginx resources removed."
}


# INSTALL kubectl
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


# INSTALL HELM
install_helm() {
  if check_command helm; then
    success "helm already installed"
    return
  fi

  info "Installing helm..."
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  success "helm installed"
}


# ==========================================
# INSTALL TOOLS
# ==========================================
install_kubectl
install_helm


# ==========================================
# VERIFY CLUSTER
# ==========================================
echo ""
info "Connected Cluster Nodes"
kubectl get nodes


# =========================================
# INSTALL NGINX INGRESS CONTROLLER
# =========================================
echo ""
info "Checking ingress-nginx installation..."

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

# CHECK EXISTING HELM RELEASE
if helm status ingress-nginx \
  -n "${INGRESS_NAMESPACE}" >/dev/null 2>&1; then
  success "ingress-nginx already installed."
else
  warn "ingress-nginx Helm release not found."

  if kubectl get clusterrole ingress-nginx \
    >/dev/null 2>&1; then

    warn "Old non-Helm ingress resources detected."
    kubectl config current-context

    if [[ "${FORCE_INGRESS_REINSTALL:-false}" == "true" ]]; then
      cleanup_old_ingress
    else
      error "Old ingress-nginx resources exist."
      echo ""
      warn "Run with:"
      echo "export FORCE_INGRESS_REINSTALL=true"
      exit 1
    fi
  fi

  # INSTALL INGRESS-NGINX
  info "Installing ingress-nginx..."

  helm upgrade --install ingress-nginx \
  ingress-nginx/ingress-nginx \
  --namespace "${INGRESS_NAMESPACE}" \
  --create-namespace \
  --set controller.replicaCount=2 \
  --set controller.service.type=LoadBalancer \
  --set controller.admissionWebhooks.enabled=true \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz \
  --wait \
  --timeout 15m

  success "ingress-nginx installed successfully."
fi


# ==========================================
# WAIT FOR INGRESS
# ==========================================
echo ""
info "Waiting for ingress controller..."

kubectl wait \
  --namespace "${INGRESS_NAMESPACE}" \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=300s


# ==========================================
# INSTALL CERT-MANAGER
# ==========================================
echo ""
info "Installing cert-manager..."
if helm status cert-manager -n cert-manager >/dev/null 2>&1; then
  success "cert-manager already installed."
else
  helm repo add jetstack https://charts.jetstack.io
  helm repo update

  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --set installCRDs=true \
    --wait \
    --timeout 10m
fi

# ==========================================
# WAIT FOR EXTERNAL IP
# ==========================================
echo ""
info "Waiting for external IP..."
EXTERNAL_IP=""

for i in {1..60}; do
  EXTERNAL_IP=$(kubectl get svc ingress-nginx-controller \
    -n "${INGRESS_NAMESPACE}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' \
    2>/dev/null || true)

  if [[ -n "${EXTERNAL_IP}" ]]; then
    success "Ingress External IP:"
    echo "http://${EXTERNAL_IP}"
    break
  fi

  echo "Waiting for external IP... (${i}/60)"
  sleep 10
done

if [[ -z "${EXTERNAL_IP}" ]]; then
  warn "External IP not assigned yet"
  warn "Check ingress controller status using:"
  echo "kubectl get svc -n ${INGRESS_NAMESPACE}"
else
  success "Ingress External IP:"
  echo "http://${EXTERNAL_IP}"
fi


# ==========================================
# CREATE NAMESPACE
# ==========================================
echo ""
info "Creating namespace..."
envsubst < "${K8S_DIR}/namespace.yaml" | kubectl apply -f -
kubectl config set-context --current --namespace="$NAMESPACE"
success "Namespace created"


# ==========================================
# DEPLOY RESOURCES
# ==========================================
apply_manifest_dir "${K8S_DIR}/secrets"
apply_manifest_dir "${K8S_DIR}/configmaps"
apply_manifest_dir "${K8S_DIR}/mongo"
apply_manifest_dir "${K8S_DIR}/redis"
apply_manifest_dir "${K8S_DIR}/backend"
apply_manifest_dir "${K8S_DIR}/frontend"
apply_manifest_dir "${K8S_DIR}/ingress"


# ==========================================
# WAIT FOR DEPLOYMENTS
# ==========================================
echo ""
info "Waiting for backend..."
kubectl rollout status deployment/backend -n "$NAMESPACE" --timeout=300s

echo ""
info "Waiting for frontend..."
kubectl rollout status deployment/frontend -n "$NAMESPACE" --timeout=300s


# ==========================================
# SHOW RESOURCES
# ==========================================
echo ""
success "Deployment completed successfully 🚀"

echo ""
kubectl get all -n "$NAMESPACE"
echo ""

if [[ -n "${EXTERNAL_IP}" ]]; then
  success "Application URL:"
  echo "http://${EXTERNAL_IP}"

fi



# ==========================================
# CREATE OR UPDATE DNS A RECORD
# ==========================================
echo ""
echo "▶️ Checking if DNS record exists..."

RECORD_EXISTS=$(
  az network dns record-set a show \
    --resource-group "$DNS_RESOURCE_GROUP" \
    --zone-name "$DNS_ZONE" \
    --name "$DNS_RECORD" \
    --query "name" \
    --output tsv 2>/dev/null || true
)

if [ -n "$RECORD_EXISTS" ]; then
  echo "ℹ️ Record exists. Removing old A records..."

  EXISTING_IPS=$(
    az network dns record-set a show \
      --resource-group "$DNS_RESOURCE_GROUP" \
      --zone-name "$DNS_ZONE" \
      --name "$DNS_RECORD" \
      --query "arecords[].ipv4Address" \
      --output tsv
  )

  for ip in $EXISTING_IPS; do
    echo "🗑 Removing existing IP: $ip"

    az network dns record-set a remove-record \
      --resource-group "$DNS_RESOURCE_GROUP" \
      --zone-name "$DNS_ZONE" \
      --record-set-name "$DNS_RECORD" \
      --ipv4-address "$ip"
  done
else
  echo "ℹ️ Record does not exist. Creating record set..."

  az network dns record-set a create \
    --resource-group "$DNS_RESOURCE_GROUP" \
    --zone-name "$DNS_ZONE" \
    --name "$DNS_RECORD" \
    --ttl "$TTL" \
    --output none
fi

echo ""
echo "▶️ Creating/updating A record '$DNS_RECORD' → '$EXTERNAL_IP' ..."

az network dns record-set a add-record \
  --resource-group "$DNS_RESOURCE_GROUP" \
  --zone-name "$DNS_ZONE" \
  --record-set-name "$DNS_RECORD" \
  --ipv4-address "$EXTERNAL_IP"

echo ""
echo "✔️ DNS A record set successfully"
echo "🌍 $DNS_RECORD.$DNS_ZONE → $EXTERNAL_IP"

echo ""
echo "▶️ Verifying DNS record..."

az network dns record-set a show \
  --resource-group "$DNS_RESOURCE_GROUP" \
  --zone-name "$DNS_ZONE" \
  --name "$DNS_RECORD" \
  --output table


# =========================================
# CREATE GRAFANA ADMIN SECRET
# =========================================
echo ""
info "Creating Grafana admin secret..."

kubectl create secret generic grafana-admin-secret -n monitoring \
  --from-literal=admin-user=admin \
  --from-literal=admin-password=admin123

success "Grafana admin secret ready."


# =========================================
# INSTALL PROMETHEUS STACK
# =========================================
echo ""
info "Installing kube-prometheus-stack..."

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update


helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace "${MONITORING_NAMESPACE}" \
  --create-namespace \
  -f "${K8S_DIR}/monitoring/values.yaml" \
  --wait \
  --timeout 30m \
  --debug

# helm upgrade --install kube-prometheus-stack \
#   prometheus-community/kube-prometheus-stack \
#   --namespace "${MONITORING_NAMESPACE}" \
#   --create-namespace \
#   --set crds.enabled=true \
#   -f "${K8S_DIR}/monitoring/values.yaml" \
#   --wait \
#   --wait-for-jobs \
#   --timeout 30m

success "kube-prometheus-stack installed."


# =========================================
# WAIT FOR CRDs
# =========================================
echo ""
info "Waiting for Prometheus Operator CRDs..."

CRDS=(
  "servicemonitors.monitoring.coreos.com"
  "prometheusrules.monitoring.coreos.com"
  "podmonitors.monitoring.coreos.com"
)

for CRD in "${CRDS[@]}"; do
  echo "Checking CRD: ${CRD}"

  until kubectl get crd "${CRD}" >/dev/null 2>&1; do
    echo "Waiting for CRD ${CRD}..."
    sleep 5
  done

  kubectl wait \
    --for=condition=Established \
    --timeout=180s \
    "crd/${CRD}"
done

success "Prometheus Operator CRDs ready."


# =========================================
# APPLY SERVICEMONITOR
# =========================================
echo ""
info "Applying ServiceMonitor..."
apply_manifest_dir "${K8S_DIR}/monitoring/servicemonitors"
success "ServiceMonitors applied."


# =========================================
# APPLY MONITORING INGRESS
# =========================================
echo ""
info "Applying Prometheus & Grafana ingress..."
apply_manifest_dir "${K8S_DIR}/monitoring/ingress"
success "Monitoring ingress applied."

