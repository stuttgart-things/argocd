# apps/homerun2 — Kargo promotion reference

This doc shows the canonical [Kargo](https://kargo.akuity.io/) pipeline for promoting `apps/homerun2` freight through `dev → staging → prod` stages. Use it as a starting point — the same shape applies to any other app-of-apps chart in this catalog (scope the `Warehouse` subscriptions and `yaml-update` paths to the relevant component versions).

The chart side is already Kargo-friendly: every version knob is a first-class value, schema-validated, and embedded in the consumer-side `Application` under `helm.valuesObject` so Kargo's `yaml-update` can patch it directly.

## Repo topology

```
stuttgart-things/argocd                            (this catalog — Helm charts)
└── apps/homerun2/install/                         consumers point at this

stuttgart-things/<cluster-config>                  (consumer repo — cluster-specific Applications)
├── clusters/dev/homerun2.yaml                     Application, helm.valuesObject patched by Kargo
├── clusters/staging/homerun2.yaml                 same shape, different version values
└── clusters/prod/homerun2.yaml                    same shape, different version values
```

Kargo Stages live alongside the per-env Application manifests in the cluster-config repo. The promotion runs `yaml-update` against `clusters/<env>/homerun2.yaml`, commits, pushes, and then `argocd-update` waits for the matching Argo CD Application to reconcile to `Healthy`.

## Per-env consumer Application

Each environment is one Application file. Kargo patches the version keys; everything else (project, destination, hostnames, gateway, sync policy) stays the same across stages.

```yaml
# clusters/dev/homerun2.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: homerun2-dev
  namespace: argocd
spec:
  project: dev
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main                  # pin to a SHA in prod, see Notes
    path: apps/homerun2/install
    helm:
      valuesObject:                       # valuesObject (not values: |) — Kargo patches structured YAML cleanly
        project: dev
        destination:
          server: https://dev-cluster.example.com
          namespace: homerun2
        redisPassword: <path:vault/data/dev/homerun2#redis>
        authToken:     <path:vault/data/dev/homerun2#auth>
        omniPitcher:
          enabled: true
          version: v1.6.2                 # ← Kargo patches this
          hostname: omni.dev.example.com
        coreCatcher:
          enabled: true
          version: v0.8.0                 # ← Kargo patches this
          kustomizeVersion: v0.7.1        # ← Kargo patches this (paired with version)
          hostname: core.dev.example.com
        scout:
          enabled: true
          version: v0.7.0                 # ← Kargo patches this
          hostname: scout.dev.example.com
        redisStack:
          enabled: true
          chartVersion: 17.1.4            # ← Kargo patches this
        httpRoute:
          enabled: true
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

Production tip: pin `spec.source.targetRevision` to a SHA (not `main`). Kargo's freight model expects the chart side to be deterministic; promoting a value bump while `main` shifts under you defeats the gate.

## Warehouse

One `Warehouse` subscribes to every artifact stream that contributes to homerun2 freight. The flux baseline ships 4 components in the `base` profile (omni-pitcher + core-catcher + scout + redis-stack); `Warehouse` mirrors that — add subscriptions for whichever components the consumer enables.

```yaml
apiVersion: kargo.akuity.io/v1alpha1
kind: Warehouse
metadata:
  name: homerun2
  namespace: kargo-homerun2
spec:
  subscriptions:
    # Component images — discovered via container registry tag scans.
    - image:
        repoURL: ghcr.io/stuttgart-things/homerun2-omni-pitcher
        semverConstraint: ">=1.0.0"
        discoveryLimit: 5
    - image:
        repoURL: ghcr.io/stuttgart-things/homerun2-core-catcher
        semverConstraint: ">=0.5.0"
        discoveryLimit: 5
    - image:
        repoURL: ghcr.io/stuttgart-things/homerun2-scout
        semverConstraint: ">=0.5.0"
        discoveryLimit: 5

    # OCI kustomize bases — discovered via OCI artifact tag scans.
    # version + kustomizeVersion ALWAYS bump together for a given component;
    # use a single subscription if your image+kustomize tags share a value,
    # otherwise add a paired subscription for each kustomize artifact.
    - chart:
        repoURL: ghcr.io/stuttgart-things/homerun2-core-catcher-kustomize
        semverConstraint: ">=0.5.0"

    # Upstream Redis OCI Helm chart.
    - chart:
        repoURL: ghcr.io/stuttgart-things/charts/redis
        semverConstraint: ">=17.0.0"
```

> **Note**: `Warehouse` is the discovery side. Whether a stage promotes that freight is decided by the `Stage`'s subscription (and any `verify` / `requestedFreight` filters). A discovery isn't a promotion.

## Stages

Three Stages, chained.

### dev — auto-promote latest discovered freight

```yaml
apiVersion: kargo.akuity.io/v1alpha1
kind: Stage
metadata:
  name: dev
  namespace: kargo-homerun2
spec:
  requestedFreight:
    - origin: { kind: Warehouse, name: homerun2 }
      sources:
        direct: true                      # pulls the newest freight directly from the Warehouse
  promotionTemplate:
    spec:
      steps:
        - uses: git-clone
          config:
            repoURL: https://github.com/stuttgart-things/cluster-config.git
            checkout:
              - branch: main
                path: ./repo
        - uses: yaml-update
          config:
            path: ./repo/clusters/dev/homerun2.yaml
            updates:
              - key: spec.source.helm.valuesObject.omniPitcher.version
                value: ${{ imageFrom("ghcr.io/stuttgart-things/homerun2-omni-pitcher").Tag }}
              - key: spec.source.helm.valuesObject.coreCatcher.version
                value: ${{ imageFrom("ghcr.io/stuttgart-things/homerun2-core-catcher").Tag }}
              - key: spec.source.helm.valuesObject.coreCatcher.kustomizeVersion
                value: ${{ chartFrom("ghcr.io/stuttgart-things/homerun2-core-catcher-kustomize").Version }}
              - key: spec.source.helm.valuesObject.scout.version
                value: ${{ imageFrom("ghcr.io/stuttgart-things/homerun2-scout").Tag }}
              - key: spec.source.helm.valuesObject.redisStack.chartVersion
                value: ${{ chartFrom("ghcr.io/stuttgart-things/charts/redis").Version }}
        - uses: git-commit
          config:
            path: ./repo
            messageFromSteps: [yaml-update]
        - uses: git-push
          config:
            path: ./repo
        - uses: argocd-update
          config:
            apps:
              - name: homerun2-dev
                sources:
                  - repoURL: https://github.com/stuttgart-things/argocd.git
                    desiredCommitFromStep: git-clone
```

### staging — gated on dev being Healthy

```yaml
apiVersion: kargo.akuity.io/v1alpha1
kind: Stage
metadata:
  name: staging
  namespace: kargo-homerun2
spec:
  requestedFreight:
    - origin: { kind: Warehouse, name: homerun2 }
      sources:
        stages: [dev]                     # promotes only freight already validated on dev
  promotionTemplate:
    spec:
      steps:
        # …same yaml-update steps, with paths under clusters/staging/homerun2.yaml
        # and argocd-update.apps[0].name: homerun2-staging
```

### prod — manual gate

```yaml
apiVersion: kargo.akuity.io/v1alpha1
kind: Stage
metadata:
  name: prod
  namespace: kargo-homerun2
spec:
  requestedFreight:
    - origin: { kind: Warehouse, name: homerun2 }
      sources:
        stages: [staging]
  # No promotionTemplate auto-trigger — promote via the UI / `kargo promote` CLI.
  promotionTemplate:
    spec:
      steps:
        # …same yaml-update steps, paths under clusters/prod/homerun2.yaml,
        # argocd-update.apps[0].name: homerun2-prod
```

## Health-check gotcha — sub-Applications

Kargo's `argocd-update` waits for the **parent** Application's `Healthy: true`. The parent (`homerun2-dev`) renders sub-Applications (`homerun2-dev-redis-stack`, `homerun2-dev-omni-pitcher`, `homerun2-dev-httproute`, …) — each reconciles independently. The parent can flip to `Healthy` before its sub-Apps finish.

If a freight bump touches a sub-App (e.g. a hostname change → HTTPRoute regenerates), add the sub-App's name to the `argocd-update` step's `apps` list:

```yaml
- uses: argocd-update
  config:
    apps:
      - name: homerun2-dev                   # parent
      - name: homerun2-dev-redis-stack       # sub-App, only listed if its values bumped
      - name: homerun2-dev-omni-pitcher
      - name: homerun2-dev-httproute
```

(Sub-App names are `<applicationName>-<component>`; default `applicationName` is `homerun2-<sha8(server)>`. Set `applicationName: homerun2-dev` in the helm.valuesObject for predictable names.)

## Multi-cluster promotion (ApplicationSet)

If `dev`, `staging`, `prod` are *clusters*, not just env labels, prefer one ApplicationSet generating one Application per cluster from the same Warehouse:

```yaml
# clusters/homerun2-appset.yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: homerun2
  namespace: argocd
spec:
  generators:
    - clusters:
        selector:
          matchLabels:
            homerun2: enabled
  template:
    metadata:
      name: '{{name}}-homerun2'
    spec:
      project: '{{name}}'
      source:
        repoURL: https://github.com/stuttgart-things/argocd.git
        targetRevision: main
        path: apps/homerun2/install
        helm:
          valuesObject:
            applicationName: '{{name}}-homerun2'
            project: '{{name}}'
            destination:
              server: '{{server}}'
              namespace: homerun2
            omniPitcher:
              enabled: true
              version: v1.6.2               # ← still Kargo-patchable in this single source
              hostname: 'omni.{{metadata.labels.domain}}'
            # … etc.
      destination:
        server: https://kubernetes.default.svc
        namespace: argocd
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

Kargo then patches *one* file (`clusters/homerun2-appset.yaml`) per Stage — every cluster picks it up. Stages still gate (different ApplicationSet manifest per Stage in different paths, or a single file with per-stage labels on the cluster generator).

## Notes

- **Pin `targetRevision` to a SHA in prod**, not `main`. Kargo treats the chart as part of the freight; floating refs defeat the gate.
- **`helm.valuesObject` (object) > `helm.values` (string)** for Kargo. `yaml-update` patches structured YAML; the string form requires the consumer to keep the inner YAML formatting stable.
- **`coreCatcher.version` and `coreCatcher.kustomizeVersion` MUST bump together** — they reference the same release. Kargo's promotion template must update both keys in one `yaml-update` call (above example does this).
- **Secret values** (`redisPassword`, `authToken`) are NOT promoted by Kargo — they're resolved at sync time by ArgoCD Vault Plugin / SOPS / etc. Kargo only moves *versions*.
- **`redisStack.chartVersion`** comes from the upstream `ghcr.io/stuttgart-things/charts/redis` chart, not from a homerun2-* artifact. Subscribe to it in the same Warehouse if you want it promoted alongside the components; otherwise pin and bump manually.

## See also

- [Kargo docs](https://kargo.akuity.io/quickstart/) — quickstart + promotion-step reference
- [`apps/homerun2/README.md`](./README.md) — chart layout + values reference
- Catalog-side `kargo` install chart: [`cicd/kargo`](../../cicd/kargo/) — install Kargo itself if you don't have it yet
