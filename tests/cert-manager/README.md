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

## End-to-end example

Full walk-through from "empty Argo CD" to "cert-manager running on
`kind-dev2`", assuming you have a kubeconfig context for the target cluster
and `argocd` + `kubectl` logged in to the Argo CD control plane.

```bash
# --- variables ---
CLUSTER_NAME=kind-dev2
CLUSTER_CONTEXT=kind-kind-dev2          # kubeconfig context for the target
CLUSTER_SERVER=https://10.100.136.190:33972

# 1. Register the workload cluster with Argo CD
argocd cluster add "${CLUSTER_CONTEXT}" \
  --name "${CLUSTER_NAME}" \
  --yes

# 2. Opt this cluster in to cert-manager via the selector label
#    (argocd cluster set --labels REPLACES all labels - see config/cluster-project)
kubectl -n argocd label secret "${CLUSTER_NAME}" \
  install/cert-manager=true --overwrite

# 3. (Optional) AppProject per cluster - only if spec.project: '{{ .name }}'
#    is kept. Skip if you hard-code spec.project: default.
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: ${CLUSTER_NAME}
  namespace: argocd
spec:
  sourceRepos:
    - https://charts.jetstack.io
    - https://github.com/stuttgart-things/argocd.git
  destinations:
    - server: ${CLUSTER_SERVER}
      namespace: '*'
  clusterResourceWhitelist:
    - group: '*'
      kind: '*'
EOF

# 4. Apply the ApplicationSets (one-time, cluster-agnostic)
kubectl apply -k tests/cert-manager/

# 5. Verify the three Applications were generated for this cluster
argocd app list | grep "${CLUSTER_NAME}"
# cert-manager-kind-dev2
# cert-manager-selfsigned-kind-dev2
# cert-manager-cluster-ca-kind-dev2

# 6. Verify they sync and the workload lands on the target cluster
argocd app wait "cert-manager-${CLUSTER_NAME}" --health --timeout 300
kubectl --context "${CLUSTER_CONTEXT}" -n cert-manager get pods
```

### Adding a second cluster

After onboarding one cluster, adding another is just steps 1-3 with new
variables - the ApplicationSets from step 4 are already running and pick
up the new Cluster secret automatically:

```bash
argocd cluster add kind-prod --name kind-prod --yes
kubectl -n argocd label secret kind-prod install/cert-manager=true --overwrite
# AppProject for kind-prod (if per-cluster projects are used)
# ... no other changes, no new files in git
```

### Removing cert-manager from a cluster

Drop the opt-in label; the ApplicationSet controller deletes the three
generated Applications (and, with `prune: true` in `syncPolicy`, their
workload):

```bash
kubectl -n argocd label secret kind-dev2 install/cert-manager-
```

## Rollback

`kubectl delete -k tests/cert-manager/` removes the ApplicationSets; the
generated child Applications are garbage-collected by the ApplicationSet
controller. The existing `infra/cert-manager/**/application.yaml` files are
untouched by this test.
