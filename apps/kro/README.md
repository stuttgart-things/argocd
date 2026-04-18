# apps/kro

Catalog entry for [kro](https://kro.run/) (Kube Resource Orchestrator) — installs the upstream OCI Helm chart from `registry.k8s.io/kro/charts`.

## Files

| File | Purpose |
|---|---|
| `application.yaml` | Child `Application`: OCI Helm chart pin + in-cluster destination placeholder + sync policy. |
| `kustomization.yaml` | Kustomize base that includes `application.yaml`. |

## OCI Helm source

kro publishes to OCI only. Argo CD expresses this as:

```yaml
source:
  repoURL: registry.k8s.io/kro/charts   # no oci:// prefix
  chart: kro
  targetRevision: 0.9.1
```

Argo CD 2.8+ with `helm.enableOciSupport: true` (default in recent versions) is required. The registry is anonymous, no pull credentials needed.

## `Replace=true` sync option

The child Application sets `syncOptions: [Replace=true]` because kro ships its own CRDs in the chart and the upstream HelmRelease equivalent uses `install.crds: CreateReplace`. `Replace=true` mirrors that behaviour on sync: CRDs are replaced rather than strategically merged, which matches kro's release expectations and avoids field drift on upgrades.

## Consumer usage

Minimal — point a root `Application` at this directory:

```yaml
spec:
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: HEAD
    path: apps/kro
```

### Overriding destination cluster

Consumer cluster repo creates an overlay dir (e.g. `clusters/<cluster>/argocd/kro/`) with a `kustomization.yaml` pulling this path as a remote base and patching the child Application's `project` + `destination.server`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - https://github.com/stuttgart-things/argocd.git/apps/kro?ref=main
patches:
  - target: { kind: Application, name: kro }
    patch: |-
      - op: replace
        path: /spec/project
        value: <cluster-project>
      - op: replace
        path: /spec/destination/server
        value: https://<cluster-api>:<port>
```

Then the consumer's root `Application` points at the overlay dir (with `spec.source.plugin.name: argocd-vault-plugin-kustomize` to skip CMP discovery thrash).

## Related

- Flux equivalent: [`stuttgart-things/flux` — `cicd/kro`](https://github.com/stuttgart-things/flux/tree/main/cicd/kro)
