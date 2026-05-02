# apps/omni-pitcher-preview

Per-PR preview environments for [`stuttgart-things/homerun2-omni-pitcher`](https://github.com/stuttgart-things/homerun2-omni-pitcher), driven by the Argo CD **`pullRequest`** ApplicationSet generator. Each open PR gets its own namespace running **redis-stack + omni-pitcher** side-by-side.

## Layout

```
apps/omni-pitcher-preview/
├── applicationset.yaml                  # PR generator -> 1 Application per open PR
├── install/                             # Umbrella chart pointed at by each generated Application
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
│       ├── _helpers.tpl                 # imagePatch / redisAddrPatch / authTokenPatch / deletePatch
│       ├── redis-stack.yaml             # Application <release>-redis-stack (sync-wave -10)
│       └── omni-pitcher.yaml            # Application <release>-omni-pitcher (sync-wave 0)
└── README.md
```

## What gets deployed (per PR)

For PR #`<n>` with head short SHA `<sha>`:

| Resource | Name | Namespace |
|---|---|---|
| Wrapper `Application` (from ApplicationSet) | `omni-pitcher-pr-<n>` | `argocd` |
| Child `Application` (redis-stack) | `omni-pitcher-pr-<n>-redis-stack` | `argocd` |
| Child `Application` (omni-pitcher) | `omni-pitcher-pr-<n>-omni-pitcher` | `argocd` |
| Workloads (redis-stack StatefulSets, Sentinel, omni-pitcher Deployment, Services, Secrets) | various | `omni-pitcher-pr-<n>` |

Omni-pitcher is wired to the co-located redis at `redis-stack.omni-pitcher-pr-<n>.svc.cluster.local:6379` via inline kustomize patches.

## Prerequisites

1. **GitHub token Secret** in the `argocd` namespace:

   ```bash
   kubectl -n argocd create secret generic github-token \
     --from-literal=token=ghp_xxxx
   ```

   The token needs `repo` scope on `stuttgart-things/homerun2-omni-pitcher` (or `public_repo` if the repo is public).

2. **Per-PR CI artifacts** tagged with the PR head short SHA:
   - container image  `ghcr.io/stuttgart-things/homerun2-omni-pitcher:<sha>`
   - kustomize OCI    `ghcr.io/stuttgart-things/homerun2-omni-pitcher-kustomize:<sha>`

   If your CI uses a different scheme (e.g. `pr-<number>`), override `omniPitcher.version` in the ApplicationSet template.

3. **Argo CD Image / Helm OCI access** to `ghcr.io/stuttgart-things/*` (already configured for the rest of the catalog).

## Apply the ApplicationSet

```bash
kubectl apply -f apps/omni-pitcher-preview/applicationset.yaml
```

New PRs are picked up within `requeueAfterSeconds` (180s). When a PR closes, the ApplicationSet controller deletes the corresponding `Application`, which in turn removes the redis-stack + omni-pitcher children and the namespace (because `CreateNamespace=true` + `prune: true`).

## Smoke-test a preview

```bash
NS=omni-pitcher-pr-42
kubectl -n $NS port-forward svc/homerun2-omni-pitcher 8080:80 &
curl -X POST http://localhost:8080/pitch \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer preview-auth-token" \
  -d '{"title":"Test","message":"hello","severity":"info","author":"me"}'
```

(The default preview token is `preview-auth-token` - see `install/values.yaml`. Override via `authToken` in the ApplicationSet `valuesObject` if you need a real secret.)

## Filtering which PRs spin up

The ApplicationSet only generates for PRs labelled `preview` (see `generators[0].pullRequest.github.labels`). Drop the `labels` filter to preview every open PR, or change the label name to fit your workflow.

## Gotchas

- **Ephemeral by default**: `redisStack.persistence.enabled: false` so previews come up without depending on a CSI driver. Flip to `true` in the `valuesObject` for stateful debugging.
- **Service name**: The redis-stack child uses inner-helm `releaseName: redis-stack` regardless of the wrapper release - so omni-pitcher resolves `redis-stack.<ns>.svc.cluster.local` cleanly even when the wrapper release is `omni-pitcher-pr-42`.
- **Secrets are dev-grade**: `preview-redis-password` / `preview-auth-token` are inlined in `values.yaml`. For sensitive flows use ArgoCD Vault Plugin / SOPS overlays on the wrapper Application.

## Related

- Source repo: <https://github.com/stuttgart-things/homerun2-omni-pitcher>
- Redis Stack chart: [`apps/redis-stack`](../redis-stack/)
- Full homerun2 stack (production-style, all components): [`apps/homerun2`](../homerun2/)
