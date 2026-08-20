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
| `kyverno-install-security`             | -10  | `infra/kyverno/install`               | `kyverno`          | Kyverno admission controller + background-scan controller + cleanup controller + CRDs (`ClusterPolicy`, `Policy`, `PolicyException`, …). Controller only — actual `ClusterPolicy` / `Policy` resources are cluster-specific and live in each cluster's overlay (same split as ESO above) |

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
| `security-platform/kyverno: "true"`                      | Enrol the cluster in `kyverno-install-security` |

Selector logic — opt-in appsets:

```yaml
matchLabels:
  security-platform: "true"
  security-platform/<feature>: "true"
```

Missing or any non-`"true"` value = excluded.

If the cluster is managed by `clusterbook-operator`, add the labels to the `ClusterbookCluster` CR's `spec.labels` — the operator propagates them onto the Argo Secret on the next reconcile.

### Opt-out and teardown

Both ApplicationSets here are app-of-apps parents and deliberately do **not** set `spec.syncPolicy.preserveResourcesOnDeletion`. What that flag preserves for such a parent are child `Application` CRs, not workloads. Preserving them leaves orphans in the `argocd` namespace that outlive a deregistered cluster and then block its `proj-<cluster>` from finalizing (#324).

Without the flag the parent Application carries `resources-finalizer.argocd.argoproj.io`, so deleting it collects the child Application with it. That cascade never reaches the target cluster: the parent's own destination is `https://kubernetes.default.svc` / `argocd`, and the child Application renders no finalizer of its own — so the deletion stops at the `Application` CR and never touches CRDs, namespaces, StorageClasses or DaemonSets.

**What a cluster loses on opt-out is not the workloads but ArgoCD's management of them.** They keep running exactly as deployed; there is just no more self-heal, drift correction or upgrade. Clean-up stays manual: `kubectl delete ns <namespace>` (or equivalent) on the target cluster if you want the resources gone.

Concretely for ESO and Kyverno: flipping a cluster's per-component label away from `"true"` deletes the child `Application`, but every `ClusterSecretStore`, `ExternalSecret`, `ClusterPolicy`, `Policy` and `PolicyException` — and the CRDs behind them — stays in place. Clean-up is `kubectl delete ns external-secrets` plus the CRDs if you want them gone.

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
