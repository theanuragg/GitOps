# docs/runbooks/operations.md
# Platform Operations Runbook

> These are the day-2 operations playbooks every senior DevOps engineer should know cold.

---

## 1. Emergency Production Rollback

**When:** A bad deploy is causing elevated error rates and the canary analysis didn't catch it.

```bash
# Option A: Abort in-progress canary (triggers auto-rollback to stable)
kubectl argo rollouts abort api-service -n api-service --context prod-cluster

# Option B: Manually roll back to a specific revision
kubectl argo rollouts undo api-service -n api-service --context prod-cluster
# or to a specific revision:
kubectl argo rollouts undo api-service --to-revision=5 -n api-service --context prod-cluster

# Verify rollback completed
kubectl argo rollouts status api-service -n api-service --context prod-cluster --watch

# Check the previous stable image is running
kubectl get rollout api-service -n api-service -o jsonpath='{.status.currentPodHash}' --context prod-cluster

# Also sync ArgoCD to the last known-good Git state (if needed)
argocd app sync api-service-prod --revision <last-good-commit-sha>
```

**Expected time to rollback:** < 2 minutes (Rollout aborts canary immediately)

---

## 2. Manual Sync Outside Sync Window

**When:** Emergency patch needed on Friday night when sync windows deny automated syncs.

```bash
# Check current sync windows
argocd app get api-service-prod | grep -A5 "Sync Window"

# Override the sync window for a single manual sync (requires SRE role)
argocd app sync api-service-prod \
  --force \
  --prune \
  --server-side \
  --retry-limit 3

# After sync, verify health
argocd app wait api-service-prod --health --timeout 300
```

---

## 3. Register a New Application (Zero YAML from Scratch)

**When:** A new service needs to be deployed across all environments.

```bash
# 1. Create the base manifests
mkdir -p apps/base/new-service
cp apps/base/{deployment,service,hpa,pdb,networkpolicy,externalsecret,servicemonitor}.yaml \
   apps/base/new-service/

# 2. Update base kustomization
cd apps/base/new-service
# Edit kustomization.yaml to reference new-service manifests

# 3. Create overlays
for env in dev staging prod; do
  mkdir -p apps/overlays/$env/new-service
  cat > apps/overlays/$env/new-service/kustomization.yaml <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: new-service
bases:
  - ../../../base/new-service
images:
  - name: ghcr.io/YOUR_ORG/new-service
    newTag: latest
EOF
done

# 4. Commit — ApplicationSet Git generator auto-discovers the new directories
git add apps/overlays/
git commit -m "feat: add new-service to all environments"
git push

# 5. ArgoCD detects the new directories within ~3 min and creates the apps
# Watch it appear:
watch argocd app list | grep new-service
```

---

## 4. Cluster Disaster Recovery

**When:** A target cluster (e.g., prod) is completely lost and needs to be rebuilt.

```bash
# 1. Provision a new cluster (Terraform or cloud console)
# 2. Register the new cluster with ArgoCD
./scripts/register-cluster.sh \
  --name prod \
  --context new-prod-cluster-context

# 3. ArgoCD immediately begins syncing ALL applications from Git
# No manual intervention needed — Git IS the truth

# 4. Monitor recovery
watch argocd app list --output wide | grep prod

# 5. Infrastructure is restored in this order (enforced by sync-wave annotations):
#    wave -40: cert-manager
#    wave -35: external-secrets
#    wave -30: ingress-nginx
#    wave -20: monitoring
#    wave   0: applications

# Expected full cluster recovery time: 15-25 minutes
# (dominated by Helm chart installs and image pulls)
```

---

## 5. Secret Rotation

**When:** A database password or API key needs to be rotated.

```bash
# 1. Update the secret in Vault (source of truth)
vault kv put secret-prod/api-service/database \
  username="api_user" \
  password="$(openssl rand -base64 32)" \
  host="prod-db.internal.example.com" \
  name="apidb"

# 2. External Secrets Operator syncs automatically (every 5 minutes per config)
# Force immediate sync:
kubectl annotate externalsecret api-service-secrets \
  -n api-service \
  --context prod-cluster \
  force-sync=$(date +%s) \
  --overwrite

# 3. Watch the K8s Secret update
kubectl get secret api-service-secrets -n api-service --context prod-cluster \
  -o jsonpath='{.metadata.resourceVersion}'

# 4. Force rolling restart to pick up new secret (if mounted as volume, auto-reloaded)
# If using envFrom (env vars), pods need restart:
kubectl rollout restart deployment/api-service -n api-service --context prod-cluster

# 5. Verify pods are using new credentials
kubectl exec -it deploy/api-service -n api-service --context prod-cluster -- \
  cat /etc/secrets/DATABASE_URL | grep -o "@[^@]*$"  # Show host only, not password
```

---

## 6. Debug ArgoCD Sync Failure

**When:** An ArgoCD app is stuck in a failed sync state.

```bash
# Check sync status and last operation
argocd app get api-service-prod

# View detailed sync logs
argocd app sync-windows api-service-prod
argocd app history api-service-prod

# Get the actual error
argocd app get api-service-prod --output yaml | \
  yq '.status.operationState.syncResult.resources[] | select(.status == "SyncFailed")'

# Common causes:
# 1. OPA Gatekeeper policy violation
kubectl get events -n api-service --context prod-cluster \
  --field-selector reason=FailedCreate | grep -i admission

# 2. Resource quota exceeded
kubectl describe quota -n api-service --context prod-cluster

# 3. PVC stuck in Pending (storage class issue)
kubectl get pvc -n api-service --context prod-cluster

# 4. Image pull failure (bad tag or registry auth)
kubectl get events -n api-service --context prod-cluster \
  --field-selector reason=Failed | grep -i image

# Force hard refresh (bypass ArgoCD cache)
argocd app get api-service-prod --hard-refresh

# After fixing the issue, retry:
argocd app sync api-service-prod --retry-limit 3
```

---

## 7. Add a New Cluster to the Platform

```bash
# 1. Provision cluster (EKS/GKE/AKS via Terraform — not covered here)

# 2. Register with ArgoCD
./scripts/register-cluster.sh \
  --name eu-prod \
  --context eks-eu-west-1-prod \
  --labels "environment=prod,region=eu-west-1"

# 3. Create cluster directory
mkdir -p clusters/eu-prod
# Copy and adapt from clusters/prod/

# 4. Create AppProject for the new cluster
# Copy projects/appprojects.yaml entry for prod and adapt for eu-prod

# 5. Create app overlays
mkdir -p apps/overlays/eu-prod
# Symlink or copy from prod overlays

# 6. Commit everything
git add clusters/eu-prod/ apps/overlays/eu-prod/ projects/
git commit -m "feat: add eu-prod cluster to platform"
git push

# ApplicationSet cluster generator automatically detects the new cluster label
# and starts syncing within 3 minutes
```

---

## 8. SLO Burn Rate Alert Response

**When:** PagerDuty fires for `SLOBurnRateFast`

```bash
# 1. Check current error rate in Grafana (link in alert)
#    Or query Prometheus directly:
kubectl exec -it prometheus-pod -n monitoring --context prod-cluster -- \
  promtool query instant http://localhost:9090 \
  'job:http_error_ratio:rate5m{job="api-service"}'

# 2. Check if a recent deployment is the cause
argocd app history api-service-prod | head -5

# 3. Check error logs
kubectl logs -l app.kubernetes.io/name=api-service \
  -n api-service --context prod-cluster \
  --since=15m | grep -i error | head -50

# 4. Check if it's canary-related
kubectl argo rollouts get rollout api-service -n api-service --context prod-cluster

# 5. Immediate mitigation options:
#    a) Abort canary (if rollout in progress)
kubectl argo rollouts abort api-service -n api-service --context prod-cluster

#    b) Scale up (if saturation-related)
kubectl scale deployment/api-service --replicas=8 -n api-service --context prod-cluster
#    Note: ArgoCD will revert this — also update the Git overlay if scaling is needed long-term

#    c) Circuit breaker (if downstream dependency is failing)
#    Configure via Envoy/Istio policy — outside this runbook scope

# 6. Document the incident in the postmortem template
```
