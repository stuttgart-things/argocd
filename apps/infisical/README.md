# apps/infisical

Catalog entry for [Infisical](https://infisical.com/docs/self-hosting/helm-charts/overview) — an open-source
secrets management platform. Packaged as an **app-of-apps Helm chart** over the upstream `infisical-standalone`
chart (`https://dl.cloudsmith.io/public/infisical/helm-charts/helm/charts/`): consumers create one ArgoCD
`Application` pointing at `apps/infisical/install`, pass overrides via `helm.values`, and the chart renders child
`Application`s for Infisical itself (plus its bundled PostgreSQL and Redis), opt-in root-key provisioning
(ExternalSecrets, or a dev-only inline Secret), and a Gateway API HTTPRoute.

Mirrors the structure of [`apps/zitadel`](../zitadel/).

## Layout

```
apps/infisical/
├── install/                      app-of-apps Helm chart (what consumers point at)
│   └── templates/
│       ├── chart.yaml            renders Application "infisical"                  (sync-wave 0)
│       ├── external-secrets.yaml renders Application "infisical-external-secrets" (sync-wave -10, gated by externalSecrets.enabled)
│       ├── secrets.yaml          renders Application "infisical-secrets"          (sync-wave -10, gated by secretsApp.enabled — DEV ONLY)
│       └── httproute.yaml        renders Application "infisical-httproute"        (sync-wave 10, gated by httpRoute.enabled)
├── external-secrets/             ESO ExternalSecret — ENCRYPTION_KEY + AUTH_SECRET from Vault (production path)
├── secrets/                      ENCRYPTION_KEY + AUTH_SECRET Secret (dev-only path)
└── httproute/                    Gateway API HTTPRoute
```

## What gets deployed

### `infisical` Application (always)
Upstream chart `infisical-standalone` at `targetRevision: .Values.chartVersion`, release name `infisical`.
Computed `valuesObject`:

- `infisical.fullnameOverride: infisical` — the Service is `infisical:8080` (without it the chart names it
  `infisical-infisical-standalone-infisical`)
- `infisical.kubeSecretRef` — the Secret named by `infisical.secretName`, read via `envFrom`; it must carry
  `ENCRYPTION_KEY` and `AUTH_SECRET`
- `infisical.extraEnv` — `SITE_URL`, from `infisical.siteUrl` or `https://<httpRoute.hostname>`
- `ingress.enabled: false` and `ingress.nginx.enabled: false` — no Ingress, no bundled ingress-nginx; the HTTPRoute
  is the ingress path
- `postgresql.*` / `redis.*` — bundled Bitnami PostgreSQL and Redis (standalone), with StorageClass and size
- `.Values.extraValues` — deep-merged on top as an escape hatch

### `infisical-external-secrets` Application (opt-in, `externalSecrets.enabled: true`, sync-wave -10)
The **production path for the root keys**. Renders an `ExternalSecret` that materialises the Secret named by
`infisical.secretName` with `ENCRYPTION_KEY` and `AUTH_SECRET` from the referenced store
(`vault kv put <mount>/infisical ENCRYPTION_KEY=$(openssl rand -hex 16) AUTH_SECRET=$(openssl rand -base64 32)`).

### `infisical-secrets` Application (opt-in, `secretsApp.enabled: true`, sync-wave -10)
Dev-only alternative: inlines `secretsApp.encryptionKey` / `secretsApp.authSecret` in git. Enable **either**
`externalSecrets` **or** `secretsApp`, not both.

### `infisical-httproute` Application (opt-in, `httpRoute.enabled: true`, sync-wave 10)
Renders an `HTTPRoute` for `httpRoute.hostname` to the `infisical` Service on port 8080.

## Database and Redis passwords

The upstream chart builds `DB_CONNECTION_URI` and `REDIS_URL` from `postgresql.auth.password` and
`redis.auth.password` **in values** — it cannot read them from a Secret while the bundled PostgreSQL / Redis are
enabled. Both must be set (alphanumeric — they land in a URL); inject them via ArgoCD Vault Plugin / SOPS, never
commit a literal. For an external database, set `postgresql.enabled: false` and use
`extraValues.postgresql.useExistingPostgresSecret`.

## Backups

All state lives in PostgreSQL, encrypted with `ENCRYPTION_KEY` — preserve both together. Losing or changing the
key leaves the data unreadable.

## Consumer usage

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: infisical
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: apps/infisical/install
    helm:
      values: |
        project: my-cluster
        destination:
          server: https://<cluster-api>:6443
          namespace: infisical
        postgresql:
          storageClass: nfs4-csi
          auth:
            password: <alnum>
        redis:
          storageClass: nfs4-csi
          auth:
            password: <alnum>
        externalSecrets:
          enabled: true
          store:
            name: vault-backend
            kind: ClusterSecretStore
          secretPath: infisical
        httpRoute:
          enabled: true
          hostname: infisical.my-cluster.example.com
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

The first user to sign up becomes the instance admin.

## Values reference

See `install/values.yaml` for defaults and `install/values.schema.json` for the full JSON Schema.

| Key | Default | Purpose |
|---|---|---|
| `project` | `default` | AppProject for all rendered Applications |
| `destination.server` | `https://kubernetes.default.svc` | Target cluster API |
| `destination.namespace` | `infisical` | Namespace for Infisical |
| `chartVersion` | `1.11.0` | Upstream `infisical-standalone` chart version |
| `replicas` | `2` | Infisical pod replicas |
| `image.{repository,tag,pullPolicy}` | `infisical/infisical` / `v0.158.0` / `IfNotPresent` | Container image |
| `infisical.siteUrl` | `""` | Public URL; empty → `https://<httpRoute.hostname>` |
| `infisical.secretName` | `infisical-secrets` | Secret with `ENCRYPTION_KEY` + `AUTH_SECRET` (envFrom) |
| `postgresql.enabled` | `true` | Deploy the bundled Bitnami PostgreSQL |
| `postgresql.{storageClass,storageSize}` | `nfs4-csi` / `8Gi` | PostgreSQL PVC |
| `postgresql.auth.{database,username,password}` | `infisicalDB` / `infisical` / `""` | PostgreSQL credentials (password required) |
| `redis.enabled` | `true` | Deploy the bundled Bitnami Redis |
| `redis.{storageClass,storageSize}` | `nfs4-csi` / `2Gi` | Redis PVC |
| `redis.auth.password` | `""` | Redis password (required) |
| `externalSecrets.enabled` | `false` | Render the `infisical-external-secrets` sub-App (production path) |
| `externalSecrets.store.{name,kind}` | `vault-backend` / `ClusterSecretStore` | ESO store |
| `externalSecrets.secretPath` | `infisical` | Entry path under the store's KV mount |
| `externalSecrets.refreshInterval` | `1h` | ESO refresh interval |
| `secretsApp.enabled` | `false` | Render the `infisical-secrets` sub-App (DEV ONLY) |
| `secretsApp.{encryptionKey,authSecret}` | `""` | Root keys, inlined when `secretsApp.enabled: true` |
| `httpRoute.enabled` | `true` | Render the HTTPRoute sub-App |
| `httpRoute.hostname` | `infisical.example.com` | FQDN on the HTTPRoute |
| `httpRoute.gateway.{name,namespace}` | `cilium-gateway` / `default` | Cross-namespace Gateway target |
| `extraValues` | `{}` | Deep-merged on top of the computed upstream `valuesObject` |
| `catalog.repoURL` / `targetRevision` | this repo / `HEAD` | Where the sub-Applications fetch manifests from |
| `syncPolicy` | automated + retry | Applied to all rendered Applications |

## Related

- Upstream chart: <https://github.com/Infisical/infisical/tree/main/helm-charts/infisical-standalone-postgres>
- Self-hosting docs: <https://infisical.com/docs/self-hosting/helm-charts/overview>
