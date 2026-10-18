# prometheus-pve-exporter

Pull-based Proxmox VE monitoring. kube-prometheus-stack's Prometheus scrapes
[`prometheus-pve-exporter`](https://github.com/prometheus-pve/prometheus-pve-exporter)
at `/pve?target=<host>`, and the exporter queries the Proxmox API **read-only**. A
Grafana dashboard ships as a ConfigMap that the kps Grafana sidecar imports. Port of
`stuttgart-things/flux` `infra/prometheus-pve-exporter`. These are plain manifests;
there is no upstream chart.

## Layout

```
infra/prometheus-pve-exporter/
├── install/    app-of-apps: renders Application "prometheus-pve-exporter-<hash>" (wave 10)
└── exporter/   leaf: Deployment, Service :9221, PodMonitor, ExternalSecret (opt), dashboard ConfigMap
    └── files/proxmox-pve.json
```

## Requirements

- **kube-prometheus-stack** in the destination namespace (default `monitoring`).
  The PodMonitor CRD comes from its operator and the dashboard needs its Grafana
  sidecar. The standalone prometheus chart has neither, so nothing fails and the
  metrics are simply missing.
- A **read-only PVE API token** (role `PVEAuditor`). Either:
  - `externalSecrets.enabled: true`: an ExternalSecret renders
    `Secret/prometheus-pve-exporter` from `remoteKey` (properties `user`,
    `token_name`, `token_value` -> `PVE_USER`, `PVE_TOKEN_NAME`, `PVE_TOKEN_VALUE`), or
  - an existing `Secret/prometheus-pve-exporter` with those three keys. Flux supplies
    it SOPS-encrypted; there is no sops equivalent here.

## Values

| Value | Default | Notes |
|---|---|---|
| `applicationName` | `prometheus-pve-exporter-<sha8(destination)>` | |
| `project`, `catalog.*`, `destination.*` | `default`, this repo/`HEAD`, in-cluster/`monitoring` | |
| `image.{repository,tag}` | `prompve/prometheus-pve-exporter` / `3.10.1` | renovate-tracked, same as Flux |
| `target` | `set-pve-exporter-target.invalid` | **set it**. The sentinel turns "no target" into a visible scrape error |
| `verifySSL` | `false` | `PVE_VERIFY_SSL` |
| `secretName` | `prometheus-pve-exporter` | |
| `externalSecrets.{enabled,refreshInterval,secretStore,remoteKey,properties}` | `false`, `1h`, CSS `""`, `pve-exporter`, `user`/`token_name`/`token_value` | |
| `scrape.{interval,scrapeTimeout}` | `60s` / `30s` | |
| `resources` | 25m/64Mi req, 200m/128Mi lim | |
| `reloader` | `true` | `reloader.stakater.com/auto` on the Deployment |
| `dashboard.enabled` | `true` | ConfigMap `pve-exporter-dashboard`, label `grafana_dashboard: "1"` |
| `syncPolicy` | automated, SSA, retry 5 | |

## The dashboard's `${...}`

In Flux the dashboard's Grafana variables are written `$${DS_PROMETHEUS}` /
`$${node}` so postBuild envsubst passes them through. Helm's `.Files.Get` does not
template the file, so `files/proxmox-pve.json` keeps them unescaped. Do not copy the
`$$` back in, because Grafana would then see a literal `$$`.

## Platform

`platforms/observability/appset-prometheus-pve-exporter.yaml`, opt-in with
`observability-platform/prometheus-pve-exporter: "true"`. Annotations:
`…/pve-exporter-target` (req), `…/pve-exporter-secret-store` (default
`…/secret-store`; with neither set, no ExternalSecret is rendered),
`…/pve-exporter-secret-key` (default `pve-exporter`), `…/pve-exporter-verify-ssl`
(default `false`).
