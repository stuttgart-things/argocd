# platforms/storage

Storage platform bundle: `ApplicationSet`s on the management cluster that fan out storage-stack catalog entries (OpenEBS LocalPV-Hostpath + Longhorn + NFS CSI driver + NFS StorageClasses) to every cluster labelled as a storage target.

All ApplicationSets share one master gate — the ArgoCD cluster `Secret` must carry:

```
storage-platform: "true"
```

Catalog entries rendered:

| ApplicationSet                  | Wave | Catalog path                      | Workload namespace | Notes |
|---|---|---|---|---|
| `openebs-storage`               | -10  | `infra/openebs/install`           | `openebs`          | OpenEBS umbrella; renders LocalPV-Hostpath and annotates `openebs-hostpath` as the cluster's default StorageClass |
| `longhorn-storage`               | -10  | `infra/longhorn/install`           | `longhorn-system`  | Longhorn 1.13 distributed block storage, lean profile (19 pods on 3 nodes). Replica count, default-SC claim and a UI HTTPRoute per cluster — see [Longhorn](#longhorn). `preUpgradeChecker.jobEnabled: false` (required for GitOps) |
| `nfs-csi-install-storage`       | -10  | `infra/nfs-csi/install`           | `kube-system`      | csi-driver-nfs (controller + node DaemonSet); no StorageClasses yet — those come from the next appset |
| `nfs-csi-storageclasses-storage`|  -5  | `infra/nfs-csi/storageclasses`    | `kube-system`      | One `StorageClass` per cluster, fields sourced from cluster-Secret annotations. **Additionally gated on** the label `storage-platform.stuttgart-things.com/nfs-config` being present (any value) |
| `cloudnative-pg-storage`        |  -5  | `infra/cloudnative-pg/install`     | `postgres`         | CloudNativePG operator + CRDs. **Opt-in**, an explicit `'true'` — a cluster with no PostgreSQL has no use for it. A singleton: `tabletennis-platform` needs it, anything else growing a Postgres uses the same one |
| `cloudnative-pg-barman-storage` |  -5  | `infra/cloudnative-pg/barman-cloud`| `postgres`         | The Barman Cloud backup plugin, beside the operator. **Opt-in** and additionally requires the operator's own label. Needs cert-manager on the target cluster |
| `velero-storage`                |  -5  | `infra/velero/install`            | `velero`           | Velero + its `cloud-credentials` ExternalSecret + the `daily-all` Schedule. **Opt-in** (`storage-platform/velero: 'true'`), annotation-driven — see [Velero](#velero-cluster-backups) |
| `backstage-rag-postgres-storage` |  5  | `apps/backstage-rag-postgres/install` | Backstage ns (`portal`) | CNPG `Cluster` + pgvector for the Backstage RAG-AI plugin. **Opt-in** (`storage-platform/backstage-rag-postgres: 'true'`) and additionally requires `storage-platform/cloudnative-pg: 'true'`. Backups (barman plugin) and the Velero Schedule off unless annotated; backups also need `cloudnative-pg-barman` |

`project: '{{ .name }}'` on every generated Application — the `AppProject` named after the cluster must exist first (see [`config/cluster-project`](../../config/cluster-project/), driven by the `cluster-projects` ApplicationSet on clusters labelled `auto-project=true`).

**Ordering:** `openebs-storage`, `longhorn-storage`, and `nfs-csi-install-storage` carry sync-wave `-10`, `nfs-csi-storageclasses-storage` carries `-5`. As noted in `platforms/network`, sync-wave on top-level Applications is informational (each ApplicationSet fires independently). The StorageClass appset's retries handle the "driver not yet installed" race — the SC manifest itself is just a CRD-free object so it can land before the driver, but consumer PVCs will stay `Pending` until both are present.

## Install

Bootstrap the platform itself (one-shot, on the management cluster):

```bash
kubectl apply -f platforms/storage/application.yaml
```

That creates an `Application` named `storage-platform` pointing at this directory. Argo renders the `kustomization.yaml` here, which applies the three ApplicationSets into the `argocd` namespace. They become active as soon as a cluster Secret is labelled `storage-platform: "true"`.

Alternatively, apply the bundle directly without the outer Application:

```bash
kubectl apply -k https://github.com/stuttgart-things/argocd.git/platforms/storage?ref=main
```

`application.yaml` is intentionally **not** listed in `kustomization.yaml` — the bootstrap Application must not manage itself.

## Per-cluster opt-out

Default behaviour: labelling a cluster with `storage-platform: "true"` enrols it in **OpenEBS**, **Longhorn**, and the **NFS CSI driver install** automatically. The NFS StorageClass appset additionally requires the `nfs-config` label gate (see below) — without it, no StorageClass is rendered.

To skip a single component on a specific cluster, add a per-component label on that cluster's `Secret` in the `argocd` namespace:

| Label on the cluster Secret                              | Effect on that cluster |
|---|---|
| `storage-platform/openebs: "false"`                      | Skip `openebs-storage` |
| `storage-platform/longhorn: "false"`                     | Skip `longhorn-storage` |
| `storage-platform/longhorn-ui-route: "true"`             | **Opt-in**: Longhorn UI HTTPRoute (see [Longhorn](#longhorn)) |
| `storage-platform/nfs-csi-install: "false"`              | Skip `nfs-csi-install-storage` |
| `storage-platform/nfs-csi-storageclasses: "false"`       | Skip `nfs-csi-storageclasses-storage` |

The two CloudNativePG appsets and the Velero appset invert this: they are
opt-**in**, so they match an explicit `storage-platform/cloudnative-pg: "true"`
(and, for the plugin, also `storage-platform/cloudnative-pg-barman: "true"`),
respectively `storage-platform/velero: "true"`. An absent label means *not*
installed. Removing the label is how you opt out.

Semantics: each ApplicationSet selector is `storage-platform=true` AND `storage-platform/<component> NotIn ["false"]`. Absent label = included (default). Only the explicit string `"false"` opts out.

If the cluster is managed by `clusterbook-operator`, add the label to the `ClusterbookCluster` CR's `spec.labels` — the operator propagates it onto the Argo Secret on the next reconcile.

### Opt-out and teardown

`appset-longhorn`, `appset-nfs-csi-install` and `appset-openebs` are app-of-apps parents and deliberately do **not** set `spec.syncPolicy.preserveResourcesOnDeletion`. What that flag preserves for such a parent are child `Application` CRs, not workloads. Preserving them leaves orphans in the `argocd` namespace that outlive a deregistered cluster and then block its `proj-<cluster>` from finalizing (#324).

Without the flag the parent Application carries `resources-finalizer.argocd.argoproj.io`, so deleting it collects the child Application with it. That cascade never reaches the target cluster: the parent's own destination is `https://kubernetes.default.svc` / `argocd`, and the child Application renders no finalizer of its own — so the deletion stops at the `Application` CR and never touches CRDs, namespaces, StorageClasses or DaemonSets.

**What a cluster loses on opt-out is not the workloads but ArgoCD's management of them.** They keep running exactly as deployed; there is just no more self-heal, drift correction or upgrade. Clean-up stays manual: `kubectl delete ns <namespace>` (or equivalent) on the target cluster if you want the resources gone.

This matters most for storage, so to be explicit: the CSI drivers, their DaemonSets, the StorageClasses and every live PV/PVC survive an opt-out untouched. Nothing gets unmounted from a running pod. `appset-nfs-csi-storageclasses` rolls out StorageClasses directly rather than an Application and keeps the flag.

## CloudNativePG: the operator and the backup plugin

Two appsets, both opt-in, both landing in `postgres`:

| Label | Installs |
|---|---|
| `storage-platform/cloudnative-pg: 'true'` | the operator and its CRDs |
| `+ storage-platform/cloudnative-pg-barman: 'true'` | the Barman Cloud plugin as well |

**Both are singletons per cluster, which is why they live here** rather than in
whichever app platform wants a database. The operator is obvious. The plugin is
less so: CloudNativePG discovers plugins by the `cnpg.io/pluginName` label on a
Service **in the operator's own namespace**, so there is exactly one place it can
go, and two platforms installing it would race on the same Deployment and the
same `objectstores.barmancloud.cnpg.io` CRD.

`appset-cloudnative-pg.yaml` used to say backups were "per-workload, so whichever
platform enables them brings it". No platform ever did, and given the namespace
rule none could have without that race — so the chart sat in the catalog
uninstalled while a dev cluster ran the plugin by hand. The plugin appset is that
sentence corrected.

> [!IMPORTANT]
> **The plugin needs cert-manager on the target cluster.** The upstream chart
> renders a self-signed `Issuer` and two `Certificate`s for operator ↔ plugin
> TLS. It is not in the selector, because a cluster may get cert-manager from
> `network-platform/cert-manager-install` or from somewhere else entirely.
> Without it the Certificates stay unissued and the plugin Pod never goes ready.

### What a database still has to do

Installing the plugin does not back anything up. It makes the
`objectstores.barmancloud.cnpg.io` CRD and the WAL archiver available; a `Cluster`
opts in with an `ObjectStore` in its own namespace, `spec.plugins` naming
`barman-cloud.cloudnative-pg.io`, and a `ScheduledBackup` with `method: plugin`.

`apps/schmetterpause/database` renders all three from `database.backup.*` — see
[`platforms/tabletennis`](../tabletennis/#backups) for how a cluster turns that
on, and why it is an overlay rather than a label.

Not the in-tree `spec.backup.barmanObjectStore`: CloudNativePG 1.30 deprecates it
and 1.31.0 removes it.

## Velero: cluster backups

`appset-velero.yaml` is the ArgoCD counterpart of what `labda-dev-a` runs from
the Flux catalog (`velero-eso` + `velero-schedule`). Opt-in, one parent per
cluster (`velero-storage-<cluster>`) rendering two children on the target
cluster:

| Application | What |
|---|---|
| `velero-<cluster>-secrets` (wave -5) | ExternalSecret → Secret `cloud-credentials` (AWS INI) from `access_key` / `secret_key` of one entry |
| `velero-<cluster>` | upstream `vmware-tanzu/velero` + AWS plugin; BSL `default` at `<bucket>/<prefix>`; Schedule `velero-daily-all` |

Backups are **metadata only** (no CSI snapshots, no node agent), like the Flux
base. Database rows are the Barman Cloud plugin's job.

| Annotation (`storage-platform.stuttgart-things.com/…`) | Required | Default | Meaning |
|---|---|---|---|
| `velero-s3-url` | **yes** | — | S3 endpoint, e.g. LabDA's `https://minio.sthings-platform.4sthings.tiab.ssc.sva.de`. Missing = the sync fails on the chart schema |
| `velero-bucket` | no | `velero` | Bucket, shared by the fleet |
| `velero-prefix` | no | `<cluster>` | Directory inside the bucket — one per cluster, so clusters never sync each other's backups in |
| `velero-secret-store` | no | `shared-velero-secret-store`, else `vault-<cluster>` | ClusterSecretStore holding the S3 pair |
| `velero-secret-key` | no | `shared-velero-secret-key`, else `velero` | Entry NAME (properties `access_key`, `secret_key`) |
| `shared-velero-secret-store` / `shared-velero-secret-key` | no | — | *[auto, ClusterStack]* the shared `_` entry a profile derives; read when the two above are unset |
| `velero-schedule-cron` | no | `0 2 * * *` | `daily-all` cron (UTC); `off` = no Schedule |
| `velero-schedule-ttl` | no | `720h0m0s` | Backup retention |
| `velero-ssl-cert-dir` | no | `/etc/ssl/custom` | `SSL_CERT_DIR` — the mount of trust-manager's `cluster-trust-bundle` |

Precedence for the credentials: explicit `velero-secret-*` > the ClusterStack's
`shared-velero-secret-*` > the cluster's own store and entry `velero` — the last
one is exactly labda-dev-a's layout (`vault-labda-dev-a`, entry `velero`).

**Preconditions** (not in the selector): external-secrets and the named
ClusterSecretStore on the cluster (security-platform); the entry itself; and for
a lab-PKI endpoint the `cluster-trust-bundle` ConfigMap in `velero`
(network-platform's trust-manager bundle reaches every namespace). Go still reads
the system CA file with `SSL_CERT_DIR` set, so a public endpoint keeps working.
No `caCert` on the BSL: one more CA copy to keep current, while the bundle is
maintained already. `reloader.stakater.com/auto` is set on the Deployment, so a
rotated key rolls Velero once reloader (base-platform) runs.

Opt-out (remove the label) collects both child Applications; Velero, its CRDs
and every backup in the bucket stay.

```bash
kubectl -n argocd label secret <cluster-secret> storage-platform=true storage-platform/velero=true
kubectl -n argocd annotate secret <cluster-secret> \
  storage-platform.stuttgart-things.com/velero-s3-url=https://minio.sthings-platform.4sthings.tiab.ssc.sva.de
```

## Default StorageClass conflicts

Three components in this platform install a CSI provider, and only one StorageClass per cluster can be annotated `storageclass.kubernetes.io/is-default-class: "true"`. The platform's defaults:

| Component | Installs StorageClass | Marked as cluster default? |
|---|---|---|
| `openebs-storage`               | `openebs-hostpath`           | **yes** (appset hard-codes `defaultStorageClass: true`) |
| `longhorn-storage`              | `longhorn`                    | no — unless `longhorn-default-class: "true"` **and** `storage-platform/openebs: "false"` |
| `nfs-csi-storageclasses-storage`| `<nfs-name>` (default `nfs-csi`) | no |

If two SCs both claim default, PVCs created without an explicit `storageClassName` bind non-deterministically to whichever the API server returns first — that's a footgun. To swap defaults:

- **Make Longhorn the default**: set **both** on the cluster Secret — label `storage-platform/openebs: "false"` (skip this platform's openebs) and annotation `storage-platform.stuttgart-things.com/longhorn-default-class: "true"`. The appset only claims default when both are present; the annotation alone is a deliberate no-op, because openebs-hostpath would still be default. Caveat: OpenEBS from `cicd-platform` (`openebs-cicd`) is not checked — if the cluster gets OpenEBS there, also set `cicd-platform/openebs: "false"` or you are back to two defaults. Opting out of openebs does not delete the running `openebs-hostpath` StorageClass (see "Opt-out and teardown"): remove its default annotation (or the SC) by hand.
- **Make NFS the default**: similar — opt out of openebs, then add the `storageclass.kubernetes.io/is-default-class: "true"` annotation to your NFS StorageClass via a kustomize patch on `infra/nfs-csi/storageclasses` in a per-cluster Application.

## Longhorn

### Labels and annotations

| On the cluster Secret | Kind | Default | Effect |
|---|---|---|---|
| `storage-platform/longhorn: "false"` | label | absent = installed | opt out |
| `storage-platform.stuttgart-things.com/longhorn-replica-count` | annotation | `"1"` | replicas per volume of the `longhorn` StorageClass and of volumes created in the UI. **Set `"3"` on 3-node clusters** — 1 has no redundancy; 3 on fewer than 3 nodes leaves PVCs `Pending`/degraded. Schema: `1`..`20` |
| `storage-platform.stuttgart-things.com/longhorn-default-class` | annotation | absent = no | `"true"` makes `longhorn` the default StorageClass — **only** together with `storage-platform/openebs: "false"`, see [Default StorageClass conflicts](#default-storageclass-conflicts) |
| `storage-platform/longhorn-ui-route` | label | absent = no route | `"true"`: HTTPRoute `longhorn-httproute` in `longhorn-system`, host `longhorn.<fqdn>` on `<cluster>-gateway` (namespace `default`, listener `https`). Needs the clusterbook annotation `clusterbook.stuttgart-things.com/fqdn`; without it the render fails on purpose |

A LabDA 3-node app cluster typically sets:

```yaml
labels:
  storage-platform: "true"
  storage-platform/longhorn-ui-route: "true"   # optional, see warning below
annotations:
  storage-platform.stuttgart-things.com/longhorn-replica-count: "3"
```

(and drops its `storage-platform/longhorn: "false"`).

> [!WARNING]
> **The Longhorn UI has no authentication.** Anyone who can reach `longhorn.<fqdn>` can delete volumes, snapshots, backups and disks. The route is therefore opt-in and only acceptable on the lab-internal clusterbook gateway — the same reasoning [`platforms/tabletennis`](../tabletennis/) gives for zaehlwerk. Follow-up before exposing it anywhere else: OIDC via oauth2-proxy in front of `longhorn-frontend` (the upstream chart takes `httproute.filters`). Without the label, `kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80` works too.

### Pod footprint

The chart's `minimalFootprint: true` (default) runs every cluster-wide controller once instead of upstream's 2–3. All of them are leader-elected, so only standbys go away; the price is a slower failover (reschedule) of a controller after a node loss — volume I/O is per-node and unaffected. 3-node cluster, steady state:

| Pod | Where | upstream | lean |
|---|---|---|---|
| `longhorn-manager`, `longhorn-csi-plugin`, `engine-image-ei-*`, `instance-manager-*` (v1) | DaemonSet-like, every node | 4 × 3 | 4 × 3 |
| `longhorn-driver-deployer` | any node | 1 | 1 |
| `longhorn-global-manager` | any node | 3 | 1 |
| `longhorn-ui` | any node | 2 | 1 |
| `csi-attacher`, `csi-provisioner`, `csi-resizer`, `csi-snapshotter` | any node | 4 × 3 | 4 × 1 |
| **total** | | **30** | **19** |

Also off: the v2 (SPDK) data engine (would add a second, hugepage-hungry instance-manager per node), the ServiceMonitor, ingress. `share-manager-*` (RWX volumes), `backing-image-manager-*` and the support-bundle manager only appear when something needs them. The helm `post-upgrade` hook becomes an Argo PostSync Job that runs and is deleted on every sync.

Upstream defaults back: `minimalFootprint: false` (per-cluster Application, see below). Anything else upstream offers — tolerations, backup target, `defaultSettings.*` — goes through `extraValues`, which is deep-merged last and wins over everything the chart computes; that needs a per-cluster Application (opt out with `storage-platform/longhorn: "false"`, point it at `infra/longhorn/install`).

## Longhorn node prerequisites

Longhorn requires kernel-level prerequisites on every node in the workload cluster: `open-iscsi` installed and running, the `iscsi_tcp` kernel module loaded, NFS client utilities (`nfs-common` / `nfs-utils`) for RWX volumes. Argo CD cannot solve these — they must be present on the node image / configured by Ignition / cloud-init / Ansible / whatever provisions your nodes. If the longhorn-manager DaemonSet pods log `Failed to start: open-iscsi not found`, the cluster's node image is the problem, not this platform.

Longhorn's own [`environment_check.sh`](https://raw.githubusercontent.com/longhorn/longhorn/v1.13.0/scripts/environment_check.sh) on the workload cluster is the fastest pre-flight check (or `longhornctl check preflight`).

> [!NOTE]
> Node images matter here. LabDA rke2 nodes (Ubuntu 26.04, e.g. `labda-apps-test1`) ship `iscsiadm`, but `iscsid` is inactive/disabled and `iscsi_tcp` is not loaded — and the `sthings.baseos` ansible collection has no playbook for it yet (only `nfs_server`). Until one exists in the ClusterStack's `ansible.stages.baseos`, enable it by hand on every node: `systemctl enable --now iscsid && modprobe iscsi_tcp && echo iscsi_tcp > /etc/modules-load.d/longhorn.conf`.

## Avoid double-installing OpenEBS

`platforms/cicd` ships its own `openebs-cicd` ApplicationSet (catalog path identical, `cicd-platform: "true"` gate). The two appsets here have been renamed (`openebs-storage`, child Application `openebs-storage-{{ .name }}`, child workload-cluster Application also explicitly named to avoid the chart's default sha-of-server name) so they don't fight over the same Argo CD Application object.

**However**, the underlying OpenEBS install is a singleton on the workload cluster — namespace `openebs`, cluster-scoped CRDs, DaemonSets, the `openebs-hostpath` StorageClass. A cluster carrying *both* `cicd-platform: "true"` and `storage-platform: "true"` would have two parallel installations racing on those resources. Pick one platform to own OpenEBS per cluster:

- The cluster will get OpenEBS from `cicd-platform`: set `storage-platform/openebs: "false"` on the Secret.
- The cluster will get OpenEBS from `storage-platform`: set `cicd-platform/openebs: "false"` on the Secret.

## NFS StorageClass: annotation contract

The `nfs-csi-storageclasses-storage` appset renders **one** StorageClass per cluster, with fields pulled from annotations on that cluster's Secret. To enrol a cluster:

1. Add label `storage-platform.stuttgart-things.com/nfs-config` to the Secret. Any value works; the appset's selector treats it as an Exists check. Without this label the appset doesn't fire — that's the safety net against rendering an Application with empty `server`/`share` strings and breaking chart validation.
2. Add the annotations below.

| Annotation                                                       | Required | Default       | Meaning |
|---|---|---|---|
| `storage-platform.stuttgart-things.com/nfs-server`               | yes      | —             | NFS server hostname or IP |
| `storage-platform.stuttgart-things.com/nfs-share`                | yes      | —             | Export path on the server, e.g. `/srv/nfs/k8s` |
| `storage-platform.stuttgart-things.com/nfs-name`                 | no       | `nfs-csi`     | Name of the rendered StorageClass |
| `storage-platform.stuttgart-things.com/nfs-subdir`               | no       | `<cluster>`   | Sub-directory under share. Default = the cluster's Argo CD name, so multiple clusters can share one export safely. To pin to a fixed sub-directory (or share the root), set this annotation explicitly |
| `storage-platform.stuttgart-things.com/nfs-version`              | no       | `4.1`         | NFS protocol version. Set `3` for NFSv3 |
| `storage-platform.stuttgart-things.com/nfs-mount-permissions`    | no       | `"0"`         | Octal, quoted (e.g. `"0"`, `"0777"`) |

Example — labelling a cluster Secret directly:

```bash
kubectl -n argocd label secret <cluster-secret> \
  storage-platform=true \
  storage-platform.stuttgart-things.com/nfs-config=true

kubectl -n argocd annotate secret <cluster-secret> \
  storage-platform.stuttgart-things.com/nfs-server=10.10.0.42 \
  storage-platform.stuttgart-things.com/nfs-share=/srv/nfs/k8s \
  storage-platform.stuttgart-things.com/nfs-version=4.1
```

If the cluster is managed by `clusterbook-operator`, set both the labels (under `spec.labels`) and the annotations (under `spec.annotations`) on the `ClusterbookCluster` CR — the operator propagates them to the Argo Secret on the next reconcile.

### Multiple StorageClasses per cluster

The annotation contract renders exactly one StorageClass. For clusters that need multiple NFS StorageClasses (e.g. nfs3 + nfs4 against different shares), opt out:

```
storage-platform/nfs-csi-storageclasses: "false"
```

…and apply `infra/nfs-csi/storageclasses` directly via a per-cluster `Application` whose values file lists every entry. The driver install (`nfs-csi-install-storage`) still fires from this platform, so all those StorageClasses share one installed CSI driver.

## Adding a catalog entry

1. Drop a new `appset-<name>.yaml` in this directory following the OpenEBS / nfs-csi templates (same cluster selector, path pointing at the new catalog entry's `install/` chart).
2. Add the filename to `kustomization.yaml`.
3. Commit — the `storage-platform` Application self-heals and reconciles.

## Related

- [`infra/openebs`](../../infra/openebs/), [`infra/longhorn`](../../infra/longhorn/), [`infra/nfs-csi`](../../infra/nfs-csi/), [`infra/velero`](../../infra/velero/) — catalog entries rendered by these ApplicationSets.
- [`platforms/cicd`](../cicd/) — sibling platform; ships its own `openebs-cicd` ApplicationSet (see "Avoid double-installing OpenEBS" above).
- [`platforms/network`](../network/) — sibling platform for clusterbook-registered classic clusters; same Exists-label gating pattern (`clusterbook.stuttgart-things.com/allocation-ip`) reused here for `storage-platform.stuttgart-things.com/nfs-config`.
