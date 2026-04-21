# cicd/argo-rollouts

Catalog entries for [Argo Rollouts](https://argo-rollouts.readthedocs.io/) and Gateway API `HTTPRoute` resources exposing the dashboard (or any other Rollouts-driven backend). Two independently deployable pieces.

## Layout

```
cicd/argo-rollouts/
├── install/       app-of-apps — renders Application "argo-rollouts" → argoproj/argo-helm
├── httproutes/    plain Helm chart — renders N Gateway API HTTPRoute resources from a values list
└── README.md
```

Typical combinations:

| Want | Applications to create |
|---|---|
| Controller + dashboard (no ingress) | `install` |
| Controller + dashboard + HTTPRoute | `install`, `httproutes` |
| Extra HTTPRoutes for Rollouts canary shaping on an already-installed controller | `httproutes` |

## install/

App-of-apps Helm chart packaging the upstream `argoproj/argo-rollouts` chart. The built-in dashboard Ingress is force-disabled — pair with `httproutes/` (or your own ingress / HTTPRoute / VirtualService) if you want the dashboard reachable.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argo-rollouts
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: cicd/argo-rollouts/install
    helm:
      values: |
        project: my-cluster
        destination:
          server: https://<cluster-api>:6443
          namespace: argo-rollouts
        controller:
          replicas: 2
          logging: { level: info, format: json }
          metrics: { enabled: true, serviceMonitor: { enabled: true } }
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

### install values reference

See `install/values.yaml` / `install/values.schema.json`.

| Key | Default | Purpose |
|---|---|---|
| `project` | `default` | ArgoCD AppProject for the rendered Application |
| `destination.server` / `namespace` | `https://kubernetes.default.svc` / `argo-rollouts` | Target workload cluster + namespace |
| `chartVersion` | `2.40.9` | Upstream argoproj/argo-rollouts chart version |
| `installCRDs` / `keepCRDs` | `true` / `true` | Chart installs Rollout CRDs and keeps them on uninstall |
| `clusterInstall` / `createClusterAggregateRoles` | `true` / `true` | Cluster-wide controller with aggregate RBAC |
| `controller.replicas` | `2` | Controller replica count |
| `controller.logging.level` / `format` | `info` / `text` | Enums: `debug`/`info`/`warn`/`error`, `text`/`json` |
| `controller.metrics.enabled` / `serviceMonitor.enabled` | `false` / `false` | Prometheus metrics + ServiceMonitor |
| `dashboard.enabled` / `readonly` / `replicas` | `true` / `false` / `1` | Dashboard deployment |
| `providerRBAC.enabled` / `gatewayAPI` | `true` / `true` | Grants the controller RBAC to mutate Gateway API HTTPRoutes for canary traffic shaping |
| `extraValues` | `{}` | Deep-merged on top of the computed upstream `valuesObject` (resources, nodeSelector, analysis providers, …) |
| `syncPolicy` | automated + retry | Applied to the rendered child Application |

Hardcoded in the template (override via `extraValues` if needed): `dashboard.service.{type=ClusterIP, port=3100, targetPort=3100}` and `dashboard.ingress.enabled: false`.

## httproutes/

Plain Helm chart that renders one `gateway.networking.k8s.io/v1` `HTTPRoute` per entry in `httpRoutes: [...]`. The list is empty by default. Each entry carries `parentRefs`, `hostnames`, and raw `rules` passed through — so you can route to the dashboard, to canary Services managed by a Rollout, or both.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argo-rollouts-httproutes
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: cicd/argo-rollouts/httproutes
    helm:
      values: |
        httpRoutes:
          - name: argo-rollouts-dashboard
            namespace: argo-rollouts
            parentRefs:
              - name: cilium-gateway
                namespace: default
            hostnames:
              - rollouts.my-cluster.example.com
            rules:
              - matches:
                  - path: { type: PathPrefix, value: / }
                backendRefs:
                  - name: argo-rollouts-dashboard
                    port: 3100
  destination:
    server: https://<cluster-api>:6443
    namespace: argo-rollouts
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ServerSideApply=true]
```

### httproutes values reference

| Key | Default | Purpose |
|---|---|---|
| `httpRoutes` | `[]` | List of HTTPRoutes to render |

Per-entry fields (all required):

| Field | Purpose |
|---|---|
| `name` / `namespace` | HTTPRoute identity |
| `parentRefs` | Gateway(s) to attach to; each `{name, namespace}` minimum, extra fields pass through |
| `hostnames` | DNS hostnames the route answers to (min 1) |
| `rules` | Raw `spec.rules` list — passed to the Gateway API webhook for validation |

## Fleet — one `ApplicationSet` per piece

Label clusters with `install/argo-rollouts: "true"` for the controller, and separately `install/argo-rollouts-httproutes: "true"` where you want routes shipped.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: argo-rollouts
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - clusters:
        selector:
          matchLabels:
            install/argo-rollouts: "true"
  template:
    metadata:
      name: 'argo-rollouts-{{ .name }}'
    spec:
      project: '{{ .name }}'
      source:
        repoURL: https://github.com/stuttgart-things/argocd.git
        targetRevision: main
        path: cicd/argo-rollouts/install
        helm:
          values: |
            project: {{ .name }}
            destination:
              server: {{ .server }}
              namespace: argo-rollouts
      destination: { server: https://kubernetes.default.svc, namespace: argocd }
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

For `httproutes/`, hostnames and parentRefs typically vary per cluster — prefer per-cluster `Application`s (or pull the values from cluster-Secret annotations and interpolate into the `values` string) over a single fleet `ApplicationSet` shipping identical routes.

## Migrating from the previous kustomize layout

| Old | New |
|---|---|
| `cicd/argo-rollouts/chart` (kustomize dir, Application inlined) | `cicd/argo-rollouts/install` (Helm chart; consumer Application passes `helm.values`) |
| `cicd/argo-rollouts/httproute` (single raw HTTPRoute with `argo-rollouts.example.com` placeholder and hardcoded parent `cilium-gateway/default`) | `cicd/argo-rollouts/httproutes` (Helm chart; `httpRoutes: [...]` list — hostnames, parentRefs, rules all per-cluster values) |

**Breaking change**: `httproutes/` no longer ships a pre-built dashboard route with `argo-rollouts.example.com`. The list is empty; consumers declare the routes they actually have. Also renamed `httproute` → `httproutes` (plural) to reflect the list-valued shape.

## Related

- Flux equivalent: [`stuttgart-things/flux` — `cicd/argo-rollouts`](https://github.com/stuttgart-things/flux/tree/main/cicd/argo-rollouts) — Flux ships the controller values via env-var substitution; this catalog maps them to typed first-class values with a JSON schema.
- Pairs with: [`infra/cilium/gateway`](../../infra/cilium/gateway/) for the parent `cilium-gateway` referenced in the HTTPRoute example.
