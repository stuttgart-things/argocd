# cicd/crossplane

Catalog entry for [Crossplane](https://crossplane.io/) plus the stuttgart-things opinionated stack of composition Functions and stuttgart-things Configurations. Split into three independent sub-entries.

## Layout

```
cicd/crossplane/
├── install/          # Crossplane Helm chart + built-in provider packages (sync-wave -10)
├── functions/        # Composition Functions: auto-ready, go-templating, kcl, patch-and-transform (sync-wave 0)
└── configs/          # stuttgart-things Crossplane Configurations (sync-wave 0)
```

Each sub-entry is a self-contained Kustomize base producing exactly one `Application`.

## Components

### install/
Installs Crossplane `v2.2.0` from the upstream stable Helm chart into `crossplane-system`. `--enable-usages` + `--debug` runtime args. Ships three provider packages out of the box:

| Package | Version |
|---|---|
| `crossplane-contrib/provider-helm` | v1.2.0 |
| `crossplane-contrib/provider-kubernetes` | v1.2.1 |
| `upbound/provider-opentofu` | v1.1.0 |

`sync-wave: -10` so the Crossplane CRDs (Provider, Function, Configuration, etc.) land before dependent CRs in the other sub-entries.

### functions/
Applies four Composition Functions directly as `pkg.crossplane.io/v1[beta1].Function` resources into `crossplane-system`. These cover the common needs for most Compositions:

| Function | Package |
|---|---|
| `function-auto-ready` | `xpkg.crossplane.io/crossplane-contrib/function-auto-ready:v0.6.0` |
| `function-go-templating` | `xpkg.crossplane.io/crossplane-contrib/function-go-templating:v0.11.3` |
| `function-kcl` | `xpkg.upbound.io/crossplane-contrib/function-kcl:v0.12.0` |
| `function-patch-and-transform` | `xpkg.upbound.io/crossplane-contrib/function-patch-and-transform:v0.9.3` |

`sync-wave: 0` — queued after the install wave.

### configs/
Applies six stuttgart-things `pkg.crossplane.io/v1.Configuration` packages published to `ghcr.io/stuttgart-things/crossplane/`:

| Configuration | Version |
|---|---|
| `cloud-config` | v0.5.1 |
| `volume-claim` | v0.1.1 |
| `storage-platform` | v0.6.0 |
| `ansible-run` | v12.0.0 |
| `pipeline-integration` | v0.1.2 |
| `harvester-vm` | v0.3.3 |

`sync-wave: 0` — queued after the install wave. Configurations depend on the Functions they reference, so functions/ should be present whenever configs/ is.

## Consumer usage

Most clusters want all three:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - https://github.com/stuttgart-things/argocd.git/cicd/crossplane/install?ref=main
  - https://github.com/stuttgart-things/argocd.git/cicd/crossplane/functions?ref=main
  - https://github.com/stuttgart-things/argocd.git/cicd/crossplane/configs?ref=main
patches:
  - target: { kind: Application, name: crossplane }
    patch: |-
      - op: replace
        path: /spec/project
        value: <cluster-project>
      - op: replace
        path: /spec/destination/server
        value: https://<cluster-api>:<port>
  - target: { kind: Application, name: crossplane-functions }
    patch: |-
      - op: replace
        path: /spec/project
        value: <cluster-project>
      - op: replace
        path: /spec/destination/server
        value: https://<cluster-api>:<port>
  - target: { kind: Application, name: crossplane-configs }
    patch: |-
      - op: replace
        path: /spec/project
        value: <cluster-project>
      - op: replace
        path: /spec/destination/server
        value: https://<cluster-api>:<port>
```

### Overriding versions or extra providers

Patch the catalog's `valuesObject` with strategic-merge / JSON patches in the consumer overlay, e.g.:

```yaml
- target: { kind: Application, name: crossplane }
  patch: |-
    - op: add
      path: /spec/source/helm/valuesObject/provider/packages/-
      value: xpkg.upbound.io/upbound/provider-aws-ec2:v1.1.0
```

## Related

- Flux equivalent: [`stuttgart-things/flux` — `cicd/crossplane`](https://github.com/stuttgart-things/flux/tree/main/cicd/crossplane)
- Crossplane docs: <https://docs.crossplane.io/>
- stuttgart-things Configurations: <https://github.com/stuttgart-things?q=crossplane>
