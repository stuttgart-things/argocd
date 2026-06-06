# apps/machinery-catalog-publisher

ArgoCD packaging for
[`machinery-catalog-publisher`](https://github.com/stuttgart-things/machinery-catalog-publisher) —
the service that streams live status from `machinery` and publishes it as
Backstage `Resource` entities to S3/MinIO.

## Charts

- **`install/`** — app-of-apps Helm chart. Renders an Argo `Application` that
  sources the publisher's OCI kustomize base
  (`ghcr.io/stuttgart-things/machinery-catalog-publisher-kustomize`), patches in
  the image, rewrites the namespace, patches the per-deploy `config.yaml` into
  the base ConfigMap, and wires the S3 connection Secret via `envFrom`. When
  `httpRoute.enabled`, it also renders the `httproute/` sub-Application; when
  `connectionSecretExternal.enabled`, the `externalsecret/` sub-Application.
- **`httproute/`** — Gateway API `HTTPRoute` to the publisher's metrics Service
  (port 8080).
- **`externalsecret/`** — ESO `ExternalSecret` that materializes the
  `minio-homerun` connection Secret (`S3_*` keys) from Vault via a
  ClusterSecretStore. MinIO creds come from Vault; endpoint/region/insecure are
  written as literals through the target template.

## Config

The publisher's runtime config (`interval`, `owner`, `source`, `sink`) is set
via `install` chart values under `config:` and patched into the base ConfigMap,
so each environment can target its own bucket / key-prefix without rebuilding
the kustomize base.

## Connection Secret

`connectionSecret` (default `minio-homerun`) names a Secret that must already
exist in the destination namespace, carrying `S3_ENDPOINT` / `S3_ACCESS_KEY` /
`S3_SECRET_KEY` / `S3_CA_BUNDLE` / `S3_INSECURE_SKIP_VERIFY`. The chart only
references it — credentials never land in git.

See [`platforms/machinery-catalog-publisher-pr-preview`](../../platforms/machinery-catalog-publisher-pr-preview)
for the per-PR preview ApplicationSet.
