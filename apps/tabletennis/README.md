# apps/tabletennis

The **tabletennis platform** — a platform of its own, beside homerun2 rather than inside it.

Two applications that are one thing to operate: [`zaehlwerk`](../zaehlwerk/) keeps the live
score of a match, [`schmetterpause`](../schmetterpause/) holds the league that match counts
towards. A cluster that wants one almost always wants both. Optionally a third piece — the LED
strip at the table.

The Argo CD counterpart to `flux/apps/tabletennis`, plus the tabletennis light-catcher that
lives on the flux side as `apps/platform/components/homerun2-light-catcher-tabletennis`.

## Layout

```
apps/tabletennis/
└── install/        app-of-apps chart (what a consumer points one Application at) — renders:
                      Application "…-schmetterpause"         (wave  0) → apps/schmetterpause/install
                      Application "…-zaehlwerk"              (wave  0) → apps/zaehlwerk/install
                      Application "…-light-catcher"          (wave  0) → homerun2-light-catcher OCI, opt-in
                      Application "…-light-catcher-secrets"  (wave -10) → apps/homerun2/secrets, opt-in
```

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
| DB backups | a component of its own (`schmetterpause-db-backup`), selected as the alternative bundle `tabletennis-backup` | `schmetterpause.values.database.backup` |
| Monitoring | three components (`schmetterpause-monitoring-off` / `-on` / `-backup`) | `schmetterpause.values.monitoring` |
| The scoreboard token | a component pair (`schmetterpause-scoreboard-off` / `-on`), because ESO fails the whole app secret over one missing Vault property | `schmetterpause.scoreboard.enabled` |
| The handover | a component pair (`zaehlwerk-handover-off` / `-on`), wired from the same variables | derived from `schmetterpause.scoreboard.enabled` + `zaehlwerk.handover` |
| The image-signature policy | a component pair (`schmetterpause-policy-off` / `-on`) reading the schmetterpause repo through a `GitRepository` | `schmetterpause.policy.enabled`, a git Application at the same tag |
| The bootstrap admin | `TABLETENNIS_SCHMETTERPAUSE_BOOTSTRAP_ADMIN` — a plain substitution, since empty means "none" to the app | `schmetterpause.bootstrapAdmin` |
| omni-pitcher routing | a default `routes.yaml` in the homerun2 base | set on homerun2's `routesContent` — see above |

Both paths reach the same end state: schmetterpause at the pinned tag with its database,
zaehlwerk beside it, the handover between them, and homerun2 carrying the panel. What
differs is only how an on/off switch is spelled — a kustomize component there, a value
here — because an empty Flux substitution cannot express "absent".

## Related

- [`apps/schmetterpause`](../schmetterpause/) · [`apps/zaehlwerk`](../zaehlwerk/) — the two
  catalog entries this chart composes.
- [`apps/homerun2`](../homerun2/) — the event bus this platform talks to.
