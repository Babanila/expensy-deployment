# Expensy Kubernetes Deployment

This document explains how to deploy the Expensy microservices application to a Kubernetes cluster such as Microsoft Azure AKS using the provided deployment script.

## Architecture Overview

### The application consists of:

- Frontend (Next.js)
- Backend API (Node.js)
- MongoDB
- Redis


### The deployment includes:

- Kubernetes Namespace
- Deployments
- Services
- ConfigMaps
- Secrets
- Persistent Volume Claim (PVC)
- Ingress

## Project Structure

k8s/
│
├── deploy.sh
├── k8s-deploy.sh
├── k8s-destroy.sh
│
├── namespace.yaml
│
├── configmaps/
│   ├── frontend-configmap.yaml
│   └── backend-configmap.yaml
│
├── secrets/
│   ├── mongo-secret.yaml
│   └── redis-secret.yaml
│
├── frontend/
│   ├── deployment.yaml
│   ├── hpa.yaml
│   └── service.yaml
│
├── backend/
│   ├── deployment.yaml
│   ├── hpa.yaml
│   ├── servicemonitor.yaml
│   └── service.yaml
│
├── mongo/
│   ├── deployment.yaml
│   ├── service.yaml
│   └── pvc.yaml
│
├── redis/
│   ├── deployment.yaml
│   └── service.yaml
│
├── ingress/
│   └── ingress.yaml
│
└── monitoring/
│    ├── values.yaml
│    ├── grafana-ingress.yaml
│    ├── grafana-secret.yaml
│    ├── prometheus-ingress.yaml
│    └── dashboards/




## Ingress Architecture

                       Internet
                          |
                    Azure LoadBalancer
                          |
                NGINX Ingress Controller
                          |
        ---------------------------------------
        |                                     |
    Frontend Service                    Backend Service



## Prerequisites

Ensure the following are installed:

- Docker
- kubectl
- Kubernetes Cluster (AKS recommended)
- Azure CLI (for AKS)
- Helm (optional)


## Verify Kubernetes Cluster Access

Check cluster connectivity:
``` bash
kubectl cluster-info
```

 
Check nodes:
``` bash
kubectl get nodes
```


## Make Deployment Script Executable

Make the script executable:
``` bash
chmod +x scripts/k8s-deploy.sh
```

## Deploy the Application

Run:
``` bash
scripts/k8s-deploy.sh
```

The script will deploy:

1. Namespace
2. Secrets
3. ConfigMaps
4. MongoDB
5. Redis
6. Backend API
7. Frontend
8. Ingress


## Verify Deployment

Check all resources:
``` bash
kubectl get pods -n expensy
```

Expected output:

``` bash
frontend
backend
mongo
redis
```

All pods should show:

``` bash
STATUS = Running
```

## View Logs

Frontend
``` bash
kubectl logs deployment/frontend -n expensy
```

Backend
``` bash
kubectl logs deployment/backend -n expensy
```

MongoDB
``` bash
kubectl logs deployment/mongo -n expensy
```

Redis
``` bash
kubectl logs deployment/redis -n expensy
```

## Access the Application

### Option 1 — Port Forwarding (Recommended for Testing)
Frontend
``` bash
kubectl port-forward svc/frontend-service 3000:3000 -n expensy
```

Open browser
``` bash
http://localhost:3000
```

Backend
``` bash
kubectl port-forward svc/backend-service 8706:8706 -n expensy
```

API endpoint:
``` bash
http://localhost:8706
```


### Option 2 — LoadBalancer Service

Update frontend service:
``` bash
type: LoadBalancer
```

Apply changes:
``` bash
kubectl apply -f frontend/service.yaml
```

Get external IP:
``` bash
kubectl get svc -n expensy
```

Open browser:
``` bash
http://EXTERNAL-IP
```


## Delete Deployment

Make the script executable:
``` bash
chmod +x scripts/k8s-destroy.sh
```

Remove all resources:
``` bash
scripts/k8s-destroy.sh
```

## Troubleshooting Commands
``` bash
kubectl get pods -n monitoring
kubectl get ingress -n monitoring
kubectl get servicemonitor -A
kubectl top pods -A
```
