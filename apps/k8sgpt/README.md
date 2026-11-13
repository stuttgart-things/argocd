# k8sgpt

K8sGPT in operator mode **without an AI backend**, and optionally its
reporter. Deployed per cluster by `platforms/observability/appset-k8sgpt.yaml`
(labels `observability-platform/k8sgpt`, `…/k8sgpt-reporter`).

| Path | What |
|---|---|
| `install/` | app-of-apps chart: renders `<name>-operator`, `<name>-resources` and, with `reporter.enabled`, `<name>-reporter` |
| `resources/` | rendered onto the cluster by `<name>-resources`: the `K8sGPT` CR and the reporter's token ExternalSecret |

## Applications (sync waves)

| Wave | Application | Source | Content |
|---|---|---|---|
| 0 | `-operator` | chart `k8sgpt-operator` from `https://charts.k8sgpt.ai` | operator + CRDs (`K8sGPT`, `Result`, `Mutation`); Interplex off |
| 1 | `-resources` | `apps/k8sgpt/resources` | `K8sGPT` CR: `ai.enabled: false`, interval 5m, k8sgpt's analyzers **without ConfigMap**, `noCache`. Own Application because its kind comes with wave 0 (`SkipDryRunOnMissingResource`). Plus the ExternalSecret `homerun2-k8s-pitcher-token-k8sgpt` with the reporter |
| 2 | `-reporter` | `oci://ghcr.io/stuttgart-things/homerun2-k8s-pitcher-kustomize` | k8s-pitcher, `nameSuffix: -k8sgpt` (next to a homerun2 k8s-pitcher without collision). Profile: informer on `results` (add/update/delete, `updates: generation`, `includeObject`) and an hourly snapshot, both unthrottled, system `k8sgpt-<cluster>`, to `reporter.centralUrl`. ClusterRole: `results` get/list/watch, its token Secret get |

Each finding is a `Result` (`spec.kind`, `spec.name`, `spec.error[].text`);
the operator deletes it once the problem is gone. The central omni-pitcher
routes `system: k8sgpt` to the stream `k8sgpt`, which only the archive
(homerun2-s3-catcher → bucket `k8s-cluster-report`) reads. The K8sGPT sinks
and `remoteCache` are not used: without AI they would send empty texts, and
the cache stores AI answers, not reports.

## Values (`install/`)

| Value | Default | |
|---|---|---|
| `operator.chartVersion` | `0.2.29` | |
| `k8sgpt.version` | `v0.4.41` | k8sgpt server image |
| `k8sgpt.interval` | `5m` | |
| `k8sgpt.filters` | defaults without ConfigMap | empty = every default analyzer |
| `reporter.enabled` | `false` | |
| `reporter.centralUrl` / `reporter.cluster` | — | required with the reporter |
| `reporter.version` | `v1.9.0` | k8s-pitcher; ≥ v1.9.0 (throttle, snapshot, per-source system) |
| `reporter.snapshotInterval` | `1h` | |
| `reporter.secret` | store `vault`, entry `_omni-pitcher`, property `alertmanager-webhook-token` | the central omni-pitcher's token |

## Verify

```bash
kubectl -n k8sgpt-operator-system get k8sgpt,results,pods
kubectl -n k8sgpt-operator-system logs deploy/homerun2-k8s-pitcher-k8sgpt   # with the reporter
```
