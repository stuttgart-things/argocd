# apps/minio

Catalog entry for [MinIO](https://min.io/) object storage via the stuttgart-things opinionated Bitnami-based chart, plus optional cert-manager Certificates and Gateway API HTTPRoutes for the console + S3 API. Packaged as an **app-of-apps Helm chart**: consumers create one ArgoCD `Application` (or `ApplicationSet`) pointing at `apps/minio/chart`, pass overrides via `helm.valuesObject`, and the chart renders the three child `Application`s that install MinIO, the Certificates, and the HTTPRoutes.

Unlike the kustomize-remote-base pattern used elsewhere in this catalog, this entry requires **zero files** in the consumer repo — everything is driven by values on the consumer-side Argo CR.

## Layout

```
apps/minio/
├── chart/                       app-of-apps Helm chart (what consumers point at)
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── values.schema.json
│   └── templates/
│       ├── minio.yaml           renders Application "minio"            (sync-wave 0)
│       ├── certs.yaml           renders Application "minio-certs"      (sync-wave -5, gated by certs.enabled)
│       └── httproute.yaml       renders Application "minio-httproute"  (sync-wave 10, gated by httpRoute.enabled)
└── charts/                      internal sub-charts rendered by the certs + httproute Applications
    ├── certs/                   cert-manager Certificates (list-shaped input from parent)
    └── httproute/               Gateway API HTTPRoutes     (list-shaped input from parent)
```

The two hostnames (`console` + `api`) are first-class values on the parent chart and flow automatically into both the Certificate list and the HTTPRoute list — set them once, get TLS + routing coherent across both Applications.

## What gets deployed

### `minio` Application (always, sync-wave 0)
Installs the stuttgart-things `minio` chart (`16.0.10` by default) from the OCI registry `ghcr.io/stuttgart-things/charts/minio` into the configured namespace. The chart constructs the upstream `valuesObject` from first-class values and allows deep-merge overrides via `extraValues`.

Opinionated baked-in values (not currently exposed as first-class keys, override via `extraValues` if needed):

- `global.imageRegistry: ghcr.io`, `global.security.allowInsecureImages: true` — the latter is required because `image.*` overrides the chart's pinned digest
- `networkPolicy.enabled: true` + `allowExternal: true`
- `ingress.enabled: false` + `apiIngress.enabled: false` — chart Ingress disabled in favor of the `httpRoute` sub-Application
- `persistence.enabled: true`

### `minio-certs` Application (opt-in, `certs.enabled: true`, sync-wave -5)
Two cert-manager `Certificate` resources, one per hostname:

| Certificate | CN / DNS (values key) | Secret (values key) |
|---|---|---|
| `minio-ingress-console` | `console.hostname` | `console.tlsSecret` |
| `minio-ingress-api` | `api.hostname` | `api.tlsSecret` |

Both issued by `certs.issuer` (default `ClusterIssuer/cluster-ca`, pairs with [`infra/cert-manager/cluster-ca/`](../../infra/cert-manager/cluster-ca/)). `sync-wave: -5` so Secrets exist before the HTTPRoutes reference them.

### `minio-httproute` Application (opt-in, `httpRoute.enabled: true`, sync-wave 10)
Two Gateway API `HTTPRoute` resources, one per hostname:

| Route | Hostname (values key) | Backend |
|---|---|---|
| `minio-console` | `console.hostname` | `minio:9001` |
| `minio-api` | `api.hostname` | `minio:9000` |

Both parent onto `httpRoute.gateway` (default `Gateway/cilium-gateway` in `default`). `sync-wave: 10` so the chart's Service exists first.

> **Backend Service name.** The chart release name (`minio`) determines the Service names. If you override the release via the upstream chart's `fullnameOverride`, keep the httproute backend names aligned.

## Consumer usage

### Single cluster — one `Application`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: minio
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: apps/minio/chart
    helm:
      valuesObject:
        catalog: { repoURL: https://github.com/stuttgart-things/argocd.git, targetRevision: main }
        project: my-cluster
        destination:
          server: https://<cluster-api>:6443
          namespace: minio
        auth:
          existingSecret: minio-auth           # pre-provisioned via ESO / Vault
        console:
          hostname: artifacts-console.my-cluster.example.com
          tlsSecret: artifacts-console-ingress-tls
        api:
          hostname: artifacts.my-cluster.example.com
          tlsSecret: artifacts-ingress-tls
        certs:
          enabled: true
          issuer: { name: cluster-ca, kind: ClusterIssuer }
        httpRoute:
          enabled: true
          gateway: { name: cilium-gateway, namespace: default }
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

Note: the outer `destination.server` is the **management cluster** (where the rendered child Applications live, in the `argocd` namespace). The inner `destination.server` in `valuesObject` is the **workload cluster** where MinIO itself runs.

**Pin `catalog.targetRevision`** to the same git ref the outer Application is pinned to — the certs + httproute child Applications load their sub-charts from this repo at that revision.

### Fleet — one `ApplicationSet` across many clusters

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: minio
  namespace: argocd
spec:
  generators:
    - clusters:
        selector:
          matchLabels:
            minio: enabled
  template:
    metadata:
      name: '{{name}}-minio'
    spec:
      project: '{{name}}'
      source:
        repoURL: https://github.com/stuttgart-things/argocd.git
        targetRevision: main
        path: apps/minio/chart
        helm:
          valuesObject:
            catalog: { repoURL: https://github.com/stuttgart-things/argocd.git, targetRevision: main }
            project: '{{name}}'
            destination: { server: '{{server}}', namespace: minio }
            auth: { existingSecret: minio-auth }
            console:
              hostname: 'artifacts-console.{{metadata.labels.domain}}'
              tlsSecret: artifacts-console-ingress-tls
            api:
              hostname: 'artifacts.{{metadata.labels.domain}}'
              tlsSecret: artifacts-ingress-tls
            certs:     { enabled: true, issuer: { name: cluster-ca, kind: ClusterIssuer } }
            httpRoute: { enabled: true, gateway: { name: cilium-gateway, namespace: default } }
      destination: { server: https://kubernetes.default.svc, namespace: argocd }
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

Label ArgoCD cluster Secrets with `minio: enabled` and `domain: <fqdn>`; add/remove clusters without touching this repo.

### Chart-only (no TLS, no Gateway API)

```yaml
certs:     { enabled: false }
httpRoute: { enabled: false }
```

### nginx Ingress instead of Gateway API

Disable the `httpRoute` sub-Application and re-enable the upstream chart's built-in Ingress via `extraValues`:

```yaml
httpRoute: { enabled: false }
extraValues:
  ingress:
    enabled: true
    ingressClassName: nginx
    hostname: artifacts-console.my-cluster.example.com
  apiIngress:
    enabled: true
    ingressClassName: nginx
    hostname: artifacts.my-cluster.example.com
```

## Values reference

See `chart/values.yaml` for defaults and `chart/values.schema.json` for the full JSON Schema. Invalid overrides fail the sync loudly.

| Key | Default | Purpose |
|---|---|---|
| `project` | `default` | ArgoCD AppProject for all three rendered Applications |
| `destination.server` / `namespace` | `https://kubernetes.default.svc` / `minio` | Target cluster API + namespace |
| `chartVersion` | `16.0.10` | Upstream MinIO OCI chart version |
| `image.registry` / `repository` / `tag` | `ghcr.io` / `stuttgart-things/minio` / `2025.4.22-debian-12-r1` | Pinned MinIO image (mirror) |
| `storageClass` / `storageSize` | `nfs4-csi` / `10Gi` | PVC StorageClass + size |
| `auth.rootUser` / `rootPassword` | `""` / `""` | Inlined credentials (use only via ArgoCD Vault Plugin or SOPS-decrypted overlay) |
| `auth.existingSecret` | `""` | **Preferred** — Secret name containing `root-user` / `root-password` keys |
| `resources.requests` / `limits` | 100m/256Mi / 1Gi | Pod resources |
| `console.hostname` / `tlsSecret` | `artifacts-console.example.com` / `artifacts-console-ingress-tls` | Console hostname + TLS secret name (flows into certs + httproute) |
| `api.hostname` / `tlsSecret` | `artifacts.example.com` / `artifacts-ingress-tls` | S3 API hostname + TLS secret name |
| `certs.enabled` | `true` | Render the Certificates sub-Application |
| `certs.issuer.name` / `kind` | `cluster-ca` / `ClusterIssuer` | cert-manager issuer reference |
| `httpRoute.enabled` | `true` | Render the HTTPRoutes sub-Application |
| `httpRoute.gateway.name` / `namespace` | `cilium-gateway` / `default` | Gateway API `Gateway` reference |
| `extraValues` | `{}` | Deep-merged on top of the computed upstream `valuesObject` |
| `catalog.repoURL` / `targetRevision` | this repo / `HEAD` | Where the certs + httpRoute child Applications fetch their sub-charts |
| `syncPolicy` | automated + retry | Applied to all three rendered Applications |

## Credentials

Defaults ship `auth.rootUser` / `auth.rootPassword` as empty placeholders — **don't deploy as-is**. Three patterns in order of preference:

1. **External Secrets / Vault** — an operator writes a Secret named e.g. `minio-auth` into the namespace with keys `root-user` + `root-password`; set `auth.existingSecret: minio-auth`. The chart reads credentials from the Secret and ignores the inline fields.
2. **ArgoCD Vault Plugin** — wrap the consumer `Application` with a Vault-plugin CMP so `auth.rootPassword` is templated from `<path:vault/data/minio#root-password>` at sync time.
3. **SOPS-encrypted overlay** — commit an encrypted values file in the consumer repo and decrypt in a pre-render hook.

## OCI Helm source

stuttgart-things publishes the MinIO chart to OCI only. Argo CD expresses this as:

```yaml
source:
  repoURL: ghcr.io/stuttgart-things/charts/minio   # no oci:// prefix
  chart: minio
  targetRevision: 16.0.10
```

Argo CD 2.8+ with `helm.enableOciSupport: true` (default) is required. The registry is anonymous, no pull credentials needed.

## Endpoints

| Endpoint | Service port | Description |
|---|---|---|
| Console | 9001 | MinIO web console UI |
| API (S3) | 9000 | S3-compatible API |

## Migrating from the previous kustomize layout

If you were consuming the old `apps/minio/{chart,certs,httproute}` paths via a Kustomize overlay with JSON patches: replace that overlay with a single `Application` (example above). The overlay's patches map to values as follows:

| Old JSON patch | New value |
|---|---|
| `/spec/project` (on every Application) | `project` |
| `/spec/destination/server` (on every Application) | `destination.server` |
| Certificate `spec.commonName` + `dnsNames[0]` (manifests) | `console.hostname` / `api.hostname` |
| Certificate `spec.secretName` (manifests) | `console.tlsSecret` / `api.tlsSecret` |
| HTTPRoute `spec.hostnames[0]` (manifests) | same as certs |
| HTTPRoute `spec.parentRefs[0].name` / `namespace` | `httpRoute.gateway.name` / `namespace` |
| Include/exclude `certs` path | `certs.enabled: true\|false` |
| Include/exclude `httproute` path | `httpRoute.enabled: true\|false` |

## Related

- Flux equivalent: [`stuttgart-things/flux` — `apps/minio`](https://github.com/stuttgart-things/flux/tree/main/apps/minio)
- Pairs with: [`infra/cert-manager/cluster-ca`](../../infra/cert-manager/cluster-ca/) (issues the TLS Certificates) and [`infra/cilium/gateway`](../../infra/cilium/gateway/) (parent for the HTTPRoutes)
