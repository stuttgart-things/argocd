# apps/backstage

Catalog entry for [Backstage](https://backstage.io) — Spotify's developer portal. Packaged as an **app-of-apps Helm chart** over the upstream `oci://ghcr.io/backstage/charts/backstage` chart: consumers create one ArgoCD `Application` pointing at `apps/backstage/install`, pass overrides via `helm.values`, and the chart renders child `Application`s for Backstage itself plus opt-in app-config ConfigMap, runtime-secrets Secret (dev-only), and Gateway API HTTPRoute + ReferenceGrant.

Port of [`stuttgart-things/flux` — `apps/backstage`](https://github.com/stuttgart-things/flux/tree/main/apps/backstage). The flux version's three HelmReleases (`backstage-configuration`, `backstage-deployment`, `backstage-httproute`) collapse onto sibling sub-charts here.

## Layout

```
apps/backstage/
├── install/                        app-of-apps Helm chart (what consumers point at)
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── values.schema.json
│   └── templates/
│       ├── chart.yaml              renders Application "backstage"            (sync-wave 0)
│       ├── config.yaml             renders Application "backstage-config"     (sync-wave -10, gated by config.enabled)
│       ├── secrets.yaml            renders Application "backstage-secrets"    (sync-wave -10, gated by secretsApp.enabled — DEV ONLY)
│       └── httproute.yaml          renders Application "backstage-httproute"  (sync-wave 10, gated by httpRoute.enabled)
├── config/                         backstage-app-config ConfigMap (app-config.extra.yaml)
├── secrets/                        backstage-secrets Secret (dev-only path; production: ExternalSecrets)
└── httproute/                      Gateway API HTTPRoute + ReferenceGrant
```

## What gets deployed

### `backstage` Application (always)
Argo CD source on `oci://ghcr.io/backstage/charts` at `chart: backstage`, `targetRevision: .Values.chartVersion`. Computed `valuesObject`:

- `global.storageClass` — for the bundled PostgreSQL PVC
- `ingress.enabled: false` — Gateway API HTTPRoute is the path here
- `postgresql.{enabled,auth.{username,password},architecture}` — bundled PostgreSQL StatefulSet (set `postgresql.password` via Argo Vault Plugin / SOPS overlay or override per-cluster)
- `backstage.replicas` + `backstage.image.{registry,repository,tag}` — pod count + image
- `backstage.extraEnvVars` — 13 env vars all sourced via `secretKeyRef` from `.Values.secretName` (default `backstage-secrets`): `APP_TITLE`, `ORGANIZATION_NAME`, `APP_BASE_URL`, `BACKEND_BASE_URL`, `CORS_ORIGIN`, `CLAIM_MACHINERY_API_URL`, `CLAIM_MACHINERY_REGISTRY_URL`, `AUTH_ENVIRONMENT`, `GITHUB_TOKEN`, `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`, `BACKEND_SECRET`, `EXTERNAL_ACCESS_TOKEN`
- `backstage.extraAppConfig` — two `configMapRef`s pulling `.Values.appConfig.extraConfigMap` (`backstage-app-config`, owned by the config sub-App) and `.Values.appConfig.catalogConfigMap` (`backstage-catalog-config`, **must be provisioned out-of-band** — per-cluster catalog locations)
- `.Values.extraValues` — deep-merged on top as an escape hatch (use this for the `NODE_EXTRA_CA_CERTS` + trust-bundle pattern documented in the flux README)

### `backstage-config` Application (opt-in, `config.enabled: true`, sync-wave -10)
Provisions the `backstage-app-config` ConfigMap with the long `app-config.extra.yaml` (GitHub integration, auth providers, proxy endpoints to claim-machinery, catalog rules, kubernetes plugin config). All `${VAR}` placeholders are resolved at runtime by Backstage from the env vars injected by the `extraEnvVars` block above.

### `backstage-secrets` Application (opt-in, `secretsApp.enabled: true`, sync-wave -10)
Inlines the `backstage-secrets` Secret with all 13 env-var values + GitHub OAuth credentials + backend signing key. **Inlining literal secrets in git is dev-only.** For real deployments, leave `secretsApp.enabled: false` and provision the Secret out-of-band via:

- ArgoCD Vault Plugin
- ExternalSecrets Operator
- SOPS overlay
- Sealed Secrets

The Deployment always references `secretKeyRef.name: <secretName>` regardless — the sub-App is just the dev-time provisioner.

### `backstage-httproute` Application (opt-in, `httpRoute.enabled: true`, sync-wave 10)
Renders both:
1. A `ReferenceGrant` allowing the cross-namespace Gateway in `.Values.httpRoute.gateway.namespace` to target Services in this namespace
2. An `HTTPRoute` to `backstage-deployment:7007`

## `backstage-catalog-config` ConfigMap (NOT provisioned by this chart)

The chart references `backstage-catalog-config` in `extraAppConfig` but does **not** provision it — catalog locations are environment-specific and should live in the cluster config, not this generic catalog entry. Example:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: backstage-catalog-config
  namespace: portal
data:
  app-config.catalog.yaml: |
    catalog:
      locations:
        - type: url
          target: https://github.com/your-org/backstage-resources/blob/main/org/<env>/org.yaml
          rules:
            - allow: [User, Group]
        - type: url
          target: https://github.com/your-org/backstage-resources/blob/main/services/<env>/catalog-index.yaml
          rules:
            - allow: [Component, Location, System, API, Resource, Template]
```

The catalog must contain `User` entities whose `metadata.name` matches GitHub usernames, otherwise the `usernameMatchingUserEntityName` sign-in resolver will reject every login.

## Consumer usage

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: backstage
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: apps/backstage/install
    helm:
      values: |
        project: my-cluster
        destination:
          server: https://<cluster-api>:6443
          namespace: backstage
        chartVersion: 2.6.3
        image:
          registry: ghcr.io
          repository: stuttgart-things/sthings-backstage
          tag: "260218.1436"
        storageClass: nfs4-csi
        postgresql:
          enabled: true
          username: backstage
          # Provide the password via ArgoCD Vault Plugin / SOPS overlay — never inline a literal here
          password: <path:vault/data/backstage#postgresql>
          architecture: standalone
        config:
          enabled: true
        httpRoute:
          enabled: true
          hostname: backstage.my-cluster.example.com
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

## Internal CA trust (Vault PKI / private CA)

If Backstage calls internal services over HTTPS with certificates issued by a
private CA (e.g. ZITADEL behind the Vault PKI), set `trustBundle.configMap`:

```yaml
trustBundle:
  configMap: cluster-trust-bundle   # trust-manager's Bundle target
  key: trust-bundle.pem
```

The ConfigMap is mounted at `/etc/ssl/custom` and `NODE_EXTRA_CA_CERTS` points
at the key; Node **adds** it to its built-in roots once at start. Requires
`infra/trust-manager/install` + a `Bundle` populating the ConfigMap.

Do not set `extraEnvVars` through `extraValues` for this: `extraValues` is
merged with `mergeOverwrite`, which replaces lists, so it would drop every
env var this chart computes (`APP_TITLE`, `GITHUB_TOKEN`, ...).

## Sign-in: guest and ZITADEL (OIDC)

Same switches as flux's `BACKSTAGE_AUTH_GUEST_ENABLED` /
`BACKSTAGE_AUTH_OIDC_ENABLED` (sthings-backstage image >= `v1.23.0`):

```yaml
auth:
  guestEnabled: false        # no guest button; guest counts as a developer
  oidc:
    enabled: true
    clientId: "123456789012345678"   # keep quoted (digits only)
    projectId: ""                    # empty = the client's own project
trustBundle:
  configMap: cluster-trust-bundle    # ZITADEL's CA
```

- `auth.oidc.enabled` sets `AUTH_OIDC_ENABLED=true`, which loads the OIDC
  module, and the `backstage-config` sub-App renders the provider block
  (`auth.providers.oidc.development`, resolver `zitadelProjectRoles`,
  `offline_access` for refresh tokens).
- Client ID and project ID are written into app-config as quoted literals.
  Through env, a digits-only ZITADEL ID arrives as a float.
- `secretName` must carry `ZITADEL_ISSUER` and `ZITADEL_CLIENT_SECRET`.
- ZITADEL project roles decide the group: `backstage-platform` →
  platform-team, `backstage-developer` → guests, none → refused.
- Redirect URI of the client: `https://<httpRoute.hostname>/api/auth/oidc/handler/frame`.

## Values reference

See `install/values.yaml` for defaults and `install/values.schema.json` for the full JSON Schema.

| Key | Default | Purpose |
|---|---|---|
| `project` | `default` | AppProject for all rendered Applications |
| `destination.server` | `https://kubernetes.default.svc` | Target cluster API |
| `destination.namespace` | `portal` | Namespace for Backstage |
| `chartVersion` | `2.6.3` | Upstream backstage chart version |
| `image.{registry,repository,tag}` | `ghcr.io` / `stuttgart-things/sthings-backstage` / `latest` | Container image |
| `replicas` | `1` | Pod replicas |
| `storageClass` | `nfs4-csi` | `global.storageClass` for bundled PostgreSQL |
| `postgresql.{enabled,username,password,architecture}` | `true` / `backstage` / `""` / `standalone` | Bundled PostgreSQL config |
| `appConfig.extraConfigMap` | `backstage-app-config` | ConfigMap holding `app-config.extra.yaml` (provisioned by `config/` sub-App) |
| `appConfig.catalogConfigMap` | `backstage-catalog-config` | ConfigMap holding catalog locations (must be provisioned out-of-band) |
| `secretName` | `backstage-secrets` | Secret carrying all `extraEnvVars` (provisioned by `secrets/` sub-App when `secretsApp.enabled: true`) |
| `config.enabled` | `true` | Render the `backstage-config` sub-App |
| `auth.guestEnabled` | `true` | `AUTH_GUEST_ENABLED`; `false` = no guest sign-in |
| `auth.oidc.enabled` | `false` | ZITADEL sign-in (see above); needs `ZITADEL_ISSUER` / `ZITADEL_CLIENT_SECRET` in `secretName` |
| `auth.oidc.clientId` / `projectId` | `""` | ZITADEL IDs, quoted literals in app-config |
| `trustBundle.configMap` / `key` | `""` / `trust-bundle.pem` | Private CA for `NODE_EXTRA_CA_CERTS`; empty = off |
| `secretsApp.enabled` | `false` | Render the `backstage-secrets` sub-App (DEV ONLY) |
| `httpRoute.enabled` | `true` | Render the HTTPRoute + ReferenceGrant sub-App |
| `httpRoute.hostname` | `backstage.example.com` | FQDN on the HTTPRoute |
| `httpRoute.gateway.{name,namespace}` | `cilium-gateway` / `default` | Cross-namespace Gateway target |
| `extraValues` | `{}` | Deep-merged on top of the computed upstream `valuesObject` |
| `catalog.repoURL` / `targetRevision` | this repo / `HEAD` | Where the config + secrets + httpRoute Applications fetch manifests from |
| `syncPolicy` | automated + retry | Applied to all rendered Applications |

## GitHub OAuth App

The `usernameMatchingUserEntityName` sign-in resolver requires a GitHub OAuth App. Create one at **GitHub → Settings → Developer settings → OAuth Apps**:

| Field | Value |
|---|---|
| Application name | `Backstage <cluster-name>` |
| Homepage URL | `https://<httpRoute.hostname>` |
| Authorization callback URL | `https://<httpRoute.hostname>/api/auth/github/handler/frame` |

Inject Client ID + Client Secret via `secretsApp.github.{clientId,clientSecret}` (dev) or via your secret-management overlay (prod).

## Related

- Flux equivalent: [`stuttgart-things/flux` — `apps/backstage`](https://github.com/stuttgart-things/flux/tree/main/apps/backstage)
- Upstream chart: <https://github.com/backstage/charts/tree/main/charts/backstage>
- Trust bundle producer: [`infra/trust-manager`](../../infra/trust-manager/)
- API consumed by Backstage proxy: [`apps/claim-machinery-api`](../claim-machinery-api/)
