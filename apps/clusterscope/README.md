# apps/clusterscope

Catalog entry for [clusterscope](https://github.com/stuttgart-things/clusterscope), a lab
visualizer. It renders the cluster directories of a GitOps repository, which a git-sync sidecar
clones into the pod. In live mode it also shows the GitOps status, workload health and HTTPRoute
endpoints of every cluster in the lab.

Port of [`stuttgart-things/flux` — `apps/clusterscope`](https://github.com/stuttgart-things/flux/tree/main/apps/clusterscope).
In flux, the `${VAR:-default}` substitutions and the opt-in kustomize components set the
behaviour. Here they are values: each component is an `enabled` switch. The platform entry is
[`platforms/observability/appset-clusterscope.yaml`](../../platforms/observability/appset-clusterscope.yaml).

## Layout

```
apps/clusterscope/
├── install/     app-of-apps chart (what consumers point at) — renders:
│                  <name>            wave 0   OCI kustomize base + args/git-sync patches
│                  <name>-config     wave -1  config ConfigMap + ExternalSecrets  (config / vaultGitAuth / vaultKubeconfigs)
│                  <name>-httproute  wave 10  HTTPRoute                              (httpRoute.enabled, default on)
│                  <name>-probes     wave 10  ScrapeConfig in `monitoring`           (blackboxProbes.enabled)
├── config/      sub-chart: ConfigMap clusterscope-config, ExternalSecrets git-sync-auth + clusterscope-kubeconfigs
├── httproute/   sub-chart: HTTPRoute clusterscope → Service clusterscope:8080
└── probes/      sub-chart: ScrapeConfig clusterscope-endpoints
```

`<name>` is `applicationName`. Left empty, it becomes `clusterscope-<sha1(destination)[:8]>`.

## Flux → values

| Flux | Here |
|---|---|
| `release.yaml` (OCIRepository + Kustomization `clusterscope-deploy`) | `<name>` Application on `oci://ghcr.io/stuttgart-things/clusterscope-kustomize` at `version` |
| `CLUSTERSCOPE_VERSION` | `version` (default `v0.26.0`, Renovate-tracked). The base pins the image of the same version |
| `CLUSTERSCOPE_NAMESPACE` | `destination.namespace` (kustomize `namespace`, which renames the base's Namespace) |
| `CLUSTERSCOPE_TECH` / `_LAB` / `_LIVE` / `_SELF_CLUSTER` / `_KUBECONFIG_DIR` / `_PROBE` / `_REFRESH` | `clusterscope.tech` / `.lab` / `.live` / `.selfCluster` / `.kubeconfigDir` / `.probe` / `.refresh` |
| `CLUSTERSCOPE_CONFIG_FILE` | derived: `/etc/clusterscope/config.yaml` when `config.enabled` |
| `CLUSTERSCOPE_TRUST_BUNDLE_CONFIGMAP` / `_KEY` | `trustBundle.configMap` / `.key` |
| `GIT_SYNC_REPO` / `_BRANCH` / `_PERIOD` / `_DIR` / `_IMAGE` / `_AUTH_SECRET` | `gitSync.repo` / `.branch` / `.period` / `.dir` / `.image.{repository,tag}` / `.authSecret` |
| `components/config` + `CLUSTERSCOPE_CONFIG` | `config.enabled` + `config.content` (YAML, or one line of JSON) |
| `components/git-sync-extra` + `GIT_SYNC_EXTRA_*` | `gitSyncExtra.{enabled,repo,branch,period}` |
| `components/vault-git-auth` + `GIT_SYNC_AUTH_STORE` / `_PATH` / `_*_PROPERTY` | `vaultGitAuth.{enabled,secretStore,path,usernameProperty,passwordProperty}` |
| `components/vault-kubeconfigs` + `CLUSTERSCOPE_KUBECONFIG_STORE` / `_CLUSTERS` | `vaultKubeconfigs.{enabled,secretStore,clusters}` |
| `CLUSTERSCOPE_ESO_REFRESH_INTERVAL` | `esoRefreshInterval` |
| `httproute.yaml` + `GATEWAY_NAME` / `GATEWAY_NAMESPACE` / `HOSTNAME`.`DOMAIN` | `httpRoute.{enabled,hostname,gateway.{name,namespace,sectionName}}`. `hostname` is the full FQDN |
| `components/blackbox-probes` + `CLUSTERSCOPE_BLACKBOX_*` | `blackboxProbes.{enabled,namespace,prometheusRelease,module,address,interval,sdRefresh}` |

Changes from the flux version, all deliberate:

- **No `CLUSTERSCOPE_PORT`.** The base fixes its Service, containerPort and liveness/readiness
  probes at 8080. Moving `-serve` on its own would leave the pod restarting on a failing liveness
  probe.
- **`-config` and `-kubeconfig-dir` are derived from the switches.** In flux you set a second
  variable (`CLUSTERSCOPE_CONFIG_FILE`, `CLUSTERSCOPE_KUBECONFIG_DIR`) that had to agree with the
  component. `clusterscope.kubeconfigDir` still overrides the derived directory.
- **Switches accept `true`/`false` or the strings `"true"`/`"false"`**, because an
  ApplicationSet can only template strings.
- **`blackboxProbes` without `clusterscope.live` refuses to render.** Without live mode,
  `/api/targets` returns an empty list.
- **The flux `$patch: delete` of a base HTTPRoute is kept, but as a guard only.** v0.26.0 ships
  no HTTPRoute, so it does nothing.
- **There is no `namespace.yaml`.** The base already ships the Namespace. `CreateNamespace=true`
  lets the wave −1 `-config` Application create the namespace before the base does.

## Usage

Minimal, for a public repository:

```yaml
project: default
destination:
  server: https://kubernetes.default.svc
  namespace: clusterscope
gitSync:
  repo: https://github.com/stuttgart-things/harvester   # no ".git": the link is named after it
  dir: /data/harvester/clusters
httpRoute:
  hostname: clusterscope.example.com
  gateway: {name: cilium-gateway, namespace: default}
```

### Lab view with live mode (example: LabUL on platform-sthings)

clusterscope reads its own cluster through the in-cluster ServiceAccount and the lab's other
clusters through kubeconfigs from Vault. The repository is private, so git-sync also gets a
token from Vault:

```yaml
clusterscope:
  lab: labul
  live: true
  probe: true
  selfCluster: platform-sthings
gitSync:
  repo: https://github.com/stuttgart-things/stuttgart-things
  dir: /data/stuttgart-things/clusters/labul
vaultKubeconfigs:
  enabled: true
  secretStore: {kind: ClusterSecretStore, name: vault-kubeconfigs}
  clusters: ^(infra-sthings|homerun2-dev2)$
vaultGitAuth:
  enabled: true
  secretStore: {kind: ClusterSecretStore, name: vault-homerun2-cd}
  path: homerun2-cd/data/kargo
  usernameProperty: gitUsername
  passwordProperty: gitToken
```

`vaultKubeconfigs` picks the Vault entries whose names match `clusters`. These are KV v2 entries:
the path is the cluster name and the property is `kubeconfig`. It writes them into one Secret
with one key per cluster and mounts it at `/kubeconfigs`. Both Secrets are optional for the pod.
It starts without them and picks up the kubeconfigs once ESO has synced. The git credentials are
the exception, see the next paragraph.

**Git credentials are read only when git-sync starts.** The Secret reaches the container as env,
so ESO creating it later does not reach a running git-sync. The `-config` Application syncs one
wave earlier to give ESO a head start. git-sync exits when its first sync fails and comes back
with the Secret once it exists. Until git-sync has cloned the repo, `-root` does not exist, and
clusterscope restarts a few times before settling.

### Clusters from a second repo (`config` + `gitSyncExtra`)

```yaml
config:
  enabled: true
  content: |
    roots:
      - path: /data/stuttgart-things/clusters/labul
      - path: /data-extra/harvester/clusters
        name: harvester
        include: [edge-test2]
    clusters:
      edge-test2: {name: edge-tt-test2, lab: labul}
    # v0.25.0+: IP / DNS allocations matched against the clusters
    # clusterbooks:
    #   - {url: https://clusterbook.infra.sthings-vsphere.labul.sva.de, lab: labul}
gitSyncExtra:
  enabled: true
  repo: https://github.com/stuttgart-things/harvester
```

The second repo gets its own git-sync on its own volume and is cloned to
`/data-extra/<last URL segment>`. `-config` replaces `-root`. Roots that are not cloned yet are
picked up once they appear. With `reloader: true` (the default), a change to the ConfigMap
restarts the pod, provided [`infra/reloader`](../../infra/reloader/) runs on the cluster.

### Blackbox probes for every endpoint (`blackboxProbes`)

In live mode, clusterscope serves every HTTPRoute URL of the lab at `/api/targets` in Prometheus
`http_sd` format, with the labels `cluster`, `namespace`, `route` and `app`. The `-probes`
Application adds a Prometheus Operator `ScrapeConfig` that probes each URL through the blackbox
exporter.

The defaults match the catalog's own components on the same cluster:

| Needs | Catalog entry | Why the default fits |
|---|---|---|
| ScrapeConfig CRD + a Prometheus that selects it | [`infra/kube-prometheus-stack`](../../infra/kube-prometheus-stack/) | Installed as release `kube-prometheus-stack`. It sets the `*SelectorNilUsesHelmValues` flags to false for ServiceMonitor, PodMonitor, Probe and Rule, but **not** for ScrapeConfig. The upstream default therefore holds: `scrapeConfigSelector: {release: kube-prometheus-stack}` and `scrapeConfigNamespaceSelector: {}`. That matches the label `blackboxProbes.prometheusRelease` and works from any namespace |
| A blackbox exporter | [`infra/blackbox-exporter`](../../infra/blackbox-exporter/) in `monitoring` | Release `blackbox-exporter` of `prometheus-blackbox-exporter` gives the Service `blackbox-exporter-prometheus-blackbox-exporter:9115`, which is `blackboxProbes.address` |

The series carry `probe_source="clusterscope"`. They also feed the blackbox-exporter chart's
generic `BlackboxProbeFailed` (critical) rule. **Pick the module with care.** clusterscope counts
a route as reachable when it answers below 500, which includes `401`/`403` behind a login and
`404` on an app without a root page. `http_2xx` fails on all of those and pages.
`infra/blackbox-exporter` ships only `http_2xx` and `http_2xx_untrusted_ca`. For anything
broader, add a module to its `config.modules`, for example `valid_status_codes` covering
200–499, and name it in `blackboxProbes.module`.

## Values

See [`install/values.yaml`](./install/values.yaml). Every value is commented there, and
[`install/values.schema.json`](./install/values.schema.json) enforces them with
`additionalProperties: false`.
