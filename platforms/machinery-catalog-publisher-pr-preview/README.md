# machinery-catalog-publisher — PR preview

Per-PR preview environments for
[`stuttgart-things/machinery-catalog-publisher`](https://github.com/stuttgart-things/machinery-catalog-publisher),
cloning the `machinery-pr-preview` pattern.

## Flow

1. Open a PR on the publisher repo, add the **`preview`** label.
2. `push-kustomize-pr.yaml` publishes the per-PR image + kustomize OCI tagged
   `pr-<n>-<sha>`.
3. The `machinery-catalog-publisher-pr-preview` ApplicationSet (this dir) picks
   the PR up on its next 600s requeue and renders
   `apps/machinery-catalog-publisher/install` into namespace
   `machinery-catalog-publisher-pr-<n>` on every labelled cluster.
4. `comment-preview-url.yaml` posts the URL on the PR:
   `https://machinery-catalog-publisher-pr-<n>.homerun2-dev.…` → `/healthz`, `/metrics`.
5. On PR close, Argo prunes the Application and `cleanup-pr-artifacts.yaml`
   deletes the OCI tags.

## What's different from machinery's preview

- **Headless service.** The publisher has no dashboard — only `/metrics` and
  `/healthz`. The preview URL routes (plain HTTP/1.1) to its metrics Service so
  there's still something to hit. No gRPC route.
- **Per-PR S3 isolation.** Each preview writes to `status/pr-<n>/` in the bucket,
  so previews never clobber each other or the prod `status/` prefix.
- **No cluster RBAC.** The publisher reads machinery over gRPC and writes to S3;
  it never touches the cluster API, so there's no ClusterRole.

## Bootstrap

Apply once on the management cluster:

```bash
kubectl apply -f platforms/machinery-catalog-publisher-pr-preview/application.yaml
```

## S3 connection Secret

The `minio-homerun` Secret is **self-provisioned per preview env** by the
install chart's `connectionSecretExternal` (an ESO `ExternalSecret` sub-App,
sync-wave `-1`, see `apps/machinery-catalog-publisher/externalsecret`). It pulls
the MinIO root creds from Vault via the `vault-homerun2-pr` ClusterSecretStore
and writes the `S3_*` keys the publisher reads. No out-of-band projection
needed — but the store and the Vault KV path must exist on the target cluster.

## Prerequisites (not declared here)

- Secret `homerun2-omni-pitcher-pat` in the `argocd` namespace (reused PAT).
- Target cluster registered as an Argo cluster labelled
  `machinery-catalog-publisher-pr-preview: "true"`, with a matching AppProject.
- `vault-homerun2-pr` ClusterSecretStore present on the target cluster, and the
  MinIO root creds in Vault at the KV path referenced by
  `connectionSecretExternal.vault` (`minio` → `root-user` / `root-password` —
  **confirm against your Vault layout**).
- `connectionSecretExternal.endpoint` set to the real MinIO S3 API.
