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
| `longhorn-storage`               | -10  | `infra/longhorn/install`           | `longhorn-system`  | Longhorn distributed block storage. Defaults: `defaultClassReplicaCount: 1` (single-node-safe — bump for prod), StorageClass installed but **not** annotated as default. `preUpgradeChecker.jobEnabled: false` (required for GitOps) |
| `nfs-csi-install-storage`       | -10  | `infra/nfs-csi/install`           | `kube-system`      | csi-driver-nfs (controller + node DaemonSet); no StorageClasses yet — those come from the next appset |
| `nfs-csi-storageclasses-storage`|  -5  | `infra/nfs-csi/storageclasses`    | `kube-system`      | One `StorageClass` per cluster, fields sourced from cluster-Secret annotations. **Additionally gated on** the label `storage-platform.stuttgart-things.com/nfs-config` being present (any value) |

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
| `storage-platform/nfs-csi-install: "false"`              | Skip `nfs-csi-install-storage` |
| `storage-platform/nfs-csi-storageclasses: "false"`       | Skip `nfs-csi-storageclasses-storage` |

Semantics: each ApplicationSet selector is `storage-platform=true` AND `storage-platform/<component> NotIn ["false"]`. Absent label = included (default). Only the explicit string `"false"` opts out.

If the cluster is managed by `clusterbook-operator`, add the label to the `ClusterbookCluster` CR's `spec.labels` — the operator propagates it onto the Argo Secret on the next reconcile.

### Opt-out safety: `preserveResourcesOnDeletion`

Each ApplicationSet sets `spec.syncPolicy.preserveResourcesOnDeletion: true`. When a cluster flips from included → opted out, the child `Application` CR is deleted, **but the workload resources it managed stay in place** (StorageClass, namespaces, DaemonSets, CRDs). Critical for storage — pruning a CSI driver's DaemonSet while live PVs reference it would unmount volumes from running pods.

Clean-up is manual: `kubectl delete ns <namespace>` (or equivalent) on the target cluster if you want the resources gone. Until then, the cluster keeps running what was deployed; ArgoCD just stops managing it.

## Default StorageClass conflicts

Three components in this platform install a CSI provider, and only one StorageClass per cluster can be annotated `storageclass.kubernetes.io/is-default-class: "true"`. The platform's defaults:

| Component | Installs StorageClass | Marked as cluster default? |
|---|---|---|
| `openebs-storage`               | `openebs-hostpath`           | **yes** (appset hard-codes `defaultStorageClass: true`) |
| `longhorn-storage`              | `longhorn`                    | no |
| `nfs-csi-storageclasses-storage`| `<nfs-name>` (default `nfs-csi`) | no |

If two SCs both claim default, PVCs created without an explicit `storageClassName` bind non-deterministically to whichever the API server returns first — that's a footgun. To swap defaults:

- **Make Longhorn the default**: set `storage-platform/openebs: "false"` on the cluster Secret to skip openebs, *and* override `defaultStorageClass: true` for longhorn (opt out of `storage-platform/longhorn` and run a per-cluster Application using `infra/longhorn/install` with `defaultStorageClass: true` — the platform appset doesn't expose this knob to keep the contract simple).
- **Make NFS the default**: similar — opt out of openebs, then add the `storageclass.kubernetes.io/is-default-class: "true"` annotation to your NFS StorageClass via a kustomize patch on `infra/nfs-csi/storageclasses` in a per-cluster Application.

## Longhorn replica count

`infra/longhorn/install` defaults `defaultClassReplicaCount: 1` so the StorageClass works on single-node clusters (kind, k3s, single-VM k8s) out of the box — three replicas need three distinct nodes and PVCs would otherwise stay `Pending` forever. **For production multi-node clusters this is the wrong default**: single-replica volumes have no redundancy.

To run Longhorn with the production-typical `3` replicas:

1. Set `storage-platform/longhorn: "false"` on the cluster Secret to opt out of the platform's longhorn appset.
2. Apply a per-cluster `Application` pointed at `infra/longhorn/install` with `extraValues.persistence.defaultClassReplicaCount: 3` (or whatever value fits your fleet).

The `extraValues` block is deep-merged on top of the chart's computed values, so any upstream key — replica count, tolerations, ingress, backup target, etc. — can be set there without modifying the catalog chart.

## Longhorn node prerequisites

Longhorn requires kernel-level prerequisites on every node in the workload cluster: `open-iscsi` installed and running, the `iscsi_tcp` kernel module loaded, NFS client utilities (`nfs-common` / `nfs-utils`) for RWX volumes. Argo CD cannot solve these — they must be present on the node image / configured by Ignition / cloud-init / Ansible / whatever provisions your nodes. If the longhorn-manager DaemonSet pods log `Failed to start: open-iscsi not found`, the cluster's node image is the problem, not this platform.

Longhorn's own [`environment_check.sh`](https://raw.githubusercontent.com/longhorn/longhorn/v1.11.2/scripts/environment_check.sh) on the workload cluster is the fastest pre-flight check.

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

- [`infra/openebs`](../../infra/openebs/), [`infra/longhorn`](../../infra/longhorn/), [`infra/nfs-csi`](../../infra/nfs-csi/) — catalog entries rendered by these ApplicationSets.
- [`platforms/cicd`](../cicd/) — sibling platform; ships its own `openebs-cicd` ApplicationSet (see "Avoid double-installing OpenEBS" above).
- [`platforms/network`](../network/) — sibling platform for clusterbook-registered classic clusters; same Exists-label gating pattern (`clusterbook.stuttgart-things.com/allocation-ip`) reused here for `storage-platform.stuttgart-things.com/nfs-config`.
