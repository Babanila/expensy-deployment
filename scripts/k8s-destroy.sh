#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
K8S_DIR="${ROOT_DIR}/infrastructure/k8s"

NAMESPACE="expensy"

echo "========================================="
echo "Deleting Expensy Kubernetes Resources"
echo "========================================="

echo ""
echo "Deleting ingress..."
kubectl delete -f "${K8S_DIR}/ingress/" --ignore-not-found

echo ""
echo "Deleting frontend..."
kubectl delete -f "${K8S_DIR}/frontend/" --ignore-not-found

echo ""
echo "Deleting backend..."
kubectl delete -f "${K8S_DIR}/backend/" --ignore-not-found

echo ""
echo "Deleting redis..."
kubectl delete -f "${K8S_DIR}/redis/" --ignore-not-found

echo ""
echo "Deleting mongo..."
kubectl delete -f "${K8S_DIR}/mongo/" --ignore-not-found

echo ""
echo "Deleting configmaps..."
kubectl delete -f "${K8S_DIR}/configmaps/" --ignore-not-found

echo ""
echo "Deleting secrets..."
kubectl delete -f "${K8S_DIR}/secrets/" --ignore-not-found

echo ""
echo "Deleting namespace..."
kubectl delete -f "${K8S_DIR}/namespace.yaml" --ignore-not-found

echo ""
echo "========================================="
echo "Teardown Completed"
echo "========================================="
