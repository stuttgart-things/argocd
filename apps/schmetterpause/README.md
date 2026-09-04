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

`sectionName` is **not** configurable: the main route belongs on the Gateway's `https`
listener and the redirect on `http`. The patches replace `parentRefs` wholesale, so both
repeat it — drop it and the redirect route would attach to every listener, redirecting
HTTPS to HTTPS.

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

`version` is a commit SHA and carries **no** `# renovate:` comment on purpose. The
repository publishes SHAs and no semver tags at all, and renovate cannot order SHAs — an
annotation would look like tracking while tracking nothing. Add one once release-please cuts
real tags ([schmetterpause#39](https://github.com/stuttgart-things/schmetterpause/issues/39)).

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
