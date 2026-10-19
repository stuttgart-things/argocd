# cicd/harbor

Harbor from the **official goharbor chart** (`helm.goharbor.io`), as an opt-in
cicd platform (`platforms/cicd/appset-harbor.yaml`, gate `cicd-platform/harbor`).
Not the Bitnami chart in `apps/harbor`: its images are frozen under
`docker.io/bitnamilegacy` and receive no updates.

| Application | Source | Renders |
|---|---|---|
| `<app>-secrets` | `cicd/externalsecrets` | 8 ExternalSecrets `harbor-eso-*` (wave -5) |
| `<app>` | `helm.goharbor.io/harbor` | Harbor, internal PostgreSQL + Redis, Trivy, HTTPRoute on `hostname` via `gateway` (TLS terminates at the Gateway) |

## Why every secret comes from ESO

Argo CD renders with `helm template`. The chart's `lookup` of the live Secret
returns nothing there, so on every render it would mint a new core secret,
XSRF key, token CA and htpasswd salt: the Application stays OutOfSync and the
pods restart on every sync. With all of them supplied as existing Secrets the
render is deterministic (verified: two renders, byte-identical).

## The KV entry

One entry (`secrets.vaultSecretName`, default `harbor`) in the store
`secrets.clusterSecretStoreName`:

| property | content |
|---|---|
| `admin_password` | initial admin password |
| `secret_key` | 16 characters |
| `core_secret` | 16 characters |
| `xsrf_key` | 32 characters |
| `jobservice_secret` | 16 characters |
| `registry_http_secret` | 16 characters |
| `registry_password` | password of `harbor_registry_user` |
| `registry_htpasswd` | `harbor_registry_user:<bcrypt>` of that password |
| `token_key`, `token_crt` | RSA key + self-signed cert for token signing |

Generate once (values never printed, written straight to a JSON file for your
KV tooling):

```bash
r() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "$1"; }
pw=$(r 24); openssl req -x509 -newkey rsa:4096 -nodes -days 3650 \
  -subj /CN=harbor-token-ca -keyout token.key -out token.crt 2>/dev/null
jq -n --arg admin "$(r 20)" --arg sk "$(r 16)" --arg cs "$(r 16)" --arg xs "$(r 32)" \
  --arg js "$(r 16)" --arg rh "$(r 16)" --arg rp "$pw" \
  --arg ht "$(htpasswd -nbB harbor_registry_user "$pw" | tr -d '\n')" \
  --rawfile tk token.key --rawfile tc token.crt \
  '{admin_password:$admin, secret_key:$sk, core_secret:$cs, xsrf_key:$xs,
    jobservice_secret:$js, registry_http_secret:$rh, registry_password:$rp,
    registry_htpasswd:$ht, token_key:$tk, token_crt:$tc}' > harbor-kv.json
rm token.key token.crt
```

The internal database keeps the chart's default password: it is reachable only
inside the namespace's ClusterIP Service.
