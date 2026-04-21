# infra/cert-manager

Catalog entries for [cert-manager](https://cert-manager.io/) and its common bootstrap resources. Three independently deployable pieces — consumers create one ArgoCD `Application` per piece they need.

## Layout

```
infra/cert-manager/
├── install/       app-of-apps — renders Application "cert-manager" → jetstack/cert-manager
├── selfsigned/    plain Helm chart — renders the `selfsigned` ClusterIssuer
├── cluster-ca/    plain Helm chart — renders CA Certificate + CA ClusterIssuer + optional wildcard Certificate
└── README.md
```

Typical combinations:

| Want | Applications to create |
|---|---|
| cert-manager only | `install` |
| cert-manager + self-signed issuer (dev / kind) | `install`, `selfsigned` |
| Full CA chain (prod) | `install`, `selfsigned`, `cluster-ca` |
| CA chain on top of an already-installed cert-manager | `selfsigned`, `cluster-ca` |
| Additional CA chain on a cluster that already has one | `cluster-ca` with renamed `ca.name` + `ca.secretName` |

## install/

App-of-apps Helm chart packaging the upstream `jetstack/cert-manager` chart. Consumer `Application` points at `infra/cert-manager/install`; chart renders a child `Application` targeting `https://charts.jetstack.io` with a computed `valuesObject`.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cert-manager
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: infra/cert-manager/install
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
| `chartVersion` | `v1.19.2` | Upstream jetstack/cert-manager chart version |
| `crds.enabled` | `true` | Install cert-manager CRDs via the chart |
| `extraValues` | `{}` | Deep-merged on top of the computed upstream `valuesObject` |
| `syncPolicy` | automated + retry | Applied to the rendered child Application |

## selfsigned/

Plain Helm chart that renders a single self-signed `ClusterIssuer`. Consumer `Application` points at `infra/cert-manager/selfsigned` — no app-of-apps wrapper, because there's no upstream chart to wrap.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cert-manager-selfsigned
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: infra/cert-manager/selfsigned
  destination:
    server: https://<cluster-api>:6443
    namespace: cert-manager
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ServerSideApply=true]
```

### selfsigned values reference

| Key | Default | Purpose |
|---|---|---|
| `name` | `selfsigned` | ClusterIssuer name. Referenced by `cluster-ca/` — override there too if you rename |

## cluster-ca/

Plain Helm chart that renders a CA chain: a CA `Certificate` (signed by the self-signed issuer), a CA `ClusterIssuer` backed by that Secret, and — when `wildcard.enabled: true` — an additional wildcard `Certificate` issued by the CA. Requires `selfsigned/` (or another compatible ClusterIssuer set via `ca.issuerRef`).

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cert-manager-cluster-ca
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: infra/cert-manager/cluster-ca
    helm:
      values: |
        ca:
          name: cluster-ca
          namespace: cert-manager
          secretName: cluster-ca-secret
          issuerRef:
            name: selfsigned
            kind: ClusterIssuer
        wildcard:
          enabled: true
          name: wildcard-tls
          namespace: default
          secretName: wildcard-tls
          commonName: "*.my-cluster.example.com"
          dnsNames:
            - "*.my-cluster.example.com"
  destination:
    server: https://<cluster-api>:6443
    namespace: cert-manager
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ServerSideApply=true]
```

### cluster-ca values reference

| Key | Default | Purpose |
|---|---|---|
| `ca.name` | `cluster-ca` | Name of both the CA Certificate and the CA ClusterIssuer |
| `ca.namespace` | `cert-manager` | Namespace for the CA Certificate (ClusterIssuer is cluster-scoped) |
| `ca.secretName` | `cluster-ca-secret` | Secret that stores the CA key/cert; referenced by the CA ClusterIssuer |
| `ca.issuerRef.name` / `kind` | `selfsigned` / `ClusterIssuer` | Issuer that signs the CA Certificate |
| `wildcard.enabled` | `false` | Render an additional wildcard Certificate issued by the CA |
| `wildcard.name` / `namespace` / `secretName` | `wildcard-tls` / `default` / `wildcard-tls` | Wildcard Certificate identity |
| `wildcard.commonName` / `dnsNames` | `*.example.com` placeholder | **Override per cluster** |
| `wildcard.duration` / `renewBefore` | `2160h` / `360h` | Certificate lifetime and renewal window |

## Fleet — one `ApplicationSet` per piece

Each entry is a self-contained chart, so fleet mode is one `ApplicationSet` per piece. Install cert-manager everywhere a cluster has `install/cert-manager: "true"`; layer `selfsigned` and `cluster-ca` with their own labels.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: cert-manager
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - clusters:
        selector:
          matchLabels:
            install/cert-manager: "true"
  template:
    metadata:
      name: 'cert-manager-{{ .name }}'
    spec:
      project: '{{ .name }}'
      source:
        repoURL: https://github.com/stuttgart-things/argocd.git
        targetRevision: main
        path: infra/cert-manager/install
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

Analogous `ApplicationSet`s target `path: infra/cert-manager/selfsigned` with selector `install/cert-manager-selfsigned: "true"` and `path: infra/cert-manager/cluster-ca` with `install/cert-manager-cluster-ca: "true"` — each takes its own per-cluster values (wildcard hostname, CA name, …) and doesn't know or care about the others.

## Migrating from the previous kustomize layout

If you were consuming the old three-entry layout (`infra/cert-manager/{chart,selfsigned,cluster-ca}` with raw Applications patched via JSON): replace each patched Application with one `Application` pointing at the corresponding chart.

| Old | New |
|---|---|
| `infra/cert-manager/chart` (kustomize dir, Application inlined) | `infra/cert-manager/install` (Helm chart; consumer Application passes `helm.values`) |
| `infra/cert-manager/selfsigned` (raw ClusterIssuer) | `infra/cert-manager/selfsigned` (Helm chart; issuer `name` is a value) |
| `infra/cert-manager/cluster-ca` (raw CA chain with baked-in wildcard) | `infra/cert-manager/cluster-ca` (Helm chart; CA `name`/`namespace`/`secretName`/`issuerRef` and the wildcard block are values, wildcard off by default) |

The wildcard Certificate is now **opt-in** (`wildcard.enabled: true`) — the old layout shipped it unconditionally with a placeholder `*.example.com`, which could land an unwanted cert in `default/` on clusters that didn't patch it. New default: off.

## Related

- Flux equivalent: [`stuttgart-things/flux` — `infra/cert-manager`](https://github.com/stuttgart-things/flux/tree/main/infra/cert-manager) — Flux splits this slightly differently (`components/install`, `components/selfsigned`, `components/extra-certificate`); this catalog mirrors the existing ArgoCD split (install / selfsigned / cluster-ca) but gives each piece the same modular, values-driven shape.
