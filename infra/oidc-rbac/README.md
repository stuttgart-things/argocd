# infra/oidc-rbac

RBAC for OIDC logins through ZITADEL (stuttgart-things/stuttgart-things#4879,
#5023): binds the lab-wide ZITADEL roles to the built-in ClusterRoles, so one
role model applies to kubectl, Headlamp (`apps/headlamp` `oidc.*`) and every
other tool that acts as the user. Same objects and names as flux's
`oidc-rbac` component, so a cluster can move between the two repos.

## Layout

```
infra/oidc-rbac/
├── rbac/       plain Helm chart — ClusterRoleBindings (+ a read-only ClusterRole)
└── README.md
```

## What gets deployed

| Object | Grants |
|---|---|
| ClusterRoleBinding `oidc-k8s-admin` | group `zitadel:k8s-admin` → `cluster-admin` |
| ClusterRoleBinding `oidc-k8s-edit` | group `zitadel:k8s-edit` → `edit` (namespaced objects, Secrets readable, no RBAC) |
| ClusterRoleBinding `oidc-k8s-view` | group `zitadel:k8s-view` → `view` (namespaced objects, no Secrets) |
| ClusterRole `oidc-cluster-reader` + binding `oidc-k8s-cluster-reader` | edit and view: read namespaces, nodes, PVs, storage, CRDs, ingress/gateway classes, metrics (no Secrets) |

Nothing else grants an OIDC user anything. Certificates and ServiceAccount
tokens are untouched: the admin-cert kubeconfig stays the break-glass login.

## Prerequisite

The kube-apiserver must accept ZITADEL tokens and map them the way these
bindings expect (RKE2: `AuthenticationConfiguration`, written by the cluster
build):

```
username  zitadel:<email>
groups    zitadel:<role key>      # k8s-admin, k8s-edit, k8s-view
```

On a cluster whose apiserver does not trust ZITADEL the bindings do nothing,
because no token carries the groups. A role is granted in ZITADEL once per lab
(project `kubernetes`) and applies on every cluster that has this chart.

## Consumer usage

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: oidc-rbac
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: infra/oidc-rbac/rbac
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

Removing the Application prunes the bindings; OIDC users then have no rights
at all.

## Values reference

| Key | Default | Purpose |
|---|---|---|
| `groupPrefix` | `zitadel:` | Prefix the apiserver adds to every group (`claimMappings.groups.prefix`) |
| `roles.admin` | `k8s-admin` | Role key bound to `cluster-admin`; `""` = no binding |
| `roles.edit` | `k8s-edit` | Role key bound to `edit`; `""` = no binding |
| `roles.view` | `k8s-view` | Role key bound to `view`; `""` = no binding |
| `clusterReader.enabled` | `true` | Read-only cluster-scoped access for edit and view |
