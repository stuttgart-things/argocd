# backstage-rag-postgres

A [CloudNativePG](https://cloudnative-pg.io) PostgreSQL with
[`pgvector`](https://github.com/pgvector/pgvector), dedicated to the Backstage
[Roadie RAG-AI plugin](https://github.com/RoadieHQ/rag-ai) for TechDocs/Catalog
embeddings. Port of `stuttgart-things/flux` `apps/backstage-rag-postgres`.

This is a **second**, optional Postgres. It does **not** touch Backstage's core
database (the bundled Bitnami Postgres in [`apps/backstage`](../backstage/)).

## Layout

```
apps/backstage-rag-postgres/
├── install/    app-of-apps: renders Application "backstage-rag-postgres-<hash>" (wave 5)
└── database/   leaf: Cluster, ExternalSecrets, ObjectStore + ScheduledBackup, Velero Schedule
```

## What gets deployed (into Backstage's namespace, default `portal`)

| Resource | When | Notes |
|---|---|---|
| `ExternalSecret/rag-postgres-creds` | `externalSecrets.enabled` (default) | basic-auth `username`/`password` for the owner role |
| `Cluster/rag-postgres` | always | 1 instance, pgvector image, DB `backstage_rag` owned by `rag`, `CREATE EXTENSION vector` + `uuid-ossp`, 5Gi. `Prune=false,Delete=false` (`protect`) |
| `ExternalSecret/rag-postgres-s3-creds` | `backup.enabled` + `externalSecrets.enabled` | `ACCESS_KEY_ID`/`SECRET_ACCESS_KEY` (+ CA from `backup.caConfigMap`) |
| `ObjectStore/rag-postgres`, `ScheduledBackup/rag-postgres-daily` | `backup.enabled` | Barman Cloud plugin: WAL archiving + daily base backup (`0 0 2 * * *`, six fields) |
| `Schedule/backstage-rag-postgres` (ns `velero`) | `veleroSchedule.enabled` | Velero backup of the K8s objects labelled `backup=backstage-rag-postgres` |

## Prerequisites

- CNPG operator: [`infra/cloudnative-pg/install`](../../infra/cloudnative-pg/install/) (`storage-platform/cloudnative-pg: "true"`)
- For backups: the Barman Cloud plugin [`infra/cloudnative-pg/barman-cloud`](../../infra/cloudnative-pg/barman-cloud/) (`storage-platform/cloudnative-pg-barman: "true"`), a pre-created bucket and a bucket-scoped key pair
- For `veleroSchedule`: Velero (`storage-platform/velero: "true"`)
- external-secrets and a ClusterSecretStore that can read the entries
- The operand image `ghcr.io/stuttgart-things/postgresql-pgvector:16`, built from
  `stuttgart-things/flux` `apps/backstage-rag-postgres/image/Dockerfile`. The kubelet
  pulls it, so the GHCR package must be **public** (or add an imagePullSecret).

## Values

| Value | Default | Notes |
|---|---|---|
| `applicationName` | `backstage-rag-postgres-<sha8(destination)>` | |
| `project` | `default` | |
| `catalog.{repoURL,targetRevision}` | this repo / `HEAD` | where the leaf chart is loaded from |
| `destination.{server\|name,namespace}` | in-cluster / `portal` | namespace = Backstage's |
| `name` | `rag-postgres` | Cluster name -> Services `<name>-rw/-ro/-r` |
| `instances` | `1` | no HA |
| `image.{repository,tag}` | `ghcr.io/stuttgart-things/postgresql-pgvector` / `16` | |
| `storage.{size,storageClass}` | `5Gi` / `nfs4-csi` | empty class = cluster default |
| `resources` | 100m/256Mi req, 1/1Gi lim | |
| `bootstrap.{database,owner,secretName}` | `backstage_rag` / `rag` / `rag-postgres-creds` | |
| `protect` | `true` | Prune/Delete off on the Cluster |
| `externalSecrets.enabled` | `true` | `false` = bring your own Secrets |
| `externalSecrets.secretStore.{kind,name}` | `ClusterSecretStore` / `vault-cluster` | |
| `externalSecrets.credentials.remoteKey` | `""` -> `kv/data/<ns>/rag-postgres` | properties `username`, `password` |
| `externalSecrets.s3.remoteKey` | `""` -> `kv/data/<ns>/rag-postgres-s3` | properties `access_key`, `secret_key` |
| `backup.enabled` | `false` | restarts the pod on an existing Cluster |
| `backup.endpointURL` | `""` | required when enabled |
| `backup.bucket` | `backstage-rag-backups` | -> `s3://<bucket>/` |
| `backup.retentionPolicy` / `schedule` / `immediate` | `7d` / `0 0 2 * * *` / `true` | set `immediate: false` when enabling on an existing Cluster |
| `backup.s3SecretName` | `rag-postgres-s3-creds` | |
| `backup.caConfigMap` / `caKey` | `""` / `trust-bundle.pem` | lab-PKI endpoints |
| `veleroSchedule.{enabled,namespace,cron,ttl,storageLocation}` | `false` / `velero` / `0 1 * * *` / `168h0m0s` / `default` | |
| `syncPolicy` | automated, SSA, retry 5 | |

The empty `remoteKey` defaults keep the Flux paths, which only resolve against a
store *without* a mount path. Per-cluster `vault-<cluster>` stores are mounted on
their KV path and want flat entry names; the platform AppSet passes
`rag-postgres` / `rag-postgres-s3`.

## Pointing Backstage at it

CNPG creates `rag-postgres-rw` (primary), `-ro` and `-r`. The RAG plugin connects to:

```
host:     rag-postgres-rw.<namespace>.svc.cluster.local
port:     5432
database: backstage_rag
user/pw:  from Secret rag-postgres-creds (username / password)
```

[`apps/backstage/install`](../backstage/install/) does **not** wire this yet: its
`extraEnvVars` list is computed and `extraValues` replaces lists rather than
appending to them. Until that chart grows a RAG option, the plugin's DB settings go
into the Backstage app-config (the `backstage-app-config` ConfigMap or the
out-of-band catalog ConfigMap), with the password from `rag-postgres-creds`. On the
first rollout Backstage starts before this database exists. Restart it once when
the Cluster is healthy: `kubectl -n portal rollout restart deploy/backstage-deployment`.

## Platform

`platforms/storage/appset-backstage-rag-postgres.yaml`, opt-in with
`storage-platform/backstage-rag-postgres: "true"` plus `storage-platform/cloudnative-pg: "true"`.

## Verify

```bash
kubectl -n portal get cluster rag-postgres                 # Cluster in healthy state
kubectl -n portal get externalsecret                       # SecretSynced=True
kubectl -n portal exec -it rag-postgres-1 -- psql -U rag -d backstage_rag -c "\dx vector"
kubectl -n portal get backup                               # with backups: phase completed
kubectl -n portal get cluster rag-postgres -o jsonpath='{.status.conditions}'  # ContinuousArchiving=True
```

## Restore

CNPG restores into a **new** Cluster from the object store (`bootstrap.recovery`
plus an `externalClusters` entry using the `barman-cloud.cloudnative-pg.io` plugin,
`barmanObjectName: rag-postgres`, `serverName: rag-postgres`). This chart has no
recovery switch. Do not let a recovered Cluster archive under the same `serverName`
it replays from. See [`apps/schmetterpause/database`](../schmetterpause/database/)
for a fully wired recovery path.
