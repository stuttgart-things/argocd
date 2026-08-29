# infra/cloudnative-pg

Catalog entry for [**CloudNativePG**](https://cloudnative-pg.io/) — the PostgreSQL operator — plus the official [`cnpg/cluster`](https://github.com/cloudnative-pg/charts/tree/main/charts/cluster) chart that renders a `postgresql.cnpg.io/v1` `Cluster`. Both sub-entries are **app-of-apps Helm charts**: consumers create one ArgoCD `Application` pointing at a sub-entry, and it renders the child `Application` that installs the upstream chart from <https://cloudnative-pg.github.io/charts>.

Port of the Helmfile definitions in [`stuttgart-things/helm`](https://github.com/stuttgart-things/helm) (`database/postgres.yaml.gotmpl`, `database/postgres-cluster.yaml.gotmpl`, merged in [helm#161](https://github.com/stuttgart-things/helm/pull/161)). The `environments.default.values` blocks there map to first-class values here.

## Why this exists

Three catalog entries carry their own bundled PostgreSQL, and all three are on a path that is closing:

| Entry | How it gets Postgres today |
|---|---|
| [`apps/backstage/install`](../../apps/backstage/install/) | bundled Bitnami StatefulSet (`postgresql.enabled`), password via the `backstage-secrets` Secret |
| [`apps/zitadel/install`](../../apps/zitadel/install/) | bundled Bitnami subchart of the upstream ZITADEL chart, credentials via ESO from Vault |
| [`apps/harbor/install`](../../apps/harbor/install/) | bundled, image pinned to `bitnamilegacy/postgresql` |

The `bitnamilegacy` pin is a deprecation shim for the Bitnami wind-down, and `apps/zitadel/install/values.yaml` already tells you in its own comment to point ZITADEL at managed PostgreSQL for production. The catalog has been routing around the absence of a managed Postgres three times; this entry is the shared answer.

**Migrating those three is deliberately out of scope.** Moving them off their bundled StatefulSets means data movement and a per-app credentials rewire — its own change, not a rider on this one. This entry is what makes it possible later.

`infra/` rather than `apps/` because CNPG is a *dependency* of other catalog entries, which puts it alongside `external-secrets` and `cert-manager`. [`apps/redis-stack`](../../apps/redis-stack/) is a surface-level analog (stateful data service, persistence, a password) but it is a leaf — nothing in the catalog consumes it.

## Layout

```
infra/cloudnative-pg/
├── install/                        the operator — one per cluster
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── values.schema.json
│   └── templates/
│       └── chart.yaml              renders Application "cloudnative-pg-<hash>" (sync-wave -10)
└── cluster/                        one PostgreSQL Cluster CR — N per cluster
    ├── Chart.yaml
    ├── values.yaml
    ├── values.schema.json
    └── templates/
        └── chart.yaml              renders Application "cnpg-cluster-<hash>" (sync-wave 0)
```

Split because the lifecycles genuinely differ: **one operator per cluster, N databases against it**. A consumer already running the operator can take `cluster/` alone, and `cluster/` is instantiable more than once per cluster (the derived Application name hashes `clusterName` *and* the destination, so two databases on one cluster don't collide).

## What gets deployed

### `install/` — the operator

One child `Application` pointing at `https://cloudnative-pg.github.io/charts`, chart `cloudnative-pg` at `.Values.chartVersion` (**0.29.0**, app **1.30.0**). Installs the operator Deployment, its webhooks, RBAC, and **11 CRDs** (`clusters`, `poolers`, `backups`, `scheduledbackups`, `databases`, `publications`, `subscriptions`, `imagecatalogs`, `clusterimagecatalogs`, `databaseroles`, `failoverquorums` — all `.postgresql.cnpg.io`).

The computed `valuesObject` is deliberately thin — `replicaCount`, `monitoring.podMonitorEnabled`, `resources`. Everything else goes through `extraValues`.

**Namespace deviation:** `destination.namespace` defaults to **`postgres`**, matching `stuttgart-things/helm`'s `database/postgres.yaml.gotmpl`. Upstream's own convention is `cnpg-system`. Consistency across the two sibling repos won here, and it is a one-value override either way — don't "fix" it.

### `cluster/` — the `Cluster` CR

One child `Application` pointing at the same repo, chart `cluster` at `.Values.chartVersion` (**0.8.1**). This is the *official* CNPG chart for the CR — the catalog does not hand-roll a `postgresql.cnpg.io/v1` `Cluster` template.

The computed `valuesObject` maps catalog values onto the upstream keys:

| Catalog value | Upstream key |
|---|---|
| `clusterName` | `nameOverride` + `fullnameOverride` (and the child Application's `releaseName`) |
| `type` / `mode` | `type` / `mode` |
| `postgresqlVersion` | `version.postgresql` |
| `instances` | `cluster.instances` |
| `storage.{size,storageClass}` | `cluster.storage.*` |
| `walStorage.{enabled,size}` | `cluster.walStorage.*` |
| `database` / `owner` | `cluster.initdb.database` / `cluster.initdb.owner` |
| `appSecretName` | `cluster.initdb.secret.name` — **emitted only when non-empty** |
| `enableSuperuserAccess` / `enablePDB` | `cluster.enableSuperuserAccess` / `cluster.enablePDB` |
| `monitoring.{enabled,podMonitor,prometheusRule}` | `cluster.monitoring.{enabled,podMonitor.enabled,prometheusRule.enabled}` |
| `backups.enabled` | `backups.enabled` |
| `extraValues` | deep-merged over all of the above |

Defaults are **lab-shaped**, matching the Helmfile. Two things to read before using them in anger:

- **`instances: 1` means an instance failure is downtime and possible data loss.** There is no replica to fail over to. Raise to `3` for anything you care about (and turn on `enablePDB` with it).
- **`backups.enabled: false`**, so the upstream chart prints `Warning! Backups not enabled. Recovery will not be possible!` on every sync. It is telling the truth. Enabling backups needs an object-store target — configure the rest of `backups.*` through `extraValues`.

Leaving `appSecretName` empty is the normal path: CNPG then generates `<clusterName>-app`, a `kubernetes.io/basic-auth` Secret carrying `username` / `password` / `dbname`. An *empty* `secret.name` reaching the upstream chart breaks bootstrap, which is why the template omits the key entirely rather than passing `""`.

One template-level trap worth knowing: upstream runs `cluster.initdb.owner` through `tpl`, so a literal `{{ … }}` in that value gets evaluated by the upstream chart. The schema forbids braces in `owner` to stop a computed value leaking them in.

## Sync waves and ordering

`install/` carries **`sync-wave: "-10"`** — matching cert-manager, crossplane, external-secrets and kyverno — because the CRDs must register before any `Cluster` CR is applied. `cluster/` carries **`"0"`**.

**Sync waves only order resources within one Argo `Application`.** A consumer taking both sub-entries in one aggregator gets the ordering for free. A consumer syncing `cluster/` against a cluster with no operator installed sees the child app fail its dry-run on the unknown `postgresql.cnpg.io/v1` kind — that is expected, and the `retry` block (limit 5, exponential backoff to 3m) is what recovers it once the operator lands. Keep the retry block; it is load-bearing, not boilerplate.

`syncOptions` for both: `CreateNamespace=true`, `ServerSideApply=true`. **`ServerSideApply` is not optional here** — the `clusters.postgresql.cnpg.io` CRD is far past the 262144-byte limit for the `kubectl.kubernetes.io/last-applied-configuration` annotation, so a client-side apply fails outright. If SSA still trips on CRD updates across a major operator bump, add `Replace=true` the way [`cicd/kro/install`](../../cicd/kro/) does.

## Consumer usage

Operator once per cluster:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cloudnative-pg
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: infra/cloudnative-pg/install
    helm:
      values: |
        project: my-cluster
        destination:
          server: https://<cluster-api>:6443
          namespace: postgres
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

Then one `Application` per database, **in the consuming app's namespace**:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: backstage-db
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: infra/cloudnative-pg/cluster
    helm:
      values: |
        project: my-cluster
        destination:
          server: https://<cluster-api>:6443
          namespace: backstage          # NOT the operator's namespace
        clusterName: backstage-db
        instances: 3
        enablePDB: true
        storage:
          size: 20Gi
          storageClass: openebs-hostpath
        database: backstage
        owner: backstage
        appSecretName: backstage-db-app  # materialised by ESO — see below
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

The `Cluster` exposes three Services in its namespace: `<clusterName>-rw` (primary), `<clusterName>-ro` (replicas), `<clusterName>-r` (any instance).

## Values reference

### `install/`

| Key | Default | Purpose |
|---|---|---|
| `project` | `default` | AppProject for the rendered Application |
| `applicationName` | derived | Explicit child Application name; defaults to `cloudnative-pg-<sha1(destination)[:8]>` |
| `destination.server` / `.name` | `https://kubernetes.default.svc` / — | Target cluster (URL or registered name; `name` wins when both are set) |
| `destination.namespace` | `postgres` | Operator namespace — deviates from upstream's `cnpg-system` on purpose |
| `chartVersion` | `0.29.0` | Upstream `cnpg/cloudnative-pg` chart version |
| `replicaCount` | `1` | Operator Deployment replicas (leader-elected — >1 buys failover, not throughput) |
| `monitoring.podMonitorEnabled` | `false` | PodMonitor for the *operator* pod; needs Prometheus Operator CRDs |
| `resources` | `{}` | Requests/limits for the operator container |
| `extraValues` | `{}` | Deep-merged on top of the computed upstream `valuesObject` |
| `syncPolicy` | automated + retry | Applied to the rendered Application |

### `cluster/`

| Key | Default | Purpose |
|---|---|---|
| `project` | `default` | AppProject for the rendered Application |
| `applicationName` | derived | Explicit child Application name; defaults to `cnpg-cluster-<sha1(clusterName@destination)[:8]>` |
| `destination.server` / `.name` | `https://kubernetes.default.svc` / — | Target cluster (URL or registered name) |
| `destination.namespace` | `cnpg-cluster` (**placeholder — override**) | Namespace for the `Cluster`. See the warning below |
| `chartVersion` | `0.8.1` | Upstream `cnpg/cluster` chart version |
| `clusterName` | `postgres-cluster` | Name of the `Cluster` CR; also the child Helm `releaseName` |
| `type` | `postgresql` | `postgresql` \| `postgis` \| `timescaledb` |
| `mode` | `standalone` | `standalone` \| `recovery` \| `replica` (the latter two need `extraValues`) |
| `postgresqlVersion` | `"17"` | Major PostgreSQL version (string) |
| `instances` | `1` | Instance count — **1 has no failover** |
| `storage.size` / `.storageClass` | `8Gi` / `""` | PGDATA volume; empty class = cluster default SC |
| `walStorage.enabled` / `.size` | `false` / `1Gi` | Separate WAL volume |
| `database` / `owner` | `app` / `app` | initdb database and owner role (`owner` may not contain `{}`) |
| `appSecretName` | `""` | Existing `kubernetes.io/basic-auth` Secret; empty = CNPG generates `<clusterName>-app` |
| `enableSuperuserAccess` | `false` | Off = the `postgres` password is blanked; the owner role is the only way in |
| `enablePDB` | `false` | Off because a PDB blocks node drains on a single-instance cluster |
| `monitoring.enabled` / `.podMonitor` / `.prometheusRule` | `false` | Prometheus Operator integration for the PostgreSQL pods |
| `backups.enabled` | `false` | See the warning above — no backups means no recovery |
| `extraValues` | `{}` | Deep-merged on top of the computed upstream `valuesObject` |
| `syncPolicy` | automated + retry | Applied to the rendered Application |

> **`destination.namespace` is the value you are most likely to get wrong.** A CNPG `Cluster` belongs in the namespace of the app that consumes it — backstage's cluster in `backstage`, zitadel's in `zitadel` — not in the operator's namespace. There is no good default, so the schema marks it `required` and `values.yaml` carries an inert placeholder (`cnpg-cluster`) purely so the chart renders standalone. Because Helm deep-merges maps, a consumer who overrides only `destination.server` silently inherits that placeholder. **Set it explicitly.**

## Secret management

Same three options as [`apps/redis-stack`](../../apps/redis-stack/README.md#secret-management) — ArgoCD Vault Plugin, SOPS + AVP, or ApplicationSet `valuesObject` templating. Since the catalog already ships [`infra/external-secrets/cluster-secret-store-vault`](../external-secrets/) and [`apps/zitadel/external-secrets`](../../apps/zitadel/) is a working precedent for exactly this shape, the cleanest story is:

1. ESO materialises a `kubernetes.io/basic-auth` Secret in the app's namespace, with `username` and `password` keys.
2. `appSecretName` points at it.
3. CNPG uses it as the owner's credentials at bootstrap instead of generating its own.

If you skip all of that and leave `appSecretName` empty, CNPG generates `<clusterName>-app` and the consuming app reads the password from there — fine for a lab, but the credential then lives only in the cluster.

**Never commit a literal password.**

## Teardown caveat

Deleting the Argo `Application` removes the Helm release but **not** the PVC, the namespace, or the CNPG CRDs. Verified during testing. A full teardown is:

```bash
kubectl -n <ns> delete pvc <clusterName>-1
kubectl delete crd clusters.postgresql.cnpg.io poolers.postgresql.cnpg.io \
  backups.postgresql.cnpg.io scheduledbackups.postgresql.cnpg.io \
  databases.postgresql.cnpg.io publications.postgresql.cnpg.io \
  subscriptions.postgresql.cnpg.io imagecatalogs.postgresql.cnpg.io \
  clusterimagecatalogs.postgresql.cnpg.io databaseroles.postgresql.cnpg.io \
  failoverquorums.postgresql.cnpg.io
```

PVC-survives-deletion is a **feature for a database, not a bug** — it is what keeps a fat-fingered `Application` delete from destroying data. The corollary is the sharp edge: `prune: true` will not save you from an accidental `clusterName` rename. A rename creates a *new* `Cluster` with a *new* empty PVC and orphans the old one, still holding your data, still costing storage.

## Verified upstream behaviour

Both charts were exercised on a live RKE2 cluster (v1.35.3, `openebs-hostpath` as default SC):

- fresh install reaches `Cluster in healthy state`, PostgreSQL 17.11, `app` database and `app` owner created, `-rw` / `-ro` / `-r` Services present;
- the operator upgrades **in place** 1.26.0 → 1.30.0 with a running cluster, and the cluster returns to healthy on its own.

## Known tension

`cluster/` strains the catalog's stated contract. The [root README](../../README.md) says the catalog holds WHAT and clusters bring WHERE and HOW — and a `Cluster` CR carrying `database` / `owner` / `appSecretName` is closer to HOW. [`apps/redis-stack`](../../apps/redis-stack/) already bends the same way (password, persistence and sentinel topology all live in the catalog entry), so there is precedent. It is still a bend, and it is named here rather than discovered later.

## Related

- Upstream charts: <https://github.com/cloudnative-pg/charts> (`cloudnative-pg`, `cluster`)
- CloudNativePG docs: <https://cloudnative-pg.io/documentation/current/>
- Helmfile equivalents: [`stuttgart-things/helm`](https://github.com/stuttgart-things/helm) — `database/postgres.yaml.gotmpl`, `database/postgres-cluster.yaml.gotmpl`
