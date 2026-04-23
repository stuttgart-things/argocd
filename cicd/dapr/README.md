# cicd/dapr

Catalog entry for the [Dapr](https://dapr.io) control-plane — packaged as an **app-of-apps Helm chart** wrapping the upstream chart at `https://dapr.github.io/helm-charts/`. Consumers create one ArgoCD `Application` (or `ApplicationSet`) pointing at `cicd/dapr/install`, pass overrides via `helm.values`, and the chart renders the child `Application` that installs the Dapr runtime (operator, placement, scheduler, sentry, sidecar injector).

Placed in `cicd/` because Dapr is primarily used here as a CI/CD-adjacent workflow engine (Backstage template workers, Argo Rollouts glue, etc.), not as a user-facing app.

## Layout

```
cicd/dapr/
└── install/                        app-of-apps Helm chart
    ├── Chart.yaml
    ├── values.yaml
    ├── values.schema.json          schema-validated overrides
    └── templates/
        └── dapr.yaml               renders Application "dapr" (sync-wave 0)
```

## Opinionated defaults

Mirrors the Flux module (`flux/apps/dapr/components/control-plane`):

| Value | Setting |
|---|---|
| `global.ha.enabled` | `false` — single-replica control-plane; override to `true` for production (3 replicas per component) |
| `global.logAsJson` | `true` — structured logs |
| `logLevel.operator` / `logLevel.placement` / `logLevel.sidecarInjector` / `logLevel.scheduler` | `info` |

## Consumer usage

### Single cluster — one `Application`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: dapr
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: cicd/dapr/install
    helm:
      values: |
        project: my-cluster
        destination:
          server: https://<cluster-api>:6443
          namespace: dapr-system
        global:
          ha:
            enabled: true
          logAsJson: true
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

The outer `destination.server` is the **management cluster** (where the rendered child Application CR lives). The inner `destination.server` in values is the **workload cluster** where Dapr installs.

### Fleet — one `ApplicationSet` across many clusters

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: dapr
  namespace: argocd
spec:
  generators:
    - clusters:
        selector:
          matchLabels:
            dapr: enabled
  template:
    metadata:
      name: '{{name}}-dapr'
    spec:
      project: '{{name}}'
      source:
        repoURL: https://github.com/stuttgart-things/argocd.git
        targetRevision: main
        path: cicd/dapr/install
        helm:
          values: |
            project: {{name}}
            destination:
              server: {{server}}
              namespace: dapr-system
      destination:
        server: https://kubernetes.default.svc
        namespace: argocd
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

## Values reference

See `install/values.yaml` for defaults and `install/values.schema.json` for the full JSON Schema.

| Key | Default | Purpose |
|---|---|---|
| `project` | `default` | ArgoCD AppProject for the rendered Application |
| `destination.server` / `namespace` | `https://kubernetes.default.svc` / `dapr-system` | Target workload cluster + namespace |
| `chartVersion` | `1.17.4` | Upstream Dapr Helm chart version |
| `global.ha.enabled` | `false` | HA control-plane (3 replicas per component) |
| `global.logAsJson` | `true` | Structured JSON logs |
| `logLevel.operator` / `placement` / `sidecarInjector` / `scheduler` | `info` | Per-component log level |
| `extraValues` | `{}` | Deep-merged on top of the computed upstream `valuesObject` |
| `syncPolicy` | automated + retry | Applied to the rendered Application |

## Per-app Dapr Components

Per-app Dapr `Component` resources (state stores, pub/sub, bindings, etc.) are **not** installed by this catalog entry — they live with the app that uses them so each app can bring its own Redis / Kafka / etc. configuration. Add them via a separate `Application` targeting the app's namespace.

## Not ported from the Flux module

The Flux module also ships a `template-execution` component for the `dapr-backstage-template-execution` workflow worker. It's not ported here because it consumes an OCI **kustomize artifact** (`oci://ghcr.io/stuttgart-things/dapr-backstage-template-execution-kustomize`), which Argo CD's repo-server cannot render natively without a custom ConfigManagementPlugin sidecar. Clusters that need it should either:

1. Publish the rendered manifests to a Git path and point an Application at it, or
2. Install a CMP sidecar (e.g. `argocd-kustomize-cmp-oci`) and add a plugin-based Application to this catalog.

## Related

- Flux equivalent: [`stuttgart-things/flux` — `apps/dapr/components/control-plane`](https://github.com/stuttgart-things/flux/tree/main/apps/dapr/components/control-plane)
- Dapr docs: <https://docs.dapr.io/>
