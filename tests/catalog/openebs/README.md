# openebs (catalog entry test)

End-to-end test for [`infra/openebs/chart`](../../../infra/openebs/) — the app-of-apps Helm chart that wraps the upstream OpenEBS umbrella chart. Two ways to exercise it:

- **`application.yaml`** — standalone `Application` for a single cluster (quick in-cluster smoke test)
- **`applicationset.yaml`** — fleet `ApplicationSet` driven by the `install/openebs: "true"` cluster-secret label

Both point at `infra/openebs/chart` at `HEAD`, so updates to the chart on `main` flow through automatically.

## Quick test — single cluster

```bash
kubectl apply -f tests/catalog/openebs/application.yaml
```

Edits to make for a non-in-cluster target:

- `spec.source.helm.valuesObject.project` — per-cluster AppProject name
- `spec.source.helm.valuesObject.destination.server` — target cluster API
- `spec.project` — matching AppProject (the outer Application also needs it)

The outer `destination.server` stays `https://kubernetes.default.svc` — the rendered child `Application` CR lives in the management cluster's `argocd` namespace regardless of where OpenEBS actually runs.

Watch it roll in:

```bash
kubectl -n argocd get applications openebs -w
kubectl -n openebs get pods              # on the target cluster
kubectl get storageclass                 # expect openebs-hostpath
```

## Fleet test — label-driven

```bash
kubectl apply -k tests/catalog/openebs/
```

Then label cluster Secrets to opt in:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: <cluster-name>
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
    install/openebs: "true"       # <-- the only opt-in
```

Opt out by removing the label — the Application is pruned.

## Enabling Mayastor on a single cluster

The ApplicationSet installs local-PV hostpath only. Mayastor (and LVM / ZFS) are boolean toggles in the chart schema, and ApplicationSet Go-template output is always a string — `'{{ .metadata.labels.mayastor }}'` would render as `"true"` and fail schema validation with `got string, want boolean`.

To enable Mayastor on a specific cluster, apply a dedicated `Application` alongside the ApplicationSet:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: openebs-my-cluster
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: HEAD
    path: infra/openebs/chart
    helm:
      valuesObject:
        project: my-cluster
        destination:
          server: https://<cluster-api>:6443
          namespace: openebs
        engines:
          replicated:
            mayastor:
              enabled: true
        mayastorInitContainers:
          enabled: true
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

Remove that cluster's `install/openebs` label (so the ApplicationSet doesn't create a competing Application) — or name this Application differently and accept two Applications both managing the `openebs` namespace (not recommended).

Mayastor additionally needs hugepages and the `nvme-tcp` kernel module on the node — handle that outside Argo CD.

## What's being tested

| Aspect | How this test covers it |
|---|---|
| Chart renders | Rendered child `Application` CR matches the previous static `application.yaml` valuesObject (verified in #32) |
| Schema enforces consumer overrides | Any typo in the valuesObject (e.g. `destnation:`) fails the sync with a clear JSON-Schema error instead of silently being ignored |
| Cluster-generator shape | ApplicationSet stamps out one `Application` per labeled cluster; removing the label prunes it |
| In-cluster vs workload destination | Outer Application on management cluster, rendered child Application destination-patched via inner valuesObject |

## Conventions

- Selector label: `install/openebs: "true"` (matches the `install/<component>: "true"` convention set by `tests/catalog/cert-manager`)
- Per-cluster project: `project: '{{ .name }}'`
- Sync-wave: default (0); nothing in this stack needs ordering against itself

## Cleanup

```bash
kubectl delete -k tests/catalog/openebs/         # removes the ApplicationSet
kubectl -n argocd delete application openebs     # if you applied the standalone
```

With `prune: true` on the outer Application, deleting it cascades: the rendered child Application goes → its workload resources go → the `openebs` namespace can be deleted last.
