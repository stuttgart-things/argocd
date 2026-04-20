# infra/openebs

Catalog entry for the [OpenEBS](https://openebs.io/) storage stack. Packaged as an **app-of-apps Helm chart**: consumers create one ArgoCD `Application` (or `ApplicationSet`) pointing at `infra/openebs/chart`, pass overrides via `helm.valuesObject`, and the chart renders the child `Application` that installs the OpenEBS umbrella chart with an opinionated minimal configuration.

local-PV hostpath (the default engine) is on out-of-the-box via the upstream chart. Optional components (`loki`, `alloy`, `volumeSnapshots`, `preUpgradeHook`) and the extra storage engines (`local.lvm`, `local.zfs`, `replicated.mayastor`) are **off** by default — opt in per cluster via values.

## Layout

```
infra/openebs/
└── chart/                          app-of-apps Helm chart (what consumers point at)
    ├── Chart.yaml
    ├── values.yaml
    ├── values.schema.json
    └── templates/
        └── openebs.yaml            renders Application "openebs"
```

## Consumer usage

### Single cluster — one `Application`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: openebs
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: infra/openebs/chart
    helm:
      valuesObject:
        project: my-cluster
        destination:
          server: https://<cluster-api>:6443
          namespace: openebs
        engines:
          replicated:
            mayastor:
              enabled: true     # opt-in; needs hugepages + nvme-tcp on the nodes
        mayastorInitContainers:
          enabled: true
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

Note: the outer `destination.server` is the **management cluster** (where the rendered child Application lives, in the `argocd` namespace). The inner `destination.server` in `valuesObject` is the **workload cluster** where OpenEBS itself runs.

### Fleet — one `ApplicationSet` across many clusters

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: openebs
  namespace: argocd
spec:
  generators:
    - clusters:
        selector:
          matchLabels:
            openebs: enabled
  template:
    metadata:
      name: '{{name}}-openebs'
    spec:
      project: '{{name}}'
      source:
        repoURL: https://github.com/stuttgart-things/argocd.git
        targetRevision: main
        path: infra/openebs/chart
        helm:
          valuesObject:
            project: '{{name}}'
            destination: { server: '{{server}}', namespace: openebs }
            engines:
              replicated:
                mayastor:
                  enabled: '{{metadata.labels.openebs-mayastor}}'
            mayastorInitContainers:
              enabled: '{{metadata.labels.openebs-mayastor}}'
      destination: { server: https://kubernetes.default.svc, namespace: argocd }
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

Label ArgoCD cluster Secrets with `openebs: enabled` and `openebs-mayastor: "true"` where applicable.

## Values reference

See `chart/values.yaml` for defaults and `chart/values.schema.json` for the full JSON Schema. Invalid overrides (unknown keys, wrong types, missing required fields) fail the sync loudly.

| Key | Default | Purpose |
|---|---|---|
| `project` | `default` | ArgoCD AppProject for the rendered Application |
| `destination.server` / `namespace` | `https://kubernetes.default.svc` / `openebs` | Target cluster + namespace |
| `chartVersion` | `4.4.0` | Upstream OpenEBS umbrella chart version |
| `preUpgradeHook.enabled` | `false` | Upstream pre-upgrade hook |
| `loki.enabled` | `false` | Bundled Loki (logs) |
| `alloy.enabled` | `false` | Bundled Grafana Alloy |
| `volumeSnapshots.enabled` | `false` | CSI volume-snapshot CRDs (`openebs-crds.csi.volumeSnapshots`) |
| `engines.local.lvm.enabled` | `false` | LVM local-PV engine (needs LVM on the node) |
| `engines.local.zfs.enabled` | `false` | ZFS local-PV engine (needs ZFS on the node) |
| `engines.replicated.mayastor.enabled` | `false` | Mayastor replicated engine (needs hugepages + nvme-tcp on the node) |
| `mayastorInitContainers.enabled` | `false` | `mayastor.csi.node.initContainers.enabled` |
| `extraValues` | `{}` | Deep-merged on top of the computed upstream `valuesObject` |
| `syncPolicy` | automated + retry | Applied to the rendered Application |

## Mayastor prerequisites

Mayastor needs hugepages configured and the `nvme-tcp` kernel module loaded on each node that runs Mayastor pods — handle that **outside ArgoCD** (node bootstrap, Ansible, systemd-networkd units, etc.). If those aren't present when `engines.replicated.mayastor.enabled: true` is applied, the Mayastor DaemonSet stays NotReady and no replicated volumes will be schedulable.

## Migrating from the previous kustomize layout

If you were consuming the old `infra/openebs` path via a Kustomize overlay with JSON patches: replace that overlay with a single `Application` (example above). The overlay's patches map to values as follows:

| Old JSON patch | New value |
|---|---|
| `/spec/project` | `project` |
| `/spec/destination/server` | `destination.server` |
| `/spec/source/helm/valuesObject/engines/replicated/mayastor/enabled` | `engines.replicated.mayastor.enabled` |
| `/spec/source/helm/valuesObject/mayastor/csi/node/initContainers/enabled` | `mayastorInitContainers.enabled` |
| `/spec/source/helm/valuesObject/engines/local/lvm/enabled` | `engines.local.lvm.enabled` |
| `/spec/source/helm/valuesObject/engines/local/zfs/enabled` | `engines.local.zfs.enabled` |
| anything else under `valuesObject` | `extraValues.<path>` |

## Related

- Flux equivalent: [`stuttgart-things/flux` — `infra/openebs`](https://github.com/stuttgart-things/flux/tree/main/infra/openebs)
