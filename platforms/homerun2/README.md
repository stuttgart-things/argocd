# platforms/homerun2

The **homerun2 event bus** as a steady-state platform install: one
`ApplicationSet` that fans `apps/homerun2/install` out to every cluster labelled
`homerun2-platform: "true"`.

The Argo CD counterpart to `flux/apps/platform/components/homerun2`.

```bash
kubectl apply -f platforms/homerun2/application.yaml   # once, on the mgmt cluster
```

## What a cluster gets

The fixed profile is what `flux/apps/homerun2/profiles/platform` installs:

| Component | Route |
|---|---|
| `redis-stack` | — (the bus) |
| `omni-pitcher` | `omni-pitcher.<fqdn>` |
| `core-catcher` | `core-catcher.<fqdn>` |
| `scout` | `scout.<fqdn>` |
| `led-catcher` | `led-catcher.<fqdn>` |

plus the ExternalSecrets for every component's Redis password and the `/pitch`
bearer token.

Off, at their chart defaults: k8s-pitcher, light-catcher, wled-mock,
config-viewer, demo-pitcher, git-pitcher, notification-catcher, the ScoutProfile
and the smoke-test. Component **versions** are not overridden either — they
inherit `apps/homerun2/install/values.yaml`, which Renovate keeps bumped, so the
platform tracks the released chart default rather than a second pinned copy.

### Why the profile is fixed

An ApplicationSet can only template **strings** into a chart's values. A
`<component>.enabled` boolean therefore cannot come from a cluster label without
widening all thirteen of those schemas to accept a string — and the string
`"false"` is truthy in a Go template, so every one of them would also need a
`toString` comparison. A cluster that needs a different component set uses the
aggregator-overlay model instead (repo README, *When to pick which model*).

## Labels and annotations

| Label | |
|---|---|
| `homerun2-platform: 'true'` | **[user]** the gate |
| `homerun2-platform/stack: 'false'` | **[user]** opt this cluster out |
| `homerun2-platform.stuttgart-things.com/secrets-config: 'true'` | **[user]** gate — set it to `'true'` only once the ClusterSecretStore exists and can read the entry |
| `clusterbook.stuttgart-things.com/allocation-ip` | *[auto]* must exist and be non-empty |

| Annotation | |
|---|---|
| `clusterbook.stuttgart-things.com/fqdn` | *[auto]* every hostname derives from it |
| `homerun2-platform.stuttgart-things.com/secret-store` | **[user]** required — the ClusterSecretStore name (`vault-<cluster>`) |
| `homerun2-platform.stuttgart-things.com/secret-key` | **[user]** optional, default = the cluster name — the Vault KV entry holding `authToken` + `redisPassword` |
| `homerun2-platform.stuttgart-things.com/storage-class` | **[user]** optional, default `openebs-hostpath` — for redis-stack's PVC |
| `homerun2-platform.stuttgart-things.com/redis-storage-size` | **[user]** optional, default `8Gi` |

The gate is matched on the **value** `'true'`, not merely on the label existing —
unlike `storage-platform`'s `nfs-config`. Under `Exists` a label written as
`'false'` still satisfies the gate, and this repo's own convention is to write
every label a cluster does not want as an explicit `'false'`, which would then
switch it on rather than off.

The `secrets-config` gate is not ceremony. ExternalSecrets fail closed, so a
cluster labelled before its store exists gets Pods sitting in
`CreateContainerConfigError` waiting for Secrets that never appear — and nothing
reports why.

## The stream allowlist

omni-pitcher gets a routing file with two streams:

```yaml
streams: [messages, tabletennis]
default_stream: messages
routes:
  - match: { system: tabletennis }
    stream: tabletennis
```

`tabletennis` is in it on **every** cluster, not only those running
[`platforms/tabletennis`](../tabletennis/). An allowlisted stream nothing writes
to costs nothing — Redis creates a stream on first `XADD` — and having it here
means adding that platform later needs no change to homerun2. Without the rule,
zaehlwerk's scores land on `messages`: the pitch still returns 200, every Pod
reports Healthy, and the tabletennis catcher watches an empty stream.

**Not** included are the flux default's `/pitch/grafana → alerts` and
`/pitch/github → github-events` rules. This profile runs no notification-catcher,
so routing Alertmanager off `messages` would only hide alerts from core-catcher
and scout. A cluster that wants them adds both rules **and**
`notificationCatcher.redisStream: alerts` in the same change.

## Opt-out and teardown

`homerun2-platform/stack: "false"` removes the parent Application and leaves the
workloads running, unmanaged. That is deliberate, and it takes two things:

- no `preserveResourcesOnDeletion` on the AppSet — this generates an app-of-apps
  parent, so what that flag preserves are child *Applications*, not workloads, and
  those orphans then block their AppProject (#324);
- `cascadingDelete: false` in the values, which takes the finalizers off the
  children so the removal does not wait on a prune that, against an already
  deregistered cluster, can never complete.

To actually remove homerun2 from a cluster, delete the parent Application by hand
with the cascade you want.

## Related

- [`platforms/tabletennis`](../tabletennis/) — the platform beside this one; needs
  the `tabletennis` stream above.
- [`apps/homerun2`](../../apps/homerun2/) — the chart this bundle renders.
- `platforms/homerun2-pr-preview/` — the per-PR previews, unrelated to this
  steady-state install.
