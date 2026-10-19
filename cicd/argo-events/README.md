# cicd/argo-events

The [Argo Events](https://argoproj.github.io/events/) controller from the
argo-helm chart (`argo-events` **2.4.27**, app v1.9.11), as an opt-in cicd
platform (`platforms/cicd/appset-argo-events.yaml`, gate
`cicd-platform/argo-events`).

| Application | Source | Renders |
|---|---|---|
| `<app>` | `argoproj.github.io/argo-helm/argo-events` | CRDs (EventBus, EventSource, Sensor) + cluster-wide controller |

Controller only. **EventBus, EventSources and Sensors are user content**:
nothing here creates them, so a fresh install has no bus and no sources. A
Sensor that triggers Argo Workflows needs `cicd/argo-workflows` (gate
`cicd-platform/argo-workflows`) and a ServiceAccount allowed to create
`workflows.argoproj.io`. No route: the controller has no UI, and a webhook
EventSource brings its own Service, which needs its own HTTPRoute.

The admission webhook is off (upstream default); turn it on with
`extraValues.webhook.enabled: true`.

Renders nothing while `enabled` is false (the default; the AppSet sets it).

## Values

| Value | Default | Notes |
|---|---|---|
| `enabled` | `false` | renders nothing when false |
| `project`, `destination.*` | `default`, in-cluster/`argo-events` | |
| `applicationName` | `argo-events-<sha8(server)>` | |
| `cascadingDelete` | `false` | opt-out stops managing instead of deleting |
| `chartVersion` | `2.4.27` | renovate-tracked |
| `extraValues` | `{}` | deep-merged over the computed upstream values |
| `syncPolicy` | automated, SSA, retry 5 | |
