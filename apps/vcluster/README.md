# apps/vcluster

Catalog entry for [vcluster](https://www.vcluster.com/) (loft-sh) — a virtual Kubernetes cluster running as a pod on a host cluster. Packaged as an **app-of-apps Helm chart**: consumers create one ArgoCD `Application` pointing at `apps/vcluster/install`, pass overrides via `helm.values`, and the chart renders the real child `Application` that installs the upstream vcluster chart.

## Layout

```
apps/vcluster/
└── install/
    ├── Chart.yaml
    ├── values.yaml
    ├── values.schema.json
    └── templates/
        └── chart.yaml             renders Application "vcluster-<name>-<hash>" (sync-wave 0)
```

## What gets deployed

Installs vcluster `0.33.1` from the loft-sh Helm repo (`https://charts.loft.sh`, chart `vcluster`) into the configured namespace on the host cluster. By default:

- **k8s distro** (real `kube-apiserver` + `etcd`) — auto-selected by the upstream chart. vcluster `0.20+` removed the k3s/k0s distros.
- `controlPlane.statefulSet.persistence.volumeClaim` — 5Gi PVC on the host's default StorageClass
- `controlPlane.service.spec.type: ClusterIP` — vcluster API reachable in-cluster as `https://<vclusterName>.<namespace>.svc:443`
- vcluster's default sync mapping (pods/services/PVCs/endpoints synced to host; nodes, ingresses, storage classes faked virtually)

Tweak the Kubernetes version or distro image via `extraValues.controlPlane.distro.k8s.*`.

## Consumer usage

### Single vcluster — one `Application`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: vcluster-dev
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: apps/vcluster/install
    helm:
      values: |
        project: default
        vclusterName: vcluster-dev
        destination:
          server: https://kubernetes.default.svc
          namespace: vcluster-dev
        persistence:
          enabled: true
          storageClass: longhorn
          size: 5Gi
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

The outer `destination.server` is the **management cluster** (where the rendered child Application lives, in the `argocd` namespace). The inner `destination.server` under `helm.values` is the **host cluster** where the vcluster pods run.

## Registering the vcluster with ArgoCD

Once the vcluster is `Healthy / Synced` in ArgoCD, register it as a destination cluster so ArgoCD can deploy *into* the vcluster. vcluster authenticates with mTLS (client cert + key), not a bearer token — the recipes below extract those three credential fields (CA, client cert, client key) from the kubeconfig vcluster emits.

> **Important — drop the `.svc` suffix.** vcluster's server cert SANs cover `<vclusterName>` and `<vclusterName>.<namespace>` but **not** `<vclusterName>.<namespace>.svc`. Using the `.svc` form makes ArgoCD's strict TLS verification fail with `x509: certificate is valid for ..., not vcluster-dev.vcluster-dev.svc`. The shorter `<vclusterName>.<namespace>` form resolves in-cluster via the DNS search path and matches the cert SAN — use it everywhere below.

### Step 1 — obtain the credentials

Two equivalent ways: the `vcluster` CLI (rewrites the server URL for you), or reading the auto-created Secret directly from the host cluster (no CLI dependency — useful for ESO, ArgoCD-as-source, helm hooks, CI).

#### Option A — `vcluster connect` (CLI)

`vcluster connect` builds a default kubeconfig pointing at `https://localhost:<random>` for use with a local port-forward. For ArgoCD-from-inside-the-cluster, rewrite the server URL to the in-cluster Service hostname with `--server=`:

```bash
export KUBECONFIG=<host-cluster-kubeconfig>
kubectl -n vcluster-dev rollout status statefulset/vcluster-dev --timeout=5m

vcluster connect vcluster-dev -n vcluster-dev \
  --server=https://vcluster-dev.vcluster-dev \
  --print > /tmp/vcluster-dev.kubeconfig
```

#### Option B — host-cluster Secret (no CLI)

vcluster creates a Secret `vc-<vclusterName>` in its own namespace on the host cluster, holding the same admin credentials. Read it directly:

```bash
export KUBECONFIG=<host-cluster-kubeconfig>
kubectl -n vcluster-dev rollout status statefulset/vcluster-dev --timeout=5m

kubectl -n vcluster-dev get secret vc-vcluster-dev \
  -o jsonpath='{.data.config}' | base64 -d > /tmp/vcluster-dev.kubeconfig
```

The Secret contains: `certificate-authority`, `client-certificate`, `client-key`, `config` (full kubeconfig — `server` field hard-codes `https://localhost:8443`), `token`.

For Step 2 below, only the three TLS fields (`caData` / `certData` / `keyData`) are consumed — the kubeconfig's `server` URL is irrelevant; you set the ArgoCD-facing server explicitly when you build the cluster Secret. So both options feed Step 2 identically.

> **Why two options?** Option A is faster on the CLI. Option B has no `vcluster` binary dependency and uses pure `kubectl get secret` — easier to wire into External Secrets Operator, an ArgoCD `repo-server` plugin, a job, or any tooling that already speaks the Kubernetes API. RBAC scope is the same in both cases: whoever runs this needs `get` on Secrets in the vcluster's host namespace.

#### Smoke-test

From a pod in the same cluster — local `kubectl` cannot resolve the in-cluster Service name, that's expected:

```bash
kubectl -n argocd run vc-probe --rm -i --restart=Never \
  --image=alpine/curl:latest -- \
  curl -sk --max-time 5 https://vcluster-dev.vcluster-dev/version
```

A `gitVersion: "v1.35.0"`-shaped JSON response means DNS + TLS + API are all reachable from the ArgoCD namespace.

### Step 2a — one-shot apply (quick, not in git)

Extract the three base64 credential fields from the kubeconfig and apply an ArgoCD cluster Secret directly:

```bash
CA=$(grep "certificate-authority-data:" /tmp/vcluster-dev.kubeconfig | awk '{print $2}')
CERT=$(grep "client-certificate-data:"    /tmp/vcluster-dev.kubeconfig | awk '{print $2}')
KEY=$(grep "client-key-data:"             /tmp/vcluster-dev.kubeconfig | awk '{print $2}')
CONFIG_JSON=$(printf '{"tlsClientConfig":{"caData":"%s","certData":"%s","keyData":"%s"}}' "$CA" "$CERT" "$KEY")

kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: vcluster-dev
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: vcluster-dev
  server: https://vcluster-dev.vcluster-dev
  config: |
    ${CONFIG_JSON}
EOF

shred -u /tmp/vcluster-dev.kubeconfig
```

The vcluster appears in **ArgoCD → Settings → Clusters** as `vcluster-dev` within seconds. Survives nothing — if the host cluster is rebuilt, re-run.

### Step 2b — SOPS-encrypted in the cluster repo (GitOps, durable)

For setups with Flux + SOPS (age) reconciling the cluster directory — the standard `stuttgart-things/stuttgart-things` cluster repo pattern — commit the encrypted Secret alongside the Application:

```bash
# 1. Build the same Secret manifest as in step 2a, but write to a file
# 2. Encrypt with the cluster's age recipient (find it in any existing
#    SOPS-encrypted file in the cluster repo, e.g. .sops.age field or
#    homerun2-dev/kubeconfig.yaml)
sops --encrypt --age <age-recipient-pubkey> \
  vcluster-dev-cluster-secret.plain.yaml \
  > clusters/<cluster-path>/argocd/vcluster-dev-cluster-secret.yaml

shred -u vcluster-dev-cluster-secret.plain.yaml /tmp/vcluster-dev.kubeconfig
git add clusters/<cluster-path>/argocd/vcluster-dev-cluster-secret.yaml
git commit -m "feat(<cluster>): SOPS-encrypted ArgoCD cluster Secret for vcluster-dev"
git push
```

Flux's `kustomize-controller` (patched with `decryption.provider: sops, secretRef.name: sops-age` in the cluster's `FluxInstance`) decrypts on reconcile and applies the Secret. If you applied the Secret manually in step 2a first, Flux adopts ownership on the next sync — no conflict.

> **Note**: SOPS is the chosen flow for this repo because Flux is already wired up for it. Alternatives like sealed-secrets, External Secrets + Vault, or ArgoCD Vault Plugin work too — pick the one your reconciler already supports.

## Using the vcluster from ArgoCD

Once registered, drop the vcluster name into any other catalog entry's `destination`:

```yaml
helm:
  values: |
    destination:
      name: vcluster-dev         # registered cluster name from step 2
      namespace: my-workload
```

ApplicationSets can target it via cluster-secret labels (e.g. label the vcluster's cluster Secret with `tier=dev` and let the existing `platforms/*` ApplicationSets fan out automatically).

## Values reference

See `install/values.yaml` for defaults and `install/values.schema.json` for the full JSON Schema.

| Key | Default | Purpose |
|---|---|---|
| `project` | `default` | ArgoCD AppProject for the rendered Application |
| `destination.server` | `https://kubernetes.default.svc` | Host cluster API |
| `destination.namespace` | `vcluster-dev` | Namespace the vcluster runs in |
| `vclusterName` | `vcluster-dev` | Helm release name + Service name (drives the API URL) |
| `chartVersion` | `0.33.1` | Upstream loft-sh vcluster chart version |
| `persistence.enabled` | `true` | Render a PVC for the control-plane StatefulSet |
| `persistence.storageClass` | `""` | StorageClass (`""` → host default) |
| `persistence.size` | `5Gi` | PVC size |
| `service.type` | `ClusterIP` | Service type for the vcluster API |
| `sync` | `{}` | Deep-merged into upstream `sync` block |
| `extraValues` | `{}` | Deep-merged on top of the computed upstream `valuesObject` (e.g. pin `controlPlane.distro.k8s.version`) |
| `syncPolicy` | automated + retry | Applied to the rendered Application |

## Related

- vcluster docs (the docs page that motivated this entry): <https://www.vcluster.com/docs/vcluster/deploy/control-plane/kubernetes-pod/basics>
- ArgoCD cluster registration: <https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#clusters>
