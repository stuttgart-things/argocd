# infra/oauth2-proxy

[oauth2-proxy](https://oauth2-proxy.github.io/oauth2-proxy/) in front of apps that have no login of their own, so their UI is only reachable after an OIDC (ZITADEL) login ([stuttgart-things#5023](https://github.com/stuttgart-things/stuttgart-things/issues/5023)). Packaged as an **app-of-apps Helm chart**: consumers create one ArgoCD `Application` pointing at `infra/oauth2-proxy/install` and list the apps to protect under `instances`.

Port of [`stuttgart-things/flux` — `infra/oauth2-proxy`](https://github.com/stuttgart-things/flux/tree/main/infra/oauth2-proxy), which protects Prometheus and Alertmanager on `platform-sthings`. Each instance renders the same proxy as the flux release.

## Layout

```
infra/oauth2-proxy/
├── install/                  app-of-apps Helm chart (what consumers point at)
│   └── templates/
│       ├── secrets.yaml      Application "oauth2-proxy-secrets-<hash>"  (sync-wave -5, gated by externalSecrets.enabled)
│       └── oauth2-proxy.yaml Application "<instance>-<hash>" per instance (sync-wave 0)
└── secrets/                  ExternalSecret for the shared client, one per instance namespace
```

## What gets deployed

### `<instance.name>-<hash>` Application (one per entry in `instances`)

The upstream `oauth2-proxy` chart (`chartVersion`), release name `instance.name`, in `instance.namespace` (or `destination.namespace`):

- **OIDC against `issuer`** (code flow with PKCE, `scope`), client and cookie secret from the Secret `secretName`, the issuer's CA from `caConfigMap`/`caKey` (`--provider-ca-file`)
- **`instance.upstream`** behind it. Every user who gets a token is let through (`emailDomains: ["*"]`)
- **Gateway API `HTTPRoute`** `instance.name` for `instance.hostname` on `gateway`, to the proxy's Service. The redirect URI is `https://<hostname>/oauth2/callback`
- **Cookie `cookieName` for `cookieDomain`**, the same everywhere. One login opens every protected app of the cluster

`extraValues` is deep-merged into every instance (lists are replaced, not merged).

### `oauth2-proxy-secrets-<hash>` Application (opt-in, `externalSecrets.enabled: true`)

One `ExternalSecret` `secretName` per distinct instance namespace, all from one entry (`externalSecrets.remoteKey`):

| Key | From property |
|---|---|
| `client-id` | `clientIdProperty` (`oauth2-proxy-client-id`) |
| `client-secret` | `clientSecretProperty` (`oauth2-proxy-client-secret`) |
| `cookie-secret` | `cookieSecretProperty` (`oauth2-proxy-cookie-secret`) — 32 random bytes, e.g. `openssl rand -base64 32 \| head -c 32 \| base64` |

Without ESO, create the Secret with these keys in every instance namespace yourself.

## Client model: one ZITADEL client per cluster

All proxies of a cluster share ONE confidential ZITADEL client (web app, code flow with PKCE). Each instance adds its redirect URI `https://<hostname>/oauth2/callback` to it. On LabUL the client is `oauth2-proxy-<cluster>` from `kubernetes_oauth2_proxies` in the `zitadel-portal-config` Terraform root.

**Who may log in is decided by ZITADEL**: the client sits in a project with "check for project role on authentication", so only users with a role on that project get a token. oauth2-proxy has no group check here: its groups claim must be a list, and ZITADEL's roles claim is a map.

Why one proxy per app and not one Gateway-level auth for all: the Gateway API `ExternalAuth` filter needs Cilium >= 1.20 and the experimental Gateway API CRDs.

## Examples

### Prometheus and Alertmanager of kube-prometheus-stack

```yaml
issuer: https://zitadel.infra.sthings-vsphere.labul.sva.de
cookieDomain: .platform.sthings-vsphere.labul.sva.de
instances:
  - name: prometheus-oauth2-proxy
    namespace: monitoring
    hostname: prometheus.platform.sthings-vsphere.labul.sva.de
    upstream: http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090
  - name: alertmanager-oauth2-proxy
    namespace: monitoring
    hostname: alertmanager.platform.sthings-vsphere.labul.sva.de
    upstream: http://kube-prometheus-stack-alertmanager.monitoring.svc.cluster.local:9093
externalSecrets:
  enabled: true
  secretStore:
    kind: ClusterSecretStore
    name: vault-cluster
  remoteKey: oauth2-proxy
```

### Longhorn

The Longhorn UI has no authentication. Keep the Longhorn chart's own route off (`httpRoute.enabled: false`, or no `storage-platform/longhorn-ui-route` label in `platforms/storage`) and add:

```yaml
instances:
  - name: longhorn-oauth2-proxy
    namespace: longhorn-system
    hostname: longhorn.<cluster>.<zone>
    upstream: http://longhorn-frontend.longhorn-system.svc.cluster.local:80
```

The proxy needs the Secret `secretName` in `longhorn-system` (with `externalSecrets.enabled` it gets one), and the ZITADEL client needs the redirect URI `https://longhorn.<cluster>.<zone>/oauth2/callback`.

## Values

| Value | Default | |
|---|---|---|
| `issuer` | `""` | ZITADEL issuer, as in the discovery document. Required with instances |
| `cookieDomain` | `""` | with the leading dot; every hostname under it. Required with instances |
| `cookieName` | `_oauth2_proxy` | |
| `secretName` | `oauth2-proxy` | Secret with `client-id`, `client-secret`, `cookie-secret` |
| `scope` | `openid profile email` | |
| `caConfigMap` / `caKey` | `cluster-trust-bundle` / `trust-bundle.pem` | the issuer's CA |
| `gateway.name` / `.namespace` | `cilium-gateway` / `default` | |
| `instances[]` | `[]` | `name`, `namespace` (empty = `destination.namespace`), `hostname`, `upstream` |
| `externalSecrets.*` | off | see above |
| `chartVersion` | `10.7.4` | upstream chart |

## Adding an app

Add an entry to `instances` with the app's in-cluster URL (`http://<svc>.<ns>.svc.cluster.local:<port>`), add its redirect URI to the ZITADEL client, and drop any HTTPRoute the app already has for that hostname: the proxy's route takes it.
