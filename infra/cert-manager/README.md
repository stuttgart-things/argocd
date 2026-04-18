# infra/cert-manager

Catalog entry for [cert-manager](https://cert-manager.io/) and common ClusterIssuer bootstrap resources. Split into three sub-entries so consumers pick what they need.

## Layout

```
infra/cert-manager/
├── chart/                # cert-manager Helm chart (v1.19.2, CRDs enabled, sync-wave -10)
├── selfsigned/           # ClusterIssuer "selfsigned" (minimal, stand-alone)
└── cluster-ca/           # Certificate+ClusterIssuer "cluster-ca" + example wildcard cert
                          # requires selfsigned/ to be present
```

Each sub-entry is a self-contained kustomize base producing exactly one `Application`. Consumers reference sub-paths they want as remote kustomize bases.

## Components

### chart/
Installs the [`jetstack/cert-manager`](https://artifacthub.io/packages/helm/cert-manager/cert-manager) chart (`v1.19.2`) into the `cert-manager` namespace. `crds.enabled: true` so the chart installs the cert-manager CRDs. `sync-wave: -10` so CRDs register before any dependent Certificate/ClusterIssuer resources.

### selfsigned/
One `ClusterIssuer` named `selfsigned` that issues certs via cert-manager's internal self-signed issuer. Minimal; no dependencies beyond the chart. Suitable for dev / kind clusters where you just need cert-manager to issue self-signed leaf certs on demand.

### cluster-ca/
The classic stuttgart-things CA chain:
1. A CA `Certificate` named `cluster-ca` (issued by the `selfsigned` ClusterIssuer)
2. A `ClusterIssuer` named `cluster-ca` backed by that CA
3. An example `wildcard-tls` Certificate (`*.example.com`) issued by `cluster-ca`, deployed into the `default` namespace

Depends on `selfsigned/` being present (same catalog, pulled together). Consumers typically override the wildcard's `commonName`/`dnsNames`/`namespace` in their cluster overlay.

## Consumer usage

Minimal (dev / kind) — chart + selfsigned:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - https://github.com/stuttgart-things/argocd.git/infra/cert-manager/chart?ref=main
  - https://github.com/stuttgart-things/argocd.git/infra/cert-manager/selfsigned?ref=main
patches:
  - target: { kind: Application, name: cert-manager }
    patch: |-
      - op: replace
        path: /spec/project
        value: <cluster-project>
      - op: replace
        path: /spec/destination/server
        value: https://<cluster-api>:<port>
  - target: { kind: Application, name: cert-manager-selfsigned }
    patch: |-
      - op: replace
        path: /spec/project
        value: <cluster-project>
      - op: replace
        path: /spec/destination/server
        value: https://<cluster-api>:<port>
```

Full (production) — chart + selfsigned + cluster-ca:

```yaml
resources:
  - https://github.com/stuttgart-things/argocd.git/infra/cert-manager/chart?ref=main
  - https://github.com/stuttgart-things/argocd.git/infra/cert-manager/selfsigned?ref=main
  - https://github.com/stuttgart-things/argocd.git/infra/cert-manager/cluster-ca?ref=main
# ... plus a patch on cert-manager-cluster-ca for project + destination,
# and additional patches on the wildcard-tls Certificate (commonName / dnsNames / namespace)
```

## Related

- Flux equivalent: [`stuttgart-things/flux` — `infra/cert-manager`](https://github.com/stuttgart-things/flux/tree/main/infra/cert-manager)
