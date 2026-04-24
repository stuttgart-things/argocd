# platforms/cicd

CI/CD platform bundle: `ApplicationSet`s on the management cluster that fan out CI/CD-adjacent catalog entries to every cluster labelled as a CI/CD target.

All ApplicationSets share one cluster selector — the ArgoCD cluster `Secret` must carry:

```
cicd-platform: "true"
```

Catalog entries rendered (initial set):

| ApplicationSet | Catalog path       | Workload namespace | Notes |
|---|---|---|---|
| `dapr-cicd`    | `cicd/dapr/install` | `dapr-system`      | Dapr control-plane via app-of-apps chart |
| `kro-cicd`     | `cicd/kro/install`  | `kro-system`       | kro (Kube Resource Orchestrator); sync uses `Replace=true` for CRDs |

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

## Adding a catalog entry

1. Drop a new `appset-<name>.yaml` in this directory following the dapr/kro template (same cluster selector, path pointing at the new catalog entry's `install/` chart).
2. Add the filename to `kustomization.yaml`.
3. Commit — the `cicd-platform` Application self-heals and reconciles.

## Related

- [`cicd/dapr`](../../cicd/dapr/), [`cicd/kro`](../../cicd/kro/) — catalog entries rendered by these ApplicationSets.
- [`platforms/clusterbook`](../clusterbook/) — sibling platform bundle targeting clusterbook-registered clusters (different selector, different catalog entries).
