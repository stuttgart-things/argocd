# apps/openbao

Catalog entry for [OpenBao](https://openbao.org), the MPL-2.0 fork of Vault (forked at Vault 1.14). It is
packaged as an **app-of-apps Helm chart** over the upstream `openbao` chart
(`https://openbao.github.io/openbao-helm`). It deploys a **standalone raft** instance, published through a Gateway
API `HTTPRoute` (the chart's own Ingress stays off). This is the ArgoCD port of `stuttgart-things/flux`
`apps/openbao`. The flux kustomize components are values here:

| flux component | value |
|---|---|
| `components/seal-none` / `seal-static` / `seal-transit` | `seal.type: none \| static \| transit` |
| `components/multi-node` / `single-node` | `topology: multi-node \| single-node` |
| `components/init-none` / `self-init-userpass` | `init.mode: none \| self-init-userpass` |
| `components/httproute` (second Kustomization, `dependsOn: openbao`) | `httpRoute.enabled` (own Application, sync-wave 10) |
| `seal-static-secret/` (SOPS `substituteFrom`) | `seal.externalSecret.enabled` (ExternalSecret, sync-wave -10), or an existing Secret |

This is a **new instance, not a migration**. The documented in-place Vault → OpenBao migration only covers Vault
1.14.1 with raft + shamir and is explicitly unsupported from Vault 1.15.0 up. An existing `apps/vault` 1.20.x cannot
take that path: stand a fresh one up and move workloads over.

## Layout

```
apps/openbao/
├── install/                      app-of-apps Helm chart (what consumers point at)
│   ├── files/self-init.hcl       the `initialize` requests for init.mode self-init-userpass
│   └── templates/
│       ├── chart.yaml            Application "<app>"                   (sync-wave 0)   upstream openbao chart
│       ├── external-secrets.yaml Application "<app>-external-secrets" (sync-wave -10) seal.externalSecret.enabled + a seal/init that reads a Secret
│       └── httproute.yaml        Application "<app>-httproute"        (sync-wave 10)  httpRoute.enabled
├── external-secrets/             ESO ExternalSecret: the seal Secret
└── httproute/                    Gateway API HTTPRoute → svc/openbao:8200
```

`<app>` is `applicationName`, or `openbao-<sha8 of destination.server>`.

## The seal: `seal.type`

| `seal.type` | What unseals it | Use when |
|---|---|---|
| `transit` | another Vault/OpenBao unwraps the master key on start | **preferred**: a peer already exists |
| `static` | a 32-byte key read from a Secret (env `OPENBAO_SEAL_STATIC_KEY`) | the **first** instance in an environment, with no peer to chain to |
| `none` (default) | a human, after **every** pod restart (`bao operator unseal`) | short-lived or hand-held instances |

In flux the seal had to be a component, because it is a block in an HCL document and no `${VAR:-default}` can omit a
stanza. Here the chart renders the whole server config, so the seal is a value. A half-written stanza (`static`
without `seal.static.keyId`, `transit` without `seal.transit.address`) **fails the render on the schema**. Without
that check you would get an instance that nobody can unseal.

> **Changing the seal of an already-initialised instance is not a value swap.** The data is still sealed by the old
> mechanism. OpenBao requires its seal-migration procedure (old stanza kept with `disabled = "true"`, unseal with
> `-migrate`), which this chart does not model. Decide the seal before the first init.

**static.** `seal.static.keyId` is an **opaque label**, but it **must** change whenever the key does. Otherwise
OpenBao cannot tell the two keys apart, and whatever was sealed with the old one becomes unreadable. This stores a key
that can unseal the instance in the same cluster as the instance. That is the same class of trade-off as an unseal
operator such as pytoshka/vault-autounseal. This one is smaller, native and rotatable (`current_key`/`previous_key`).
The operator, by contrast, holds the shamir keys **and** the root token beside the server, has no licence and has not
been pushed to since 2025-06. Prefer `transit` wherever a peer exists.

**transit.** The token goes in as `BAO_TOKEN` via `extraSecretEnvironmentVars`, never in the config: the chart renders
the config into a **ConfigMap**, where a token would be plaintext to anyone with `get`. Make the token **periodic and
renewable**. OpenBao renews it itself (`disable_renewal` defaults to false), which is why it does not turn into a
static token that dies a month later while everything reports green. The CA that signed the peer's certificate must be
in `seal.transit.trustBundle.configMap` (default trust-manager's `cluster-trust-bundle`, mounted at
`/etc/ssl/custom`). Otherwise the seal fails on x509 and the pod never becomes ready **while the Application reports
Synced**. The peer-side half (transit mount, key, policy, token) is **not** created here and cannot be: it needs
credentials for the other Vault.

### The seal Secret: ExternalSecret or existing Secret

The Secret is `seal.static.secretName` / `seal.transit.secretName` (defaults `openbao-static-seal` /
`openbao-transit-seal`). It never comes from this repo:

* `seal.externalSecret.enabled: true` renders `<app>-external-secrets` (sync-wave -10). It holds an `ExternalSecret`
  against `seal.externalSecret.store` (a `ClusterSecretStore` by default), entry `seal.externalSecret.remoteKey`. The
  store properties are named like the Secret keys:

  | Property | When |
  |---|---|
  | `key` (`openssl rand -base64 32`) | `seal.type: static` (= `seal.static.secretKey`) |
  | `token` (periodic, renewable) | `seal.type: transit` (= `seal.transit.secretKey`) |
  | `terraform-password`, `admin-password` | `init.mode: self-init-userpass` |

  ```bash
  vault kv put <mount>/openbao key="$(openssl rand -base64 32)" \
    terraform-password="$(openssl rand -hex 16)" admin-password="$(openssl rand -hex 16)"
  ```

  `refreshInterval: "0"` (default) means fetch **once**. A key overwritten in the store under the same key ID
  therefore cannot reach the running instance by itself. `creationPolicy: Orphan` means removing the ExternalSecret
  (opt-out) leaves the Secret beside the raft PVC it unseals.
* `seal.externalSecret.enabled: false`: the Secret must already exist in the namespace, created out of band. The pod
  sits in `CreateContainerConfigError` until it does.

## Topology: `topology`

`multi-node` (default) is the upstream chart as it is: agent injector on, `resources` (50m / 512Mi request, 3Gi
limit). The requests make the pod Burstable. Without them the kernel kills it **first** when the node runs short
(sthings-infra 2026-10-07: OOM-killed at 2.1 GB RSS after weeks of ~50 MiB/day growth). Both topologies run
**one** standalone raft server. "multi-node" describes the cluster, not OpenBao HA.

`single-node` is for a cluster with one node:

| What | Why |
|---|---|
| `injector.enabled: false` (`singleNode.injectorEnabled`) | Nothing on a single node is expected to use sidecar injection. |
| `injector.affinity: ""` | The injector has a **hard** anti-affinity against itself plus a RollingUpdate. On one node the new pod never schedules beside the old one, and every upgrade stalls. Not `strategy: Recreate`: server-side apply then fails on the live, defaulted `rollingUpdate`. |
| small `singleNode.resources` (50m / 128Mi, 512Mi limit) | On a small box the request is what reserves the room. |

The flux `install/upgrade.disableWait` is **dropped**. It existed because a fresh pod is never Ready before the init
(the readiness probe is `bao status`), so a Helm install that waited for it timed out, and remediation uninstalled the
pod you needed to `exec` into. ArgoCD neither waits nor uninstalls. The openbao Application just stays
`Progressing` until the init. Check `bao status`, not only the Application.

## Self-initialisation: `init.mode: self-init-userpass`

Instead of `bao operator init` by hand, OpenBao initialises **itself** on its first start
([`initialize`](https://openbao.org/docs/configuration/self-init/)). It runs the requests in
[`install/files/self-init.hcl`](install/files/self-init.hcl) once, on empty storage, with a root token it revokes
right after. **No root token** is handed to anyone and **no recovery keys** are created. The result is userpass with:

| Created | What |
|---|---|
| policy + user `terraform` | PKI at `pki/` and nothing else, token TTL 1h (max 4h), password env `OPENBAO_TERRAFORM_PASSWORD` |
| policy + user `admin` | **break-glass**: `path "*"` with every capability, token TTL 30m (max 1h), password env `OPENBAO_ADMIN_PASSWORD` |

The passwords come from keys `terraform-password` / `admin-password` of the **seal Secret**: the one Secret the
instance already depends on. Keep the admin password in the store only and use it **by hand**
(`bao login -method=userpass username=admin`), never in automation.

**How it is wired.** The requests are appended to the server config the chart renders. Flux needed a second config
file (ConfigMap + `extraVolumes` + `-config`) only because a JSON patch cannot append to the string the seal component
replaced. `bao server` reads the `initialize` stanzas from one file just the same.

**Rules:**

* **An auto-unseal is required.** The schema rejects `self-init-userpass` with `seal.type: none`, as OpenBao would.
  In flux this was a build failure through the patch order.
* **Empty storage only.** On an initialised instance it changes the config and nothing else. Reinstall (delete the
  PVC) or create the users by hand.
* **Failure is loud, at runtime.** A missing key keeps the pod in `CreateContainerConfigError` (add it, done). An
  **empty** password fails the self-init: the server exits and from then on refuses to unseal
  (`self-initialization failed: refusing to unseal`). Fix the password, then delete PVC `data-openbao-0` and the pod.
* **The passwords are read once.** Change one later as `admin` (`bao write auth/userpass/users/<user>/password`),
  then in the store.

## The HTTPRoute

`<app>-httproute` (sync-wave 10) is its own Application, rendering [`httproute/`](httproute/) → `svc/openbao:8200` on
`httpRoute.gateway`. Cilium resolves a route's `backendRefs` once. A route applied before its Service exists serves
**HTTP 500 for good** while everything reports healthy. That is why flux split it into `openbao-httproute` with
`dependsOn: openbao`, and why it is a later wave here.

## Values

| Value | Default | Description |
|---|---|---|
| `catalog.repoURL` / `.targetRevision` | this repo / `HEAD` | where the sub-charts are loaded from |
| `project`, `destination.server`, `destination.namespace` | `default`, in-cluster, `openbao` | |
| `applicationName` | `openbao-<sha8>` | name of the openbao Application, prefix of the others |
| `chartVersion` | `0.30.3` | openbao-helm chart (Renovate-pinned, same as flux) |
| `image.repository` | `openbao/openbao` | **no tag on purpose**: the chart derives it from its appVersion with the `v` stripped. Setting `v2.7.1` yields an image that does not exist |
| `storage.size` | `8Gi` | raft PVC |
| `storage.storageClass` | `set-storageClass` | **set it**: a PVC that never binds leaves the pod Pending |
| `topology` | `multi-node` | `multi-node` \| `single-node` |
| `resources` | 50m/512Mi req, 3Gi limit | multi-node server resources |
| `singleNode.injectorEnabled` / `.resources` | `false` / 50m/128Mi, 512Mi | single-node only |
| `seal.type` | `none` | `none` \| `static` \| `transit` |
| `seal.static.keyId` | `""` | **required** with static; opaque, change it with the key |
| `seal.static.secretName` / `.secretKey` | `openbao-static-seal` / `key` | |
| `seal.transit.address` | `""` | **required** with transit |
| `seal.transit.keyName` / `.mountPath` | `openbao-unseal` / `transit/` | |
| `seal.transit.secretName` / `.secretKey` | `openbao-transit-seal` / `token` | |
| `seal.transit.trustBundle.configMap` / `.key` | `cluster-trust-bundle` / `trust-bundle.pem` | CA of the peer |
| `seal.externalSecret.enabled` | `false` | ExternalSecret for the seal Secret; else it must exist |
| `seal.externalSecret.store.name` / `.kind` | `vault-backend` / `ClusterSecretStore` | |
| `seal.externalSecret.remoteKey` | `openbao` | entry in the store |
| `seal.externalSecret.refreshInterval` | `"0"` | fetch once |
| `init.mode` | `none` | `none` \| `self-init-userpass` |
| `httpRoute.enabled` / `.hostname` / `.gateway` | `true` / `openbao.example.com` / `cilium-gateway` in `default` | |
| `extraValues` | `{}` | deep-merged into the upstream values (lists are replaced) |
| `syncPolicy` | automated, SSA, `RespectIgnoreDifferences` | applied to all rendered Applications |

The openbao Application ignores the injector webhook's `caBundle`. The injector patches it at runtime, and selfHeal
would otherwise write the chart's empty value back.

## Deployment

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: openbao-parent
  namespace: argocd
spec:
  project: default
  destination: { server: https://kubernetes.default.svc, namespace: argocd }
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: apps/openbao/install
    helm:
      valuesObject:
        applicationName: openbao     # must differ from this parent's name
        storage: { storageClass: openebs-hostpath }
        seal:
          type: static
          static: { keyId: openbao-2026-01 }
          externalSecret: { enabled: true, store: { name: vault-backend, kind: ClusterSecretStore } }
        init: { mode: self-init-userpass }
        httpRoute: { hostname: openbao.example.com }
  syncPolicy: { automated: { prune: true, selfHeal: true } }
```

Fleet-wide, `platforms/security/appset-openbao.yaml` renders this per cluster labelled
`security-platform/openbao: 'true'`, configured through `security-platform.stuttgart-things.com/openbao-*`
annotations.

## Initialize

Unless `init.mode: self-init-userpass`, the instance has to be **initialised once**:

```bash
kubectl exec -n openbao openbao-0 -- bao operator init
```

With `transit` or `static` this returns **recovery keys**. With `none` it returns **unseal keys**, and every pod
restart needs `bao operator unseal <key>` up to the threshold. Store the output immediately: it is printed once.

## Verify

```bash
kubectl get pods,pvc -n openbao                       # Pending pod = usually the StorageClass
kubectl exec -n openbao openbao-0 -- bao status       # Sealed false is the thing to look for
kubectl logs -n openbao openbao-0 | grep -i seal      # bad transit address/token/CA shows here
kubectl get externalsecret,httproute -n openbao
curl -sk https://<hostname>/v1/sys/health
```
