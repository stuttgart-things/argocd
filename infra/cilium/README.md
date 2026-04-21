# infra/cilium

Catalog entries for [Cilium](https://cilium.io/) plus its optional LoadBalancer IP pool and Gateway API Gateway. Modelled after the Flux layout (`stuttgart-things/flux` → `infra/cilium/components/{install,lb,gateway}`) — three independently deployable pieces you can mix and match. Consumers create one ArgoCD `Application` per piece they need.

## Layout

```
infra/cilium/
├── install/    app-of-apps — renders Application "cilium" → helm.cilium.io
├── lb/         plain Helm chart — renders CiliumLoadBalancerIPPool + CiliumL2AnnouncementPolicy
├── gateway/    plain Helm chart — renders Gateway API Gateway (HTTPS terminate + HTTP)
└── README.md
```

Matrix of typical consumer shapes:

| Want | Applications to create |
|---|---|
| Cilium only | `install` |
| Cilium + LB | `install`, `lb` |
| Cilium + LB + Gateway | `install`, `lb`, `gateway` |
| LB only (Cilium already running) | `lb` |
| LB + Gateway (Cilium already running) | `lb`, `gateway` |
| Gateway only (Cilium already running) | `gateway` |

## install/

App-of-apps Helm chart packaging the upstream Cilium Helm chart. Consumer `Application` points at `infra/cilium/install`; chart renders a child `Application` targeting `https://helm.cilium.io` with a computed `valuesObject`. Mirrors the openebs / headlamp / minio pattern.

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
    path: infra/cilium/install
    helm:
      values: |
        project: my-cluster
        destination:
          server: https://<cluster-api>:6443
          namespace: kube-system
        k8s:
          serviceHost: <cluster-api>
          servicePort: 6443
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

The outer `destination.server` is the **management cluster** (where the child Application CR lives). The inner `destination.server` in values is the **workload cluster** where Cilium actually installs.

### install values reference

See `install/values.yaml` / `install/values.schema.json` for the full contract.

| Key | Default | Purpose |
|---|---|---|
| `project` | `default` | ArgoCD AppProject for the rendered Application |
| `destination.server` / `namespace` | `https://kubernetes.default.svc` / `kube-system` | Target workload cluster + namespace |
| `chartVersion` | `1.18.5` | Upstream Cilium Helm chart version |
| `k8s.serviceHost` / `servicePort` | `""` / `6443` | Cluster API endpoint for `kubeProxyReplacement` |
| `kubeProxyReplacement` | `true` | Cilium replaces kube-proxy |
| `operatorReplicas` | `1` | `cilium-operator` replicas |
| `gatewayAPI.enabled` | `true` | Enables the `cilium` GatewayClass (required by `gateway/`) |
| `l2announcements.enabled` | `true` | L2 announcements (required by `lb/`) |
| `externalIPs.enabled` | `true` | Allow externalIPs on Services (required by `lb/`) |
| `extraValues` | `{}` | Deep-merged on top of the computed upstream `valuesObject` |
| `syncPolicy` | automated + retry | Applied to the rendered child Application |

## lb/

Plain Helm chart that renders `CiliumLoadBalancerIPPool` + `CiliumL2AnnouncementPolicy` directly. Consumer `Application` points at `infra/cilium/lb` with values describing the IP blocks — no app-of-apps wrapper, because there's no upstream Helm chart involved; the consumer-owned `Application` IS the outer wrapper.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cilium-lb
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: infra/cilium/lb
    helm:
      values: |
        poolName: my-cluster-pool
        blocks:
          - start: 10.0.42.10
            stop: 10.0.42.30
        l2Policy:
          name: default-l2-announcement-policy
          namespace: kube-system
          externalIPs: true
          loadBalancerIPs: true
  destination:
    server: https://<cluster-api>:6443
    namespace: kube-system
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ServerSideApply=true]
```

Prerequisite (whether you installed Cilium via `install/` or out-of-band): `l2announcements.enabled: true` and `externalIPs.enabled: true` on the running Cilium. Defaults in `install/` already set those.

### lb values reference

See `lb/values.yaml` / `lb/values.schema.json` for the full contract.

| Key | Default | Purpose |
|---|---|---|
| `poolName` | `default-pool` | `CiliumLoadBalancerIPPool` name |
| `blocks` | `192.168.1.240`–`250` placeholder | IP blocks — **override per cluster**; each entry supports `start`/`stop` or `cidr` |
| `l2Policy.name` / `namespace` | `default-l2-announcement-policy` / `kube-system` | `CiliumL2AnnouncementPolicy` identity |
| `l2Policy.externalIPs` / `loadBalancerIPs` | `true` / `true` | L2 announcement flags |

## gateway/

Plain Helm chart that renders a Gateway API `Gateway` (HTTPS terminate + HTTP listener). Same shape as `lb/` — consumer `Application` IS the outer wrapper.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cilium-gateway
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: infra/cilium/gateway
    helm:
      values: |
        name: cilium-gateway
        namespace: default
        gatewayClassName: cilium
        hostname: "*.my-cluster.example.com"
        tlsSecretName: my-cluster-gateway-tls
  destination:
    server: https://<cluster-api>:6443
    namespace: default
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ServerSideApply=true]
```

Prerequisite: the `cilium` GatewayClass must exist (`gatewayAPI.enabled: true` in `install/`, or the equivalent on your out-of-band Cilium install).

### gateway values reference

See `gateway/values.yaml` / `gateway/values.schema.json` for the full contract.

| Key | Default | Purpose |
|---|---|---|
| `name` | `cilium-gateway` | `Gateway` name |
| `namespace` | `default` | `Gateway` namespace |
| `gatewayClassName` | `cilium` | `GatewayClass` to bind |
| `hostname` | `*.example.com` | Listener hostname — **override per cluster** |
| `tlsSecretName` | `cilium-gateway-tls` | TLS Secret for the HTTPS listener |

## Fleet — one `ApplicationSet` per piece

Because each entry is a self-contained chart, fleet mode is one `ApplicationSet` per piece. Install Cilium everywhere a cluster has `install/cilium: "true"`, and layer `lb`/`gateway` with their own label selectors — the pieces are orthogonal.

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
        path: infra/cilium/install
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

Analogous `ApplicationSet`s can target `path: infra/cilium/lb` with selector `install/cilium-lb: "true"` and `path: infra/cilium/gateway` with `install/cilium-gateway: "true"` — each takes its own cluster-specific values (IP blocks, hostname, TLS secret) and doesn't know or care about the others.

## Migrating from the previous kustomize layout

If you were consuming the old three-entry kustomize layout (`infra/cilium/chart`, `infra/cilium/lb`, `infra/cilium/gateway` each with `application.yaml` + `kustomization.yaml`) via an overlay with JSON patches: replace each patched Application with one `Application` pointing at the new chart. Mapping:

| Old | New |
|---|---|
| `infra/cilium/chart` (kustomize dir, Application inlined) | `infra/cilium/install` (Helm chart; consumer Application passes `helm.values`) |
| `infra/cilium/lb` (raw manifests, patched per cluster) | `infra/cilium/lb` (Helm chart; blocks / pool / policy are values) |
| `infra/cilium/gateway` (raw manifests, patched per cluster) | `infra/cilium/gateway` (Helm chart; hostname / TLS secret / name / namespace are values) |

No more raw-manifest patching — every per-cluster knob is a value, enforced by each chart's `values.schema.json`.

## Related

- Flux equivalent: [`stuttgart-things/flux` — `infra/cilium`](https://github.com/stuttgart-things/flux/tree/main/infra/cilium) — this catalog's `install/` `lb/` `gateway/` are the ArgoCD analogs of Flux's `components/install`, `components/lb`, `components/gateway`.
