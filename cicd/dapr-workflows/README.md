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
| shared `git-pat` (`_git-pat`) | `githubToken` | template-execution |
| shared `backstage-token` (`_backstage-token`) | `backstageToken` | template-execution |
| shared `homerun-pitch` (`_homerun-pitch`) | `homerunAuthToken` | cluster-build-watch, with `homerunPitchURL` |
| shared `machinery-grpc` (`_machinery-grpc`) | `machineryToken` | cluster-build-watch, with `machineryAuth.enabled` |

## Values

See `install/values.yaml`. Through the platform AppSet every knob is a cluster
label or annotation — see `platforms/cicd/appset-dapr-workflows.yaml` and
`platforms/cluster.reference.yaml`.
