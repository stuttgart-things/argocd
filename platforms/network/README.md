# platforms/network

Clusterbook-aware platform bootstrap: nine `ApplicationSet`s on the management cluster that fan out to every cluster registered via [clusterbook-operator](https://github.com/stuttgart-things/clusterbook-operator), wiring its reserved IP + FQDN through cilium LoadBalancer, cert-manager (cluster-CA chain and/or Vault PKI), trust-manager, and one or two cilium Gateways.

All ApplicationSets share a base anchor — the ArgoCD cluster `Secret` enriched by clusterbook-operator must carry:

```
clusterbook.stuttgart-things.com/allocation-ip: <label exists>
clusterbook.stuttgart-things.com/ip:    <annotation, the reserved IP>
clusterbook.stuttgart-things.com/fqdn:  <annotation, the reserved FQDN>
```

Optional clusterbook fields, consumed only when the matching feature is opted in:

```
clusterbook.stuttgart-things.com/fqdn-secondary:    <annotation, second FQDN>          # secondary gateway
clusterbook.stuttgart-things.com/vault-server:      <annotation, https://vault.../>    # vault-pki
clusterbook.stuttgart-things.com/vault-pki-path:    <annotation, pki/sign/<role>>      # vault-pki
clusterbook.stuttgart-things.com/vault-token-secret:<annotation, Secret name>          # vault-pki
```

These are emitted by `ClusterbookCluster` and `ClusterbookAllocation` CRs. Nothing here generates until clusterbook-operator has populated them.

## Opt-in: `network-platform` master gate + per-feature toggles

On top of the `allocation-ip` anchor, each ApplicationSet additionally requires a master `network-platform` gate. Most components are **default-enabled** (opt out per cluster with `<feature>: "false"`); two components are **opt-in** (require `<feature>: "true"`) because they need additional cluster state to function.

Default-enabled (opt-out via `NotIn ["false"]`):

| ApplicationSet | per-feature label key |
|---|---|
| `cilium-lb-clusterbook`               | `network-platform/cilium-lb` |
| `cilium-gateway-clusterbook`          | `network-platform/cilium-gateway` |
| `cert-manager-install-clusterbook`    | `network-platform/cert-manager-install` |
| `cert-manager-selfsigned-clusterbook` | `network-platform/cert-manager-selfsigned` |
| `cert-manager-cluster-ca-clusterbook` | `network-platform/cert-manager-cluster-ca` |
| `trust-manager-install-clusterbook`   | `network-platform/trust-manager-install` |
| `trust-manager-bundle-clusterbook`    | `network-platform/trust-manager-bundle` |

Opt-in (require `<feature>: "true"`):

| ApplicationSet | per-feature label key | Why opt-in |
|---|---|---|
| `cilium-gateway-secondary-clusterbook` | `network-platform/cilium-gateway-secondary` | Needs `clusterbook.stuttgart-things.com/fqdn-secondary` annotation |
| `cert-manager-vault-pki-clusterbook`   | `network-platform/cert-manager-vault-pki`   | Needs Vault token Secret (`vault-pki-token`) pre-provisioned in `cert-manager` ns + clusterbook vault annotations |

Selector logic — opt-out (default-enabled) appsets:

```yaml
matchLabels:
  network-platform: "true"
matchExpressions:
  - key: clusterbook.stuttgart-things.com/allocation-ip
    operator: Exists
  - key: network-platform/<feature>
    operator: NotIn
    values: ["false"]
```

Selector logic — opt-in appsets:

```yaml
matchLabels:
  network-platform: "true"
  network-platform/<feature>: "true"
matchExpressions:
  - key: clusterbook.stuttgart-things.com/allocation-ip
    operator: Exists
```

Default-enabled means: cluster Secret needs `network-platform: "true"` to receive the component, and can opt out with `network-platform/<feature>: "false"`. Missing per-feature labels default to enabled (NotIn ["false"] matches both true and missing).

## What gets deployed per registered cluster

| ApplicationSet | Wave | Destination | Catalog path | Produces |
|---|---|---|---|---|
| `cert-manager-install-clusterbook`     | 0 | mgmt cluster | `infra/cert-manager/install`   | child `Application` installing cert-manager on the workload cluster |
| `cilium-lb-clusterbook`                | 0 | workload/kube-system | `infra/cilium/lb` | `CiliumLoadBalancerIPPool` pinned to the clusterbook IP + L2 announcement policy |
| `cert-manager-selfsigned-clusterbook`  | 1 | workload/cert-manager | `infra/cert-manager/selfsigned` | `selfsigned` `ClusterIssuer` |
| `cert-manager-cluster-ca-clusterbook`  | 2 | workload/cert-manager | `infra/cert-manager/cluster-ca` | cluster CA `Certificate` + `ClusterIssuer` + `<cluster>-gateway-tls` wildcard `Certificate` for the clusterbook FQDN; **also** `<cluster>-gateway-tls-secondary` when `clusterbook.stuttgart-things.com/fqdn-secondary` is set |
| `cert-manager-vault-pki-clusterbook`   | 2 | workload/cert-manager | `infra/cert-manager/vault-pki` | `vault-pki` `ClusterIssuer` (token auth) — coexists with the cluster-CA chain; consumers pick the issuer per `Certificate` |
| `cilium-gateway-clusterbook`           | 3 | workload/default | `infra/cilium/gateway` | Gateway API `Gateway` listening on the FQDN, TLS from `<cluster>-gateway-tls` |
| `cilium-gateway-secondary-clusterbook` | 3 | workload/default | `infra/cilium/gateway` | Second Gateway listening on `fqdn-secondary`, TLS from `<cluster>-gateway-tls-secondary` |
| `trust-manager-install-clusterbook`    | 3 | mgmt cluster | `infra/trust-manager/install` | child `Application` installing trust-manager on the workload cluster (watches `cert-manager` ns) |
| `trust-manager-bundle-clusterbook`     | 4 | workload/cert-manager | `infra/trust-manager/bundle` | `cluster-trust-bundle` `Bundle` combining default CAs + `cluster-ca-secret` → ConfigMap `cluster-trust-bundle` (key `trust-bundle.pem`) |

`project: '{{ .name }}'` on every generated Application — the `AppProject` named after the cluster must exist first. That's the job of [`config/cluster-project`](../../config/cluster-project/) driven by the `cluster-projects` ApplicationSet (label the cluster Secret with `auto-project=true`).

## Ordering caveat

`argocd.argoproj.io/sync-wave` on the **Application** metadata only orders children of a common parent App-of-Apps. Here the Applications are top-level (each ApplicationSet fires independently, each has its own `automated.selfHeal`), so the 0 → 1 → 2 → 3 waves are **informational**. Convergence happens through retries + cert-manager's own ordering, not sync-waves.

If you need real ordering (e.g. to swap the selfsigned + cluster-ca chain for a Vault PKI issuer that depends on an out-of-cluster prerequisite), wrap the cert-manager chain in an App-of-Apps or collapse it into a single Application whose source emits all three manifests.

## Install

```bash
kubectl apply -k https://github.com/stuttgart-things/argocd.git/platforms/network?ref=main
```

All ApplicationSets land in the `argocd` namespace on the management cluster. They become active once clusterbook-operator labels the cluster Secret with `allocation-ip` **and** the `ClusterbookCluster` carries `spec.labels.network-platform: "true"` (plus, optionally, per-feature opt-in / opt-out toggles).

## Enabling the secondary gateway

To front a cluster with a second Gateway (different hostname, separate TLS Secret) the cluster Secret needs:

```yaml
metadata:
  labels:
    network-platform: "true"
    network-platform/cilium-gateway-secondary: "true"
  annotations:
    clusterbook.stuttgart-things.com/fqdn-secondary: foo.example.com
```

The `cert-manager-cluster-ca-clusterbook` ApplicationSet detects the `fqdn-secondary` annotation and additionally renders a `<cluster>-gateway-tls-secondary` wildcard `Certificate`; the `cilium-gateway-secondary-clusterbook` ApplicationSet then publishes a second Gateway consuming that Secret. Same CA, two TLS Secrets, two Gateways.

## Enabling the Vault PKI ClusterIssuer

`cert-manager-vault-pki-clusterbook` is opt-in and additive — it does **not** disable the selfsigned/cluster-CA chain. Consumers choose the issuer per `Certificate.spec.issuerRef`. Required cluster Secret state:

```yaml
metadata:
  labels:
    network-platform: "true"
    network-platform/cert-manager-vault-pki: "true"
  annotations:
    clusterbook.stuttgart-things.com/vault-server: https://vault.infra.example.com
    clusterbook.stuttgart-things.com/vault-pki-path: pki/sign/my-role
    clusterbook.stuttgart-things.com/vault-token-secret: vault-pki-token
```

The referenced Secret (default name `vault-pki-token`, key `token`) must exist in the workload cluster's `cert-manager` namespace before the ClusterIssuer can become Ready — typically provisioned by Terraform like [`vault-cert-issuer`](https://github.com/stuttgart-things/stuttgart-things/tree/main/clusters/labul/vsphere/platform-sthings/vault-cert-issuer).

## trust-manager + cluster-trust-bundle

`trust-manager-install-clusterbook` deploys the controller (default-enabled, opt-out via `network-platform/trust-manager-install: "false"`); `trust-manager-bundle-clusterbook` ships a single `cluster-trust-bundle` `Bundle` combining Mozilla's default CAs with the cluster's own `cluster-ca-secret` into a ConfigMap `cluster-trust-bundle` (key `trust-bundle.pem`) consumable by workloads that need the full trust chain.

The bundle ApplicationSet depends on `cert-manager-cluster-ca-clusterbook` having produced `cluster-ca-secret` in `cert-manager`. If a cluster runs only the Vault PKI issuer (`network-platform/cert-manager-cluster-ca: "false"`), also disable the bundle (`network-platform/trust-manager-bundle: "false"`) or replace the Bundle source.

## Related

- [`stuttgart-things/clusterbook-operator`](https://github.com/stuttgart-things/clusterbook-operator) — the operator that produces the labels and annotations consumed here.
- [`config/cluster-project`](../../config/cluster-project/) — the `AppProject` chart that also fires off a `clusters`-generator ApplicationSet; same pattern, different label (`auto-project=true`).
- [`infra/cert-manager`](../../infra/cert-manager/), [`infra/cilium`](../../infra/cilium/) — the catalog charts these ApplicationSets render.
