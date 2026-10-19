# cicd/externalsecrets

Plain ExternalSecrets in one namespace, read from a ClusterSecretStore. The
app-of-apps charts in `cicd/` (dapr-workflows, harbor, zot) render one
Application per namespace pointing here, instead of each shipping its own
ExternalSecret chart.

```yaml
namespace: harbor
clusterSecretStoreName: vault-cicd
refreshInterval: 1h
secrets:
  - secretName: harbor-admin
    data:
      - secretKey: HARBOR_ADMIN_PASSWORD
        vaultSecretName: harbor
        property: admin_password
```

With `secrets: []` (the default) it renders nothing; with secrets and no store
it fails the render instead of producing ExternalSecrets that never sync.
