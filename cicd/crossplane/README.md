# cicd/crossplane

Catalog entries for [Crossplane](https://crossplane.io/) plus the stuttgart-things opinionated stack of composition Functions, Providers, ProviderConfigs, and Configurations. Five independently deployable pieces — consumers create one ArgoCD `Application` per piece they need, each pointing at a Helm chart in this directory.

## Layout

```
cicd/crossplane/
├── install/           app-of-apps — renders Application "crossplane" (sync-wave -10)
├── providers/         plain Helm chart — renders Crossplane Provider resources
├── provider-configs/  plain Helm chart — renders Crossplane ProviderConfig resources
├── functions/         plain Helm chart — renders Crossplane Function resources
├── configs/           plain Helm chart — renders Crossplane Configuration resources
└── README.md
```

Matrix of typical consumer shapes:

| Want | Applications to create |
|---|---|
| Crossplane only | `install` |
| Crossplane + Providers | `install`, `providers` |
| Crossplane + Providers + ProviderConfigs | `install`, `providers`, `provider-configs` |
| Crossplane + Providers + ProviderConfigs + Functions | `install`, `providers`, `provider-configs`, `functions` |
| Crossplane + Providers + ProviderConfigs + Functions + stuttgart-things Configurations | `install`, `providers`, `provider-configs`, `functions`, `configs` |

`install/` is app-of-apps (wraps the upstream Helm chart). `providers/`, `provider-configs/`, `functions/` and `configs/` are plain Helm charts — the consumer-owned `Application` IS the outer wrapper; there's no upstream Helm chart to re-wrap.

## install/

App-of-apps Helm chart packaging the upstream `crossplane/crossplane` Helm chart. Consumer `Application` points at `cicd/crossplane/install`; chart renders a child `Application` targeting `https://charts.crossplane.io/stable` with a computed `valuesObject`.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: crossplane
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: cicd/crossplane/install
    helm:
      values: |
        project: my-cluster
        destination:
          server: https://<cluster-api>:6443
          namespace: crossplane-system
        # providerPackages defaults to [] — install providers via the separate
        # `providers/` chart. Populate this list only for one-off setups that
        # don't use the providers chart.
        providerPackages: []
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

`sync-wave: -10` on the rendered Application so Crossplane CRDs (Provider, Function, Configuration, etc.) land before dependent CRs in the other sub-entries.

### install values reference

See `install/values.yaml` / `install/values.schema.json` for the full contract.

| Key | Default | Purpose |
|---|---|---|
| `project` | `default` | ArgoCD AppProject for the rendered Application |
| `destination.server` *or* `destination.name`, `destination.namespace` | `https://kubernetes.default.svc` / `crossplane-system` | Target workload cluster + namespace. Set exactly one of `server` (cluster API URL) or `name` (ArgoCD cluster-Secret `name`). Using `name` is convenient when registering vclusters by name |
| `chartVersion` | `2.2.1` | Upstream crossplane chart version |
| `args` | `[--debug, --enable-usages, --enable-operations]` | Crossplane runtime args. `--enable-operations` enables the alpha Operations / CronOperations / WatchOperations APIs |
| `providerPackages` | `[]` | Provider xpkgs to install via the upstream chart. Empty by default — install providers through `providers/` instead so they version independently of core. Set non-empty here only for one-off setups |
| `extraValues` | `{}` | Deep-merged on top of the computed upstream `valuesObject` |
| `syncPolicy` | automated + retry | Applied to the rendered child Application |

## providers/

Plain Helm chart rendering `pkg.crossplane.io/v1.Provider` resources from a list, plus optional sugar for the AWS family (Upbound ships one xpkg per AWS service). Consumer `Application` points at `cicd/crossplane/providers` directly — no app-of-apps wrapper.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: crossplane-providers
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: cicd/crossplane/providers
    # Optional — the chart ships with the helm + kubernetes + opentofu
    # baseline. Override `providers` and/or `awsFamily` to taste.
  destination:
    server: https://<cluster-api>:6443
    namespace: crossplane-system
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ServerSideApply=true]
```

### providers defaults

| Provider | apiVersion | Package | RBAC |
|---|---|---|---|
| `provider-helm` | `pkg.crossplane.io/v1` | `xpkg.upbound.io/crossplane-contrib/provider-helm:v1.2.0` | `cluster-admin` |
| `provider-kubernetes` | `pkg.crossplane.io/v1` | `xpkg.upbound.io/crossplane-contrib/provider-kubernetes:v1.2.1` | `cluster-admin` |
| `provider-opentofu` | `pkg.crossplane.io/v1` | `xpkg.upbound.io/upbound/provider-opentofu:v1.1.2` | `cluster-admin` |

Override the list — or add additional providers — via `helm.values`:

```yaml
helm:
  values: |
    providers:
      - name: provider-helm
        package: xpkg.upbound.io/crossplane-contrib/provider-helm:v1.2.0
        rbac:
          clusterRole: cluster-admin
      - name: provider-vsphere
        package: ghcr.io/acme/provider-vsphere:v0.1.0
        # No rbac block — vsphere talks to vSphere API, not local kube API,
        # so no in-cluster ServiceAccount permissions needed.
```

#### Stable ServiceAccount + RBAC

`InjectedIdentity` ProviderConfigs (the default in `provider-configs/`) make the provider Pod talk to the local Kubernetes API as its own ServiceAccount — which has no permissions by default, so every Composition fails with `forbidden`. To fix this **without** chasing the per-revision SA hash (`provider-kubernetes-f6665ef36536` etc.), an entry's optional `rbac` block tells the chart to additionally emit:

1. A `DeploymentRuntimeConfig.pkg.crossplane.io/v1beta1` pinning the provider Pod to a stable ServiceAccount name (= the Provider's name). The Provider gets a `runtimeConfigRef` pointing at it.
2. A `ClusterRoleBinding` granting `rbac.clusterRole` to that ServiceAccount in `crossplane-system`.

`cluster-admin` is the default for the baseline helm/kubernetes/opentofu providers because they need broad in-cluster authority to manage arbitrary resources. Tighten the ClusterRole per cluster if your security posture requires it (provider-kubernetes needs `get/list/watch/create/update/patch/delete` on the kinds it's expected to manage; provider-helm needs the same plus permissions to manage `Release`-owned objects, which in practice is broad).

Cloud providers using Secret-based credentials (AWS family, Azure, GCP) don't talk to the local kube API for their workload, so skip the `rbac` block for those entries.

### AWS family

Upbound publishes the AWS provider as ~50 service-scoped xpkgs (`provider-aws-ec2`, `provider-aws-s3`, `provider-aws-iam`, …). Listing each by hand is noisy, so the chart exposes a small `awsFamily` block:

```yaml
helm:
  values: |
    awsFamily:
      enabled: true
      version: v1.1.0       # applied to every service
      services: [ec2, s3, iam, eks]
```

Each entry in `services` becomes a `provider-aws-<service>` Provider CR pinned to `awsFamily.version`. Disabled by default. Combine freely with the flat `providers` list — `providers: []` + `awsFamily.enabled: true` is a valid AWS-only set.

`ProviderConfig` resources live in the sibling [`provider-configs/`](#provider-configs) chart. Credentials Secrets stay with the consumer (per-cluster, per-environment, typically SOPS-encrypted or sourced from ESO).

## provider-configs/

Plain Helm chart rendering `ProviderConfig` / `ClusterProviderConfig` resources for any installed Provider. Every Crossplane provider ships its own ProviderConfig CRD with its own apiGroup (`helm.m.crossplane.io/v1beta1`, `kubernetes.m.crossplane.io/v1alpha1`, `aws.upbound.io/v1beta1`, …), so this chart doesn't try to abstract them — it emits them opaquely from a values list.

provider-kubernetes v1.2+ and provider-helm v1.x ship **namespaced** `Object` / `Release` resources under `*.m.crossplane.io`. Those namespaced resources reference `kind: ClusterProviderConfig` in the same apiGroup, not `ProviderConfig`. The v2 namespaced XR default can only compose those namespaced resources, so the chart's defaults target the v2 (m.*) ClusterProviderConfig API surface — set `kind: ProviderConfig` explicitly in `configs` only if you also need the legacy v1 non-namespaced shape for the cluster-scoped Object (`kubernetes.crossplane.io/v1alpha2`).

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: crossplane-provider-configs
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: cicd/crossplane/provider-configs
    # Optional — the chart ships ProviderConfigs for provider-helm and
    # provider-kubernetes targeting the local cluster via InjectedIdentity
    # (zero secrets, works out of the box). Override `configs` to taste.
  destination:
    server: https://<cluster-api>:6443
    namespace: crossplane-system
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ServerSideApply=true]
```

### provider-configs defaults

| Name | apiVersion | Kind | Credentials |
|---|---|---|---|
| `in-cluster` | `helm.m.crossplane.io/v1beta1` | `ClusterProviderConfig` | `InjectedIdentity` (local cluster, the SA crossplane runs as) |
| `in-cluster` | `kubernetes.m.crossplane.io/v1alpha1` | `ClusterProviderConfig` | `InjectedIdentity` (local cluster) |
| `in-cluster` | `opentofu.m.upbound.io/v1beta1` | `ClusterProviderConfig` | Empty creds list + kubernetes backend (state in-cluster). Skeleton — add a provider block + creds to make it useful. |

Name `in-cluster` matches the `providerConfigRef: in-cluster` convention used in the stuttgart-things Compositions (e.g. [`crossplane/configurations/k8s/volume-claim`](https://github.com/stuttgart-things/crossplane/tree/main/configurations/k8s/volume-claim)).

`InjectedIdentity` works for helm + kubernetes when the Provider has cluster-admin-ish permissions on the cluster it runs in — sufficient for in-cluster dev work. provider-opentofu has no equivalent injected mode; the default ships a syntactically valid skeleton (k8s backend, empty creds, no provider block) and consumers must override with their actual terraform config. See [`provider-opentofu/examples/namespaced/clusterproviderconfig.yaml`](https://github.com/upbound/provider-opentofu/blob/main/examples/namespaced/clusterproviderconfig.yaml) for a GCP-credentialed shape. For other external targets or cloud APIs, override the list:

```yaml
helm:
  values: |
    configs:
      # Keep the local-helm default
      - name: in-cluster
        apiVersion: helm.m.crossplane.io/v1beta1
        kind: ClusterProviderConfig
        spec:
          credentials:
            source: InjectedIdentity

      # Add a kubernetes ClusterProviderConfig pointing at a remote cluster.
      # The secret `provider-kubernetes-target-kubeconfig` (created out-of-band
      # by ESO, SOPS, or whatever flow you use) must exist in crossplane-system.
      - name: target-cluster
        apiVersion: kubernetes.m.crossplane.io/v1alpha1
        kind: ClusterProviderConfig
        spec:
          credentials:
            source: Secret
            secretRef:
              namespace: crossplane-system
              name: provider-kubernetes-target-kubeconfig
              key: kubeconfig

      # AWS family — one ProviderConfig referenced by every provider-aws-*
      # (provider-aws-* is still on the v1 non-namespaced API surface as of v1.x)
      - name: default
        apiVersion: aws.upbound.io/v1beta1
        spec:
          credentials:
            source: Secret
            secretRef:
              namespace: crossplane-system
              name: aws-credentials
              key: creds
```

The chart doesn't manage credentials Secrets — those are per-cluster, per-environment, often secret-store-backed. Land them in `crossplane-system` via External Secrets Operator, SOPS, sealed-secrets, or whichever mechanism your cluster repo already uses; reference them by `secretRef` here.

## functions/

Plain Helm chart rendering `pkg.crossplane.io/v1[beta1].Function` resources from a list. Consumer `Application` points at `cicd/functions` directly — no app-of-apps wrapper, because there's no upstream Helm chart involved.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: crossplane-functions
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: cicd/crossplane/functions
    # Optional — the chart ships with the stuttgart-things default function
    # stack (auto-ready, go-templating, kcl, patch-and-transform). Override
    # only if you want a different set.
  destination:
    server: https://<cluster-api>:6443
    namespace: crossplane-system
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ServerSideApply=true]
```

### functions defaults

| Function | apiVersion | Package |
|---|---|---|
| `function-auto-ready` | `pkg.crossplane.io/v1beta1` | `xpkg.crossplane.io/crossplane-contrib/function-auto-ready:v0.6.4` |
| `function-go-templating` | `pkg.crossplane.io/v1beta1` | `xpkg.crossplane.io/crossplane-contrib/function-go-templating:v0.12.0` |
| `function-kcl` | `pkg.crossplane.io/v1` | `xpkg.upbound.io/crossplane-contrib/function-kcl:v0.12.1` |
| `function-patch-and-transform` | `pkg.crossplane.io/v1beta1` | `xpkg.upbound.io/crossplane-contrib/function-patch-and-transform:v0.10.5` |
| `function-environment-configs` | `pkg.crossplane.io/v1` | `xpkg.crossplane.io/crossplane-contrib/function-environment-configs:v0.7.0` |

Override the whole list via `helm.values`:

```yaml
helm:
  values: |
    functions:
      - name: function-kcl
        apiVersion: pkg.crossplane.io/v1
        package: xpkg.upbound.io/crossplane-contrib/function-kcl:v0.12.0
      - name: function-my-custom
        package: ghcr.io/acme/function-my-custom:v0.1.0
```

## configs/

Plain Helm chart rendering `pkg.crossplane.io/v1.Configuration` packages from a list.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: crossplane-configs
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: cicd/crossplane/configs
  destination:
    server: https://<cluster-api>:6443
    namespace: crossplane-system
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ServerSideApply=true]
```

### configs defaults

The chart ships the stuttgart-things Configuration stack published to `ghcr.io/stuttgart-things/crossplane/`:

| Configuration | Version |
|---|---|
| `cloud-config` | v0.5.1 |
| `volume-claim` | v0.1.1 |
| `storage-platform` | v0.6.0 |
| `ansible-run` | v12.0.0 |
| `pipeline-integration` | v0.1.2 |
| `harvester-vm` | v0.3.3 |

Configurations depend on the Functions they reference, so `functions/` should be present whenever `configs/` is. Override the list via `helm.values`:

```yaml
helm:
  values: |
    configurations:
      - name: cloud-config
        package: ghcr.io/stuttgart-things/crossplane/cloud-config:v0.5.1
      - name: my-custom
        package: ghcr.io/acme/my-custom-config:v0.1.0
```

## Fleet — one `ApplicationSet` per piece across many clusters

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: crossplane
  namespace: argocd
spec:
  generators:
    - clusters:
        selector:
          matchLabels:
            crossplane: enabled
  template:
    metadata:
      name: '{{name}}-crossplane'
    spec:
      project: '{{name}}'
      source:
        repoURL: https://github.com/stuttgart-things/argocd.git
        targetRevision: main
        path: cicd/crossplane/install
        helm:
          values: |
            project: {{name}}
            destination:
              server: {{server}}
              namespace: crossplane-system
      destination:
        server: https://kubernetes.default.svc
        namespace: argocd
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

Repeat the pattern for `providers/`, `provider-configs/`, `functions/` and `configs/` — their consumer Application targets the workload cluster directly (no inner app-of-apps wrapping), so `destination.server` is `{{server}}` rather than `https://kubernetes.default.svc`.

## Related

- Flux equivalent: [`stuttgart-things/flux` — `cicd/crossplane`](https://github.com/stuttgart-things/flux/tree/main/cicd/crossplane)
- Crossplane docs: <https://docs.crossplane.io/>
- stuttgart-things Configurations: <https://github.com/stuttgart-things?q=crossplane>
