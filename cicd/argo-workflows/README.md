# cicd/argo-workflows

[Argo Workflows](https://argoproj.github.io/workflows/) from the argo-helm chart
(`argo-workflows` **2.0.13**, app v4.1.5), as an opt-in cicd platform
(`platforms/cicd/appset-argo-workflows.yaml`, gate `cicd-platform/argo-workflows`).

| Application | Source | Renders |
|---|---|---|
| `<app>` | `argoproj.github.io/argo-helm/argo-workflows` | CRDs (pre-sync hook Job, server-side apply), workflow controller, server UI, HTTPRoute on `hostname` via `gateway` -> `argo-workflows-server:2746` |

Renders nothing without `hostname` (lint and the catalog probe use the defaults).

## Auth

`authMode` (upstream `server.authModes`):

- **`client`** (default): the UI asks for a bearer token and every API call runs
  with that token's RBAC. For a lab cluster the quickest token is the server's
  own ServiceAccount (cluster-wide workflow rights), minted by someone who
  already has cluster access:

  ```bash
  echo "Bearer $(kubectl -n argo-workflows create token argo-workflows-server --duration=8h)"
  ```

  Paste the whole line, `Bearer ` included, into the login page.
- **`server`**: every call runs as the server's ServiceAccount. **Anyone who
  reaches the hostname can read, submit and delete workflows in every
  namespace** -- acceptable only on a test cluster behind a lab-internal
  gateway. Per cluster via annotation
  `cicd-platform.stuttgart-things.com/argo-workflows-auth-mode: server`.

SSO is not wired up; set it through `extraValues.server.sso` plus
`authMode`/`extraValues` when needed.

## Values

| Value | Default | Notes |
|---|---|---|
| `project`, `destination.*` | `default`, in-cluster/`argo-workflows` | |
| `applicationName` | `argo-workflows-<sha8(server)>` | |
| `cascadingDelete` | `false` | opt-out stops managing instead of deleting |
| `chartVersion` | `2.0.13` | renovate-tracked |
| `hostname` | `""` | required to render |
| `gateway.{name,namespace}` | `""` / `default` | name required to render |
| `authMode` | `client` | `client` or `server`, see above |
| `artifactRepository` | `{}` | upstream `artifactRepository` (s3/gcs/azure); empty = no default artifact repository |
| `extraValues` | `{}` | deep-merged over the computed upstream values (e.g. `controller.workflowNamespaces`) |
| `syncPolicy` | automated, SSA, retry 5 | |

No artifact repository by default: workflows that pass artifacts need an
`artifactRepositoryRef` or an inline repository. Credentials stay Secret
references (`accessKeySecret` etc.) in the workflow namespace.

Workflows run as the `default` ServiceAccount of their namespace unless they set
`serviceAccountName`. Upstream binds the executor Role to a ServiceAccount
`argo-workflow` only in `controller.workflowNamespaces` (default `[default]`)
and does not create that ServiceAccount (`workflow.serviceAccount.create:
false`) -- set both through `extraValues`.
