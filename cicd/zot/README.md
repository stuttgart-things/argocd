# cicd/zot

The [zot](https://zotregistry.dev) OCI registry from its official chart, as an
opt-in cicd platform (`platforms/cicd/appset-zot.yaml`, gate `cicd-platform/zot`).

| Application | Source | Renders |
|---|---|---|
| `<app>-secrets` | `cicd/externalsecrets` | ExternalSecret `zot-eso-htpasswd` (wave -5) |
| `<app>` | `zotregistry.dev/helm-charts/zot` | StatefulSet + PVC, config (dedupe, GC, search + UI), HTTPRoute on `hostname` via `gateway` |

Access: anonymous pull (`anonymousRead`, default on), push/update/delete for
every htpasswd user. The probes use `/livez`, so `anonymousRead: false` works too.

KV entry `secrets.vaultSecretName` (default `zot`), property `htpasswd`: one
bcrypt line per user, e.g. `htpasswd -nbB ci "$PASSWORD"`.
