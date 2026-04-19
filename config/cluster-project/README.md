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

<details>
<summary><b>Onboard a new cluster end-to-end via Dagger shell</b> (ephemeral container, no local tool installs)</summary>

Spin up a throwaway Wolfi container with `kubectl` + the `argocd` CLI, mount the **target cluster's** kubeconfig, and run the registration from inside.

```bash
# 1. Open a Dagger shell with kubectl + argocd available
dagger -c 'container |
  from cgr.dev/chainguard/wolfi-base:latest |
  with-mounted-file /kubeconfig <path-to-target-kubeconfig> |
  with-env-variable KUBECONFIG /kubeconfig |
  with-env-variable PATH /tmp:/usr/sbin:/usr/bin:/sbin:/bin |
  with-exec apk add curl git kubectl |
  with-exec -- curl -sSL -o /tmp/argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64 |
  with-exec chmod +x /tmp/argocd |
  terminal'
```

```bash
# 2. Inside the Dagger shell — log into ArgoCD (interactive prompts admin user + password)
argocd login <argocd-server>          # add --plaintext if the server has no TLS

# 3. Sanity-check kubectl can talk to the target cluster
kubectl get nodes

# 4. argocd cluster add reads the *current kubeconfig context* by name and
#    registers it under that same name. Many minimal kubeconfigs ship the
#    context as "default" — rename it first so the ArgoCD cluster Secret
#    gets a meaningful name.
kubectl config get-contexts
kubectl config rename-context default <cluster-name>

# 5. Register + label in one shot (avoids the cluster set --label replace footgun)
argocd cluster add <cluster-name> --yes \
  --label auto-project=true \
  --label tier=dev          # or omit / use tier=prod for strict mode
# Combine more labels by repeating --label, e.g.:
#   --label auto-project=true --label tier=dev --label allow-all=true --label env=lab
```

**Listing clusters**

```bash
# Compact view (name, server, version, status)
argocd cluster list

# Wider view including labels (recommended for verifying the appset selector)
argocd cluster list -o wide

# Full detail for a single cluster, including its label set
argocd cluster get <cluster-name> -o yaml | grep -A6 labels

# Cross-check from the kubectl side (run against the management cluster)
kubectl get secret -n argocd \
  -l argocd.argoproj.io/secret-type=cluster \
  -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.metadata.labels}{"\n"}{end}'
```

**Adding/changing a label *after* the cluster is registered**

⚠️ `argocd cluster set --label` **replaces the entire label set** — it is not a merge. To avoid silently dropping `auto-project=true` (which would prune the generated Application + AppProject), pass *every* label you want to keep:

```bash
# Safe: re-state all labels in one invocation
argocd cluster set <cluster-name> \
  --label auto-project=true \
  --label tier=dev \
  --label allow-all=true

# Surgical alternative: kubectl --overwrite against the management cluster's
# Secret (only touches the one label, leaves the rest alone)
kubectl label secret <cluster-secret> -n argocd allow-all=true --overwrite
```

The ApplicationSet on the management cluster picks up label changes within ~30s and re-renders `proj-<cluster-name>` → AppProject `<cluster-name>` accordingly.

**Notes**
- The container is ephemeral — when you exit the Dagger shell, the kubeconfig and any cached argocd creds are gone.
- Avoid `--username admin --password <plaintext>` on the command line; it lands in shell history. Use the interactive prompt or an SSO flow instead.
- If `argocd cluster add` errors with `context X does not exist in kubeconfig`, you forgot step 4 (rename the context).

</details>

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
