# infra/nfs-csi

Catalog entry for the [kubernetes-csi/csi-driver-nfs](https://github.com/kubernetes-csi/csi-driver-nfs) driver plus opinionated NFSv3 and NFSv4 `StorageClass` examples.

## Layout

```
infra/nfs-csi/
├── chart/                  # csi-driver-nfs Helm chart (v4.13.1, sync-wave -10)
└── storageclasses/         # nfs3-csi + nfs4-csi StorageClasses (sync-wave 10)
```

## Components

### chart/
Installs the csi-driver-nfs chart into `kube-system`. Values match the Flux release: FSGroup policy on, inline volumes off, external snapshotter on, snapshot CRDs off (cluster-wide snapshot CRDs are expected to come from elsewhere — e.g. openebs-crds).

### storageclasses/
Two `StorageClass` resources pointing at the same example NFS server:

- `nfs3-csi` — NFSv3, hostname locking off (`nolock`), `onDelete: archive`
- `nfs4-csi` — NFSv4.1, world-writable mount permissions

**Both default to `server: nfs.example.com` / `share: /exports`** — consumers must patch their cluster overlay with real server/share values.

## Consumer usage

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - https://github.com/stuttgart-things/argocd.git/infra/nfs-csi/chart?ref=main
  - https://github.com/stuttgart-things/argocd.git/infra/nfs-csi/storageclasses?ref=main
patches:
  - target: { kind: Application, name: nfs-csi }
    patch: |-
      - op: replace
        path: /spec/project
        value: <cluster-project>
      - op: replace
        path: /spec/destination/server
        value: https://<cluster-api>:<port>
  - target: { kind: Application, name: nfs-csi-storageclasses }
    patch: |-
      - op: replace
        path: /spec/project
        value: <cluster-project>
      - op: replace
        path: /spec/destination/server
        value: https://<cluster-api>:<port>
```

### Overriding the NFS server / share per cluster

If the default `nfs.example.com` doesn't suit, override via an additional overlay layer that patches the `StorageClass` resources, or fork `storageclasses/manifests/` into your cluster overlay. The catalog intentionally ships a placeholder because real NFS endpoints are cluster-specific.

## Related

- Flux equivalent: [`stuttgart-things/flux` — `infra/nfs-csi`](https://github.com/stuttgart-things/flux/tree/main/infra/nfs-csi)
