# GitOps Multi-Cluster Platform with ArgoCD

> Production-grade GitOps platform managing **dev / staging / prod** clusters from a single management cluster using ArgoCD ApplicationSets, App-of-Apps pattern, and full security hardening.

---

## Architecture Overview

```mermaid
flowchart TD
ManagementCluster[MANAGEMENT CLUSTER]
ArgoCD[ArgoCD (control)]
ImageUpdater[ArgoCD Image Updater]
AppSet[ApplicationSet Controller]
GitRepo[Git Repository (Single Source of Truth)]
Clusters[clusters/]
Apps[apps/]
Infra[infrastructure/]
Policies[policies/]
DevCluster[DEV CLUSTER]
StagingCluster[STAGING CLUSTER]
ProdCluster[PROD CLUSTER]
DevApp[app-dev]
DevMon[monitoring]
DevInfra[infra]
StagingApp[app-staging]
StagingMon[monitoring]
StagingInfra[infra]
ProdApp[app-prod]
ProdMon[monitoring]
ProdInfra[infra]

ManagementCluster --> ArgoCD
ManagementCluster --> ImageUpdater
ManagementCluster --> AppSet
ManagementCluster -->|GitOps Sync (pull-based)| GitRepo
GitRepo -->|Contains| Clusters
GitRepo --> Apps
GitRepo --> Infra
GitRepo --> Policies
Clusters --> DevCluster
Clusters --> StagingCluster
Clusters --> ProdCluster
DevCluster -->|app-dev| DevApp
DevCluster -->|monitoring| DevMon
DevCluster -->|infra| DevInfra
StagingCluster -->|app-staging| StagingApp
StagingCluster -->|monitoring| StagingMon
StagingCluster -->|infra| StagingInfra
ProdCluster -->|app-prod| ProdApp
ProdCluster -->|monitoring| ProdMon
ProdCluster -->|infra| ProdInfra
```

---

## About the Code (Brutally Detailed)

This repository implements a **production-grade, multi-cluster GitOps platform** using ArgoCD, ApplicationSets, and a suite of security and operational tools. Below is a comprehensive breakdown of the codebase, its structure, and the rationale behind each component:

### 1. Bootstrap Layer (`bootstrap/`)
- **Purpose:** One-time setup for the management cluster and registration of target clusters.
- **Key Files:**
      - `argocd/`: Contains manifests for installing ArgoCD and its dependencies in the management cluster. Includes `root-app.yaml` (the entrypoint for the App-of-Apps pattern) and `values.yaml` for configuration.
      - `clusters/`: Contains manifests for registering new clusters with ArgoCD using ApplicationSets. The `cluster-appset.yaml` defines how clusters are discovered and managed.

### 2. Application Layer (`apps/`)
- **Purpose:** Declarative definitions of all deployable applications, separated into base and overlays for environment-specific customization.
- **Structure:**
      - `base/`: Contains Kustomize bases for all applications. These are reusable, environment-agnostic manifests (e.g., `deployment.yaml`, `manifests.yaml`).
      - `overlays/`: Contains environment-specific overlays (e.g., `dev/`, `staging/`, `prod/`). Each overlay customizes the base manifests for its environment, supporting DRY principles and safe promotion across environments.

### 3. Cluster Layer (`clusters/`)
- **Purpose:** Cluster-level configuration using the App-of-Apps pattern. Each subfolder (e.g., `management/`, `dev/`, `staging/`, `prod/`) contains ArgoCD Application manifests that aggregate apps, infra, and policies for that cluster.

### 4. Infrastructure Layer (`infrastructure/`)
- **Purpose:** Platform-wide components required by all clusters.
- **Components:**
      - `cert-manager/`: Manages TLS certificates for workloads.
      - `external-secrets/`: Integrates with Vault to inject secrets into clusters without storing them in Git.
      - `monitoring/`: Contains Alertmanager configs and monitoring stack manifests.
      - `vault/`: (May include Terraform code for Vault deployment and configuration.)
      - `ingress-nginx/`: (If present) Handles ingress traffic for workloads.

### 5. Policy Layer (`policies/`)
- **Purpose:** Enforces security and operational policies using OPA Gatekeeper. The `constraints.yaml` file contains policy definitions that are applied to all clusters, preventing misconfigurations and enforcing best practices.

### 6. Projects Layer (`projects/`)
- **Purpose:** Defines ArgoCD AppProjects for RBAC and multi-tenancy. The `appprojects.yaml` file specifies boundaries and permissions for different teams or environments.

### 7. Scripts Layer (`scripts/`)
- **Purpose:** Automation scripts for bootstrapping, registering clusters, and operational tasks. Examples include:
      - `bootstrap.sh`: Bootstraps the management cluster with ArgoCD and core infra.
      - `register-cluster.sh`: Registers a new cluster with ArgoCD, setting up necessary permissions and secrets.
      - `wait-for-argocd.sh`, `wait-for-rollout.sh`: Utility scripts for orchestrating deployments and rollouts.

### 8. Documentation Layer (`docs/`)
- **Purpose:** Runbooks and operational guides for platform users and operators. Includes high-level talking points and detailed operational procedures.

---

### Security & Operations
- **Secrets:** Managed via External Secrets and Vault. No secrets are ever stored in Git.
- **Policy Enforcement:** OPA Gatekeeper ensures only compliant resources are deployed.
- **Progressive Delivery:** Argo Rollouts enables canary and blue-green deployments with metric-based gates.
- **Network Security:** Calico enforces namespace-level microsegmentation.

---

### How Everything Works Together
1. **Bootstrap:** Run `bootstrap.sh` to install ArgoCD and core infra in the management cluster.
2. **Cluster Registration:** Register each target cluster with `register-cluster.sh`, which sets up ArgoCD access and secrets.
3. **App-of-Apps:** Apply `root-app.yaml` to let ArgoCD recursively manage all clusters, apps, infra, and policies.
4. **Continuous Delivery:** All changes are made via Git. ArgoCD syncs clusters automatically, ensuring Git is always the source of truth.
5. **Security & Policy:** Policies and secrets are enforced and injected at deploy time, never leaking sensitive data.

---

This codebase is designed for **scalability, security, and operational excellence**. It enables teams to manage multiple Kubernetes clusters with minimal manual intervention, maximum automation, and strong security guarantees.

## Key Design Decisions

| Decision | Choice | Reason |
|---|---|---|
| Deployment model | Pull-based GitOps | Clusters pull from Git; no inbound firewall holes |
| App pattern | App-of-Apps + ApplicationSets | Scalable; one file registers a new cluster |
| Secret management | External Secrets + Vault | Never store secrets in Git |
| Config layering | Kustomize overlays | DRY base, env-specific patches |
| Policy enforcement | OPA/Gatekeeper | Prevent misconfigs before they reach clusters |
| Image promotion | ArgoCD Image Updater | Automated image tag updates via Git commits |
| Network policy | Calico | Microsegmentation per namespace |
| Progressive delivery | Argo Rollouts | Canary/Blue-Green with metric gates |

---

## Repository Structure

```
gitops-multicluster/
├── bootstrap/                    # One-time cluster bootstrap
│   ├── argocd/                   # ArgoCD install manifests
│   └── clusters/                 # Cluster registration
├── apps/                         # Application definitions
│   ├── base/                     # Kustomize base manifests
│   └── overlays/                 # Per-environment patches
│       ├── dev/
│       ├── staging/
│       └── prod/
├── clusters/                     # Cluster-level config (App-of-Apps)
│   ├── management/
│   ├── dev/
│   ├── staging/
│   └── prod/
├── infrastructure/               # Platform components
│   ├── cert-manager/
│   ├── external-secrets/
│   ├── ingress-nginx/
│   ├── monitoring/
│   └── vault/
├── projects/                     # ArgoCD AppProjects (RBAC)
├── policies/                     # OPA Gatekeeper policies
├── scripts/                      # Bootstrap & operational scripts
└── docs/                         # Runbooks
```

---

## Quick Start

```bash
# 1. Bootstrap the management cluster
./scripts/bootstrap.sh --context management-cluster

# 2. Register target clusters
./scripts/register-cluster.sh --name dev --context dev-cluster
./scripts/register-cluster.sh --name staging --context staging-cluster
./scripts/register-cluster.sh --name prod --context prod-cluster

# 3. Apply the root App-of-Apps
kubectl apply -f bootstrap/argocd/root-app.yaml

# ArgoCD will self-manage everything from here
```
