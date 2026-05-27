#!/bin/bash

set -Eeuo pipefail

LOCATION="eastus"
RESOURCE_GROUP="baba-aks-rg"
CLUSTER_NAME="baba-aks-cluster"
NODE_SIZE="Standard_D4pds_v5"
MIN_NODES="2"
MAX_NODES="5"
K8S_VERSION="1.33.11"

echo ""
echo "▶️ Creating resource group..."
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION"


echo ""
echo "▶️ Creating AKS cluster..."
az aks create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --location "$LOCATION" \
  --node-vm-size "$NODE_SIZE" \
  --enable-cluster-autoscaler \
  --min-count "$MIN_NODES" \
  --max-count "$MAX_NODES" \
  --kubernetes-version "$K8S_VERSION" \
  --enable-managed-identity \
  --enable-oidc-issuer \
  --enable-workload-identity \
  --network-plugin azure \
  --generate-ssh-keys \
  --tier standard


echo ""
echo "▶️ Fetching kubeconfig..."
az aks get-credentials \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --overwrite-existing


echo ""
echo "▶️ Cluster created successfully"
kubectl get nodes -o wide
