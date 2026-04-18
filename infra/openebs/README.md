# infra/openebs

Catalog entry for the [OpenEBS](https://openebs.io/) storage stack.

Ships a child `Application` that installs the upstream `openebs` umbrella Helm chart with the default local-PV engines enabled. Replicated/optional engines (`local.lvm`, `local.zfs`, `replicated.mayastor`) are **off** by default — opt in via a consumer-side overlay.

## Files

| File | Purpose |
|---|---|
| `application.yaml` | The child `Application`: upstream chart pin + default `valuesObject` + in-cluster destination + sync policy. |
| `kustomization.yaml` | Kustomize base that includes `application.yaml`. |

## Consumer usage

Minimal — point a root `Application` at this directory:

```yaml
spec:
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: HEAD
    path: infra/openebs
```

### Overriding destination cluster or values

Consumer cluster repo creates an overlay dir (e.g. `clusters/<cluster>/argocd/openebs/`) with a `kustomization.yaml` like:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - https://github.com/stuttgart-things/argocd.git/infra/openebs?ref=main
patches:
  - target: { kind: Application, name: openebs }
    patch: |-
      - op: replace
        path: /spec/destination/server
        value: https://<cluster-api>:<port>
      - op: add
        path: /spec/source/helm/valuesObject/engines/replicated/mayastor/enabled
        value: true
```

Then the consumer's root `Application` points at that overlay dir instead of `infra/openebs` directly.

## Mayastor

Mayastor additionally needs hugepages and the NVMe-TCP kernel module on the node — handle that outside ArgoCD.

## Related

- Flux equivalent: [`stuttgart-things/flux` — `infra/openebs`](https://github.com/stuttgart-things/flux/tree/main/infra/openebs)
