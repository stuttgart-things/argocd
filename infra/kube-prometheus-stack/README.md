# infra/kube-prometheus-stack

Catalog entry for [prometheus-community/kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) — the whole stack: Prometheus Operator and its CRDs, Prometheus, Alertmanager, Grafana with the bundled dashboards, node-exporter and kube-state-metrics, plus the chart's default alert rules. Packaged as an **app-of-apps Helm chart**: consumers create one ArgoCD `Application` pointing at `infra/kube-prometheus-stack/install`, and the chart renders up to three child `Application`s.

Port of [`stuttgart-things/flux` — `infra/kube-prometheus-stack`](https://github.com/stuttgart-things/flux/tree/main/infra/kube-prometheus-stack), which runs on `platform-sthings`. Same resource sizing, same scrape interval, same alert routing shape. Use `infra/prometheus` instead when a bare Prometheus without the operator is enough.

## Layout

```
infra/kube-prometheus-stack/
├── install/                        app-of-apps Helm chart (what consumers point at)
│   └── templates/
│       ├── secrets.yaml            Application "<name>-secrets"   (sync-wave -5, gated by externalSecrets.enabled)
│       ├── kube-prometheus-stack.yaml  Application "<name>"       (sync-wave 0)
│       └── httproute.yaml          Application "<name>-httproute" (sync-wave 10, gated by httpRoute.enabled)
├── secrets/                        ExternalSecrets for the Grafana admin and the webhook token
└── httproute/                      Gateway API HTTPRoute for Grafana
```

## What gets deployed

### `<name>` Application (always)

Installs `kube-prometheus-stack` `.Values.chartVersion` into `.Values.destination.namespace`, release name `kube-prometheus-stack`. Computed `valuesObject`:

- **CRDs and default rules on.** The curated rules are what Alertmanager fires on — `KubePodCrashLooping`, `KubePersistentVolumeFillingUp`, `TargetDown` and the rest
- **Prometheus:** one replica, `prometheus.scrapeInterval` as scrape and evaluation interval, `prometheus.retention` and `prometheus.retentionSize` (80% of the PVC unless set), a PVC of `prometheus.storageSize` (on `prometheus.storageClass`, or the cluster default when empty). Discovers `ServiceMonitor`, `PodMonitor`, `PrometheusRule` and `Probe` objects **in every namespace**, not only those carrying the release label — so an application ships its own monitor next to its Deployment
- **`clusterName`** set → every series and alert carries `cluster: <name>`
- **Control-plane scrape jobs off** (`controlPlane.*`). On k3s and RKE2 the controller manager, scheduler and etcd are not reachable as separate targets, and Cilium's kube-proxy replacement leaves no kube-proxy. Their default ServiceMonitors would only raise permanent `TargetDown` alerts. kubelet, cAdvisor and kube-apiserver are scraped regardless
- **Alertmanager:** one replica, no PVC (silences do not survive a restart). With `alertmanager.webhook.enabled`, `warning` and `critical` alerts go to the webhook with `send_resolved: true`; `info` and the always-firing `Watchdog` go to a `null` receiver. Critical inhibits warning/info, warning inhibits info, per namespace and alert name
- **Grafana:** bundled dashboards, dashboard folders by the ConfigMap annotation `grafana_folder` (sidecar `folderAnnotation`; without it → General), no PVC (dashboards are provisioned from ConfigMaps on every start; edits in the UI do not persist), no chart Ingress. `grafana.adminSecret` set → admin credentials from that Secret; `httpRoute.enabled` → `root_url` is the route's hostname; `grafana.oidc.issuer` set → login via ZITADEL (see below)

### `<name>-secrets` Application (opt-in, `externalSecrets.enabled: true`)

Up to three `ExternalSecret`s from one entry (`externalSecrets.remoteKey`) in an existing (Cluster)SecretStore:

| Target Secret | Keys | From property |
|---|---|---|
| `grafana.adminSecret` | `admin-user`, `admin-password` | `grafanaAdminUserProperty`, `grafanaAdminPasswordProperty` |
| `alertmanager.webhook.tokenSecret` | `token` | `webhookTokenProperty` (entry `webhookRemoteKey`, empty = `remoteKey`) |
| `grafana.oidc.secretName` | `GF_AUTH_GENERIC_OAUTH_CLIENT_ID`, `GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET` | `grafanaOidcClientIdProperty`, `grafanaOidcClientSecretProperty` (entry `grafanaOidcRemoteKey`, empty = `remoteKey`) |

Each is rendered only when its consumer is on. Sync-wave -5 puts them ahead of the stack.

### `<name>-httproute` Application (opt-in, `httpRoute.enabled: true`)

One `HTTPRoute` for Grafana (`kube-prometheus-stack-grafana:80`) on `httpRoute.gateway`. Prometheus and Alertmanager are not routed here: they have no login of their own, so route them through [`infra/oauth2-proxy`](../oauth2-proxy/) (its README has the example).

## The webhook, and why its secret is a file

The receiver is shaped for homerun2's omni-pitcher (`/pitch/grafana`, which accepts Alertmanager's webhook payload), the path that already carries `platform-sthings` alerts to Teams:

```
Alertmanager ─▶ omni-pitcher /pitch/grafana ─▶ Redis stream "alerts" ─▶ notification-catcher ─▶ Teams
```

The Bearer token is mounted from `tokenSecret` (`alertmanagerSpec.secrets`) and referenced as `credentials_file`, and the CA bundle is mounted from `caConfigMap` (`alertmanagerSpec.configMaps`) and referenced as `ca_file`. Neither value is ever part of the Alertmanager config Secret, the rendered Application, or Git. On a cluster outside the pitcher's own, the URL is its public HTTPS address, which chains to the internal CA — hence `cluster-trust-bundle`.

## Grafana login via ZITADEL (OIDC)

Off by default. `grafana.oidc.issuer` set (e.g. `https://zitadel.platform.sthings.lab`) → Grafana gets a "Sign in with `grafana.oidc.name`" button (generic OAuth, PKCE, `auto_login: false`), next to the local admin — never instead of it. Same settings as the flux-run clusters:

- Client ID and secret come as env (`envFromSecret`) from `grafana.oidc.secretName`, keys `GF_AUTH_GENERIC_OAUTH_CLIENT_ID` / `GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET`; with `externalSecrets.enabled` the secrets Application creates it from `grafanaOidcClientIdProperty` / `grafanaOidcClientSecretProperty`
- Endpoints derived from the issuer: `/oauth/v2/authorize`, `/oauth/v2/token`, `/oidc/v1/userinfo`
- Role from the ZITADEL project-roles claim: `grafana.oidc.adminRole` → Admin, `grafana.oidc.editorRole` → Editor (empty = no Editor mapping), `grafana.oidc.viewerRole` → Viewer, none → login refused (`role_attribute_strict`)
- `grafana.oidc.scopes`: default `openid profile email`. A client in its own ZITADEL project, like the LabUL/LabDA `grafana` project (stuttgart-things#4697, roles `grafana-admin`/`-editor`/`-viewer`), adds `urn:zitadel:iam:org:project:id:<id>:aud urn:zitadel:iam:org:projects:roles`
- `grafana.oidc.caConfigMap` set → mounted at `/etc/grafana/oidc-ca` and used as `tls_client_ca` (ZITADEL behind the internal CA); empty = system roots
- Redirect URI to register in ZITADEL: `https://<httpRoute.hostname>/login/generic_oauth`

## Consumer usage

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kube-prometheus-stack
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: infra/kube-prometheus-stack/install
    helm:
      valuesObject:
        project: my-cluster
        destination:
          server: https://<cluster-api>:6443
          namespace: monitoring
        clusterName: my-cluster
        prometheus:
          storageClass: openebs-hostpath
          storageSize: 10Gi
          retention: 15d
          scrapeInterval: 60s
        grafana:
          enabled: true
          adminSecret: kube-prometheus-stack-grafana-admin
        alertmanager:
          enabled: true
          webhook:
            enabled: true
            url: https://omni.platform.example.com/pitch/grafana
        externalSecrets:
          enabled: true
          secretStore: { kind: ClusterSecretStore, name: vault-monitoring }
          remoteKey: my-cluster
        httpRoute:
          enabled: true
          hostname: grafana.my-cluster.example.com
          gateway: { name: my-cluster-gateway, namespace: default }
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
```

On clusters registered through clusterbook, use the `observability-platform` label instead of writing this by hand (`platforms/observability`).

## Values reference

| Key | Default | Purpose |
|---|---|---|
| `project` | `default` | AppProject for all rendered Applications |
| `destination.server` / `namespace` | in-cluster / `monitoring` | Target cluster and namespace |
| `applicationName` | `kube-prometheus-stack-<sha8 of server>` | Name of the stack Application; `-secrets` / `-httproute` are appended for the others |
| `chartVersion` | `91.0.0` | Upstream `kube-prometheus-stack` chart version (renovate) |
| `clusterName` | `""` | `cluster` external label; empty = none |
| `prometheus.storageClass` / `storageSize` | `""` / `10Gi` | Prometheus PVC; empty class = cluster default |
| `prometheus.retention` | `15d` | TSDB retention |
| `prometheus.retentionSize` | `""` | TSDB size cap (WAL included), e.g. `8GB`; empty = 80% of `storageSize` |
| `prometheus.scrapeInterval` | `60s` | Scrape and rule evaluation interval |
| `controlPlane.{kubeControllerManager,kubeScheduler,kubeEtcd,kubeProxy}` | `false` | Control-plane scrape jobs |
| `grafana.enabled` | `true` | Grafana subchart |
| `grafana.adminSecret` | `""` | Secret with `admin-user`/`admin-password`; empty = upstream default credentials |
| `grafana.oidc.issuer` | `""` | ZITADEL issuer URL; empty = OIDC login off |
| `grafana.oidc.name` | `ZITADEL` | Login button label |
| `grafana.oidc.secretName` | `kube-prometheus-stack-grafana-oidc` | Secret with `GF_AUTH_GENERIC_OAUTH_CLIENT_ID`/`_SECRET` |
| `grafana.oidc.caConfigMap` / `caKey` | `cluster-trust-bundle` / `trust-bundle.pem` | CA bundle for the issuer's TLS; empty = system roots |
| `grafana.oidc.adminRole` / `editorRole` / `viewerRole` | `grafana-admin` / `grafana-editor` / `grafana-readonly` | ZITADEL project roles → Grafana Admin / Editor / Viewer; `editorRole: ""` = no Editor mapping |
| `grafana.oidc.scopes` | `openid profile email` | Space-separated OAuth scopes |
| `alertmanager.enabled` | `true` | Alertmanager |
| `alertmanager.webhook.enabled` / `url` | `false` / `""` | Webhook receiver for warning and critical |
| `alertmanager.webhook.tokenSecret` | `kube-prometheus-stack-alertmanager-webhook` | Secret with key `token` (Bearer) |
| `alertmanager.webhook.caConfigMap` / `caKey` | `cluster-trust-bundle` / `trust-bundle.pem` | CA bundle for the webhook's TLS; empty = system roots |
| `externalSecrets.enabled` | `false` | Render the secrets Application |
| `externalSecrets.secretStore.kind` / `name` | `ClusterSecretStore` / `""` | Store to read from |
| `externalSecrets.remoteKey` | `""` | Entry name, flat (no `/data/`) |
| `externalSecrets.*Property` | `grafana-admin-user`, `grafana-admin-password`, `alertmanager-webhook-token`, `grafana-oidc-client-id`, `grafana-oidc-client-secret` | Property names in that entry |
| `externalSecrets.webhookRemoteKey` / `grafanaOidcRemoteKey` | `""` | Entry the webhook token / Grafana OIDC client is read from; empty = `remoteKey` |
| `httpRoute.enabled` | `false` | Render the Grafana HTTPRoute Application |
| `httpRoute.hostname` / `gateway` | `grafana.example.com` / `cilium-gateway` in `default` | Route target |
| `extraValues` | `{}` | Deep-merged on top of the computed upstream `valuesObject` |
| `catalog.repoURL` / `targetRevision` | this repo / `HEAD` | Where the sub-Applications fetch their charts |
| `syncPolicy` | automated + retry, `ServerSideApply` | Applied to all rendered Applications. Keep `ServerSideApply`: the operator CRDs exceed the client-side annotation limit |

## Related

- Flux equivalent: [`stuttgart-things/flux` — `infra/kube-prometheus-stack`](https://github.com/stuttgart-things/flux/tree/main/infra/kube-prometheus-stack)
- Bare Prometheus: [`infra/prometheus`](../prometheus/)
- Upstream chart: <https://prometheus-community.github.io/helm-charts>
