# run-things-collector

Distributed cluster informer for the [run-things](https://github.com/stuttgart-things/run-things)
service portal. A small daemon ships in every member cluster, lists workloads
(Deployments, StatefulSets, DaemonSets, Services, Ingresses) on a schedule, and
pushes the snapshot — plus a heartbeat — to the central run-things server.

```
+---------------------+   POST /api/v1/collector/inventory
| collector-agent Pod | --------------------------------------> +-----------+
| (per member cluster)|   POST /api/v1/collector/heartbeat      | run-things|
+---------------------+ --------------------------------------> +-----------+
```

## What's deployed

The Helm chart in [`install/`](./install) emits per cluster:

- `Namespace` (default `run-things-collector`)
- `ServiceAccount`
- `ClusterRole` + `ClusterRoleBinding` — read-only on `apps/*`, `services`, `ingresses`
- `Deployment` running `ghcr.io/stuttgart-things/run-things-collector-agent`

When `applicationSet.enabled=true` (the default in `values.yaml`) the chart also
emits a single `ApplicationSet` that uses the `clusters` generator to fan the
chart out to every Argo CD-registered cluster matching the label selector
(`run-things/collector=enabled` by default). The rendered child Applications
re-use the same chart with `applicationSet.enabled=false` so we don't recurse.

## Opting a cluster in

Label the cluster Secret in the Argo CD namespace:

```bash
kubectl -n argocd label secret <cluster-secret> run-things/collector=enabled
```

## Bootstrap

Apply the parent ApplicationSet via Argo CD's app-of-apps pattern, or directly:

```bash
helm template run-things-collector ./install \
  --set server.url=https://run-things.example.com:50051 \
  --set image.tag=v0.1.0 | kubectl apply -f -
```

## Configuration

See [`install/values.yaml`](./install/values.yaml). Key settings:

| Value | Description |
|---|---|
| `server.url` | Base URL of the central run-things collector ingest port (default `:50051`) |
| `server.token` | Optional bearer token (use ExternalSecret in real envs) |
| `image.repository` / `image.tag` | Collector agent image |
| `reportInterval` | Full inventory cadence (default `60s`) |
| `heartbeatInterval` | Heartbeat cadence (default `30s`) |
| `namespaces` | Comma-separated namespace allow list (empty = cluster-wide) |
| `applicationSet.generators.clusters.selector` | Which Argo CD clusters get the collector |
