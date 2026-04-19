# config/cluster-project

Helm chart that renders an ArgoCD `AppProject` for a single cluster, parameterized by cluster identity and a small set of behavior switches. Intended to be sourced by an `ApplicationSet` running on the management cluster — one `AppProject` per registered cluster, label-driven.

## Layout

```
config/cluster-project/
└── chart/    Helm chart producing one AppProject per release
    ├── Chart.yaml
    ├── values.yaml
    └── templates/appproject.yaml
```

The chart itself does **not** ship an `Application`. It is consumed indirectly via an `ApplicationSet` `clusters` generator on the management cluster (see [Consumer usage](#consumer-usage)).

## Values

| Key | Type | Required | Default | Notes |
|---|---|---|---|---|
| `cluster.name` | string | ✅ | `""` | ArgoCD cluster Secret name (becomes the AppProject name + first destination name) |
| `cluster.server` | string | ✅ | `""` | Cluster API server URL |
| `allowAll` | bool | — | `false` | Permissive mode: `sourceRepos: ["*"]` + adds wildcard destination `*/*/*` |
| `tier` | string | — | `""` | `dev` implies `allowAll`; `prod` keeps strict (default); other values treated as strict |
| `project.description` | string | — | `Apps deployed to the <cluster.name> cluster` | |
| `project.finalizers` | list | — | `[resources-finalizer.argocd.argoproj.io]` | |
| `sourceRepos` | list | — | `stuttgart-things/*`, `oci://ghcr.io/stuttgart-things/*` | Strict-mode only — ignored when `allowAll`/`tier=dev` |
| `extraDestinations` | list | — | `[]` | Strict-mode only — appended to the per-cluster + in-cluster destinations |
| `clusterResourceWhitelist` | list | — | `[{group: '*', kind: '*'}]` | |
| `namespaceResourceWhitelist` | list | — | `[{group: '*', kind: '*'}]` | |
| `orphanedResources.warn` | bool | — | `true` | |

### Behavior matrix

`allowAll` and `tier` combine as `permissive = allowAll || (tier == "dev")`:

| `tier` | `allowAll` | Effective mode | `sourceRepos` | Destinations |
|---|---|---|---|---|
| `""` (unset) | `false` | strict | `stuttgart-things/*` + OCI | cluster + in-cluster (+ `extraDestinations`) |
| `prod` | `false` | strict | same as above | same as above |
| `dev` | any | permissive | `["*"]` | cluster + in-cluster + `*/*/*` |
| any | `true` | permissive | `["*"]` | cluster + in-cluster + `*/*/*` |

## Cluster labels (the contract)

The ApplicationSet reads labels from the ArgoCD cluster Secret and forwards them as Helm values. Recognized labels:

| Label | Maps to value | Effect |
|---|---|---|
| `auto-project=true` | (selector) | **Required** — the `clusters` generator only matches Secrets carrying this label. Without it the cluster is ignored. |
| `tier=dev` | `tier: dev` | Permissive AppProject |
| `tier=prod` | `tier: prod` | Strict AppProject (same as omitting) |
| `allow-all=true` | `allowAll: "true"` | Permissive AppProject regardless of `tier` |

### Setting labels via `argocd` CLI

```bash
# Register a new cluster as dev (auto-project + tier in one go)
argocd cluster add <kubeconfig-context> \
  --name <cluster-name> \
  --label auto-project=true \
  --label tier=dev

# Update labels on an existing cluster (requires argocd ≥ 2.8)
# ⚠️ REPLACE semantics — see warning below; pass ALL labels you want to keep
argocd cluster set <name-or-server> --label auto-project=true --label tier=dev

# Verify
argocd cluster list -o wide
```

> ⚠️ **`argocd cluster set --label` replaces the entire label set.**
> Running `argocd cluster set foo --label tier=dev` on a cluster that already
> has `auto-project=true` will *drop* `auto-project`, the ApplicationSet
> selector stops matching, and the generated Application + AppProject get
> pruned. Always pass every label you want to keep in a single invocation.
>
> If you only want to add/change one label without touching the rest, use
> `kubectl label secret <cluster-secret> -n argocd <key>=<value> --overwrite`
> against the management cluster instead.

> Equivalent kubectl path (when working directly against the management cluster):
> ```bash
> kubectl label secret <cluster-secret> -n argocd auto-project=true tier=dev
> ```

## Consumer usage

Drop an `ApplicationSet` like the following onto your management cluster (i.e. the cluster running ArgoCD). It will iterate every cluster Secret carrying `auto-project=true` and produce one `proj-<cluster>` Application that renders this chart.

```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: cluster-projects
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - clusters:
        selector:
          matchLabels:
            auto-project: "true"
  template:
    metadata:
      name: 'proj-{{ .name }}'
    spec:
      project: default
      source:
        repoURL: https://github.com/stuttgart-things/argocd.git
        targetRevision: main
        path: config/cluster-project/chart
        helm:
          releaseName: 'proj-{{ .name }}'
          valuesObject:
            cluster:
              name: '{{ .name }}'
              server: '{{ .server }}'
            allowAll: '{{ index .metadata.labels "allow-all" | default "false" }}'
            tier: '{{ index .metadata.labels "tier" | default "" }}'
      destination:
        server: https://kubernetes.default.svc
        namespace: argocd
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - ServerSideApply=true
```

Reference deployment: [`stuttgart-things/stuttgart-things — clusters/labul/vsphere/platform-sthings/argocd/appset-cluster-projects.yaml`](https://github.com/stuttgart-things/stuttgart-things/blob/main/clusters/labul/vsphere/platform-sthings/argocd/appset-cluster-projects.yaml).

### End-to-end flow

1. Apply the `ApplicationSet` once to the management cluster's `argocd` namespace.
2. Register or label clusters with `auto-project=true` (+ optional `tier`/`allow-all`).
3. The ApplicationSet generates `proj-<cluster>` → which deploys this chart → which creates an `AppProject` named `<cluster>`.
4. Per-cluster Applications then use `spec.project: <cluster>` to be governed by that project.

## Local rendering / smoke tests

```bash
# Strict (prod default)
helm template t config/cluster-project/chart \
  --set cluster.name=k8s-prod \
  --set cluster.server=https://10.0.0.1:6443 \
  --set tier=prod

# Permissive via tier=dev
helm template t config/cluster-project/chart \
  --set cluster.name=tpl-testvm \
  --set cluster.server=https://10.0.0.2:6443 \
  --set tier=dev

# Permissive via explicit allowAll
helm template t config/cluster-project/chart \
  --set cluster.name=sandbox \
  --set cluster.server=https://10.0.0.3:6443 \
  --set allowAll=true
```

## Notes & caveats

- `cluster.name` and `cluster.server` are required — the chart fails fast (`required ...`) if either is empty.
- The chart only renders `AppProject`. The wrapping Application is produced by the ApplicationSet on the management cluster, not by this chart.
- The destination `name: in-cluster` (server `https://kubernetes.default.svc`) is always added so the project can host control-plane Applications (e.g. AppOfApps wrappers) alongside the workload Applications targeting the labelled cluster.
- Permissive mode (`*/*/*` destination) is intentionally broad. Reserve `tier=dev` / `allow-all=true` for short-lived or fully-trusted clusters.

## Related

- Companion appset: [`stuttgart-things/stuttgart-things` PR #2076](https://github.com/stuttgart-things/stuttgart-things/pull/2076)
- Existing per-cluster AppProject pattern (manual, pre-chart): [`proj-cicd.yaml`](https://github.com/stuttgart-things/stuttgart-things/blob/main/clusters/labul/vsphere/platform-sthings/argocd/proj-cicd.yaml), [`proj-kind-dev2.yaml`](https://github.com/stuttgart-things/stuttgart-things/blob/main/clusters/labul/vsphere/platform-sthings/argocd/kind-dev2/proj-kind-dev2.yaml)
