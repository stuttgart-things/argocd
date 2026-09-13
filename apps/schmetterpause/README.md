# apps/schmetterpause

Catalog entry for **schmetterpause** — the Argo CD replacement for the `task kcl:up`
hand-apply path in [`stuttgart-things/schmetterpause`](https://github.com/stuttgart-things/schmetterpause)
`docs/deployment.md`. Hand-apply gives you no drift detection and no prune; this gives you both.

## Layout

```
apps/schmetterpause/
├── install/        app-of-apps chart (what consumers point at) — renders:
│                     Application "schmetterpause"     (sync-wave   0) → the published kustomize OCI, environment patched in
│                     Application "schmetterpause-db"  (sync-wave -10) → apps/schmetterpause/database
└── database/       CloudNativePG Cluster
```

## Why the database is a separate chart

CI publishes the rendered kustomize base to
`ghcr.io/stuttgart-things/schmetterpause-kustomize`, and that artefact is deliberately
environment-neutral: eight resources — ConfigMap, Deployment, two ExternalSecrets, two
HTTPRoutes, Service, ServiceAccount. It contains **no** CNPG `Cluster`, because every value
of one is a property of the cluster it lands on (storage class, size, instances). So the
environment supplies it, from `database/`, as its own Application one sync-wave earlier —
the app's Deployment mounts the Secret the database bootstraps from.

## What the environment patches

Five patches, all of them places where the base names a placeholder:

| Base ships | Patched to |
|---|---|
| `parentRefs.name: gateway` on both routes | `.Values.gateway.name` / `.namespace` |
| `schmetterpause.cluster.example.com` (2 routes + `SP_PUBLIC_BASE_URL`) | `.Values.hostname` |
| `secretStoreRef.name: vault-cluster` on both ExternalSecrets | `.Values.secretStore.name` / `.kind` |

The listener names come from `gateway.sectionNameHTTPS` / `sectionNameHTTP`. The patches
replace `parentRefs` wholesale, so they have to be repeated — and getting them wrong is the
quiet kind of wrong: both routes attach to *every* listener and the redirect sends HTTPS
back to HTTPS, a loop with nothing red anywhere.

The image is **not** patched. CI tags the artefact and the container image with the same
commit SHA and bakes that reference into the Deployment, so `version` pins both.

The Vault entry name is not patched either: the ClusterSecretStore carries the KV mount and
the base asks for the entry `schmetterpause` under it.

## Application names

`applicationName` defaults to empty, which derives `schmetterpause-<sha1(destination)[:8]>`.
Both Applications live in the `argocd` namespace of **one** management cluster, so a fixed
name would make two clusters' deployments of this app collide on the same object. The
catalog verifier fails a chart whose names do not vary with the destination (argocd#41) —
it caught exactly that in the first version of this chart. Set `applicationName` explicitly
when the entry is used for a single cluster and you want a readable name.

## Pinning

`version` pins the published kustomize artefact — and with it the application, because CI
gives artefact and image the same tag and bakes the image reference into the Deployment.

Upstream is **pre-1.0**, and that changes what a bump means here. The patch surface this
chart drives — gateway name, hostname in three places, both `secretStoreRef`s, the two
listener names — *is* the interface between the two repositories, and it is still moving.
Under `0.x` a rename in it is a **minor** bump, not a major. `renovate.json` therefore keeps
`schmetterpause` and `schmetterpause-kustomize` out of the shared `stuttgart-things images`
group and off auto-merge, so such a bump arrives as its own reviewable PR rather than inside
a batch title. Fold them back in once upstream reaches 1.0.0.

## The database is not prunable, on purpose

The CNPG `Cluster` carries `argocd.argoproj.io/sync-options: Prune=false,Delete=false`
(`database.protect`, on by default). The PVC has an ownerReference to the Cluster and CNPG
has no retention flag, so deleting the Cluster garbage-collects the volume — and two
ordinary GitOps events reach that: the resource falling out of the render, or the
Application being deleted and its `resources-finalizer` cascading. The annotation sits on
the resource rather than the Application, so the protection travels with the object instead
of depending on how a consumer wires its sync policy. The price: this database has to be
removed by hand.

The same reasoning is why the published artefact ships no `Cluster` at all — the upstream
`kcl/database.k` is a separate entry point precisely so that no value anyone sets can put
one into the base.

## Cluster preconditions

- **CNPG operator** — `infra/cloudnative-pg/install`; without it the `Cluster` CRD is absent
  and the database Application fails to sync.
- **A ClusterSecretStore** over the Vault mount holding the `schmetterpause` entry
  (`session-key`, `username`, `password`) — `infra/external-secrets/cluster-secret-store-vault`.
- **A Gateway** with an `http` and an `https` listener whose hostname covers `.Values.hostname`.
- On a cluster with more than one default StorageClass, `database.storage.storageClass` must
  be set explicitly.

## Consumer usage

```yaml
    helm:
      values: |
        project: my-cluster
        destination:
          name: my-cluster
          namespace: schmetterpause
        version: 59ec952
        hostname: schmetterpause.my-cluster.example.com
        gateway:      { name: my-cluster-gateway, namespace: default }
        secretStore:  { kind: ClusterSecretStore, name: vault-schmetterpause }
        database:
          enabled: true
          storage: { size: 8Gi, storageClass: openebs-hostpath }
```

Real example: `clusters/labul/vsphere/platform-sthings/argocd/homerun2-test1/schmetterpause.yaml`
in `stuttgart-things/stuttgart-things`, whose environment profile (and the reasoning behind
every value) lives next to it in `argocd/clusters/homerun2-test1/schmetterpause-profile.yaml`.

## Backups

`database.backup` switches on continuous WAL archiving and a daily base backup through the Barman Cloud plugin: an `ExternalSecret` (S3 key pair plus the CA copied from `cluster-trust-bundle`), an `ObjectStore`, a `ScheduledBackup` with `method: plugin`, and `spec.plugins` on the Cluster. Off by default.

Not the in-tree `spec.backup.barmanObjectStore`: CloudNativePG 1.30 deprecates it and 1.31.0 removes it.

**Preconditions:** `infra/cloudnative-pg/barman-cloud` on the cluster (without the `ObjectStore` CRD the database Application does not sync), a bucket, and a secret-store entry with the key pair — its own entry, not the app's.

```yaml
        database:
          backup:
            enabled: true
            endpointURL: https://artifacts.example.com
            destinationPath: s3://schmetterpause-cnpg/
            remoteKey: schmetterpause-backup
            # secretStore defaults to the top-level one
```

**Switching it on restarts the Postgres pod** — do it outside the hours the database is used. `immediate` stays `false` for the same reason; take the first backup by hand once archiving runs.

**It works when two things are true**, and a green sync says neither:

```bash
kubectl -n schmetterpause get cluster schmetterpause-db \
  -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].status}'   # True
kubectl -n schmetterpause get backups.postgresql.cnpg.io                          # a completed one
```

**Restore** is a new Cluster bootstrapped from the object store, into an empty namespace — never an in-place overwrite: an `ExternalSecret` and `ObjectStore` like the ones above, then a `Cluster` with `bootstrap.recovery.source` naming an `externalClusters` entry that uses the plugin with `barmanObjectName` and `serverName: schmetterpause-db`. Set `storage.storageClass` explicitly, and give the restored Cluster **no** WAL archiver on the same `serverName` — two clusters archiving into one path corrupt each other's timeline.
