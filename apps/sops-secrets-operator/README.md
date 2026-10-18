# apps/sops-secrets-operator

Catalog entry for [**sops-secrets-operator**](https://github.com/stuttgart-things/sops-secrets-operator) —
the operator that turns a `SopsSecret` (an age-encrypted blob committed to git) into a real
Kubernetes `Secret`. The Argo CD counterpart to `flux/apps/sops-secrets-operator`.

## Layout

```
apps/sops-secrets-operator/
├── install/   renders Application "sops-secrets-operator-<sha8>" (sync-wave 0) → the published
│              kustomize OCI artifact ghcr.io/stuttgart-things/sops-secrets-operator-kustomize
│              and, when ageKey.externalSecret.secretStore.name is set,
│              "<app>-age-key" (sync-wave 1) → age-key/
└── age-key/   one ExternalSecret per namespace materialising the age key Secret
               (sops-age-key / age.agekey) from a (Cluster)SecretStore
```

The artifact is rendered from the operator repo's `kcl/` profile, **not** from its kubebuilder
`config/default`: Namespace `sops-secrets-operator-system`, 5 CRDs, ServiceAccount, ClusterRole
+ Binding, Deployment — nothing else. The artifact pins its own image, so `version` pins the
operator; no image patch.

## Preconditions

**No cert-manager.** Reading the operator repo suggests the opposite — `config/default` composes
`../webhook` and `../certmanager`, and the flux `release.yaml` still carries a comment about a
webhook waiting on cert-manager — but that describes a `kubectl apply -k config/default`
install, not this artifact. Checked against the pulled `v0.9.2` artifact (and, in the flux
catalog, against `v0.9.0` and a live install): no `ValidatingWebhookConfiguration`, no
`Certificate`, no cert volume on the pod. So there is **no sync-wave dependency on
cert-manager** to translate; adding one would only make the operator wait on a component it does
not use. Flux's `timeout: 10m` survives as a longer `syncPolicy.retry` (10 attempts, up to 5m).

If a future artifact does start shipping the webhook, cert-manager becomes a precondition to
document here and to gate on in the AppSet — a sync-wave cannot express it, because the
generated parents of different AppSets are independent Applications that neither order against
nor wait for each other (network-platform's cert-manager install is wave `0`, this one `-5`).

**An age key.** The operator carries none: it resolves the key per resource through
`spec.decryption.keyRef`, a Secret in the resource's namespace. Installing the operator alone
decrypts nothing. Two ways to get the Secret there:

- **out of band** (default, like the flux catalog) — e.g. the machinery play writes
  `sops-age-key` (`age.agekey`) into each namespace from `SOPS_AGE_KEY`;
- **ExternalSecret** — set `ageKey.externalSecret.secretStore.name` and the chart renders
  `<app>-age-key`: one ExternalSecret per entry in `ageKey.externalSecret.namespaces`. Needs
  external-secrets and the store (security-platform) able to read the entry. Every listed
  namespace must already exist; the operator's own is created by its base.

`ageKey.global: true` additionally points the operator's ONE global key
(`--global-age-key-secret` / `--global-age-key-data-key`, ≥ v0.9.0,
[#47](https://github.com/stuttgart-things/sops-secrets-operator/pull/47)) at the Secret in
`sops-secrets-operator-system`, for resources that omit `keyRef`. It does not remove
per-namespace copies — a resource's own `keyRef` always wins.

## Namespace ownership

The base creates `sops-secrets-operator-system` itself and names it on every object. The chart
therefore sets **no** kustomize `namespace` (flux: no `targetNamespace`) — overriding it would
rewrite the Deployment while leaving the RBAC subjects pointing at the old one — and **no**
`CreateNamespace=true`, so the namespace has one owner. `destination.namespace` is only Argo
CD's default for namespace-less objects, of which the base has none.

## Values

| Value | Default | Notes |
|---|---|---|
| `catalog.repoURL` / `.targetRevision` | this repo / `HEAD` | source of the `-age-key` Application; the AppSet pins it |
| `applicationName` | `""` | empty = `sops-secrets-operator-<sha1(destination)[:8]>` |
| `project` | `default` | |
| `destination.server` / `.name` | `https://kubernetes.default.svc` | `name` wins if both are set |
| `destination.namespace` | `sops-secrets-operator-system` | does **not** move the operator (see above) |
| `version` | `v0.9.2` | artifact tag, **keep the `v`** — flux `SOPS_OPERATOR_VERSION`. Schema refuses < v0.9.0: earlier tags ship the previous release's image ([#90](https://github.com/stuttgart-things/sops-secrets-operator/pull/90)) |
| `ageKey.secretName` / `.dataKey` | `sops-age-key` / `age.agekey` | what the fleet's `keyRef`s name |
| `ageKey.externalSecret.secretStore.kind` / `.name` | `ClusterSecretStore` / `""` | **empty name = no ExternalSecret** |
| `ageKey.externalSecret.remoteKey` / `.property` | `sops-age-key` / `age.agekey` | entry name under the store's mount, not a KV path |
| `ageKey.externalSecret.refreshInterval` | `1h` | |
| `ageKey.externalSecret.namespaces` | `[sops-secrets-operator-system]` | one ExternalSecret per namespace |
| `ageKey.global` | `false` | global age key flags on the manager |
| `protectCRDs` | `true` | `Prune=false,Delete=false` on the five CRDs — deleting them deletes every `SopsSecret` and the Secrets they own |
| `cascadingDelete` | `false` | resources-finalizer on the child Applications |
| `syncPolicy` | automated, `ServerSideApply=true`, retry 10 × up to 5m | |

## Teardown

With `cascadingDelete: false` deleting the Applications leaves the operator and every generated
Secret in place, unmanaged. Removal is manual: `kubectl delete ns sops-secrets-operator-system`
plus the ClusterRole/Binding; the CRDs only deliberately, since they take the `SopsSecret`s with
them.
