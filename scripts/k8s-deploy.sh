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
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
K8S_DIR="${ROOT_DIR}/infrastructure/k8s"

echo "========================================="
echo "Deploying Expensy Kubernetes Resources"
echo "========================================="

NAMESPACE="expensy"

echo ""
info "Creating namespace..."
kubectl apply -f "${K8S_DIR}/namespace.yaml"

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

echo ""
echo "========================================="
success "Deployment Completed Successfully 🚀🚀🚀"
echo "========================================="

echo ""
echo "Resources in namespace: $NAMESPACE"
kubectl get all -n $NAMESPACE
