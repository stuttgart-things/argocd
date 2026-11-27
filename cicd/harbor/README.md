# cicd/harbor

Harbor from the **official goharbor chart** (`helm.goharbor.io`), as an opt-in
cicd platform (`platforms/cicd/appset-harbor.yaml`, gate `cicd-platform/harbor`).
Not the Bitnami chart in `apps/harbor`: its images are frozen under
`docker.io/bitnamilegacy` and receive no updates.

| Application | Source | Renders |
|---|---|---|
| `<app>-secrets` | `cicd/externalsecrets` | 7 ExternalSecrets `harbor-eso-*` (wave -5); the registry credentials one builds `REGISTRY_HTPASSWD` (bcrypt) from the fetched password with an ESO template |
| `<app>-token-cert` | `cicd/harbor/token-cert` | self-signed Issuer + Certificate → `harbor-core-token-cert` (token signing key, RSA 4096 PKCS#1; needs cert-manager) |
| `<app>` | `helm.goharbor.io/harbor` | Harbor, internal PostgreSQL + Redis, Trivy, HTTPRoute on `hostname` via `gateway` (TLS terminates at the Gateway) |

## Why every secret comes from ESO

Argo CD renders with `helm template`. The chart's `lookup` of the live Secret
returns nothing there, so on every render it would mint a new core secret,
XSRF key, token CA and htpasswd salt: the Application stays OutOfSync and the
pods restart on every sync. With all of them supplied as existing Secrets the
render is deterministic (verified: two renders, byte-identical).

## The KV entry

One entry (`secrets.vaultSecretName`, default `harbor`) in the store
`secrets.clusterSecretStoreName`. **Every property is a random string**, so an
AppSecretProfile can generate the whole entry:

| property | length |
|---|---|
| `admin_password` | any |
| `secret_key` | 16 |
| `core_secret` | 16 |
| `xsrf_key` | 32 |
| `jobservice_secret` | 16 |
| `registry_http_secret` | 16 |
| `registry_password` | any |

The two values that are NOT random strings are derived instead: the registry
htpasswd line by ESO (`{{ htpasswd "harbor_registry_user" .registry_password "bcrypt" }}`,
verified on ESO v2.12 — the line changes salt on each refresh, every one of
them verifies the same password), the token key pair by cert-manager.

The internal database keeps the chart's default password: it is reachable only
inside the namespace's ClusterIP Service.

## Login via ZITADEL (`oidc.*`)

Port of flux's `harbor-oidc` (stuttgart-things#5023). Harbor takes OIDC from its configuration, which the core reads from `CONFIG_OVERWRITE_JSON` at every start. Both values name Secrets the cluster supplies in the Harbor namespace, so the client secret never enters the Application:

| Value | Secret key | |
|---|---|---|
| `oidc.overridesSecret` | `overrides.json` | `auth_mode: oidc_auth` and the `oidc_*` settings → `core.extraEnvVars` `CONFIG_OVERWRITE_JSON` |
| `oidc.caBundleSecret` | `ca.crt` | the issuer's CA → `caBundleSecretName` (trust store of core, jobservice, registry, trivy), e.g. a trust-manager `Bundle` with a Secret target |

```json
{
  "auth_mode": "oidc_auth",
  "oidc_name": "ZITADEL",
  "oidc_endpoint": "https://zitadel.example",
  "oidc_client_id": "<client id>",
  "oidc_client_secret": "<client secret>",
  "oidc_scope": "openid,profile,email,offline_access",
  "oidc_verify_cert": true,
  "oidc_auto_onboard": true,
  "oidc_user_claim": "preferred_username",
  "oidc_groups_claim": "harbor_groups",
  "oidc_admin_group": "harbor-admin"
}
```

- the groups claim must be a **list**; ZITADEL's roles claim is a map, so the stuttgart-things zitadel-config roots add `harbor_groups` with an action (`harbor-admin` → system admin, `harbor-user` → login only)
- `offline_access` and a refresh token grant on the client keep the CLI secret (`docker login`) valid past the ID token's lifetime
- redirect URI: `https://<hostname>/c/oidc/callback`
- switching `auth_mode` works only while Harbor has **no local users** besides `admin`; the admin stays as emergency access
