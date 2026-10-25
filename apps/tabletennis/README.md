# apps/tabletennis

The **tabletennis platform** — a platform of its own, beside homerun2 rather than inside it.

Two applications that are one thing to operate: [`zaehlwerk`](../zaehlwerk/) keeps the live
score of a match, [`schmetterpause`](../schmetterpause/) holds the league that match counts
towards. A cluster that wants one almost always wants both. Optionally a third piece — the LED
strip at the table.

The Argo CD counterpart to `flux/apps/tabletennis`, plus the tabletennis light-catcher that
lives on the flux side as `apps/homerun2/components/light-catcher-tabletennis` (bundled by
`apps/platform/components/homerun2-light-catcher-tabletennis`).

## Layout

```
apps/tabletennis/
└── install/        app-of-apps chart (what a consumer points one Application at) — renders:
                      Application "…-schmetterpause"         (wave  0) → apps/schmetterpause/install
                      Application "…-zaehlwerk"              (wave  0) → apps/zaehlwerk/install
                      Application "…-light-catcher"          (wave  0) → homerun2-light-catcher OCI, opt-in
                      Application "…-light-catcher-secrets"  (wave -10) → apps/homerun2/secrets, opt-in
                      Application "…-piezo-sim"              (wave  1) → apps/zaehlwerk/piezo-sim, opt-in
                      Application "…-pong"                   (wave  1) → apps/zaehlwerk/pong, opt-in
```

With `schmetterpause.seed`, schmetterpause's sub-chart renders one more leaf, `…-seed`
(wave 1) → `apps/schmetterpause/seed`.

The two applications are delegated rather than re-implemented: their charts
([`apps/schmetterpause`](../schmetterpause/), [`apps/zaehlwerk`](../zaehlwerk/)) stay usable on
their own, and each keeps its own strict schema. This chart computes what the two have in
common — project, destination, sync policy, gateway, secret store, the hostnames — and each
component's `values` block passes anything else straight through:

```yaml
schmetterpause:
  values:
    database:
      storage: { size: 8Gi, storageClass: openebs-hostpath }
      backup:  { enabled: true, endpointURL: https://minio…, destinationPath: s3://… }
    monitoring:
      enabled: true
```

A consumer's `values` wins over the computed defaults, and the sub-chart's own schema validates
the result — so the knobs are documented where they belong rather than duplicated here.

One exception to "straight through": `database.backup.enabled` and `database.recovery.enabled`
may arrive as the strings `"true"` / `"false"`, because a platform AppSet templates them from
cluster annotations and cannot produce a boolean. This chart turns them into booleans before
handing over (`tabletennis.schmetterpauseOverride`), because the sub-chart's schema refuses a
string, and in a Go-template `if` the string `"false"` is truthy. Anything but `"true"` is off.

## Three namespaces, no shared one

There is no top-level `destination.namespace`. schmetterpause, zaehlwerk and the light-catcher
each land in a namespace of their own, set per component, and every rendered Application
carries `CreateNamespace=true` — none of the published bases ships a Namespace, on purpose
(more than one Application shipping the same Namespace makes ArgoCD flag it as a
SharedResource, after which one Application's prune deletes it out from under the others).

## What it knows about homerun2

One value:

```yaml
homerun2:
  namespace: homerun2
```

That is the whole coupling. It derives three things:

- **zaehlwerk's panel** — `http://homerun2-omni-pitcher.<ns>.svc.cluster.local` (where a scored
  point goes) and `http://homerun2-led-catcher.<ns>.svc.cluster.local` (the catcher zaehlwerk
  takes over for the duration of a match).
- **the light-catcher's Redis** — `redis-stack.<ns>.svc.cluster.local`, across the namespace
  boundary. This platform runs no Redis of its own; the bus belongs to homerun2.
- **the default WLED endpoint** — homerun2's wled-mock, for a cluster without a real strip.

Leave it empty and homerun2 is simply not on this cluster: zaehlwerk runs without a panel,
which upstream supports and reports nothing about, and `lightCatcher.enabled` is refused
because it would have no bus to read from.

## What homerun2 has to be told

**One setting, on the homerun2 side, and nothing here can check it.** zaehlwerk pitches with
`system: tabletennis`; omni-pitcher only puts that on a `tabletennis` stream if its routing
file says so. In `apps/homerun2/install`:

```yaml
omniPitcher:
  routesContent: |
    streams: [messages, tabletennis]
    default_stream: messages
    routes:
      - match: { system: tabletennis }
        stream: tabletennis
```

Without it the scores land on `messages`. **The pitch returns 200, every Pod reports Healthy,
and the tabletennis catcher watches an empty stream** — a failure with no error anywhere in it.
Check it directly rather than trusting green Applications:

```bash
# after a point has been scored in zaehlwerk's /ui
kubectl -n homerun2 exec deploy/redis-stack -- redis-cli -a "$PW" XLEN tabletennis
```

A cluster that also wants Alertmanager and GitHub traffic on streams of their own extends the
same file (the full block is in `apps/homerun2/install/values.yaml`). Note that moving
`/pitch/grafana` onto an `alerts` stream means `notificationCatcher.redisStream` has to move
with it.

**And the bearer token has to be the same value in two Vault entries.** zaehlwerk reads
`zaehlwerk:omni-pitcher-token`; omni-pitcher reads whatever homerun2's
`secrets.vaultSecretName` / `authToken` names. Different values mean `/pitch` answers 401,
which surfaces only as a `panel pitch failed, point not shown` line in zaehlwerk's log.

## The light-catcher belongs here, not to homerun2

It exists for the table, not for the bus — so it is this platform's. It happens to run the
homerun2 light-catcher image, which is why `homerun2.namespace` is required for it.

**A second instance, not a second stream** on homerun2's existing light-catcher: that base's
profile matches `info` on systems `["*"]` and fires DJ Light for three seconds, so every point
would trigger it, and a profile has no rule that matches and does nothing, nor one that
excludes a system. The strip at the table is not the strip that shows cluster alerts anyway.

**Its own namespace, not a name suffix:** the base names everything `homerun2-light-catcher`
and selects on those labels — the Service, the Deployment selector, its pod anti-affinity. In
one namespace the two Services would each route to both instances.

The effects profile ships four rules — match won, set won, point to side a, point to side b —
each pointed at `wledEndpoint`. They match on the tags zaehlwerk v0.3.0+ emits, so
**light-catcher v1.1.0 or later is required**: an older catcher ignores tags, and then the
first rule takes every set *and* match and side a's colour every point. `profileContent`
replaces the whole file.

| value | default | |
|---|---|---|
| `lightCatcher.reloader` | `true` | annotates the Deployment `reloader.stakater.com/auto: "true"`, so a changed profile or rotated redis Secret rolls the pod (the catcher reads both at start only). Needs Stakater Reloader (`infra/reloader`) on the cluster |
| `lightCatcher.httpRoute.enabled` | `false` | keep the base's HTTPRoute, patched onto `gateway` with `hostname`, instead of deleting it. Patched in place, so route and Service land in one apply (Cilium resolves backendRefs once) |
| `lightCatcher.hostname` | `""` | the route's hostname; empty = `light-catcher-tabletennis.<domain>` |

## The piezo board simulator (`piezoSim`)

`piezoSim.enabled: true` (platform: cluster label `tabletennis-platform/piezo-sim: 'true'`)
renders [`apps/zaehlwerk/piezo-sim`](../zaehlwerk/piezo-sim/) into zaehlwerk's namespace: the
piezo board from zaehlwerk's `tools/chain-mock` (image `zaehlwerk-piezo`). It waits, like the
real board, until a match is started on the scoring page, plays it through `POST /ingest/piezo`
— rallies, the deliberate duplicates, delta-0 events and undos — and waits for the next. It
never starts a match itself.

**A won match is handed over like any other.** With `zaehlwerk.handover` and
`schmetterpause.scoreboard` on, every simulated match lands in that cluster's league (pending,
schmetterpause ADR-0015). Demo and test clusters only.

The image tag is `zaehlwerk.version`, or `piezoSim.version` when set. `zaehlwerk-piezo` exists
from **v0.8.0** on, and the chart refuses an older version rather than leave a pod in
ImagePullBackOff. `piezoSim.board` sets best of, pace, the noise shares and the seed. The PR
previews run the same chart (`platforms/zaehlwerk-pr-preview`, label `preview-sim`).

## zaehlwerk-pong (`pong`)

`pong.enabled` renders [`apps/zaehlwerk/pong`](../zaehlwerk/pong/) into zaehlwerk's namespace:
the game at `pong.hostname` (default `zaehlwerk-pong.<domain>`, on `gateway`), and zaehlwerk's
`PONG_URL` pointed at it for the watch screen's screensaver (zaehlwerk ADR-0013). The image tag
is `zaehlwerk.version` unless `pong.version` is set; the chart refuses anything below v0.16.0.
`pong.attractAfter` turns attract mode on. **Without `pong.league` every Pong match is a demo**
and is reported nowhere (zaehlwerk ADR-0008). This is the counterpart of flux's
`zaehlwerk-pong-on` / `-attract`.

## The Pong sandbox

A second schmetterpause and zaehlwerk, in namespaces of their own, where zaehlwerk-pong plays a
league by itself: one real match after another between eight bot players, every result
reported and rated at once (zaehlwerk ADR-0015/0016, schmetterpause ADR-0027). The counterpart
of flux's `profiles/sandbox`, selected there as `tabletennis-sandbox`.

**Here it is a second Application of this same chart**, next to the office's, with the values
below. The chart can host two instances on one cluster because everything it names is derived
from `applicationName` (Applications, Helm release names) or set per component (namespaces,
hostnames). The one cluster-scoped object it can render, schmetterpause's Kyverno policy, stays
with the office (`schmetterpause.policy.enabled` off here), and so do the light-catcher, its
secrets and the piezo board.

| value | what it adds | flux component |
|---|---|---|
| `schmetterpause.scoreboard.enabled` | `/api` on the sandbox's schmetterpause, and — with `zaehlwerk.handover` — the handover | `schmetterpause-scoreboard-sops`, `zaehlwerk-handover-sops` |
| `zaehlwerk.schmetterpauseURL` | the handover over the in-cluster Service, so the league depends on no certificate | `ZAEHLWERK_SCHMETTERPAUSE_URL` |
| `zaehlwerk.matches` | `MATCHES_TOKEN`: `POST /matches` takes player ids (zaehlwerk **v0.31.0+**). Adds the container's env entry too, because the v0.31.0 base does not list the key | `zaehlwerk-matches-sops` |
| `schmetterpause.scoreboard.settle: immediate` | `SP_SCOREBOARD_SETTLE` (schmetterpause **v0.18.0+**): nobody confirms in a sandbox | `schmetterpause-settle-immediate` |
| `schmetterpause.seed` | a Job running `schmetterpause seed` with `SP_SEED_FIXTURE=pong`: Ada … Hanna and the observer `Pong`. Refuses a database with players, so every later run is a no-op | `schmetterpause-seed-pong` |
| `pong` + `pong.league` | the game in league mode: `ZAEHLWERK_TOKEN` (the matches token), `PONG_OPERATOR` (`Pong`), `PONG_PLAYER_SKILL` (a spread over the seed's names), `PONG_LEAGUE_PAUSE` (`30s`); with `pong.league.tournaments`, `PONG_TOURNAMENTS=on`: open tournament places first (zaehlwerk v0.32.0+, schmetterpause v0.19.0+) | `zaehlwerk-pong-league` |
| `zaehlwerk.panel: redis` + `panelStream` | optional: the score into homerun2's Redis on `tabletennis-sandbox`, no catcher switch | `zaehlwerk-panel-redis` |

```yaml
    helm:
      values: |
        applicationName: tabletennis-<cluster>-sandbox   # MUST differ from the office's
        project: <cluster>
        destination: { name: <cluster> }
        domain: <cluster>.sthings.lab
        gateway:     { name: <cluster>-gateway, namespace: default }
        secretStore: { kind: ClusterSecretStore, name: vault-<cluster> }
        secretSources:
          schmetterpause:
            entry: schmetterpause-sandbox    # + schmetterpause-sandbox-scoreboard
        homerun2: { namespace: homerun2 }
        schmetterpause:
          namespace: schmetterpause-sandbox
          hostname: schmetterpause-sandbox.<cluster>.sthings.lab
          scoreboard: { enabled: true, settle: immediate }
          seed: { enabled: true, fixture: pong }
          values:
            database: { storage: { size: 1Gi } }
        zaehlwerk:
          namespace: zaehlwerk-sandbox
          hostname: zaehlwerk-sandbox.<cluster>.sthings.lab
          schmetterpauseURL: http://schmetterpause.schmetterpause-sandbox.svc.cluster.local
          matches: { enabled: true, vaultPath: zaehlwerk-sandbox-matches, vaultProperty: token }
          panel: redis                       # or false
          panelStream: tabletennis-sandbox
        pong:
          enabled: true
          hostname: zaehlwerk-pong-sandbox.<cluster>.sthings.lab
          league: { enabled: true }
        cascadingDelete: false
```

**The Vault entries come first.** ESO fails a whole ExternalSecret over one missing property,
so before this syncs the store needs `schmetterpause-sandbox` (`session-key`, `username`,
`password`), `schmetterpause-sandbox-scoreboard` (`token`, read by both sides) and
`zaehlwerk-sandbox-matches` (`token`, `openssl rand -hex 32`, read by zaehlwerk as
`MATCHES_TOKEN` and by the game as `ZAEHLWERK_TOKEN`). zaehlwerk's panel properties keep
coming from `zaehlwerk` (or homerun2's entry through `secretSources.homerun2`); with
`panel: redis` its `redis-password` has to be homerun2's.

**On the office's panel.** With the sandbox's panel at `redis`, its matches go to
`tabletennis-sandbox`. The office shows them between its own matches when that stream is in its
zaehlwerk's idle streams — `zaehlwerk.catcherIdleStreams: messages,tabletennis-sandbox` in the
office's values — and in homerun2's led-catcher streams on the homerun2 side. A real match
switches the catcher to `tabletennis` alone and the sandbox is off the panel until it ends
(zaehlwerk ADR-0003, ADR-0016).

**Never on the office's pair.** Every sandbox-only value is off by default, and the guard is a
secret: an office zaehlwerk has no `MATCHES_TOKEN`, so Pong in league mode is refused with 503
there and creates nothing. The chart also refuses `pong.league` without `zaehlwerk.matches`,
`zaehlwerk.matches` without the handover, and either below zaehlwerk v0.31.0.

## Per-cluster secrets

`secretSources` addresses secrets by the app that owns them, as a ClusterStack publishes them
(crossplane-configurations#464, xplane-cluster >= 0.18.0):

| owner | store / entry go to |
|---|---|
| `schmetterpause` | schmetterpause's `secretStore` + `vaultEntry`; scoreboard token `<entry>-scoreboard`; zaehlwerk's handover token through that store |
| `homerun2` | zaehlwerk's panel store + `homerun2Secrets.vaultEntry` (authToken, redisPassword from homerun2's own entry); the light-catcher's store and entry |

Empty keeps the single `secretStore` and the fleet-wide entries (`schmetterpause`,
`schmetterpause-scoreboard`, `zaehlwerk`, `secrets.vaultSecretName`) — the rendered output is
byte-identical to before.

## Middle layer and deletion

`schmetterpause` and `zaehlwerk` are each ONE middle-layer Application here, rendering the sub-chart's own Applications (app, database, monitoring, policy). Two rules follow:

- **Its own name, never the leaf's.** The sub-chart names its leaves after `applicationName`; this chart passes `<app>-schmetterpause-delegate` / `<app>-zaehlwerk-delegate` unless `values.applicationName` overrides it. A leaf carrying the middle layer's name is the same object — it applied its spec over itself and never settled (the pattern homerun2's `redis-stack` → `redis-stack-delegate` already avoids).
- **Always a `resources-finalizer` on the middle layer**, whatever `cascadingDelete` says. It renders only Applications in `argocd`, so deleting it removes Argo records, nothing on the cluster; without it the leaves were orphaned when the ApplicationSet removed a cluster, and blocked its AppProject. The workloads stay protected by the leaves, which follow `cascadingDelete` (no finalizer when `false`).

## Cluster preconditions

- **A Gateway** with an `http` and an `https` listener whose hostname covers `*.<domain>` —
  and it must be **internal**. zaehlwerk has no authentication of its own, so its route *is*
  the access control: anyone who can reach the hostname can start a match, score it, take a
  point back, end it, and with the panel wired, take over the LED strip.
- **The CNPG operator** (`infra/cloudnative-pg/install`) for schmetterpause's database, plus
  the Barman Cloud plugin (`infra/cloudnative-pg/barman-cloud`) if backups are enabled.
- **External Secrets** with a `ClusterSecretStore` (`infra/external-secrets/install` +
  `cluster-secret-store-vault`) holding two entries: `schmetterpause` (`session-key`,
  `username`, `password`) and `zaehlwerk` (`omni-pitcher-token`, `redis-password`). Put **both**
  zaehlwerk properties there even if Redis is unused — ESO fails the whole ExternalSecret on a
  missing key.
- **Stakater Reloader** (`infra/reloader/install`) so a changed panel URL actually rolls
  zaehlwerk; the annotation is harmless without the controller, but then it needs a manual
  rollout restart.
- **The Prometheus Operator CRDs** (`infra/kube-prometheus-stack`) for
  `schmetterpause.values.monitoring.enabled`.

## Consumer usage

```yaml
    helm:
      values: |
        project: tabletennis
        destination:
          name: tabletennis
        domain: tabletennis.sthings.lab
        gateway:     { name: cilium-gateway, namespace: default }
        secretStore: { kind: ClusterSecretStore, name: vault-tabletennis }
        homerun2:
          namespace: homerun2
        schmetterpause:
          enabled: true
          version: v0.11.0
          bootstrapAdmin: timoboll
          # Turns on schmetterpause's /api AND wires zaehlwerk to it — see below.
          scoreboard:
            enabled: true
          values:
            database:
              storage: { size: 8Gi, storageClass: openebs-hostpath }
              protect: true
        zaehlwerk:
          enabled: true
          version: v0.5.0
        lightCatcher:
          enabled: true
          wledEndpoint: http://wled-tt.lan
        secrets:
          enabled: true
          vaultSecretName: homerun2
```

Hostnames come out as `schmetterpause.tabletennis.sthings.lab` and
`zaehlwerk.tabletennis.sthings.lab`; set a component's own `hostname` to override.

## Differences from the flux path

| | flux | here |
|---|---|---|
| The pair | `apps/tabletennis/profiles/base` (a kustomize component list) | one app-of-apps chart delegating to two catalog entries |
| Panel on/off | two components (`zaehlwerk-panel-homerun2` / `-off`), because an empty Flux substitution renders as YAML `null` and fails the whole apps layer | `zaehlwerk.panel` + `homerun2.namespace` — Helm can express "absent" |
| The tabletennis light-catcher | a homerun2 platform component (`apps/platform/components/homerun2-light-catcher-tabletennis`) | part of this platform, since it exists for the table |
| The light-catcher's route | always, from a routes Kustomization that `dependsOn` the catcher (`light-catcher-tabletennis.<domain>`) | opt-in `lightCatcher.httpRoute.enabled`; the base's own route patched in place, same hostname default |
| The light-catcher's Vault property | `redis-password` | `redisPassword` — the property every homerun2 component reads on the Argo side |
| DB backups | a component of its own (`schmetterpause-db-backup`), selected as the alternative bundle `tabletennis-backup` | `schmetterpause.values.database.backup` |
| Monitoring | three components (`schmetterpause-monitoring-off` / `-on` / `-backup`) | `schmetterpause.values.monitoring` |
| The scoreboard token | a component pair (`schmetterpause-scoreboard-off` / `-on`), because ESO fails the whole app secret over one missing Vault property | `schmetterpause.scoreboard.enabled` |
| The handover | a component pair (`zaehlwerk-handover-off` / `-on`), wired from the same variables | derived from `schmetterpause.scoreboard.enabled` + `zaehlwerk.handover` |
| The live score | — | `zaehlwerk.liveScore`: schmetterpause's `SP_ZAEHLWERK_URL` and zaehlwerk's `ALLOWED_ORIGINS`, derived from the two hostnames |
| The image-signature policy | a component pair (`schmetterpause-policy-off` / `-on`) reading the schmetterpause repo through a `GitRepository` | `schmetterpause.policy.enabled`, a git Application at the same tag |
| The bootstrap admin | `TABLETENNIS_SCHMETTERPAUSE_BOOTSTRAP_ADMIN` — a plain substitution, since empty means "none" to the app | `schmetterpause.bootstrapAdmin` |
| omni-pitcher routing | a default `routes.yaml` in the homerun2 base | set on homerun2's `routesContent` — see above |
| The panel modes | `TABLETENNIS_ZAEHLWERK_PANEL`: `off`, `homerun2`, `redis` (components) | `zaehlwerk.panel`: `false`/`off`, `true`/`homerun2`, `redis`, plus `panelStream` |
| Catcher idle streams | `ZAEHLWERK_CATCHER_IDLE_STREAMS`, always set (`messages`) | `zaehlwerk.catcherIdleStreams`, left out when empty (zaehlwerk's default is `messages`) |
| zaehlwerk-pong | `zaehlwerk-pong-off` / `-on` / `-attract` / `-league` | `pong.enabled`, `pong.attractAfter`, `pong.league` |
| The Pong sandbox | `profiles/sandbox`, a bundle entry of its own (`tabletennis-sandbox`) with `TABLETENNIS_SANDBOX_*` variables and a sops Secret | a second Application of this chart with its own `applicationName` and values — see above; credentials through ESO like the office's |
| The seed Job | `kustomize.toolkit.fluxcd.io/force: Enabled` | `argocd.argoproj.io/sync-options: Force=true,Replace=true`, in an Application of its own |

Both paths reach the same end state: schmetterpause at the pinned tag with its database,
zaehlwerk beside it, the handover between them, and homerun2 carrying the panel. What
differs is only how an on/off switch is spelled — a kustomize component there, a value
here — because an empty Flux substitution cannot express "absent".

## Related

- [`apps/schmetterpause`](../schmetterpause/) · [`apps/zaehlwerk`](../zaehlwerk/) — the two
  catalog entries this chart composes.
- [`apps/homerun2`](../homerun2/) — the event bus this platform talks to.
