# apps/rancher

Catalog entry for [Rancher](https://www.rancher.com/) via the `rancher-stable` Helm repo. Packaged as an **app-of-apps Helm chart**: consumers create one ArgoCD `Application` (or `ApplicationSet`) pointing at `apps/rancher/install`, pass overrides via `helm.values`, and the chart renders child `Application`s for Rancher itself plus opt-in cert-manager Certificate and Gateway API HTTPRoute sub-Applications.

Port of [`stuttgart-things/flux` — `apps/rancher`](https://github.com/stuttgart-things/flux/tree/main/apps/rancher). The flux version's `postBuild.substitute` variables map to first-class values here. TLS is terminated at the Gateway API `Gateway`; Rancher runs with `ingress.enabled: false` and `tls: external`, and traffic is routed via an `HTTPRoute` to the `rancher` Service on port `80`.

## Layout

```
apps/rancher/
├── install/                        app-of-apps Helm chart (what consumers point at)
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── values.schema.json
│   └── templates/
│       ├── chart.yaml              renders Application "rancher"           (sync-wave 0, rancher-stable/rancher)
│       ├── certs.yaml              renders Application "rancher-certs"     (sync-wave -10, gated by certs.enabled)
│       └── httproute.yaml          renders Application "rancher-httproute" (sync-wave 10, gated by httpRoute.enabled)
├── certs/                          cert-manager Certificate sub-chart
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── values.schema.json
│   └── templates/certificate.yaml
└── httproute/                      Gateway API HTTPRoute (+ ReferenceGrant) sub-chart
    ├── Chart.yaml
    ├── values.yaml
    ├── values.schema.json
    └── templates/httproutes.yaml
```

## What gets deployed

### `rancher` Application (always)
Argo CD source on `https://releases.rancher.com/server-charts/stable` at `chart: rancher`, `targetRevision: .Values.chartVersion`. The install chart constructs the upstream `valuesObject`:

- `hostname` — `<hostname>.<domain>`
- `replicas` — `.Values.replicas`
- `tls` — `.Values.tls` (default `external`, since the Gateway terminates TLS)
- `ingress.enabled` — `false` (use the httpRoute sub-App instead)
- `privateCA` — `.Values.privateCA` (trust a private/internal CA via the `tls-ca` secret)
- `global.cattle.psp.enabled` — `false`
- `bootstrapPassword` — only set when `.Values.bootstrapPassword` is non-empty
- `.Values.extraValues` — deep-merged on top as an escape hatch

> When `privateCA: true`, the chart expects a `tls-ca` secret (`cacerts.pem`) in the
> namespace — typically distributed by **trust-manager** (see `infra/trust-manager`
> with `secretTargets.enabled` and a Bundle writing `tls-ca` into the namespace).

### `rancher-certs` Application (opt-in, `certs.enabled: true`, sync-wave -10)
Provisions a cert-manager `Certificate` (secret `<fqdn>-tls`) using `.Values.certs.issuer.{name,kind}` (defaults `cluster-ca` / `ClusterIssuer`). Provision the cert *before* the Gateway listener / Rancher reconcile.

### `rancher-httproute` Application (opt-in, `httpRoute.enabled: true`, sync-wave 10)
Renders a cross-namespace `ReferenceGrant` (Gateway → Service) plus the Rancher `HTTPRoute`, parented onto `.Values.httpRoute.gateway`, routing `/` to the `rancher` Service on port `80`. Keep `ingress.enabled: false` and `tls: external` when using this.

## Consumer usage

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: rancher
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: apps/rancher/install
    helm:
      values: |
        project: my-cluster
        destination:
          server: https://<cluster-api>:6443
          namespace: cattle-system
        chartVersion: 2.14.2
        hostname: rancher
        domain: my-cluster.example.com
        replicas: 3
        bootstrapPassword: "ChangeMe123"   # pragma: allowlist secret
        tls: external
        certs:
          enabled: true
          issuer:
            name: cluster-issuer-approle
            kind: ClusterIssuer
        httpRoute:
          enabled: true
          gateway:
            name: cilium-gateway
            namespace: default
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

## Values reference

| Key | Default | Purpose |
|---|---|---|
| `project` | `default` | AppProject for all rendered Applications |
| `destination.server` | `https://kubernetes.default.svc` | Target cluster API |
| `destination.namespace` | `cattle-system` | Namespace for Rancher |
| `chartVersion` | `2.14.2` | Upstream rancher-stable chart version |
| `hostname` | `rancher` | Hostname prefix |
| `domain` | `example.com` | Base domain (`hostname` = `<hostname>.<domain>`) |
| `replicas` | `3` | Rancher replica count |
| `bootstrapPassword` | `""` | Initial admin password (omit to manage out-of-band) |
| `tls` | `external` | Rancher TLS source (`external` = Gateway terminates TLS) |
| `privateCA` | `false` | Trust a private CA via the `tls-ca` secret (needs trust-manager) |
| `ingress.enabled` | `false` | Rancher's built-in ingress (leave off when using httpRoute) |
| `certs.enabled` | `false` | Render the cert-manager Certificate sub-App |
| `httpRoute.enabled` | `true` | Render the Gateway API HTTPRoute sub-App |
| `extraValues` | `{}` | Deep-merged on top of the computed upstream `valuesObject` |
| `catalog.repoURL` / `targetRevision` | this repo / `HEAD` | Where the certs + httpRoute Applications fetch manifests from |
| `syncPolicy` | automated + retry | Applied to all rendered Applications |

## Sync-wave ordering

1. **-10 `rancher-certs`** — provision the TLS Secret *before* Rancher reconciles (if used).
2. **0 `rancher`** — core Rancher chart.
3. **10 `rancher-httproute`** — ReferenceGrant + HTTPRoute land after the `rancher` Service exists.

## Related

- Flux equivalent: [`stuttgart-things/flux` — `apps/rancher`](https://github.com/stuttgart-things/flux/tree/main/apps/rancher)
- Upstream chart: `https://releases.rancher.com/server-charts/stable` at `chart: rancher`
