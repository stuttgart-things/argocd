# apps/headlamp

Catalog entry for [Headlamp](https://headlamp.dev/), a general-purpose Kubernetes web UI. Ships the chart with the Prometheus plugin pre-loaded and an optional `cluster-admin` ClusterRoleBinding for the Headlamp ServiceAccount.

## Layout

```
apps/headlamp/
├── chart/    Headlamp Helm chart 0.40.0 with Prometheus plugin + HTTPRoute (sync-wave 0)
└── rbac/     ClusterRoleBinding "headlamp-cluster-admin" (sync-wave 10, opt-in)
```

## Components

### chart/
Installs Headlamp `0.40.0` from `https://kubernetes-sigs.github.io/headlamp/` into the `headlamp` namespace. Values:

- `config.watchPlugins: true` — hot-reload plugins on disk changes
- `pluginsManager` — pre-installs the Prometheus plugin (`prometheus-0.8.2`)
- `httpRoute` — chart-native Gateway API `HTTPRoute` attached to `cilium-gateway` on `headlamp.example.com` (placeholder — consumers patch)

Consumers **must** patch `httpRoute.parentRefs` and `httpRoute.hostnames` to match their cluster's Gateway and DNS.

### rbac/
A single `ClusterRoleBinding` binding `cluster-admin` to the `headlamp` ServiceAccount. **Opt-in** — only include if you intend to let Headlamp act as a cluster admin. For multi-tenant or scoped access, skip this sub-entry and bind a narrower Role yourself.

## Login token

Once deployed, generate a ServiceAccount token:

```bash
kubectl create token headlamp -n headlamp --duration=8760h
```

Paste into the Headlamp login screen.

## Consumer usage

Full stack (chart + rbac):

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - https://github.com/stuttgart-things/argocd.git/apps/headlamp/chart?ref=main
  - https://github.com/stuttgart-things/argocd.git/apps/headlamp/rbac?ref=main
patches:
  - target: { kind: Application, name: headlamp }
    patch: |-
      - op: replace
        path: /spec/project
        value: <cluster-project>
      - op: replace
        path: /spec/destination/server
        value: https://<cluster-api>:<port>
      - op: replace
        path: /spec/source/helm/valuesObject/httpRoute/parentRefs/0/name
        value: <cluster-gateway-name>
      - op: replace
        path: /spec/source/helm/valuesObject/httpRoute/parentRefs/0/namespace
        value: <cluster-gateway-namespace>
      - op: replace
        path: /spec/source/helm/valuesObject/httpRoute/hostnames/0
        value: headlamp.<cluster-domain>
  - target: { kind: Application, name: headlamp-rbac }
    patch: |-
      - op: replace
        path: /spec/project
        value: <cluster-project>
      - op: replace
        path: /spec/destination/server
        value: https://<cluster-api>:<port>
```

Chart-only (external access / bring-your-own RBAC): drop the rbac sub-entry from `resources`.

## Related

- Flux equivalent: [`stuttgart-things/flux` — `apps/headlamp`](https://github.com/stuttgart-things/flux/tree/main/apps/headlamp)
- Headlamp docs: <https://headlamp.dev/docs>
