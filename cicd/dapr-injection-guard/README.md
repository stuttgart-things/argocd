# dapr-injection-guard

Recreates pods that asked for a Dapr sidecar (`dapr.io/enabled: "true"`) but
were admitted without one (no `dapr.io/sidecar-injected` label), because the
`dapr-sidecar-injector` was not serving yet when they were created
(stuttgart-things/stuttgart-things#4486).

A pod is mutated once, at admission, and the injector's webhook has
`failurePolicy: Ignore`: on a fresh cluster a worker synced in the same
minutes as Dapr can come up without `daprd` and crash-loop for good -- a
container restart never adds the sidecar, only a new pod does. Argo CD cannot
order it: `dapr` and `dapr-workflows` are separate ApplicationSets, and
Application health is not assessed, so sync waves do not wait for Dapr.

Every `schedule` (default 2 min) a CronJob checks, once
`dapr-sidecar-injector` in `daprNamespace` has an available replica, the pods
of each `watchNamespaces` entry and deletes those with the annotation but
without the label -- only pods with an owner, so their ReplicaSet recreates
them, injected this time. Nothing cluster-wide: a Role per watched namespace
(pods get/list/delete) and one in `daprNamespace` (that one Deployment, get).

Rendered by `cicd/dapr-workflows/install` (`injectionGuard`), which passes the
namespaces of the enabled workers.
