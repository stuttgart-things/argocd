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
| `storage-platform/cloudnative-pg` | `appset-cloudnative-pg` → CloudNativePG operator (CRDs + operator in `postgres`) | — — **opt-in**, an explicit `'true'`. A singleton per cluster: `tabletennis-platform` needs it, anything else growing a Postgres uses the same one. The Barman Cloud plugin is not included — backups are per-workload |
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

### `observability-platform` — kube-prometheus-stack
| Label | AppSet | Needs annotations |
|---|---|---|
| `observability-platform/kube-prometheus-stack` | `appset-kube-prometheus-stack` → Prometheus Operator, Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics | **gate label** `observability-platform.stuttgart-things.com/secrets-config` + `…/secret-store`, `…/alert-webhook-url` **(user)**; optional `…/secret-key` (def cluster), `…/storage-class` (def cluster default), `…/storage-size` (def `10Gi`), `…/retention` (def `15d`); `…/fqdn` *(auto)* for Grafana |

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
| `homerun2-platform` | `appset-homerun2` → redis-stack + omni-pitcher + core-catcher + scout + led-catcher, their routes and their ExternalSecrets (the `flux/apps/homerun2/profiles/platform` profile) | **gate** `homerun2-platform.stuttgart-things.com/secrets-config: 'true'` + `…/secret-store` **(user)**; optional `…/secret-key` (def cluster name), `…/storage-class` (def `openebs-hostpath`), `…/redis-storage-size` (def `8Gi`); `…/fqdn` *(auto)* for every hostname |

Opt one cluster out with `homerun2-platform/stack: 'false'`. The component set is
fixed — an AppSet can only template strings, so a `<component>.enabled` boolean
cannot come from a label. See [`platforms/homerun2`](./homerun2/).

### `tabletennis-platform` — schmetterpause + zaehlwerk
| Label | AppSet | Needs annotations |
|---|---|---|
| `tabletennis-platform` | `appset-tabletennis` → schmetterpause + its CNPG database, zaehlwerk, and (opt-in) the LED strip at the table | **gate** `tabletennis-platform.stuttgart-things.com/secrets-config: 'true'` + `…/secret-store` **(user)**; optional `…/storage-class`, `…/db-storage-size` (def `8Gi`), `…/homerun2-namespace` (def `homerun2`), `…/wled-endpoint`; `…/fqdn` *(auto)* |
| `tabletennis-platform/light-catcher` | the LED strip, an opt-in `'true'` — physical hardware, so per cluster | `…/wled-endpoint` **(user)**, optional |

> ⚠️ **Requires `storage-platform/cloudnative-pg: 'true'`.** schmetterpause's
> database is a CNPG `Cluster`; without the CRD that Application's dry-run
> rejects the whole apply.

Opt out with `tabletennis-platform/tabletennis: 'false'`. See
[`platforms/tabletennis`](./tabletennis/).

### Opt-in app/preview platforms (single label, no umbrella)
`homerun2-pr-preview` · `machinery-pr-preview` · `machinery-catalog-publisher-pr-preview`
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
