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
| `network-platform/trust-manager-bundle` | `appset-trust-manager-bundle` | — |

### `storage-platform`
| Label | AppSet | Needs annotations |
|---|---|---|
| `storage-platform/openebs` | `appset-openebs` (storage) → `openebs-hostpath` **default SC** + VolumeSnapshot CRDs | — |
| `storage-platform/longhorn` | `appset-longhorn` | — |
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

### `kind-platform` — only when `spec.clusterType: kind`
| Label | AppSet |
|---|---|
| `kind-platform/cilium-install` | `appset-cilium-install-kind` |
| `kind-platform/cilium-lb` | `appset-cilium-lb-kind` |
| `kind-platform/cert-manager-install` | `appset-cert-manager-install-kind` |
| `kind-platform/cert-manager-selfsigned` | `appset-cert-manager-selfsigned-kind` |

`expose-external` (gateway/cluster-ca for kind) is gated by the annotation
`clusterbook.stuttgart-things.com/expose-external: 'true'` (+ `lb-range-start/stop`).

### Opt-in app/preview platforms (single label, no umbrella)
`homerun2-pr-preview` · `machinery-pr-preview` · `machinery-catalog-publisher-pr-preview`
— set the label to `'true'` to fan the matching `platforms/<name>/` AppSets onto the cluster.

## Annotations: who sets them

- **`[auto]` controller-stamped** (from reservation/spec — never set by hand):
  `cluster-name`, `ip`, `fqdn`, `fqdn-secondary`, `lb-range-start`, `lb-range-stop`, `cluster-type`, allocation-*.
- **`[user]` you provide** (component config):
  `vault-server` / `vault-pki-path` / `vault-token-secret`, `wildcard-issuer-name`,
  `expose-external`, and all `storage-platform.stuttgart-things.com/nfs-*`.

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
