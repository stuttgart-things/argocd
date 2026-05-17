# homerun2 PR-preview platform

Bundles every cluster-side moving part of the homerun2 per-PR preview-env machinery into one platform Application. Mirrors `platforms/security/` and `platforms/network/`: a single bootstrap Application renders a set of `ApplicationSet`s that fan out to clusters opting in via labels.

Replaces 17 hand-maintained files that previously lived under `clusters/<cluster>/.../homerun2-dev/` in `stuttgart-things/stuttgart-things` (three per-component AppSets + 13 near-identical Kyverno-policy Applications + ClusterSecretStore).

## Layout

```
platforms/homerun2-pr-preview/
├── application.yaml                       # bootstrap, applied once on the management cluster
├── kustomization.yaml                     # lists the four AppSets (not the bootstrap)
├── appset-omni-pitcher-pr-preview.yaml    # per-PR previews for homerun2-omni-pitcher
├── appset-core-catcher-pr-preview.yaml    # per-PR previews for homerun2-core-catcher
├── appset-scout-pr-preview.yaml           # per-PR previews for homerun2-scout
├── appset-policies.yaml                   # all Kyverno policy Applications (matrix gen)
└── README.md
```

## Opt-in label

The cluster Secret on the management cluster needs:

```yaml
metadata:
  labels:
    homerun2-pr-preview: "true"
```

In `stuttgart-things/stuttgart-things` cluster overlays, add this label to the cluster's `ClusterbookCluster` `spec.labels` block (Clusterbook propagates it to the Argo cluster Secret).

The cluster also needs a matching `AppProject` of the same name as the cluster (the platform uses `{{ .name }}` for both project + destination), plus the `vault-homerun2-pr` `ClusterSecretStore` wired up.

## Opt-out

- **Whole platform** on a cluster: remove the `homerun2-pr-preview: "true"` label from its cluster Secret. AppSets stop emitting Applications for it. Existing PR-preview Applications are preserved (`preserveResourcesOnDeletion: true` on `appset-policies.yaml`; remove them by hand or by closing the PRs).
- **One component**: drop its `appset-<component>-pr-preview.yaml` from `kustomization.yaml` and remove its rows from `appset-policies.yaml`.

## Bootstrap

```bash
kubectl apply -f platforms/homerun2-pr-preview/application.yaml
```

That's it. Argo syncs the Application, which renders the platform directory, which materializes the four AppSets, which fan out to every labelled cluster.

## Prereqs not declared here

- Secret `homerun2-omni-pitcher-pat` in `argocd` ns on the management cluster (GitHub PAT with `repo:status` + `public_repo`).
- Vault auth + KV path `homerun2-pr/preview-env` on each target cluster, surfaced as the `vault-homerun2-pr` `ClusterSecretStore`.
- `apps/homerun2/install` chart published at the catalog's `main` ref (this is the parent-Application source the per-PR AppSets reference).

## Adding a new component

1. Drop a new `appset-<component>-pr-preview.yaml` in this directory.
2. Add it to `kustomization.yaml` resources.
3. Append rows to `appset-policies.yaml`'s list generator: one per policy (quota, secrets, seed-data, sweep) plus any component-specific extras (e.g. scout's `preview-scout-verify`).

## Cluster-specific values (currently hardcoded)

These are baked into the AppSets because only `homerun2-dev` consumes the platform today. Lifting to per-cluster overrides requires moving them onto cluster Secret annotations and templating via `{{ index .metadata.annotations "..." }}`:

| Value | Where used |
|-------|------------|
| `homerun2-dev.sthings-vsphere.labul.sva.de` | hostname suffix in all three AppSets |
| `homerun2-dev-gateway` / `default` | `httpRoute.gateway` block in all three AppSets |
| `vault-homerun2-pr` / `preview-env` | `clusterSecretStoreName` / `vaultSecretName` in `appset-policies.yaml` |
