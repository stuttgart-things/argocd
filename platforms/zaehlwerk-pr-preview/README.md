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
└── README.md
```

## One cell

For pull request 54 on `app-dev`:

| | |
|---|---|
| Parent Application | `zaehlwerk-pr-54` (argocd ns, management cluster) |
| App Application | `zaehlwerk-pr-54-app` |
| Namespace | `zaehlwerk-pr-54` |
| URL | `https://zaehlwerk-pr-54.app-dev.sthings-vsphere.labul.sva.de` |
| Artefacts | `ghcr.io/stuttgart-things/zaehlwerk{,-kustomize}:pr-54-<head sha>` |

The parent's name and `applicationName` differ on purpose: the chart uses
`applicationName` verbatim, so a child sharing the parent's name would *be* the
parent.

## What a preview is — and is not

zaehlwerk **alone**. The panel (omni-pitcher, led-catcher) and the
schmetterpause handover are left off: both are optional upstream, and both
would be wrong in a preview — a test match must not take over the real LED
strip or land in the real league. With no panel URL the chart removes
`OMNI_PITCHER_URL` from the ConfigMap, which is zaehlwerk's "no panel".

zaehlwerk owns no database (the running match is in memory), so unlike
schmetterpause a preview costs one Pod and no volume.

The panel ExternalSecret still has to resolve for the Application to be
Healthy. It reads homerun2's entry for the cluster (`<cluster>` under
`vault-homerun2`), exactly what the cluster's permanent zaehlwerk reads. A
cluster whose homerun2 store has another name sets the annotation
`zaehlwerk-pr-preview.stuttgart-things.com/secret-store`.

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
