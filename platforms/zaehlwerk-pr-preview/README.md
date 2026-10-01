# zaehlwerk PR-preview platform

Per-pull-request preview environments for
[stuttgart-things/zaehlwerk](https://github.com/stuttgart-things/zaehlwerk).
One bootstrap Application renders two ApplicationSets that fan out to every
cluster opting in by label — the same shape as `platforms/homerun2-pr-preview/`
and `platforms/schmetterpause-pr-preview/`.

## Layout

```
platforms/zaehlwerk-pr-preview/
├── application.yaml                  # bootstrap, applied once on the management cluster
├── kustomization.yaml                # lists the AppSets (not the bootstrap)
├── appset-zaehlwerk-pr-preview.yaml  # (clusters × labelled PRs)
├── appset-sweep.yaml                 # namespace sweep per cluster
├── appset-sim.yaml                   # opt-in board simulator (preview-sim)
└── README.md
```

## One cell

For pull request 54 on `app-dev`:

| | |
|---|---|
| Parent Application | `zaehlwerk-pr-54` (argocd ns, management cluster) |
| Children | `zaehlwerk-pr-54-bundle-zaehlwerk`, `zaehlwerk-pr-54-bundle-schmetterpause` (+ its database) |
| Namespace | `zaehlwerk-pr-54` (both apps) |
| URLs | `https://zaehlwerk-pr-54.<fqdn>`, `https://schmetterpause-zaehlwerk-pr-54.<fqdn>` |
| Artefacts | `zaehlwerk{,-kustomize}:pr-54-<head sha>`, `schmetterpause-kustomize:preview` |

## What a preview is

The tabletennis bundle (`apps/tabletennis/install`): zaehlwerk from the PR plus
a schmetterpause of its own, wired by the handover (zaehlwerk ADR-0004) — the
one place the two meet. zaehlwerk takes its players **and** the people allowed
to keep score from schmetterpause, so that schmetterpause is the `preview` tag:
main, rendered with the seed Job (schmetterpause CI job `kustomize-preview`). A
release artefact has no seed, and an empty league would make the preview
unusable. A won match lands in the preview's league, never in the real one.

Both apps read the entries the cluster's tabletennis platform reads (cluster
annotations `tabletennis-platform.stuttgart-things.com/{schmetterpause,homerun2}-secret-{store,key}`),
including the handover token `<entry>-scoreboard` — one credential both sides
of the preview read.

No panel and no LED strip: `homerun2.namespace` is empty, which is the chart's
"homerun2 is not here", so a test match cannot take over the real strip.

A preview costs the zaehlwerk Pod plus a schmetterpause with a 1Gi Postgres.

## The board simulator (`preview-sim`)

A PR carrying `preview-sim` **in addition to** `preview` also gets the piezo
board simulator (`apps/zaehlwerk/piezo-sim`, image `zaehlwerk-piezo` from the
PR) in its namespace (`appset-sim.yaml`). The board waits like the real one:
start a match on the preview's scoring page and it plays it — rallies, the
deliberate duplicates, delta-0 events and undos — and the won match goes over
the handover into the preview's schmetterpause. It never starts a match of its
own, so nothing lands in the league unless a person started that match. Taking
the label off removes just the board.

## Opt-in

**On the cluster Secret**, so a cluster chooses to host previews:

```yaml
metadata:
  labels:
    zaehlwerk-pr-preview: "true"
```

In `stuttgart-things/stuttgart-things` this goes in the `ClusterbookCluster`
`spec.labels` block. With no cluster carrying it the AppSet renders zero cells
— not broken, just empty, which is harder to see.

**On the pull request**: the `preview` label. CI publishes the per-PR artefacts
for every PR (`push-kustomize-pr.yaml`); the environment waits for the label.
The PR then gets a comment with its URL (`comment-preview-url.yaml`, org
variable `HOMERUN2_PREVIEW_DOMAIN`), and closing it removes the artefacts
(`cleanup-pr-artifacts.yaml`).

## Teardown and the sweep

Closing the PR or removing the label drops the cell: the parent's finalizer
prunes the child, the child's (`cascadingDelete: true`) prunes the workload.
The namespace stays — `CreateNamespace=true` does not track it — and
`appset-sweep.yaml` removes it: a Kyverno `ClusterCleanupPolicy` per cluster
deletes `zaehlwerk-pr-*` namespaces older than an hour with no Pods. The
cluster's Kyverno cleanup controller needs `pods: get, list` for that (security
platform, stuttgart-things/argocd#568); without it the policy fails the moment
a namespace matches and stops running.
