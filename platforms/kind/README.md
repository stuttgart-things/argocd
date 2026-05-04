# platforms/kind

Kind-aware platform bootstrap: six `ApplicationSet`s on the management cluster that fan out to every kind cluster registered via [clusterbook-operator](https://github.com/stuttgart-things/clusterbook-operator), wiring Cilium itself + LoadBalancer IP pool + Gateway + cert-manager chain onto each one.

Mirrors [`platforms/clusterbook/`](../clusterbook/) but with two differences forced by kind:

1. **Cilium is installed by this bundle** — kind ships without a CNI. The vSphere/Talos clusters that `platforms/clusterbook/` targets already have Cilium pre-installed; kind doesn't.
2. **The LB pool comes from a docker-bridge IP range** — kind LoadBalancer IPs are carved out of the docker network the cluster runs on, so each cluster needs its own contiguous `start`/`stop` block. The clusterbook-operator writes that range to the cluster Secret as annotations.

## Prerequisite — clusterbook-operator ≥ v0.15.0

Each kind cluster's ArgoCD `Secret` (created or enriched by `ClusterbookCluster`) must carry:

```yaml
labels:
  clusterbook.stuttgart-things.com/cluster-type: kind
annotations:
  clusterbook.stuttgart-things.com/cluster-name:    <cluster-name>
  clusterbook.stuttgart-things.com/ip:              <primary-ip>
  clusterbook.stuttgart-things.com/fqdn:            <wildcard-fqdn>
  clusterbook.stuttgart-things.com/lb-range-start:  <range-start>
  clusterbook.stuttgart-things.com/lb-range-stop:   <range-stop>
```

`clusterType`, `lbRange`, and the `cluster-name` annotation are added by [stuttgart-things/clusterbook-operator#79](https://github.com/stuttgart-things/clusterbook-operator/issues/79) (released in v0.15.0). Until that operator version reconciles your cluster, none of the ApplicationSets here will generate.

A minimal `ClusterbookCluster` for kind (user-pinned docker-bridge range) lives at [`examples/clusterbookcluster-kind.yaml`](https://github.com/stuttgart-things/clusterbook-operator/blob/main/examples/clusterbookcluster-kind.yaml) in the operator repo.

## What gets deployed per registered kind cluster

| ApplicationSet | Wave | Destination | Catalog path | Produces |
|---|---|---|---|---|
| `cilium-install-kind`             | -10 | mgmt cluster | `infra/cilium/install`        | child `Application` installing Cilium on the workload cluster (CNI + L2 + GatewayClass) |
| `cert-manager-install-kind`       |   0 | mgmt cluster | `infra/cert-manager/install`  | child `Application` installing cert-manager on the workload cluster |
| `cilium-lb-kind`                  |   0 | workload/kube-system | `infra/cilium/lb`     | `CiliumLoadBalancerIPPool` with a docker-bridge range + L2 announcement policy |
| `cert-manager-selfsigned-kind`    |   1 | workload/cert-manager | `infra/cert-manager/selfsigned` | `selfsigned` `ClusterIssuer` |
| `cert-manager-cluster-ca-kind`    |   2 | workload/cert-manager | `infra/cert-manager/cluster-ca` | cluster CA `Certificate` + `ClusterIssuer` + `<cluster>-gateway-tls` wildcard for the FQDN |
| `cilium-gateway-kind`             |   3 | workload/default | `infra/cilium/gateway`   | Gateway API `Gateway` listening on the FQDN, TLS from `<cluster>-gateway-tls` |

## Cilium install values

`appset-cilium-install-kind.yaml` feeds the `infra/cilium/install` chart these knobs:

- `k8s.serviceHost: <cluster-name>-control-plane`, `servicePort: 6443` — kind's API endpoint via docker hostname; required for `kubeProxyReplacement`.
- `operatorReplicas: 2` — survives a single docker-node restart.
- `extraValues.routingMode: native` + `ipv4NativeRoutingCIDR: 10.244.0.0/16` + `autoDirectNodeRoutes: true` — uses the docker bridge directly (no tunnel overhead) and keeps LoadBalancer L2 announcements simple.
- `extraValues.devices: [eth0, net0]` — kind nodes can have either depending on docker version / network topology.
- `extraValues.l2announcements.{leaseDuration: 3s, leaseRenewDeadline: 1s, leaseRetryPeriod: 500ms}` — tight failover on small kind nodes where leadership churn is more likely than on a real cluster.

These live in `extraValues` (deep-merged into the upstream Cilium chart) rather than first-class fields. Promote them to `infra/cilium/install/values.yaml` if a third platform needs the same knobs.

## AppProject per cluster

`project: '{{ .name }}'` on every generated Application — the `AppProject` named after the cluster must exist first. Provisioned by [`config/cluster-project`](../../config/cluster-project/) driven by the `cluster-projects` ApplicationSet (the cluster Secret must also carry `auto-project=true`). For a kind cluster, both labels go on the same Secret:

```yaml
labels:
  clusterbook.stuttgart-things.com/cluster-type: kind
  auto-project: "true"
```

Add the `auto-project=true` label via `spec.labels` on the `ClusterbookCluster` CR.

## Ordering caveat

`argocd.argoproj.io/sync-wave` on the **Application** metadata only orders children of a common parent App-of-Apps. Here the Applications are top-level (each ApplicationSet fires independently, each has its own `automated.selfHeal`), so the -10 → 0 → 1 → 2 → 3 waves are **informational**. Convergence happens through retries + cert-manager's own ordering, not sync-waves.

This is the same caveat as `platforms/clusterbook/`. The one wave that matters in practice is `cilium-install-kind` (-10) needing to land before anything else — without a CNI, every other reconcile loop will retry forever, but they will eventually converge once Cilium is up.

## Install

```bash
kubectl apply -k https://github.com/stuttgart-things/argocd.git/platforms/kind?ref=main
```

All six ApplicationSets land in the `argocd` namespace on the management cluster. They become active as soon as clusterbook-operator labels a cluster Secret with `cluster-type=kind`.

## Swapping the issuer (Vault PKI path)

Same path as [`platforms/clusterbook/README.md`](../clusterbook/README.md#swapping-the-issuer-vault-pki-path) — the selfsigned + cluster-ca chain is replaceable with a Vault-backed `ClusterIssuer`. The gateway ApplicationSet stays as-is.

## Related

- [`stuttgart-things/clusterbook-operator`](https://github.com/stuttgart-things/clusterbook-operator) — the operator that produces the `cluster-type=kind` label and the `lb-range-{start,stop}` annotations consumed here.
- [`platforms/clusterbook`](../clusterbook/) — the vSphere/Talos sibling bundle that this one mirrors.
- [`config/cluster-project`](../../config/cluster-project/) — the per-cluster `AppProject` provisioner.
- [`infra/cilium`](../../infra/cilium/), [`infra/cert-manager`](../../infra/cert-manager/) — the catalog charts these ApplicationSets render.
