# cicd/crossplane

Catalog entries for [Crossplane](https://crossplane.io/) plus the stuttgart-things opinionated stack of composition Functions and Configurations. Three independently deployable pieces — consumers create one ArgoCD `Application` per piece they need, each pointing at a Helm chart in this directory.

## Layout

```
cicd/crossplane/
├── install/      app-of-apps — renders Application "crossplane" (sync-wave -10)
├── functions/    plain Helm chart — renders Crossplane Function resources
├── configs/      plain Helm chart — renders Crossplane Configuration resources
└── README.md
```

Matrix of typical consumer shapes:

| Want | Applications to create |
|---|---|
| Crossplane only | `install` |
| Crossplane + Functions | `install`, `functions` |
| Crossplane + Functions + stuttgart-things Configurations | `install`, `functions`, `configs` |

`install/` is app-of-apps (wraps the upstream Helm chart). `functions/` and `configs/` are plain Helm charts — the consumer-owned `Application` IS the outer wrapper; there's no upstream Helm chart to re-wrap.

## install/

App-of-apps Helm chart packaging the upstream `crossplane/crossplane` Helm chart. Consumer `Application` points at `cicd/crossplane/install`; chart renders a child `Application` targeting `https://charts.crossplane.io/stable` with a computed `valuesObject`.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: crossplane
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: cicd/crossplane/install
    helm:
      values: |
        project: my-cluster
        destination:
          server: https://<cluster-api>:6443
          namespace: crossplane-system
        providerPackages:
          - xpkg.upbound.io/crossplane-contrib/provider-helm:v1.2.0
          - xpkg.upbound.io/crossplane-contrib/provider-kubernetes:v1.2.1
          - xpkg.upbound.io/upbound/provider-opentofu:v1.1.0
          - xpkg.upbound.io/upbound/provider-aws-ec2:v1.1.0
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

`sync-wave: -10` on the rendered Application so Crossplane CRDs (Provider, Function, Configuration, etc.) land before dependent CRs in the other sub-entries.

### install values reference

See `install/values.yaml` / `install/values.schema.json` for the full contract.

| Key | Default | Purpose |
|---|---|---|
| `project` | `default` | ArgoCD AppProject for the rendered Application |
| `destination.server` / `namespace` | `https://kubernetes.default.svc` / `crossplane-system` | Target workload cluster + namespace |
| `chartVersion` | `2.2.0` | Upstream crossplane chart version |
| `args` | `[--debug, --enable-usages]` | Crossplane runtime args |
| `providerPackages` | helm + kubernetes + opentofu | Provider xpkgs installed alongside Crossplane |
| `extraValues` | `{}` | Deep-merged on top of the computed upstream `valuesObject` |
| `syncPolicy` | automated + retry | Applied to the rendered child Application |

## functions/

Plain Helm chart rendering `pkg.crossplane.io/v1[beta1].Function` resources from a list. Consumer `Application` points at `cicd/functions` directly — no app-of-apps wrapper, because there's no upstream Helm chart involved.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: crossplane-functions
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: cicd/crossplane/functions
    # Optional — the chart ships with the stuttgart-things default function
    # stack (auto-ready, go-templating, kcl, patch-and-transform). Override
    # only if you want a different set.
  destination:
    server: https://<cluster-api>:6443
    namespace: crossplane-system
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ServerSideApply=true]
```

### functions defaults

| Function | apiVersion | Package |
|---|---|---|
| `function-auto-ready` | `pkg.crossplane.io/v1beta1` | `xpkg.crossplane.io/crossplane-contrib/function-auto-ready:v0.6.0` |
| `function-go-templating` | `pkg.crossplane.io/v1beta1` | `xpkg.crossplane.io/crossplane-contrib/function-go-templating:v0.11.3` |
| `function-kcl` | `pkg.crossplane.io/v1` | `xpkg.upbound.io/crossplane-contrib/function-kcl:v0.12.0` |
| `function-patch-and-transform` | `pkg.crossplane.io/v1beta1` | `xpkg.upbound.io/crossplane-contrib/function-patch-and-transform:v0.9.3` |

Override the whole list via `helm.values`:

```yaml
helm:
  values: |
    functions:
      - name: function-kcl
        apiVersion: pkg.crossplane.io/v1
        package: xpkg.upbound.io/crossplane-contrib/function-kcl:v0.12.0
      - name: function-my-custom
        package: ghcr.io/acme/function-my-custom:v0.1.0
```

## configs/

Plain Helm chart rendering `pkg.crossplane.io/v1.Configuration` packages from a list.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: crossplane-configs
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: cicd/crossplane/configs
  destination:
    server: https://<cluster-api>:6443
    namespace: crossplane-system
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ServerSideApply=true]
```

### configs defaults

The chart ships the stuttgart-things Configuration stack published to `ghcr.io/stuttgart-things/crossplane/`:

| Configuration | Version |
|---|---|
| `cloud-config` | v0.5.1 |
| `volume-claim` | v0.1.1 |
| `storage-platform` | v0.6.0 |
| `ansible-run` | v12.0.0 |
| `pipeline-integration` | v0.1.2 |
| `harvester-vm` | v0.3.3 |

Configurations depend on the Functions they reference, so `functions/` should be present whenever `configs/` is. Override the list via `helm.values`:

```yaml
helm:
  values: |
    configurations:
      - name: cloud-config
        package: ghcr.io/stuttgart-things/crossplane/cloud-config:v0.5.1
      - name: my-custom
        package: ghcr.io/acme/my-custom-config:v0.1.0
```

## Fleet — one `ApplicationSet` per piece across many clusters

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: crossplane
  namespace: argocd
spec:
  generators:
    - clusters:
        selector:
          matchLabels:
            crossplane: enabled
  template:
    metadata:
      name: '{{name}}-crossplane'
    spec:
      project: '{{name}}'
      source:
        repoURL: https://github.com/stuttgart-things/argocd.git
        targetRevision: main
        path: cicd/crossplane/install
        helm:
          values: |
            project: {{name}}
            destination:
              server: {{server}}
              namespace: crossplane-system
      destination:
        server: https://kubernetes.default.svc
        namespace: argocd
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

Repeat the pattern for `functions/` and `configs/` — their consumer Application targets the workload cluster directly (no inner app-of-apps wrapping), so `destination.server` is `{{server}}` rather than `https://kubernetes.default.svc`.

## Related

- Flux equivalent: [`stuttgart-things/flux` — `cicd/crossplane`](https://github.com/stuttgart-things/flux/tree/main/cicd/crossplane)
- Crossplane docs: <https://docs.crossplane.io/>
- stuttgart-things Configurations: <https://github.com/stuttgart-things?q=crossplane>
