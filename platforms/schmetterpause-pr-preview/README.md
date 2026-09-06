# schmetterpause PR-preview platform

Per-pull-request preview environments for
[stuttgart-things/schmetterpause](https://github.com/stuttgart-things/schmetterpause).
One bootstrap Application renders an `ApplicationSet` that fans out to every
cluster opting in by label — the same shape as `platforms/homerun2-pr-preview/`.

## Why this app has previews

Schmetterpause is a browser app whose premise is a colleague opening it on
their phone during a break. "Does this look right on your phone?" is answered
by a link and not by a diff. The triggers that were weighed before building
this are recorded in stuttgart-things/schmetterpause#82.

## Layout

```
platforms/schmetterpause-pr-preview/
├── application.yaml                        # bootstrap, applied once on the management cluster
├── kustomization.yaml                      # lists the AppSet (not the bootstrap)
├── appset-schmetterpause-pr-preview.yaml   # (clusters × labelled PRs)
└── README.md
```

## One cell

For pull request 42 on a cluster called `homerun2-test1`:

| | |
|---|---|
| Parent Application | `schmetterpause-pr-42` (argocd ns, management cluster) |
| App Application | `schmetterpause-pr-42-app` |
| Database Application | `schmetterpause-pr-42-app-db` (sync wave -10) |
| Namespace | `schmetterpause-pr-42` |
| URL | `https://schmetterpause-pr-42.homerun2-test1.sthings-vsphere.labul.sva.de` |
| Artefacts | `ghcr.io/stuttgart-things/schmetterpause{,-kustomize}:pr-42-<head sha>` |

The parent's name and `applicationName` differ on purpose. The chart uses
`applicationName` verbatim, so a child sharing the parent's name would *be* the
parent object, overwrite its spec, and leave the sync waiting on its own
deletion.

## Opt-in

Two labels, and both are deliberate.

**On the cluster Secret**, so a cluster chooses to host previews:

```yaml
metadata:
  labels:
    schmetterpause-pr-preview: "true"
```

In `stuttgart-things/stuttgart-things` this goes in the `ClusterbookCluster`
`spec.labels` block, which Clusterbook propagates to the Argo cluster Secret —
for homerun2-test1 that is
`clusters/labul/vsphere/platform-sthings/argocd/homerun2-test1/cluster.yaml`.

**Watch out for how this fails.** With no cluster carrying the label the
ApplicationSet reports `generated 0 applications` — which is exactly what it
reports when no pull request carries `preview`. Nothing is red either way. The
`ParametersGenerated` condition distinguishes them.

**`preview` on the pull request**, so a change chooses to have an environment.
CI publishes an artefact for *every* pull request — that is what lets the Trivy
scan see one — but a Renovate bump does not need a Postgres and a hostname.

## What a preview costs

One app pod, one CloudNativePG instance and one 1Gi PVC per open labelled pull
request. That is the expensive half schmetterpause#82 named, and it is why the
label exists rather than previews being automatic.

## What it does not need

- **No PAT of its own.** Every preview ApplicationSet in this catalog reads
  `homerun2-omni-pitcher-pat` — including the three `machinery-*` sets, which
  watch entirely different repositories. It is the shared PR-reader token under
  a name it outgrew. A second PAT for the same job is a second thing to rotate,
  and the one that gets forgotten is the one nobody else depends on.
- **No AppProject work.** `cluster-projects` in the platform-sthings overlay
  renders `proj-<cluster>` for every cluster labelled `auto-project: "true"`,
  and `config/cluster-project/chart` always grants
  `name: <cluster>, namespace: '*'`. So `schmetterpause-pr-*` is permitted
  without an `extraDestination`.
- **No Vault work per preview.** `vault-schmetterpause` is a
  `ClusterSecretStore` authenticating as the cluster's ESO service account, so
  an `ExternalSecret` in a preview namespace resolves like any other.
- **No DNS and no certificate per preview.** The gateway's listener carries
  `*.homerun2-test1.sthings-vsphere.labul.sva.de` and DNS is wildcarded to the
  same address.
- **No Kyverno policy to seed the environment.** homerun2 needs one because its
  fixture is posted from outside; schmetterpause ships a `seed` subcommand and
  CI renders the Job into the `pr-*` artefact only. An empty preview would be a
  useless preview — a join form and an empty ranking show nothing about a
  change to the standings.

## Teardown

Closing the pull request drops the generator entry. The
`resources-finalizer.argocd.argoproj.io` on the parent is what makes that a
cascading delete rather than an orphaning — without it the pods, the Cluster
and its PVC stay behind.

**The database's own guard has to be off for that to work.** The chart
annotates the CNPG `Cluster` `Prune=false,Delete=false` by default, which is
right for the permanent instance and wrong here: with it on, the cascade stops
at the Cluster and leaves a Postgres pod, three Services and a 1Gi volume
behind. This set passes `database.protect: false`. A cleanup workflow in the app repository deletes both
GHCR packages on the same event.

**The namespace itself is not swept.** Argo removes what it manages; an empty
namespace shell remains. homerun2 solved that with a Kyverno policy, and the
same would work here if the shells become a nuisance.

## Not covered yet

- **No ResourceQuota or LimitRange.** Worth adding before this is used by more
  than a couple of open pull requests at a time.

## Turning it on

Done, and running since 2026-09-06. The bootstrap Application sits beside the
other preview platforms in `stuttgart-things/stuttgart-things`:

```
clusters/labul/vsphere/platform-sthings/argocd/schmetterpause-pr-preview-platform.yaml
```

`application.yaml` in this directory is the same object for a `kubectl apply`
where that is quicker — it is deliberately not listed in `kustomization.yaml`,
so the rendered set never contains its own bootstrap.

The first cell, end to end, took about ten minutes from the label: CI published
`pr-187-7589b21f…` for both packages, the ApplicationSet picked it up on its
next poll, and the seed job reported `players=6 confirmed=10 pending=1
disputed=1` before the page answered 200 under the wildcard certificate.
