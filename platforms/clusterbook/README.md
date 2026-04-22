# platforms/clusterbook

Clusterbook-aware platform bootstrap: five `ApplicationSet`s on the management cluster that fan out to every cluster registered via [clusterbook-operator](https://github.com/stuttgart-things/clusterbook-operator), wiring its reserved IP + FQDN through cilium LoadBalancer, cert-manager, and a cilium Gateway.

All five ApplicationSets share one selector — the ArgoCD cluster `Secret` enriched by clusterbook-operator must carry:

```
clusterbook.stuttgart-things.com/allocation-ip: <label exists>
clusterbook.stuttgart-things.com/ip:    <annotation, the reserved IP>
clusterbook.stuttgart-things.com/fqdn:  <annotation, the reserved FQDN>
```

These are emitted by `ClusterbookCluster` and `ClusterbookAllocation` CRs. Nothing here generates until clusterbook-operator has populated them.

## What gets deployed per registered cluster

| ApplicationSet | Wave | Destination | Catalog path | Produces |
|---|---|---|---|---|
| `cert-manager-install-clusterbook`   | 0 | mgmt cluster | `infra/cert-manager/install`   | child `Application` installing cert-manager on the workload cluster |
| `cilium-lb-clusterbook`              | 0 | workload/kube-system | `infra/cilium/lb` | `CiliumLoadBalancerIPPool` pinned to the clusterbook IP + L2 announcement policy |
| `cert-manager-selfsigned-clusterbook`| 1 | workload/cert-manager | `infra/cert-manager/selfsigned` | `selfsigned` `ClusterIssuer` |
| `cert-manager-cluster-ca-clusterbook`| 2 | workload/cert-manager | `infra/cert-manager/cluster-ca` | cluster CA `Certificate` + `ClusterIssuer` + `<cluster>-gateway-tls` wildcard Certificate for the clusterbook FQDN |
| `cilium-gateway-clusterbook`         | 3 | workload/default | `infra/cilium/gateway` | Gateway API `Gateway` listening on the FQDN, TLS from `<cluster>-gateway-tls` |

`project: '{{ .name }}'` on every generated Application — the `AppProject` named after the cluster must exist first. That's the job of [`config/cluster-project`](../../config/cluster-project/) driven by the `cluster-projects` ApplicationSet (label the cluster Secret with `auto-project=true`).

## Ordering caveat

`argocd.argoproj.io/sync-wave` on the **Application** metadata only orders children of a common parent App-of-Apps. Here the Applications are top-level (each ApplicationSet fires independently, each has its own `automated.selfHeal`), so the 0 → 1 → 2 → 3 waves are **informational**. Convergence happens through retries + cert-manager's own ordering, not sync-waves.

If you need real ordering (e.g. to swap the selfsigned + cluster-ca chain for a Vault PKI issuer that depends on an out-of-cluster prerequisite), wrap the cert-manager chain in an App-of-Apps or collapse it into a single Application whose source emits all three manifests.

## Install

```bash
kubectl apply -k https://github.com/stuttgart-things/argocd.git/platforms/clusterbook?ref=main
```

All five ApplicationSets land in the `argocd` namespace on the management cluster. They become active as soon as clusterbook-operator labels a cluster Secret with `allocation-ip`.

## Swapping the issuer (Vault PKI path)

To swap the selfsigned → cluster-ca chain for a Vault-backed `ClusterIssuer` (`vault-pki`), provisioned out-of-band by the Terraform in [`stuttgart-things/clusters/.../vault-cert-issuer`](https://github.com/stuttgart-things/stuttgart-things/tree/main/clusters/labul/vsphere/platform-sthings/vault-cert-issuer):

1. Run the Terraform from CI before Argo CD fires (e.g. on `ClusterbookCluster` registration).
2. Delete `appset-cert-manager-selfsigned.yaml` and `appset-cert-manager-cluster-ca.yaml` from this bundle.
3. Add one new ApplicationSet that emits only the wildcard `Certificate` with `issuerRef.name: vault-pki` (see `infra/cert-manager/cluster-ca` for the template — only the `wildcard` block is needed).
4. The gateway ApplicationSet stays as-is; it consumes `<cluster>-gateway-tls` regardless of which issuer minted it.

## Related

- [`stuttgart-things/clusterbook-operator`](https://github.com/stuttgart-things/clusterbook-operator) — the operator that produces the labels and annotations consumed here.
- [`config/cluster-project`](../../config/cluster-project/) — the `AppProject` chart that also fires off a `clusters`-generator ApplicationSet; same pattern, different label (`auto-project=true`).
- [`infra/cert-manager`](../../infra/cert-manager/), [`infra/cilium`](../../infra/cilium/) — the catalog charts these ApplicationSets render.
