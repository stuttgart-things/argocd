# apps/homerun2

Catalog entry for the **homerun2** message-bus stack — Redis Stack + 9 Go microservices that pitch (produce) and catch (consume) events through Redis Streams. Packaged as an **app-of-apps Helm chart** with one toggle per component, so consumers compose deployments by flipping `<component>.enabled` flags.

Port of [`stuttgart-things/flux` — `apps/homerun2`](https://github.com/stuttgart-things/flux/tree/main/apps/homerun2). Maps the flux Kustomize Components pattern (10 components × OCIRepository + Flux Kustomization + per-component HTTPRoute) onto a single Helm chart that emits Argo CD `Application`s with inline kustomize patches.

## Layout

```
apps/homerun2/
├── install/                                  app-of-apps Helm chart (what consumers point at)
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── values.schema.json
│   └── templates/
│       ├── _helpers.tpl                       shared image / redis / auth-token / delete patch templates
│       ├── redis-stack.yaml                   Application "homerun2-redis-stack"   (sync-wave -10, delegates to apps/redis-stack/install)
│       ├── omni-pitcher.yaml                  Application "...-omni-pitcher"       (sync-wave 0)
│       ├── core-catcher.yaml                  Application "...-core-catcher"       (sync-wave 0)
│       ├── scout.yaml                         Application "...-scout"              (sync-wave 0)
│       ├── k8s-pitcher.yaml                   Application "...-k8s-pitcher"        (sync-wave 0)
│       ├── light-catcher.yaml                 Application "...-light-catcher"      (sync-wave 0)
│       ├── wled-mock.yaml                     Application "...-wled-mock"          (sync-wave 0)
│       ├── demo-pitcher.yaml                  Application "...-demo-pitcher"       (sync-wave 0)
│       ├── led-catcher.yaml                   Application "...-led-catcher"        (sync-wave 0)
│       ├── git-pitcher.yaml                   Application "...-git-pitcher"        (sync-wave 0)
│       └── httproute.yaml                     Application "...-httproute"          (sync-wave 10, builds routes from enabled components)
└── httproute/                                 multi-HTTPRoute sub-chart (driven by a values list)
```

## Profiles → values

The flux repo ships pre-composed [`profiles/base`](https://github.com/stuttgart-things/flux/tree/main/apps/homerun2/profiles/base) and [`profiles/cicd`](https://github.com/stuttgart-things/flux/tree/main/apps/homerun2/profiles/cicd) overlays. In Argo this collapses to *which `enabled` flags you set*:

| Profile | Override |
|---|---|
| `base` (default) | `redisStack`, `omniPitcher`, `coreCatcher`, `scout` enabled — others off |
| `cicd` | base + `gitPitcher.enabled: true` |
| `all` | every component enabled (matches the flux root kustomization) |
| `core+light` | base + `lightCatcher.enabled: true` + `wledMock.enabled: true` |

## Component cheat-sheet

| Component | Purpose | Routes? | Auth-token? |
|---|---|---|---|
| `redisStack` | Redis Stack with Sentinel — the bus everything pitches/catches over (delegates to `apps/redis-stack/install`) | no | no |
| `omniPitcher` | HTTP `/pitch` API gateway | yes | yes |
| `coreCatcher` | Redis Streams consumer + web dashboard | yes | no |
| `scout` | Web dashboard / monitoring | yes | no |
| `k8sPitcher` | Watches K8s API (informers/collectors) → pitches to omni | no | yes |
| `lightCatcher` | Redis Streams consumer → WLED HTTP | yes | no |
| `wledMock` | Mock WLED device + dashboard (dev) | yes | no |
| `demoPitcher` | Web UI for manually pitching messages | yes | no |
| `ledCatcher` | Redis Streams consumer → LED display | yes | no |
| `gitPitcher` | Watches Git repos → pitches | no | no |

## What gets deployed (per component)

Each enabled non-redis-stack component renders one Argo CD `Application` whose source is an Argo Kustomize directive against `oci://ghcr.io/stuttgart-things/homerun2-<name>-kustomize` at `.Values.<name>.version`. Inline kustomize patches mirror the corresponding flux `release.yaml`:

1. **Image override** — `ghcr.io/stuttgart-things/homerun2-<name>:<version>`
2. **Per-component redis Secret stringData patch** — the kustomize base ships e.g. `homerun2-omni-pitcher-redis` with a placeholder `password` key; we patch it to `.Values.redisPassword`
3. **REDIS_ADDR / REDIS_PORT env injection** — points the Deployment at `redis-stack.<namespace>.svc.cluster.local:6379` (the chart's redis-stack sub-Application)
4. **(omni + k8s only) Auth-token Secret patch** — patches the per-component `*-token` Secret's `auth-token` key with `.Values.authToken`
5. **(most) Ingress + KCL HTTPRoute deletes** — the bases ship a default Ingress and/or HTTPRoute; we always strip them and ship our own through the httpRoute sub-Application
6. **(k8s-pitcher only) trust-bundle volume + profile ConfigMap reference + webhook port + delete the KCL profile CM** — the calling side provides its own `K8sPitcherProfile` ConfigMap (cluster-specific config)
7. **(git-pitcher only) Namespace delete** — the base creates its own `homerun2` Namespace; we strip it because the parent stack manages the namespace via the install chart's destination

`coreCatcher` is the only component that takes a separate `kustomizeVersion` from its image `version`. Earlier core-catcher kustomize tags used a `-web` suffix to enable web mode; recent tags accept `CATCHER_MODE: web` via env (which the chart sets unconditionally), so usually `kustomizeVersion == version`.

## Consumer usage

### Default (base profile — redis-stack + omni-pitcher + core-catcher + scout)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: homerun2
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: apps/homerun2/install
    helm:
      values: |
        project: my-cluster
        destination:
          server: https://<cluster-api>:6443
          namespace: homerun2
        # Provide via ArgoCD Vault Plugin / SOPS — never inline literals
        redisPassword: <path:vault/data/homerun2#redis>
        authToken:     <path:vault/data/homerun2#auth>
        omniPitcher:
          enabled: true
          version: v1.6.2
          hostname: omni.my-cluster.example.com
        coreCatcher:
          enabled: true
          version: v0.8.0
          kustomizeVersion: v0.7.1
          hostname: core.my-cluster.example.com
        scout:
          enabled: true
          version: v0.7.0
          hostname: scout.my-cluster.example.com
        httpRoute:
          enabled: true
          gateway:
            name: cilium-gateway
            namespace: default
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

### Full stack (matches flux apps/homerun2 root kustomization)

Add to the helm.values block:

```yaml
        k8sPitcher:
          enabled: true
          version: v0.4.0
          namespace: homerun2-flux
        lightCatcher:
          enabled: true
          version: v0.3.0
          hostname: light.my-cluster.example.com
        wledMock:
          enabled: true
          version: v0.3.0
          hostname: wled.my-cluster.example.com
        demoPitcher:
          enabled: true
          version: v1.4.0
          hostname: demo.my-cluster.example.com
        ledCatcher:
          enabled: true
          version: v0.1.1
          hostname: led.my-cluster.example.com
        gitPitcher:
          enabled: true
          version: v0.5.0
```

## K8sPitcherProfile ConfigMap (NOT provisioned by this chart)

`k8sPitcher` references a ConfigMap named `homerun2-k8s-pitcher-profile` (override via `.Values.k8sPitcherProfileConfigMap`) that holds the cluster-specific `K8sPitcherProfile` (pitcher address, collectors, informers). Provision it out-of-band — example shape (apply to the same namespace as `k8sPitcher.namespace`):

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: homerun2-k8s-pitcher-profile
  namespace: homerun2-flux
data:
  profile.yaml: |
    apiVersion: homerun2.sthings.io/v1alpha1
    kind: K8sPitcherProfile
    metadata:
      name: my-cluster
    spec:
      pitcher:
        addr: https://omni.my-cluster.example.com/pitch
        insecure: false
      auth:
        tokenFrom:
          secretKeyRef:
            name: homerun2-k8s-pitcher-token
            namespace: homerun2-flux
            key: auth-token
      collectors:
        - { kind: Node,  interval: 60s }
        - { kind: Pod,   namespace: "*", interval: 30s }
        - { kind: Event, namespace: "*", interval: 15s }
      informers:
        - { group: "",    version: v1, resource: pods,        namespace: "*", events: [add, update, delete] }
        - { group: apps,  version: v1, resource: deployments, namespace: homerun2-flux, events: [add, update, delete] }
```

For CRD watching, add the CRD API group to the ClusterRole on the calling side.

## Trust bundle (k8s-pitcher TLS)

`k8sPitcher` mounts `.Values.trustBundleConfigMap` (default `cluster-trust-bundle`) at `/etc/ssl/custom/trust-bundle.pem` and sets `SSL_CERT_DIR=/etc/ssl/custom`. The ConfigMap is `optional: true`, so the pod boots without it. To populate it, deploy [`infra/trust-manager/install`](../../infra/trust-manager/) + `infra/trust-manager/bundle` on the workload cluster.

## Values reference

See `install/values.yaml` for defaults and `install/values.schema.json` for the full JSON Schema.

| Key | Default | Purpose |
|---|---|---|
| `project` | `default` | AppProject for all rendered Applications |
| `destination.server` | `https://kubernetes.default.svc` | Target cluster API |
| `destination.namespace` | `homerun2` | Shared namespace for the stack |
| `redisPassword` | `""` | Plain-text Redis password (use ArgoCD Vault Plugin / SOPS) |
| `authToken` | `""` | Bearer token for `/pitch` (use ArgoCD Vault Plugin / SOPS) |
| `trustBundleConfigMap` | `cluster-trust-bundle` | trust-manager Bundle ConfigMap mounted into k8s-pitcher |
| `k8sPitcherProfileConfigMap` | `homerun2-k8s-pitcher-profile` | ConfigMap holding the K8sPitcherProfile |
| `redisStack.enabled` / `chartVersion` / `serviceType` / `persistence.*` / `image.*` / `sentinel.*` | enabled / `17.1.4` / `ClusterIP` / nfs-defaults / stuttgart-things mirrors | Delegates to `apps/redis-stack/install` |
| `<component>.enabled` | `true` for `redisStack`/`omniPitcher`/`coreCatcher`/`scout`; `false` otherwise | Toggle component |
| `<component>.version` | per the flux defaults | Image tag + (usually) OCI kustomize tag |
| `coreCatcher.kustomizeVersion` | `v0.7.1` | OCI kustomize tag (may differ from image `version`) |
| `<component>.hostname` | `<component>.example.com` | FQDN on the HTTPRoute |
| `k8sPitcher.namespace` | `homerun2` | Optional override — k8s-pitcher often runs in a different namespace |
| `httpRoute.enabled` / `gateway.{name,namespace}` | `true` / `cilium-gateway` / `default` | Render Gateway API HTTPRoutes for every enabled component that exposes one |
| `catalog.repoURL` / `targetRevision` | this repo / `HEAD` | Where the redis-stack + httpRoute Applications fetch manifests from |
| `syncPolicy` | automated + retry | Applied to all rendered Applications |

## Testing

Pitch a test event to omni-pitcher:

```bash
curl -X POST https://omni.<DOMAIN>/pitch \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <AUTH_TOKEN>" \
  -d '{"title":"Test","message":"hello","severity":"info","author":"me"}'
```

The full payload schema is documented in the upstream [homerun2-omni-pitcher](https://stuttgart-things.github.io/homerun2-omni-pitcher/) README. Health check: `curl https://omni.<DOMAIN>/health`.

## Related

- Flux equivalent: [`stuttgart-things/flux` — `apps/homerun2`](https://github.com/stuttgart-things/flux/tree/main/apps/homerun2)
- Redis Stack chart: [`apps/redis-stack`](../redis-stack/)
- Trust bundle source: [`infra/trust-manager`](../../infra/trust-manager/)
- omni-pitcher docs: <https://stuttgart-things.github.io/homerun2-omni-pitcher/>
- core-catcher docs: <https://stuttgart-things.github.io/homerun2-core-catcher/>
- demo-pitcher docs: <https://stuttgart-things.github.io/homerun2-demo-pitcher/>
- light-catcher docs: <https://stuttgart-things.github.io/homerun2-light-catcher/>
