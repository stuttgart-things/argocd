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
