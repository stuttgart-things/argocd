# stuttgart-things/argocd

Platform catalog for **Argo CD**. Curated, versioned `Application` building blocks that cluster repos compose into their own GitOps stack via Kustomize remote bases.

One reviewed source of truth for WHAT each app is (chart pin, sensible defaults, sync policy, CRD handling). Clusters bring WHERE and HOW (target cluster, environment values, overrides).

## What's inside

```
apps/      user-facing applications
cicd/      CI/CD tooling
config/    ArgoCD-side configuration (projects, etc.) consumed by ApplicationSets on the management cluster
infra/     platform infrastructure
platforms/ pre-bundled ApplicationSets that fan out catalog entries to clusters by label, for fleets that don't want to hand-author overlays per cluster
```

Every catalog entry is a self-contained Kustomize base producing one or more `Application` manifests. Larger apps (cert-manager, tekton, cilium, minio, …) are split into independent sub-entries so consumers can pick exactly what they need (e.g. `infra/cert-manager/install` + `infra/cert-manager/selfsigned`, skipping the full `cluster-ca` chain).

## Catalog index

Version columns show what the child `Application` currently pins. `—` in the Version column means the sub-entry ships plain manifests (no upstream chart). Each row links to its per-entry README.

<details>
<summary><b><code>infra/</code> — platform infrastructure</b> (8 entries)</summary>

| Entry | Sub-entries | Version | Purpose |
|---|---|---|---|
| [`cert-manager`](./infra/cert-manager/) | `install` / `selfsigned` / `cluster-ca` / `vault-pki` | `v1.19.2` + — + — + — | cert-manager chart, self-signed `ClusterIssuer`, CA chain (`cluster-ca` Certificate + ClusterIssuer + one or two wildcards), Vault PKI `ClusterIssuer` (token auth) |
| [`cilium`](./infra/cilium/) | `chart` / `lb` / `gateway` | `1.18.5` + — + — | CNI with kube-proxy replacement, L2 LoadBalancer IP pool, Gateway API `Gateway` |
| [`external-secrets`](./infra/external-secrets/) | `install` / `cluster-secret-store-vault` | `2.4.1` + — | External Secrets Operator (ESO) + a templated `ClusterSecretStore` for Vault (k8s-auth, KV v2). Cluster overlays consume `cluster-secret-store-vault` per `(cluster, KV path)` pair |
| [`kyverno`](./infra/kyverno/) | `install` | `3.8.0` | Kyverno admission controller (policy engine) — `ClusterPolicy` / `Policy` / `PolicyException` CRDs. Controller only; policies are cluster-specific |
| [`longhorn`](./infra/longhorn/) | `install` | `1.11.2` | Longhorn distributed block storage; GitOps-friendly defaults (`preUpgradeChecker.jobEnabled: false`, `defaultClassReplicaCount: 1` for single-node-safe install) |
| [`nfs-csi`](./infra/nfs-csi/) | `chart` / `storageclasses` | `v4.13.1` + — | kubernetes-csi NFS driver + opinionated `StorageClass` set |
| [`openebs`](./infra/openebs/) | — (single) | `4.4.0` | OpenEBS (local-PV + replicated volumes) with Loki/Alloy disabled |
| [`trust-manager`](./infra/trust-manager/) | `install` / `bundle` | `0.22.0` + — | trust-manager chart (app-of-apps), values-driven `Bundle`s — empty by default; consumers declare which Bundles their cluster needs |

</details>

<details>
<summary><b><code>cicd/</code> — CI/CD tooling</b> (6 entries)</summary>

| Entry | Sub-entries | Version | Purpose |
|---|---|---|---|
| [`argo-rollouts`](./cicd/argo-rollouts/) | `chart` / `httproute` | `2.40.9` + — | Argo Rollouts controller + dashboard, Gateway API `HTTPRoute` for the dashboard |
| [`crossplane`](./cicd/crossplane/) | `install` / `functions` / `configs` | `2.2.0` + — + — | Crossplane core + 3 providers (helm / kubernetes / opentofu), 4 composition Functions, 6 stuttgart-things Configurations |
| [`dapr`](./cicd/dapr/) | — (single) | `1.17.4` | Dapr control-plane (operator, placement, scheduler, sentry, sidecar injector); HA off, JSON logs |
| [`kargo`](./cicd/kargo/) | `chart` / `certs` / `httproute` | `1.9.6` (OCI) + — + — | Akuity Kargo (multi-stage GitOps promotion orchestrator), cert-manager Certificate for the API hostname, Gateway API HTTPRoute |
| [`kro`](./cicd/kro/) | — (single) | `0.9.1` | Kube Resource Orchestrator (OCI Helm, CRDs replaced on sync) |
| [`tekton`](./cicd/tekton/) | `operator` / `config` / `ci-namespace` / `dashboard-httproute` | — (vendored) + — + — + — | Tekton Operator + `TektonConfig` (pruner), shared `ci` namespace, dashboard `HTTPRoute` |

</details>

<details>
<summary><b><code>apps/</code> — user-facing applications</b> (2 entries)</summary>

| Entry | Sub-entries | Version | Purpose |
|---|---|---|---|
| [`headlamp`](./apps/headlamp/) | `chart` / `rbac` | `0.40.0` + — | Headlamp Kubernetes dashboard + ClusterRoleBinding for SSO group |
| [`minio`](./apps/minio/) | `chart` / `certs` / `httproute` | `16.0.10` (OCI) + — + — | MinIO object storage (stuttgart-things mirrored image), cert-manager Certificates for console + API, Gateway API HTTPRoutes |

</details>

<details>
<summary><b><code>config/</code> — ArgoCD-side configuration</b> (1 entry)</summary>

Catalog entries that configure Argo CD itself rather than installing workloads. Consumed by an `ApplicationSet` on the **management cluster** (the cluster running Argo CD), not by the per-cluster aggregator pattern used elsewhere.

| Entry | Sub-entries | Version | Purpose |
|---|---|---|---|
| [`cluster-project`](./config/cluster-project/) | `chart` | — | Helm chart that renders one `AppProject` per registered cluster, label-driven (`auto-project=true`, `tier=dev\|prod`, `allow-all=true`). Sourced by a `clusters`-generator `ApplicationSet`. |

</details>

<details>
<summary><b><code>platforms/</code> — pre-bundled ApplicationSets per cluster role</b> (5 bundles)</summary>

Each platform bundle is a kustomize directory of `ApplicationSet`s that live in the `argocd` namespace on the **management cluster** and fan out catalog entries to every cluster `Secret` matching a label gate. Alternative to the per-cluster aggregator-overlay pattern below: instead of every cluster repo composing its own `infra/cicd/apps` overlay, label the cluster Secret with `<bundle>-platform: "true"` and the right ApplicationSets fire automatically.

Selector pattern shared by all bundles:
- **Master gate** — `<bundle>-platform: "true"` on the cluster Secret enrols it in the bundle.
- **Per-feature opt-out** — `<bundle>-platform/<feature>: "false"` skips a single component on a specific cluster (default = included).
- **`preserveResourcesOnDeletion: true`** — flipping a cluster from included → opted-out deletes the parent `Application` but leaves the workload state in place (StorageClasses, CRDs, DaemonSets), so opt-out doesn't tear out live storage / CRDs.

| Bundle | Master gate | Components | Notes |
|---|---|---|---|
| [`platforms/cicd`](./platforms/cicd/) | `cicd-platform: "true"` | 10 appsets — openebs, dapr, kro, argo-rollouts, crossplane, kargo + httproute, tekton + config + dashboard-httproute | Has bootstrap `application.yaml` (mgmt-cluster apply once). The `*-httproute` appsets additionally require `clusterbook.stuttgart-things.com/allocation-ip` Exists — non-clusterbook clusters get the workload but no Gateway API route |
| [`platforms/network`](./platforms/network/) | `network-platform: "true"` + `clusterbook.stuttgart-things.com/allocation-ip` Exists | 9 appsets — cert-manager (install / selfsigned / cluster-ca), cilium (lb / gateway), trust-manager (install / bundle) by default; opt-in cilium gateway-secondary + cert-manager vault-pki | Clusterbook-aware. Reads the cluster's reserved IP + FQDN from `clusterbook-operator`-set annotations to wire LoadBalancer IPPool + wildcard cert + Gateway hostname. Optional second Gateway from `fqdn-secondary` annotation; optional Vault PKI `ClusterIssuer` from `vault-server`/`vault-pki-path`/`vault-token-secret` annotations |
| [`platforms/kind`](./platforms/kind/) | `clusterbook.stuttgart-things.com/cluster-type: kind` (no master `kind-platform` label) | base: 4 appsets — cilium (install / lb), cert-manager (install / selfsigned). `expose-external/`: optional overlay adding cluster-CA + cilium gateway for kind clusters that publish their LB IPs via DNS | Tuned for kind networking (native routing on `eth0`/`net0`, tight L2-announcement leases). Per-feature opt-out via `kind-platform/<feature>: "false"` |
| [`platforms/security`](./platforms/security/) | `security-platform: "true"` + per-component **opt-in** (e.g. `security-platform/external-secrets: "true"`, `security-platform/kyverno: "true"`) | 2 appsets — external-secrets-install, kyverno-install | Has bootstrap `application.yaml`. **Opt-in only** — labelling a cluster `security-platform: "true"` installs nothing on its own; each component needs an explicit `security-platform/<feature>: "true"`. Controllers only — ESO `ClusterSecretStore`s + Kyverno `ClusterPolicy`s are cluster-specific and stay in each cluster's overlay |
| [`platforms/storage`](./platforms/storage/) | `storage-platform: "true"` | 4 appsets — openebs, longhorn, nfs-csi-install, nfs-csi-storageclasses | Has bootstrap `application.yaml`. openebs is the cluster default SC; longhorn ships alongside but not as default. NFS storage-class appset additionally requires `storage-platform.stuttgart-things.com/nfs-config` Exists; per-cluster `server`/`share`/etc. sourced from cluster-Secret annotations |

When to pick which model:
- **Aggregator-overlay** (next section) — when each cluster has bespoke versions, value overrides, or ordering and you want every change reviewed in the cluster repo.
- **Platform bundles** — when you have a fleet that should converge on one stack per role (`cicd`, `storage`, `network`); changes here propagate to every labelled cluster on the next reconcile, no per-cluster commit required.

The two models coexist — a cluster Secret can carry multiple `<bundle>-platform: "true"` labels and *also* be referenced from an aggregator overlay. Just watch for double-installs of components owned by both (e.g. openebs lives in both `platforms/cicd` and `platforms/storage`; pick one with `<bundle>-platform/openebs: "false"` on the other).

</details>

## How consumers use it

```
┌──────────────────────────────────┐       ┌───────────────────────────────────┐
│  this repo  (catalog)            │       │  cluster consumer repo            │
│                                  │       │                                   │
│  <bucket>/<app>/                 │◀─────▶│  clusters/<cluster>/argocd/       │
│    kustomization.yaml            │       │    infra.yaml   (root app)        │
│    application.yaml              │       │    apps.yaml    (root app)        │
│    README.md                     │       │    cicd.yaml    (root app)        │
│                                  │       │    infra/                         │
│                                  │       │      kustomization.yaml ← aggr.   │
│                                  │       │      <app>/                       │
│                                  │       │        kustomization.yaml ← base  │
│                                  │       │                            + patch│
└──────────────────────────────────┘       └───────────────────────────────────┘
```

Consumer flow per cluster:

1. One `AppProject` scoping what this cluster is allowed to do. Either hand-authored (see [Consumer patterns → AppProject per cluster](#consumer-patterns)) or rendered automatically by the [`config/cluster-project`](./config/cluster-project/) chart driven by an `ApplicationSet` (label the cluster Secret with `auto-project=true`).
2. One root `Application` per bucket (`<cluster>-infra`, `<cluster>-apps`, `<cluster>-cicd`) pointing at an aggregator directory in the consumer repo.
3. Each aggregator directory lists the catalog sub-paths the cluster wants.
4. Per app, a tiny overlay Kustomization pulls the catalog path as a remote base and patches `project` + `destination` (and anything cluster-specific).

## Prerequisites

- **Argo CD 2.8+** with OCI Helm support (default in recent versions).
- **Kustomize available to the repo-server.** This is the non-obvious one. The consumer overlays use **Kustomize remote bases** (`resources: - https://github.com/…/<bucket>/<app>?ref=main`). Argo CD's repo-server renders these through Kustomize — either the built-in renderer or a ConfigManagementPlugin sidecar. **CMP sidecar images do not ship Kustomize by default** (the `argocd-vault-plugin-kustomize` CMP invokes `sh -c "kustomize build . | argocd-vault-plugin generate -"` and silently returns empty if the binary isn't present). Make sure the `kustomize` binary is on `$PATH` in the sidecar, or all remote-base overlays will render to zero resources while reporting Synced.
- **Git read access** to this repo from the Argo CD repo-server. If consumer cluster repos are private, Argo CD also needs a repo credential for those — see "Private consumer repo" below.

## Consumer patterns

<details>
<summary><b>AppProject per cluster</b></summary>

Each cluster gets its own AppProject that whitelists its target API endpoint **and** the in-cluster Argo CD endpoint (so the root app-of-apps Applications — which live in the `argocd` namespace on the control plane — don't get rejected).

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: my-cluster
  namespace: argocd
spec:
  description: my-cluster
  destinations:
    # workload destination
    - name: my-cluster
      namespace: '*'
      server: https://<cluster-api>:<port>
    # root app-of-apps destination (the control plane)
    - name: in-cluster
      namespace: argocd
      server: https://kubernetes.default.svc
  sourceRepos:
    - '*'
  clusterResourceWhitelist:
    - { group: '*', kind: '*' }
  namespaceResourceWhitelist:
    - { group: '*', kind: '*' }
  clusterResourceBlacklist:
    - { group: '',  kind: ''  }
  namespaceResourceBlacklist:
    - { group: '',  kind: ''  }
```

</details>

<details>
<summary><b>Root Applications and aggregators (<code>infra</code>, <code>apps</code>, <code>cicd</code>)</b></summary>

One root `Application` per bucket. The root points at an aggregator directory in the consumer repo; the aggregator is a Kustomization that lists catalog sub-paths.

**Root Application** (apply once via `kubectl`, not via Argo CD itself — it's the bootstrap):

```yaml
# clusters/my-cluster/argocd/infra.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-cluster-infra
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/my-org/my-cluster-repo.git
    targetRevision: HEAD
    path: clusters/my-cluster/argocd/infra
    plugin:
      name: argocd-vault-plugin-kustomize   # pin if multiple CMPs are registered
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
```

**Aggregator Kustomization** — collects multiple catalog entries into one bucket:

```yaml
# clusters/my-cluster/argocd/infra/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - cert-manager   # pulls clusters/my-cluster/argocd/infra/cert-manager/kustomization.yaml
  - cilium
  - nfs-csi
  - openebs
```

Repeat for `apps` (e.g. `[kro]`) and `cicd` (e.g. `[tekton]`). Adding a new app at some future point means one new overlay directory plus one new line in the relevant aggregator — no new root Application needed.

**Overlay per app** — a Kustomization that uses the catalog path as a remote base and patches what the catalog left as placeholders (`project`, `destination.server`, sometimes values):

```yaml
# clusters/my-cluster/argocd/infra/cert-manager/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - https://github.com/stuttgart-things/argocd.git/infra/cert-manager/install?ref=main
  - https://github.com/stuttgart-things/argocd.git/infra/cert-manager/selfsigned?ref=main

patches:
  - target: { kind: Application, name: cert-manager }
    patch: |-
      - op: replace
        path: /spec/project
        value: my-cluster
      - op: replace
        path: /spec/destination/server
        value: https://<cluster-api>:<port>
  - target: { kind: Application, name: cert-manager-selfsigned }
    patch: |-
      - op: replace
        path: /spec/project
        value: my-cluster
      - op: replace
        path: /spec/destination/server
        value: https://<cluster-api>:<port>
```

Pin the catalog version via `?ref=v1.2.3` (tag) once the catalog stabilises; use `?ref=main` while iterating.

</details>

<details>
<summary><b>Private consumer repo — declarative credential for Argo CD</b></summary>

If the consumer cluster repo is private, Argo CD's repo-server needs credentials to fetch it. Credentials are declared as a labelled `Secret` in the `argocd` namespace.

**PAT (simplest)** — encrypt with SOPS before committing:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: repo-my-org
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: https://github.com/my-org/my-cluster-repo
  username: <github-user-or-bot>
  password: <GitHub PAT, repo:read scope>
```

**Encrypt + apply** (matches the stuttgart-things SOPS + age pattern):

```bash
export AGE_PUBLIC_KEY="age1..."
dagger call -m github.com/stuttgart-things/dagger/sops encrypt \
  --age-key="env:AGE_PUBLIC_KEY" \
  --plaintext-file="./repo-my-org.yaml" \
  --file-extension="yaml" \
  export --path="./repo-my-org.enc.yaml"

# Apply via Flux SOPS-decryption or argocd-vault-plugin, never commit the plaintext.
```

Alternatives:
- **SSH deploy key** — per-repo read-only key; use `sshPrivateKey` + `url: git@github.com:...`.
- **GitHub App** — centrally rotatable, best at scale; use `githubAppID` / `githubAppInstallationID` / `githubAppPrivateKey` keys on the secret.

For the catalog repo itself (this repo — public): no credential needed.

</details>

<details>
<summary><b>Upstream-chart values overrides</b></summary>

For Helm-backed catalog entries (most of them), the child `Application` in the catalog sets sensible defaults under `spec.source.helm.valuesObject`. Consumers override via a strategic-merge patch in their overlay:

```yaml
patches:
  - target: { kind: Application, name: cilium }
    patch: |-
      - op: add
        path: /spec/source/helm/valuesObject/operator/replicas
        value: 2
```

For deeper overrides (long values trees), splitting out a dedicated `values.yaml` referenced via a multi-source `Application` with `$values` is usually easier — but costs you one extra Git source per app. Start with inline patches; migrate to multi-source only if the overlay gets unwieldy.

</details>

## Versioning

`main` is the default and only branch. Tag releases with `v<semver>` when the catalog shape stabilises; consumers pin their remote-base URLs to those tags (`?ref=v1.2.3`). Between tags, `?ref=main` follows HEAD — fine for exploration, noisy for production.

## Related

Flux-based sibling: [`stuttgart-things/flux`](https://github.com/stuttgart-things/flux). The `cicd/tekton/operator` entry here still pulls vendored operator manifests from the Flux repo (`cicd/tekton/components/operator`) via a `directory:` source — those ~1500 lines of upstream YAML are shared between the Flux and Argo CD install paths rather than duplicated.
