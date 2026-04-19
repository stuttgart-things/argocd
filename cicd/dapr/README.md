# cicd/dapr

Catalog entry for the [Dapr](https://dapr.io) control-plane — installs the upstream Helm chart from `https://dapr.github.io/helm-charts/` so the runtime (operator, placement, scheduler, sentry, sidecar injector) is available to inject sidecars into workloads.

Placed in `cicd/` because Dapr is primarily used here as a CI/CD-adjacent workflow engine (Backstage template workers, Argo Rollouts glue, etc.), not as a user-facing app.

## Files

| File | Purpose |
|---|---|
| `application.yaml` | Child `Application`: Dapr Helm chart pin (`1.17.4`) + `dapr-system` destination placeholder + sync policy. |
| `kustomization.yaml` | Kustomize base that includes `application.yaml`. |

## Opinionated defaults

Mirrors the Flux module (`flux/apps/dapr/components/control-plane`):

| Value | Setting |
|---|---|
| `global.ha.enabled` | `false` — single-replica control-plane; override to `true` for production (3 replicas per component) |
| `global.logAsJson` | `true` — structured logs |
| `dapr_operator.logLevel` / `dapr_placement.logLevel` / `dapr_sidecar_injector.logLevel` / `dapr_scheduler.logLevel` | `info` |

## Consumer usage

Minimal — point a root `Application` at this directory:

```yaml
spec:
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: HEAD
    path: cicd/dapr
```

### Overriding destination cluster

Consumer cluster repo creates an overlay dir (e.g. `clusters/<cluster>/argocd/dapr/`) with a `kustomization.yaml` pulling this path as a remote base and patching the child Application's `project` + `destination.server`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - https://github.com/stuttgart-things/argocd.git/cicd/dapr?ref=main
patches:
  - target: { kind: Application, name: dapr }
    patch: |-
      - op: replace
        path: /spec/project
        value: <cluster-project>
      - op: replace
        path: /spec/destination/server
        value: https://<cluster-api>:<port>
```

### Enabling HA

```yaml
patches:
  - target: { kind: Application, name: dapr }
    patch: |-
      - op: replace
        path: /spec/source/helm/valuesObject/global/ha/enabled
        value: true
```

## Per-app Dapr Components

Per-app Dapr `Component` resources (state stores, pub/sub, bindings, etc.) are **not** installed by this catalog entry — they live with the app that uses them so each app can bring its own Redis / Kafka / etc. configuration. Add them via a separate `Application` targeting the app's namespace.

## Not ported from the Flux module

The Flux module also ships a `template-execution` component for the `dapr-backstage-template-execution` workflow worker. It's not ported here because it consumes an OCI **kustomize artifact** (`oci://ghcr.io/stuttgart-things/dapr-backstage-template-execution-kustomize`), which Argo CD's repo-server cannot render natively without a custom ConfigManagementPlugin sidecar. Clusters that need it should either:

1. Publish the rendered manifests to a Git path and point an Application at it, or
2. Install a CMP sidecar (e.g. `argocd-kustomize-cmp-oci`) and add a plugin-based Application to this catalog.

## Related

- Flux equivalent: [`stuttgart-things/flux` — `apps/dapr/components/control-plane`](https://github.com/stuttgart-things/flux/tree/main/apps/dapr/components/control-plane)
- Dapr docs: <https://docs.dapr.io/>
