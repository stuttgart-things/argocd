# apps/minio/charts/certs

Internal sub-chart used by [`apps/minio/chart`](../../chart/). Renders a list of cert-manager `Certificate` resources from a single list-shaped values input. Not intended for direct consumption — the parent `minio` app-of-apps Application drives its values via `helm.valuesObject`.

Kept as a standalone chart so the rendered `minio-certs` Argo `Application` can load it from this repo by path and pass values derived from the parent's `console.hostname` / `api.hostname` / `certs.issuer`.

See `values.yaml` for the shape and `values.schema.json` for strict validation.
