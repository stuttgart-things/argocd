# apps/claim-machinery-api

Catalog entry for [claim-machinery-api](https://github.com/stuttgart-things/claim-machinery-api) — REST API behind the Backstage `claimMachinery` plugin and CLI. Packaged as an **app-of-apps Helm chart** over the `claim-machinery-api-kustomize` OCI base: consumers create one ArgoCD `Application` pointing at `apps/claim-machinery-api/install`, pass overrides via `helm.values`, and the chart renders child `Application`s that install the API, optionally publish its HTTPRoute, and optionally provision the HOMERUN auth-token Secret.

Port of [`stuttgart-things/flux` — `apps/claim-machinery-api`](https://github.com/stuttgart-things/flux/tree/main/apps/claim-machinery-api).

## Layout

```
apps/claim-machinery-api/
├── install/                        app-of-apps Helm chart (what consumers point at)
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── values.schema.json
│   └── templates/
│       ├── chart.yaml              renders Application "claim-machinery-api"            (sync-wave 0, OCI kustomize + 5 patches)
│       ├── httproute.yaml          renders Application "claim-machinery-api-httproute"  (sync-wave 10, gated by httpRoute.enabled)
│       └── auth-secret.yaml        renders Application "claim-machinery-api-auth"       (sync-wave -10, gated by authSecret.enabled)
├── httproute/                      Gateway API HTTPRoute sub-chart
└── auth-secret/                    HOMERUN auth-token Secret sub-chart (dev-only)
```

## What gets deployed

### `claim-machinery-api` Application (always)
Argo CD Kustomize source against `oci://ghcr.io/stuttgart-things/claim-machinery-api-kustomize` at `.Values.kustomize.targetRevision`. The install chart emits five Kustomize `patches` mirroring the flux `release.yaml`:

1. **Ingress delete** — base ships an Ingress; we always remove it (Gateway API is the path here)
2. **Deployment image override + `args: [server]`** — `ghcr.io/stuttgart-things/claim-machinery-api:<tag>`
3. **ConfigMap overrides** — `TEMPLATE_PROFILE_PATH` + `ENABLE_HOMERUN` + `HOMERUN_URL`
4. **HOMERUN_AUTH_TOKEN env** — pulled from `.Values.auth.{secretName,secretKey}` with `optional: true` (so the pod boots when the Secret hasn't landed yet)
5. **trust-bundle volume + SSL_CERT_DIR** — mounts a key out of `.Values.trustBundle.configMapName` (defaults to `cluster-trust-bundle` from `infra/trust-manager`) at `<sslCertDir>/<key>`. ConfigMap is `optional: true`.

### `claim-machinery-api-httproute` Application (opt-in, `httpRoute.enabled: true`)
One Gateway API `HTTPRoute` pointing at `claim-machinery-api:8080`, parented onto `.Values.httpRoute.gateway`.

### `claim-machinery-api-auth` Application (opt-in, `authSecret.enabled: true`, sync-wave -10)
Provisions the `claim-machinery-auth` Secret with `HOMERUN_AUTH_TOKEN` before the main app reconciles. **Inlining a literal token in git is dev-only** — for real deployments, leave `authSecret.enabled: false` and provision the Secret out-of-band via ExternalSecrets / SOPS / Vault plugin.

## Consumer usage

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: claim-machinery-api
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: apps/claim-machinery-api/install
    helm:
      values: |
        project: my-cluster
        destination:
          server: https://<cluster-api>:6443
          namespace: claim-machinery
        kustomize:
          repoURL: ghcr.io/stuttgart-things/claim-machinery-api-kustomize
          targetRevision: v0.21.1
        image:
          repository: ghcr.io/stuttgart-things/claim-machinery-api
          tag: v0.21.1
        config:
          templateProfilePath: /etc/claim-machinery/profile.json
          homerun:
            enabled: true
            url: https://homerun2.example.com
        httpRoute:
          enabled: true
          hostname: claim-api.my-cluster.example.com
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
| `destination.namespace` | `claim-machinery` | Namespace for the API |
| `kustomize.repoURL` / `targetRevision` | `ghcr.io/stuttgart-things/claim-machinery-api-kustomize` / `v0.21.1` | OCI kustomize base + tag |
| `image.repository` / `tag` | `ghcr.io/stuttgart-things/claim-machinery-api` / `v0.21.1` | Container image |
| `config.templateProfilePath` | `""` | `TEMPLATE_PROFILE_PATH` env on the API |
| `config.homerun.enabled` / `url` | `false` / `""` | `ENABLE_HOMERUN` + `HOMERUN_URL` |
| `auth.secretName` / `secretKey` | `claim-machinery-auth` / `HOMERUN_AUTH_TOKEN` | Where the Deployment looks for the token |
| `trustBundle.configMapName` / `key` / `sslCertDir` | `cluster-trust-bundle` / `trust-bundle.pem` / `/etc/ssl/custom` | trust-manager bundle mount |
| `httpRoute.enabled` | `true` | Render the Gateway API sub-App |
| `httpRoute.hostname` / `gateway.*` | `claim-machinery-api.example.com` / `cilium-gateway` / `default` | Route target |
| `authSecret.enabled` / `homerunAuthToken` | `false` / `""` | Inline-Secret sub-App (dev only) |
| `catalog.repoURL` / `targetRevision` | this repo / `HEAD` | Where the httpRoute + auth Applications fetch manifests from |
| `syncPolicy` | automated + retry | Applied to all rendered Applications |

## Related

- Flux equivalent: [`stuttgart-things/flux` — `apps/claim-machinery-api`](https://github.com/stuttgart-things/flux/tree/main/apps/claim-machinery-api)
- Upstream repo: <https://github.com/stuttgart-things/claim-machinery-api>
- trust bundle producer: [`infra/trust-manager`](../../infra/trust-manager/)
