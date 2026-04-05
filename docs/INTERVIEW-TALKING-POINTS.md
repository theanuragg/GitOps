# docs/INTERVIEW-TALKING-POINTS.md
# How to Talk About This Project in Interviews

---

## The 30-Second Pitch

> "I built a GitOps platform on ArgoCD managing three environments across separate Kubernetes clusters from a single Git repository. 
> The core pattern is App-of-Apps with ApplicationSets — so onboarding a new cluster is just committing one directory and running a script. 
> Production deployments go through an automated canary pipeline with Prometheus-based metric gates, and all secrets come from Vault via External Secrets Operator — nothing sensitive ever touches Git. 
> OPA Gatekeeper enforces policy at the admission level so misconfigured workloads can't reach any cluster."

---

## Deep-Dive Questions & Answers

### "Why pull-based GitOps instead of push-based (like Flux push / Helm upgrade in CI)?"

> Push-based means your CI needs cluster credentials — either a kubeconfig or a ServiceAccount token with broad permissions stored as a CI secret. 
> That's a large attack surface: a compromised CI pipeline can push malicious workloads directly.
> 
> Pull-based inverts this. Clusters reach out to Git — no inbound credentials needed, and no firewall holes.
> The cluster only ever applies what's in Git, which is auditable and reviewable via PRs.
> Drift is also eliminated: selfHeal=true means if someone runs `kubectl edit` in prod, ArgoCD reverts it within 3 minutes.

---

### "How do you handle the chicken-and-egg problem of ArgoCD managing itself?"

> ArgoCD is installed via Helm by the bootstrap script — that's the one manual operation. 
> After that, the root App-of-Apps points ArgoCD back at its own Helm values file in Git.
> Any change to ArgoCD's own config — values.yaml, RBAC, OIDC — goes through Git review, and ArgoCD syncs itself.
> The sync-wave annotation on the root app is set to -100, ensuring it processes before any child applications.

---

### "What happens if the management cluster goes down?"

> The target clusters keep running — they don't depend on ArgoCD for runtime.
> ArgoCD is only in the control path for deploys, not for serving traffic.
> The target clusters continue running whatever was last applied.
> Recovery means rebuilding the management cluster (it's cattle, not pets), re-running bootstrap.sh, and re-registering clusters.
> Since ALL state is in Git, nothing is lost. Time to recovery is ~15 minutes.

---

### "How do you prevent a developer from deploying to production accidentally?"

> Multiple layers:
> 1. **AppProjects** — each project whitelists specific destination clusters. The dev AppProject physically cannot target the prod cluster server URL.
> 2. **Sync windows** — prod has automated syncs blocked on weekends and Friday afternoons. Manual syncs require SRE role.
> 3. **RBAC** — developers only have `sync` permission on the dev project. They can't trigger prod syncs.
> 4. **Git branch protection** — prod overlays require PR approval from the platform team before merge.
> 5. **OPA Gatekeeper** — even if something reaches prod, policies enforce non-root, resource limits, required labels.

---

### "How does image promotion work — how does a new build get to prod?"

> Images are built once and promoted — never rebuilt per environment. 
> The image tag is the git SHA (immutable). 
> The promotion pipeline updates the `newTag` field in the relevant Kustomize overlay and commits to Git. 
> ArgoCD detects the change and syncs.
> In prod, the sync triggers an Argo Rollout canary, not a direct Deployment update.
> The canary sends 20%, then 50% traffic while querying Prometheus for error rate and p99 latency.
> If either metric breaches threshold, the rollout auto-aborts and stable traffic is restored. No human needed.

---

### "What's the role of OPA Gatekeeper vs Pod Security Standards?"

> They're complementary, not competing.
> 
> Pod Security Standards (PSS) are Kubernetes-native and fast — they enforce broad security profiles (restricted/baseline/privileged) at the namespace level. Good for catching `runAsRoot` at the pod level.
> 
> OPA Gatekeeper is custom Rego policies — you express business logic that PSS can't. Examples in this platform:
> - Require specific labels (app.kubernetes.io/name, environment)
> - Block `:latest` image tags
> - Require resource limits AND requests (PSS doesn't check this)
> - Enforce naming conventions
> 
> Both run as admission webhooks, so they block non-compliant workloads before etcd ever stores them.

---

### "How do you handle secrets — what's the flow from Vault to the pod?"

> 1. Vault is the source of truth — secrets live there, not in Git.
> 2. External Secrets Operator (ESO) runs in each cluster. It authenticates to Vault using Kubernetes auth — the pod's ServiceAccount JWT is exchanged for a Vault token.
> 3. The ExternalSecret CRD in each namespace declares which Vault path to pull from.
> 4. ESO syncs every 5 minutes. If a secret changes in Vault, ESO detects it and updates the K8s Secret.
> 5. Secrets are mounted as files, not environment variables — avoids exposure via `ps aux` or `/proc`.
> 6. All Vault access is audited — every read is logged.

---

### "If you had to scale this to 20 clusters, what would break?"

> Honest answer — a few things need attention:
> 
> 1. **Application Controller** — it's a single StatefulSet. At 20 clusters × 50 apps, you'd enable sharding (`--application-controller-replicas=3`) and distribute clusters across shards.
> 2. **Repo Server** — it caches Git repo contents. Heavy load means more replicas and potentially a dedicated Git cache layer.
> 3. **ApplicationSet templating** — the matrix generator (cluster × component) creates N² apps. At 20 clusters × 10 infra components, that's 200 Applications. Manageable, but you'd add pagination to the ArgoCD UI.
> 4. **Vault** — you'd need Vault Performance Replication to put a Vault cluster near each region's clusters rather than all clusters hitting one endpoint.
> 5. **Monitoring** — Thanos or Cortex for federated Prometheus, not 20 isolated Prometheus instances.

---

## Architecture Decision Records (ADR)

### ADR-001: App-of-Apps vs Plain ApplicationSets

**Decision:** Use both — App-of-Apps as the bootstrap entry point, ApplicationSets as the scaling mechanism.

**Rationale:** Pure App-of-Apps requires manually creating an Application per app. Pure ApplicationSets require a running ApplicationSet controller before you can register anything. 
The combination solves both: one manually-applied root app bootstraps everything, and ApplicationSets handle dynamic scaling.

---

### ADR-002: Kustomize vs Helm for Application Manifests

**Decision:** Kustomize for application manifests, Helm for infrastructure components.

**Rationale:** Helm is excellent for upstream charts (cert-manager, prometheus, nginx-ingress) — it handles complex values and templating well. 
But for our own apps, Kustomize's overlay model is simpler and more transparent: there's no hidden templating, and `kustomize build` shows exactly what will apply. 
Reviewers can read patches without knowing Helm's `{{ include }}` idioms.

---

### ADR-003: One Repo vs Many Repos

**Decision:** Monorepo for all environments and apps.

**Rationale:** Multiple repo models (one per team, one per env) create synchronization problems — ApplicationSets pointing at different repos, access control fragmented across repos, harder to enforce cross-cutting changes (e.g., adding a new required label to all apps). 
Monorepo with CODEOWNERS per directory gives team autonomy while maintaining platform-level governance.
Cost: repo gets large over time. Mitigation: sparse-checkout for teams that don't need to see all clusters.
