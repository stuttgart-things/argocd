# platforms/cicd

CI/CD platform bundle: `ApplicationSet`s on the management cluster that fan out CI/CD-adjacent catalog entries to every cluster labelled as a CI/CD target.

All ApplicationSets share one cluster selector — the ArgoCD cluster `Secret` must carry:

```
cicd-platform: "true"
```

Catalog entries rendered:

| ApplicationSet       | Catalog path                  | Workload namespace | Notes |
|---|---|---|---|
| `openebs-cicd`       | `infra/openebs/install`        | `openebs`          | Storage prerequisite — provisions `openebs-hostpath` and annotates it as the cluster default SC |
| `dapr-cicd`          | `cicd/dapr/install`            | `dapr-system`      | Dapr control-plane |
| `kro-cicd`           | `cicd/kro/install`             | `kro-system`       | kro (Kube Resource Orchestrator); inner sync uses `Replace=true` for CRDs |
| `argo-rollouts-cicd` | `cicd/argo-rollouts/install`   | `argo-rollouts`    | Progressive-delivery controller |
| `crossplane-cicd`    | `cicd/crossplane/install`      | `crossplane-system`| Crossplane core; providers/functions/configurations are separate charts under `cicd/crossplane/` — opt in per cluster via follow-up Applications |
| `kargo-cicd`         | `cicd/kargo/install`           | `kargo`            | Kargo control-plane. `api.host` is derived from the cluster's `clusterbook.stuttgart-things.com/fqdn` annotation (→ `kargo.<fqdn>`) so install + HTTPRoute + cert + cookie-Host check line up |
| `kargo-httproute-cicd` | `cicd/kargo/httproute`       | `kargo`            | Gateway API `HTTPRoute` exposing the kargo API. **Additionally gated on** `clusterbook.stuttgart-things.com/allocation-ip` being present — only clusterbook-registered clusters have the `<cluster>-gateway` Gateway and `<cluster>-gateway-tls` wildcard cert this route consumes. Non-clusterbook clusters in the cicd platform get kargo installed but no HTTPRoute (bring your own Gateway) |
| `tekton-cicd`        | `cicd/tekton/operator`         | `tekton-operator`  | Tekton operator (control plane for the rest) |
| `tekton-config-cicd` | `cicd/tekton/config`           | `tekton-pipelines` | `TektonConfig` CR, profile `all` (Pipelines + Triggers + Dashboard + Chains + Results). Uniform across clusters today; per-cluster override via cluster-Secret annotation can be added when needed |
| `tekton-dashboard-httproute-cicd` | `cicd/tekton/dashboard-httproute` | `tekton-pipelines` | Gateway API `HTTPRoute` exposing `tekton-dashboard:9097` on `tekton.<cluster-fqdn>`. **Additionally gated on** `clusterbook.stuttgart-things.com/allocation-ip` — clusterbook clusters only (same reason as `kargo-httproute-cicd`) |

**Ordering:** `openebs-cicd` carries sync-wave `-10`, the others wave `0`. As noted in `platforms/clusterbook`, sync-wave on top-level Applications is informational (each ApplicationSet fires independently). Convergence on fresh clusters relies on each component's `syncPolicy.retry` — e.g. dapr scheduler PVCs stay `Pending` until OpenEBS installs the default StorageClass, then Argo re-syncs dapr.

`project: '{{ .name }}'` on every generated Application — the `AppProject` named after the cluster must exist first (see [`config/cluster-project`](../../config/cluster-project/), driven by the `cluster-projects` ApplicationSet on clusters labelled `auto-project=true`).

## Install

Bootstrap the platform itself (one-shot, on the management cluster):

```bash
kubectl apply -f platforms/cicd/application.yaml
```

That creates an `Application` named `cicd-platform` pointing at this directory. Argo renders the `kustomization.yaml` here, which applies the two ApplicationSets into the `argocd` namespace. They become active as soon as a cluster Secret is labelled `cicd-platform: "true"`.

Alternatively, apply the bundle directly without the outer Application:

```bash
kubectl apply -k https://github.com/stuttgart-things/argocd.git/platforms/cicd?ref=main
```

`application.yaml` is intentionally **not** listed in `kustomization.yaml` — the bootstrap Application must not manage itself.

## Per-cluster prerequisites

Some components need Secrets that can't live in Git. Create these on the target cluster **before** or **just after** enrolling it — missing ones leave the corresponding inner Application stuck in `ComparisonError` / `SyncFailed`.

### `kargo-admin` (required when enrolling kargo)

The upstream kargo chart refuses to render without an admin password hash + token signing key. This platform points it at an `existingSecret` named `kargo-admin` in the `kargo` namespace; you create that Secret per cluster.

**Keys the Secret must carry:**

| Key                              | Format                                                         |
|---|---|
| `ADMIN_ACCOUNT_PASSWORD_HASH`     | bcrypt, `$2a$` variant (NOT `$2y$`)                            |
| `ADMIN_ACCOUNT_TOKEN_SIGNING_KEY` | random, 32 chars                                                |

**Minimal recipe (kubectl against the target cluster):**

```bash
# bcrypt the admin password — use htpasswd, or python3 -c "import bcrypt; ..."
PASSWORD_HASH=$(htpasswd -bnBC 10 "" '<your-password>' | tr -d ':\n' | sed 's/$2y/$2a/')
TOKEN_SIGNING_KEY=$(openssl rand -base64 29 | tr -d '=+/' | head -c 32)

kubectl create namespace kargo --dry-run=client -o yaml | kubectl apply -f -
kubectl -n kargo create secret generic kargo-admin \
  --from-literal=ADMIN_ACCOUNT_PASSWORD_HASH="$PASSWORD_HASH" \
  --from-literal=ADMIN_ACCOUNT_TOKEN_SIGNING_KEY="$TOKEN_SIGNING_KEY"
```

Python bcrypt fallback if `htpasswd` isn't available:

```bash
PASSWORD_HASH=$(python3 -c 'import bcrypt; print(bcrypt.hashpw(b"<your-password>", bcrypt.gensalt(rounds=10)).decode().replace("$2b$","$2a$"))')
```

**For prod / multi-cluster fleets**, replace `kubectl` with External Secrets Operator (syncs from Vault / AWS / GCP Secret Manager), Argo CD Vault Plugin, or a SOPS-encrypted overlay — whichever your threat model calls for. The appset stays the same; only *how* `kargo-admin` gets onto the cluster changes.

**Rotation:** replace the Secret and `kubectl -n kargo rollout restart deploy kargo-api`. The Secret is only read at pod start.

## Per-cluster opt-out

Default behaviour: labelling a cluster with `cicd-platform: "true"` enrols it in **all** three components. To skip a single component on a specific cluster, add a per-component label on that cluster's `Secret` in the `argocd` namespace:

| Label on the cluster Secret                    | Effect on that cluster |
|---|---|
| `cicd-platform/openebs: "false"`               | Skip `openebs-cicd`       |
| `cicd-platform/dapr: "false"`                  | Skip `dapr-cicd`          |
| `cicd-platform/kro: "false"`                   | Skip `kro-cicd`           |
| `cicd-platform/argo-rollouts: "false"`         | Skip `argo-rollouts-cicd` |
| `cicd-platform/crossplane: "false"`            | Skip `crossplane-cicd`    |
| `cicd-platform/kargo: "false"`                 | Skip `kargo-cicd` **and** `kargo-httproute-cicd` (shared key) |
| `cicd-platform/tekton: "false"`                | Skip `tekton-cicd`, `tekton-config-cicd` **and** `tekton-dashboard-httproute-cicd` (shared key) |

Semantics: each ApplicationSet selector is `cicd-platform=true` AND `cicd-platform/<component> NotIn ["false"]`. Absent label = included (default). Only the explicit string `"false"` opts out.

If the cluster is managed by `clusterbook-operator`, add the label to the `ClusterbookCluster` CR's `spec.labels` — the operator propagates it onto the Argo Secret on the next reconcile.

### Opt-out safety: `preserveResourcesOnDeletion`

Each ApplicationSet sets `spec.syncPolicy.preserveResourcesOnDeletion: true`. When a cluster flips from included → opted out, the child `Application` CR is deleted, **but the workload resources it managed stay in place** (StorageClass, namespaces, DaemonSets, CRDs). This avoids tearing out live state — especially for storage (OpenEBS) and CRD owners (kro) — on a flag flip.

Clean-up is manual: `kubectl delete ns <namespace>` (or equivalent) on the target cluster if you want the resources gone. Until then, the cluster keeps running what was deployed; ArgoCD just stops managing it.

## Adding a catalog entry

1. Drop a new `appset-<name>.yaml` in this directory following the dapr/kro template (same cluster selector, path pointing at the new catalog entry's `install/` chart).
2. Add the filename to `kustomization.yaml`.
3. Commit — the `cicd-platform` Application self-heals and reconciles.

## Related

- [`cicd/dapr`](../../cicd/dapr/), [`cicd/kro`](../../cicd/kro/) — catalog entries rendered by these ApplicationSets.
- [`platforms/clusterbook`](../clusterbook/) — sibling platform bundle targeting clusterbook-registered clusters (different selector, different catalog entries).
