# apps/zitadel

Catalog entry for [ZITADEL](https://zitadel.com) — an open-source identity and
access platform (OIDC / OAuth2 provider). Packaged as an **app-of-apps Helm
chart** over the upstream `https://charts.zitadel.com` chart: consumers create
one ArgoCD `Application` pointing at `apps/zitadel/install`, pass overrides via
`helm.values`, and the chart renders child `Application`s for ZITADEL itself
(plus its bundled PostgreSQL), an opt-in dev-only masterkey Secret, and a
Gateway API HTTPRoute.

Mirrors the structure of [`apps/vault`](../vault/) and [`apps/backstage`](../backstage/).

> **Why this exists:** Part 1 of the Backstage PR-preview auth spike
> ([`sthings-backstage#82`](https://github.com/stuttgart-things/sthings-backstage/issues/82)).
> GitHub OAuth Apps allow no wildcard callback URLs, so dynamic preview
> hostnames can't authenticate against GitHub directly. ZITADEL becomes the
> IdP that absorbs that churn — Backstage talks generic OIDC to ZITADEL, and
> redirect-URI management moves into ZITADEL where it is controllable.

## Layout

```
apps/zitadel/
├── install/                      app-of-apps Helm chart (what consumers point at)
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── values.schema.json
│   └── templates/
│       ├── chart.yaml            renders Application "zitadel"           (sync-wave 0)
│       ├── secrets.yaml          renders Application "zitadel-secrets"   (sync-wave -10, gated by secretsApp.enabled — DEV ONLY)
│       └── httproute.yaml        renders Application "zitadel-httproute" (sync-wave 10, gated by httpRoute.enabled)
├── secrets/                      ZITADEL masterkey Secret (dev-only path; production: ExternalSecrets)
└── httproute/                    Gateway API HTTPRoute
```

## What gets deployed

### `zitadel` Application (always)
ArgoCD source on `https://charts.zitadel.com` at `chart: zitadel`,
`targetRevision: .Values.chartVersion`. Computed `valuesObject`:

- `replicaCount` + `image.{repository,tag,pullPolicy}` — pod count + image
- `zitadel.configmapConfig.{ExternalDomain,ExternalPort,ExternalSecure}` —
  ZITADEL's notion of the public URL. `ExternalDomain` **must** equal
  `httpRoute.hostname`; it is baked into issued tokens. `TLS.Enabled: false`
  because TLS terminates at the Gateway (see below).
- `zitadel.masterkeySecretName` — the chart reads the 32-byte masterkey from
  this Secret (key `masterkey`). The chart enforces *exactly one* of
  `masterkey` / `masterkeySecretName`; this chart always uses the latter.
- `postgresql.*` — bundled Bitnami PostgreSQL StatefulSet. When
  `postgresql.enabled: true` the upstream chart auto-wires the DB connection.
- `ingress.enabled: false` — Gateway API HTTPRoute is the ingress path here
- `.Values.extraValues` — deep-merged on top as an escape hatch

### `zitadel-secrets` Application (opt-in, `secretsApp.enabled: true`, sync-wave -10)
Provisions the Secret named by `zitadel.masterkeySecretName` with the masterkey
under key `masterkey`. **Inlining a literal masterkey in git is dev-only.** For
real deployments leave `secretsApp.enabled: false` and provision the Secret
out-of-band via ArgoCD Vault Plugin / ExternalSecrets Operator / SOPS. The
masterkey **must be exactly 32 characters** and must not change after the first
deploy (it encrypts data at rest).

### `zitadel-httproute` Application (opt-in, `httpRoute.enabled: true`, sync-wave 10)
Renders an `HTTPRoute` to the `zitadel` Service on port 8080. ZITADEL serves
**HTTP/2 cleartext (h2c)** — the upstream chart sets
`appProtocol: kubernetes.io/h2c` on the Service, so a Gateway that honours
`appProtocol` (Cilium does) proxies the gRPC/Connect API correctly over a
single route.

## TLS / external URL

TLS terminates at the Gateway. ZITADEL itself runs plaintext h2c inside the
cluster, but must still be told it is publicly reached over HTTPS:

- `zitadel.externalSecure: true`
- `zitadel.externalPort: 443`
- `TLS.Enabled: false` (set automatically by this chart)

Getting `externalDomain` / `externalSecure` wrong produces a login loop —
ZITADEL issues tokens for the wrong origin.

## Backups

All ZITADEL state lives in PostgreSQL, and the masterkey decrypts secrets
*inside* it — both must be preserved together:

- **PostgreSQL PVC** — the data itself. Include the `zitadel` namespace in the
  [`infra/velero`](../../infra/velero/) backup scope so the StatefulSet's PVC
  is captured.
- **masterkey** — keep it in Vault. Losing it leaves the PostgreSQL data as
  unrecoverable ciphertext; it must also never change after the first deploy.

The bundled PostgreSQL is single-instance (`architecture: standalone`) — fine
for a homelab IdP, but not highly available.

## Consumer usage

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: zitadel
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: apps/zitadel/install
    helm:
      values: |
        project: my-cluster
        destination:
          server: https://<cluster-api>:6443
          namespace: zitadel
        chartVersion: 10.0.1
        zitadel:
          externalDomain: zitadel.my-cluster.example.com
          masterkeySecretName: zitadel-masterkey
        postgresql:
          enabled: true
          storageClass: nfs4-csi
          auth:
            # Provide via ArgoCD Vault Plugin / SOPS — never inline a literal
            password: <path:vault/data/zitadel#pg-password>
            postgresPassword: <path:vault/data/zitadel#pg-admin-password>
        httpRoute:
          enabled: true
          hostname: zitadel.my-cluster.example.com
          gateway:
            name: cilium-gateway
            namespace: default
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

The masterkey Secret (`zitadel-masterkey`) must exist before the `zitadel`
Application syncs — either provision it out-of-band, or set
`secretsApp.enabled: true` (dev only) so the sub-App creates it at sync-wave -10.

## Values reference

See `install/values.yaml` for defaults and `install/values.schema.json` for the
full JSON Schema.

| Key | Default | Purpose |
|---|---|---|
| `project` | `default` | AppProject for all rendered Applications |
| `destination.server` | `https://kubernetes.default.svc` | Target cluster API |
| `destination.namespace` | `zitadel` | Namespace for ZITADEL |
| `chartVersion` | `10.0.1` | Upstream ZITADEL chart version |
| `replicas` | `1` | ZITADEL pod replicas |
| `image.{repository,tag,pullPolicy}` | `ghcr.io/zitadel/zitadel` / `v4.14.0` / `IfNotPresent` | Container image (track the chart's appVersion) |
| `zitadel.externalDomain` | `zitadel.example.com` | Public FQDN — must equal `httpRoute.hostname` |
| `zitadel.externalPort` | `443` | Public port |
| `zitadel.externalSecure` | `true` | ZITADEL is reached over HTTPS |
| `zitadel.masterkeySecretName` | `zitadel-masterkey` | Secret holding the 32-byte masterkey (key `masterkey`) |
| `postgresql.enabled` | `true` | Deploy the bundled Bitnami PostgreSQL |
| `postgresql.storageClass` | `nfs4-csi` | StorageClass for the PostgreSQL PVC |
| `postgresql.storageSize` | `8Gi` | PostgreSQL PVC size |
| `postgresql.auth.{database,username,password,postgresPassword}` | `zitadel` / `zitadel` / `""` / `""` | Bundled PostgreSQL credentials (set passwords via secret overlay) |
| `secretsApp.enabled` | `false` | Render the `zitadel-secrets` sub-App (DEV ONLY) |
| `secretsApp.masterkey` | `""` | 32-char masterkey, inlined when `secretsApp.enabled: true` |
| `httpRoute.enabled` | `true` | Render the HTTPRoute sub-App |
| `httpRoute.hostname` | `zitadel.example.com` | FQDN on the HTTPRoute |
| `httpRoute.gateway.{name,namespace}` | `cilium-gateway` / `default` | Cross-namespace Gateway target |
| `extraValues` | `{}` | Deep-merged on top of the computed upstream `valuesObject` |
| `catalog.repoURL` / `targetRevision` | this repo / `HEAD` | Where the secrets + httpRoute Applications fetch manifests from |
| `syncPolicy` | automated + retry | Applied to all rendered Applications |

## Related

- Backstage preview-auth spike: [`sthings-backstage#82`](https://github.com/stuttgart-things/sthings-backstage/issues/82)
- Upstream chart: <https://github.com/zitadel/zitadel-charts>
- ZITADEL configuration reference: <https://zitadel.com/docs/self-hosting/manage/configure>
