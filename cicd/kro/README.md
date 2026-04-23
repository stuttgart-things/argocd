# cicd/kro

Catalog entry for [kro](https://kro.run/) (Kube Resource Orchestrator) — packaged as an **app-of-apps Helm chart** wrapping the upstream OCI Helm chart at `registry.k8s.io/kro/charts`. Consumers create one ArgoCD `Application` (or `ApplicationSet`) pointing at `cicd/kro/install`, pass overrides via `helm.values`, and the chart renders the child `Application` that installs kro.

## Layout

```
cicd/kro/
└── install/                        app-of-apps Helm chart
    ├── Chart.yaml
    ├── values.yaml
    ├── values.schema.json          schema-validated overrides
    └── templates/
        └── kro.yaml                renders Application "kro" (sync-wave 0)
```

## OCI Helm source

kro publishes to OCI only. Argo CD expresses this as:

```yaml
source:
  repoURL: registry.k8s.io/kro/charts   # no oci:// prefix
  chart: kro
  targetRevision: 0.9.1
```

Argo CD 2.8+ with `helm.enableOciSupport: true` (default in recent versions) is required. The registry is anonymous, no pull credentials needed.

## `Replace=true` sync option

The default `syncPolicy.syncOptions` include `Replace=true` because kro ships its own CRDs in the chart and the upstream HelmRelease equivalent uses `install.crds: CreateReplace`. `Replace=true` mirrors that behaviour on sync: CRDs are replaced rather than strategically merged, which matches kro's release expectations and avoids field drift on upgrades.

## Consumer usage

### Single cluster — one `Application`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kro
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: cicd/kro/install
    helm:
      values: |
        project: my-cluster
        destination:
          server: https://<cluster-api>:6443
          namespace: kro-system
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

The outer `destination.server` is the **management cluster** (where the rendered child Application CR lives). The inner `destination.server` in values is the **workload cluster** where kro installs.

### Fleet — one `ApplicationSet` across many clusters

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: kro
  namespace: argocd
spec:
  generators:
    - clusters:
        selector:
          matchLabels:
            kro: enabled
  template:
    metadata:
      name: '{{name}}-kro'
    spec:
      project: '{{name}}'
      source:
        repoURL: https://github.com/stuttgart-things/argocd.git
        targetRevision: main
        path: cicd/kro/install
        helm:
          values: |
            project: {{name}}
            destination:
              server: {{server}}
              namespace: kro-system
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
| `destination.server` / `namespace` | `https://kubernetes.default.svc` / `kro-system` | Target workload cluster + namespace |
| `chartVersion` | `0.9.1` | Upstream kro Helm chart version |
| `extraValues` | `{}` | Deep-merged on top of the `valuesObject` passed to the upstream chart |
| `syncPolicy` | automated + retry + `Replace=true` | Applied to the rendered Application |

## Related

- Flux equivalent: [`stuttgart-things/flux` — `cicd/kro`](https://github.com/stuttgart-things/flux/tree/main/cicd/kro)
- kro docs: <https://kro.run/docs>
