# apps/zaehlwerk

Catalog entry for **zaehlwerk** — live scorekeeping for office table tennis
([`stuttgart-things/zaehlwerk`](https://github.com/stuttgart-things/zaehlwerk)).

The Argo CD counterpart to `flux/apps/tabletennis/components/zaehlwerk`. It pairs with
[`apps/schmetterpause`](../schmetterpause/): zaehlwerk keeps the live score of a match,
schmetterpause holds the league that match counts towards. They are separate services in
separate namespaces but one thing to operate — a cluster that wants one almost always wants
both.

## Layout

```
apps/zaehlwerk/
└── install/        renders Application "zaehlwerk" (sync-wave 0) → the published
                    kustomize OCI artifact, environment patched in
```

No sub-charts. Unlike schmetterpause, zaehlwerk owns no database: the running match lives in
the process's memory (upstream ADR-0001), and the panel's Redis and led-catcher are things it
talks to rather than things it owns.

## One replica, and the schema refuses more

The running match is in memory and this service is its only writer, so a second Pod keeps a
second score rather than sharing load. The base sets `replicas: 1` and strategy `Recreate` on
purpose, and upstream's KCL schema asserts it. Nothing in this chart exposes a replica count —
do not add one.

## What the environment patches

Four places where the published base names a placeholder:

| Base ships | Patched to |
|---|---|
| `parentRefs.name: gateway` / `sectionName: https` on the route | `.Values.gateway.*` |
| `zaehlwerk.cluster.example.com` | `.Values.hostname` |
| `secretStoreRef.name: vault-cluster` on `zaehlwerk-panel` | `.Values.secretStore.*` |
| `OMNI_PITCHER_URL: https://omni-pitcher.example.com` in `zaehlwerk-config` | `.Values.panel.*` — or **removed** |

The image is **not** patched. CI tags the artifact and the container image with the same
release version and bakes that reference into the Deployment, so `version` pins both.

The Vault entry name is not patched either: the ClusterSecretStore carries the KV mount and
the base asks for the entry `zaehlwerk` under it, with the properties `omni-pitcher-token` and
`redis-password`.

## The panel key is removed, not blanked

zaehlwerk decides whether it has a panel by asking whether `OMNI_PITCHER_URL` is set — it
tests `os.Getenv(...) != ""`. So any non-empty sentinel is taken for a URL and dialled
forever, and "off" cannot be expressed as a value. With `panel.omniPitcherURL` empty this
chart therefore emits

```yaml
- op: remove
  path: /data/OMNI_PITCHER_URL
```

and the base ships the placeholder precisely so that there is a key to remove: kustomize can
patch a key it can see, but not one that was never rendered.

**An unpatched placeholder is loud rather than broken.** Applied as it stands, the base
pitches to `omni-pitcher.example.com`, which does not resolve. The match still scores and
`/ui` still serves; the log carries one line per point:

```
WARN panel pitch failed, point not shown
     error="… lookup omni-pitcher.example.com … no such host" title="1:0"
```

That line is the signal that `panel.omniPitcherURL` was never set.

## The route is the access control

zaehlwerk has **no authentication** — no token, no session, nothing. Everything reachable
through the HTTPRoute is reachable by anyone who can reach the hostname: creating a match,
scoring it, taking a point back, ending it, and with `panel.catcherURL` set, taking over the
LED strip. Upstream states this as a design decision and refuses a narrower path split, on the
grounds that the scoring page under `/ui` already exercises every capability the API has
(`kcl/httproute.k`).

**So this belongs on an internal gateway.** There is one route and no HTTP-to-HTTPS redirect:
a plaintext request here leaks nothing a login form would, and that policy belongs on the
Gateway once for everything behind it.

## Wiring it to homerun2

The panel is what connects the two platforms. Set one value and both URLs are derived:

```yaml
panel:
  homerun2Namespace: homerun2
```

which gives

```
OMNI_PITCHER_URL: http://homerun2-omni-pitcher.homerun2.svc.cluster.local
CATCHER_URL:      http://homerun2-led-catcher.homerun2.svc.cluster.local
```

Two things on the homerun2 side have to agree with it, and neither fails loudly:

1. **omni-pitcher must route the stream.** Set `omniPitcher.tabletennisStream: true` in
   `apps/homerun2/install`. Without it there is no `tabletennis` stream, the pitch still
   returns 200, every Pod is `Healthy`, and the scores sit on `messages` where no tabletennis
   catcher is looking.
2. **The bearer token must be the same value in two Vault entries.** zaehlwerk reads
   `zaehlwerk:omni-pitcher-token`; homerun2's omni-pitcher reads whatever
   `secrets.vaultSecretName`/`authToken` names. Put the same token in both, or `/pitch`
   answers 401 — which shows up as the same `panel pitch failed` line above.

## Application name

`applicationName` defaults to empty, which derives `zaehlwerk-<sha1(destination)[:8]>`. The
Application lives in the `argocd` namespace of **one** management cluster, so a fixed name
would make two clusters' deployments collide on the same object. The catalog verifier fails a
chart whose names do not vary with the destination (argocd#41). Set `applicationName`
explicitly when the entry is used for a single cluster and you want a readable name.

## Pinning

Upstream is pre-1.0, and the patch surface above **is** the interface between the two
repositories. Under 0.x a rename in it is a MINOR bump, not a major — so a minor of
`zaehlwerk-kustomize` can require a change here. `renovate.json` keeps zaehlwerk out of the
shared `stuttgart-things images` group and off auto-merge for that reason; do not fold it back
in before upstream reaches 1.0.0.

## Cluster preconditions

- **A Gateway** with an `https` listener whose hostname covers `.Values.hostname`, on an
  internal network — see "the route is the access control" above.
- **A ClusterSecretStore** over the Vault mount holding the `zaehlwerk` entry with
  `omni-pitcher-token` and `redis-password` — `infra/external-secrets/cluster-secret-store-vault`.
  Both keys are optional inside the Secret (the Deployment reads them with `optional: true`),
  so a cluster with no entry yet gets a Pod that starts and scores; only the panel pitch
  comes back 401.
- **Stakater Reloader** (`infra/reloader/install`) for `reloader: true` to do anything. The
  annotation is harmless without the controller, but then a changed panel URL needs a manual
  rollout restart — which is how it was found on labda-dev-a.
- **`CreateNamespace=true`**, which the chart's default `syncPolicy` carries. The published
  base ships no Namespace on purpose: several Applications can share a workload namespace, and
  a Namespace resource in more than one of them makes ArgoCD flag it as a SharedResource,
  after which one Application's prune deletes the namespace out from under the others.

## Consumer usage

```yaml
    helm:
      values: |
        project: my-cluster
        destination:
          name: my-cluster
          namespace: zaehlwerk
        version: v0.3.0
        hostname: zaehlwerk.my-cluster.example.com
        gateway:     { name: my-cluster-gateway, namespace: default, sectionName: https }
        secretStore: { kind: ClusterSecretStore, name: vault-my-cluster }
        panel:
          homerun2Namespace: homerun2
        # schmetterpause's origin, once its live tab exists
        allowedOrigins: ""
```

## Differences from the flux path

| | flux | here |
|---|---|---|
| Panel on/off | two components (`zaehlwerk-panel-homerun2` / `-off`), because an empty Flux substitution renders as YAML `null` and fails the whole apps layer | one value — Helm can express "absent", so the remove-op is conditional instead |
| Reloader | patch in `release.yaml` | `reloader: true` |
| Namespace | `requirements.yaml` ships one | `CreateNamespace=true` |
| `OMNI_PITCHER_URL` | always removed, then re-added by the panel component | removed only when no panel is configured |

## Related

- [`apps/schmetterpause`](../schmetterpause/) — the other half of the tabletennis pair.
- [`apps/homerun2`](../homerun2/) — the bus the panel pitches to (`omniPitcher.tabletennisStream`,
  `lightCatcherTabletennis`).
