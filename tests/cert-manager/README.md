# cert-manager ApplicationSet test

Test bed for replacing the per-cluster kustomize overlay pattern (one overlay
file per cluster rewriting `.spec.project` and `.spec.destination.server`)
with a single `ApplicationSet` that fills those fields from the Cluster
secret.

## What this replaces

Today `infra/cert-manager/{chart,selfsigned,cluster-ca}/application.yaml`
hard-code `project: default` and `destination.server:
https://kubernetes.default.svc`. To target a remote cluster a separate
overlay file is committed per cluster, e.g.

```yaml
# clusters/kind-dev2/cert-manager/kustomization.yaml   (the file we want to drop)
resources:
  - https://github.com/stuttgart-things/argocd.git/infra/cert-manager/chart?ref=main
  - https://github.com/stuttgart-things/argocd.git/infra/cert-manager/selfsigned?ref=main
patches:
  - target: { kind: Application, name: cert-manager }
    patch: |-
      - op: replace
        path: /spec/project
        value: kind-dev2
      - op: replace
        path: /spec/destination/server
        value: https://10.100.136.190:33972
  - target: { kind: Application, name: cert-manager-selfsigned }
    patch: |-
      - op: replace
        path: /spec/project
        value: kind-dev2
      - op: replace
        path: /spec/destination/server
        value: https://10.100.136.190:33972
```

With the ApplicationSet here no per-cluster file exists. Onboarding a new
cluster is one label on its Cluster secret.

## Files

| File | Purpose |
|---|---|
| `applicationset.yaml` | Three `ApplicationSet`s (chart, selfsigned, cluster-ca) fan-out per cluster |
| `cluster-secret-example.yaml` | Sample Cluster secret with the opt-in label |
| `kustomization.yaml` | Thin wrapper so the dir is `kubectl apply -k`-able |

## Required rewrites vs. the current repo schema

These are the concrete changes needed to go from "Application committed in
git + per-cluster overlay" to "ApplicationSet generates Application per
cluster."

### 1. Move static Application fields into the ApplicationSet template

The following values previously lived in
`infra/cert-manager/chart/application.yaml` and are now inlined into the
ApplicationSet `spec.template.spec`:

| Field | Source `application.yaml` | ApplicationSet template |
|---|---|---|
| `source.repoURL` | `https://charts.jetstack.io` | same, literal |
| `source.chart` | `cert-manager` | same, literal |
| `source.targetRevision` | `v1.19.2` | same, literal |
| `source.helm.releaseName` | `cert-manager` | same, literal |
| `source.helm.valuesObject` | `{crds: {enabled: true}}` | same, literal |
| `destination.namespace` | `cert-manager` | same, literal |
| `syncPolicy` | as committed | same, literal |

Same mapping for `selfsigned` and `cluster-ca`, except
`source.repoURL/path/targetRevision` point at the git repo instead of the
Helm registry.

### 2. Templated (per-cluster) fields

These are the two fields the kustomize overlay used to patch. They become
go-template expressions:

| Application field | Old value | New expression |
|---|---|---|
| `metadata.name` | `cert-manager` | `cert-manager-{{ .name }}` |
| `spec.project` | `default` | `{{ .name }}` |
| `spec.destination.server` | `https://kubernetes.default.svc` | `{{ .server }}` |

`{{ .name }}` and `{{ .server }}` come from the Cluster secret's
`stringData.name` and `stringData.server`. The `clusters` generator exposes
them automatically.

### 3. Cluster opt-in label

The generator uses a label selector so not every registered cluster gets
cert-manager. Add to each target Cluster secret:

```yaml
metadata:
  labels:
    argocd.argoproj.io/secret-type: cluster   # already required by Argo CD
    install/cert-manager: "true"              # new opt-in
```

See `cluster-secret-example.yaml`.

### 4. AppProject requirement

`spec.project: '{{ .name }}'` assumes an `AppProject` named after the
cluster (`kind-dev2`, ...) already exists and permits
`destinations.server = <cluster-server>` and the jetstack + in-repo
`repoURLs`. If projects aren't per-cluster, hard-code
`spec.project: default` instead and drop the templating on that field.

### 5. Deletions in the main tree (when promoting out of tests/)

When this pattern is adopted for real, the following become dead code and
should be removed:

- `infra/cert-manager/chart/application.yaml`
- `infra/cert-manager/selfsigned/application.yaml`
- `infra/cert-manager/cluster-ca/application.yaml`
- `infra/cert-manager/*/kustomization.yaml` (if they only reference the
  `application.yaml` above)
- any `clusters/<cluster>/cert-manager/` per-cluster overlay directories

The reusable bits — `infra/cert-manager/selfsigned/manifests/` and
`infra/cert-manager/cluster-ca/manifests/` — stay; the ApplicationSet
references them via `source.path`.

## Try it

```bash
# 1. Label a target cluster secret
kubectl -n argocd label secret kind-dev2 install/cert-manager=true

# 2. Apply the ApplicationSets
kubectl apply -k tests/cert-manager/

# 3. Observe per-cluster Applications materialize
kubectl -n argocd get applications -l \
  app.kubernetes.io/managed-by=argocd-applicationset-controller
```

Expected Applications for a cluster named `kind-dev2`:

- `cert-manager-kind-dev2`
- `cert-manager-selfsigned-kind-dev2`
- `cert-manager-cluster-ca-kind-dev2`

Each with `spec.project=kind-dev2` and
`spec.destination.server=https://10.100.136.190:33972` — i.e. exactly what
the kustomize overlay used to produce, minus the overlay file.

## Rollback

`kubectl delete -k tests/cert-manager/` removes the ApplicationSets; the
generated child Applications are garbage-collected by the ApplicationSet
controller. The existing `infra/cert-manager/**/application.yaml` files are
untouched by this test.
