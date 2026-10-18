# apps/clusterbook-operator

Catalog entry for [**clusterbook-operator**](https://github.com/stuttgart-things/clusterbook-operator) —
the operator that reconciles `ClusterbookCluster`, `ClusterbookAllocation`,
`ClusterbookLoadBalancer` and `ClusterbookProviderConfig` CRs against a clusterbook server
([`apps/clusterbook`](../clusterbook/)) and writes the **Argo CD cluster Secrets** — with the
`clusterbook.stuttgart-things.com/*` labels and annotations — that every `platforms/` AppSet
selects on.

The Argo CD counterpart to `flux/apps/clusterbook-operator` (and the operator half of
`flux/cicd/argocd-platform`).

## Layout

```
apps/clusterbook-operator/
└── install/   renders Application "clusterbook-operator-<sha8>" (sync-wave 0) → the published
               kustomize OCI artifact ghcr.io/stuttgart-things/clusterbook-operator-kustomize
               (CRDs, Namespace, RBAC, ServiceAccount, Deployment), patched with the image tag
               and the trust-manager CA bundle
```

## Where it runs

**On the cluster that hosts Argo CD**, i.e. the management cluster. The operator writes the
cluster Secrets into its *own* cluster (`spec.argocdNamespace`, default `argocd`); installed
anywhere else it registers clusters with an Argo CD that is not there. The flux bundle installs
it after Argo CD for the same reason (`dependsOn: argo-cd`).

The platform AppSet ([`platforms/cicd/appset-clusterbook-operator.yaml`](../../platforms/cicd/appset-clusterbook-operator.yaml))
is therefore **opt-in** (`cicd-platform/clusterbook-operator: "true"`), unlike the other cicd
components: it belongs on the one cluster whose Argo CD manages the fleet, never fleet-wide.

Bootstrapping: the cluster generator can only select the management cluster if it has a cluster
Secret of its own. Declare the in-cluster Secret (`server: https://kubernetes.default.svc`) with
the labels, or apply this chart once directly:

```bash
helm template clusterbook-operator apps/clusterbook-operator/install \
  --set applicationName=clusterbook-operator | kubectl apply -n argocd -f -
```

## Values

| Value | Default | Notes |
|---|---|---|
| `applicationName` | `""` | empty = `clusterbook-operator-<sha1(destination)[:8]>` |
| `project` | `default` | |
| `destination.server` / `.name` | `https://kubernetes.default.svc` | the Argo CD cluster; `name` wins if both are set |
| `destination.namespace` | `clusterbook-system` | operator namespace, applied as kustomize `namespace` (renames the base's Namespace and the CRB subject) — flux `CLUSTERBOOK_OPERATOR_NAMESPACE` |
| `version` | `v0.21.0` | artifact tag — flux `CLUSTERBOOK_OPERATOR_VERSION` |
| `image.repository` / `image.tag` | `ghcr.io/stuttgart-things/clusterbook-operator` / `v0.21.0` | patched over the `manager` container; keep in step with `version`. ≥ v0.21.0 — the network-platform AppSets gate on the `cluster-ready` label it latches (clusterbook-operator#119) |
| `trustBundle.enabled` | `true` | mount the trust-manager bundle + set `SSL_CERT_DIR` |
| `trustBundle.configMapName` | `cluster-trust-bundle` | mounted `optional: true` — flux `CLUSTERBOOK_OPERATOR_TRUST_BUNDLE_CONFIGMAP` |
| `trustBundle.key` | `trust-bundle.pem` | key in the ConfigMap / file name — flux `CLUSTERBOOK_OPERATOR_TRUST_BUNDLE_KEY` |
| `trustBundle.sslCertDir` | `/etc/ssl/custom` | flux `CLUSTERBOOK_OPERATOR_SSL_CERT_DIR` |
| `protectCRDs` | `true` | `Prune=false,Delete=false` on the five CRDs |
| `cascadingDelete` | `false` | resources-finalizer on the child Application |
| `syncPolicy` | automated, `ServerSideApply=true` | no `CreateNamespace` — the base ships its Namespace |

## Why the CRDs are protected

Deleting a CRD deletes every `ClusterbookCluster` with it, and each one's finalizer releases the
IP reservation and removes the Argo CD cluster Secret. One mistaken cascade on this Application
would deregister every cluster the platform manages — and with the Secrets, every platform
Application targeting them. `protectCRDs` keeps Argo CD from ever removing them; clean-up is a
deliberate `kubectl delete crd`.

## Not in this chart: the `ClusterbookProviderConfig`

The `ClusterbookProviderConfig` (`default`: `apiURL` of the clusterbook server,
`insecureSkipVerify`) is environment data, not part of the operator — the flux catalog keeps it
out of `apps/clusterbook-operator` too and seeds it once from the cluster repo. Put it next to
the cluster's other Argo CD artifacts, created once and not managed afterwards (e.g. with
`argocd.argoproj.io/sync-options: Prune=false` if an Application applies it). Until it exists,
every `ClusterbookCluster` waits on `providerConfigRef`.

```yaml
apiVersion: clusterbook.stuttgart-things.com/v1alpha1
kind: ClusterbookProviderConfig
metadata:
  name: default
spec:
  apiURL: https://clusterbook.infra.example.com
  insecureSkipVerify: false   # needs the trust bundle above for an internal CA
```

The `ClusterbookCluster` CRs themselves — what the operator acts on — are documented in
[`platforms/cluster.reference.yaml`](../../platforms/cluster.reference.yaml).

## Teardown

With `cascadingDelete: false` deleting the Application leaves the operator running, unmanaged.
To remove it: `kubectl delete ns clusterbook-system` plus the ClusterRole/Binding. Delete the
`ClusterbookCluster` CRs **while the operator still runs** if the reservations should be
released; deleting the CRDs first strands them on their finalizers.
