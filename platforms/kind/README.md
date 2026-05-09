# platforms/kind

Kind-aware platform bootstrap: `ApplicationSet`s on the management cluster that fan out to every kind cluster registered via [clusterbook-operator](https://github.com/stuttgart-things/clusterbook-operator), wiring Cilium itself + LoadBalancer IP pool + cert-manager chain onto each one.

Mirrors [`platforms/network/`](../clusterbook/) but with two differences forced by kind:

1. **Cilium is installed by this bundle** — kind ships without a CNI. The vSphere/Talos clusters that `platforms/network/` targets already have Cilium pre-installed; kind doesn't.
2. **The LB pool comes from a docker-bridge IP range** — kind LoadBalancer IPs are carved out of the docker network the cluster runs on, so each cluster needs its own contiguous `start`/`stop` block. The clusterbook-operator writes that range to the cluster Secret as annotations.

The bundle is split in two:

- **base** (this directory) — the four AppSets that work on any kind cluster: Cilium install + LB pool + cert-manager install + selfsigned issuer.
- **`expose-external/`** — opt-in overlay (cluster-CA + Cilium Gateway) for clusters that publish their kind LB IPs externally via DNS. Gated on a per-cluster opt-in label so the default kind install doesn't generate Applications that can't render without an FQDN. See [Expose externally](#expose-externally) below.

## Prerequisite — clusterbook-operator ≥ v0.15.0

Each kind cluster's ArgoCD `Secret` (created or enriched by `ClusterbookCluster`) must carry:

```yaml
labels:
  clusterbook.stuttgart-things.com/cluster-type: kind
  # only when applying expose-external/:
  clusterbook.stuttgart-things.com/expose-external: "true"
annotations:
  clusterbook.stuttgart-things.com/cluster-name:    <cluster-name>
  clusterbook.stuttgart-things.com/lb-range-start:  <range-start>
  clusterbook.stuttgart-things.com/lb-range-stop:   <range-stop>
  # only when applying expose-external/:
  clusterbook.stuttgart-things.com/fqdn:            <wildcard-fqdn>
  clusterbook.stuttgart-things.com/ip:              <primary-ip>
```

`clusterType`, `lbRange`, and the `cluster-name` annotation are added by [stuttgart-things/clusterbook-operator#79](https://github.com/stuttgart-things/clusterbook-operator/issues/79) (released in v0.15.0). Until that operator version reconciles your cluster, none of the ApplicationSets here will generate.

A minimal `ClusterbookCluster` for kind (user-pinned docker-bridge range) lives at [`examples/clusterbookcluster-kind.yaml`](https://github.com/stuttgart-things/clusterbook-operator/blob/main/examples/clusterbookcluster-kind.yaml) in the operator repo.

## What gets deployed per registered kind cluster

### base (default install)

| ApplicationSet | Wave | Destination | Catalog path | Produces |
|---|---|---|---|---|
| `cilium-install-kind`             | -10 | mgmt cluster | `infra/cilium/install`        | child `Application` installing Cilium on the workload cluster (CNI + L2 + GatewayClass) |
| `cert-manager-install-kind`       |   0 | mgmt cluster | `infra/cert-manager/install`  | child `Application` installing cert-manager on the workload cluster |
| `cilium-lb-kind`                  |   0 | workload/kube-system | `infra/cilium/lb`     | `CiliumLoadBalancerIPPool` with a docker-bridge range + L2 announcement policy |
| `cert-manager-selfsigned-kind`    |   1 | workload/cert-manager | `infra/cert-manager/selfsigned` | `selfsigned` `ClusterIssuer` |

### expose-external (opt-in)

| ApplicationSet | Wave | Destination | Catalog path | Produces |
|---|---|---|---|---|
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

This is the same caveat as `platforms/network/`. The one wave that matters in practice is `cilium-install-kind` (-10) needing to land before anything else — without a CNI, every other reconcile loop will retry forever, but they will eventually converge once Cilium is up.

## Install

```bash
kubectl apply -k https://github.com/stuttgart-things/argocd.git/platforms/kind?ref=main
```

The four base ApplicationSets land in the `argocd` namespace on the management cluster. They become active as soon as a cluster Secret carries `kind-platform: "true"` (the master gate — see below).

## Master gate + per-feature opt-out (base bundle)

The base ApplicationSets gate on a `kind-platform: "true"` master label (mirroring the `network-platform: "true"` pattern in `platforms/network/`). Each AppSet additionally allows opting a cluster out of a single feature via a `kind-platform/<feature>: "false"` label — missing labels default to enabled (same `NotIn ["false"]` semantics as `platforms/cicd` and `platforms/network`).

The Backstage `create-argocd-cluster` template auto-derives the master gate from the multi-select `Kind Platform Features` form input (`kind-platform: "true"` if any feature is selected, otherwise `"false"`). Hand-rolled `ClusterbookCluster` CRs need to set `kind-platform: "true"` on `spec.labels` explicitly.

Note: the AppSets no longer gate on `clusterbook.stuttgart-things.com/cluster-type=kind`. The operator still sets that label when `spec.clusterType: kind` is present on the CR — `cilium-lb-kind`'s template still consumes operator-written `lb-range-{start,stop}` annotations, so a kind cluster registered without `spec.clusterType: kind` (e.g. via the Backstage form while [stuttgart-things/kcl#48](https://github.com/stuttgart-things/kcl/issues/48) is open) will match `cilium-lb-kind` but render with empty LB range values.

| ApplicationSet | per-feature label key |
|---|---|
| `cilium-install-kind`          | `kind-platform/cilium-install` |
| `cilium-lb-kind`               | `kind-platform/cilium-lb` |
| `cert-manager-install-kind`    | `kind-platform/cert-manager-install` |
| `cert-manager-selfsigned-kind` | `kind-platform/cert-manager-selfsigned` |

The `expose-external/` overlay (cluster-CA + Gateway) is **not** covered by this pattern — it stays gated on the explicit `clusterbook.stuttgart-things.com/expose-external: "true"` label.

## Expose externally

The cluster-CA + gateway flow needs an FQDN that resolves to the kind cluster's LB IP. kind LB IPs live on the docker bridge of the host running the cluster — they're host-local by default, so DNS publication only makes sense for clusters where someone has set up routing or port-forwarding to that range.

Apply the overlay separately:

```bash
kubectl apply -k https://github.com/stuttgart-things/argocd.git/platforms/kind/expose-external?ref=main
```

Then opt each cluster in by adding the label to its ArgoCD cluster Secret. With clusterbook-operator that's:

```yaml
apiVersion: clusterbook.stuttgart-things.com/v1alpha1
kind: ClusterbookCluster
metadata:
  name: dev-a
spec:
  clusterType: kind
  # … kubeconfigSecretRef, lbRange, etc.
  labels:
    auto-project: "true"
    clusterbook.stuttgart-things.com/expose-external: "true"   # opt in here
```

Without the label, the two AppSets in `expose-external/` won't generate Applications for the cluster — even if the overlay is applied on the management cluster. This is deliberate: applying the overlay shouldn't fan out to every existing kind cluster automatically, only the ones that genuinely have external DNS pointing at their LB IPs.

Both labels (`cluster-type=kind` and `expose-external=true`) and a non-empty `clusterbook.stuttgart-things.com/fqdn` annotation must be present for the helm charts to render — without an FQDN they fail validation with `wildcard.commonName: minLength got 0`. The clusterbook-operator's `ClusterbookProviderConfig` has to be pointing at a server that allocates DNS records for the cluster.

## Vault PKI as an alternative issuer

`platforms/network` exposes a Vault PKI `ClusterIssuer` as an additive opt-in (`network-platform/cert-manager-vault-pki: "true"` + clusterbook annotations for server / path / token Secret name) — both the cluster-CA chain and Vault PKI coexist, and consumers pick the issuer per `Certificate`. See [`platforms/network/README.md`](../network/README.md#enabling-the-vault-pki-clusterissuer) for the cluster-Secret shape. The gateway ApplicationSet (in `expose-external/`) stays as-is regardless of which issuer minted `<cluster>-gateway-tls`.

## Related

- [`stuttgart-things/clusterbook-operator`](https://github.com/stuttgart-things/clusterbook-operator) — the operator that produces the `cluster-type=kind` label and the `lb-range-{start,stop}` annotations consumed here.
- [`platforms/network`](../network/) — the vSphere/Talos sibling bundle that this one mirrors.
- [`config/cluster-project`](../../config/cluster-project/) — the per-cluster `AppProject` provisioner.
- [`infra/cilium`](../../infra/cilium/), [`infra/cert-manager`](../../infra/cert-manager/) — the catalog charts these ApplicationSets render.
