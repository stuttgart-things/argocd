# komoplane

[Komoplane](https://github.com/komodorio/komoplane) is a read-only web UI for
Crossplane claims, composites, managed resources and their relations. This app-of-apps
chart wraps the upstream `komoplane` Helm chart (https://helm-charts.komodor.io,
**0.1.8**, app 0.2.1) and adds an optional Gateway API HTTPRoute sub-Application. It is
a port of `stuttgart-things/flux` `cicd/komoplane`.

## Komoplane has no authentication

The upstream chart has no authentication of any kind. Being read-only is the only
protection, so anything the Gateway exposes can be read by anyone who reaches the
hostname. Attach the route only to a lab-internal Gateway.

## Layout

```
cicd/komoplane/
├── install/     renders Application "komoplane-<hash>" (wave 5) and, with httpRoute.enabled,
│                "komoplane-<hash>-httproute" (wave 10)
└── httproute/   leaf: HTTPRoute -> Service komoplane:8090
```

Komoplane needs **Crossplane** on the same cluster. Without it, the UI starts and shows
an empty tree.

## Values

| Value | Default | Notes |
|---|---|---|
| `applicationName` | `komoplane-<sha8(destination)>` | route App = `<this>-httproute` |
| `project`, `catalog.*`, `destination.*` | `default`, this repo/`HEAD`, in-cluster/`komoplane` | |
| `chartVersion` | `0.1.8` | renovate-tracked, same as Flux |
| `debug`, `mrCacheTTL`, `mrdCacheTTL` | `false`, `1m`, `5m` | upstream `komoplane:` block |
| `replicaCount` | `1` | |
| `resources` | 200m/256Mi req, 1/1Gi lim | |
| `httpRoute.enabled` | `false` | bool or `"true"`/`"false"` |
| `httpRoute.hostname` | `""` | required when enabled |
| `httpRoute.gateway.{name,namespace,sectionName}` | `cilium-gateway` / `default` / `""` | |
| `extraValues` | `{}` | deep-merged over the computed upstream values |
| `syncPolicy` | automated, SSA, retry 5 | |

The upstream Ingress is always off. Use `httpRoute`.

## Platform

`platforms/cicd/appset-komoplane.yaml`, opt-in with `cicd-platform/komoplane: "true"`
(and `cicd-platform/crossplane` not set to `"false"`). The route
`komoplane.<fqdn>` on `<cluster>-gateway` is rendered only when the cluster has a
`clusterbook.stuttgart-things.com/fqdn` annotation. Without it, use
`kubectl -n komoplane port-forward svc/komoplane 8090`.
