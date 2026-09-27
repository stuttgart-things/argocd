# cicd/kargo

Catalog entries for [Kargo](https://kargo.akuity.io/) — multi-stage promotion orchestrator for GitOps. Three independently deployable pieces, mirroring the Cilium layout — consumers create one ArgoCD `Application` per piece they need. A fourth, `secrets/`, is rendered by `install` itself.

## Layout

```
cicd/kargo/
├── install/      app-of-apps — renders Application "kargo" (OCI Helm, sync-wave 0)
├── certs/        plain Helm chart — renders cert-manager Certificate(s) for the API hostname
├── httproute/    plain Helm chart — renders Gateway API HTTPRoute(s) for the API
├── secrets/      plain Helm chart — kargo-admin from Vault through ESO; rendered BY install, not by a consumer
└── README.md
```

Matrix of typical consumer shapes:

| Want | Applications to create |
|---|---|
| Kargo only | `install` |
| Kargo + TLS | `install`, `certs` |
| Kargo + TLS + Gateway API | `install`, `certs`, `httproute` |
| Kargo behind the chart's built-in Ingress (no Gateway API) | `install` (patch `api.ingress.enabled: true` via `extraValues`) |

`install/` is app-of-apps (wraps the upstream OCI Helm chart). `certs/` and `httproute/` are plain Helm charts — the consumer-owned `Application` IS the outer wrapper; there's no upstream Helm chart to re-wrap.

## install/

App-of-apps Helm chart packaging the upstream akuity/kargo OCI chart (`1.9.6`) from `oci://ghcr.io/akuity/kargo-charts/kargo`.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kargo
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: cicd/kargo/install
    helm:
      values: |
        project: my-cluster
        destination:
          server: https://<cluster-api>:6443
          namespace: kargo
        api:
          host: kargo.my-cluster.example.com
          adminAccount:
            passwordHash: <bcrypt-hash>
            tokenSigningKey: <random-32-bytes>
            tokenTTL: 24h
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

### OCI Helm source

Akuity publishes the Kargo chart to OCI only. The chart targets:

```yaml
source:
  repoURL: ghcr.io/akuity/kargo-charts   # no oci:// prefix
  chart: kargo
  targetRevision: <install.chartVersion>
```

Argo CD 2.8+ with `helm.enableOciSupport: true` (default) is required. The registry is anonymous, no pull credentials needed.

### Credentials

`api.adminAccount.passwordHash` and `api.adminAccount.tokenSigningKey` ship as empty placeholders — **don't deploy as-is**.

**On a ClusterStack cluster with the `kargo` profile, nothing is done by hand.** The stack writes `kargo/<cluster>` in Vault (`password`, `tokenSigningKey`), derives the store and the gate `cicd-platform.stuttgart-things.com/secrets-config`, and `platforms/cicd/appset-kargo` passes `secrets.clusterSecretStoreName` to `install`, which then renders [`secrets/`](#secrets) — see there (stuttgart-things/stuttgart-things#3232).

Everywhere else, consumers inject real credentials one of three ways:

1. **External Secrets / Vault**: a secret-management operator writes `kargo-admin` into the namespace, then the consumer overlay sets `extraValues.api.adminAccount.existingSecret: kargo-admin`.
2. **Argo CD Vault Plugin**: wrap the consumer-side Application source in a plugin overlay that templates `<path:vault/data/kargo#password-hash>` placeholders.
3. **SOPS-encrypted overlay**: consumer maintains a decrypted `values.yaml` fragment and passes it via `helm.values` or `helm.valueFiles`.

Generate the placeholder values (bcrypt hash + random signing key):

```bash
# Password hash (bcrypt, $2a$ variant)
htpasswd -bnBC 10 "" '<your-password>' | tr -d ':\n' | sed 's/$2y/$2a/'

# Token signing key
openssl rand -base64 29 | tr -d "=+/" | head -c 32
```

### install values reference

See `install/values.yaml` / `install/values.schema.json` for the full contract.

| Key | Default | Purpose |
|---|---|---|
| `project` | `default` | ArgoCD AppProject for the rendered Application |
| `destination.server` / `namespace` | `https://kubernetes.default.svc` / `kargo` | Target workload cluster + namespace |
| `chartVersion` | `1.9.6` | Upstream kargo OCI chart version |
| `api.host` | `kargo.example.com` | External hostname (override per cluster; must match `certs/` + `httproute/`) |
| `api.service.type` | `ClusterIP` | API Service type |
| `api.tls.enabled` | `false` | TLS terminates at the Gateway / Ingress, not the API Service |
| `api.ingress.enabled` | `false` | Chart Ingress disabled in favor of `httproute/` |
| `api.adminAccount.*` | empty placeholders | See *Credentials* above |
| `secrets.clusterSecretStoreName` | `""` | Non-empty renders the sibling Application `<name>-secrets` from [`secrets/`](#secrets). A string rather than an `enabled` flag, because an ApplicationSet templates only strings |
| `secrets.vaultSecretName` | `""` | Vault entry with `password` + `tokenSigningKey`; required once a store is named |
| `secrets.secretName` | `kargo-admin` | Must match the upstream chart's `api.secret.name` |
| `catalog.repoURL` / `targetRevision` | this repo / `""` | Where `secrets/` is read from; the revision is required once a store is named — pass the tag `install` itself comes from |
| `controller.logLevel` / `garbageCollector.logLevel` | `INFO` | Log levels (`DEBUG`/`INFO`/`WARN`/`ERROR`) |
| `webhooksServer.tls.selfSignedCert` | `true` | Webhook TLS bootstraps via its own self-signed cert |
| `extraValues` | `{}` | Deep-merged on top of the computed upstream `valuesObject` |
| `syncPolicy` | automated + retry | Applied to the rendered child Application |

## secrets/

One `ExternalSecret`, `kargo-admin`, rendered as a sibling Application by `install` (sync-wave `-10`, ahead of Kargo) — not meant to be consumed directly.

Kargo wants `ADMIN_ACCOUNT_PASSWORD_HASH` as a bcrypt hash (`$2a$`). Vault holds the password **in plain** — an AppSecretProfile can generate a value, not hash one — so ESO's template engine hashes it (`bcrypt`, golang.org/x/crypto). The plain value is also what a person logs in with: `vault kv get kargo/<cluster>`.

`refreshPolicy: CreatedOnce`, because bcrypt salts: every refresh would write a new, equally valid hash. **Rotate** by changing the Vault entry, deleting the `kargo-admin` Secret (ESO recreates it) and restarting `kargo-api`, which reads it only at start.

An empty `vaultSecretName` renders nothing, on purpose: a default entry would read another cluster's admin credential without a word.

## certs/

Plain Helm chart that renders `cert-manager.io/v1.Certificate` resources from a list. Pairs with [`infra/cert-manager/cluster-ca/`](../../infra/cert-manager/cluster-ca/) — point `issuerRef` at the `cluster-ca` ClusterIssuer and cert-manager will issue a cert signed by the cluster CA.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kargo-certs
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: cicd/kargo/certs
    helm:
      values: |
        certificates:
          - name: kargo-ingress
            namespace: kargo
            commonName: kargo.my-cluster.example.com
            dnsNames:
              - kargo.my-cluster.example.com
            secretName: kargo.my-cluster.example.com-tls
            issuerRef:
              name: cluster-ca
              kind: ClusterIssuer
  destination:
    server: https://<cluster-api>:6443
    namespace: kargo
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

## httproute/

Plain Helm chart that renders `gateway.networking.k8s.io/v1.HTTPRoute` resources from a list. Pairs with [`infra/cilium/gateway/`](../../infra/cilium/gateway/) — point `parentRefs` at the cilium Gateway.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kargo-httproute
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: cicd/kargo/httproute
    helm:
      values: |
        httpRoutes:
          - name: kargo
            namespace: kargo
            parentRefs:
              - name: cilium-gateway
                namespace: default
            hostnames:
              - kargo.my-cluster.example.com
            rules:
              - backendRefs:
                  - name: kargo-api
                    port: 443
  destination:
    server: https://<cluster-api>:6443
    namespace: kargo
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ServerSideApply=true]
```

### Overriding the hostname

Keep `api.host` (install), `dnsNames` + `commonName` (certs), and `hostnames` (httproute) **in lockstep** per cluster — all three need to match for TLS + routing + API cookie `Host` checks to line up.

## Related

- Flux equivalent: [`stuttgart-things/flux` — `apps/kargo`](https://github.com/stuttgart-things/flux/tree/main/apps/kargo)
- Pairs with: [`infra/cert-manager/cluster-ca`](../../infra/cert-manager/cluster-ca/) (issues the TLS Certificate) and [`infra/cilium/gateway`](../../infra/cilium/gateway/) (parent for the HTTPRoute)
- Kargo docs: <https://docs.kargo.io/>
