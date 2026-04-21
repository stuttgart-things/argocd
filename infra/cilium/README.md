# infra/cilium

Catalog entry for [Cilium](https://cilium.io/) with opt-in LoadBalancer IP pool and Gateway API Gateway. Packaged as an **app-of-apps Helm chart**: consumers create one ArgoCD `Application` (or `ApplicationSet`) pointing at `infra/cilium/chart`, pass overrides via `helm.values` / `helm.valuesObject`, and the chart renders up to three child Applications — Cilium itself, plus the LB pool and the Gateway when opted in.

## Layout

```
infra/cilium/
├── chart/                         app-of-apps Helm chart (what consumers point at)
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── values.schema.json
│   └── templates/
│       ├── cilium.yaml            renders Application "cilium"         (sync-wave -10)
│       ├── cilium-lb.yaml         renders Application "cilium-lb"      (sync-wave 0,  lb.enabled)
│       └── cilium-gateway.yaml    renders Application "cilium-gateway" (sync-wave 10, gateway.enabled)
├── lb-chart/                      sub-chart — CiliumLoadBalancerIPPool + CiliumL2AnnouncementPolicy
└── gateway-chart/                 sub-chart — Gateway API Gateway (HTTPS terminate + HTTP)
```

## Components

- **`chart/templates/cilium.yaml`** — installs Cilium `v1.18.5` into `kube-system` with `kubeProxyReplacement`, Gateway API controller, L2 announcements and external IPs on by default. All of those are exposed as first-class values; `extraValues` is the escape hatch for any upstream key not surfaced directly.
- **`chart/templates/cilium-lb.yaml`** — gated on `lb.enabled`. Child Application points at `infra/cilium/lb-chart` and passes the pool name, IP blocks, and L2 policy through values. **Consumers set `lb.blocks` to match their network** — the shipped `192.168.1.240`–`192.168.1.250` is a placeholder.
- **`chart/templates/cilium-gateway.yaml`** — gated on `gateway.enabled`. Child Application points at `infra/cilium/gateway-chart` and passes the Gateway name / namespace / hostname / TLS Secret through values. Required by anything that wants an HTTPRoute through Cilium. Needs `gatewayAPI.enabled: true` (default).

## Consumer usage

Lead examples use `helm.values` as a string (per the repo convention) so the outer `valuesObject` stays boolean-safe from ApplicationSet Go-template output.

### Single cluster — one `Application`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cilium
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: infra/cilium/chart
    helm:
      values: |
        project: my-cluster
        destination:
          server: https://<cluster-api>:6443
          namespace: kube-system
        k8s:
          serviceHost: <cluster-api>
          servicePort: 6443
        lb:
          enabled: true
          blocks:
            - start: 10.0.42.10
              stop: 10.0.42.30
        gateway:
          enabled: true
          hostname: "*.my-cluster.example.com"
          tlsSecretName: my-cluster-gateway-tls
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

Note: the outer `destination.server` is the **management cluster** (where the rendered child Applications live, in the `argocd` namespace). The inner `destination.server` in values is the **workload cluster** where Cilium itself runs.

### Fleet — one `ApplicationSet` across many clusters

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: cilium
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - clusters:
        selector:
          matchLabels:
            install/cilium: "true"
  template:
    metadata:
      name: 'cilium-{{ .name }}'
    spec:
      project: '{{ .name }}'
      source:
        repoURL: https://github.com/stuttgart-things/argocd.git
        targetRevision: main
        path: infra/cilium/chart
        helm:
          values: |
            project: {{ .name }}
            destination:
              server: {{ .server }}
              namespace: kube-system
      destination: { server: https://kubernetes.default.svc, namespace: argocd }
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

Label ArgoCD cluster Secrets with `install/cilium: "true"`. Fleet-wide opt-ins (`lb.enabled`, `gateway.enabled`) stay off — flip them per cluster with a dedicated Application (as above), because ApplicationSet Go-template output is always a string and would fail the schema's `boolean` type on those keys.

## Values reference

See `chart/values.yaml` for defaults and `chart/values.schema.json` for the full JSON Schema. Invalid overrides (unknown keys, wrong types, missing required fields when a feature is enabled) fail the sync loudly.

| Key | Default | Purpose |
|---|---|---|
| `project` | `default` | ArgoCD AppProject for the rendered Applications |
| `destination.server` / `namespace` | `https://kubernetes.default.svc` / `kube-system` | Target cluster + namespace for Cilium |
| `chartVersion` | `1.18.5` | Upstream Cilium Helm chart version |
| `k8s.serviceHost` / `k8s.servicePort` | `""` / `6443` | Cluster API endpoint for `kubeProxyReplacement` |
| `kubeProxyReplacement` | `true` | Cilium replaces kube-proxy |
| `operatorReplicas` | `1` | `cilium-operator` replicas |
| `gatewayAPI.enabled` | `true` | Enables the `cilium` GatewayClass |
| `l2announcements.enabled` | `true` | L2 announcements for LoadBalancer IPs |
| `externalIPs.enabled` | `true` | Allow externalIPs on Services |
| `extraValues` | `{}` | Deep-merged on top of the computed upstream `valuesObject` |
| `lb.enabled` | `false` | Render `CiliumLoadBalancerIPPool` + `CiliumL2AnnouncementPolicy` |
| `lb.poolName` | `default-pool` | Pool name |
| `lb.blocks` | `192.168.1.240`–`250` placeholder | IP blocks — **override per cluster** |
| `lb.l2Policy.*` | `default-l2-announcement-policy` in `kube-system`, both enabled | L2 policy config |
| `gateway.enabled` | `false` | Render Gateway API `Gateway` |
| `gateway.name` / `namespace` | `cilium-gateway` / `default` | Gateway identity |
| `gateway.gatewayClassName` | `cilium` | GatewayClass to bind |
| `gateway.hostname` | `*.example.com` | Listener hostname — **override per cluster** |
| `gateway.tlsSecretName` | `cilium-gateway-tls` | TLS Secret for the HTTPS listener |
| `syncPolicy` | automated + retry | Applied to every rendered Application |

## Migrating from the previous kustomize layout

If you were consuming the old three-entry layout (`infra/cilium/chart`, `infra/cilium/lb`, `infra/cilium/gateway`) via a Kustomize overlay with JSON patches: replace all three with a single `Application` (example above). The overlay's patches map to values as follows:

| Old target / patch | New value |
|---|---|
| `Application cilium` → `/spec/project` / `/spec/destination/server` | `project` / `destination.server` |
| Inline `valuesObject` on the old cilium Application | first-class values (`kubeProxyReplacement`, `gatewayAPI.enabled`, `l2announcements.enabled`, `externalIPs.enabled`, `k8s.*`, `operatorReplicas`) or `extraValues.<path>` |
| `infra/cilium/lb/manifests/cilium-config.yaml` (raw IP pool + L2 policy) | `lb.enabled: true` + `lb.blocks` / `lb.poolName` / `lb.l2Policy.*` |
| `infra/cilium/gateway/manifests/gateway.yaml` (raw Gateway) | `gateway.enabled: true` + `gateway.hostname` / `gateway.tlsSecretName` / `gateway.name` / `gateway.namespace` |

No more raw-manifest patching for the IP range or the Gateway hostname — both are values now.

## Related

- Flux equivalent: [`stuttgart-things/flux` — `infra/cilium`](https://github.com/stuttgart-things/flux/tree/main/infra/cilium)
