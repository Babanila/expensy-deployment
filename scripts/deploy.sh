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
INGRESS_NAMESPACE="ingress-nginx"


# ==========================================
# HELPERS
# ==========================================
check_command() {
  command -v "$1" >/dev/null 2>&1
}

apply_manifest_dir() {
  local dir="$1"

  for file in "$dir"/*.yaml; do
    [ -f "$file" ] || continue

    echo ""
    info "Applying $(basename "$file")"
    envsubst < "$file" | kubectl apply -f -

  done
}


# ==========================================
# INSTALL kubectl
# ==========================================
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


# ==========================================
# INSTALL HELM
# ==========================================
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

INGRESS_NAMESPACE="ingress-nginx"

if kubectl get namespace "${INGRESS_NAMESPACE}" >/dev/null 2>&1; then
  warn "Namespace ${INGRESS_NAMESPACE} already exists."
else
  info "Creating namespace ${INGRESS_NAMESPACE}..."
  kubectl create namespace "${INGRESS_NAMESPACE}"
fi


# Check Existing Helm Release
if helm status ingress-nginx -n "${INGRESS_NAMESPACE}" >/dev/null 2>&1; then
  success "ingress-nginx already installed. Skipping installation."
else
  warn "ingress-nginx release not found."

  # Detect Existing Resources
  if kubectl get sa ingress-nginx -n "${INGRESS_NAMESPACE}" >/dev/null 2>&1; then
    warn "Existing ingress-nginx resources detected."
    info "Cleaning old ingress-nginx resources..."
    kubectl delete sa ingress-nginx \
      -n "${INGRESS_NAMESPACE}" \
      --ignore-not-found
  fi

  info "Installing ingress-nginx..."

  helm repo add ingress-nginx \
    https://kubernetes.github.io/ingress-nginx

  helm repo update
  helm upgrade --install ingress-nginx \
    ingress-nginx/ingress-nginx \
    --namespace "${INGRESS_NAMESPACE}" \
    --create-namespace \
    --set controller.replicaCount=2 \
    --set controller.service.type=LoadBalancer \
    --wait \
    --timeout 10m

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
    break
  fi

  echo "Waiting for external IP... (${i}/60)"
  sleep 10

done

if [[ -z "${EXTERNAL_IP}" ]]; then
  warn "External IP not assigned yet"
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

kubectl rollout status deployment/backend \
  -n "$NAMESPACE" \
  --timeout=300s

echo ""
info "Waiting for frontend..."

kubectl rollout status deployment/frontend \
  -n "$NAMESPACE" \
  --timeout=300s


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
