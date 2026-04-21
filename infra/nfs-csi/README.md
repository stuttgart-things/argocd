# infra/nfs-csi

Catalog entries for the [kubernetes-csi/csi-driver-nfs](https://github.com/kubernetes-csi/csi-driver-nfs) driver and matching `StorageClass` resources. Two independently deployable pieces — consumers create one ArgoCD `Application` per piece they need.

## Layout

```
infra/nfs-csi/
├── install/          app-of-apps — renders Application "nfs-csi" → kubernetes-csi/csi-driver-nfs
├── storageclasses/   plain Helm chart — renders N StorageClasses from a values list
└── README.md
```

Typical combinations:

| Want | Applications to create |
|---|---|
| Driver only (consumer writes their own StorageClasses) | `install` |
| Driver + StorageClasses | `install`, `storageclasses` |
| StorageClasses only (driver already installed out-of-band) | `storageclasses` |

## install/

App-of-apps Helm chart packaging the upstream `csi-driver-nfs` chart. Consumer `Application` points at `infra/nfs-csi/install`; chart renders a child `Application` targeting the kubernetes-csi release channel with a computed `valuesObject`.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: nfs-csi
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: infra/nfs-csi/install
    helm:
      values: |
        project: my-cluster
        destination:
          server: https://<cluster-api>:6443
          namespace: kube-system
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

The snapshotter sidecar is on by default, snapshot CRDs are off — so the driver plays nicely with clusters where another component (e.g. `infra/openebs` / an external snapshot-controller) already owns the `VolumeSnapshot*` CRDs. Two owners of the same CRD fight on sync.

### install values reference

See `install/values.yaml` / `install/values.schema.json`.

| Key | Default | Purpose |
|---|---|---|
| `project` | `default` | ArgoCD AppProject for the rendered Application |
| `destination.server` / `namespace` | `https://kubernetes.default.svc` / `kube-system` | Target workload cluster + namespace |
| `chartVersion` | `v4.13.1` | Upstream csi-driver-nfs chart version |
| `externalSnapshotter.enabled` | `true` | Run the snapshotter sidecar |
| `externalSnapshotter.customResourceDefinitions.enabled` | `false` | Install `VolumeSnapshot*` CRDs from this chart — leave off if another component owns them |
| `extraValues` | `{}` | Deep-merged on top of the computed upstream `valuesObject` (driver, feature, kubeletDir, SA/RBAC overrides) |
| `syncPolicy` | automated + retry | Applied to the rendered child Application |

## storageclasses/

Plain Helm chart that renders one `StorageClass` per entry in `storageClasses: [...]`. Consumer `Application` points at `infra/nfs-csi/storageclasses` with the list. The list is empty by default — no cluster gets `nfs.example.com` placeholders.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: nfs-csi-storageclasses
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: infra/nfs-csi/storageclasses
    helm:
      values: |
        storageClasses:
          - name: nfs3-csi
            server: nfs.my-cluster.example.com
            share: /exports
            subDir: my-cluster
            mountPermissions: "0"
            onDelete: archive
            mountOptions:
              - nfsvers=3
              - rsize=1048576
              - wsize=1048576
              - tcp
              - hard
              - nolock
          - name: nfs4-csi
            server: nfs.my-cluster.example.com
            share: /exports
            mountPermissions: "0777"
            mountOptions:
              - nfsvers=4.1
  destination:
    server: https://<cluster-api>:6443
    namespace: kube-system
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ServerSideApply=true]
```

### storageclasses values reference

| Key | Default | Purpose |
|---|---|---|
| `provisioner` | `nfs.csi.k8s.io` | Must match the installed driver (don't change unless you know why) |
| `storageClasses` | `[]` | List of StorageClasses to render |

Per-entry fields (all quoted in rendered YAML):

| Field | Required | Purpose |
|---|---|---|
| `name` | ✓ | StorageClass name |
| `server` | ✓ | NFS server hostname/IP |
| `share` | ✓ | NFS export path |
| `subDir` | — | Subdirectory under `share`; often the cluster name |
| `mountPermissions` | ✓ | Octal as string: `"0"`, `"0777"`, … |
| `onDelete` | — | `delete` / `archive` / `retain` — what the driver does with the backing directory on PVC delete |
| `volumeBindingMode` | — | `Immediate` (default) / `WaitForFirstConsumer` |
| `reclaimPolicy` | — | `Delete` (default) / `Retain` |
| `allowVolumeExpansion` | — | default `true` |
| `mountOptions` | ✓ | NFS mount options — **include `nfsvers=3` or `nfsvers=4.1`** |

The schema enforces `name`, `server`, `share`, `mountPermissions`, `mountOptions` per entry and validates the enums above; invalid overrides fail the sync.

## Fleet — one `ApplicationSet` per piece

Label clusters with `install/nfs-csi: "true"` for the driver, and `install/nfs-csi-storageclasses: "true"` for StorageClasses. Per-cluster NFS server + share come from the cluster Secret (via ApplicationSet `{{ .metadata.annotations.nfsServer }}`-style fields, or from generator-specific values).

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: nfs-csi
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - clusters:
        selector:
          matchLabels:
            install/nfs-csi: "true"
  template:
    metadata:
      name: 'nfs-csi-{{ .name }}'
    spec:
      project: '{{ .name }}'
      source:
        repoURL: https://github.com/stuttgart-things/argocd.git
        targetRevision: main
        path: infra/nfs-csi/install
        helm:
          values: |
            project: {{ .name }}
            destination:
              server: {{ .server }}
              namespace: kube-system
      destination: { server: https://kubernetes.default.svc, namespace: argocd }
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

For `storageclasses/`, fleet mode typically wants the NFS server/share to vary per cluster — pull those from cluster Secret annotations and interpolate into the `values` string, or use a matrix generator with a per-cluster overlay file. Because ApplicationSet Go-template output is always a string, a single fleet `ApplicationSet` shipping identical `storageClasses` entries only fits homogeneous NFS backends.

## Migrating from the previous kustomize layout

| Old | New |
|---|---|
| `infra/nfs-csi/chart` (kustomize dir, Application inlined) | `infra/nfs-csi/install` (Helm chart; consumer Application passes `helm.values`) |
| `infra/nfs-csi/storageclasses` (raw nfs3 + nfs4 manifests with `nfs.example.com` placeholders) | `infra/nfs-csi/storageclasses` (Helm chart; pass `storageClasses: [...]` with real server/share) |

**Breaking change**: `storageclasses` no longer ships fixed `nfs3-csi` + `nfs4-csi` StorageClasses by default — the list is empty, and consumers supply whatever set they need. The old layout applied two StorageClasses pointing at `nfs.example.com` to any cluster that consumed the path without patching.

## Related

- Flux equivalent: [`stuttgart-things/flux` — `infra/nfs-csi`](https://github.com/stuttgart-things/flux/tree/main/infra/nfs-csi) — Flux bundles driver + StorageClasses into two sibling HelmReleases (`release.yaml` + `post-release.yaml` via sthings-cluster); this catalog maps them to two independently deployable charts.
