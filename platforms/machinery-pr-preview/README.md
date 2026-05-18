# machinery PR-preview platform

Single bootstrap Application that renders an `ApplicationSet` for per-PR preview environments of [`stuttgart-things/machinery`](https://github.com/stuttgart-things/machinery). Mirrors `platforms/homerun2-pr-preview/` but scoped to one component — machinery is standalone (gRPC + HTMX dashboard for Crossplane CRs), not part of the homerun2 stack.

## Layout

```
platforms/machinery-pr-preview/
├── application.yaml                       # bootstrap, applied once on the management cluster
├── kustomization.yaml                     # lists the AppSet (not the bootstrap)
├── appset-machinery-pr-preview.yaml       # per-PR previews for machinery
└── README.md
```

## What gets created per PR

For each open PR on `stuttgart-things/machinery` labelled `preview`, one Argo `Application` named `machinery-pr-<num>` is rendered against every cluster Secret labelled `machinery-pr-preview: "true"`. Each Application:

- Deploys into namespace `machinery-pr-<num>` on the target cluster
- Pulls image `ghcr.io/stuttgart-things/machinery:pr-<num>-<head_sha>`
- Pulls kustomize OCI `ghcr.io/stuttgart-things/machinery-kustomize:pr-<num>-<head_sha>`
- Exposes the HTMX dashboard at `https://machinery-pr-<num>.homerun2-dev.sthings-vsphere.labul.sva.de`
- Exposes gRPC at port 50051 (cluster-internal only — no HTTPRoute on that port)

## Opt-in label

The cluster Secret on the management cluster needs:

```yaml
metadata:
  labels:
    machinery-pr-preview: "true"
```

In `stuttgart-things/stuttgart-things` cluster overlays, add this label to the cluster's `ClusterbookCluster` `spec.labels` (Clusterbook propagates it to the Argo cluster Secret).

The cluster also needs a matching `AppProject` of the same name as the cluster (the AppSet uses `{{ .name }}` for both `project` and as the destination key).

## Opt-out

- **Whole platform** on a cluster: remove the `machinery-pr-preview: "true"` label from its cluster Secret. The AppSet stops emitting Applications for it. Existing PR-preview Applications are torn down by the finalizer on the next reconcile.
- **One PR**: remove the `preview` label from the PR on GitHub. The pullRequest generator drops the entry on its next 600s requeue.

## Bootstrap

```bash
kubectl apply -f platforms/machinery-pr-preview/application.yaml
```

Argo syncs the Application, which renders this directory, which materializes the AppSet, which fans out to every labelled cluster.

## Prereqs not declared here

- Secret `homerun2-omni-pitcher-pat` in `argocd` ns on the management cluster (GitHub PAT with `repo:status` + `public_repo`). The PAT is reused from the homerun2 platform — it covers any public stuttgart-things repo, so no dedicated machinery PAT is minted.
- Three workflows in [`stuttgart-things/machinery`](https://github.com/stuttgart-things/machinery/tree/main/.github/workflows):
  - `push-kustomize-pr.yaml` — publishes the `pr-<n>-<sha>` artifacts the AppSet consumes
  - `cleanup-pr-artifacts.yaml` — deletes the OCI tags when the PR closes
  - `comment-preview-url.yaml` — posts the preview URL on the PR

## Cluster-specific values (currently hardcoded)

These are baked into the AppSet because only `homerun2-dev` consumes the platform today. Lifting to per-cluster overrides requires moving them onto cluster Secret annotations and templating via `{{ index .metadata.annotations "..." }}`:

| Value | Where used |
|-------|------------|
| `homerun2-dev.sthings-vsphere.labul.sva.de` | hostname suffix |
| `homerun2-dev-gateway` / `default` | `httpRoute.gateway` block |
