# cicd/github-arc

GitHub Actions self-hosted runners (Actions Runner Controller, ARC) through our
own Crossplane packages from
[stuttgart-things/crossplane-configurations](https://github.com/stuttgart-things/crossplane-configurations)
(`cicd/github-arc-controller`, `cicd/github-runner-set`), as an opt-in cicd
platform (`platforms/cicd/appset-github-arc.yaml`, gate `cicd-platform/github-arc`).

| Application | Source | Renders |
|---|---|---|
| `<app>-secrets` | `cicd/externalsecrets` | Namespace `arc-runners` (CreateNamespace) + ExternalSecret → Secret `github-arc`, key `github_token` (wave -5) |
| `<app>` | `cicd/github-arc/resources` | wave -1: Configurations `github-arc-controller` + `github-runner-set`; wave 0: `GithubArcController` (release `github-controller` in `arc-systems`); wave 1: one `GithubRunnerSet` per repository |

Crossplane installs both charts on the cluster itself through the
`in-cluster` ClusterProviderConfig (helm.m.crossplane.io) from
`cicd/crossplane/provider-configs`, so the cluster needs the crossplane AppSets
(Crossplane, provider-helm, function-go-templating, function-auto-ready) --
which is why the AppSet also excludes `cicd-platform/crossplane: "false"`.

## Ordering

Everything that has to happen in order sits in ONE Application, so Argo's
sync-waves do the ordering rather than the timing of two Applications:

1. **wave -1** -- the two `Configuration`s. Argo's built-in health check for
   `*.crossplane.io` holds the sync until each reports `Healthy`, i.e. its XRD
   (and with it the XR CRD) is established.
2. **wave 0** -- the `GithubArcController` XR, **wave 1** -- the
   `GithubRunnerSet` XRs. On a first sync their CRDs do not exist yet, so the
   up-front dry-run would reject them: each carries
   `argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true`. The
   `syncPolicy.retry` covers the window between `Healthy` and the API server
   serving the new kind.

The XRs report no Argo health (no health check for
`resources.stuttgart-things.com`), so wave 1 does not wait for the controller
to be *running*. The runner sets therefore name the controller ServiceAccount
(`<releaseName>-gha-rs-controller` in `arc-systems`) instead of letting the
chart discover it by label -- that lookup fails while the controller is still
installing. The PAT Secret comes from the separate `-secrets` Application;
until it exists the listener fails and ARC retries.

The XRs live in `crossplane-system`, like the packages' examples (both XRDs are
namespaced). Not in `arc-runners`: deleting the runner namespace would take the
XRs and with them every runner set.

## Contract (cluster Secret)

| | key | value |
|---|---|---|
| label | `cicd-platform` | `"true"` |
| label | `cicd-platform/github-arc` | `"true"` (opt-in) |
| label | `cicd-platform/crossplane` | anything but `"false"` |
| annotation | `cicd-platform.stuttgart-things.com/github-arc-secret-store` | ClusterSecretStore with the PAT; falls back to `.../secret-store`; neither → the parent fails to render |
| annotation | `cicd-platform.stuttgart-things.com/github-arc-secret-key` | KV entry, default `_github-arc` (property `github_token`) |
| annotation | `cicd-platform.stuttgart-things.com/github-runner-repos` | comma-separated repositories in `stuttgart-things`, e.g. `docs,argocd`. Absent: controller only |
| annotation | `cicd-platform.stuttgart-things.com/storage-class` | runner work volume, default `openebs-hostpath` |

Each repository becomes the scale set `ghr-<repo>-<cluster>` -- also the Helm
release name and the **`runs-on:` label** (e.g. `runs-on: ghr-docs-labda-cicd-test1`).
Helm caps release names at 53 characters; a longer combination fails the
render. Repository names must be lowercase DNS labels (schema-checked).

## The PAT

One shared KV entry (default `_github-arc`), property `github_token`. A
**fine-grained** PAT, resource owner `stuttgart-things`, repository access to
every runner repository, permission **Administration: Read and write** (ARC
registers repository-level runners with it; Metadata: read is implied). An
expired or under-scoped token shows up as the listener failing to get a
registration token -- check `kubectl -n arc-systems logs` and the listener pod
in `arc-runners`.

## Upgrading -- CRDs are installed once

`resources/values.yaml` pins the ARC chart version (`arcVersion`, controller and
runner sets in lockstep: ARC supports only matching pairs), the runner image tag
and the two package versions, each with a renovate comment.

**Helm installs the ARC CRDs on the first install only and never upgrades
them.** After an `arcVersion` bump, apply the matching CRDs server-side by hand
-- a stale CRD silently prunes status fields the new controller writes (see the
[github-arc-controller README](https://github.com/stuttgart-things/crossplane-configurations/tree/main/cicd/github-arc-controller#upgrading)):

```bash
ARC_VERSION=0.15.0   # = arcVersion
BASE=https://raw.githubusercontent.com/actions/actions-runner-controller/gha-runner-scale-set-${ARC_VERSION}/charts/gha-runner-scale-set-controller/crds
for crd in ephemeralrunners ephemeralrunnersets autoscalingrunnersets autoscalinglisteners; do
  kubectl apply --server-side --force-conflicts -f "${BASE}/actions.github.com_${crd}.yaml"
done
```

Keep the runner image current: GitHub deprecates runner versions server-side,
and a deprecated runner exits 7 on every start (ARC phase `Outdated`).
