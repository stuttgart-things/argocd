# apps/machinery

Catalog entry for [Machinery](https://github.com/stuttgart-things/machinery) — gRPC + HTMX service for watching Crossplane-managed Kubernetes custom resources. Packaged as an **app-of-apps Helm chart** over the `machinery-kustomize` OCI base: consumers create one ArgoCD `Application` (or `ApplicationSet`) pointing at `apps/machinery/install`, pass overrides via `helm.values`, and the chart renders the child `Application`s that install Machinery and optionally its HTTPRoute.

Port of [`stuttgart-things/flux` — `apps/machinery`](https://github.com/stuttgart-things/flux/tree/main/apps/machinery). The flux version's `postBuild.substitute` variables map to first-class values here.

## Layout

```
apps/machinery/
├── install/                        app-of-apps Helm chart (what consumers point at)
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── values.schema.json
│   └── templates/
│       ├── chart.yaml              renders Application "machinery"           (sync-wave 0, OCI kustomize + patches)
│       └── httproute.yaml          renders Application "machinery-httproute" (sync-wave 10, gated by httpRoute.enabled)
└── httproute/                      Gateway API HTTPRoute sub-chart
    ├── Chart.yaml
    ├── values.yaml
    ├── values.schema.json
    └── templates/httproutes.yaml
```

## What gets deployed

### `machinery` Application (always)
Argo CD Kustomize source against `oci://ghcr.io/stuttgart-things/machinery-kustomize` at `.Values.kustomize.targetRevision`. The install chart emits Kustomize `patches` equivalent to the flux version's `spec.patches`:

- **Deployment image override** — `ghcr.io/stuttgart-things/machinery:<tag>` from `.Values.image`
- **Deployment env + volumes** — `MACHINERY_CONFIG=/etc/machinery/config.json` + `machinery-config` ConfigMap mounted at `/etc/machinery` (optional)
- **Deployment ports** — `grpc:50051` + `http:8080`
- **Service ports** — `grpc:50051` + `http:8080`
- **HTTPRoute delete** — when `httpRoute.enabled: true`, the KCL-generated HTTPRoute in the base is pruned (we ship our own via the sub-Application below)

### `machinery-httproute` Application (opt-in, `httpRoute.enabled: true`)
Renders one Gateway API `HTTPRoute` pointing at `machinery:8080`, parented onto `.Values.httpRoute.gateway`.

## Consumer usage

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: machinery
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: apps/machinery/install
    helm:
      values: |
        project: my-cluster
        destination:
          server: https://<cluster-api>:6443
          namespace: machinery
        kustomize:
          repoURL: ghcr.io/stuttgart-things/machinery-kustomize
          targetRevision: 1.3.0
        image:
          repository: ghcr.io/stuttgart-things/machinery
          tag: 1.3.0
        httpRoute:
          enabled: true
          hostname: machinery.my-cluster.example.com
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

## Values reference

| Key | Default | Purpose |
|---|---|---|
| `project` | `default` | AppProject for all rendered Applications |
| `destination.server` | `https://kubernetes.default.svc` | Target cluster API |
| `destination.namespace` | `machinery` | Namespace for Machinery |
| `kustomize.repoURL` | `ghcr.io/stuttgart-things/machinery-kustomize` | OCI kustomize base |
| `kustomize.targetRevision` | `1.3.0` | Kustomize base tag (flux `MACHINERY_VERSION`) |
| `image.repository` / `tag` | `ghcr.io/stuttgart-things/machinery` / `1.3.0` | Container image override |
| `httpRoute.enabled` | `true` | Render the HTTPRoute sub-Application + delete the base's KCL HTTPRoute |
| `httpRoute.hostname` | `machinery.example.com` | FQDN on the HTTPRoute |
| `httpRoute.gateway.name` / `namespace` | `cilium-gateway` / `default` | Gateway reference |
| `catalog.repoURL` / `targetRevision` | this repo / `HEAD` | Where the httpRoute Application fetches manifests from |
| `syncPolicy` | automated + retry | Applied to all rendered Applications |

## Endpoints

| Endpoint | Description |
|---|---|
| `https://<hostname>/` | HTMX dashboard |
| `<hostname>:50051` | gRPC API |

## Note: PipelineRuns re-appearing daily

Machinery only **watches** Crossplane XRs (`AnsibleRun`, `VMProvision`, …) and surfaces their status — it does not create PipelineRuns itself. If runs in the CI namespace appear to re-trigger every morning, the cause is the cluster-wide Tekton operator pruner deleting them, followed by Crossplane recreating them. See `cicd/tekton` README section *Caveat: Pruner + Crossplane-managed PipelineRuns*.

## Related

- Flux equivalent: [`stuttgart-things/flux` — `apps/machinery`](https://github.com/stuttgart-things/flux/tree/main/apps/machinery)
- Machinery repo: <https://github.com/stuttgart-things/machinery>
