# cicd/tekton

Catalog entry for [Tekton](https://tekton.dev/) installed via the upstream Tekton Operator manifests. Split into four independent sub-entries so consumers can pick which components to install.

## Layout

```
cicd/tekton/
├── operator/                  # Tekton Operator (vendored upstream manifests, sync-wave -10)
├── config/                    # TektonConfig CR (sync-wave 0)
├── ci-namespace/              # tekton-ci namespace with prune.skip (sync-wave 0, opt-in)
└── dashboard-httproute/       # Gateway API HTTPRoute for the dashboard (sync-wave 10, opt-in)
```

Each subdir is a self-contained kustomize base producing one `Application`. Consumers reference one or more as remote kustomize bases in their cluster overlay.

## Components

### operator/
Vendored Tekton Operator manifests. The child Application uses a `directory:` source pointing at [`cicd/tekton/components/operator`](https://github.com/stuttgart-things/flux/tree/main/cicd/tekton/components/operator) in the Flux repo — the manifests are ~1500 lines of upstream YAML, not worth duplicating across repos.

Installs into `tekton-operator` namespace, `CreateNamespace=true`, `ServerSideApply=true`, `sync-wave: -10` (so CRDs register before dependent CRs).

### config/
`TektonConfig` CR. Installs into `tekton-operator` namespace, `sync-wave: 0`. Retries with backoff until the operator registers the `operator.tekton.dev/v1alpha1` CRD.

Defaults:
- `targetNamespace: tekton-pipelines`
- `profile: all`
- `pipeline.enable-api-fields: beta`
- Pruner enabled (daily at 08:00, keeps 24h)

### ci-namespace/
Creates the `tekton-ci` namespace with `operator.tekton.dev/prune.skip: "true"`. Use if you want per-project PipelineRuns exempt from the global pruner (see "Pruner caveat" below). Opt-in.

### dashboard-httproute/
Gateway API `HTTPRoute` for the Tekton dashboard. Requires Gateway API CRDs and a parent Gateway (e.g. from `infra/cilium`). `sync-wave: 10` so it lands after the operator has stood up `tekton-dashboard`.

Opt-in — only include if your cluster has a Gateway. Default hostname is `tekton.example.com`; consumers should patch.

## Consumer usage

Single consumer cluster picking what it wants — in `clusters/<cluster>/argocd/cicd/tekton/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - https://github.com/stuttgart-things/argocd.git/cicd/tekton/operator?ref=main
  - https://github.com/stuttgart-things/argocd.git/cicd/tekton/config?ref=main
  # - https://github.com/stuttgart-things/argocd.git/cicd/tekton/ci-namespace?ref=main
  # - https://github.com/stuttgart-things/argocd.git/cicd/tekton/dashboard-httproute?ref=main
patches:
  - target: { kind: Application, name: tekton-operator }
    patch: |-
      - op: replace
        path: /spec/project
        value: <cluster-project>
      - op: replace
        path: /spec/destination/server
        value: https://<cluster-api>:<port>
  - target: { kind: Application, name: tekton-config }
    patch: |-
      - op: replace
        path: /spec/project
        value: <cluster-project>
      - op: replace
        path: /spec/destination/server
        value: https://<cluster-api>:<port>
```

Each included child Application needs its own destination/project patch (the bases ship in-cluster placeholders).

## Pruner caveat

The operator's pruner is a single cluster-wide CronJob. If PipelineRuns are managed externally (e.g. by Crossplane's `provider-kubernetes`), deletions trigger re-creates in a loop. The `ci-namespace` component is the mitigation — namespaces annotated with `operator.tekton.dev/prune.skip: "true"` are bypassed while global pruning continues elsewhere.

## Related

- Flux equivalent: [`stuttgart-things/flux` — `cicd/tekton`](https://github.com/stuttgart-things/flux/tree/main/cicd/tekton)
- The `operator/` sub-entry still pulls vendored manifests from the Flux repo via `directory:` source.
