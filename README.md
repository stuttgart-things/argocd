# argocd

ArgoCD app catalog for `stuttgart-things` — reusable `Application` / App-of-Apps definitions consumed by cluster repos.

Complements [`stuttgart-things/flux`](https://github.com/stuttgart-things/flux): `flux` hosts Flux CD `HelmRelease` / `Kustomization` definitions, this repo hosts their ArgoCD equivalents.

## Pattern

```
argocd repo (this)                 cluster consumer repo (e.g. stuttgart-things)
-----------------------------      -----------------------------------------
infra/<app>/                       clusters/<site>/<cluster>/argocd/
  kustomization.yaml                 <app>.yaml            # root Application
  application.yaml        <────      <app>/                # optional overlay
  README.md                            kustomization.yaml  #   patches base
                                       values.yaml         #   cluster values
```

- **This repo** defines WHAT each app is: upstream chart / source, default values, sync policy, in-cluster destination placeholder.
- **Consumer cluster repo** defines WHERE and HOW it runs: target cluster, cluster-specific Helm values, per-cluster overrides. The consumer's root `Application` (or `ApplicationSet`) points at a path in this repo and kustomize-overlays it.

## Layout

```
infra/      # Infrastructure components (cert-manager, cilium, openebs, …)
apps/       # Application releases
cicd/       # CI/CD tooling
```

## Consuming an entry from a cluster repo

A consumer cluster repo typically has a root `Application` per app:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: openebs-root
  namespace: argocd
spec:
  project: <cluster-project>
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: HEAD
    path: infra/openebs
  destination:
    server: https://kubernetes.default.svc   # argocd control-plane cluster
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
```

The root Application renders manifests from `infra/openebs` — which includes a child `Application` targeting the real workload cluster. To inject cluster-specific values, use a consumer-side kustomize overlay that patches the child Application.

See each `infra/<app>/README.md` for per-app details.

## Branching

`main` is the default and only branch. Tag releases with `v<semver>` when the catalog shape stabilises.
