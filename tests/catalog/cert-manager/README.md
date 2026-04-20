# cert-manager (catalog entry)

A **catalog entry** is a self-contained, reusable component that any cluster
managed by this ArgoCD instance can install by setting **one label on its
cluster secret**. No per-cluster YAML copies, no patches — just opt-in.

This folder is the first proof-of-concept for the pattern we intend to apply
to every platform component (cilium, openebs, gateway, vault, etc.).

---

## Why this shape

Today every cluster has its own overlay under
`stuttgart-things/clusters/<env>/.../argocd/<cluster>/infra/<component>/`,
copying the same two or three Application manifests and patching
`project` / `destination.server` for each new cluster.

That scales badly:

- Adding a cluster means touching N overlays (one per component).
- Bumping cert-manager means touching every overlay.
- Overlays drift — a patch added for one cluster quietly doesn't land on another.
- Test/debug requires reproducing the overlay stack locally.

The catalog pattern inverts it:

- **One ApplicationSet per component**, sourced from *this* repo.
- **Cluster-secret labels** decide which components a cluster gets.
- **Optional per-cluster `values.yaml`** in the `stuttgart-things` repo, pulled
  in via ArgoCD multi-source (`ref: values`) with `ignoreMissingValueFiles`.
- **No overlays** — adding a cluster is labeling its secret; adding a component
  is dropping a folder here.

---

## What this entry ships

Three ApplicationSets, each gated on the same cluster-selector label:

| Wave | ApplicationSet             | Source                                             | Purpose                                 |
|-----:|----------------------------|----------------------------------------------------|-----------------------------------------|
|  -10 | `cert-manager`             | Jetstack Helm chart (multi-source + cluster values) | cert-manager itself, CRDs enabled       |
|    0 | `cert-manager-selfsigned`  | `manifests/selfsigned`                              | Self-signed `ClusterIssuer`             |
|    0 | `cert-manager-cluster-ca`  | `manifests/cluster-ca`                              | Cluster-CA `Issuer` + `Certificate`     |

Sync wave `-10` guarantees the Helm chart (and CRDs) land before the
`ClusterIssuer` manifests — otherwise the issuer apply fails with
`no matches for kind "ClusterIssuer"` on a fresh cluster.

---

## How to onboard a cluster

### 1. Label the ArgoCD cluster secret

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: <cluster-name>
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
    install/cert-manager: "true"   # <-- the only thing that matters
type: Opaque
stringData:
  name: <cluster-name>
  server: https://<cluster-api-endpoint>
  config: |
    { ... }
```

The `install/cert-manager: "true"` label is how the cluster-generator in each
ApplicationSet picks up the cluster. Remove the label → the Applications are
pruned automatically.

### 2. (Optional) Drop a values file

The `cert-manager` ApplicationSet expects per-cluster values at:

```
stuttgart-things/stuttgart-things.git
  clusters/labul/vsphere/platform-sthings/argocd/<cluster-name>/infra/cert-manager/values.yaml
```

`<cluster-name>` = the `name` field on the ArgoCD cluster secret.

If the file is missing, the chart renders with its defaults plus the baseline
`crds.enabled: true` from `valuesObject` in the ApplicationSet. That's the
`ignoreMissingValueFiles: true` knob.

Example override:

```yaml
---
crds:
  enabled: true
replicaCount: 2
resources:
  requests:
    cpu: 50m
    memory: 128Mi
```

### 3. That's it

ArgoCD reconciles. `cert-manager` lands first (wave -10), then the two issuer
ApplicationSets (wave 0). `cmctl check api` from the target cluster verifies
the webhook.

---

## Folder structure

```
tests/catalog/cert-manager/
├── README.md                         # this file
├── applicationset.yaml               # 3 ApplicationSets (chart + 2 issuers)
├── kustomization.yaml                # wraps applicationset.yaml
└── manifests/
    ├── selfsigned/
    │   ├── clusterissuer.yaml
    │   └── kustomization.yaml
    └── cluster-ca/
        ├── cluster-ca.yaml
        └── kustomization.yaml
```

Paths referenced from the ApplicationSets:

- `tests/catalog/cert-manager/manifests/selfsigned` → `cert-manager-selfsigned`
- `tests/catalog/cert-manager/manifests/cluster-ca` → `cert-manager-cluster-ca`

---

## Testing this entry

Pick a scratch/dev cluster (e.g. `tpl-testvm`):

1. Ensure an ArgoCD cluster secret exists with the label
   `install/cert-manager: "true"`.
2. Apply the ApplicationSets once (from the ArgoCD management cluster):

   ```bash
   kubectl apply -k tests/catalog/cert-manager/
   ```

3. Watch in ArgoCD UI or:

   ```bash
   kubectl -n argocd get applicationset
   kubectl -n argocd get applications -l argocd.argoproj.io/instance
   ```

4. On the target cluster:

   ```bash
   kubectl -n cert-manager get pods
   kubectl get clusterissuers
   cmctl check api
   ```

5. To test overrides: commit a `values.yaml` at the conventional path in
   `stuttgart-things/stuttgart-things`, wait for sync, confirm the Helm
   release picks it up (`helm get values cert-manager -n cert-manager`).

6. To test opt-out: remove the `install/cert-manager: "true"` label from
   the cluster secret. Applications should be pruned.

---

## Conventions this catalog entry sets

Future catalog entries (cilium, openebs, …) must follow the same contract so
onboarding/offboarding stays uniform:

- **Selector label**: `install/<component>: "true"` on the cluster secret.
- **Multi-source for Helm**: chart from upstream, values from
  `stuttgart-things/stuttgart-things.git` at
  `clusters/<env>/<provider>/<platform>/argocd/<cluster>/<area>/<component>/values.yaml`,
  `ignoreMissingValueFiles: true`.
- **Per-cluster ArgoCD project**: `project: '{{ .name }}'` — a project per
  cluster already exists (see `appset-cluster-projects.yaml`).
- **Sync-wave discipline**: CRDs / controllers at negative waves, consumers at
  zero or positive waves.
- **Retries on CRD-dependent resources**: 5× with backoff, so a race between
  chart sync and issuer sync self-heals rather than failing the Application.

---

## Known tradeoffs

- A chart bump in `applicationset.yaml` hits **every labeled cluster at once**.
  Until we introduce a `cert-manager/channel: stable|canary` label with two
  ApplicationSets pinned to different `targetRevision`s, treat chart bumps as
  a fleet-wide change that needs review.
- Per-cluster values live in a **separate repo** (`stuttgart-things`) — the
  `ref: values` indirection is invisible in the ArgoCD UI. The `Application`
  shows two sources; inspect both if a render looks wrong.
- `ignoreMissingValueFiles: true` means a typo in the values path silently
  falls back to defaults. Verify with `helm get values` on the target cluster.
