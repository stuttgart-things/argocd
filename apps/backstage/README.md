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

If Backstage needs to call internal services over HTTPS with certificates issued by a private CA, mount the trust-manager `cluster-trust-bundle` and set `NODE_EXTRA_CA_CERTS`. Pass the override via `extraValues`:

```yaml
extraValues:
  backstage:
    extraVolumes:
      - name: trust-bundle
        configMap:
          name: cluster-trust-bundle
          optional: true
    extraVolumeMounts:
      - name: trust-bundle
        mountPath: /etc/ssl/custom/trust-bundle.pem
        subPath: trust-bundle.pem
        readOnly: true
    extraEnvVars:
      - name: NODE_EXTRA_CA_CERTS
        value: /etc/ssl/custom/trust-bundle.pem
```

This requires `infra/trust-manager/install` + a `Bundle` populating `cluster-trust-bundle` on the workload cluster.

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
