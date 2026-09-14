# platforms/tabletennis

The **tabletennis platform** as a steady-state install: one `ApplicationSet` that
fans `apps/tabletennis/install` out to every cluster labelled
`tabletennis-platform: "true"`.

A platform of its own, **beside** homerun2 rather than inside it. It talks to
homerun2 over the event bus and knows one thing about it: the namespace it runs
in.

The Argo CD counterpart to `flux/apps/platform/components/tabletennis`.

```bash
kubectl apply -f platforms/tabletennis/application.yaml   # once, on the mgmt cluster
```

## What a cluster gets

| Component | Namespace | Route |
|---|---|---|
| `schmetterpause` + its CloudNativePG database | `schmetterpause` | `schmetterpause.<fqdn>` |
| `zaehlwerk` | `zaehlwerk` | `zaehlwerk.<fqdn>` |
| the LED strip at the table (opt-in) | `homerun2-tabletennis` | — |

Versions are not overridden — they inherit `apps/tabletennis/install/values.yaml`,
which Renovate keeps bumped. Both upstreams are pre-1.0 and carry an
`interface-surface` rule, so those bumps are never auto-merged.

schmetterpause's **monitoring stays off**: it needs the Prometheus Operator CRDs
(`observability-platform`), and its `enabled` is a boolean an AppSet cannot
template from a label. Turn it on through an overlay on clusters that run the
stack.

## Cluster preconditions

- **`storage-platform/cloudnative-pg: 'true'`** — schmetterpause's database is a
  CNPG `Cluster`, and without the CRD that Application's dry-run rejects the whole
  apply. The operator AppSet lives in
  [`platforms/storage`](../storage/appset-cloudnative-pg.yaml) because it is a
  singleton per cluster and more than one platform will want it.
- **A ClusterSecretStore** holding two entries: `schmetterpause` (`session-key`,
  `username`, `password`) and `zaehlwerk` (`omni-pitcher-token`,
  `redis-password`). Put **both** zaehlwerk properties there even if Redis is
  unused — ESO fails the whole ExternalSecret on a missing key.
- **An internal gateway.** zaehlwerk has no authentication of its own — no token,
  no session — so its route *is* the access control: anyone who can reach the
  hostname can start a match, score it, take a point back, end it, and with the
  panel wired, take over the LED strip. The clusterbook gateway is on the lab
  network, which is what makes this acceptable.
- **`infra/reloader/install`** (optional) so a changed panel URL actually rolls
  zaehlwerk. The annotation is harmless without the controller, but then it needs
  a manual rollout restart.

## Labels and annotations

| Label | |
|---|---|
| `tabletennis-platform: 'true'` | **[user]** the gate |
| `tabletennis-platform/tabletennis: 'false'` | **[user]** opt this cluster out |
| `tabletennis-platform/light-catcher: 'true'` | **[user]** the LED strip at the table |
| `tabletennis-platform.stuttgart-things.com/secrets-config: 'true'` | **[user]** gate — set it to `'true'` only once the ClusterSecretStore holds both entries |
| `clusterbook.stuttgart-things.com/allocation-ip` | *[auto]* must exist and be non-empty |

| Annotation | |
|---|---|
| `clusterbook.stuttgart-things.com/fqdn` | *[auto]* both hostnames and `allowedOrigins` derive from it |
| `tabletennis-platform.stuttgart-things.com/secret-store` | **[user]** required — the ClusterSecretStore name (`vault-<cluster>`) |
| `tabletennis-platform.stuttgart-things.com/storage-class` | **[user]** optional, empty = the cluster's default SC |
| `tabletennis-platform.stuttgart-things.com/db-storage-size` | **[user]** optional, default `8Gi` |
| `tabletennis-platform.stuttgart-things.com/homerun2-namespace` | **[user]** optional, default `homerun2`; blank it where homerun2 is absent |
| `tabletennis-platform.stuttgart-things.com/wled-endpoint` | **[user]** optional — the real strip's address; empty uses homerun2's wled-mock |
| `homerun2-platform.stuttgart-things.com/secret-key` | **[user]** optional — reused, so the light-catcher reads the *same* Vault entry as every other homerun2 component |

The database **bootstraps** from the Secret its ExternalSecret produces, so
without the store the CNPG Cluster never initialises at all — which is why the
`secrets-config` gate exists.

## What homerun2 has to be told

**One setting, on the homerun2 side, and nothing here can check it.** zaehlwerk
pitches with `system: tabletennis`; omni-pitcher only puts that on a `tabletennis`
stream if its routing file says so.

[`platforms/homerun2`](../homerun2/) ships that rule on **every** cluster it
manages, so a cluster running both bundles needs nothing extra. A cluster whose
homerun2 comes from somewhere else has to carry the rule itself — see that
bundle's README for the block and the `XLEN tabletennis` check.

The other half is the bearer token: zaehlwerk reads
`zaehlwerk:omni-pitcher-token`, omni-pitcher reads `<secret-key>:authToken`. Same
value in both, or `/pitch` answers 401 — visible only as a
`panel pitch failed, point not shown` line in zaehlwerk's log.

## The LED strip is a label, and that is why `enabled` takes a string

It is physical hardware, so it belongs to the cluster rather than the catalog —
`tabletennis-platform/light-catcher: 'true'`. An AppSet can only template
strings, and the string `"false"` is **truthy** in a Go template, so
`apps/tabletennis/install` compares `lightCatcher.enabled` with `toString`
instead of using it as a boolean (same treatment as
`infra/trust-manager/bundle`'s `includeVaultPkiCa`). A plain `if` would deploy
the catcher on every cluster carrying the label at all — which it briefly did,
showing up as an ExternalSecret and a namespace for a catcher that did not exist.

## Pinning

Both `targetRevision`s — the AppSet's own source and the `catalog` it hands the
chart — are pinned to a catalog tag, and Renovate's *Catalog self-pin* rule keeps
them moving. That rule never auto-merges: rolling a catalog release out to every
labelled cluster stays a human decision.

The bootstrap `application.yaml` deliberately stays on `main`, like every other
bundle's — it syncs this directory's ApplicationSets, not the charts they render.

## Opt-out and teardown

`tabletennis-platform/tabletennis: "false"` removes the parent and leaves the
workloads running, unmanaged — no `preserveResourcesOnDeletion` plus
`cascadingDelete: false`, threaded all the way to the grandchildren the two
sub-charts render. See [`platforms/homerun2`](../homerun2/#opt-out-and-teardown)
for why both halves are needed.

**The database survives either way.** The schmetterpause chart's own
`database.protect` puts `Prune=false` + `Delete=false` on the CNPG `Cluster`,
because the PVC holds an ownerReference on it and a prune would take the data
with it. It is on by default and this bundle leaves it there.

## Related

- [`platforms/homerun2`](../homerun2/) — the bus this platform pitches to.
- [`apps/tabletennis`](../../apps/tabletennis/) — the chart this bundle renders.
