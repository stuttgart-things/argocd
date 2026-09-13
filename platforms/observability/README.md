# platforms/observability

Observability platform bundle: `ApplicationSet`s on the management cluster that fan out the monitoring stack to every cluster labelled as an observability target.

All ApplicationSets share one master gate — the ArgoCD cluster `Secret` must carry:

```
observability-platform: "true"
```

Catalog entries rendered:

| ApplicationSet | Wave | Catalog path | Workload namespace | Notes |
|---|---|---|---|---|
| `kube-prometheus-stack-observability` | 5 | `infra/kube-prometheus-stack/install` | `monitoring` | The whole stack: Prometheus Operator + CRDs, Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics, default rules. Grafana behind the cluster's gateway, Grafana admin and webhook token from a ClusterSecretStore, warning/critical alerts to a webhook |

`project: '{{ .name }}'` on every generated Application — the `AppProject` named after the cluster must exist first (see [`config/cluster-project`](../../config/cluster-project/), driven by the `cluster-projects` ApplicationSet on clusters labelled `auto-project=true`).

Wave 5 puts it after storage (-10) and ESO (-10), which it needs: a PVC for Prometheus, and ExternalSecrets for its two Secrets. As in `platforms/network`, sync-wave on top-level Applications is informational; the retries cover the race.

## Install

Bootstrap the platform itself (one-shot, on the management cluster):

```bash
kubectl apply -f platforms/observability/application.yaml
```

That creates an `Application` named `observability-platform` pointing at this directory. The ApplicationSets become active as soon as a cluster Secret carries the labels below.

## Per-cluster opt-in

Like `security-platform`, and for the same reason, the umbrella label alone installs nothing. The stack needs things the platform cannot create for it: a ClusterSecretStore that can read an entry holding the Grafana admin and the webhook token, and a webhook to send alerts to. So there is a **gate label** as well, present only once those exist:

| On the cluster (ClusterbookCluster `spec.labels` / `spec.annotations`) | Kind | Effect |
|---|---|---|
| `observability-platform: 'true'` | label | umbrella |
| `observability-platform/kube-prometheus-stack` | label | `'false'` opts out; absent or `'true'` = in |
| `observability-platform.stuttgart-things.com/secrets-config` | label, **gate** (`Exists`) | present = the store and entry below exist |
| `observability-platform.stuttgart-things.com/secret-store` | annotation **(user, req)** | ClusterSecretStore name, e.g. `vault-observability` |
| `observability-platform.stuttgart-things.com/secret-key` | annotation (user) | entry name in that store; default = cluster name |
| `observability-platform.stuttgart-things.com/alert-webhook-url` | annotation **(user, req)** | where warning/critical alerts go, e.g. `https://omni.platform.sthings-vsphere.labul.sva.de/pitch/grafana` |
| `observability-platform.stuttgart-things.com/storage-class` | annotation (user) | Prometheus PVC class; default = cluster default. Set it on clusters with two defaults |
| `observability-platform.stuttgart-things.com/storage-size` | annotation (user) | default `10Gi` |
| `observability-platform.stuttgart-things.com/retention` | annotation (user) | default `15d` |
| `clusterbook.stuttgart-things.com/fqdn` | annotation *(auto)* | Grafana at `grafana.<fqdn without *.>` on `<cluster>-gateway` |

The entry the store reads needs three properties: `grafana-admin-user`, `grafana-admin-password`, `alertmanager-webhook-token` (Bearer token for the webhook). The webhook's certificate is checked against `cluster-trust-bundle` from `network-platform/trust-manager-bundle`.

**The quiet failure:** a ClusterSecretStore that reports `Valid` / `Ready=True` only proves the login works. If the cluster's Vault role lacks the policy for the entry, both ExternalSecrets fail with a 400, Grafana does not start, and Alertmanager never gets its token file. Check with `kubectl -n monitoring get externalsecret`.

Every alert carries `cluster: <name>` as an external label, so a shared channel shows where it came from.

## Opt-out and teardown

Set `observability-platform/kube-prometheus-stack: 'false'` (or remove the umbrella label). The generated Application is deleted with prune; the PVC of the Prometheus StatefulSet stays, as PVCs of StatefulSets do.
