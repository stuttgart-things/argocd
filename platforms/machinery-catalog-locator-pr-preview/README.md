# machinery-catalog-locator PR-preview platform

Single bootstrap Application that renders an `ApplicationSet` for per-PR
preview environments of
[`stuttgart-things/machinery-catalog-locator`](https://github.com/stuttgart-things/machinery-catalog-locator).
Mirrors `platforms/machinery-pr-preview/`, adapted for catalog-locator.

catalog-locator is the same shape as machinery (standalone gRPC `:50051` +
HTMX dashboard `:8080`), so the platform structure carries over. The one
substantive difference: catalog-locator reads **Git** (it resolves the
software catalog and opens PRs to remove resources), **not** the cluster API.
So there is no cluster-watch `config`/`rbac` block — instead each preview
needs **GitHub credentials** (see below).

## Layout

```
platforms/machinery-catalog-locator-pr-preview/
├── application.yaml                                   # bootstrap, applied once on the management cluster
├── kustomization.yaml                                 # lists the AppSet (not the bootstrap)
├── appset-machinery-catalog-locator-pr-preview.yaml   # per-PR previews
└── README.md
```

## What gets created per PR

For each open PR on `stuttgart-things/machinery-catalog-locator` labelled
`preview`, Argo `Application`s are rendered on the management cluster against
every cluster Secret labelled `machinery-catalog-locator-pr-preview: "true"`:

| Name | Owner | Source | Role |
|---|---|---|---|
| `machinery-catalog-locator-pr-<n>-platform` | the AppSet | this repo, `apps/machinery-catalog-locator/install` | parent — renders the helm chart, which emits the children below |
| `machinery-catalog-locator-pr-<n>` | the platform Application | `ghcr.io/…/machinery-catalog-locator-kustomize:pr-<n>-<sha>` | the catalog-locator Deployment + Service via kustomize OCI |
| `machinery-catalog-locator-pr-<n>-httproute` | the platform Application | this repo, `apps/machinery/httproute` (reused) | Gateway API HTTPRoute → `:8080` |
| `machinery-catalog-locator-pr-<n>-grpcroute` | the platform Application | this repo, `apps/machinery/grpcroute` (reused) | Gateway API GRPCRoute → `:50051` |

Each per-PR install:

- Deploys into namespace `machinery-catalog-locator-pr-<n>` on the target cluster
- Pulls image `ghcr.io/stuttgart-things/machinery-catalog-locator:pr-<n>-<head_sha>`
- Pulls kustomize OCI `ghcr.io/stuttgart-things/machinery-catalog-locator-kustomize:pr-<n>-<head_sha>`
- Exposes the HTMX dashboard at `https://machinery-catalog-locator-pr-<n>.homerun2-dev.sthings-vsphere.labul.sva.de`
- Exposes gRPC at `https://machinery-catalog-locator-pr-<n>-grpc.homerun2-dev.sthings-vsphere.labul.sva.de`

## GitHub credentials (the catalog-locator-specific bit)

catalog-locator's `config.Load` refuses to start without GitHub credentials.
The AppSet wires the **GitHub App** path: it inlines the (non-secret) App ID +
installation ID, and the PEM is provisioned into each per-PR namespace by
**Vault + the External Secrets Operator** — no key material in git.

The flow per preview namespace (all rendered by the install chart):

1. `externalSecrets.enabled: true` renders an `ExternalSecret` (sync-wave −10)
   that pulls `private-key.pem` from Vault via the dedicated
   `vault-machinery-catalog-locator` `ClusterSecretStore`.
2. ESO materializes the Secret `machinery-catalog-locator-github-app` in the
   namespace.
3. The Deployment patch mounts that PEM and points `GITHUB_PRIVATE_KEY_PATH`
   at it.

> **Provisioning status** (stuttgart-things org, homerun2-dev):
> - GitHub App created + installed; `github.appID: "3928844"`,
>   `github.installationID: "137151756"` set in the AppSet. ✅
> - Dedicated `vault-machinery-catalog-locator` `ClusterSecretStore` +
>   `machinery-catalog-locator` KV mount provisioned (see
>   `stuttgart-things/stuttgart-things`), and `read-machinery-catalog-locator`
>   bound to the homerun2-dev `eso` role. ✅
> - PEM stored at `machinery-catalog-locator/machinery-catalog-locator-github-app`,
>   property `private-key.pem`. ✅
>
> To onboard another cluster, repeat the store + role-binding + label steps there.

To use a **PAT** instead (simpler — one env var, no file mount), set
`externalSecrets.keys: [token]` and `github.tokenSecret.name` to the synced
Secret. See `apps/machinery-catalog-locator/install/values.yaml`.

## Opt-in label

The cluster Secret on the management cluster needs:

```yaml
metadata:
  labels:
    machinery-catalog-locator-pr-preview: "true"
```

In `stuttgart-things/stuttgart-things` cluster overlays, add this to the
cluster's `ClusterbookCluster` `spec.labels`. The cluster also needs a matching
`AppProject` of the same name (the AppSet uses `{{ .name }}` for both `project`
and the destination key).

## Opt-out

- **Whole platform** on a cluster: remove the
  `machinery-catalog-locator-pr-preview: "true"` label from its cluster Secret.
- **One PR**: remove the `preview` label from the PR. The pullRequest generator
  drops the entry on its next 600s requeue.

## Bootstrap

```bash
kubectl apply -f platforms/machinery-catalog-locator-pr-preview/application.yaml
```

## Prereqs not declared here

- Secret `homerun2-omni-pitcher-pat` in `argocd` ns on the management cluster
  (reused — covers any public stuttgart-things repo). Used by the pullRequest
  generator to read PRs.
- The GitHub App PEM Secret in each per-PR namespace (see above).
- The repo-side CI in
  [`stuttgart-things/machinery-catalog-locator`](https://github.com/stuttgart-things/machinery-catalog-locator/tree/main/.github/workflows)
  that publishes the `pr-<n>-<sha>` artifacts — landed in #18.

## Cluster-specific values (currently hardcoded)

Baked into the AppSet because only `homerun2-dev` consumes the platform today:

| Value | Where used |
|-------|------------|
| `homerun2-dev.sthings-vsphere.labul.sva.de` | hostname suffix |
| `homerun2-dev-gateway` / `default` | `httpRoute`/`grpcRoute` gateway block |
