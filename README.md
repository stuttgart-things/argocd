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
<summary><b><code>infra/</code> — platform infrastructure</b> (13 entries)</summary>

| Entry | Sub-entries | Version | Purpose |
|---|---|---|---|
| [`blackbox-exporter`](./infra/blackbox-exporter/) | `install` | `11.18.0` | prometheus-community blackbox-exporter — probes URLs/endpoints from inside the cluster. Deploy it next to the Prometheus that scrapes it |
| [`cert-manager`](./infra/cert-manager/) | `install` / `selfsigned` / `cluster-ca` / `vault-pki` | `v1.21.1` + — + — + — | cert-manager chart, self-signed `ClusterIssuer`, CA chain (`cluster-ca` Certificate + ClusterIssuer + one or two wildcards), Vault PKI `ClusterIssuer` (token **or** kubernetes auth) |
| [`cilium`](./infra/cilium/) | `install` / `lb` / `gateway` | `1.20.1` + — + — | CNI with kube-proxy replacement, L2 LoadBalancer IP pool, Gateway API `Gateway` |
| [`cloudnative-pg`](./infra/cloudnative-pg/) | `install` / `cluster` | `0.29.0` + `0.8.1` | CloudNativePG operator + a PostgreSQL `Cluster` CR (official `cnpg/cluster` chart) |
| [`external-secrets`](./infra/external-secrets/) | `install` / `cluster-secret-store-vault` | `2.10.0` + — | External Secrets Operator (ESO) + a templated `ClusterSecretStore` for Vault (k8s-auth, KV v2). Cluster overlays consume `cluster-secret-store-vault` per `(cluster, KV path)` pair |
| [`kyverno`](./infra/kyverno/) | `install` | `3.9.0` | Kyverno admission controller (policy engine) — `ClusterPolicy` / `Policy` / `PolicyException` CRDs. Controller only; policies are cluster-specific |
| [`longhorn`](./infra/longhorn/) | `install` | `1.12.1` | Longhorn distributed block storage; GitOps-friendly defaults (`preUpgradeChecker.jobEnabled: false`, `defaultClassReplicaCount: 1` for single-node-safe install) |
| [`nfs-csi`](./infra/nfs-csi/) | `install` / `storageclasses` | `4.13.4` + — | kubernetes-csi NFS driver + opinionated `StorageClass` set |
| [`openebs`](./infra/openebs/) | `install` | `4.6.0` | OpenEBS (local-PV + replicated volumes) with Loki/Alloy disabled |
| [`prometheus`](./infra/prometheus/) | `install` / `httproute` | `29.27.2` + — | Standalone prometheus-community Prometheus (no Grafana, Alertmanager off by default) + Gateway API `HTTPRoute` for its UI |
| [`reloader`](./infra/reloader/) | `install` | `2.2.17` | stakater Reloader — restarts workloads when a mounted ConfigMap/Secret changes. Belongs on the **workload** cluster, not the management cluster |
| [`trust-manager`](./infra/trust-manager/) | `install` / `bundle` | `v0.24.0` + — | trust-manager chart (app-of-apps), values-driven `Bundle`s — empty by default; consumers declare which Bundles their cluster needs |
| [`velero`](./infra/velero/) | `install` / `cloud-credentials` | `12.1.0` + — | Cluster backup/restore to S3-compatible object storage via `velero-plugin-for-aws` (works against MinIO and real AWS) |

</details>

<details>
<summary><b><code>cicd/</code> — CI/CD tooling</b> (7 entries)</summary>

| Entry | Sub-entries | Version | Purpose |
|---|---|---|---|
| [`argo-rollouts`](./cicd/argo-rollouts/) | `install` / `httproutes` | `2.43.1` + — | Argo Rollouts controller + dashboard, Gateway API `HTTPRoute` for the dashboard |
| [`crossplane`](./cicd/crossplane/) | `install` / `functions` / `configs` / `providers` / `provider-configs` | `2.4.0` + — ×4 | Crossplane core, 5 composition Functions (auto-ready, go-templating, kcl, patch-and-transform, environment-configs), 3 providers (helm / opentofu / kubeconfig) with their ProviderConfigs, and 2 stuttgart-things Configurations (namespace, volume-claim) |
| [`dapr`](./cicd/dapr/) | `install` | `1.18.3` | Dapr control-plane (operator, placement, scheduler, sentry, sidecar injector); HA off, JSON logs |
| [`kargo`](./cicd/kargo/) | `install` / `certs` / `httproute` | `1.9.6` (OCI) + — + — | Akuity Kargo (multi-stage GitOps promotion orchestrator), cert-manager Certificate for the API hostname, Gateway API HTTPRoute |
| [`kro`](./cicd/kro/) | `install` | `0.9.1` | Kube Resource Orchestrator (OCI Helm, CRDs replaced on sync) |
| [`tekton`](./cicd/tekton/) | `operator` / `config` / `ci-namespace` / `dashboard-httproute` | — (vendored) + — + — + — | Tekton Operator + `TektonConfig` (pruner), shared `ci` namespace, dashboard `HTTPRoute` |
| [`vcluster`](./cicd/vcluster/) | `install` | `0.37.0` | loft-sh vcluster — virtual clusters inside a host namespace, sized for CI use (resource requests, pinned `k8sVersion`). Same upstream chart as [`apps/vcluster`](./apps/vcluster/); this one carries the CI defaults |

</details>

<details>
<summary><b><code>apps/</code> — user-facing applications</b> (16 entries)</summary>

Entries whose upstream is a **kustomize OCI base** pin a tag rather than a chart version; where the base and the image are tagged separately, both are listed. Note that those ghcr tags are published **v-prefixed only** — a bare `1.2.3` is a 404, not an older release.

| Entry | Sub-entries | Version | Purpose |
|---|---|---|---|
| [`backstage`](./apps/backstage/) | `install` / `config` / `httproute` / `secrets` | chart `2.6.3` + image `v1.5.1` | Spotify's developer portal over the upstream `oci://ghcr.io/backstage/charts` chart, with the stuttgart-things image, an `app-config` ConfigMap, Gateway API HTTPRoute and its Secrets |
| [`claim-machinery-api`](./apps/claim-machinery-api/) | `install` / `auth-secret` / `httproute` | `v0.21.1` (kustomize) | REST API behind the Backstage `claimMachinery` plugin — renders Crossplane claim templates through KCL |
| [`clusterbook`](./apps/clusterbook/) | `install` / `httproute` / `pdns` | `v1.28.2` (kustomize) | Clusterbook — GitOps IP address management for clusters; the service `clusterbook-operator` reserves IP/DNS from. Optional PowerDNS token Secret |
| [`harbor`](./apps/harbor/) | `install` / `certs` / `httproute` | `27.0.3` (bitnami OCI) + — + — | Harbor container registry, cert-manager Certificates + Gateway API HTTPRoutes |
| [`headlamp`](./apps/headlamp/) | `install` / `manifests` | `0.45.0` + — | Headlamp Kubernetes dashboard + the extra manifests (RBAC / SSO group binding) |
| [`homerun2`](./apps/homerun2/) | `install` + 12 sub-charts (`httproute`, `secrets`, `kargo`, `scout-profile`, `k8s-pitcher-profile`, `omni-pitcher-routes`, `smoke-test`, `preview-*`) | redis `17.1.4` + per-service kustomize tags | The homerun2 message-bus stack: Redis Stack + 11 Go services that pitch (produce) and catch (consume) events — core/led/light/notification catchers, omni/git/k8s/demo pitchers, scout, config-viewer, wled-mock |
| [`machinery`](./apps/machinery/) | `install` / `configmap` / `httproute` / `grpcroute` / `rbac` | base `v1.13.2` + image `v1.13.4` | Machinery — gRPC + HTMX service for watching Crossplane-managed resources. The one `apps/` entry a platform label reaches (`cicd-platform/machinery`) |
| [`machinery-catalog-locator`](./apps/machinery-catalog-locator/) | `install` / `external-secrets` | `latest` ⚠️ floating | Catalog locator for the machinery catalog. Both base and image pin the mutable `latest` tag — pin a release before relying on it |
| [`machinery-catalog-publisher`](./apps/machinery-catalog-publisher/) | `install` / `externalsecret` / `httproute` | base `v0.1.0` + image `v0.1.1` | Publishes machinery catalog entries |
| [`minio`](./apps/minio/) | `install` / `certs` / `httproute` | `16.0.10` (OCI) + — + — | MinIO object storage (stuttgart-things mirrored image), cert-manager Certificates for console + API, Gateway API HTTPRoutes |
| [`rancher`](./apps/rancher/) | `install` / `certs` / `httproute` | `2.15.1` + — + — | Rancher server from the `rancher-stable` Helm repo, optionally trusting a private CA |
| [`redis-stack`](./apps/redis-stack/) | `install` | `17.1.4` | The stuttgart-things `redis` chart configured as Redis Stack (RedisJSON / Search / TimeSeries), standalone or with sentinel |
| [`schmetterpause`](./apps/schmetterpause/) | `install` / `database` | `v0.3.0` (kustomize) | schmetterpause + its CloudNativePG database — the Argo CD replacement for the repo's hand-applied `task kcl:up` path (drift detection and prune, which hand-apply has neither of) |
| [`vault`](./apps/vault/) | `install` / `certs` / `httproute` | chart `1.9.0` + autounseal `0.5.3` | HashiCorp Vault via the stuttgart-things Helm mirror, optional vault-autounseal sub-Application, cert-manager Certificates + HTTPRoute |
| [`vcluster`](./apps/vcluster/) | `install` | `0.37.0` | loft-sh vcluster as a workload — one virtual cluster per Application. Same chart as [`cicd/vcluster`](./cicd/vcluster/), without the CI-sized defaults |
| [`zitadel`](./apps/zitadel/) | `install` / `external-secrets` / `httproute` / `secrets` | chart `10.0.6` + image `v4.15.2` | ZITADEL identity provider, its ExternalSecrets/Secrets and Gateway API HTTPRoute |

</details>

<details>
<summary><b><code>config/</code> — ArgoCD-side configuration</b> (1 entry)</summary>

Catalog entries that configure Argo CD itself rather than installing workloads. Consumed by an `ApplicationSet` on the **management cluster** (the cluster running Argo CD), not by the per-cluster aggregator pattern used elsewhere.

| Entry | Sub-entries | Version | Purpose |
|---|---|---|---|
| [`cluster-project`](./config/cluster-project/) | `chart` | — | Helm chart that renders one `AppProject` per registered cluster, label-driven (`auto-project=true`, `tier=dev\|prod`, `allow-all=true`). Sourced by a `clusters`-generator `ApplicationSet`. |

</details>

<details>
<summary><b><code>platforms/</code> — pre-bundled ApplicationSets per cluster role</b> (10 bundles)</summary>

Each platform bundle is a kustomize directory of `ApplicationSet`s that live in the `argocd` namespace on the **management cluster** and fan out catalog entries to every cluster `Secret` matching a label gate. Alternative to the per-cluster aggregator-overlay pattern below: instead of every cluster repo composing its own `infra/cicd/apps` overlay, label the cluster Secret with `<bundle>-platform: "true"` and the right ApplicationSets fire automatically.

Selector pattern shared by the five role bundles:
- **Master gate** — `<bundle>-platform: "true"` on the cluster Secret enrols it in the bundle.
- **Per-feature opt-out** — `<bundle>-platform/<feature>: "false"` skips a single component on a specific cluster (default = included).
- **`preserveResourcesOnDeletion: true`** — flipping a cluster from included → opted-out deletes the parent `Application` but leaves the workload state in place (StorageClasses, CRDs, DaemonSets), so opt-out doesn't tear out live storage / CRDs.

The five **preview** bundles below work differently: one single label, no umbrella, no opt-out — plus a `pullRequest` generator, so they render one environment per PR carrying the `preview` label.

The canonical, annotated list of every label and annotation a cluster Secret can carry is [`platforms/cluster.reference.yaml`](./platforms/cluster.reference.yaml).

| Bundle | Master gate | Components | Notes |
|---|---|---|---|
| [`platforms/cicd`](./platforms/cicd/) | `cicd-platform: "true"` | 19 appsets — openebs, dapr, kro, argo-rollouts, crossplane (install / functions / configs / providers / provider-configs / platform-baseline), kargo + httproute, tekton + config + dashboard-httproute, machinery, and the three `cxp-*` XR sets (ansible / proxmoxvm / vspherevm) | Has bootstrap `application.yaml` (mgmt-cluster apply once). The `*-httproute` appsets and `machinery` additionally require `clusterbook.stuttgart-things.com/allocation-ip` Exists (and `NotIn [""]`, which excludes registration-only kind clusters) — other clusters get the workload but no Gateway API route. `platform-baseline` and the three `cxp-*` sets are git-file/directory generators keyed on the cluster's **`env`** label: without it the path segment renders empty and nothing is generated, silently |
| [`platforms/network`](./platforms/network/) | `network-platform: "true"` + `clusterbook.stuttgart-things.com/allocation-ip` Exists | 9 appsets — cert-manager (install / selfsigned / cluster-ca), cilium (lb / gateway), trust-manager (install / bundle) by default; opt-in cilium gateway-secondary + cert-manager vault-pki | Clusterbook-aware. Reads the cluster's reserved IP + FQDN from `clusterbook-operator`-set annotations to wire LoadBalancer IPPool + wildcard cert + Gateway hostname. Optional second Gateway from `fqdn-secondary` annotation; optional Vault PKI `ClusterIssuer` from `vault-server`/`vault-pki-path`/`vault-token-secret` annotations |
| [`platforms/kind`](./platforms/kind/) | `kind-platform: "true"` | base: 4 appsets — cilium (install / lb), cert-manager (install / selfsigned). `expose-external/`: optional overlay adding cluster-CA + cilium gateway for kind clusters that publish their LB IPs via DNS | Tuned for kind networking (native routing on `eth0`/`net0`, tight L2-announcement leases). Per-feature opt-out via `kind-platform/<feature>: "false"`. The AppSets no longer gate on `clusterbook.stuttgart-things.com/cluster-type: kind`; the operator still sets that label from `spec.clusterType`, and `cilium-lb-kind` still consumes the `lb-range-*` annotations it comes with. Needs clusterbook-operator >= v0.15.0 |
| [`platforms/security`](./platforms/security/) | `security-platform: "true"` | 2 appsets — external-secrets-install, kyverno-install | Has bootstrap `application.yaml`. **Opt-out like every other bundle** — the umbrella label is enough, a component is skipped only by an explicit `security-platform/<feature>: "false"`. (It was opt-in via a second `matchLabels` until that silently dropped clusters carrying only the umbrella.) Controllers only — ESO `ClusterSecretStore`s + Kyverno `ClusterPolicy`s are cluster-specific and stay in each cluster's overlay |
| [`platforms/storage`](./platforms/storage/) | `storage-platform: "true"` | 4 appsets — openebs, longhorn, nfs-csi-install, nfs-csi-storageclasses | Has bootstrap `application.yaml`. openebs is the cluster default SC; longhorn ships alongside but not as default. NFS storage-class appset additionally requires `storage-platform.stuttgart-things.com/nfs-config` Exists; per-cluster `server`/`share`/etc. sourced from cluster-Secret annotations |
| [`platforms/homerun2-pr-preview`](./platforms/homerun2-pr-preview/) | `homerun2-pr-preview: "true"` | 9 appsets — 8 per-service preview environments + `policies` | One environment per pull request labelled `preview`, across the homerun2 service repos. Shares the `homerun2-omni-pitcher-pat` PR-reader token with the other preview bundles |
| [`platforms/machinery-pr-preview`](./platforms/machinery-pr-preview/) | `machinery-pr-preview: "true"` | 1 appset | Preview environment per `preview`-labelled PR in `stuttgart-things/machinery` |
| [`platforms/machinery-catalog-locator-pr-preview`](./platforms/machinery-catalog-locator-pr-preview/) | `machinery-catalog-locator-pr-preview: "true"` | 1 appset | Same, for `machinery-catalog-locator` |
| [`platforms/machinery-catalog-publisher-pr-preview`](./platforms/machinery-catalog-publisher-pr-preview/) | `machinery-catalog-publisher-pr-preview: "true"` | 1 appset (+ `appproject.yaml`) | Same, for `machinery-catalog-publisher` |
| [`platforms/schmetterpause-pr-preview`](./platforms/schmetterpause-pr-preview/) | `schmetterpause-pr-preview: "true"` | 1 appset | Same, for `schmetterpause` — including its per-PR Postgres |

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
