# apps/homerun2

Catalog entry for the **homerun2** message-bus stack — Redis Stack + 9 Go microservices that pitch (produce) and catch (consume) events through Redis Streams. Packaged as an **app-of-apps Helm chart** with one toggle per component, so consumers compose deployments by flipping `<component>.enabled` flags.

Port of [`stuttgart-things/flux` — `apps/homerun2`](https://github.com/stuttgart-things/flux/tree/main/apps/homerun2). Maps the flux Kustomize Components pattern (10 components × OCIRepository + Flux Kustomization + per-component HTTPRoute) onto a single Helm chart that emits Argo CD `Application`s with inline kustomize patches.

## Layout

```
apps/homerun2/
├── install/                                  app-of-apps Helm chart (what consumers point at)
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── values.schema.json
│   └── templates/
│       ├── _helpers.tpl                       shared image / redis / auth-token / delete patch templates
│       ├── redis-stack.yaml                   Application "homerun2-redis-stack"   (sync-wave -10, delegates to apps/redis-stack/install)
│       ├── omni-pitcher.yaml                  Application "...-omni-pitcher"       (sync-wave 0)
│       ├── core-catcher.yaml                  Application "...-core-catcher"       (sync-wave 0)
│       ├── scout.yaml                         Application "...-scout"              (sync-wave 0)
│       ├── scout-profile.yaml                 Application "...-scout-profile"      (sync-wave 1, only with scout.profile.enabled or scout.profile.content)
│       ├── k8s-pitcher.yaml                   Application "...-k8s-pitcher"        (sync-wave 0)
│       ├── light-catcher.yaml                 Application "...-light-catcher"      (sync-wave 0)
│       ├── wled-mock.yaml                     Application "...-wled-mock"          (sync-wave 0)
│       ├── config-viewer.yaml                 Application "...-config-viewer"      (sync-wave 0, reads the Kubernetes API — no Redis, no Secrets)
│       ├── demo-pitcher.yaml                  Application "...-demo-pitcher"       (sync-wave 0)
│       ├── led-catcher.yaml                   Application "...-led-catcher"        (sync-wave 0)
│       ├── notification-catcher.yaml          Application "...-notification-catcher" (sync-wave 0, consumer only — no Service, no route)
│       ├── notification-catcher-notify.yaml   Application "...-notification-catcher-notify" (sync-wave -10, only with notificationCatcher.notifyConfig)
│       ├── git-pitcher.yaml                   Application "...-git-pitcher"        (sync-wave 0)
│       ├── ai-pitcher.yaml                    Application "...-ai-pitcher"         (sync-wave 0, four CronJobs — one per mode)
│       ├── schedule-pitcher.yaml              Application "...-schedule-pitcher"   (sync-wave 0, central instance: UI + API)
│       ├── schedule-pitcher-profile.yaml      Application "...-schedule-pitcher-profile" (sync-wave -10, its profile ConfigMap + secret-check Roles)
│       ├── sound-catcher.yaml                 Application "...-sound-catcher"      (sync-wave 0, browser player page, route from its base)
│       ├── portal.yaml                        Application "...-portal"             (sync-wave 5, one frontend for the UIs, route from its base)
│       ├── httproute.yaml                     Application "...-httproute"          (sync-wave 10, builds routes from enabled components)
│       └── smoke-test.yaml                    Application "...-smoke-test"         (sync-wave 20, opt-in via smokeTest.enabled)
├── httproute/                                 multi-HTTPRoute sub-chart (driven by a values list)
├── notification-catcher-notify/               ConfigMap sub-chart carrying notification-catcher's config.yaml (driven by notificationCatcher.notifyConfig)
├── schedule-pitcher-profile/                  ConfigMap sub-chart carrying schedule-pitcher's profile.yaml, plus one Role per namespace its secret checks read (driven by schedulePitcher.profileContent / secretAccess)
├── smoke-test/                                PostSync-hook Job that probes a deployed omni-pitcher (health, unauthenticated 401, authenticated pitch — in-cluster and through the HTTPRoute); see its README
├── preview-quota/                             Kyverno `ClusterPolicy` auto-generating `ResourceQuota` + `LimitRange` in every `homerun2-pr-*` namespace (PR-preview safety net; requires Kyverno installed — see `infra/kyverno/install`)
├── preview-secrets/                           Kyverno `ClusterPolicy` auto-generating `ExternalSecret`s in every `homerun2-pr-*` namespace (pulls per-component secrets from Vault via ESO; requires Kyverno + ESO + `ClusterSecretStore`)
├── preview-seed-data/                         Kyverno `ClusterPolicy` generating a one-shot `Job` in every `homerun2-pr-*` namespace that posts a curated event fixture to omni-pitcher's /pitch endpoint (reviewer-visible non-empty stream from the moment the preview is Ready; requires Kyverno + the `homerun2-omni-pitcher-token` Secret)
└── preview-sweep/                             Kyverno `ClusterCleanupPolicy` reclaiming empty `homerun2-pr-*` namespace shells left behind after PR close (cron-driven; requires Kyverno)
```

## Profiles → values

The flux repo ships pre-composed [`profiles/base`](https://github.com/stuttgart-things/flux/tree/main/apps/homerun2/profiles/base) and [`profiles/cicd`](https://github.com/stuttgart-things/flux/tree/main/apps/homerun2/profiles/cicd) overlays. In Argo this collapses to *which `enabled` flags you set*:

| Profile | Override |
|---|---|
| `base` (default) | `redisStack`, `omniPitcher`, `coreCatcher`, `scout` enabled — others off |
| `cicd` | base + `gitPitcher.enabled: true` |
| `all` | every component enabled (matches the flux root kustomization) |
| `core+light` | base + `lightCatcher.enabled: true` + `wledMock.enabled: true` |

## Component cheat-sheet

| Component | Purpose | Routes? | Auth-token? |
|---|---|---|---|
| `redisStack` | Redis Stack with Sentinel — the bus everything pitches/catches over (delegates to `apps/redis-stack/install`) | no | no |
| `omniPitcher` | HTTP `/pitch` API gateway | yes | yes |
| `coreCatcher` | Redis Streams consumer + web dashboard | yes | no |
| `scout` | RediSearch analytics API — severity/system/alert aggregates + Prometheus `/metrics` for Grafana | yes | yes |
| `k8sPitcher` | Watches K8s API (informers/collectors) → pitches to omni | no | yes |
| `lightCatcher` | Redis Streams consumer → WLED HTTP | yes | no |
| `wledMock` | Mock WLED device + dashboard (dev) | yes | no |
| `configViewer` | Read-only view of which alert triggers what in which catcher — components, findings, severity × system matrix, dry run ([homerun-library#122](https://github.com/stuttgart-things/homerun-library/issues/122)) | yes | no |
| `demoPitcher` | Web UI for manually pitching messages | yes | no |
| `ledCatcher` | Redis Streams consumer → LED display | yes | no |
| `gitPitcher` | Watches Git repos → pitches | no | no |
| `notificationCatcher` | Redis Streams consumer → MS Teams / generic webhooks (the other half of the Alertmanager/Grafana chain) | no | no |
| `aiPitcher` | CronJobs: AI summaries of scout's digest + the schedule-pitcher's open findings via OpenRouter, pitched to omni (morning / evening / week-ahead / weekly) | no | reads omni's + scout's |
| `schedulePitcher` | Central schedule-pitcher: token/cert expiry checks, reminders, findings from agents → omni, web UI + API | yes | own (`schedulePitcherAuthToken`) |
| `soundCatcher` | Redis Streams consumer → clips and spoken announcements on a browser player page (no speaker in a Pod) | yes | `/play` (`authToken`) |
| `portal` | One web frontend for the homerun2 UIs: shell with navigation and service status, reverse proxy serving each service under `/<key>/` ([homerun2-portal](https://github.com/stuttgart-things/homerun2-portal)) | yes (whole hostname) | no |

## What gets deployed (per component)

Each enabled non-redis-stack component renders one Argo CD `Application` whose source is an Argo Kustomize directive against `oci://ghcr.io/stuttgart-things/homerun2-<name>-kustomize` at `.Values.<name>.version`. Inline kustomize patches mirror the corresponding flux `release.yaml`:

1. **Image override** — `ghcr.io/stuttgart-things/homerun2-<name>:<version>`
2. **Per-component redis Secret stringData patch** — the kustomize base ships e.g. `homerun2-omni-pitcher-redis` with a placeholder `password` key; we patch it to `.Values.redisPassword`
3. **REDIS_ADDR / REDIS_PORT env injection** — points the Deployment at `redis-stack.<namespace>.svc.cluster.local:6379` (the chart's redis-stack sub-Application)
4. **(omni + k8s only) Auth-token Secret patch** — patches the per-component `*-token` Secret's `auth-token` key with `.Values.authToken`
5. **(most) Ingress + KCL HTTPRoute deletes** — the bases ship a default Ingress and/or HTTPRoute; we always strip them and ship our own through the httpRoute sub-Application
6. **(k8s-pitcher only) trust-bundle volume + profile ConfigMap reference + webhook port + delete the KCL profile CM** — the calling side provides its own `K8sPitcherProfile` ConfigMap (cluster-specific config)
7. **(notification-catcher only) image, Redis-in-a-ConfigMap, notify volume, both Secrets** — four things no other component needs. Its base is the only one that ships `image: …:latest` while no `latest` is published, so an unpatched install is an ImagePullBackOff, not an old version. Its Redis connection lives in the env ConfigMap rather than container env, so the usual `redisAddrPatch` does not apply. The routing config is mounted from a ConfigMap the chart creates from `notifyConfig`, or that is provisioned out-of-band (see below). And its `…-secrets` Secret ships the literal string `${TEAMS_WEBHOOK_URL}` — an unexpanded placeholder the catcher would POST to — so it is always patched or deleted

8. **(scout + wled-mock) Namespace delete** — scout's and wled-mock's bases ship their own `homerun2` Namespace; we strip it, because otherwise that Application owns the namespace and `prune: true` would take the whole stack down with it when scout is disabled. The parent stack manages the namespace via `CreateNamespace=true` on the destination. (git-pitcher's base used to ship one too; as of v1.0.0 it no longer does.)

9. **(scout only) Auth-token Secret** — same treatment as omni-pitcher: patched from `authToken`, or deleted so an ESO-managed Secret takes over. The base ships a literal `changeme`, and that Secret is the only thing guarding `/analytics/*`

10. **(config-viewer only) no Redis patches** — the viewer reads the Kubernetes API, not the bus, so there is no `*-redis` Secret and no `REDIS_ADDR` to patch. Its base ships a namespace-scoped `Role` + `RoleBinding` (`get`/`list` on `deployments` and `configmaps`), which the Application's AppProject must allow. The only patches are the image and the HTTPRoute (inlined or deleted)

Every `<component>.version` default now carries a `# renovate:` comment, so the catalog defaults track upstream releases instead of ageing silently. The chart uses one `version` for both the image tag and the kustomize OCI tag, which holds because both artifacts ship from the same Release workflow — `coreCatcher` is the exception and takes a separate `kustomizeVersion`.

`coreCatcher` is the only component that takes a separate `kustomizeVersion` from its image `version`. Earlier core-catcher kustomize tags used a `-web` suffix to enable web mode; recent tags accept `CATCHER_MODE: web` via env (which the chart sets unconditionally), so usually `kustomizeVersion == version`.

## Consumer usage

### Default (base profile — redis-stack + omni-pitcher + core-catcher + scout)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: homerun2
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: apps/homerun2/install
    helm:
      values: |
        project: my-cluster
        destination:
          server: https://<cluster-api>:6443
          namespace: homerun2
        # Provide via ArgoCD Vault Plugin / SOPS — never inline literals
        redisPassword: <path:vault/data/homerun2#redis>
        authToken:     <path:vault/data/homerun2#auth>
        omniPitcher:
          enabled: true
          version: v1.6.2
          hostname: omni.my-cluster.example.com
        coreCatcher:
          enabled: true
          version: v0.8.0
          kustomizeVersion: v0.7.1
          hostname: core.my-cluster.example.com
        scout:
          enabled: true
          version: v0.7.0
          hostname: scout.my-cluster.example.com
        httpRoute:
          enabled: true
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

### Full stack (matches flux apps/homerun2 root kustomization)

Add to the helm.values block:

```yaml
        k8sPitcher:
          enabled: true
          version: v0.4.0
          namespace: homerun2-flux
        lightCatcher:
          enabled: true
          version: v0.3.0
          hostname: light.my-cluster.example.com
        wledMock:
          enabled: true
          version: v0.3.0
          hostname: wled.my-cluster.example.com
        demoPitcher:
          enabled: true
          version: v1.4.0
          hostname: demo.my-cluster.example.com
        ledCatcher:
          enabled: true
          version: v0.1.1
          hostname: led.my-cluster.example.com
        gitPitcher:
          enabled: true
          version: v0.5.0
```

## K8sPitcherProfile ConfigMap

`k8sPitcher` references a ConfigMap named `homerun2-k8s-pitcher-profile` (override via `.Values.k8sPitcherProfileConfigMap`) that holds the cluster-specific `K8sPitcherProfile` (pitcher address, collectors, informers). Set `k8sPitcher.profileContent` to the document and the chart creates it (sub-Application `…-k8s-pitcher-profile`, sync-wave -10, in `k8sPitcher.namespace`) and rolls the Pod when it changes; `platforms/homerun2` passes it from the cluster annotation `…/k8s-pitcher-profile`. Empty, provision it out-of-band — example shape (apply to the same namespace as `k8sPitcher.namespace`):

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: homerun2-k8s-pitcher-profile
  namespace: homerun2-flux
data:
  profile.yaml: |
    apiVersion: homerun2.sthings.io/v1alpha1
    kind: K8sPitcherProfile
    metadata:
      name: my-cluster
    spec:
      pitcher:
        addr: https://omni.my-cluster.example.com/pitch
        insecure: false
      auth:
        tokenFrom:
          secretKeyRef:
            name: homerun2-k8s-pitcher-token
            namespace: homerun2-flux
            key: auth-token
      collectors:
        - { kind: Node,  interval: 60s }
        - { kind: Pod,   namespace: "*", interval: 30s }
        - { kind: Event, namespace: "*", interval: 15s }
      informers:
        - { group: "",    version: v1, resource: pods,        namespace: "*", events: [add, update, delete] }
        - { group: apps,  version: v1, resource: deployments, namespace: homerun2-flux, events: [add, update, delete] }
```

In-cluster, point `pitcher.addr` at `http://homerun2-omni-pitcher.<namespace>.svc.cluster.local/pitch` (plain HTTP, no trust bundle needed) and take the token from `homerun2-k8s-pitcher-token` (the secrets sub-Application materializes it from `authToken`).

**RBAC.** The kustomize base ships the ClusterRole `homerun2-k8s-pitcher` (get/list/watch on pods, nodes, events, deployments, replicasets; get on secrets — the token) and its binding; kustomize rewrites the binding's subject to `k8sPitcher.namespace`. That covers the shape above. A profile that informs on anything else (a CRD, jobs, …) adds its rules through `k8sPitcher.extraRbacRules`, which the chart appends to that ClusterRole.

## Schedule-pitcher, ai-pitcher and scout's digest

The three belong together; each one works alone, too.

- **`schedulePitcher`** runs the central instance (`serve`): the checks and reminders of its
  profile, plus findings that agents on other clusters and jobs on VMs `POST /findings`,
  delivered in office hours to the in-cluster omni-pitcher with omni-pitcher's token
  (`PITCHER_TOKEN` from `homerun2-omni-pitcher-token`; the base's `-pitcher` Secret is
  dropped). State lives in this stack's redis-stack. Web UI (`/ui/`) and API on
  `schedulePitcher.hostname`, login with its own token: Secret
  `homerun2-schedule-pitcher-token`, from the per-cluster Vault property
  **`schedulePitcherAuthToken`** — a token of its own because agents carry it.
  The profile is `schedulePitcher.profileContent` (empty: a minimal profile without checks
  that still takes findings and sends the heartbeat); the chart creates the ConfigMap
  (sub-Application `…-schedule-pitcher-profile`, sync-wave -10) and rolls the Pod on a
  change. Checks that read a token through `tokenFrom.secretKeyRef` need `get` on that
  Secret: list them in `schedulePitcher.secretAccess` and the same sub-Application renders
  one `Role` + `RoleBinding` per namespace (the base ships none). Other check types that
  need the API (`scheduled-run`, discovery) need their RBAC added on the calling side.
- **`aiPitcher`** v0.4 runs one CronJob per mode — `modes.{morning,evening,weekAhead,weekly}`,
  all on by default with the base's schedules (as on LabUL platform-sthings); a disabled
  mode's CronJob is not deployed. Each run reads scout's digest and, **when
  `schedulePitcher` is on, its open findings** from `homerun2-schedule-pitcher` in the same
  namespace (with its token). Without it, `aiPitcher.schedulePitcherURL` can name one
  elsewhere; both empty skips the findings. The OpenRouter key is a **shared** entry,
  `secrets.openrouterVaultSecretName` (property `openrouterApiKey`, e.g. `_openrouter`);
  without it the runs still pitch the plain digest marked `[AI n/a]`.
- **`scout`**: with `aiPitcher` on, scout gets `DIGEST_EXCLUDE_SYSTEMS=ai-digest,ai-evening,
  ai-week-ahead,ai-weekly,ai-ticker`, so no digest counts an AI summary; a ScoutProfile that
  lists `digest.excludeSystems` gets the same systems added (its fields win over the env).
  The weekly mode compares this week with the one before, so scout keeps 15 days
  (`SCOUT_RETENTION_TTL=360h`) unless `scout.retentionTTL` says otherwise — more Redis memory
  for a busy stream. The weekly window itself needs scout v0.12+.

The ScoutProfile (alerting, retention, scout's own pitched digest) is `scout.profile.spec`
with `enabled: true`, or `scout.profile.content` as a YAML string — what a cluster
annotation can carry (`platforms/homerun2`: `…/scout-profile`). It must parse to a map, or
the whole chart fails to render. Scout pitches alerts and its digest to
`alerting.pitcherURL`; the chart then hands it omni-pitcher's token.

## Portal

`portal` puts the homerun2 UIs behind one hostname: the portal's overview at `/`, and
each service under `/<key>/` through its reverse proxy, which forwards the path unchanged.
So every service it fronts runs with `BASE_PATH=/<key>` — set `<component>.basePath`
(led-catcher v0.18.0+, core-catcher v1.1.0+, light-catcher v1.9.0+, demo-pitcher v2.1.0+;
the service fragments on the overview, shared colours and compact header need led-catcher
v0.20.0+, core-catcher v1.3.0+, light-catcher v1.12.0+, demo-pitcher v2.3.0+ and portal
v0.4.0+). With a basePath the service answers only under it, on its own hostname too, where
`/` redirects there; `/health` stays at the root for probes and the portal's status check.

```yaml
        portal:
          enabled: true
          hostname: homerun2.my-cluster.example.com
        ledCatcher:   { enabled: true, basePath: /led }
        coreCatcher:  { enabled: true, basePath: /core }
        lightCatcher: { enabled: true, basePath: /light }
        demoPitcher:  { enabled: true, basePath: /pitch }
```

`portal.services` empty lists every enabled one of these four with a basePath, keyed by it
(`/led` → `led=http://homerun2-led-catcher`), in that order — key and prefix cannot drift
apart. Set `portal.services` (`key=url` or `key|Title=url`) to choose the order, titles or
other services. The portal's kustomize OCI ships its HTTPRoute (the whole hostname); the
chart patches parentRef + hostname, or deletes it with `httpRoute.enabled: false`. Same
setup as flux `apps/homerun2/profiles/portal` (`HOMERUN2_PORTAL_SERVICES`,
`HOMERUN2_<COMPONENT>_BASE_PATH`).

## Sound-catcher

`soundCatcher` runs the catcher with the browser sink only — a Pod has no speaker. Open
`https://<soundCatcher.hostname>/` and keep the page open; announcements (clips + Piper
speech, the base's default rules and quiet hours) play there. The route is the one the
kustomize base ships, patched in place, because it carries the `/api/events` rule with
`timeouts.request: 0s` for the page's event stream (the standalone `httproute` chart has no
per-rule timeouts). `/play`, replay and mute take the stack's `authToken` (Secret
`homerun2-sound-catcher-api`, key `token`). Both its Secrets come from `secrets.enabled`:
the base ships neither, only references them.

## Notify config and webhook (notification-catcher)

`notificationCatcher` mounts `config.yaml` from a ConfigMap named
`homerun2-notification-catcher-notify` (override via
`.Values.notificationCatcher.notifyConfigMap`) — which outputs exist, and which stream
entries reach them. Two ways to provide it:

- **From the chart:** set `notificationCatcher.notifyConfig` to the `config.yaml` content.
  The chart renders a `…-notification-catcher-notify` sub-Application
  ([`notification-catcher-notify/`](./notification-catcher-notify/), sync-wave -10) that
  creates the ConfigMap in `destination.namespace`, and the catcher's Pod carries a hash of
  the content so a changed config rolls it.
- **Out-of-band** (`notifyConfig` empty, the default): create the ConfigMap yourself, e.g.:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: homerun2-notification-catcher-notify
  namespace: homerun2
data:
  config.yaml: |
    outputs:
      - name: teams-grafana-alerts
        type: msteams
        webhook_url: "${TEAMS_WEBHOOK_URL}"     # from the …-secrets Secret
        filters:
          match:
            author: grafana                     # omni-pitcher's grafana transformer hard-codes this
          severity_min: warning
```

`${TEAMS_WEBHOOK_URL}` here is expanded by the catcher from its Secret at runtime. Its env
interpolation is regex-only, so a `${…}` inside a YAML **comment** is treated as a real
placeholder too — keep bare `$`-curlies out of comments in this file. Through
`notifyConfig` the placeholder is passed on verbatim: the chart only quotes and indents it
(no `tpl`), and Argo CD does not envsubst Helm values.

The webhook URL itself lives in the Secret `homerun2-notification-catcher-secrets`, key
`TEAMS_WEBHOOK_URL`. The base's copy (a literal placeholder) is always replaced:

- `notificationCatcher.teamsWebhookUrl` set → the base Secret is patched with the literal
  (dev only; use an ArgoCD Vault Plugin / SOPS overlay).
- `secrets.enabled` + `secrets.teamsWebhookVaultSecretName` set (and `teamsWebhookUrl`
  empty) → the secrets sub-Application renders an ExternalSecret reading property
  `teamsWebhookUrl` from that **shared** entry (e.g. `_teams-webhook`) in the same
  ClusterSecretStore as the rest — the same pattern as `githubTokenVaultSecretName`.
- neither → the base Secret is deleted and an out-of-band Secret of that name has to exist.

Leave `dryRun: true` until the filters are known-good: the first wrong one posts to a real
Teams channel.

## Trust bundle (k8s-pitcher TLS)

`k8sPitcher` mounts `.Values.trustBundleConfigMap` (default `cluster-trust-bundle`) at `/etc/ssl/custom/trust-bundle.pem` and sets `SSL_CERT_DIR=/etc/ssl/custom`. The ConfigMap is `optional: true`, so the pod boots without it. To populate it, deploy [`infra/trust-manager/install`](../../infra/trust-manager/) + `infra/trust-manager/bundle` on the workload cluster.

## Values reference

See `install/values.yaml` for defaults and `install/values.schema.json` for the full JSON Schema.

| Key | Default | Purpose |
|---|---|---|
| `project` | `default` | AppProject for all rendered Applications |
| `destination.server` | `https://kubernetes.default.svc` | Target cluster API |
| `destination.namespace` | `homerun2` | Shared namespace for the stack |
| `redisPassword` | `""` | Plain-text Redis password (use ArgoCD Vault Plugin / SOPS) |
| `authToken` | `""` | Bearer token for `/pitch` (use ArgoCD Vault Plugin / SOPS) |
| `trustBundleConfigMap` | `cluster-trust-bundle` | trust-manager Bundle ConfigMap mounted into k8s-pitcher |
| `k8sPitcherProfileConfigMap` | `homerun2-k8s-pitcher-profile` | ConfigMap holding the K8sPitcherProfile |
| `redisStack.enabled` / `chartVersion` / `serviceType` / `persistence.*` / `image.*` / `sentinel.*` | enabled / `17.1.4` / `ClusterIP` / nfs-defaults / stuttgart-things mirrors | Delegates to `apps/redis-stack/install` |
| `<component>.enabled` | `true` for `redisStack`/`omniPitcher`/`coreCatcher`/`scout`; `false` otherwise | Toggle component |
| `<component>.version` | per the flux defaults | Image tag + (usually) OCI kustomize tag |
| `coreCatcher.kustomizeVersion` | `v1.0.3` | OCI kustomize tag (may differ from image `version`) |
| `<component>.hostname` | `<component>.example.com` | FQDN on the HTTPRoute |
| `k8sPitcher.namespace` | `homerun2` | Optional override — k8s-pitcher often runs in a different namespace |
| `httpRoute.enabled` / `gateway.{name,namespace}` | `true` / `cilium-gateway` / `default` | Render Gateway API HTTPRoutes for every enabled component that exposes one |
| `catalog.repoURL` / `targetRevision` | this repo / `HEAD` | Where the redis-stack + httpRoute Applications fetch manifests from |
| `notificationCatcher.enabled` / `version` / `redisStream` / `redisStreams` / `dryRun` / `notifyConfigMap` / `notifyConfig` / `teamsWebhookUrl` | `false` / `v3.0.3` / `messages` / `""` / `false` / `homerun2-notification-catcher-notify` / `""` / `""` | Fan-out to MS Teams / webhooks. Consumer only — no Service, no route. `redisStreams` (comma list, e.g. `messages,tabletennis`) → `REDIS_STREAMS`, which the catcher prefers over `redisStream`: one Deployment consumes them all. `notifyConfig` set → the chart creates the notify ConfigMap, empty → out-of-band; an empty `teamsWebhookUrl` deletes the base's placeholder Secret so an ESO-managed one takes over |
| `secrets.enabled` / `clusterSecretStoreName` / `vaultSecretName` / `githubTokenVaultSecretName` / `teamsWebhookVaultSecretName` / `openrouterVaultSecretName` / `refreshInterval` | `false` / `vault-homerun2-pr` / `preview-env` / `""` / `""` / `""` / `1h` | ExternalSecrets sub-Application. The three `…VaultSecretName` overrides point one component at a shared entry in the same store: git-pitcher's `githubToken`, notification-catcher's `teamsWebhookUrl` (→ Secret `homerun2-notification-catcher-secrets`, key `TEAMS_WEBHOOK_URL`; rendered only when set), ai-pitcher's `openrouterApiKey` (→ `homerun2-ai-pitcher-openrouter`, key `api-key`; rendered only when set) |
| `aiPitcher.enabled` / `version` / `modes.<mode>.{enabled,schedule}` / `timeZone` / `suspend` / `model` / `language` / `retries` / `schedulePitcherURL` / `schedulePitcherTokenSecret` | `false` / `v0.4.1` / all four on, base schedules / `Europe/Berlin` / `false` / free-model list / `German` / `2` / `""` / `homerun2-schedule-pitcher-token` | AI summaries, see above. The two `schedulePitcher…` keys only matter while `schedulePitcher` is off |
| `schedulePitcher.enabled` / `version` / `hostname` / `inlineHttpRoute` / `profileConfigMap` / `profileContent` / `secretAccess` | `false` / `v1.10.0` / `schedule-pitcher.example.com` / `false` / `homerun2-schedule-pitcher-profile` / `""` (minimal profile) / `[]` | Central schedule-pitcher, see above |
| `soundCatcher.enabled` / `version` / `hostname` / `redisStreams` | `false` / `v1.0.0` / `sound-catcher.example.com` / `messages` | Browser-only sound-catcher |
| `ledCatcher.basePath` / `coreCatcher.basePath` / `lightCatcher.basePath` / `demoPitcher.basePath` | `""` | `BASE_PATH`, one segment such as `/led`, for serving behind the portal; see [Portal](#portal) |
| `portal.enabled` / `version` / `hostname` / `services` | `false` / `v0.4.0` / `portal.example.com` / `[]` (derived from the basePaths) | homerun2-portal, see [Portal](#portal) |
| `scout.profile.content` / `scout.retentionTTL` | `""` / `""` | ScoutProfile spec as a YAML string (replaces `spec`, renders on its own); `SCOUT_RETENTION_TTL` (360h with the ai-pitcher's weekly mode) |
| `k8sPitcher.profileContent` / `extraRbacRules` | `""` / `[]` | K8sPitcherProfile document (chart creates the ConfigMap); extra rules for the base's ClusterRole |
| `smokeTest.enabled` / `external.*` / `extraProbes` / `events` | `false` / verify TLS via `cluster-trust-bundle`, dial the gateway Service / one fixture event | Opt-in Job asserting `/health`, an unauthenticated `POST /pitch` → 401, and an authenticated pitch — in-cluster and through the HTTPRoute — plus a `/health` probe per enabled core-catcher/scout. Needs the auth-token Secret (inline `authToken` or `secrets.enabled`). See [`smoke-test/`](./smoke-test/) |
| `syncPolicy` | automated + retry | Applied to all rendered Applications |

## Testing

Automated: set `smokeTest.enabled: true` and the stack ships its own
PostSync-hook Job — see [`smoke-test/`](./smoke-test/). By hand:

```bash
curl -X POST https://omni.<DOMAIN>/pitch \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <AUTH_TOKEN>" \
  -d '{"title":"Test","message":"hello","severity":"info","author":"me"}'
```

The full payload schema is documented in the upstream [homerun2-omni-pitcher](https://stuttgart-things.github.io/homerun2-omni-pitcher/) README. Health check: `curl https://omni.<DOMAIN>/health`.

## Promoting with Kargo

See [`kargo.md`](./kargo.md) for a full Warehouse + Stage example (dev → staging → prod) including the version-key paths Kargo's `yaml-update` step targets, the `coreCatcher.version`/`kustomizeVersion` paired-bump pattern, and the sub-Application health-check gotcha.

## Related

- Flux equivalent: [`stuttgart-things/flux` — `apps/homerun2`](https://github.com/stuttgart-things/flux/tree/main/apps/homerun2)
- Redis Stack chart: [`apps/redis-stack`](../redis-stack/)
- Table tennis is a platform of its own beside this one: [`apps/tabletennis`](../tabletennis/). It needs exactly one setting here — a `tabletennis` stream in `omniPitcher.routesContent` — and nothing on either side reports it missing
- Trust bundle source: [`infra/trust-manager`](../../infra/trust-manager/)
- omni-pitcher docs: <https://stuttgart-things.github.io/homerun2-omni-pitcher/>
- core-catcher docs: <https://stuttgart-things.github.io/homerun2-core-catcher/>
- demo-pitcher docs: <https://stuttgart-things.github.io/homerun2-demo-pitcher/>
- light-catcher docs: <https://stuttgart-things.github.io/homerun2-light-catcher/>

## Reloader

`reloader: true` (default) annotates every component Deployment and the redis-stack StatefulSet with `reloader.stakater.com/auto: "true"`. All of them read the Redis password and their token only at start, so a rotated Secret now rolls them automatically instead of waiting for a manual restart — which the switch of homerun2-test1 to its own entry needed (crossplane-configurations#464 step 7). A no-op without the Reloader controller (`infra/reloader/install`); `reloader: false` renders exactly as before.
