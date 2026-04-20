# apps/headlamp

Catalog entry for [Headlamp](https://headlamp.dev/) — a general-purpose Kubernetes web UI. Packaged as an **app-of-apps Helm chart**: consumers create one ArgoCD `Application` (or `ApplicationSet`) pointing at `apps/headlamp/chart`, pass overrides via `helm.values` (or `helm.valuesObject` on Argo CD 2.6+), and the chart renders the real child `Application`s that install Headlamp and optionally its RBAC.

Unlike the kustomize-remote-base pattern used elsewhere in this catalog, this entry requires **zero files** in the consumer repo — everything is driven by values on the consumer-side Argo CR.

## Layout

```
apps/headlamp/
├── chart/                          app-of-apps Helm chart (what consumers point at)
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── values.schema.json          schema-validated overrides
│   └── templates/
│       ├── chart.yaml              renders Application "headlamp"      (sync-wave 0)
│       └── rbac.yaml               renders Application "headlamp-rbac" (sync-wave 10, gated by rbac.enabled)
└── manifests/
    └── rbac/clusterrolebinding.yaml   loaded by the headlamp-rbac Application from this repo
```

## What gets deployed

### `headlamp` Application (always)
Installs Headlamp `0.40.0` from `https://kubernetes-sigs.github.io/headlamp/` into the configured namespace. The chart constructs the upstream `valuesObject` from first-class values:

- `config.watchPlugins: true` — hot-reload plugins on disk changes
- `pluginsManager` — enabled when `.Values.plugins` is non-empty, pre-installs each plugin
- `httpRoute` — Gateway API `HTTPRoute` built from `.Values.httpRoute.{hostname,gateway.name,gateway.namespace}`
- `.Values.extraValues` — deep-merged on top as an escape hatch for any upstream key not exposed above

### `headlamp-rbac` Application (opt-in, `rbac.enabled: true`)
A single `ClusterRoleBinding` binding `cluster-admin` to the Headlamp ServiceAccount. **Only enable** if you intend to let Headlamp act as a cluster admin — for multi-tenant or scoped access, leave it off and bind a narrower Role yourself.

## Consumer usage

### Single cluster — one `Application`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: headlamp
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: apps/headlamp/chart
    helm:
      values: |
        project: my-cluster
        destination:
          server: https://<cluster-api>:6443
          namespace: headlamp
        httpRoute:
          enabled: true
          hostname: headlamp.my-cluster.example.com
          gateway:
            name: cilium-gateway
            namespace: default
        rbac:
          enabled: true
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

Note: the outer `destination.server` is the **management cluster** (where the rendered child Applications live, in the `argocd` namespace). The inner `destination.server` under `helm.values` is the **workload cluster** where Headlamp itself runs.

> **Why `helm.values` (string) and not `helm.valuesObject` (object)?** Both work, but `values: |` (a YAML block string) is universally compatible across every Argo CD version since 2.0. `valuesObject:` needs Argo CD 2.6+ and has been observed to mis-serialize on some older patch versions, producing `cannot unmarshal string into Go value of type map[string]interface {}` from Helm. On a confirmed-modern Argo, `valuesObject:` is type-preserving and saves you an indentation level — swap freely.

### Fleet — one `ApplicationSet` across many clusters

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: headlamp
  namespace: argocd
spec:
  generators:
    - clusters:
        selector:
          matchLabels:
            headlamp: enabled
  template:
    metadata:
      name: '{{name}}-headlamp'
    spec:
      project: '{{name}}'
      source:
        repoURL: https://github.com/stuttgart-things/argocd.git
        targetRevision: main
        path: apps/headlamp/chart
        helm:
          values: |
            project: {{name}}
            destination:
              server: {{server}}
              namespace: headlamp
            httpRoute:
              enabled: true
              hostname: headlamp.{{metadata.labels.domain}}
              gateway:
                name: cilium-gateway
                namespace: default
            # rbac.enabled takes a boolean — you cannot drive it from a
            # cluster-secret label via ApplicationSet templating (Go-template
            # output is always a string; the chart's JSON Schema is strict about
            # type: boolean). For per-cluster RBAC toggling, apply a dedicated
            # Application per target cluster.
      destination:
        server: https://kubernetes.default.svc
        namespace: argocd
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

Label the ArgoCD cluster Secrets with `headlamp: enabled` and `domain: <fqdn>`; add/remove clusters without touching this repo. Note: `rbac.enabled` (a boolean chart value) cannot be driven by a cluster-secret label — see the inline comment above for the reason and the dedicated-Application workaround.

## Values reference

See `chart/values.yaml` for defaults and `chart/values.schema.json` for the full JSON Schema. Invalid overrides (unknown keys, wrong types, missing `hostname` when `httpRoute.enabled: true`) fail the sync loudly.

| Key | Default | Purpose |
|---|---|---|
| `project` | `default` | ArgoCD AppProject for both rendered Applications |
| `destination.server` | `https://kubernetes.default.svc` | Target cluster API |
| `destination.namespace` | `headlamp` | Namespace for Headlamp |
| `chartVersion` | `0.40.0` | Upstream Headlamp chart version |
| `httpRoute.enabled` | `true` | Render a Gateway API HTTPRoute |
| `httpRoute.hostname` | `headlamp.example.com` | Public hostname (override per cluster) |
| `httpRoute.gateway.name` / `namespace` | `cilium-gateway` / `default` | Gateway reference |
| `plugins` | `[prometheus 0.8.2]` | Plugins pre-loaded by pluginsManager; `[]` disables it |
| `extraValues` | `{}` | Deep-merged on top of the computed upstream `valuesObject` |
| `rbac.enabled` | `false` | Install the cluster-admin ClusterRoleBinding |
| `catalog.repoURL` / `targetRevision` | this repo / `HEAD` | Where the rbac Application fetches manifests from |
| `syncPolicy` | automated + retry | Applied to both rendered Applications |

## Login token

Once deployed, generate a ServiceAccount token:

```bash
kubectl create token headlamp -n headlamp --duration=8760h
```

Paste into the Headlamp login screen.

## Migrating from the previous kustomize layout

If you were consuming the old `apps/headlamp/chart` + `apps/headlamp/rbac` paths via a Kustomize overlay with JSON-patches: replace that overlay with a single `Application` (example above). The overlay's patches map to values as follows:

| Old JSON patch | New value |
|---|---|
| `/spec/project` | `project` |
| `/spec/destination/server` | `destination.server` |
| `/spec/source/helm/valuesObject/httpRoute/parentRefs/0/name` | `httpRoute.gateway.name` |
| `/spec/source/helm/valuesObject/httpRoute/parentRefs/0/namespace` | `httpRoute.gateway.namespace` |
| `/spec/source/helm/valuesObject/httpRoute/hostnames/0` | `httpRoute.hostname` |
| include/exclude the `rbac` resource | `rbac.enabled: true\|false` |

## Related

- Flux equivalent: [`stuttgart-things/flux` — `apps/headlamp`](https://github.com/stuttgart-things/flux/tree/main/apps/headlamp)
- Headlamp docs: <https://headlamp.dev/docs>
