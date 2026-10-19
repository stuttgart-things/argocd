# cicd/zot

The [zot](https://zotregistry.dev) OCI registry from its official chart, as an
opt-in cicd platform (`platforms/cicd/appset-zot.yaml`, gate `cicd-platform/zot`).

| Application | Source | Renders |
|---|---|---|
| `<app>-secrets` | `cicd/externalsecrets` | ExternalSecret `zot-eso-htpasswd` (wave -5) |
| `<app>` | `zotregistry.dev/helm-charts/zot` | StatefulSet + PVC, config (dedupe, GC, search + UI), HTTPRoute on `hostname` via `gateway` |

Access: anonymous pull (`anonymousRead`, default on), push/update/delete for
every htpasswd user. The probes use `/livez`, so `anonymousRead: false` works too.

KV entry `secrets.vaultSecretName` (default `zot`), property `admin_password`:
a random string, so an AppSecretProfile can generate it. ESO builds the
htpasswd file from it (`{{ htpasswd "admin" .admin_password "bcrypt" }}`, the
same template verified for Harbor on ESO v2.12); log in as `admin`.
