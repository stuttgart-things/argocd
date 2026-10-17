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
│       ├── postgresql.yaml       renders Application "infisical-postgresql"       (sync-wave -5, ESO mode + postgresql.enabled)
│       ├── redis.yaml            renders Application "infisical-redis"            (sync-wave -5, ESO mode + redis.enabled)
│       └── httproute.yaml        renders Application "infisical-httproute"        (sync-wave 10, gated by httpRoute.enabled)
├── external-secrets/             ESO ExternalSecret — root keys + DB/Redis credentials from Vault (production path)
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
- `postgresql.*` / `redis.*` — bundled Bitnami PostgreSQL and Redis (standalone), with StorageClass and size.
  In ESO mode both sub-charts are **off** here and run as their own Applications (below).
- `.Values.extraValues` — deep-merged on top as an escape hatch

### `infisical-external-secrets` Application (opt-in, `externalSecrets.enabled: true`, sync-wave -10)
The **production path** — no credential in values or git. Renders an `ExternalSecret` that materialises the
Secret named by `infisical.secretName` from these store properties:

| Property | When |
|---|---|
| `ENCRYPTION_KEY` (`openssl rand -hex 16`), `AUTH_SECRET` (`openssl rand -base64 32`) | always |
| `DB_PASSWORD` | `postgresql.enabled: true` |
| `DB_CONNECTION_URI` | `postgresql.enabled: false` (external database, taken as-is) |
| `REDIS_PASSWORD` | `redis.enabled: true` |
| `REDIS_URL` | `redis.enabled: false` (external Redis, taken as-is) |

With the bundled databases, ESO templates `DB_CONNECTION_URI` and `REDIS_URL` into the same Secret from the
passwords (`target.template`, `mergePolicy: Merge`), so each password lives in the store exactly once. Keep them
alphanumeric — they land in a URL.

```bash
vault kv put <mount>/infisical \
  ENCRYPTION_KEY=$(openssl rand -hex 16) AUTH_SECRET=$(openssl rand -base64 32) \
  DB_PASSWORD=$(openssl rand -hex 24) REDIS_PASSWORD=$(openssl rand -hex 24)
```

### `infisical-postgresql` / `infisical-redis` Applications (ESO mode, sync-wave -5)
Why they exist: the upstream chart builds `DB_CONNECTION_URI` / `REDIS_URL` from `values` whenever its bundled
sub-charts are on, and an explicit `env` entry wins over `envFrom` — a password in a Secret could never reach
Infisical. So in ESO mode those sub-charts are switched off, and the same Bitnami charts
(`registry-1.docker.io/bitnamicharts/{postgresql,redis}` at `postgresql.chartVersion` / `redis.chartVersion`, the
versions upstream pins, `mirror.gcr.io/bitnamilegacy` images) run as their own Applications with the same
names (`postgresql`, `redis-master`), reading `DB_PASSWORD` / `REDIS_PASSWORD` via `existingSecret`. Infisical
gets both URLs through `envFrom`.

### `infisical-secrets` Application (opt-in, `secretsApp.enabled: true`, sync-wave -10)
Dev-only alternative: inlines `secretsApp.encryptionKey` / `secretsApp.authSecret` in git. Enable **either**
`externalSecrets` **or** `secretsApp`, not both.

### `infisical-httproute` Application (opt-in, `httpRoute.enabled: true`, sync-wave 10)
Renders an `HTTPRoute` for `httpRoute.hostname` to the `infisical` Service on port 8080.

## Database and Redis passwords without ESO

Without `externalSecrets`, the upstream sub-charts run and build both URLs from `postgresql.auth.password` and
`redis.auth.password` **in values**. Set both (alphanumeric) and inject them via ArgoCD Vault Plugin / SOPS — never
commit a literal. Prefer the ESO mode above.

Switching an existing install between the two modes keeps the Service names, but the PVCs belong to different
Helm releases — treat it as a migration (backup and restore), not a toggle.

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
        redis:
          storageClass: nfs4-csi
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
| `postgresql.chartVersion` | `14.1.10` | `bitnamicharts/postgresql` version (ESO mode) |
| `postgresql.{storageClass,storageSize}` | `nfs4-csi` / `8Gi` | PostgreSQL PVC |
| `postgresql.auth.{database,username,password}` | `infisicalDB` / `infisical` / `""` | PostgreSQL credentials (password: non-ESO only, then required) |
| `redis.enabled` | `true` | Deploy the bundled Bitnami Redis |
| `redis.chartVersion` | `18.14.1` | `bitnamicharts/redis` version (ESO mode) |
| `redis.{storageClass,storageSize}` | `nfs4-csi` / `2Gi` | Redis PVC |
| `redis.auth.password` | `""` | Redis password (non-ESO only, then required) |
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
