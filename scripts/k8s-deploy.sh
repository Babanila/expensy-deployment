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

echo "========================================="
echo "Deploying Expensy Kubernetes Resources"
echo "========================================="

NAMESPACE="expensy"
INGRESS_NAMESPACE="ingress-nginx"


# Check Dependencies
command -v kubectl >/dev/null 2>&1 || {
  error "kubectl is not installed"
  exit 1
}

command -v helm >/dev/null 2>&1 || {
  error "helm is not installed"
  exit 1
}

echo ""
info "Creating namespace..."
kubectl apply -f "${K8S_DIR}/namespace.yaml"


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


echo ""
info "Applying secrets..."
kubectl apply -f "${K8S_DIR}/secrets/"

echo ""
info "Applying configmaps..."
kubectl apply -f "${K8S_DIR}/configmaps/"

echo ""
info "Deploying MongoDB..."
kubectl apply -f "${K8S_DIR}/mongo/"

echo ""
info "Deploying Redis..."
kubectl apply -f "${K8S_DIR}/redis/"

echo ""
info "Deploying Backend..."
kubectl apply -f "${K8S_DIR}/backend/"

echo ""
info "Deploying Frontend..."
kubectl apply -f "${K8S_DIR}/frontend/"

echo ""
info "Deploying Ingress..."
kubectl apply -f "${K8S_DIR}/ingress/"


# Wait For Pods
echo ""
info "Waiting for pods to become ready..."

kubectl wait --for=condition=available --timeout=300s deployment/frontend -n "${NAMESPACE}"
kubectl wait --for=condition=available --timeout=300s deployment/backend -n "${NAMESPACE}"


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
