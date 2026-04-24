# apps/clusterbook

Catalog entry for [Clusterbook](https://github.com/stuttgart-things/clusterbook) — GitOps-based IP address management for Kubernetes clusters. Packaged as an **app-of-apps Helm chart** over the `clusterbook-kustomize` OCI base: consumers create one ArgoCD `Application` (or `ApplicationSet`) pointing at `apps/clusterbook/install`, pass overrides via `helm.values`, and the chart renders the child `Application`s that install Clusterbook, optionally publish its HTTPRoute, and optionally provision the PowerDNS token Secret.

Port of [`stuttgart-things/flux` — `apps/clusterbook`](https://github.com/stuttgart-things/flux/tree/main/apps/clusterbook). The flux version's `postBuild.substitute` variables map to first-class values here.

## Layout

```
apps/clusterbook/
├── install/                        app-of-apps Helm chart (what consumers point at)
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── values.schema.json
│   └── templates/
│       ├── chart.yaml              renders Application "clusterbook"            (sync-wave 0, OCI kustomize + patches)
│       ├── httproute.yaml          renders Application "clusterbook-httproute"  (sync-wave 10, gated by httpRoute.enabled)
│       └── pdns.yaml               renders Application "clusterbook-pdns"       (sync-wave -10, gated by pdns.enabled)
├── httproute/                      Gateway API HTTPRoute sub-chart
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── values.schema.json
│   └── templates/httproutes.yaml
└── pdns/                           PDNS token Secret sub-chart
    ├── Chart.yaml
    ├── values.yaml
    ├── values.schema.json
    └── templates/secret.yaml
```

## What gets deployed

### `clusterbook` Application (always)
Argo CD Kustomize source against `oci://ghcr.io/stuttgart-things/clusterbook-kustomize` at `.Values.kustomize.targetRevision`. The install chart emits Kustomize `patches` equivalent to the flux version's `spec.patches`:

- **Deployment image override** — `ghcr.io/stuttgart-things/clusterbook:<tag>` from `.Values.image`
- **Deployment `envFrom`** — always mounts `clusterbook-config` ConfigMap; adds `clusterbook-pdns` Secret when `pdns.enabled: true`
- **ConfigMap `clusterbook-config`** — sets `PDNS_ENABLED` / `PDNS_URL` / `PDNS_ZONE` from `.Values.pdns`
- **HTTPRoute delete** — when `httpRoute.enabled: true`, the KCL-generated HTTPRoute in the base is pruned (we ship our own via the sub-Application below). Leave `httpRoute.enabled: false` to keep the base's HTTPRoute.

### `clusterbook-httproute` Application (opt-in, `httpRoute.enabled: true`)
Renders one Gateway API `HTTPRoute` pointing at `clusterbook-http:8080`, parented onto `.Values.httpRoute.gateway`.

### `clusterbook-pdns` Application (opt-in, `pdns.enabled: true`, sync-wave -10)
Provisions the `clusterbook-pdns` Secret with `PDNS_TOKEN` before the main Application syncs. **Inlining a literal token in git is a dev-only path** — for real deployments, disable this sub-Application and provision the Secret via ExternalSecrets / SOPS / Vault plugin.

## Consumer usage

### Single cluster — one `Application`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: clusterbook
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: apps/clusterbook/install
    helm:
      values: |
        project: my-cluster
        destination:
          server: https://<cluster-api>:6443
          namespace: clusterbook
        kustomize:
          repoURL: ghcr.io/stuttgart-things/clusterbook-kustomize
          targetRevision: 1.24.0
        image:
          repository: ghcr.io/stuttgart-things/clusterbook
          tag: 1.24.0
        httpRoute:
          enabled: true
          hostname: clusterbook.my-cluster.example.com
          gateway:
            name: cilium-gateway
            namespace: default
        pdns:
          enabled: true
          url: https://pdns.my-cluster.example.com
          zone: sthings.io
          token: ${PDNS_TOKEN}
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

The outer `destination.server` is the **management cluster** (where the rendered child Applications live, in `argocd`). The inner `destination.server` is the **workload cluster** where Clusterbook runs.

## Values reference

See `install/values.yaml` for defaults and `install/values.schema.json` for the full JSON Schema. Invalid overrides fail the sync loudly.

| Key | Default | Purpose |
|---|---|---|
| `project` | `default` | AppProject for all rendered Applications |
| `destination.server` | `https://kubernetes.default.svc` | Target cluster API |
| `destination.namespace` | `clusterbook` | Namespace for Clusterbook |
| `kustomize.repoURL` | `ghcr.io/stuttgart-things/clusterbook-kustomize` | OCI kustomize base |
| `kustomize.targetRevision` | `1.24.0` | Kustomize base tag (flux `CLUSTERBOOK_VERSION`) |
| `image.repository` / `tag` | `ghcr.io/stuttgart-things/clusterbook` / `1.24.0` | Container image override patched into the base Deployment |
| `pdns.enabled` | `false` | Render the PDNS Secret sub-Application + wire `envFrom` + set ConfigMap keys |
| `pdns.url` / `zone` / `token` | empty | PowerDNS API URL, zone, token (inline is dev-only) |
| `httpRoute.enabled` | `true` | Render the HTTPRoute sub-Application + delete the base's KCL HTTPRoute |
| `httpRoute.hostname` | `clusterbook.example.com` | FQDN on the HTTPRoute (override per cluster) |
| `httpRoute.gateway.name` / `namespace` | `cilium-gateway` / `default` | Gateway reference |
| `catalog.repoURL` / `targetRevision` | this repo / `HEAD` | Where the httpRoute + pdns Applications fetch manifests from |
| `syncPolicy` | automated + retry | Applied to all rendered Applications |

## NetworkConfig CR

The `NetworkConfig` CR is **environment-specific data** and does not belong in this generic catalog entry. Place it in the cluster config (e.g. `config/<cluster>/clusterbook-networkconfig.yaml`) and annotate it so Argo seeds it once but never overwrites runtime changes:

```yaml
annotations:
  argocd.argoproj.io/sync-options: Prune=false,IgnoreExtraneous=true
```

## Related

- Flux equivalent: [`stuttgart-things/flux` — `apps/clusterbook`](https://github.com/stuttgart-things/flux/tree/main/apps/clusterbook)
- Clusterbook repo: <https://github.com/stuttgart-things/clusterbook>
