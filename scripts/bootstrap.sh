#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — Idempotent ArgoCD bootstrap on management cluster
#
# Usage:
#   ./scripts/bootstrap.sh --context <kubectl-context> [--dry-run]
#
# What this does:
#   1. Installs ArgoCD with production-grade HA configuration
#   2. Applies OIDC / SSO configuration (GitHub OAuth)
#   3. Registers this repo as the bootstrap source
#   4. Applies the root App-of-Apps so ArgoCD manages itself
#
# Requirements: kubectl, helm, argocd CLI, jq, vault CLI
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

log()  { echo -e "${GREEN}[✔]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✘]${NC} $*" >&2; exit 1; }
info() { echo -e "${CYAN}[→]${NC} $*"; }

# ── Defaults ─────────────────────────────────────────────────────────────────
ARGOCD_NAMESPACE="argocd"
ARGOCD_VERSION="v2.10.5"          # pin version; never use latest in prod
REPO_URL="https://github.com/YOUR_ORG/gitops-multicluster"
REPO_BRANCH="main"
DRY_RUN=false
KUBE_CONTEXT=""

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --context)  KUBE_CONTEXT="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=true; shift ;;
    --version)  ARGOCD_VERSION="$2"; shift 2 ;;
    *) err "Unknown argument: $1" ;;
  esac
done

[[ -z "$KUBE_CONTEXT" ]] && err "--context is required"

# ── Pre-flight checks ─────────────────────────────────────────────────────────
info "Running pre-flight checks..."
for cmd in kubectl helm argocd jq; do
  command -v "$cmd" &>/dev/null || err "Required tool not found: $cmd"
done

kubectl config use-context "$KUBE_CONTEXT" || err "kubectl context '$KUBE_CONTEXT' not found"

K8S_VERSION=$(kubectl version --client -o json | jq -r '.clientVersion.gitVersion')
log "kubectl $K8S_VERSION"
log "Context: $KUBE_CONTEXT"

if $DRY_RUN; then
  warn "DRY RUN mode — no changes will be applied"
fi

apply() {
  if $DRY_RUN; then
    echo "  [DRY RUN] kubectl apply $*"
  else
    kubectl apply "$@"
  fi
}

# ── Step 1: Namespace ─────────────────────────────────────────────────────────
info "Step 1/7: Creating namespace $ARGOCD_NAMESPACE..."
kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | apply -f -

# Label the namespace for network policy matching
kubectl label namespace "$ARGOCD_NAMESPACE" \
  app.kubernetes.io/managed-by=bootstrap \
  environment=management \
  --overwrite

# ── Step 2: Install ArgoCD (HA mode) ─────────────────────────────────────────
info "Step 2/7: Installing ArgoCD $ARGOCD_VERSION (HA mode)..."

# Add Helm repo
helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo update argo

HELM_ARGS=(
  upgrade --install argocd argo/argo-cd
  --namespace "$ARGOCD_NAMESPACE"
  --version "$(helm search repo argo/argo-cd --output json | jq -r '.[0].version')"
  --values "$(dirname "$0")/../bootstrap/argocd/values.yaml"
  --wait
  --timeout 10m
  --atomic
)

if $DRY_RUN; then
  echo "  [DRY RUN] helm ${HELM_ARGS[*]}"
else
  helm "${HELM_ARGS[@]}"
fi

log "ArgoCD installed"

# ── Step 3: Wait for ArgoCD to be healthy ────────────────────────────────────
info "Step 3/7: Waiting for ArgoCD pods to be ready..."
if ! $DRY_RUN; then
  kubectl wait --for=condition=available deployment \
    --all \
    -n "$ARGOCD_NAMESPACE" \
    --timeout=300s
fi
log "ArgoCD pods ready"

# ── Step 4: Configure ArgoCD CLI ─────────────────────────────────────────────
info "Step 4/7: Logging into ArgoCD..."
if ! $DRY_RUN; then
  ARGOCD_INITIAL_PASSWORD=$(kubectl -n "$ARGOCD_NAMESPACE" \
    get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d)

  # Port-forward in background for CLI login
  kubectl port-forward svc/argocd-server -n "$ARGOCD_NAMESPACE" 18080:443 &>/dev/null &
  PF_PID=$!
  sleep 3

  argocd login localhost:18080 \
    --username admin \
    --password "$ARGOCD_INITIAL_PASSWORD" \
    --insecure \
    --grpc-web

  # Rotate the initial password immediately
  NEW_PASS=$(openssl rand -base64 32)
  argocd account update-password \
    --current-password "$ARGOCD_INITIAL_PASSWORD" \
    --new-password "$NEW_PASS"

  # Store new password in Vault
  vault kv put secret/argocd/admin password="$NEW_PASS"
  log "Admin password rotated and stored in Vault"

  kill $PF_PID 2>/dev/null || true
fi

# ── Step 5: Register Git repository ──────────────────────────────────────────
info "Step 5/7: Registering Git repository..."

# GitHub App credentials stored in Vault
if ! $DRY_RUN; then
  GITHUB_APP_ID=$(vault kv get -field=app_id secret/github/argocd)
  GITHUB_APP_INSTALL_ID=$(vault kv get -field=install_id secret/github/argocd)
  GITHUB_APP_PRIVATE_KEY=$(vault kv get -field=private_key secret/github/argocd)

  argocd repo add "$REPO_URL" \
    --github-app-id "$GITHUB_APP_ID" \
    --github-app-installation-id "$GITHUB_APP_INSTALL_ID" \
    --github-app-private-key-path <(echo "$GITHUB_APP_PRIVATE_KEY") \
    --insecure-skip-server-verification=false

  log "Repository registered with GitHub App auth"
fi

# ── Step 6: Apply AppProjects (RBAC) ─────────────────────────────────────────
info "Step 6/7: Applying ArgoCD AppProjects..."
apply -f "$(dirname "$0")/../projects/" --recursive

# ── Step 7: Apply root App-of-Apps ───────────────────────────────────────────
info "Step 7/7: Applying root App-of-Apps..."
apply -f "$(dirname "$0")/../bootstrap/argocd/root-app.yaml"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  Bootstrap complete! ArgoCD is now self-managing.${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${CYAN}ArgoCD UI:${NC}    https://argocd.internal.example.com"
echo -e "  ${CYAN}Admin pass:${NC}   vault kv get -field=password secret/argocd/admin"
echo -e "  ${CYAN}Next step:${NC}    ./scripts/register-cluster.sh --name dev --context dev-ctx"
echo ""
warn "Rotate the admin account after SSO is verified and disable local login."
