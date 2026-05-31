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
- **Deployment env + volumes** — `MACHINERY_CONFIG=/etc/machinery/config.json` + `machinery-config-file` ConfigMap mounted at `/etc/machinery` (optional; distinct from the env-vars `machinery-config` ConfigMap shipped by the KCL base)
- **Deployment ports** — `grpc:50051` + `http:8080`
- **Service ports** — `grpc:50051` (`appProtocol: kubernetes.io/h2c`, so Cilium speaks h2c to the gRPC backend) + `http:8080`
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
          targetRevision: v1.13.2   # v-prefixed; keep in lockstep with image.tag
        image:
          repository: ghcr.io/stuttgart-things/machinery
          tag: v1.13.2
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
| `kustomize.targetRevision` | `v1.13.2` | Kustomize base tag (flux `MACHINERY_VERSION`); v-prefixed, lockstep with image.tag |
| `image.repository` / `tag` | `ghcr.io/stuttgart-things/machinery` / `v1.13.2` | Container image override (v-prefixed) |
| `httpRoute.enabled` | `true` | Render the HTTPRoute sub-Application + delete the base's KCL HTTPRoute |
| `httpRoute.hostname` | `machinery.example.com` | FQDN on the HTTPRoute |
| `httpRoute.gateway.name` / `namespace` | `cilium-gateway` / `default` | Gateway reference |
| `catalog.repoURL` / `targetRevision` | this repo / `HEAD` | Where the httpRoute Application fetches manifests from |
| `config.watch` | _(unset)_ | List of kind names from the `kinds` catalog to watch — see below |
| `config.content` | _(unset)_ | Escape-hatch inline JSON config (you own the matching `rbac.rules`) |
| `config.fromConfigMap` | _(unset)_ | Name of an externally-materialized config ConfigMap |
| `kinds` | _(catalog)_ | Library of watchable kinds; `config.watch` selects from it |
| `rbac.rules` | `[]` | Extra ClusterRole rules, unioned with those derived from `config.watch` |
| `syncPolicy` | automated + retry | Applied to all rendered Applications |

## Watch config (the smart path)

Machinery needs two things to surface a kind: a **watch entry** in its
`MACHINERY_CONFIG` JSON, and **list/watch RBAC** for the
ServiceAccount. Historically those were two hand-edited blocks
(`config.content` + `rbac.rules`) that had to be kept in sync — drift
meant either an empty dashboard filter or an error-loop.

`config.watch` collapses them into one list. Each name is looked up in
the `kinds` catalog (`values.yaml`), and the chart derives **both** the
config JSON and the matching ClusterRole rules from that single entry:

```yaml
helm:
  valuesObject:
    config:
      watch:
        - AnsibleRun        # → resources map entry + RBAC for ansibleruns
        - HarvesterVM
    # no rbac.rules needed — apiGroups/resources come from the catalog
```

Rules for kinds sharing an apiGroup are collapsed into one ClusterRole
rule. `rbac.rules` still exists for *extra* permissions (e.g. a kind you
pulled in via `config.content`) and is unioned with the derived set.

To watch a kind not yet in the catalog, add it to `kinds` in
`values.yaml` (one PR, reusable everywhere) — or fall back to
`config.content` + a matching `rbac.rules` for a one-off. Catalog
field-paths are taken from the live CRDs/XRDs; dot-paths must match the
real object (array indexing like `spec.parentRefs[0]` is not supported —
point at the parent and let machinery flatten it).

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
