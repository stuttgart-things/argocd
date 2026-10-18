# cicd/crossplane/capabilities

What a management cluster can **do**, as opposed to what it *is*. App-of-apps
chart: renders one ArgoCD `Application` per enabled capability, each targeting
the workload (crossplane) cluster. Ported from
[`stuttgart-things/flux` — `cicd/crossplane/capabilities`](https://github.com/stuttgart-things/flux/tree/main/cicd/crossplane/capabilities).

The Configurations (`../configs`) are a fleet fact. A package alone does nothing:
without a `ClusterProviderConfig` the provider does not know where to connect,
without credentials it cannot log in, and without an `EnvironmentConfig` it does
not know which node, datastore or template to use. Those three are **cluster
facts** — they are what this chart ships.

| Capability (`capabilities.<key>`) | Source | Renders on the cluster |
|---|---|---|
| `vspherevm` | `ghcr.io/stuttgart-things/charts/vspherevm` `0.13.0` | ClusterProviderConfig, ClusterSecretStore + `vsphere-creds-<env>` ExternalSecret, placement EnvironmentConfig |
| `proxmoxvm` | `ghcr.io/stuttgart-things/charts/proxmoxvm` `0.13.0` | ClusterProviderConfig, ClusterSecretStore + `proxmox-creds-<env>` / cloud-init password ExternalSecrets, DRC `provider-proxmox-bpg`, EnvironmentConfig |
| `ansibleRun` | `ghcr.io/stuttgart-things/charts/ansible` `0.9.33` | `ansible-run-defaults` EnvironmentConfig (label always `default`), `ansible-credentials` ExternalSecret, ManagedNamespace, provider-kubernetes RBAC |
| `packer` | `ghcr.io/stuttgart-things/charts/packer` `0.3.1` | `packer-build-defaults`, `packer-release-defaults`, `packer-release-labda` EnvironmentConfigs, `packer-ca-certs` ConfigMap |
| `harvesterVm` | [`./harvester-vm`](harvester-vm/values.yaml) in this repo (no chart exists) | `harvester-vm-defaults` EnvironmentConfig |

## What differs from flux

- **Credentials via ESO**, `secretStore.backend: eso` (ansible: `sshCredentials.backend: eso`) instead of sops-git. vspherevm/proxmoxvm render their own `ClusterSecretStore` (`vault-cicd-<hypervisor>-<env>`) against the cluster's Vault Kubernetes auth mount — `secretStore.authMountPath`, **required** when either is enabled (the AppSet injects `<cluster>-eso`). Needs ESO, the `eso` Vault role, and the `vault-pki-ca` Secret in `cert-manager`.
- **Sets are presets**: `presets/{labda-vsphere,labul-proxmox,labda-vsphere-labul-proxmox,harvester-demo}.yaml` (use as `valueFiles`), or one opt-in label per capability through the platform AppSet.

## Configurations are NOT installed here

`configuration.install: false` (ansible: `configuration.enabled: false`) and proxmoxvm's `provider.install: false` are hardcoded. A chart-installed Configuration lands under the chart's short name while the same OCI path is (or will be) present under the dependsOn-derived name — a duplicate lock node, and every package on the cluster goes `Healthy=False` while `Installed` stays True. Packages belong to `../configs` (one family per cluster).

**Gap:** neither `../configs` list (default nor `profiles/flux.yaml`) contains `vspherevm`, `proxmoxvm`, `packer-build` or `packer-release` today — on flux those come from the machinery profile. A cluster using those capabilities needs them added to its configs list (derived names, e.g. `stuttgart-things-crossplane-configurations-vspherevm`), or, knowingly, `extraValues: {configuration: {install: true}}`.

## Values

| Key | Default | Purpose |
|---|---|---|
| `project` | `default` | AppProject of the rendered Applications |
| `destination.server` *or* `.name`, `.namespace` | in-cluster / `crossplane-system` | Workload cluster |
| `applicationName` | `cxp-cap-<sha1(dest)[0:8]>` | Prefix of the child names (`<prefix>-<capability>`) |
| `catalog.repoURL` / `.targetRevision` | this repo / `HEAD` | Where `./harvester-vm` is read from |
| `chartRepository` | `ghcr.io/stuttgart-things/charts` | OCI registry of the capability charts |
| `tektonNamespace` | `tekton-ci` | PipelineRun namespace (ansible-run, packer) |
| `secretStore.authMountPath` | `""` | Vault k8s auth mount of this cluster; required for vspherevm/proxmoxvm |
| `capabilities.<cap>.enabled` | `false` | Toggle per capability |
| `capabilities.<cap>.chartVersion` | see table | OCI chart version (Renovate-tracked) |
| `capabilities.{vspherevm,proxmoxvm,ansibleRun}.environment` | `labda` / `labul` / `labda` | `environments.<key>` of the chart |
| `capabilities.ansibleRun.storageClass` | `openebs-hostpath` | PipelineRun workspace PVC |
| `capabilities.ansibleRun.secretStoreName` | `""` | Store for `ansible-credentials`; empty = chart's `vault-cicd-vsphere-<env>` (rendered only by vspherevm) |
| `capabilities.<cap>.extraValues` | `{}` | Deep-merged over the computed upstream values (lists replace) |
| `capabilities.harvesterVm.*` | see `values.yaml` | EnvironmentConfig fields; defaults fit only a Harvester that IS the cluster |
| `syncPolicy` | automated + retry | Applied to every child |

`ansibleRun` is wave 2 (its ExternalSecret reads the store vspherevm/proxmoxvm render at wave 1).

## Fleet

`platforms/cicd/appset-crossplane-capabilities.yaml` — one ApplicationSet per capability, opt-in label `cicd-platform/crossplane-cap-<vspherevm|proxmoxvm|ansible-run|packer|harvester-vm>: "true"`, parameters from `cicd-platform.stuttgart-things.com/crossplane-cap-*` annotations (listed in the file header). A cluster still carrying an old `cicd-platform/crossplane-{ansible,proxmoxvm,vspherevm}: "true"` label (monorepo path, `appset-cxp-*.yaml`) is excluded for that capability.

## Example

```yaml
source:
  repoURL: https://github.com/stuttgart-things/argocd.git
  targetRevision: main
  path: cicd/crossplane/capabilities
  helm:
    valueFiles:
      - presets/labda-vsphere-labul-proxmox.yaml
    valuesObject:
      applicationName: cxp-cap-my-cluster
      project: my-cluster
      destination:
        server: https://<cluster-api>:6443
        namespace: crossplane-system
      secretStore:
        authMountPath: my-cluster-eso
destination:
  server: https://kubernetes.default.svc
  namespace: argocd
```
