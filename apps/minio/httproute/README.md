# apps/minio/httproute

Internal sub-chart used by [`apps/minio/install`](../install/). Renders a list of Gateway API `HTTPRoute` resources from a single list-shaped values input. Not intended for direct consumption — the parent `minio` app-of-apps Application drives its values via `helm.valuesObject`.

Kept as a standalone chart so the rendered `minio-httproute` Argo `Application` can load it from this repo by path and pass values derived from the parent's `console.hostname` / `api.hostname` / `httpRoute.gateway`.

See `values.yaml` for the shape and `values.schema.json` for strict validation.
