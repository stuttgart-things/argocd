# cicd/tekton

Catalog entries for [Tekton](https://tekton.dev/) installed via the upstream Tekton Operator. Four independently deployable pieces — consumers create one ArgoCD `Application` per piece they need.

## Layout

```
cicd/tekton/
├── operator/                 app-of-apps — renders Application "tekton-operator" (directory source, sync-wave -10)
├── config/                   plain Helm chart — renders TektonConfig CR
├── ci-namespace/             plain Helm chart — renders namespaces with pruner-skip annotation
├── dashboard-httproute/      plain Helm chart — renders Gateway API HTTPRoute(s) for the Dashboard
└── README.md
```

Matrix of typical consumer shapes:

| Want | Applications to create |
|---|---|
| Tekton control plane only | `operator`, `config` |
| Full stack with Gateway-exposed Dashboard | `operator`, `config`, `dashboard-httproute` |
| Plus Crossplane-managed PipelineRuns protected from pruner | add `ci-namespace` |

`operator/` is app-of-apps — it wraps the vendored Tekton Operator manifests that live in the Flux repo via a `directory:` source. `config/`, `ci-namespace/`, and `dashboard-httproute/` are plain Helm charts — the consumer-owned `Application` IS the outer wrapper; there's no upstream Helm chart to re-wrap.

## operator/

App-of-apps chart rendering one `Application` that pulls the upstream Tekton Operator manifests via a `directory:` source. The manifests (~1500 lines of upstream YAML) live in [`stuttgart-things/flux` — `cicd/tekton/components/operator`](https://github.com/stuttgart-things/flux/tree/main/cicd/tekton/components/operator) and aren't duplicated into this repo.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: tekton-operator
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: cicd/tekton/operator
    helm:
      values: |
        project: my-cluster
        destination:
          server: https://<cluster-api>:6443
          namespace: tekton-operator
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

Rendered Application gets `sync-wave: -10` so CRDs register before dependent CRs (TektonConfig, etc.).

### operator values reference

See `operator/values.yaml` / `operator/values.schema.json` for the full contract.

| Key | Default | Purpose |
|---|---|---|
| `project` | `default` | ArgoCD AppProject for the rendered Application |
| `destination.server` / `namespace` | `https://kubernetes.default.svc` / `tekton-operator` | Target workload cluster + namespace |
| `source.repoURL` / `targetRevision` / `path` | Flux repo / `HEAD` / `cicd/tekton/components/operator` | Directory source for the vendored manifests |
| `syncPolicy` | automated + retry | Applied to the rendered child Application |

## config/

Plain Helm chart rendering a single `operator.tekton.dev/v1alpha1.TektonConfig` CR. The Operator uses this to install the Tekton components.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: tekton-config
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: cicd/tekton/config
    # Defaults suit most clusters — profile: all, pipeline.enable-api-fields: beta
  destination:
    server: https://<cluster-api>:6443
    namespace: tekton-operator
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ServerSideApply=true]
    retry:
      limit: 5
      backoff: { duration: 10s, factor: 2, maxDuration: 3m }
```

The retry loop matters — if `config` syncs before the Operator has registered `operator.tekton.dev/v1alpha1`, the first apply fails; retries give it ~3 minutes to settle.

### config values reference

| Key | Default | Purpose |
|---|---|---|
| `name` | `config` | TektonConfig singleton name (Operator expects this) |
| `profile` | `all` | `lite` / `basic` / `all` — which components the Operator installs |
| `targetNamespace` | `tekton-pipelines` | Where the Operator installs Tekton components |
| `pipeline.enableApiFields` | `beta` | `alpha` / `beta` / `stable` — Pipelines API gate |
| `pipeline.disableInlineSpec` | `""` | Operator default; set `"true"` / `"false"` to force |
| `extraSpec` | `{}` | Deep-merged onto `TektonConfig.spec` (addon, pruner, dashboard, hub, chains, etc.) |

## ci-namespace/

Plain Helm chart rendering one or more namespaces annotated `operator.tekton.dev/prune.skip: "true"`. Opt-in — use when PipelineRuns in a namespace are managed externally (e.g. by Crossplane's `provider-kubernetes`) and the global Operator pruner would otherwise trigger a delete/recreate loop.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: tekton-ci-namespace
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: cicd/tekton/ci-namespace
    helm:
      values: |
        namespaces:
          - name: tekton-ci
          - name: builds-protected
            labels:
              pod-security.kubernetes.io/enforce: baseline
  destination:
    server: https://<cluster-api>:6443
    namespace: default
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ServerSideApply=true]
```

The `prune.skip: "true"` annotation is always applied — consumer-provided `annotations` are merged on top.

## dashboard-httproute/

Plain Helm chart rendering `gateway.networking.k8s.io/v1.HTTPRoute` resources from a list. Requires a parent Gateway (e.g. from [`infra/cilium/gateway/`](../../infra/cilium/gateway/)).

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: tekton-dashboard-httproute
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: cicd/tekton/dashboard-httproute
    helm:
      values: |
        httpRoutes:
          - name: tekton-dashboard
            namespace: tekton-pipelines
            parentRefs:
              - name: cilium-gateway
                namespace: default
            hostnames:
              - tekton.my-cluster.example.com
            rules:
              - backendRefs:
                  - name: tekton-dashboard
                    port: 9097
  destination:
    server: https://<cluster-api>:6443
    namespace: tekton-pipelines
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ServerSideApply=true]
```

Should sync after the Operator has stood up `tekton-dashboard` — if ordering matters in your setup, wrap the Applications in an app-of-apps with `sync-wave` annotations.

## Pruner caveat

The Operator's pruner is a single cluster-wide CronJob. If PipelineRuns are managed externally (e.g. by Crossplane's `provider-kubernetes`), deletions trigger re-creates in a loop. The `ci-namespace/` chart is the mitigation — namespaces annotated with `operator.tekton.dev/prune.skip: "true"` are bypassed while global pruning continues elsewhere.

## Related

- Flux equivalent: [`stuttgart-things/flux` — `cicd/tekton`](https://github.com/stuttgart-things/flux/tree/main/cicd/tekton)
- The `operator/` sub-entry still pulls vendored manifests from the Flux repo via `directory:` source.
