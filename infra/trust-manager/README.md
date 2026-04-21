# infra/trust-manager

Catalog entries for [trust-manager](https://cert-manager.io/docs/trust/trust-manager/) and the `Bundle` resources it reconciles. Two independently deployable pieces — consumers create one ArgoCD `Application` per piece they need.

## Layout

```
infra/trust-manager/
├── install/    app-of-apps — renders Application "trust-manager" → jetstack/trust-manager
├── bundle/     plain Helm chart — renders N trust-manager Bundle resources from a values list
└── README.md
```

Typical combinations:

| Want | Applications to create |
|---|---|
| trust-manager only (consumer writes their own Bundles) | `install` |
| trust-manager + Bundles | `install`, `bundle` |
| Bundles only (trust-manager already installed out-of-band) | `bundle` |

Pairs with [`infra/cert-manager`](../cert-manager/) — trust-manager depends on cert-manager's CRDs and webhook. The common pattern is: `infra/cert-manager/install` + `infra/cert-manager/selfsigned` + `infra/cert-manager/cluster-ca` (produces `cluster-ca-secret`), then `infra/trust-manager/install` + `infra/trust-manager/bundle` (consumes it).

## install/

App-of-apps Helm chart packaging the upstream `jetstack/trust-manager` chart. Consumer `Application` points at `infra/trust-manager/install`; chart renders a child `Application` targeting `https://charts.jetstack.io` with a computed `valuesObject`.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: trust-manager
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: infra/trust-manager/install
    helm:
      values: |
        project: my-cluster
        destination:
          server: https://<cluster-api>:6443
          namespace: cert-manager
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

### install values reference

See `install/values.yaml` / `install/values.schema.json`.

| Key | Default | Purpose |
|---|---|---|
| `project` | `default` | ArgoCD AppProject for the rendered Application |
| `destination.server` / `namespace` | `https://kubernetes.default.svc` / `cert-manager` | Target workload cluster + namespace |
| `chartVersion` | `0.22.0` | Upstream jetstack/trust-manager chart version |
| `trustNamespace` | `cert-manager` | Namespace trust-manager watches for source Secrets/ConfigMaps — keep aligned with where `cluster-ca-secret` lives |
| `extraValues` | `{}` | Deep-merged on top of the computed upstream `valuesObject` |
| `syncPolicy` | automated + retry | Applied to the rendered child Application |

## bundle/

Plain Helm chart that renders one `trust.cert-manager.io/v1alpha1` `Bundle` per entry in `bundles: [...]`. The list is empty by default — no cluster gets a pre-shipped Bundle referencing Secrets that may or may not exist.

Each entry passes a raw Bundle `spec` through, so the full trust-manager API surface is available (source types `useDefaultCAs` / `secret` / `configMap` / `inLine`; target types `configMap` / `secret` / `additionalFormats`). See the [trust-manager API reference](https://cert-manager.io/docs/trust/trust-manager/api-reference/).

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: trust-manager-bundle
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: infra/trust-manager/bundle
    helm:
      values: |
        bundles:
          - name: cluster-trust-bundle
            spec:
              sources:
                - useDefaultCAs: true
                - secret:
                    name: cluster-ca-secret
                    key: ca.crt
              target:
                configMap:
                  key: trust-bundle.pem
  destination:
    server: https://<cluster-api>:6443
    namespace: cert-manager
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ServerSideApply=true]
```

Source `Secret`s / `ConfigMap`s must live in the `trustNamespace` configured on the `install/` entry (default `cert-manager`). Cross-namespace sources are a deliberate trust-manager design choice, not a chart limitation — if the CA Secret is elsewhere, mirror it into the trust namespace first (e.g. with `cert-manager` itself issuing a `Certificate` into `cert-manager`, or with an explicit Secret sync tool).

### bundle values reference

| Key | Default | Purpose |
|---|---|---|
| `bundles` | `[]` | List of Bundles to render |

Per-entry fields:

| Field | Required | Purpose |
|---|---|---|
| `name` | ✓ | Bundle name (cluster-scoped) |
| `spec` | ✓ | Raw `trust.cert-manager.io/v1alpha1` Bundle spec; `spec.sources` (non-empty) and `spec.target` both required |

The schema enforces those two required keys and that `sources` is non-empty; everything inside `spec` passes through to the trust-manager webhook, which does deeper validation (valid source/target one-of unions, correct field shapes, …).

## Fleet — one `ApplicationSet` per piece

Label clusters with `install/trust-manager: "true"` for the controller, and `install/trust-manager-bundle: "true"` for Bundles.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: trust-manager
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - clusters:
        selector:
          matchLabels:
            install/trust-manager: "true"
  template:
    metadata:
      name: 'trust-manager-{{ .name }}'
    spec:
      project: '{{ .name }}'
      source:
        repoURL: https://github.com/stuttgart-things/argocd.git
        targetRevision: main
        path: infra/trust-manager/install
        helm:
          values: |
            project: {{ .name }}
            destination:
              server: {{ .server }}
              namespace: cert-manager
      destination: { server: https://kubernetes.default.svc, namespace: argocd }
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

For `bundle/`, a single fleet `ApplicationSet` shipping identical Bundles only fits clusters whose Secret names + layout match. When source Secrets differ per cluster, either templating the `bundles` list from cluster annotations or one Application per cluster are both valid — pick based on how much the Bundles actually vary.

## Migrating from the previous kustomize layout

| Old | New |
|---|---|
| `infra/trust-manager/chart` (kustomize dir, Application inlined) | `infra/trust-manager/install` (Helm chart; consumer Application passes `helm.values`) |
| `infra/trust-manager/bundle` (raw `cluster-trust-bundle` Bundle with hardcoded `cluster-ca-secret` + `vault-pki-ca` sources) | `infra/trust-manager/bundle` (Helm chart; the full Bundle shape is a value) |

**Breaking change**: `bundle/` no longer ships a pre-built `cluster-trust-bundle` combining Mozilla CAs + `cluster-ca-secret` + `vault-pki-ca`. The list is empty, and consumers declare whichever Bundles (and sources) they actually have. Clusters that previously consumed the path unpatched would fail reconciling because `vault-pki-ca` did not exist. Copy the example above and prune the Vault PKI source if you don't have one.

## Related

- Flux equivalent: [`stuttgart-things/flux` — `infra/trust-manager`](https://github.com/stuttgart-things/flux/tree/main/infra/trust-manager) — Flux ships the same pair (`release.yaml` + `post-release.yaml`) with env-var-substituted Bundle fields; this catalog maps them to two independently deployable charts with schema-validated values.
- Pairs with: [`infra/cert-manager`](../cert-manager/) — required for trust-manager itself; `cluster-ca/` produces the `cluster-ca-secret` a typical cluster-trust-bundle references.
