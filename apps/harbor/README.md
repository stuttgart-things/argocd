# apps/harbor

Catalog entry for [Harbor](https://goharbor.io/) — cloud-native container registry. Packaged as an **app-of-apps Helm chart** over the bitnami `harbor` OCI chart, with bitnamilegacy image overrides applied throughout (the new bitnami images require an enterprise pull secret; bitnamilegacy mirrors the old free path). Consumers create one ArgoCD `Application` pointing at `apps/harbor/install`, pass overrides via `helm.values`, and the chart renders child `Application`s for Harbor itself plus opt-in cert-manager Certificate, Gateway API HTTPRoutes, and harbor-project-proxy.

Port of [`stuttgart-things/flux` — `apps/harbor`](https://github.com/stuttgart-things/flux/tree/main/apps/harbor) (including its `httproute/` and `components/project-proxy/` overlays).

## Layout

```
apps/harbor/
├── install/                        app-of-apps Helm chart (what consumers point at)
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── values.schema.json
│   └── templates/
│       ├── chart.yaml              renders Application "harbor"               (sync-wave 0,  bitnami harbor + bitnamilegacy image overrides)
│       ├── certs.yaml              renders Application "harbor-certs"         (sync-wave -10, gated by certs.enabled)
│       ├── httproute.yaml          renders Application "harbor-httproute"     (sync-wave 10, gated by httpRoute.enabled)
│       └── project-proxy.yaml      renders Application "harbor-project-proxy" (sync-wave 10, gated by projectProxy.enabled — points at oci://ghcr.io/hiddenmarten/harbor-project-proxy)
├── certs/                          cert-manager Certificate sub-chart (FQDN + wildcard SAN)
└── httproute/                      Gateway API HTTPRoutes — main + wildcard project-proxy
```

## What gets deployed

### `harbor` Application (always)
Argo CD source on `oci://registry-1.docker.io/bitnamicharts` at `chart: harbor`, `targetRevision: .Values.chartVersion`. Computed `valuesObject`:

- `externalURL: <hostname>.<domain>` + `clusterDomain: cluster.local`
- `adminPassword: .Values.adminPassword` — pass via Argo Vault Plugin / SOPS overlay; never inline a literal
- `global` — `imageRegistry: docker.io`, `defaultStorageClass`/`storageClass: .Values.storageClass`, `security.allowInsecureImages: true` (required since the bitnamilegacy mirror image digests don't match the chart's pinned digests)
- **bitnamilegacy image overrides** for nginx, portal, core, jobservice, registry (server + controller), trivy, exporter, volumePermissions, postgresql, redis — exactly the set the flux release.yaml pinned
- `exposureType: .Values.exposureType` (default `ingress`) + `service.type: ClusterIP`
- `ingress.core.{ingressClassName, hostname, tls, extraTls, annotations}` — the bitnami chart's built-in nginx Ingress. Disable by setting `ingress.enabled: false` (or `exposureType: clusterIP`) when using the httpRoute sub-App.
- `persistence.persistentVolumeClaim.{registry,trivy,jobservice}.size` — from `.Values.persistence.*`
- `.Values.extraValues` — deep-merged on top as an escape hatch

### `harbor-certs` Application (opt-in, `certs.enabled: true`, sync-wave -10)
cert-manager `Certificate` with two SANs: the apex FQDN (`<hostname>.<domain>`) for Harbor's portal and a wildcard (`*.<hostname>.<domain>`) for the project-proxy. Stored in `<fqdn>-tls`, consumed by the bitnami Ingress via `extraTls.secretName` and by the project-proxy Ingress via its `tls` block.

### `harbor-httproute` Application (opt-in, `httpRoute.enabled: true`, sync-wave 10)
Renders **two** Gateway API `HTTPRoute`s:
1. `harbor` — splits paths on the apex FQDN: `/api/`, `/v2/`, `/service/`, `/c/`, `/chartrepo/`, `/harbor/` → `harbor-core:80`, everything else → `harbor-portal:80`. Mirrors the path split that nginx Ingress does in the bitnami chart.
2. `harbor-project-proxy` — `*.<fqdn>` → `harbor-project-proxy:80`.

When using the httpRoute path, set `ingress.enabled: false` (and ideally `exposureType: clusterIP`) so the bitnami chart's own Ingress is not rendered.

### `harbor-project-proxy` Application (opt-in, `projectProxy.enabled: true`, sync-wave 10)
[`harbor-project-proxy`](https://github.com/hiddenmarten/harbor-project-proxy) — rewrites `<project>.<fqdn>` to `<fqdn>/<project>`, lets you `docker pull <project>.harbor.example.com/<image>` instead of `harbor.example.com/<project>/<image>`. Pulled from `oci://ghcr.io/hiddenmarten/harbor-project-proxy` at `.Values.projectProxy.chartVersion` (default `0.0.1`).

## Consumer usage

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: harbor
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: apps/harbor/install
    helm:
      values: |
        project: my-cluster
        destination:
          server: https://<cluster-api>:6443
          namespace: harbor
        chartVersion: 27.0.3
        hostname: harbor
        domain: my-cluster.example.com
        adminPassword: <path:vault/data/harbor#admin>
        storageClass: nfs4-csi
        exposureType: clusterIP    # disable bitnami Ingress when using HTTPRoute
        ingress:
          enabled: false
          className: nginx
        certs:
          enabled: true
          issuer:
            name: cluster-ca
            kind: ClusterIssuer
        httpRoute:
          enabled: true
          gateway:
            name: cilium-gateway
            namespace: default
        projectProxy:
          enabled: true
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
| `destination.namespace` | `harbor` | Namespace for Harbor |
| `chartVersion` | `27.0.3` | Upstream bitnami harbor chart version |
| `hostname` / `domain` | `harbor` / `example.com` | Combine to `<hostname>.<domain>` everywhere (externalURL, ingress hostname, cert CN, HTTPRoute hostnames) |
| `adminPassword` | `""` | Harbor admin password (use ArgoCD Vault Plugin / SOPS — not inline) |
| `storageClass` | `nfs4-csi` | StorageClass for Harbor PVCs (registry/trivy/jobservice + bundled DBs) |
| `persistence.{enabled,registrySize,trivySize,jobserviceSize}` | `true` / `12Gi` / `5Gi` / `1Gi` | Per-component PVC sizes |
| `exposureType` | `ingress` | One of `ingress`, `clusterIP`, `nodePort`, `loadBalancer`. Use `clusterIP` when relying solely on HTTPRoute. |
| `ingress.enabled` / `className` | `true` / `nginx` | Bitnami chart's built-in Ingress (turn off when using HTTPRoute) |
| `certs.enabled` / `issuer.{name,kind}` | `false` / `cluster-ca` / `ClusterIssuer` | cert-manager Certificate sub-App |
| `httpRoute.enabled` / `gateway.{name,namespace}` | `false` / `cilium-gateway` / `default` | Gateway API HTTPRoute sub-App |
| `projectProxy.enabled` / `chartVersion` / `replicaCount` / `ingress.{enabled,className}` | `false` / `0.0.1` / `1` / `true` / `nginx` | harbor-project-proxy sub-App |
| `extraValues` | `{}` | Deep-merged on top of the computed upstream `valuesObject` |
| `catalog.repoURL` / `targetRevision` | this repo / `HEAD` | Where the certs + httpRoute Applications fetch manifests from |
| `syncPolicy` | automated + retry | Applied to all rendered Applications |

## Why bitnamilegacy?

In late 2025 Bitnami moved its free Helm chart images to `bitnamilegacy/<name>` and gated `bitnami/<name>` behind a paid Bitnami Premium pull secret. The chart still defaults to the new `bitnami/*` paths; if you don't override, every pod ImagePulls fails with 401. The flux release.yaml pinned `bitnamilegacy/*` for every component (nginx, portal, core, jobservice, registry server + controller, trivy, exporter, volumePermissions, postgresql, redis) — this chart does the same. Setting `global.security.allowInsecureImages: true` is required because the legacy image digests don't match the chart's pinned digests.

If/when stuttgart-things mirrors a usable Harbor chart with sane image defaults, swap `chart.yaml`'s `repoURL` and drop the override block.

## Related

- Flux equivalent: [`stuttgart-things/flux` — `apps/harbor`](https://github.com/stuttgart-things/flux/tree/main/apps/harbor)
- Upstream chart: <https://github.com/bitnami/charts/tree/main/bitnami/harbor>
- Project proxy: <https://github.com/hiddenmarten/harbor-project-proxy>
