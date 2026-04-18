# infra/cilium

Catalog entry for [Cilium](https://cilium.io/) with optional L2/LB announcement and Gateway API resources. Split into three sub-entries so consumers pick what they need.

## Layout

```
infra/cilium/
├── chart/              # Cilium Helm chart (v1.18.5, sync-wave -10)
├── lb/                 # CiliumLoadBalancerIPPool + CiliumL2AnnouncementPolicy (sync-wave 0)
└── gateway/            # Gateway API Gateway "cilium-gateway" in default ns (sync-wave 10)
```

## Components

### chart/
Installs Cilium `v1.18.5` into `kube-system` with:
- `kubeProxyReplacement: true` (replaces kube-proxy)
- `gatewayAPI.enabled: true` (enables the `cilium` GatewayClass)
- `l2announcements.enabled: true` + `externalIPs.enabled: true` (enables L2 LoadBalancer announcements)
- `operator.replicas: 1`
- `k8sServiceHost: ""` / `k8sServicePort: 6443` — override per-cluster for kubeProxyReplacement to work in non-standard setups

### lb/
Two resources for Cilium's in-cluster load balancing:
- `CiliumLoadBalancerIPPool default-pool` — advertises IPs from `192.168.1.240`–`192.168.1.250`
- `CiliumL2AnnouncementPolicy default-l2-announcement-policy` — enables ARP for externalIPs and LB IPs

**Consumers must patch the IP range to match their network** — the shipped `192.168.1.240/250` is a placeholder.

### gateway/
One Gateway API `Gateway` named `cilium-gateway` in the `default` namespace with HTTPS (port 443, TLS terminate via `cilium-gateway-tls` Secret) and HTTP (port 80) listeners on `*.example.com`.

Consumers typically patch `hostname` + the TLS Secret reference per cluster. Required by anything that wants an HTTPRoute through Cilium (e.g. `cicd/tekton/dashboard-httproute`).

## Consumer usage

Full stack (chart + lb + gateway):

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - https://github.com/stuttgart-things/argocd.git/infra/cilium/chart?ref=main
  - https://github.com/stuttgart-things/argocd.git/infra/cilium/lb?ref=main
  - https://github.com/stuttgart-things/argocd.git/infra/cilium/gateway?ref=main
patches:
  - target: { kind: Application, name: cilium }
    patch: |-
      - op: replace
        path: /spec/project
        value: <cluster-project>
      - op: replace
        path: /spec/destination/server
        value: https://<cluster-api>:<port>
  - target: { kind: Application, name: cilium-lb }
    patch: |-
      - op: replace
        path: /spec/project
        value: <cluster-project>
      - op: replace
        path: /spec/destination/server
        value: https://<cluster-api>:<port>
  - target: { kind: Application, name: cilium-gateway }
    patch: |-
      - op: replace
        path: /spec/project
        value: <cluster-project>
      - op: replace
        path: /spec/destination/server
        value: https://<cluster-api>:<port>
```

Chart-only clusters (no LB, no Gateway API) omit the latter two entries.

## Related

- Flux equivalent: [`stuttgart-things/flux` — `infra/cilium`](https://github.com/stuttgart-things/flux/tree/main/infra/cilium)
