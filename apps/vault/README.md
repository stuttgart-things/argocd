# apps/vault

Catalog entry for [HashiCorp Vault](https://www.vaultproject.io/) via the stuttgart-things Helm mirror. Packaged as an **app-of-apps Helm chart**: consumers create one ArgoCD `Application` (or `ApplicationSet`) pointing at `apps/vault/install`, pass overrides via `helm.values`, and the chart renders child `Application`s for Vault itself plus opt-in cert-manager Certificate, Gateway API HTTPRoute, and vault-autounseal sub-Applications.

Port of [`stuttgart-things/flux` — `apps/vault`](https://github.com/stuttgart-things/flux/tree/main/apps/vault) (including `apps/vault/autounseal` and `apps/vault/httproute`). The flux version's `postBuild.substitute` variables map to first-class values here.

## Layout

```
apps/vault/
├── install/                        app-of-apps Helm chart (what consumers point at)
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── values.schema.json
│   └── templates/
│       ├── chart.yaml              renders Application "vault"              (sync-wave 0, stuttgart-things/charts/vault/vault)
│       ├── certs.yaml              renders Application "vault-certs"        (sync-wave -10, gated by certs.enabled)
│       ├── httproute.yaml          renders Application "vault-httproute"    (sync-wave 10, gated by httpRoute.enabled)
│       └── autounseal.yaml         renders Application "vault-autounseal"   (sync-wave 20, gated by autounseal.enabled — points at pytoshka/vault-autounseal)
├── certs/                          cert-manager Certificate sub-chart (for the built-in ingress TLS)
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── values.schema.json
│   └── templates/certificate.yaml
└── httproute/                      Gateway API HTTPRoute sub-chart
    ├── Chart.yaml
    ├── values.yaml
    ├── values.schema.json
    └── templates/httproutes.yaml
```

## What gets deployed

### `vault` Application (always)
Argo CD source on `oci://ghcr.io/stuttgart-things` at `chart: charts/vault/vault`, `targetRevision: .Values.chartVersion`. The install chart constructs the upstream `valuesObject`:

- `server.image` — Vault server image from `.Values.image`
- `server.ingress` — built-in Vault Ingress, only rendered when `ingress.enabled: true` (leave `false` when using the httpRoute sub-App)
- `global.storageClass` / `global.security.allowInsecureImages: true` (required when overriding the chart's default image digest)
- `injector` — Vault Agent Injector sidecar config (`.Values.injector`)
- `volumePermissions` — chown init container (`.Values.volumePermissions`)
- `.Values.extraValues` — deep-merged on top as an escape hatch

### `vault-certs` Application (opt-in, `certs.enabled: true`, sync-wave -10)
Provisions a cert-manager `Certificate` for the Vault built-in ingress TLS Secret. Uses `.Values.certs.issuer.{name,kind}` (defaults `cluster-ca` / `ClusterIssuer`). Skip when using the HTTPRoute path (Gateway terminates TLS there).

### `vault-httproute` Application (opt-in, `httpRoute.enabled: true`, sync-wave 10)
Renders one Gateway API `HTTPRoute` pointing at `vault-server:8200`, parented onto `.Values.httpRoute.gateway`. When using this, keep `ingress.enabled: false` (the flux README's same guidance applies).

### `vault-autounseal` Application (opt-in, `autounseal.enabled: true`, sync-wave 20)
Deploys [`vault-autounseal`](https://github.com/pytoshka/vault-autounseal) from `.Values.autounseal.repoURL` (default `https://pytoshka.github.io/vault-autounseal`). Settings:

- `vault_url` — how the operator reaches Vault (default `http://vault-server.vault.svc:8200`)
- `vault_label_selector` — which pods to treat as server pods (default `app.kubernetes.io/component=server`)

## Consumer usage

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: vault
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: apps/vault/install
    helm:
      values: |
        project: my-cluster
        destination:
          server: https://<cluster-api>:6443
          namespace: vault
        chartVersion: 1.9.0
        image:
          registry: ghcr.io
          repository: stuttgart-things/vault
          tag: 1.20.2-debian-12-r2
        storageClass: openebs-hostpath
        injector:
          enabled: true
        httpRoute:
          enabled: true
          hostname: vault.my-cluster.example.com
          gateway:
            name: cilium-gateway
            namespace: default
        autounseal:
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
| `destination.namespace` | `vault` | Namespace for Vault |
| `chartVersion` | `1.9.0` | Upstream stuttgart-things vault chart version |
| `image.*` | `ghcr.io/stuttgart-things/vault:1.20.2-debian-12-r2` | Vault server image |
| `storageClass` | `standard` | `global.storageClass` for server PVCs |
| `ingress.enabled` | `false` | Enable Vault chart's built-in ingress (leave off when using httpRoute) |
| `injector.enabled` | `true` | Deploy Vault Agent Injector |
| `volumePermissions.enabled` | `true` | Init container chown for server PVCs |
| `certs.enabled` | `false` | Render the cert-manager Certificate sub-App |
| `httpRoute.enabled` | `true` | Render the Gateway API HTTPRoute sub-App |
| `autounseal.enabled` | `false` | Deploy pytoshka/vault-autounseal sub-App |
| `extraValues` | `{}` | Deep-merged on top of the computed upstream `valuesObject` |
| `catalog.repoURL` / `targetRevision` | this repo / `HEAD` | Where the certs + httpRoute Applications fetch manifests from |
| `syncPolicy` | automated + retry | Applied to all rendered Applications |

## Sync-wave ordering

1. **-10 `vault-certs`** — provision the TLS Secret *before* Vault reconciles (if ingress TLS is used).
2. **0 `vault`** — core Vault chart.
3. **10 `vault-httproute`** — HTTPRoute lands after the `vault-server` Service exists.
4. **20 `vault-autounseal`** — the unseal operator only matters once Vault pods are running.

## Related

- Flux equivalent: [`stuttgart-things/flux` — `apps/vault`](https://github.com/stuttgart-things/flux/tree/main/apps/vault)
- Upstream chart: `oci://ghcr.io/stuttgart-things` at `charts/vault/vault`
- Autounseal: <https://github.com/pytoshka/vault-autounseal>
