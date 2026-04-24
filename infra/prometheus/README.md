# infra/prometheus

Catalog entry for [prometheus-community/prometheus](https://prometheus-community.github.io/helm-charts/) — standalone Prometheus (no Grafana, no Alertmanager by default). Packaged as an **app-of-apps Helm chart**: consumers create one ArgoCD `Application` pointing at `infra/prometheus/install` and the chart renders child `Application`s that install Prometheus and optionally publish its UI via Gateway API.

Port of [`stuttgart-things/flux` — `infra/prometheus`](https://github.com/stuttgart-things/flux/tree/main/infra/prometheus).

## Layout

```
infra/prometheus/
├── install/                        app-of-apps Helm chart (what consumers point at)
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── values.schema.json
│   └── templates/
│       ├── prometheus.yaml         renders Application "prometheus"           (sync-wave 0)
│       └── httproute.yaml          renders Application "prometheus-httproute" (sync-wave 10, gated by httpRoute.enabled)
└── httproute/                      Gateway API HTTPRoute sub-chart
    ├── Chart.yaml
    ├── values.yaml
    ├── values.schema.json
    └── templates/httproutes.yaml
```

## What gets deployed

### `prometheus` Application (always)
Installs `prometheus` `.Values.chartVersion` from `https://prometheus-community.github.io/helm-charts` into `.Values.destination.namespace`. Computed `valuesObject`:

- `alertmanager.enabled` / `prometheus-pushgateway.enabled` / `kube-state-metrics.enabled` / `prometheus-node-exporter.enabled` — from first-class values (flux defaults: alertmanager + pushgateway off, kube-state-metrics + node-exporter on)
- `server.persistentVolume` — `storageClass` + `size` from `.Values.storage{Class,Size}`
- `server.retention` — from `.Values.retention` (default `15d`)
- `.Values.extraValues` — deep-merged on top as an escape hatch

### `prometheus-httproute` Application (opt-in, `httpRoute.enabled: true`)
One Gateway API `HTTPRoute` pointing at `prometheus-server:80`, parented onto `.Values.httpRoute.gateway`.

## Consumer usage

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: prometheus
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: infra/prometheus/install
    helm:
      values: |
        project: my-cluster
        destination:
          server: https://<cluster-api>:6443
          namespace: monitoring
        chartVersion: 28.13.0
        storageClass: nfs4-csi
        storageSize: 10Gi
        retention: 15d
        httpRoute:
          enabled: true
          hostname: prometheus.my-cluster.example.com
          gateway:
            name: cilium-gateway
            namespace: default
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
| `project` | `default` | AppProject for all rendered Applications |
| `destination.server` | `https://kubernetes.default.svc` | Target cluster API |
| `destination.namespace` | `monitoring` | Namespace for Prometheus |
| `chartVersion` | `28.13.0` | Upstream `prometheus` chart version |
| `storageClass` / `storageSize` | `nfs4-csi` / `10Gi` | `server.persistentVolume` |
| `retention` | `15d` | `server.retention` |
| `alertmanager.enabled` | `false` | Subchart toggle |
| `pushgateway.enabled` | `false` | Subchart toggle |
| `kubeStateMetrics.enabled` | `true` | Subchart toggle |
| `nodeExporter.enabled` | `true` | Subchart toggle |
| `httpRoute.enabled` | `true` | Render HTTPRoute sub-App |
| `httpRoute.hostname` | `prometheus.example.com` | FQDN on the HTTPRoute |
| `httpRoute.gateway.name` / `namespace` | `cilium-gateway` / `default` | Gateway reference |
| `extraValues` | `{}` | Deep-merged on top of the computed upstream `valuesObject` |
| `catalog.repoURL` / `targetRevision` | this repo / `HEAD` | Where the httpRoute Application fetches manifests from |
| `syncPolicy` | automated + retry | Applied to all rendered Applications |

## Useful PromQL queries

### PVC / volume usage

```promql
# Used GiB per PVC
kubelet_volume_stats_used_bytes / 1024 / 1024 / 1024

# Usage percent per PVC
kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes * 100
```

### Cluster overview

```promql
# Node CPU busy %
100 - (avg by(instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# Node memory usage %
(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100

# Pod restarts
kube_pod_container_status_restarts_total > 0
```

## Related

- Flux equivalent: [`stuttgart-things/flux` — `infra/prometheus`](https://github.com/stuttgart-things/flux/tree/main/infra/prometheus)
- Upstream chart: <https://prometheus-community.github.io/helm-charts>
