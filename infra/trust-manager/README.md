# infra/trust-manager

Catalog entry for [trust-manager](https://cert-manager.io/docs/trust/trust-manager/) plus an opinionated cluster-wide trust Bundle. Split into two sub-entries so consumers pick what they need.

## Layout

```
infra/trust-manager/
├── chart/             # trust-manager Helm chart (v0.22.0, sync-wave 0)
└── bundle/            # cluster-trust-bundle: default CAs + cluster CA + Vault PKI CA (sync-wave 10)
```

Each sub-entry is a self-contained Kustomize base producing exactly one `Application`.

## Components

### chart/
Installs the [`jetstack/trust-manager`](https://artifacthub.io/packages/helm/cert-manager/trust-manager) chart (`0.22.0`) into the `cert-manager` namespace alongside cert-manager itself. `app.trust.namespace: cert-manager` so trust-manager watches `cert-manager` as its trust source namespace — keep this aligned with the namespace hosting `cluster-ca-secret`.

Depends on cert-manager CRDs + webhook being present — pair with `infra/cert-manager/chart/`.

### bundle/
One `trust.cert-manager.io/v1alpha1` `Bundle` named `cluster-trust-bundle` that merges:

1. Mozilla's default public CA trust store (`useDefaultCAs: true`)
2. The cluster's own CA (`cluster-ca-secret` / `ca.crt`, produced by `infra/cert-manager/cluster-ca/`)
3. The Vault PKI intermediate CA (`vault-pki-ca` / `ca.crt`)

Distributes the combined trust store as a ConfigMap keyed `trust-bundle.pem` across every namespace. `sync-wave: 10` so the `Bundle` lands after the `chart/` CRDs register.

Consumers typically override the source `Secret` names / namespaces and the target key in a cluster overlay. If the Vault PKI source isn't present in a given cluster, patch that entry out.

## Consumer usage

Full stack (chart + bundle):

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - https://github.com/stuttgart-things/argocd.git/infra/trust-manager/chart?ref=main
  - https://github.com/stuttgart-things/argocd.git/infra/trust-manager/bundle?ref=main
patches:
  - target: { kind: Application, name: trust-manager }
    patch: |-
      - op: replace
        path: /spec/project
        value: <cluster-project>
      - op: replace
        path: /spec/destination/server
        value: https://<cluster-api>:<port>
  - target: { kind: Application, name: trust-manager-bundle }
    patch: |-
      - op: replace
        path: /spec/project
        value: <cluster-project>
      - op: replace
        path: /spec/destination/server
        value: https://<cluster-api>:<port>
```

Chart-only clusters (no opinionated bundle) omit the second entry and define their own `Bundle` resources out-of-band.

## Related

- Flux equivalent: [`stuttgart-things/flux` — `infra/trust-manager`](https://github.com/stuttgart-things/flux/tree/main/infra/trust-manager)
- Pairs with: [`infra/cert-manager`](../cert-manager/) (required for trust-manager itself; `cluster-ca/` produces `cluster-ca-secret`)
