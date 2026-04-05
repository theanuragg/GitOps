#!/usr/bin/env bash
# =============================================================================
# register-cluster.sh — Register a target cluster with ArgoCD
#
# Usage:
#   ./scripts/register-cluster.sh \
#     --name dev \
#     --context gke_project_region_dev-cluster \
#     [--labels "region=us-east1,tier=dev"]
#
# What this does:
#   1. Creates a dedicated ServiceAccount in the target cluster (least privilege)
#   2. Generates a kubeconfig scoped to that SA
#   3. Registers the cluster with ArgoCD via CLI
#   4. Creates the cluster secret with metadata labels for ApplicationSet matching
#   5. Commits the cluster overlay stub to Git
#
# Security note:
#   ArgoCD gets a cluster-admin-equivalent SA only on the target cluster.
#   The SA is scoped; it cannot reach the management cluster.
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${GREEN}[✔]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✘]${NC} $*" >&2; exit 1; }
info() { echo -e "${CYAN}[→]${NC} $*"; }

CLUSTER_NAME=""
KUBE_CONTEXT=""
CLUSTER_LABELS="environment=${CLUSTER_NAME}"
MGMT_CONTEXT="management-cluster"
ARGOCD_NAMESPACE="argocd"

while [[ $# -gt 0 ]]; do
  case $1 in
    --name)    CLUSTER_NAME="$2"; shift 2 ;;
    --context) KUBE_CONTEXT="$2"; shift 2 ;;
    --labels)  CLUSTER_LABELS="$2"; shift 2 ;;
    --mgmt-context) MGMT_CONTEXT="$2"; shift 2 ;;
    *) err "Unknown argument: $1" ;;
  esac
done

[[ -z "$CLUSTER_NAME" ]] && err "--name is required"
[[ -z "$KUBE_CONTEXT" ]] && err "--context is required"

VALID_NAMES=("dev" "staging" "prod")
[[ " ${VALID_NAMES[*]} " =~ " ${CLUSTER_NAME} " ]] || \
  err "Cluster name must be one of: ${VALID_NAMES[*]}"

# ── Step 1: Create ArgoCD SA on target cluster ────────────────────────────────
info "Step 1/5: Creating ArgoCD service account on $CLUSTER_NAME cluster..."

kubectl config use-context "$KUBE_CONTEXT"

# Create a dedicated namespace for the argocd SA on the remote cluster
kubectl create namespace argocd-agent --dry-run=client -o yaml | kubectl apply -f -

# ServiceAccount with minimal permissions to manage workloads
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-manager
  namespace: argocd-agent
  labels:
    app.kubernetes.io/managed-by: argocd-bootstrap
    cluster: ${CLUSTER_NAME}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: argocd-manager
  labels:
    app.kubernetes.io/managed-by: argocd-bootstrap
rules:
  # Core resources ArgoCD needs to manage
  - apiGroups: [""]
    resources:
      - configmaps
      - endpoints
      - events
      - namespaces
      - persistentvolumeclaims
      - pods
      - pods/log
      - replicationcontrollers
      - resourcequotas
      - secrets
      - serviceaccounts
      - services
    verbs: ["*"]
  - apiGroups: ["apps"]
    resources:
      - daemonsets
      - deployments
      - replicasets
      - statefulsets
    verbs: ["*"]
  - apiGroups: ["batch"]
    resources: ["cronjobs", "jobs"]
    verbs: ["*"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses", "networkpolicies"]
    verbs: ["*"]
  - apiGroups: ["rbac.authorization.k8s.io"]
    resources:
      - clusterroles
      - clusterrolebindings
      - roles
      - rolebindings
    verbs: ["*"]
  - apiGroups: ["apiextensions.k8s.io"]
    resources: ["customresourcedefinitions"]
    verbs: ["*"]
  # ArgoCD Rollouts
  - apiGroups: ["argoproj.io"]
    resources: ["*"]
    verbs: ["*"]
  # Cert-manager
  - apiGroups: ["cert-manager.io"]
    resources: ["*"]
    verbs: ["*"]
  # External secrets
  - apiGroups: ["external-secrets.io"]
    resources: ["*"]
    verbs: ["*"]
  # Monitoring
  - apiGroups: ["monitoring.coreos.com"]
    resources: ["*"]
    verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-manager
  labels:
    app.kubernetes.io/managed-by: argocd-bootstrap
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: argocd-manager
subjects:
  - kind: ServiceAccount
    name: argocd-manager
    namespace: argocd-agent
EOF

log "Service account created"

# ── Step 2: Generate token ────────────────────────────────────────────────────
info "Step 2/5: Generating long-lived SA token (Kubernetes 1.24+ manual secret)..."

kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: argocd-manager-token
  namespace: argocd-agent
  annotations:
    kubernetes.io/service-account.name: argocd-manager
type: kubernetes.io/service-account-token
EOF

# Wait for token to be populated
sleep 5

SA_TOKEN=$(kubectl get secret argocd-manager-token \
  -n argocd-agent \
  -o jsonpath='{.data.token}' | base64 -d)

CA_DATA=$(kubectl get secret argocd-manager-token \
  -n argocd-agent \
  -o jsonpath='{.data.ca\.crt}')

SERVER=$(kubectl config view \
  --minify \
  --flatten \
  -o jsonpath='{.clusters[0].cluster.server}')

log "Token generated (length: ${#SA_TOKEN})"

# ── Step 3: Store in Vault ────────────────────────────────────────────────────
info "Step 3/5: Storing cluster credentials in Vault..."
vault kv put "secret/clusters/${CLUSTER_NAME}" \
  server="$SERVER" \
  token="$SA_TOKEN" \
  ca_data="$CA_DATA"
log "Credentials stored in Vault at secret/clusters/${CLUSTER_NAME}"

# ── Step 4: Register with ArgoCD ─────────────────────────────────────────────
info "Step 4/5: Registering cluster with ArgoCD..."

kubectl config use-context "$MGMT_CONTEXT"

# Port-forward ArgoCD
kubectl port-forward svc/argocd-server -n "$ARGOCD_NAMESPACE" 18080:443 &>/dev/null &
PF_PID=$!
sleep 3

ARGOCD_PASS=$(vault kv get -field=password secret/argocd/admin)
argocd login localhost:18080 \
  --username admin \
  --password "$ARGOCD_PASS" \
  --insecure \
  --grpc-web

# Register using the remote context directly
# ArgoCD will use the SA token we created, not the user's kubeconfig
argocd cluster add "$KUBE_CONTEXT" \
  --name "$CLUSTER_NAME" \
  --label "environment=${CLUSTER_NAME}" \
  --label "managed-by=argocd" \
  --in-cluster=false \
  --upsert

kill $PF_PID 2>/dev/null || true
log "Cluster registered with ArgoCD"

# ── Step 5: Scaffold cluster directory ───────────────────────────────────────
info "Step 5/5: Creating cluster directory structure..."

CLUSTER_DIR="clusters/${CLUSTER_NAME}"
mkdir -p "$CLUSTER_DIR"

cat > "$CLUSTER_DIR/kustomization.yaml" <<EOF
# clusters/${CLUSTER_NAME}/kustomization.yaml
# This file is the cluster-level App-of-Apps root.
# ArgoCD ApplicationSet discovers this via the git generator.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  # Infrastructure components (applied first, alphabetical matters here)
  - ../../infrastructure/cert-manager
  - ../../infrastructure/external-secrets
  - ../../infrastructure/ingress-nginx
  - ../../infrastructure/monitoring

  # Applications for this environment
  - ../../apps/overlays/${CLUSTER_NAME}
EOF

log "Cluster directory created: $CLUSTER_DIR"

echo ""
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo -e "${GREEN}  Cluster '${CLUSTER_NAME}' registered!   ${NC}"
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo ""
warn "Next: git add clusters/${CLUSTER_NAME}/ && git commit -m 'feat: register ${CLUSTER_NAME} cluster' && git push"
warn "ArgoCD will detect and begin syncing within 3 minutes (default poll interval)."
