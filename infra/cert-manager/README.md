# infra/cert-manager

Catalog entries for [cert-manager](https://cert-manager.io/) and its common bootstrap resources. Four independently deployable pieces — consumers create one ArgoCD `Application` per piece they need.

## Layout

```
infra/cert-manager/
├── install/       app-of-apps — renders Application "cert-manager" → jetstack/cert-manager
├── selfsigned/    plain Helm chart — renders the `selfsigned` ClusterIssuer
├── cluster-ca/    plain Helm chart — renders CA Certificate + CA ClusterIssuer + optional wildcard Certificate(s)
├── vault-pki/     plain Helm chart — renders a Vault PKI ClusterIssuer (token or kubernetes auth)
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
| Vault-backed issuer, tokenless (preferred — Vault-side Kubernetes auth mount required) | `install`, `vault-pki` with `vault.auth.method: kubernetes` |
| Vault-backed issuer (token Secret pre-provisioned) | `install`, `vault-pki` |

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

Plain Helm chart that renders a CA chain: a CA `Certificate` (signed by the self-signed issuer), a CA `ClusterIssuer` backed by that Secret, and — when `wildcard.enabled: true` (and optionally `wildcardSecondary.enabled: true`) — one or two wildcard `Certificate`s issued by the CA. Requires `selfsigned/` (or another compatible ClusterIssuer set via `ca.issuerRef`).

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
| `wildcardSecondary.enabled` | `false` | Render a second wildcard Certificate (same shape as `wildcard`) — useful when fronting more than one Gateway hostname |
| `wildcardSecondary.name` / `namespace` / `secretName` | `wildcard-secondary-tls` / `default` / `wildcard-secondary-tls` | Secondary wildcard identity |
| `wildcardSecondary.commonName` / `dnsNames` | `*.secondary.example.com` placeholder | **Override per cluster** |
| `wildcardSecondary.duration` / `renewBefore` | `2160h` / `360h` | Secondary certificate lifetime and renewal window |

## vault-pki/

Plain Helm chart that renders a single `vault`-type `ClusterIssuer`, with either of two authentication methods selected by `vault.auth.method`.

**`token`** (the default) uses a pre-provisioned `Secret` (default name `vault-pki-token`) in the cert-manager namespace carrying the Vault token under the configured key — provisioned out-of-band (e.g. by Terraform, like [`vault-cert-issuer`](https://github.com/stuttgart-things/stuttgart-things/tree/main/clusters/labul/vsphere/platform-sthings/vault-cert-issuer)). Nothing renews that token and Vault caps its TTL, so issuance starts failing once it expires — while the ClusterIssuer keeps reporting `Ready=True`.

**`kubernetes`** removes the credential instead of lengthening it: cert-manager mints a short-lived ServiceAccount token per signing request through the TokenRequest API, and nothing long-lived is stored in the cluster. **Prefer it.** It needs a Kubernetes auth mount and role on the Vault side, plus the ServiceAccount it binds — all created Vault-side by [`vault-base-setup`](https://github.com/stuttgart-things/vault-base-setup)'s `k8s_auths`, not by this chart. The mount path, role and ServiceAccount name must match that configuration exactly; the module derives the mount from `<cluster_name>-<name>`.

The chart does ship the `cert-manager-tokenrequest` Role/RoleBinding the method needs (`rbac.create`, kubernetes auth only). The cert-manager chart rendered that Role up to v1.18.x and stopped in v1.21.x with no values flag to restore it, and its absence is silent — the ClusterIssuer reports `Ready=True` because cert-manager verifies the Vault *login* and never the ability to sign, so certificates simply never appear and the only signal is the cert-manager log. Set `rbac.create: false` where something else already owns that Role, such as a cluster whose issuer comes from [stuttgart-things/flux](https://github.com/stuttgart-things/flux) (component `infra/cert-manager/components/vault-issuer`), which ships the same pair.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cert-manager-vault-pki
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: infra/cert-manager/vault-pki
    helm:
      values: |
        name: vault-pki
        vault:
          server: https://vault.example.com
          path: pki/sign/my-role
          auth:
            tokenSecretRef:
              name: vault-pki-token
              key: token
  destination:
    server: https://<cluster-api>:6443
    namespace: cert-manager
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ServerSideApply=true]
```

### vault-pki values reference

| Key | Default | Purpose |
|---|---|---|
| `name` | `vault-pki` | ClusterIssuer name — referenced by `Certificate.spec.issuerRef.name` |
| `vault.server` | placeholder | Vault server URL (`https://...`) |
| `vault.path` | placeholder | Vault PKI sign path (`pki/sign/<role>`) |
| `vault.auth.method` | `token` | `token` or `kubernetes`. Empty counts as `token`, so an ApplicationSet may pass a missing cluster annotation through unconditionally |
| `vault.auth.tokenSecretRef.name` | `vault-pki-token` | **token auth** — Secret in the cert-manager namespace holding the Vault token |
| `vault.auth.tokenSecretRef.key` | `token` | **token auth** — key inside the Secret holding the raw token |
| `vault.auth.kubernetes.mountPath` | `""` | **kubernetes auth** — Vault auth mount *including* the `/v1/auth/` prefix, e.g. `/v1/auth/my-cluster-certmanager` |
| `vault.auth.kubernetes.role` | `""` | **kubernetes auth** — Vault role name on that mount |
| `vault.auth.kubernetes.serviceAccountRef.name` | role name | **kubernetes auth** — ServiceAccount cert-manager presents when logging in. Must exist and be in the Vault role's `bound_service_account_names` |
| `vault.caBundleSecretRef.name` / `.key` | unset | Optional Secret carrying the Vault server's CA bundle, for verifying its TLS. Omit for an in-cluster `http://` address, where there is nothing to verify |
| `rbac.create` | `true` | Ship the `cert-manager-tokenrequest` Role/RoleBinding (kubernetes auth only) |
| `rbac.tokenRequesterServiceAccount` | `cert-manager` | ServiceAccount that *calls* TokenRequest — the controller, not the one whose token is minted |

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
