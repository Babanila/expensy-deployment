#!/bin/bash

# deploy.sh - Deploy voting app to EKS in order

set -Eeuo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'


info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
K8S_DIR="${ROOT_DIR}/infrastructure/k8s"


# =========================================
# Secure .env loading
# =========================================
load_env() {
  local env_file="${ROOT_DIR}/.env"

  if [[ ! -f "$env_file" ]]; then
    warn ".env file not found. Continuing with existing environment variables."
    return
  fi

  info "Loading environment variables from .env"

  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a

  info "Environment variables loaded..."
}


# =========================================
# Manifest Application Helper
# =========================================
apply_manifest_dir() {
  local dir="$1"

  for file in "$dir"/*.yaml; do
    info "Applying $(basename "$file")"
    envsubst < "$file" | kubectl apply -f -

  done
}


echo "========================================="
echo "Deploying Expensy Kubernetes Resources"
echo "========================================="


# Check Dependencies
command -v kubectl >/dev/null 2>&1 || {
  error "kubectl is not installed"
  exit 1
}

command -v helm >/dev/null 2>&1 || {
  error "helm is not installed"
  exit 1
}

load_env

echo ""
info "Creating namespace..."
envsubst < "${K8S_DIR}/namespace.yaml" | kubectl apply -f -
kubectl config set-context --current --namespace=$NAMESPACE

success "$NAMESPACE created successfully."


# Install NGINX Ingress Controller
echo ""
info "Installing NGINX Ingress Controller..."

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true

helm repo update >/dev/null 2>&1

if ! kubectl get namespace "${INGRESS_NAMESPACE}" >/dev/null 2>&1; then
  kubectl create namespace "${INGRESS_NAMESPACE}"
fi

if ! helm list -n "${INGRESS_NAMESPACE}" | grep -q ingress-nginx; then
  helm install ingress-nginx ingress-nginx/ingress-nginx --namespace "${INGRESS_NAMESPACE}"
else
  warn "Ingress controller already installed. Skipping..."
fi

# Wait For Ingress External IP
echo ""
info "Waiting for Ingress LoadBalancer external IP..."

for i in {1..30}; do
  EXTERNAL_IP=$(kubectl get svc ingress-nginx-controller \
    -n "${INGRESS_NAMESPACE}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

  if [[ -n "${EXTERNAL_IP}" ]]; then
    break
  fi

  echo "Waiting for external IP... (${i}/30)"
  sleep 10
done

if [[ -z "${EXTERNAL_IP}" ]]; then
  warn "External IP not assigned yet."
else
  success "Ingress External IP: ${EXTERNAL_IP}"
fi


# =========================================
# Apply Secrets
# =========================================
apply_manifest_dir "${K8S_DIR}/secrets"
apply_manifest_dir "${K8S_DIR}/configmaps"
apply_manifest_dir "${K8S_DIR}/mongo"
apply_manifest_dir "${K8S_DIR}/redis"
apply_manifest_dir "${K8S_DIR}/backend"
apply_manifest_dir "${K8S_DIR}/frontend"
apply_manifest_dir "${K8S_DIR}/ingress"


# Wait For Pods
echo ""
info "Waiting for pods to become ready..."

kubectl wait --for=condition=available --timeout=300s deployment/frontend -n "$NAMESPACE"
kubectl wait --for=condition=available --timeout=300s deployment/backend -n "$NAMESPACE"


echo ""
echo "========================================="
success "Deployment Completed Successfully 🚀🚀🚀"
echo "========================================="

echo ""
info "Resources in namespace: $NAMESPACE"
kubectl get all -n $NAMESPACE

echo ""

if [[ -n "${EXTERNAL_IP}" ]]; then
  success "Ingress External IP:"
  echo "http://${EXTERNAL_IP}"

  echo ""
  warn "Update your DNS record:"
  echo "expensy.yourdomain.com -> ${EXTERNAL_IP}"
fi
