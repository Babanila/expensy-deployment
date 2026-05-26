#!/bin/bash

# K8s-destroy.sh - Destroy Locally Deployed Kubernetes Resources

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

load_env

# =========================================
# Manifest Application Helper
# =========================================
delete_manifest_dir() {
  local dir="$1"

  if [[ ! -d "$dir" ]]; then
    warn "Directory does not exist: $dir"
    return 0
  fi

  shopt -s nullglob

  local files=("$dir"/*.yaml)

  if [[ ${#files[@]} -eq 0 ]]; then
    warn "No manifest files found in: $dir"
    return 0
  fi

  for file in "${files[@]}"; do
    info "Deleting $(basename "$file")..."

    envsubst < "$file" | kubectl delete \
      --ignore-not-found=true \
      -f -

  done

  shopt -u nullglob
}


echo "========================================="
echo "Deleting Expensy Kubernetes Resources"
echo "========================================="

# =========================================
# Delete Manifest
# =========================================
delete_manifest_dir "${K8S_DIR}/ingress"

delete_manifest_dir "${K8S_DIR}/frontend"
delete_manifest_dir "${K8S_DIR}/backend"

delete_manifest_dir "${K8S_DIR}/redis"
delete_manifest_dir "${K8S_DIR}/mongo"

delete_manifest_dir "${K8S_DIR}/configmaps"
delete_manifest_dir "${K8S_DIR}/secrets"

echo "Deleting namespace..."
envsubst < "${K8S_DIR}/namespace.yaml" | kubectl delete --ignore-not-found=true -f -

echo ""
echo "========================================="
echo "Teardown Completed"
echo "========================================="
