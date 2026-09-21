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

## Cluster identity comes from the cluster Secret

Hostnames and the Gateway are templated per cluster, the same way `platforms/homerun2` does it — nothing in the AppSets names a cluster:

| Value | Source |
|-------|--------|
| hostname suffix | `clusterbook.stuttgart-things.com/fqdn` annotation (Clusterbook sets it on every cluster it registers), `*.` trimmed |
| Gateway | `<cluster name>-gateway` in `default` |

Moving the platform to another cluster is therefore: register the cluster through Clusterbook, add the `homerun2-pr-preview: "true"` label, provide the `AppProject` and the `vault-homerun2-pr` `ClusterSecretStore`. No edit here.

Until 2026-09-20 both were literals naming `homerun2-dev` — a cluster that was deregistered on 2026-08-20 (stuttgart-things/stuttgart-things#2537). Every cluster carrying the label rendered hostnames on a domain and a Gateway it did not have.

Still per-cluster in `appset-policies.yaml`: `vault-homerun2-pr` / `preview-env` (`clusterSecretStoreName` / `vaultSecretName`).

The **preview-URL bot** in each component repo cannot read cluster annotations; its `hostname-domain` input is still a literal there and has to follow when the preview cluster changes.

## No version pins for co-tenants

A preview runs the component under test at `pr-<n>-<head sha>` and its co-tenants (omni-pitcher, core-catcher, demo-pitcher) at the **install chart's default version**, which Renovate keeps current in `apps/homerun2/install/values.yaml`. Pins in these AppSets are out of Renovate's reach: the ones that stood here until 2026-09-20 had drifted to omni-pitcher `v1.11.1` against a current `v2.3.0` and core-catcher `v0.13.0` against `v1.0.3`, across major versions. If a preview needs a co-tenant at a specific version, pin it with a `# renovate:` comment so it does not go stale again.

The exception is **wled-mock** in the light-catcher preview: it ships from the light-catcher repository and is built per PR like the catcher itself.
