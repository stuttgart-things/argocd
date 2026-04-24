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
| `kargo-cicd`         | `cicd/kargo/install`           | `kargo`            | Kargo control-plane; HTTPRoute + certs (`cicd/kargo/httproute`, `cicd/kargo/certs`) not shipped by the platform — consumers wire those per cluster if exposure is needed |
| `tekton-cicd`        | `cicd/tekton/operator`         | `tekton-operator`  | Tekton **operator** only. The operator needs a `TektonConfig` CR to bring up the actual pipelines — supply via `cicd/tekton/config` as a follow-up Application or add a separate appset here if the platform should own it |

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

## Per-cluster opt-out

Default behaviour: labelling a cluster with `cicd-platform: "true"` enrols it in **all** three components. To skip a single component on a specific cluster, add a per-component label on that cluster's `Secret` in the `argocd` namespace:

| Label on the cluster Secret                    | Effect on that cluster |
|---|---|
| `cicd-platform/openebs: "false"`               | Skip `openebs-cicd`       |
| `cicd-platform/dapr: "false"`                  | Skip `dapr-cicd`          |
| `cicd-platform/kro: "false"`                   | Skip `kro-cicd`           |
| `cicd-platform/argo-rollouts: "false"`         | Skip `argo-rollouts-cicd` |
| `cicd-platform/crossplane: "false"`            | Skip `crossplane-cicd`    |
| `cicd-platform/kargo: "false"`                 | Skip `kargo-cicd`         |
| `cicd-platform/tekton: "false"`                | Skip `tekton-cicd`        |

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
