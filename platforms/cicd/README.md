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
| `crossplane-cicd`    | `cicd/crossplane/install`      | `crossplane-system`| Crossplane core (chart `2.2.1`, args include `--enable-operations` for the alpha Operations / CronOperations / WatchOperations APIs). Providers installed via `crossplane-providers-cicd`; functions/configurations are separate charts under `cicd/crossplane/` — opt in per cluster via follow-up Applications |
| `crossplane-providers-cicd` | `cicd/crossplane/providers` | `crossplane-system`| Crossplane Providers (defaults: provider-helm, provider-kubernetes, provider-opentofu). Shares the `cicd-platform/crossplane` opt-out key with `crossplane-cicd` |
| `crossplane-provider-configs-cicd` | `cicd/crossplane/provider-configs` | `crossplane-system`| Crossplane ProviderConfigs (defaults: helm + kubernetes pointed at the local cluster via `InjectedIdentity`). Shares the `cicd-platform/crossplane` opt-out key with `crossplane-cicd` |
| `kargo-cicd`         | `cicd/kargo/install`           | `kargo`            | Kargo control-plane. `api.host` is derived from the cluster's `clusterbook.stuttgart-things.com/fqdn` annotation (→ `kargo.<fqdn>`) so install + HTTPRoute + cert + cookie-Host check line up |
| `kargo-httproute-cicd` | `cicd/kargo/httproute`       | `kargo`            | Gateway API `HTTPRoute` exposing the kargo API. **Additionally gated on** `clusterbook.stuttgart-things.com/allocation-ip` being present — only clusterbook-registered clusters have the `<cluster>-gateway` Gateway and `<cluster>-gateway-tls` wildcard cert this route consumes. Non-clusterbook clusters in the cicd platform get kargo installed but no HTTPRoute (bring your own Gateway) |
| `tekton-cicd`        | `cicd/tekton/operator`         | `tekton-operator`  | Tekton operator (control plane for the rest) |
| `tekton-config-cicd` | `cicd/tekton/config`           | `tekton-pipelines` | `TektonConfig` CR, profile `all` (Pipelines + Triggers + Dashboard + Chains + Results). Uniform across clusters today; per-cluster override via cluster-Secret annotation can be added when needed |
| `tekton-dashboard-httproute-cicd` | `cicd/tekton/dashboard-httproute` | `tekton-pipelines` | Gateway API `HTTPRoute` exposing `tekton-dashboard:9097` on `tekton.<cluster-fqdn>`. **Additionally gated on** `clusterbook.stuttgart-things.com/allocation-ip` — clusterbook clusters only (same reason as `kargo-httproute-cicd`) |
| `machinery-cicd` | `apps/machinery/install` | `machinery` | App-of-apps rendering the machinery resource dashboard + gRPC `ResourceService` (workload + config + RBAC + HTTPRoute + GRPCRoute) on `machinery.<cluster-fqdn>` / `machinery-grpc.<cluster-fqdn>`. **Additionally gated on** `clusterbook.stuttgart-things.com/allocation-ip` — needs the `<cluster>-gateway` Gateway and `<cluster>-gateway-tls` wildcard cert, so clusterbook clusters only |

**Ordering:** `openebs-cicd` carries sync-wave `-10`, the others wave `0`. As noted in `platforms/network`, sync-wave on top-level Applications is informational (each ApplicationSet fires independently). Convergence on fresh clusters relies on each component's `syncPolicy.retry` — e.g. dapr scheduler PVCs stay `Pending` until OpenEBS installs the default StorageClass, then Argo re-syncs dapr.

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

The upstream kargo chart refuses to render without an admin password hash + token signing key. This platform sets `api.secret.name: kargo-admin`, which tells the chart to suppress its own Secret template and consume an existing Secret by that name in the `kargo` namespace. You create that Secret per cluster.

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
| `cicd-platform/crossplane: "false"`            | Skip `crossplane-cicd`, `crossplane-providers-cicd` **and** `crossplane-provider-configs-cicd` (shared key) |
| `cicd-platform/kargo: "false"`                 | Skip `kargo-cicd` **and** `kargo-httproute-cicd` (shared key) |
| `cicd-platform/tekton: "false"`                | Skip `tekton-cicd`, `tekton-config-cicd` **and** `tekton-dashboard-httproute-cicd` (shared key) |
| `cicd-platform/machinery: "false"`             | Skip `machinery-cicd` |

Semantics: each ApplicationSet selector is `cicd-platform=true` AND `cicd-platform/<component> NotIn ["false"]`. Absent label = included (default). Only the explicit string `"false"` opts out.

If the cluster is managed by `clusterbook-operator`, add the label to the `ClusterbookCluster` CR's `spec.labels` — the operator propagates it onto the Argo Secret on the next reconcile.

### Opt-out safety: `preserveResourcesOnDeletion`

Each ApplicationSet sets `spec.syncPolicy.preserveResourcesOnDeletion: true`. When a cluster flips from included → opted out, the child `Application` CR is deleted, **but the workload resources it managed stay in place** (StorageClass, namespaces, DaemonSets, CRDs). This avoids tearing out live state — especially for storage (OpenEBS) and CRD owners (kro) — on a flag flip.

Clean-up is manual: `kubectl delete ns <namespace>` (or equivalent) on the target cluster if you want the resources gone. Until then, the cluster keeps running what was deployed; ArgoCD just stops managing it.

## Adding a catalog entry

1. Drop a new `appset-<name>.yaml` in this directory following the dapr/kro template (same cluster selector, path pointing at the new catalog entry's `install/` chart).
2. Add the filename to `kustomization.yaml`.
3. Commit — the `cicd-platform` Application self-heals and reconciles.

## Crossplane: baseline vs. capabilities

The crossplane management-cluster config is split along **two independent axes** so
that not every cxp cluster has to be identical:

- **env** (`env` label, e.g. `LabUL`) decides *which values* — endpoints, ESO
  stores, network — via `vars/<env>.yaml`. This is the **configuration** axis.
- **capability** (a per-cluster opt-in label) decides *which components install at
  all* — vSphere provider config vs. GH-runner provider config, etc. This is the
  **selection** axis, driven by the cluster's *planned usage*.

Selection and configuration are kept separate: a label says *what* a cluster runs,
the env file says *how* it is configured for that env.

| ApplicationSet | Cluster selector | Monorepo source | Purpose |
|---|---|---|---|
| `crossplane-platform-baseline-cicd` | `cicd-platform=true` AND `cicd-platform/crossplane != false` (opt-**out**) | `crossplane/platform/baseline/*/vars/<env>.yaml` (Helm) | Shared substrate every cxp cluster in an env needs: ESO stores, RBAC, env-wide EnvironmentConfig. Wave 0. |
| `crossplane-platform-<cap>-cicd` | `cicd-platform/crossplane-<cap>=true` (opt-**in**) | `crossplane/platform/capabilities/<cap>/*/vars/<env>.yaml` (Helm) | Use-case provider config — ClusterProviderConfig / EnvironmentConfig / RBAC for that capability. Wave 1. |
| `crossplane-xrs-<cap>-cicd` | `cicd-platform/crossplane-<cap>=true` (opt-**in**) | `crossplane/xrs/<cap>/<env>/` (plain manifests) | The concrete XR instances (claims/composites) for that capability. Wave 2. |

A *capability* bundles a provider-config appset (wave 1) **and** an XR appset
(wave 2) behind **one** label, shipped together in `appset-cxp-<cap>.yaml`.
`appset-cxp-vspherevm.yaml` is the worked example ("this cluster builds vSphere
VMs"): label `cicd-platform/crossplane-vspherevm: "true"`.

**Why per-capability appsets and not one wildcard with a dynamic label?** ArgoCD
`clusters` selectors only match *static* label keys, and a template can't skip an
app — so a component discovered dynamically from git can't be gated on a
dynamically-named label inside one appset. One appset per capability is the
idiomatic, implementable path (and mirrors every other `appset-*.yaml` here).

### Monorepo layout this expects (`stuttgart-things` repo)

```
crossplane/
  platform/
    baseline/<component>/vars/<env>.yaml          # opt-out, env-keyed
    capabilities/<cap>/<component>/vars/<env>.yaml # opt-in per capability
  xrs/
    <cap>/<env>/                                   # plain manifests, opt-in per capability
```

> **Note:** as drafted, the only env content in the monorepo is `labda`, while the
> registered clusters are labelled `env: LabUL`. The monorepo must grow the
> matching `<env>` vars files / folders (or clusters be relabelled) before any of
> these appsets produce Applications.

### Adding a capability

1. In the monorepo: add `crossplane/platform/capabilities/<cap>/…` and
   `crossplane/xrs/<cap>/<env>/`.
2. Here: copy `appset-cxp-vspherevm.yaml` → `appset-cxp-<cap>.yaml`, swap the label
   key + the two monorepo paths, and add the file to `kustomization.yaml`.
3. Onboard a cluster: label its Secret `cicd-platform/crossplane-<cap>: "true"`
   (a use-case is just a preset of these labels applied at provisioning).

## Related

- [`cicd/dapr`](../../cicd/dapr/), [`cicd/kro`](../../cicd/kro/) — catalog entries rendered by these ApplicationSets.
- [`platforms/network`](../network/) — sibling platform bundle targeting clusterbook-registered classic clusters (different selector, different catalog entries).
