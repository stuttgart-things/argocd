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
├── cloud-credentials/   plain Helm chart — renders an ExternalSecret that materialises `cloud-credentials`
└── README.md
```

Typical combinations:

| Want | Applications to create |
|---|---|
| Velero with a pre-provisioned `cloud-credentials` Secret | `install` |
| Velero with `cloud-credentials` synced from Vault via ESO | `cloud-credentials`, `install` |

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
| `chartVersion` | `9.0.0` | Upstream vmware-tanzu/velero chart version |
| `pluginAws.image` / `tag` | `velero/velero-plugin-for-aws` / `1.14.0` | Plugin image loaded into `/target` as an initContainer |
| `credentials.existingSecret` | `cloud-credentials` | Pre-existing Secret in the velero namespace holding the AWS-style INI under key `cloud` |
| `trustBundle.configMapName` / `mountPath` | `cluster-trust-bundle` / `/etc/ssl/custom` | Optional CA bundle mount (harmless if absent) |
| `sslCertDir` | `""` | `SSL_CERT_DIR` env var. Empty = system CAs; set to `trustBundle.mountPath` to activate the bundle |
| `backup.bucket` | placeholder | **Required** — S3 bucket for the default `BackupStorageLocation` |
| `backup.s3Url` | placeholder | **Required** — S3 endpoint (MinIO / R2 / S3) |
| `backup.region` / `s3ForcePathStyle` / `insecureSkipTLSVerify` | `minio` / `true` / `false` | S3 config knobs |
| `snapshot.region` | `minio` | Region for the default `VolumeSnapshotLocation` |
| `snapshotsEnabled` | `false` | Volume snapshots |
| `deployNodeAgent` | `false` | File-system backup daemon (restic/kopia) |
| `metrics.enabled` | `true` | Velero Prometheus metrics |
| `metrics.serviceMonitor.enabled` | `false` | Render a `ServiceMonitor` (needs Prometheus Operator) |
| `metrics.serviceMonitor.additionalLabels` | `{release: prometheus}` | Label used by kube-prometheus-stack's `serviceMonitorSelector` |
| `schedules` | `{}` | Velero `Schedule` definitions rendered by the chart |
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
        secretPath: kv/data/velero/s3
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
| `secretPath` | `kv/data/velero/s3` | Vault KV v2 path holding the S3 credentials |
| `properties.accessKey` / `secretKey` | `access_key` / `secret_key` | Property names inside the KV entry |

The rendered target Secret is always called `cloud-credentials` (hard-coded —
that is what the upstream chart's `credentials.existingSecret` defaults to and
what this catalog's `install` chart passes through).

## Fleet — one `ApplicationSet` per piece

Each entry is a self-contained chart, so fleet mode is one `ApplicationSet` per
piece. Install velero everywhere a cluster has `install/velero: "true"`; layer
`cloud-credentials` with its own label.

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
