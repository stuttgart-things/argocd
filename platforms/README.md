# Platforms — ClusterbookCluster reference

This directory holds the **platform ApplicationSets** that turn a registered
cluster into a working environment. You don't edit them per cluster — instead
you register a `ClusterbookCluster` with the right **labels** (which platform
components to install) and **annotations** (their parameters), and the AppSets
here fan out to that cluster.

- **Full annotated template:** [`cluster.reference.yaml`](./cluster.reference.yaml)
- **Real examples:** `clusters/labul/vsphere/platform-sthings/argocd/<cluster>/cluster.yaml`

## How it wires together

```
cluster.yaml (ClusterbookCluster)
   │  controller reserves IP/DNS, renders an ArgoCD cluster Secret
   ▼
cluster Secret  ── labels ──▶  AppSet cluster generator selects the cluster
                └ annotations ▶  AppSet template reads component parameters
   ▼
platforms/<profile>/appset-*.yaml  ──▶  one Application per matched cluster
```

Convention: `<profile>: 'true'` is the **umbrella** switch; `<profile>/<component>`
toggles one component (only fires if its umbrella is also `true`). Every value is
an explicit `'true'`/`'false'` string — selectors match on `"false"`, so leave a
component at `'false'` rather than omitting it.

## Profiles

### `base-platform` — what every cluster gets
| Label | AppSet | Needs annotations |
|---|---|---|
| `base-platform/reloader` | `appset-reloader` → Stakater Reloader in `reloader` on the workload cluster | — |

Not owned by any one app platform, but depended on by several: ESO refreshes a
Secret and the Pods holding the old value keep holding it. **Inert until a
workload opts in** with `reloader.stakater.com/auto: "true"` — installing the
bundle changes the behaviour of nothing already running. See
[`platforms/base`](./base/).

### `cicd-platform` — vSphere CI/CD stack
| Label | AppSet | Needs annotations |
|---|---|---|
| `cicd-platform/crossplane` | `appset-crossplane` (+ configs/functions/provider-configs/providers) | — |
| `cicd-platform/kro` | `appset-kro` | — |
| `cicd-platform/tekton` | `appset-tekton` (+ config, dashboard-httproute) | — |
| `cicd-platform/dapr` | `appset-dapr` | — |
| `cicd-platform/kargo` | `appset-kargo` (+ httproute) | — |
| `cicd-platform/argo-rollouts` | `appset-argo-rollouts` | — |
| `cicd-platform/openebs` | `appset-openebs` (cicd) | — (prefer `storage-platform/openebs`; keep mutually exclusive) |
| `cicd-platform/machinery` | `machinery-cicd` (resource dashboard + gRPC ResourceService → `apps/machinery/install`) | `…/fqdn` *(auto)*, `…/allocation-ip` *(auto)* — clusterbook-registered clusters only |
| `cicd-platform/clusterbook-operator` | `appset-clusterbook-operator` → clusterbook-operator in `clusterbook-system` (`apps/clusterbook-operator/install`) | — — **opt-in**, an explicit `'true'`, and ONLY on the cluster that hosts Argo CD (it writes the cluster Secrets there; the mgmt cluster needs a declared in-cluster Secret carrying the labels). Optional `…/clusterbook-operator-namespace` (def `clusterbook-system`), `…/clusterbook-operator-trust-bundle` (def `cluster-trust-bundle`). Needs a `ClusterbookProviderConfig` `default` seeded from the cluster repo |
| `cicd-platform/komoplane` | `appset-komoplane` → read-only Crossplane UI (`cicd/komoplane/install`) + HTTPRoute `komoplane.<fqdn>` | — — **opt-in**, an explicit `'true'`: the UI has NO authentication, lab-internal gateways only. Shares the `cicd-platform/crossplane` opt-out; `…/fqdn` *(auto)* for the route |
| `cicd-platform/crossplane-configs-flux` | `appset-crossplane-configs-flux` → `cicd/crossplane/configs` + `profiles/flux.yaml` (flux-family `ghcr.io/stuttgart-things/crossplane/*` Configurations) | — — **opt-in**; also EXCLUDES the cluster from `appset-crossplane-configs`: one Configuration family per cluster, never both (duplicate lock node → every package Healthy=False). Choose the family when the cluster is built |
| `cicd-platform/crossplane-cap-vspherevm` / `-proxmoxvm` / `-ansible-run` / `-packer` / `-harvester-vm` | `appset-crossplane-capabilities` → `cicd/crossplane/capabilities` (OCI charts `ghcr.io/stuttgart-things/charts/*`, credentials via ESO) | — — **opt-in** per capability; skipped where the old `cicd-platform/crossplane-{vspherevm,proxmoxvm,ansible}: 'true'` label is set. Optional `…/crossplane-cap-{vspherevm,proxmoxvm,ansible-run}-environment` (def `labda`/`labul`/`labda`), `…/crossplane-cap-ansible-run-secret-store`, `…/crossplane-cap-vault-auth-mount` (def `<cluster>-eso`), `…/crossplane-cap-storage-class` (def `openebs-hostpath`), `…/crossplane-cap-tekton-namespace` (def `tekton-ci`), `…/crossplane-cap-harvester-{environment,provider-config,storage-class,namespace,network,image}` |

### `network-platform` — Cilium + cert-manager + trust-manager
| Label | AppSet | Needs annotations |
|---|---|---|
| `network-platform/cilium-lb` | `appset-cilium-lb` | `…/ip` *(auto)* |
| `network-platform/cilium-gateway` | `appset-cilium-gateway` | `…/fqdn` *(auto)* |
| `network-platform/cilium-gateway-secondary` | `appset-cilium-gateway-secondary` | `…/fqdn-secondary` *(auto)* |
| `network-platform/cert-manager-install` | `appset-cert-manager-install` | — |
| `network-platform/cert-manager-selfsigned` | `appset-cert-manager-selfsigned` | — |
| `network-platform/cert-manager-cluster-ca` | `appset-cert-manager-cluster-ca` | `…/fqdn` *(auto)*, `…/wildcard-issuer-name` **(user)** |
| `network-platform/cert-manager-vault-pki` | `appset-cert-manager-vault-pki` | `…/vault-server`, `…/vault-pki-path`, `…/vault-token-secret` **(user)** |
| `network-platform/trust-manager-install` | `appset-trust-manager-install` | — |
| `network-platform/trust-manager-bundle` | `appset-trust-manager-bundle` | — (auto-adds the Vault PKI CA when `…/cert-manager-vault-pki` is `'true'` **or** `…/wildcard-issuer-name` starts with `vault-pki`; that Secret must exist on the target) |

### `storage-platform`
| Label | AppSet | Needs annotations |
|---|---|---|
| `storage-platform/openebs` | `appset-openebs` (storage) → `openebs-hostpath` **default SC** + VolumeSnapshot CRDs | — |
| `storage-platform/longhorn` | `appset-longhorn` | — |
| `storage-platform/cloudnative-pg` | `appset-cloudnative-pg` → CloudNativePG operator (CRDs + operator in `postgres`) | — — **opt-in**, an explicit `'true'`. A singleton per cluster: `tabletennis-platform` needs it, anything else growing a Postgres uses the same one. The Barman Cloud plugin is its own opt-in appset, the row above |
| `storage-platform/cloudnative-pg-barman` | `appset-cloudnative-pg-barman` → the Barman Cloud backup plugin, beside the operator in `postgres` | — — **opt-in**, and needs `storage-platform/cloudnative-pg: 'true'` too. Also a singleton: CloudNativePG finds plugins only in the operator's own namespace. Needs cert-manager on the cluster. Installing it backs nothing up — a database still opts in with an `ObjectStore` + `ScheduledBackup` |
| `storage-platform/velero` | `appset-velero` → Velero + `cloud-credentials` ExternalSecret + Schedule `daily-all` in `velero` | — — **opt-in**, an explicit `'true'`. `…/velero-s3-url` **(user)**; optional `…/velero-bucket` (def `velero`), `…/velero-prefix` (def cluster), `…/velero-secret-store` / `…/velero-secret-key` (def `…/shared-velero-secret-*` *(auto, ClusterStack)*, else `vault-<cluster>` / `velero`), `…/velero-schedule-cron` (def `0 2 * * *`, `off` = none), `…/velero-schedule-ttl` (def `720h0m0s`), `…/velero-ssl-cert-dir` (def `/etc/ssl/custom`). Needs external-secrets + the store |
| `storage-platform/backstage-rag-postgres` | `appset-backstage-rag-postgres` → CNPG `Cluster` + pgvector for the Backstage RAG-AI plugin, in the Backstage namespace (def `portal`) | — — **opt-in**, an explicit `'true'`, and needs `storage-platform/cloudnative-pg: 'true'` too. Optional `…/backstage-namespace`, `…/backstage-rag-postgres-{storage-class,storage-size,secret-store,secret-key}`; backups off unless `…/backstage-rag-postgres-backup-enabled: 'true'` (needs `cloudnative-pg-barman`, `…/backstage-rag-postgres-s3-url` def `https://artifacts.<fqdn>`, `…/backstage-rag-postgres-{bucket,s3-secret-key,ca-configmap}`); Velero Schedule via `…/backstage-rag-postgres-velero-enabled`. Backstage itself is not wired to it yet — see `apps/backstage-rag-postgres` |
| `storage-platform/nfs-csi-install` | `appset-nfs-csi-install` (driver + snapshot-controller) | — |
| `storage-platform/nfs-csi-storageclasses` | `appset-nfs-csi-storageclasses` | **gate label** `storage-platform.stuttgart-things.com/nfs-config` + `…/nfs-server`, `…/nfs-share` **(user)**; optional `…/nfs-version` (def 4.1), `…/nfs-name` (def `nfs-csi`), `…/nfs-subdir` (def cluster), `…/nfs-mount-permissions` (def `0`) |

> ⚠️ The nfs-csi StorageClass AppSet **also requires** the gate label
> `storage-platform.stuttgart-things.com/nfs-config` (operator `Exists`). Setting
> `storage-platform/nfs-csi-storageclasses: 'true'` alone installs nothing.
> On the labul NFS server (`10.31.101.26`) use `nfs-version: '3'` — it's NFSv3-only.

### `security-platform`
| Label | AppSet |
|---|---|
| `security-platform/external-secrets` | `appset-external-secrets-install` |
| `security-platform/kyverno` | `appset-kyverno-install` |
| `security-platform/sops-secrets-operator` | `appset-sops-secrets-operator` → sops-secrets-operator in `sops-secrets-operator-system` — **opt-in** `'true'`; optional `security-platform.stuttgart-things.com/sops-age-key-store` (set = ExternalSecret `sops-age-key` from that store; needs `security-platform/external-secrets`), `…/sops-age-key-secret-key` (def `sops-age-key`), `…/sops-age-key-property` (def `age.agekey`). No cert-manager needed (the v0.9.2 base ships no webhook) |
| `security-platform/openbao` | `appset-openbao` → OpenBao in `openbao` — **opt-in** `'true'`. `…/openbao-storage-class` **(user, required)**, `…/openbao-seal` (def `transit`; `static`/`none`), `…/openbao-seal-address` (transit) / `…/openbao-seal-key-id` (static) **(user)**; optional `…/openbao-seal-key-name` (def `openbao-unseal`), `…/openbao-seal-mount-path` (def `transit/`), `…/openbao-topology` (def `multi-node`), `…/openbao-init` (def `none`; `self-init-userpass`), `…/openbao-storage-size` (def `8Gi`), `…/openbao-secret-store` (def `vault-<cluster>`), `…/openbao-secret-key` (def `openbao`), `…/openbao-hostname` (def `openbao.<fqdn>`). Needs external-secrets + the store |

### `observability-platform` — kube-prometheus-stack
| Label | AppSet | Needs annotations |
|---|---|---|
| `observability-platform/kube-prometheus-stack` | `appset-kube-prometheus-stack` → Prometheus Operator, Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics | **gate label** `observability-platform.stuttgart-things.com/secrets-config` + `…/secret-store`, `…/alert-webhook-url` **(user)**; optional `…/secret-key` (def cluster), `…/storage-class` (def cluster default), `…/storage-size` (def `10Gi`), `…/retention` (def `15d`); `…/fqdn` *(auto)* for Grafana |
| `observability-platform/clusterscope` | `appset-clusterscope` → clusterscope lab visualizer (+ optional blackbox ScrapeConfig via label `…/clusterscope-blackbox-probes`) | **opt-in**; `…/clusterscope-git-repo` **(user, req)**; optional `…/clusterscope-*` (see [`platforms/observability`](./observability/)); `…/fqdn` *(auto)*. The probes need `…/clusterscope-live: 'true'`, kube-prometheus-stack and a blackbox exporter in `monitoring` (no platform AppSet installs `infra/blackbox-exporter` yet) |
| `observability-platform/prometheus-pve-exporter` | `appset-prometheus-pve-exporter` → Proxmox VE exporter, PodMonitor, Grafana dashboard | **opt-in**; `…/pve-exporter-target` **(user)**; optional `…/pve-exporter-secret-store` (def `…/secret-store`; neither = hand-made Secret `prometheus-pve-exporter`), `…/pve-exporter-secret-key` (def `pve-exporter`), `…/pve-exporter-verify-ssl` (def `false`) |

> ⚠️ Like the NFS StorageClass, the stack **also requires** its gate label
> `observability-platform.stuttgart-things.com/secrets-config` (operator `Exists`) —
> set it once the ClusterSecretStore and its entry (`grafana-admin-user`,
> `grafana-admin-password`, `alertmanager-webhook-token`) exist. See
> [`platforms/observability`](./observability/).

### `kind-platform` — only when `spec.clusterType: kind`
| Label | AppSet |
|---|---|
| `kind-platform/cilium-install` | `appset-cilium-install-kind` |
| `kind-platform/cilium-lb` | `appset-cilium-lb-kind` |
| `kind-platform/cert-manager-install` | `appset-cert-manager-install-kind` |
| `kind-platform/cert-manager-selfsigned` | `appset-cert-manager-selfsigned-kind` |

`expose-external` (gateway/cluster-ca for kind) is gated by the annotation
`clusterbook.stuttgart-things.com/expose-external: 'true'` (+ `lb-range-start/stop`).

### `homerun2-platform` — the homerun2 event bus
| Label | AppSet | Needs annotations |
|---|---|---|
| `homerun2-platform` | `appset-homerun2` → by default redis-stack + omni-pitcher + core-catcher + scout + led-catcher (the `flux/apps/homerun2/profiles/platform` set), their routes and their ExternalSecrets; every component is a label (below) | **gate** `homerun2-platform.stuttgart-things.com/secrets-config: 'true'` + `…/secret-store` **(user)**; optional `…/secret-key` (def cluster name), `…/storage-class` (def `openebs-hostpath`), `…/redis-storage-size` (def `8Gi`), `…/redis-image-tag` (def chart); `…/fqdn` *(auto)* for every hostname |

Opt one cluster out with `homerun2-platform/stack: 'false'`. Components are
per-cluster labels: **core** ones are on unless `homerun2-platform/<component>:
'false'`, **extras** are off unless `'true'`:

| Component | Kind | Label to flip it | Notes |
|---|---|---|---|
| redis-stack | core (on) | `homerun2-platform/redis-stack: 'false'` | every catcher/pitcher needs a Redis; off only with another one |
| omni-pitcher | core (on) | `homerun2-platform/omni-pitcher: 'false'` | route inline (`inlineHttpRoute: true`, #518) |
| core-catcher | core (on) | `homerun2-platform/core-catcher: 'false'` | |
| scout | core (on) | `homerun2-platform/scout: 'false'` | no ScoutProfile: alerting off |
| led-catcher | core (on) | `homerun2-platform/led-catcher: 'false'` | |
| light-catcher | extra (off) | `homerun2-platform/light-catcher: 'true'` | drives WLED; the mock unless configured |
| wled-mock | extra (off) | `homerun2-platform/wled-mock: 'true'` | dev/lab |
| demo-pitcher | extra (off) | `homerun2-platform/demo-pitcher: 'true'` | dev/lab |
| config-viewer | extra (off) | `homerun2-platform/config-viewer: 'true'` | read-only view |
| notification-catcher | extra (off) | `homerun2-platform/notification-catcher: 'true'` | needs its notify ConfigMap + Teams webhook, out of band |
| git-pitcher | extra (off) | `homerun2-platform/git-pitcher: 'true'` | needs the shared GitHub token (`…/shared-git-pat-secret-key`) |
| k8s-pitcher | extra (off) | `homerun2-platform/k8s-pitcher: 'true'` | needs cluster RBAC + a profile ConfigMap |
| smoke-test | extra (off) | `homerun2-platform/smoke-test: 'true'` | |

See [`platforms/homerun2`](./homerun2/).

### `tabletennis-platform` — schmetterpause + zaehlwerk
| Label | AppSet | Needs annotations |
|---|---|---|
| `tabletennis-platform` | `appset-tabletennis` → schmetterpause + its CNPG database, zaehlwerk, and (opt-in) the LED strip at the table | **gate** `tabletennis-platform.stuttgart-things.com/secrets-config: 'true'` + `…/secret-store` **(user)**; optional `…/storage-class`, `…/db-storage-size` (def `8Gi`), `…/db-image-name` (def `postgresql:18`), `…/homerun2-namespace` (def `homerun2`), `…/wled-endpoint`; `…/fqdn` *(auto)* |
| `tabletennis-platform/light-catcher` | the LED strip, an opt-in `'true'` — physical hardware, so per cluster | `…/wled-endpoint` **(user)**, optional |
| `tabletennis-platform/piezo-sim` | the piezo board simulator, an opt-in `'true'` — plays every match started on the page; results are handed over, so demo/test clusters only | — |

> ⚠️ **Requires `storage-platform/cloudnative-pg: 'true'`.** schmetterpause's
> database is a CNPG `Cluster`; without the CRD that Application's dry-run
> rejects the whole apply.

Opt out with `tabletennis-platform/tabletennis: 'false'`. See
[`platforms/tabletennis`](./tabletennis/).

### Opt-in app/preview platforms (single label, no umbrella)
`homerun2-pr-preview` · `machinery-pr-preview` · `machinery-catalog-publisher-pr-preview` · `schmetterpause-pr-preview` · `zaehlwerk-pr-preview`
— set the label to `'true'` to fan the matching `platforms/<name>/` AppSets onto the cluster.

## Annotations: who sets them

- **`[auto]` controller-stamped** (from reservation/spec — never set by hand):
  `cluster-name`, `ip`, `fqdn`, `fqdn-secondary`, `lb-range-start`, `lb-range-stop`, `cluster-type`, allocation-*.
- **`[user]` you provide** (component config):
  `vault-server` / `vault-pki-path` / `vault-token-secret`, `wildcard-issuer-name`,
  `expose-external`, all `storage-platform.stuttgart-things.com/nfs-*`, and all
  `observability-platform.stuttgart-things.com/*`,
  `homerun2-platform.stuttgart-things.com/*` and
  `tabletennis-platform.stuttgart-things.com/*`.

## Presets

### `cicd-vsphere` — full CI/CD workload cluster (e.g. crossplane-dev1)
```yaml
spec:
  clusterType: default
  labels:
    cicd-platform: 'true'
    cicd-platform/crossplane: 'true'
    cicd-platform/kro: 'true'
    cicd-platform/tekton: 'true'
    cicd-platform/machinery: 'true'                  # resource dashboard + gRPC ResourceService
    network-platform: 'true'
    network-platform/cilium-lb: 'true'
    network-platform/cilium-gateway: 'true'
    network-platform/cert-manager-install: 'true'
    network-platform/cert-manager-selfsigned: 'true'
    network-platform/cert-manager-cluster-ca: 'true'
    network-platform/cert-manager-vault-pki: 'true'
    network-platform/trust-manager-install: 'true'
    network-platform/trust-manager-bundle: 'true'
    storage-platform: 'true'
    storage-platform/openebs: 'true'                 # default SC + snapshot CRDs
    storage-platform/nfs-csi-install: 'true'
    storage-platform/nfs-csi-storageclasses: 'true'
    storage-platform.stuttgart-things.com/nfs-config: 'true'
    security-platform: 'true'
    security-platform/external-secrets: 'true'
    security-platform/kyverno: 'true'
  annotations:
    clusterbook.stuttgart-things.com/vault-server: https://vault.infra.sthings-vsphere.labul.sva.de
    clusterbook.stuttgart-things.com/vault-pki-path: pki/sign/sthings-vsphere
    clusterbook.stuttgart-things.com/vault-token-secret: cert-manager-vault-token
    storage-platform.stuttgart-things.com/nfs-server: '10.31.101.26'
    storage-platform.stuttgart-things.com/nfs-share: /data/col1/sthings
    storage-platform.stuttgart-things.com/nfs-version: '3'
```

### `network-only` — app cluster, no CI/CD or storage (e.g. homerun2-dev)
```yaml
spec:
  clusterType: default
  labels:
    network-platform: 'true'
    network-platform/cilium-lb: 'true'
    network-platform/cilium-gateway: 'true'
    network-platform/cert-manager-install: 'true'
    network-platform/cert-manager-selfsigned: 'true'
    network-platform/cert-manager-cluster-ca: 'true'
    network-platform/cert-manager-vault-pki: 'true'
    network-platform/trust-manager-install: 'true'
    network-platform/trust-manager-bundle: 'true'
    security-platform: 'true'
    security-platform/external-secrets: 'true'
    security-platform/kyverno: 'true'
  annotations:
    clusterbook.stuttgart-things.com/vault-server: https://vault.infra.sthings-vsphere.labul.sva.de
    clusterbook.stuttgart-things.com/vault-pki-path: pki/sign/sthings-vsphere
    clusterbook.stuttgart-things.com/vault-token-secret: cert-manager-vault-token
```

### `homerun2-tabletennis` — app cluster running both app platforms (e.g. tabletennis)

Network + storage + security, then the two app bundles. The CNPG operator is
opt-in and tabletennis needs it.

```yaml
spec:
  clusterType: default
  labels:
    network-platform: 'true'
    network-platform/cilium-lb: 'true'
    network-platform/cilium-gateway: 'true'
    network-platform/cert-manager-install: 'true'
    network-platform/cert-manager-selfsigned: 'true'
    network-platform/cert-manager-cluster-ca: 'true'
    network-platform/cert-manager-vault-pki: 'true'
    network-platform/trust-manager-install: 'true'
    network-platform/trust-manager-bundle: 'true'
    storage-platform: 'true'
    storage-platform/openebs: 'true'                 # default SC
    storage-platform/cloudnative-pg: 'true'          # REQUIRED by tabletennis
    security-platform: 'true'
    security-platform/external-secrets: 'true'       # REQUIRED by both
    security-platform/kyverno: 'true'
    homerun2-platform: 'true'
    homerun2-platform/stack: 'true'
    homerun2-platform.stuttgart-things.com/secrets-config: 'true'    # only once the store exists
    tabletennis-platform: 'true'
    tabletennis-platform/tabletennis: 'true'
    tabletennis-platform/light-catcher: 'true'       # only where a strip exists
    tabletennis-platform.stuttgart-things.com/secrets-config: 'true' # only once the store exists
  annotations:
    clusterbook.stuttgart-things.com/vault-server: https://openbao.platform.sthings.lab
    clusterbook.stuttgart-things.com/vault-pki-path: pki/sign/sthings-lab
    clusterbook.stuttgart-things.com/wildcard-issuer-name: vault-pki
    homerun2-platform.stuttgart-things.com/secret-store: vault-tabletennis
    tabletennis-platform.stuttgart-things.com/secret-store: vault-tabletennis
    tabletennis-platform.stuttgart-things.com/wled-endpoint: http://wled-tt.lan
```

Present the two `secrets-config` gate labels only once that store exists and holds
its entries — `homerun2` (`authToken`, `redisPassword`), `schmetterpause`
(`session-key`, `username`, `password`) and `zaehlwerk` (`omni-pitcher-token`,
`redis-password`), with `omni-pitcher-token` equal to homerun2's `authToken`.

### `kind-dev` — local kind cluster (e.g. cd-mgmt-1-kind-dev1)
```yaml
spec:
  clusterType: kind
  lbRange: { start: '172.18.255.200', stop: '172.18.255.250' }
  labels:
    kind-platform: 'true'
    kind-platform/cilium-install: 'true'
    kind-platform/cilium-lb: 'true'
    kind-platform/cert-manager-install: 'true'
    kind-platform/cert-manager-selfsigned: 'true'
```

> Every component left out of a preset should be set explicitly to `'false'`
> (see `cluster.reference.yaml`) so a cluster's intent is self-documenting and
> selectors behave predictably.
