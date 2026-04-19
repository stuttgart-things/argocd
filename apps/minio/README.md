# apps/minio

Catalog entry for [MinIO](https://min.io/) object storage via the stuttgart-things opinionated Bitnami-based chart, plus optional cert-manager Certificates and Gateway API HTTPRoutes for the console + S3 API.

## Layout

```
apps/minio/
├── chart/             # MinIO Helm chart (OCI, charts/minio v16.0.10, sync-wave 0)
├── certs/             # cert-manager Certificates for console + API hostnames (sync-wave -5)
└── httproute/         # Gateway API HTTPRoutes for console + API (sync-wave 10)
```

Each sub-entry is a self-contained Kustomize base producing exactly one `Application`.

## Components

### chart/
Installs the stuttgart-things `minio` chart (`16.0.10`) from the OCI registry `ghcr.io/stuttgart-things/charts/minio` into the `minio` namespace.

Opinionated defaults:

- `global.security.allowInsecureImages: true` — required because the image registry override pulls from `ghcr.io/stuttgart-things/minio` (mirror, not Bitnami's chart-pinned digest)
- `image.registry: ghcr.io`, `image.repository: stuttgart-things/minio`, `image.tag: 2025.4.22-debian-12-r1` — pinned mirrored MinIO image
- `networkPolicy.enabled: true` + `allowExternal: true`
- `auth.rootUser` / `auth.rootPassword` — **empty placeholders** (see *Credentials* below)
- `ingress.enabled: false` + `apiIngress.enabled: false` — chart Ingress disabled in favor of the `httproute/` sub-entry
- `persistence.storageClass: nfs4-csi`, `size: 10Gi`
- resources: 100m/256Mi requests, 1Gi memory limit

#### OCI Helm source

stuttgart-things publishes the MinIO chart to OCI only. Argo CD expresses this as:

```yaml
source:
  repoURL: ghcr.io/stuttgart-things/charts/minio   # no oci:// prefix
  chart: minio
  targetRevision: 16.0.10
```

Argo CD 2.8+ with `helm.enableOciSupport: true` (default) is required. The registry is anonymous, no pull credentials needed.

#### Credentials

The catalog ships `auth.rootUser` / `auth.rootPassword` as empty placeholders — **don't deploy as-is**. Consumers inject real credentials one of three ways:

1. **External Secrets / Vault**: a secret-management operator writes `minio-auth` into the namespace, then a consumer overlay patches the Application's `valuesObject.auth.existingSecret: minio-auth` (and removes the `rootUser` / `rootPassword` keys).
2. **Argo CD Vault Plugin**: wrap the `chart/` Application source in a plugin overlay that templates `<path:vault/data/minio#root-password>` placeholders.
3. **SOPS-encrypted overlay**: a consumer overlay patches `valuesObject.auth` from a decrypted values file.

### certs/
Two cert-manager `Certificate` resources in the `minio` namespace:

| Certificate | Hostname (default) | Secret |
|---|---|---|
| `minio-ingress-console` | `artifacts-console.example.com` | `artifacts-console-ingress-tls` |
| `minio-ingress-api` | `artifacts.example.com` | `artifacts-ingress-tls` |

Both issued by `ClusterIssuer/cluster-ca` (pairs with [`infra/cert-manager/cluster-ca/`](../../infra/cert-manager/cluster-ca/)). `sync-wave: -5` so Secrets exist before the HTTPRoutes / chart reference them.

Consumers must patch `commonName`, `dnsNames`, `secretName`, and `issuerRef.name` in a cluster overlay.

### httproute/
Two Gateway API `HTTPRoute` resources in the `minio` namespace:

| Route | Hostname (default) | Backend |
|---|---|---|
| `minio-console` | `artifacts-console.example.com` | `minio:9001` |
| `minio-api` | `artifacts.example.com` | `minio:9000` |

Both parent onto `Gateway/cilium-gateway` in the `default` namespace. `sync-wave: 10` so the chart's Service exists first. Consumers override `hostnames`, `parentRefs.name`, `parentRefs.namespace` per cluster.

> **Backend Service name.** The chart release name determines the Service names: with `releaseName: minio` the console Service is `minio` (port 9001) and the S3 API is served from the same Service (port 9000). Keep the Application's `releaseName` aligned if you rename.

## Consumer usage

Full stack (chart + certs + httproute):

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - https://github.com/stuttgart-things/argocd.git/apps/minio/chart?ref=main
  - https://github.com/stuttgart-things/argocd.git/apps/minio/certs?ref=main
  - https://github.com/stuttgart-things/argocd.git/apps/minio/httproute?ref=main
patches:
  - target: { kind: Application, name: minio }
    patch: |-
      - op: replace
        path: /spec/project
        value: <cluster-project>
      - op: replace
        path: /spec/destination/server
        value: https://<cluster-api>:<port>
  - target: { kind: Application, name: minio-certs }
    patch: |-
      - op: replace
        path: /spec/project
        value: <cluster-project>
      - op: replace
        path: /spec/destination/server
        value: https://<cluster-api>:<port>
  - target: { kind: Application, name: minio-httproute }
    patch: |-
      - op: replace
        path: /spec/project
        value: <cluster-project>
      - op: replace
        path: /spec/destination/server
        value: https://<cluster-api>:<port>
```

Chart-only clusters (no TLS, no Gateway API) omit `certs/` and `httproute/`.

### nginx Ingress instead of Gateway API

Skip `httproute/`. In a consumer overlay, patch the chart Application to enable the built-in chart Ingress:

```yaml
- target: { kind: Application, name: minio }
  patch: |-
    - op: replace
      path: /spec/source/helm/valuesObject/ingress/enabled
      value: true
    - op: replace
      path: /spec/source/helm/valuesObject/apiIngress/enabled
      value: true
    - op: add
      path: /spec/source/helm/valuesObject/ingress/ingressClassName
      value: nginx
    - op: add
      path: /spec/source/helm/valuesObject/ingress/hostname
      value: artifacts-console.<domain>
    # ... etc.
```

## Endpoints

| Endpoint | Service port | Description |
|---|---|---|
| Console | 9001 | MinIO web console UI |
| API (S3) | 9000 | S3-compatible API |

## Related

- Flux equivalent: [`stuttgart-things/flux` — `apps/minio`](https://github.com/stuttgart-things/flux/tree/main/apps/minio)
- Pairs with: [`infra/cert-manager/cluster-ca`](../../infra/cert-manager/cluster-ca/) (issues the TLS Certificates) and [`infra/cilium/gateway`](../../infra/cilium/gateway/) (parent for the HTTPRoutes)
