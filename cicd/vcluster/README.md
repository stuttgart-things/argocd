# cicd/vcluster

Catalog entry for [vcluster](https://www.vcluster.com/) (loft-sh) — virtual Kubernetes clusters that run inside a host namespace. Packaged as an **app-of-apps Helm chart**: consumers create one ArgoCD `Application` pointing at `cicd/vcluster/install` and the chart renders the child `Application` that installs vcluster from `https://charts.loft.sh`.

Port of [`stuttgart-things/flux` — `apps/vcluster`](https://github.com/stuttgart-things/flux/tree/main/apps/vcluster). Lives under `cicd/` here because vcluster typically backs CI / preview environments in this repo's topology.

## Layout

```
cicd/vcluster/
└── install/                        app-of-apps Helm chart (what consumers point at)
    ├── Chart.yaml
    ├── values.yaml
    ├── values.schema.json
    └── templates/
        └── chart.yaml              renders Application "vcluster" (sync-wave 0)
```

## What gets deployed

A single Argo CD `Application` pointing at the loft.sh `vcluster` chart. Computed `valuesObject`:

- `controlPlane.distro.k8s.enabled: true` + `image.tag: .Values.k8sVersion` (default `v1.33.4`)
- `controlPlane.backingStore.etcd.embedded.enabled: true` — embedded etcd, no external store
- `controlPlane.backingStore.resources` — from `.Values.resources` (default 200m/512Mi/1Gi → 4Gi/8Gi)
- `controlPlane.backingStore.highAvailability.replicas: .Values.replicas` (set to 3 for true HA)
- `controlPlane.persistence.volumeClaim` — `enabled` + `size` + `storageClass`, `retentionPolicy: Retain`, `ReadWriteOnce`
- `sync.toHost` — services, endpoints, PVCs synced from vcluster down to the host
- `sync.fromHost` — events + StorageClasses + IngressClasses imported from the host (nodes off by default)
- `.Values.extraValues` — deep-merged on top as an escape hatch

## Consumer usage

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: vcluster
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: cicd/vcluster/install
    helm:
      values: |
        project: my-cluster
        destination:
          server: https://<cluster-api>:6443
          namespace: vcluster
        chartVersion: 0.29.1
        k8sVersion: v1.33.4
        persistence:
          enabled: true
          storageClass: longhorn
          size: 10Gi
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
| `destination.namespace` | `vcluster` | Namespace for the vcluster controlPlane |
| `chartVersion` | `0.29.1` | Upstream `vcluster` chart version |
| `k8sVersion` | `v1.33.4` | Kubernetes version inside the virtual cluster |
| `resources.{requests,limits}` | 200m/512Mi/1Gi → 4Gi/8Gi | controlPlane etcd resources |
| `replicas` | `1` | controlPlane HA replicas (use 3 for production) |
| `persistence.{enabled,storageClass,size}` | `true` / `""` / `10Gi` | controlPlane PVC config (empty `storageClass` lets the cluster default apply) |
| `sync.toHost.{services,endpoints,persistentVolumeClaims}` | all `true` | Push these resource types out to the host namespace |
| `sync.fromHost.{events,storageClasses,nodes,ingressClasses}` | `true,true,false,true` | Pull these in from the host |
| `extraValues` | `{}` | Deep-merged on top of the computed upstream `valuesObject` |
| `syncPolicy` | automated + retry | Applied to the rendered Application |

## Related

- Flux equivalent: [`stuttgart-things/flux` — `apps/vcluster`](https://github.com/stuttgart-things/flux/tree/main/apps/vcluster)
- Upstream: <https://www.vcluster.com/docs>
- Helm chart: `https://charts.loft.sh` (chart `vcluster`)
