# fluent-bit

[Fluent Bit](https://fluentbit.io/) as a DaemonSet: every container log of the
cluster, with its Kubernetes metadata, pushed to a Loki -- in this lab the
central one on `platform` (`loki.platform.sthings.lab`).

The Argo CD counterpart of stuttgart-things/flux `infra/fluent-bit`
(+ `components/remote`). The `[INPUT]`, `[FILTER]` and `[OUTPUT]` sections are
the same, so a stream from an Argo CD cluster looks exactly like one from a
Flux cluster:

| label | value |
|---|---|
| `job` | `fluent-bit` |
| `cluster` | `clusterName` |
| `namespace_name`, `pod_name`, `container_name` | from the Kubernetes filter |

Fan-out across clusters: `platforms/observability/appset-fluent-bit.yaml`.

## Deploy it on the workload cluster

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: fluent-bit-<cluster>-parent
  namespace: argocd
spec:
  project: <cluster>
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: infra/fluent-bit/install
    helm:
      valuesObject:
        applicationName: fluent-bit-<cluster>
        project: <cluster>
        destination:
          name: <cluster>
          namespace: logging
        clusterName: <cluster>
        loki:
          host: loki.platform.sthings.lab
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
```

## TLS

With `loki.tls: true` (default) fluent-bit pushes HTTPS to `loki.port` (443)
and verifies the certificate against `trustBundle` -- by default the
`cluster-trust-bundle` ConfigMap trust-manager writes into every namespace on
clusters with `network-platform/trust-manager-bundle`. That bundle carries the
Vault/OpenBao PKI root on clusters that use a `vault-pki*` issuer, which is the
root the lab's Gateway certificates chain to.

The ConfigMap is mounted **optional**: the pod starts without it, and then
every push fails TLS verification. If the first pushes failed because the
namespace was created before trust-manager filled it, restart the DaemonSet
once.

`loki.tls: false` + `loki.port: 80` for a Loki in the same cluster
(`loki-gateway.<ns>.svc.cluster.local`).

## Values

| Value | Default | Description |
|---|---|---|
| `project` | `default` | AppProject of the rendered Application |
| `applicationName` | derived | name of the rendered Application |
| `destination.server` / `.name` | in-cluster | the **workload** cluster |
| `destination.namespace` | `logging` | |
| `chartVersion` | `0.58.3` | upstream chart (Fluent Bit 5.1.3), same as stuttgart-things/flux |
| `clusterName` | *(required)* | `cluster` label on every stream |
| `loki.host` | *(required)* | Loki gateway host |
| `loki.port` | `443` | |
| `loki.tls` | `true` | HTTPS + verification against `trustBundle` |
| `loki.tenantId` | `""` | `X-Scope-OrgID`; empty for a single-tenant Loki |
| `trustBundle.configMap` / `.key` | `cluster-trust-bundle` / `trust-bundle.pem` | CA bundle, mounted optional |
| `resources` | 20m / 64Mi, limit 256Mi | DaemonSet container |
| `extraValues` | `{}` | deep-merged over the computed upstream values |
| `syncPolicy` | automated, prune, selfHeal, SSA | of the rendered Application |
