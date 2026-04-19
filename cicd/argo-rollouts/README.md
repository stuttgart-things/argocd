# cicd/argo-rollouts

Catalog entry for [Argo Rollouts](https://argo-rollouts.readthedocs.io/) plus an optional Gateway API `HTTPRoute` for the dashboard. Split into two sub-entries so consumers pick what they need.

## Layout

```
cicd/argo-rollouts/
├── chart/             # argo-rollouts Helm chart (v2.40.9, sync-wave 0)
└── httproute/         # Gateway API HTTPRoute for the dashboard (sync-wave 10)
```

Each sub-entry is a self-contained Kustomize base producing exactly one `Application`.

## Components

### chart/
Installs the [`argoproj/argo-rollouts`](https://artifacthub.io/packages/helm/argo/argo-rollouts) chart (`2.40.9`) from `https://argoproj.github.io/argo-helm` into the `argo-rollouts` namespace. Opinionated defaults:

- `installCRDs: true` + `keepCRDs: true` — chart installs Rollout CRDs and leaves them on uninstall
- `clusterInstall: true` + `createClusterAggregateRoles: true` — cluster-wide controller with aggregate RBAC
- `controller.replicas: 2` — HA controller
- `providerRBAC.providers.gatewayAPI: true` — grants the controller RBAC to mutate Gateway API `HTTPRoute` for traffic shaping
- `dashboard.enabled: true` — dashboard pod + `ClusterIP` Service on port 3100
- `dashboard.ingress.enabled: false` — the chart's built-in Ingress is off in favor of the `httproute/` sub-entry

### httproute/
One Gateway API `HTTPRoute` named `argo-rollouts-dashboard` in the `argo-rollouts` namespace that routes `argo-rollouts.example.com` → `argo-rollouts-dashboard:3100` via a parent `cilium-gateway` in the `default` namespace.

Consumers override `hostnames`, `parentRefs.name`, and `parentRefs.namespace` per cluster. `sync-wave: 10` so the `HTTPRoute` lands after the chart's Service exists.

## Consumer usage

Full stack (chart + httproute):

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - https://github.com/stuttgart-things/argocd.git/cicd/argo-rollouts/chart?ref=main
  - https://github.com/stuttgart-things/argocd.git/cicd/argo-rollouts/httproute?ref=main
patches:
  - target: { kind: Application, name: argo-rollouts }
    patch: |-
      - op: replace
        path: /spec/project
        value: <cluster-project>
      - op: replace
        path: /spec/destination/server
        value: https://<cluster-api>:<port>
  - target: { kind: Application, name: argo-rollouts-httproute }
    patch: |-
      - op: replace
        path: /spec/project
        value: <cluster-project>
      - op: replace
        path: /spec/destination/server
        value: https://<cluster-api>:<port>
```

Chart-only clusters (no Gateway API, or BYO ingress) omit the second entry.

### Overriding hostname + gateway

Patch the `HTTPRoute` inside the `httproute/manifests` path via a consumer overlay:

```yaml
- target: { kind: HTTPRoute, name: argo-rollouts-dashboard }
  patch: |-
    - op: replace
      path: /spec/hostnames/0
      value: rollouts.<domain>
    - op: replace
      path: /spec/parentRefs/0/name
      value: <gateway-name>
```

## Related

- Flux equivalent: [`stuttgart-things/flux` — `cicd/argo-rollouts`](https://github.com/stuttgart-things/flux/tree/main/cicd/argo-rollouts)
- Pairs with: [`infra/cilium/gateway`](../../infra/cilium/gateway/) for the parent `cilium-gateway`
