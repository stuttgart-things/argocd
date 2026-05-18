# apps/vcluster

Catalog entry for [vcluster](https://www.vcluster.com/) (loft-sh) — a virtual Kubernetes cluster running as a pod on a host cluster. Packaged as an **app-of-apps Helm chart**: consumers create one ArgoCD `Application` pointing at `apps/vcluster/install`, pass overrides via `helm.values`, and the chart renders the real child `Application` that installs the upstream vcluster chart.

## Layout

```
apps/vcluster/
└── install/
    ├── Chart.yaml
    ├── values.yaml
    ├── values.schema.json
    └── templates/
        └── chart.yaml             renders Application "vcluster-<name>-<hash>" (sync-wave 0)
```

## What gets deployed

Installs vcluster `0.33.1` from the loft-sh Helm repo (`https://charts.loft.sh`, chart `vcluster`) into the configured namespace on the host cluster. By default:

- **k8s distro** (real `kube-apiserver` + `etcd`) — auto-selected by the upstream chart. vcluster `0.20+` removed the k3s/k0s distros.
- `controlPlane.statefulSet.persistence.volumeClaim` — 5Gi PVC on the host's default StorageClass
- `controlPlane.service.spec.type: ClusterIP` — vcluster API reachable in-cluster as `https://<vclusterName>.<namespace>.svc:443`
- vcluster's default sync mapping (pods/services/PVCs/endpoints synced to host; nodes, ingresses, storage classes faked virtually)

Tweak the Kubernetes version or distro image via `extraValues.controlPlane.distro.k8s.*`.

## Consumer usage

### Single vcluster — one `Application`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: vcluster-dev
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: apps/vcluster/install
    helm:
      values: |
        project: default
        vclusterName: vcluster-dev
        destination:
          server: https://kubernetes.default.svc
          namespace: vcluster-dev
        persistence:
          enabled: true
          storageClass: longhorn
          size: 5Gi
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

The outer `destination.server` is the **management cluster** (where the rendered child Application lives, in the `argocd` namespace). The inner `destination.server` under `helm.values` is the **host cluster** where the vcluster pods run.

## Registering the vcluster with ArgoCD

Once the vcluster is `Healthy / Synced` in ArgoCD, register it as a destination cluster so ArgoCD can deploy *into* the vcluster.

### Option A — `vcluster` CLI + `argocd cluster add` (simplest)

```bash
# 1. Wait for the vcluster pod to be ready on the host cluster
export KUBECONFIG=/home/sthings/.kube/platform-sthings
kubectl -n vcluster-dev rollout status statefulset/vcluster-dev --timeout=5m

# 2. Generate a kubeconfig context pointing at the vcluster (creates a new
#    context vcluster_vcluster-dev_vcluster-dev_<host> in $KUBECONFIG)
vcluster connect vcluster-dev -n vcluster-dev --update-current=true \
  --server=https://vcluster-dev.vcluster-dev.svc

# 3. Register with ArgoCD using the in-cluster service URL (so ArgoCD reaches
#    the vcluster via the host's internal service network, not via port-forward).
#    Run from inside the management cluster context or via `argocd login` first.
argocd cluster add vcluster_vcluster-dev_vcluster-dev_<host> \
  --name vcluster-dev \
  --server-side-apply
```

If you'd rather hand-craft the cluster Secret, the API endpoint is `https://vcluster-dev.vcluster-dev.svc:443`, and the bearer token + CA can be extracted from the kubeconfig vcluster emits.

### Option B — declarative cluster Secret in this repo (GitOps registration)

Create a `Secret` of type `argocd.argoproj.io/secret-type: cluster` in the `argocd` namespace, with `server` pointing at the in-cluster vcluster Service and `config` containing the bearer token + CA. This is the GitOps-pure path but requires sealing/encrypting the token (SOPS, External Secrets, ArgoCD Vault Plugin). Out of scope for this entry — see [`infra/external-secrets/cluster-secret-store-vault`](../../infra/external-secrets/) for a Vault-backed approach.

## Using the vcluster from ArgoCD

Once registered, drop the vcluster name into any other catalog entry's `destination`:

```yaml
helm:
  values: |
    destination:
      name: vcluster-dev         # registered cluster name (Option A above)
      namespace: my-workload
```

ApplicationSets can target it via cluster-secret labels (e.g. label the vcluster's cluster Secret with `tier=dev` and let the existing `platforms/*` ApplicationSets fan out automatically).

## Values reference

See `install/values.yaml` for defaults and `install/values.schema.json` for the full JSON Schema.

| Key | Default | Purpose |
|---|---|---|
| `project` | `default` | ArgoCD AppProject for the rendered Application |
| `destination.server` | `https://kubernetes.default.svc` | Host cluster API |
| `destination.namespace` | `vcluster-dev` | Namespace the vcluster runs in |
| `vclusterName` | `vcluster-dev` | Helm release name + Service name (drives the API URL) |
| `chartVersion` | `0.33.1` | Upstream loft-sh vcluster chart version |
| `persistence.enabled` | `true` | Render a PVC for the control-plane StatefulSet |
| `persistence.storageClass` | `""` | StorageClass (`""` → host default) |
| `persistence.size` | `5Gi` | PVC size |
| `service.type` | `ClusterIP` | Service type for the vcluster API |
| `sync` | `{}` | Deep-merged into upstream `sync` block |
| `extraValues` | `{}` | Deep-merged on top of the computed upstream `valuesObject` (e.g. pin `controlPlane.distro.k8s.version`) |
| `syncPolicy` | automated + retry | Applied to the rendered Application |

## Related

- vcluster docs (the docs page that motivated this entry): <https://www.vcluster.com/docs/vcluster/deploy/control-plane/kubernetes-pod/basics>
- ArgoCD cluster registration: <https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#clusters>
