# apps/redis-stack

Catalog entry for the stuttgart-things [`redis`](https://github.com/stuttgart-things/charts) Helm chart, configured as **Redis Stack** — bundles RediSearch, RedisJSON, RedisTimeSeries, and RedisBloom modules loaded via a merged start-script. Packaged as an **app-of-apps Helm chart**: consumers create one ArgoCD `Application` pointing at `apps/redis-stack/install` and the chart renders the child `Application` that installs the upstream OCI chart with the Stack-specific `extraDeploy` ConfigMap + master/replica args wired in.

Port of [`stuttgart-things/flux` — `apps/redis-stack`](https://github.com/stuttgart-things/flux/tree/main/apps/redis-stack). The flux version's `postBuild.substitute` variables map to first-class values here.

## Layout

```
apps/redis-stack/
└── install/                        app-of-apps Helm chart (what consumers point at)
    ├── Chart.yaml
    ├── values.yaml
    ├── values.schema.json
    └── templates/
        └── chart.yaml              renders Application "redis-stack" (sync-wave 0)
```

## What gets deployed

A single Argo CD `Application` pointing at `oci://ghcr.io/stuttgart-things/charts/redis` at `.Values.chartVersion`. The install chart constructs the upstream `valuesObject`:

- `image.{registry,repository,tag}` — defaults to the stuttgart-things `redis-stack-server` mirror (Redis + RediSearch + RedisJSON + RedisTimeSeries + RedisBloom in one image)
- `global.redis.password` — root password (inline only for dev; prefer an ArgoCD Vault Plugin / SOPS overlay)
- `sentinel.*` — HA sentinel sidecar (enabled by default); service type, masterSet, quorum, parallelSyncs, image
- `master` + `replica` — persistence config + custom `args` pointing at `start-master.sh` / `start-replica.sh` + `extraVolumes`/`extraVolumeMounts` for the merged-start-scripts ConfigMap
- `extraDeploy` — inlines the `bitnami-redis-stack-server-merged` ConfigMap containing the start-scripts that invoke `redis-server --loadmodule` for each of the four Redis Stack modules
- `.Values.extraValues` — deep-merged on top as an escape hatch for any upstream key

## Consumer usage

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: redis-stack
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: apps/redis-stack/install
    helm:
      values: |
        project: my-cluster
        destination:
          server: https://<cluster-api>:6443
          namespace: redis-stack
        chartVersion: 17.1.4
        auth:
          password: ${REDIS_STACK_PASSWORD}
        persistence:
          enabled: true
          storageClass: nfs4-csi
          size: 8Gi
        sentinel:
          enabled: true
          serviceType: ClusterIP
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

## Values reference

| Key | Default | Purpose |
|---|---|---|
| `project` | `default` | AppProject for the rendered Application |
| `destination.server` | `https://kubernetes.default.svc` | Target cluster API |
| `destination.namespace` | `redis-stack` | Namespace for Redis |
| `chartVersion` | `17.1.4` | Upstream stuttgart-things/redis OCI chart version |
| `auth.password` | empty | Root Redis password (use ArgoCD Vault Plugin / SOPS — not inline) |
| `image.registry` / `repository` / `tag` | `ghcr.io` / `stuttgart-things/redis-stack-server` / `7.2.0-v18` | Redis Stack server image |
| `sentinel.enabled` | `true` | Enable the sentinel sidecar (HA) |
| `sentinel.serviceType` | `ClusterIP` | Sentinel service type |
| `sentinel.image.*` | `ghcr.io/stuttgart-things/redis-sentinel:7.4.2-debian-12-r9` | Sentinel image |
| `persistence.enabled` / `storageClass` / `size` | `true` / `standard` / `8Gi` | StatefulSet persistence |
| `replicaCount` | `1` | Replica StatefulSet size |
| `extraValues` | `{}` | Deep-merged on top of the computed upstream `valuesObject` |
| `syncPolicy` | automated + retry | Applied to the rendered Application |

## Secret management

The flux version loads `REDIS_STACK_PASSWORD` from a SOPS-encrypted Secret via `substituteFrom`. In the Argo CD world, pass the password through either:

- **ArgoCD Vault Plugin** — reference `<path:vault/data/redis#password>` in `helm.values` and let the plugin resolve it at sync time
- **SOPS + argocd-vault-plugin** — same pattern, different backend
- **ApplicationSet with `valuesObject` templating** — pull from a cluster-secret key

Never commit the literal password into git.

## Related

- Flux equivalent: [`stuttgart-things/flux` — `apps/redis-stack`](https://github.com/stuttgart-things/flux/tree/main/apps/redis-stack)
- Upstream chart: <https://github.com/stuttgart-things/charts> (`charts/redis`)
- Redis Stack docs: <https://redis.io/docs/stack/>
