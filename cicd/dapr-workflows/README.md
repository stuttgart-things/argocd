# cicd/dapr-workflows

The dapr workflow workers as an Argo CD app-of-apps — what `cicd-machinery-test5`
runs through Flux (`apps/dapr` in stuttgart-things/flux), so a Backstage-built
cluster can take it over (stuttgart-things/stuttgart-things#3796,
stuttgart-things/argocd#658).

| Application | Source | Namespace | Renders |
|---|---|---|---|
| `<app>-redis` | `apps/redis-stack/install` | `dapr-redis` | redis (sentinel, one replica) — dapr state store for both workers |
| `<app>-secrets-<ns>` | `cicd/externalsecrets` | per namespace | ExternalSecrets, see below |
| `<app>-template-execution` | OCI `dapr-backstage-template-execution-kustomize` | `backstage-workflows` | worker that runs Backstage scaffolder templates (`request-vm` → `create-terraform-vm`) and follows the GitHub Actions run |
| `<app>-template-execution-trigger` | same artifact, `<tag>-trigger` | cluster | kro RGD `backstage-template-run` (kind `BackstageTemplateRun`) |
| `<app>-template-execution-runs` | git, `templateExecution.runs.path` (only when set) | `backstage-workflows` | the `BackstageTemplateRun` files `request-vm` / `request-vm-deletion` commit; the merge is the approval. The repo is private: the Argo CD cluster needs a repository Secret for it |
| `<app>-cluster-build-watch` | OCI `dapr-cluster-build-watch-kustomize` | `cluster-build-watch` | worker that follows a cluster build and reports each checkpoint |
| `<app>-cluster-build-watch-trigger` | same artifact, `<tag>-trigger` | cluster | kro RGD `cluster-build-watch` (kind `ClusterBuildWatch`) |

Patched onto the OCI bases (the same changes the Flux components make):
the image tag, the dapr statestore host (`redis-stack.<redis ns>`), the
placeholder Secrets removed (ESO is the only writer), the template worker's CA
pointed at trust-manager's `cluster-trust-bundle`, its sidecar listening on
`0.0.0.0` (the trigger Job curls it), and for cluster-build-watch the optional
homerun sink and machinery gRPC auth.

## Prerequisites on the cluster

- dapr and kro (`appset-dapr`, `appset-kro` in `platforms/cicd`)
- trust-manager's `cluster-trust-bundle` ConfigMap in the worker namespaces
- ESO stores for the entries below. In the AppSecretProfile shape (what a
  ClusterStack derives): the worker's own entry plus SHARED entries, each in its
  own mount with its own store (`secrets.shared.*.clusterSecretStoreName`,
  `""` = the own store).

| entry | property | used by |
|---|---|---|
| own (`secrets.vaultSecretName`) | `redisPassword` (generated) | redis, both workers |
| shared `github-merge` (`_github-merge`; before: `git-pat`) | `githubToken` | template-execution -- merges the VM PRs: fine-grained PAT with Contents RW, Pull requests RW, Actions R |
| shared `backstage-token` (`_backstage-token`) | `backstageToken` | template-execution |
| shared `homerun-pitch` (`_homerun-pitch`) | `homerunAuthToken` | cluster-build-watch, with `homerunPitchURL` |
| shared `machinery-grpc` (`_machinery-grpc`) | `machineryToken` | cluster-build-watch, with `machineryAuth.enabled` |

## Discovery (cluster-build-watch)

`clusterBuildWatch.discovery.enabled` (annotation
`cicd-platform.stuttgart-things.com/cluster-build-watch-discovery: "true"`)
makes the worker list the ClusterStacks on `discovery.server` and start a
build watch for every new order and a teardown watch for every deleting stack
(stuttgart-things/stuttgart-things#3831, dapr-workflows#60) -- nobody writes a
`ClusterBuildWatch` per order.

- **One cluster per fleet.** Two workers with discovery on the same machinery
  send every card twice.
- The machinery needs the ClusterStack info field `UID` (flux
  `cicd/machinery/watch-config.yaml`, v1.168.0+); without it every stack is
  skipped and the worker log says so.
- It uses the machinery token of `machineryAuth` -- on when the cluster has the
  shared `machinery-grpc` entry.
- Opt-out per stack: `discovery.exclude` (annotation `...-discovery-exclude`,
  `<namespace>/<name>` globs). An annotation on the ClusterStack itself does
  not work yet (stuttgart-things/machinery#104).

## Values

See `install/values.yaml`. Through the platform AppSet every knob is a cluster
label or annotation — see `platforms/cicd/appset-dapr-workflows.yaml` and
`platforms/cluster.reference.yaml`.
