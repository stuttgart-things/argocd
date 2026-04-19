# cicd/kargo

Catalog entry for [Kargo](https://kargo.akuity.io/) — multi-stage promotion orchestrator for GitOps — from the Akuity OCI Helm registry. Split into three sub-entries so consumers pick what they need.

## Layout

```
cicd/kargo/
├── chart/             # Kargo Helm chart (OCI, v1.9.6, sync-wave 0)
├── certs/             # cert-manager Certificate for the API hostname (sync-wave -5)
└── httproute/         # Gateway API HTTPRoute routing the API through cilium-gateway (sync-wave 10)
```

Each sub-entry is a self-contained Kustomize base producing exactly one `Application`.

## Components

### chart/
Installs the Akuity `kargo` chart (`1.9.6`) from `oci://ghcr.io/akuity/kargo-charts/kargo` into the `kargo` namespace.

Opinionated defaults:

- `api.host: kargo.example.com` — placeholder hostname, override in consumer overlay
- `api.adminAccount.passwordHash` / `tokenSigningKey` — **empty placeholders** (see *Credentials* below)
- `api.adminAccount.tokenTTL: 24h`
- `api.service.type: ClusterIP` + `api.tls.enabled: false` — TLS termination happens at the Gateway / Ingress, not inside the API Service
- `api.ingress.enabled: false` — chart Ingress disabled in favor of the `httproute/` sub-entry
- `webhooksServer.tls.selfSignedCert: true` — webhook TLS bootstraps via its own self-signed cert (not cert-manager)
- `controller.logLevel` / `garbageCollector.logLevel: INFO`

#### OCI Helm source

Akuity publishes the Kargo chart to OCI only. Argo CD expresses this as:

```yaml
source:
  repoURL: ghcr.io/akuity/kargo-charts   # no oci:// prefix
  chart: kargo
  targetRevision: 1.9.6
```

Argo CD 2.8+ with `helm.enableOciSupport: true` (default) is required. The registry is anonymous, no pull credentials needed.

#### Credentials

`adminAccount.passwordHash` and `adminAccount.tokenSigningKey` ship as empty placeholders — **don't deploy as-is**. Consumers inject real credentials one of three ways:

1. **External Secrets / Vault**: a secret-management operator writes `kargo-admin` into the namespace, then a consumer overlay patches the Application's `valuesObject.api.adminAccount.existingSecret: kargo-admin`.
2. **Argo CD Vault Plugin**: wrap the `chart/` Application source in a plugin overlay that templates `<path:vault/data/kargo#password-hash>` placeholders.
3. **SOPS-encrypted overlay**: a consumer overlay patches `valuesObject.api.adminAccount` from a decrypted values file.

Generate the placeholder values (bcrypt hash + random signing key):

```bash
# Password hash (bcrypt, $2a$ variant)
htpasswd -bnBC 10 "" '<your-password>' | tr -d ':\n' | sed 's/$2y/$2a/'

# Token signing key
openssl rand -base64 29 | tr -d "=+/" | head -c 32
```

### certs/
One cert-manager `Certificate` named `kargo-ingress` in the `kargo` namespace for the API hostname (`kargo.example.com`), issued by `ClusterIssuer/cluster-ca` and written to secret `kargo.example.com-tls`. Pairs with [`infra/cert-manager/cluster-ca/`](../../infra/cert-manager/cluster-ca/).

`sync-wave: -5` so the Secret exists before the HTTPRoute references it. Consumers must patch `commonName`, `dnsNames`, `secretName`, and `issuerRef.name` in a cluster overlay.

### httproute/
One Gateway API `HTTPRoute` named `kargo` in the `kargo` namespace routing `kargo.example.com` → `kargo-api:443` via parent `Gateway/cilium-gateway` in the `default` namespace. `sync-wave: 10` so the chart's `kargo-api` Service exists first.

Consumers override `hostnames`, `parentRefs.name`, `parentRefs.namespace` per cluster.

## Consumer usage

Full stack (chart + certs + httproute):

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - https://github.com/stuttgart-things/argocd.git/cicd/kargo/chart?ref=main
  - https://github.com/stuttgart-things/argocd.git/cicd/kargo/certs?ref=main
  - https://github.com/stuttgart-things/argocd.git/cicd/kargo/httproute?ref=main
patches:
  - target: { kind: Application, name: kargo }
    patch: |-
      - op: replace
        path: /spec/project
        value: <cluster-project>
      - op: replace
        path: /spec/destination/server
        value: https://<cluster-api>:<port>
  - target: { kind: Application, name: kargo-certs }
    patch: |-
      - op: replace
        path: /spec/project
        value: <cluster-project>
      - op: replace
        path: /spec/destination/server
        value: https://<cluster-api>:<port>
  - target: { kind: Application, name: kargo-httproute }
    patch: |-
      - op: replace
        path: /spec/project
        value: <cluster-project>
      - op: replace
        path: /spec/destination/server
        value: https://<cluster-api>:<port>
```

Chart-only clusters (no TLS, no Gateway API) omit `certs/` and `httproute/` and either expose the API via the chart's built-in Ingress (patch `api.ingress.enabled: true` + classname + annotations) or port-forward for local dev.

### Overriding the hostname

Patch the `chart/` Application's `valuesObject.api.host` **and** the `certs/` + `httproute/` manifests' hostnames in the same overlay — all three need to match for TLS + routing + API cookie `Host` checks to line up.

## Related

- Flux equivalent: [`stuttgart-things/flux` — `apps/kargo`](https://github.com/stuttgart-things/flux/tree/main/apps/kargo)
- Pairs with: [`infra/cert-manager/cluster-ca`](../../infra/cert-manager/cluster-ca/) (issues the TLS Certificate) and [`infra/cilium/gateway`](../../infra/cilium/gateway/) (parent for the HTTPRoute)
- Kargo docs: <https://docs.kargo.io/>
