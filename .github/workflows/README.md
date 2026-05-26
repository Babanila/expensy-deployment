# CI/CD Deployment Guide


## Overview

This project uses a production-style CI/CD pipeline with:
- GitHub Actions
- Docker Hub
- Azure Kubernetes Service (AKS)
- Kubernetes
- Helm
- NGINX Ingress Controller
- Cert-Manager (TLS/HTTPS)


The pipeline automatically:
1. Builds frontend and backend applications
2. Runs tests
3. Builds Docker images
4. Pushes images to Docker Hub
5. Deploys applications to AKS
6. Configures HTTPS ingress with TLS certificates


## Architecture

GitHub Push
    │
    ▼
GitHub Actions
    │
    ├── Build
    ├── Test
    ├── Docker Build & Push
    └── Deploy to AKS
                │
                ▼
        Azure Kubernetes Service
                │
                ▼
      NGINX Ingress Controller
                │
                ▼
        HTTPS/TLS Access


## Project Structure

expensy-deployment/
│
├── .github/
│   └── workflows/
│       ├── ci-cd-pipeline.yml
│       ├── build.yml
│       ├── test.yml
│       ├── docker.yml
│       ├── deploy.yml
│       └── README.md
│
├── services/
│   ├── frontend/
│   └── backend/
│
├── infrastructure/
│   └── k8s/
│       ├── namespace.yaml
│       ├── secrets/
│       ├── configmaps/
│       ├── mongo/
│       ├── redis/
│       ├── backend/
│       ├── frontend/
│       ├── ingress/
│       └── README.md
│
├── scripts/
│   ├── deploy.sh
│   ├── k8s-deploy.sh
│   └── k8s-destroy.sh
│
│
├── .env-example
├── .gitignore
├── docker-compose-online.yml
├── docker-compose.yml
└── README.md


## CI/CD Pipeline Stages

### 1. Build

Workflow: build.yml

Responsibilities:
- Install dependencies
- Build frontend
- Build backend
- Upload artifacts

### 2. Test

Workflow: test.yml

Responsibilities:
- Run unit tests
- Validate applications


### 3. Docker Build & Push

Workflow: docker.yml

Responsibilities:
- Build Docker images
- Push images to Docker Hub

Images:
```bash
babanila/expensy_frontend
babanila/expensy_backend
```

### 4. Deploy

Workflow: deploy.yml

Responsibilities:
- Authenticate with Azure
- Connect to AKS
- Install ingress controller
- Install cert-manager
- Deploy Kubernetes manifests
- Configure HTTPS/TLS


## GitHub Actions Workflows

### Main Pipeline

File:
```bash
.github/workflows/ci-cd-pipeline.yml
```

### Reusable Workflows

| Workflow   | Purpose                    |
| ---------- | -------------------------- |
| build.yml  | Build applications         |
| test.yml   | Run tests                  |
| docker.yml | Build & push Docker images |
| deploy.yml | Deploy to AKS              |


## GitHub Secrets

Add the following repository secrets:

### Repository Secrets

| Secret             | Description                  |
| ------------------ | ---------------------------- |
| DOCKER_USERNAME    | Docker Hub username          |
| DOCKER_PASSWORD    | Docker Hub access token      |
| AZURE_CREDENTIALS  | Azure Service Principal JSON |
| AKS_RESOURCE_GROUP | Azure Resource Group         |
| AKS_CLUSTER_NAME   | AKS Cluster Name             |


## GitHub Environment Variables

Create GitHub environments:
```bash
dev
staging
production
```

Add variables per environment.

### Variables

| Variable    | Example                      |
| ----------- | ---------------------------- |
| NAMESPACE   | expensy                      |
| DOMAIN_NAME | baba-expensy.az.ironlabs.com |


## Docker Hub Setup

### Create Access Token

Go to:
```bash
Docker Hub
→ Account Settings
→ Security
→ New Access Token
```

Use the token as:
```bash
DOCKER_PASSWORD
```

## Azure Setup

### Create AKS Cluster

Example:
```bash
az aks create \
  --resource-group my-rg \
  --name expensy-aks \
  --node-count 2 \
  --enable-addons monitoring \
  --generate-ssh-keys
```


Create Service Principal
```bash
az ad sp create-for-rbac \
  --name github-actions-sp \
  --role contributor \
  --scopes /subscriptions/<SUBSCRIPTION_ID> \
  --sdk-auth
```

Copy output to:
```bash
AZURE_CREDENTIALS
```


## Kubernetes Deployment

Deployment is handled by:
```bash
scripts/deploy.sh
```

The script:
- Installs kubectl if missing
- Installs helm if missing
- Installs ingress-nginx
- Installs cert-manager
- Deploys manifests
- Waits for deployments
- Retrieves ingress external IP


## Ingress & HTTPS

The deployment includes:
- NGINX Ingress Controller
- TLS certificates via Let's Encrypt
- HTTPS redirection


## DNS Configuration

After deployment:
```bash
kubectl get svc ingress-nginx-controller -n ingress-nginx
```

Copy the external IP.

Create DNS A record:
```bash
baba-expensy.az.ironlabs.com -> <EXTERNAL_IP>
```

## Triggering Deployments

### Automatic Deployment

Deployments run automatically when:
```bash
Push to main branch
```

### Manual Deployment

Go to:
```bash
GitHub
→ Actions
→ Deploy
→ Run Workflow
```
Select:
- dev
- staging
- production


## Verify Deployment
### Check Pods
```bash
kubectl get pods -n expensy
```

### Check Services
```bash
kubectl get svc -n expensy
```

### Check Ingress
```bash
kubectl get ingress -n expensy
```

### Check Pod Logs
```bash
kubectl logs -f deployment/frontend -n expensy
kubectl logs -f deployment/backend -n expensy
```

### Check Cert-Manager
```bash
kubectl get certificates -A
```

### Check NGINX Ingress
```bash
kubectl get pods -n ingress-nginx
```


## Access Application
```bash
https://baba-expensy.az.ironlabs.com
```


## Author

Babajide Williams


## License

MIT License
