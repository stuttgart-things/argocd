# platforms/security

Security platform bundle: `ApplicationSet`s on the management cluster that fan out the security-stack catalog entries to every cluster labelled as a security-platform target.

All ApplicationSets share one master gate — the ArgoCD cluster `Secret` must carry:

```
security-platform: "true"
```

Catalog entries rendered:

| ApplicationSet                         | Wave | Catalog path                          | Workload namespace | Notes |
|---|---|---|---|---|
| `external-secrets-install-security`    | -10  | `infra/external-secrets/install`      | `external-secrets` | External Secrets Operator (ESO) controller + webhook + cert-controller + CRDs (`ClusterSecretStore`, `ExternalSecret`, …). Controller only — `ClusterSecretStore`s are cluster-specific and live in each cluster's overlay |

`project: '{{ .name }}'` on every generated Application — the `AppProject` named after the cluster must exist first (see [`config/cluster-project`](../../config/cluster-project/), driven by the `cluster-projects` ApplicationSet on clusters labelled `auto-project=true`).

## Install

Bootstrap the platform itself (one-shot, on the management cluster):

```bash
kubectl apply -f platforms/security/application.yaml
```

That creates an `Application` named `security-platform` pointing at this directory. Argo renders the `kustomization.yaml` here, which applies the ApplicationSets into the `argocd` namespace. They become active as soon as a cluster Secret is labelled `security-platform: "true"`.

Alternatively, apply the bundle directly without the outer Application:

```bash
kubectl apply -k https://github.com/stuttgart-things/argocd.git/platforms/security?ref=main
```

`application.yaml` is intentionally **not** listed in `kustomization.yaml` — the bootstrap Application must not manage itself.

## Per-cluster opt-in

Unlike the sibling `storage` / `cicd` platforms, **security components are opt-in**, not default-enabled. Labelling a cluster with `security-platform: "true"` alone installs **nothing** — every component requires an explicit per-component opt-in label as well.

Why: ESO needs Vault-side prerequisites (Kubernetes auth backend mounted at the cluster-specific path, role bound to a policy, CA bundle present on the cluster) before it's useful. Default-installing the controller on every security-labelled cluster would produce broken `ClusterSecretStore`s and noisy reconcile errors on clusters that aren't ready.

| Component opt-in label on the cluster Secret             | Effect |
|---|---|
| `security-platform/external-secrets: "true"`             | Enrol the cluster in `external-secrets-install-security` |

Selector logic — opt-in appsets:

```yaml
matchLabels:
  security-platform: "true"
  security-platform/<feature>: "true"
```

Missing or any non-`"true"` value = excluded.

If the cluster is managed by `clusterbook-operator`, add the labels to the `ClusterbookCluster` CR's `spec.labels` — the operator propagates them onto the Argo Secret on the next reconcile.

### Opt-out safety: `preserveResourcesOnDeletion`

Each ApplicationSet sets `spec.syncPolicy.preserveResourcesOnDeletion: true`. When a cluster's per-component label is flipped from `"true"` → anything else (or removed), the child `Application` CR is deleted, **but the workload resources it managed stay in place** (CRDs, namespace, deployments). Critical for ESO — pruning its CRDs would delete every `ExternalSecret` and `ClusterSecretStore` referenced by other apps, and the materialised K8s Secrets would be cleaned up on the next reconcile, breaking running workloads.

Clean-up is manual: `kubectl delete ns external-secrets` plus the CRDs if you want the resources gone. Until then, the cluster keeps running what was deployed; ArgoCD just stops managing it.

## ClusterSecretStores live per-cluster, not here

The ESO controller is fleet-wide and belongs in this platform. **`ClusterSecretStore` resources are not** — each one points at a cluster-specific auth backend (e.g. Vault Kubernetes auth path `<cluster_name>-eso`, AWS IAM role per account, …) and references cluster-specific Secrets for CA bundles. Defining them in this bundle would force every cluster to share one auth identity to one backend, which is the wrong sharing model.

Per-cluster overlays should drop their own `ClusterSecretStore` manifests alongside the cluster's other ArgoCD artifacts. For an example, see `homerun2-dev`'s `external-secrets/cluster-secret-store.yaml` in the cluster's registration repo.

## Adding a catalog entry

1. Drop a new `appset-<name>.yaml` in this directory following the `appset-external-secrets-install.yaml` template (same cluster selector + opt-out pattern, path pointing at the new catalog entry's `install/` chart).
2. Add the filename to `kustomization.yaml`.
3. Commit — the `security-platform` Application self-heals and reconciles.

## Related

- [`infra/external-secrets`](../../infra/external-secrets/) — catalog entry rendered by the ESO ApplicationSet here.
- [`platforms/storage`](../storage/) and [`platforms/cicd`](../cicd/) — sibling platforms with the same `<bundle>-platform: "true"` gating pattern.
