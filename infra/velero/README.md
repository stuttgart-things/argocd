# infra/velero

Catalog entries for [Velero](https://velero.io/) — cluster backup/restore against
S3-compatible object storage via the `velero-plugin-for-aws` plugin (works with
MinIO out of the box; same plugin handles real AWS S3, Cloudflare R2, Wasabi…).

Two independently deployable pieces — consumers create one ArgoCD `Application`
per piece they need.

## Layout

```
infra/velero/
├── install/             app-of-apps — renders Application "velero" → vmware-tanzu/velero
│                        (+ optional "<name>-secrets" → cloud-credentials/, externalSecrets.enabled)
├── cloud-credentials/   plain Helm chart — renders an ExternalSecret that materialises `cloud-credentials`
└── README.md
```

Typical combinations:

| Want | Applications to create |
|---|---|
| Velero with a pre-provisioned `cloud-credentials` Secret | `install` |
| Velero with `cloud-credentials` synced from Vault via ESO | `install` with `externalSecrets.enabled: true` (renders the `cloud-credentials` Application itself), or both by hand |
| Fleet: every cluster labelled `storage-platform/velero: "true"` | nothing — [`platforms/storage/appset-velero.yaml`](../../platforms/storage/appset-velero.yaml) |

## install/

App-of-apps Helm chart packaging the upstream `vmware-tanzu/velero` chart. The
consumer `Application` points at `infra/velero/install`; the chart renders a
child `Application` targeting `https://vmware-tanzu.github.io/helm-charts` with a
computed `valuesObject`.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: velero
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: infra/velero/install
    helm:
      values: |
        project: my-cluster
        destination:
          server: https://<cluster-api>:6443
          namespace: velero
        backup:
          bucket: my-cluster-velero
          s3Url: https://minio.example.com
          region: minio
          s3ForcePathStyle: true
          insecureSkipTLSVerify: false
        sslCertDir: /etc/ssl/custom
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

The Secret referenced by `credentials.existingSecret` (default `cloud-credentials`)
must exist in the velero namespace **before** the velero pods start. Provision it
out-of-band (static Secret, sealed-secrets, Terraform, …) or layer in the
`cloud-credentials/` chart from this catalog.

### install values reference

See `install/values.yaml` for defaults and `install/values.schema.json` for the
full JSON Schema. Invalid overrides fail the sync loudly.

| Key | Default | Purpose |
|---|---|---|
| `project` | `default` | ArgoCD AppProject for the rendered Application |
| `destination.server` / `namespace` | `https://kubernetes.default.svc` / `velero` | Target workload cluster + namespace |
| `catalog.repoURL` / `targetRevision` | this repo / `HEAD` | Where the `-secrets` Application loads `infra/velero/cloud-credentials` from |
| `chartVersion` | `12.2.1` | Upstream vmware-tanzu/velero chart version |
| `pluginAws.image` / `tag` | `velero/velero-plugin-for-aws` / `1.14.4` | Plugin image loaded into `/target` as an initContainer |
| `credentials.existingSecret` | `cloud-credentials` | Pre-existing Secret in the velero namespace holding the AWS-style INI under key `cloud` |
| `trustBundle.configMapName` / `mountPath` | `cluster-trust-bundle` / `/etc/ssl/custom` | Optional CA bundle mount (harmless if absent) |
| `sslCertDir` | `""` | `SSL_CERT_DIR` env var. Empty = system CAs; set to `trustBundle.mountPath` to activate the bundle |
| `backup.bucket` | placeholder | **Required** — S3 bucket for the default `BackupStorageLocation` |
| `backup.s3Url` | placeholder | **Required** — S3 endpoint (MinIO / R2 / S3) |
| `backup.region` / `s3ForcePathStyle` / `insecureSkipTLSVerify` | `minio` / `true` / `false` | S3 config knobs |
| `backup.prefix` | `""` | Directory inside the bucket. Several clusters share one bucket with a prefix each; without one they sync each other's backups in |
| `snapshot.region` | `minio` | Region for the default `VolumeSnapshotLocation` |
| `snapshotsEnabled` | `false` | Volume snapshots |
| `deployNodeAgent` | `false` | File-system backup daemon (restic/kopia) |
| `metrics.enabled` | `true` | Velero Prometheus metrics |
| `metrics.serviceMonitor.enabled` | `false` | Render a `ServiceMonitor` (needs Prometheus Operator) |
| `metrics.serviceMonitor.additionalLabels` | `{release: prometheus}` | Label used by kube-prometheus-stack's `serviceMonitorSelector` |
| `schedules` | `{}` | Velero `Schedule` definitions rendered by the chart |
| `defaultSchedule.cron` | `""` | One whole-cluster Schedule (`velero-<name>`), mirroring Flux's `daily-all`. Empty = none |
| `defaultSchedule.name` / `ttl` / `excludedNamespaces` | `daily-all` / `720h0m0s` / kube-system, kube-public, kube-node-lease | Its name, retention and excluded namespaces. Metadata only: no snapshots, no file-system backup |
| `externalSecrets.enabled` | `false` | Render `<applicationName>-secrets` (sync-wave -5) → `cloud-credentials/`, so one parent brings Velero and its Secret |
| `externalSecrets.secretStore.kind` / `name` | `ClusterSecretStore` / `""` | Store to read from; `name` required when enabled |
| `externalSecrets.remoteKey` | `velero` | Entry NAME under the store's mount (never a `…/data/…` path) |
| `externalSecrets.accessKeyProperty` / `secretKeyProperty` | `access_key` / `secret_key` | Properties inside the entry |
| `upgradeJob.enabled` | `false` | Upstream upgrade Job (off for GitOps installs — races with Helm release lifecycle) |
| `cleanUpCRDs` | `false` | Delete CRDs on uninstall (off — keeps backup metadata around) |
| `kubectl.image.repository` / `tag` | `docker.io/bitnamilegacy/kubectl` / `1.33.4` | kubectl image used by the chart's CRD pre-install/pre-upgrade hook (bitnami sunset their free Docker Hub catalogue) |
| `extraValues` | `{}` | Deep-merged on top of the computed upstream `valuesObject` |
| `syncPolicy` | automated + retry | Applied to the rendered child Application |

## cloud-credentials/

Plain Helm chart that renders one `ExternalSecret` materialising the
`cloud-credentials` Secret consumed by `velero-plugin-for-aws`. Reads
`access_key` / `secret_key` properties from a Vault KV path via an existing
`(Cluster)SecretStore`. Requires `external-secrets` to be installed on the
cluster (see `infra/external-secrets`).

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: velero-cloud-credentials
  namespace: argocd
spec:
  project: my-cluster
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: infra/velero/cloud-credentials
    helm:
      values: |
        namespace: velero
        secretStoreRef:
          name: vault-my-cluster
          kind: ClusterSecretStore
        secretPath: velero
  destination:
    server: https://<cluster-api>:6443
    namespace: velero
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

### cloud-credentials values reference

| Key | Default | Purpose |
|---|---|---|
| `name` | `velero-cloud-credentials` | ExternalSecret name |
| `namespace` | `velero` | Namespace the ExternalSecret + materialised Secret live in (must match `install` `destination.namespace`) |
| `refreshInterval` | `1h` | How often ESO re-reads Vault |
| `secretStoreRef.name` / `kind` | `vault-cluster` / `ClusterSecretStore` | Existing (Cluster)SecretStore reference |
| `secretPath` | `velero` | Entry NAME under the store's mount holding the S3 credentials. Not a path: the store composes `<mount>/data/<entry>`, so `kv/data/…` resolved to nothing (schema now refuses `/data/`) |
| `properties.accessKey` / `secretKey` | `access_key` / `secret_key` | Property names inside the KV entry |

The rendered target Secret is always called `cloud-credentials` (hard-coded —
that is what the upstream chart's `credentials.existingSecret` defaults to and
what this catalog's `install` chart passes through).

## Fleet

The catalog ships one: [`platforms/storage/appset-velero.yaml`](../../platforms/storage/appset-velero.yaml),
opt-in per cluster with `storage-platform/velero: "true"` — bucket, endpoint,
store, entry and schedule come from cluster annotations (see
[`platforms/storage/README.md`](../../platforms/storage/README.md)). The sketch
below is the shape for a fleet outside that bundle.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: velero
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - clusters:
        selector:
          matchLabels:
            install/velero: "true"
  template:
    metadata:
      name: 'velero-{{ .name }}'
    spec:
      project: '{{ .name }}'
      source:
        repoURL: https://github.com/stuttgart-things/argocd.git
        targetRevision: main
        path: infra/velero/install
        helm:
          values: |
            project: {{ .name }}
            destination:
              server: {{ .server }}
              namespace: velero
            backup:
              bucket: {{ .name }}-velero
              s3Url: {{ index .metadata.annotations "velero/s3Url" }}
      destination: { server: https://kubernetes.default.svc, namespace: argocd }
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

## Related

- Flux equivalent: [`stuttgart-things/flux` — `infra/velero`](https://github.com/stuttgart-things/flux/tree/main/infra/velero) — this catalog mirrors the Flux split (release + components/external-secret) as ArgoCD `install` + `cloud-credentials` charts.
- `infra/external-secrets` — needs to be installed first if you use the `cloud-credentials` chart.
