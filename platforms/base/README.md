# platforms/base

What every cluster gets regardless of what it runs — the components no single
app platform owns but several depend on.

```bash
kubectl apply -f platforms/base/application.yaml   # once, on the mgmt cluster
```

| AppSet | Component | Label |
|---|---|---|
| `appset-reloader` | Stakater Reloader, in `reloader` on the workload cluster | `base-platform/reloader` (opt-out) |

The umbrella label is `base-platform: 'true'`; components are opt-**out**, the
convention the [repo README](../README.md) describes — a component is deselected
only by an explicit `'false'`.

## Why Reloader is here

Every bundle that reads credentials from a store has the same problem: ESO
refreshes a Secret, and the Pods holding the old value go on holding it until
something restarts them. It is not one platform's concern, and it is not worth
installing three times.

[`platforms/tabletennis`](../tabletennis/) already named `infra/reloader/install`
as a precondition — a changed panel URL has to roll zaehlwerk — so until this
bundle existed the catalog asked for a component no bundle installed. That was
the gap this closes.

## It does nothing until a workload opts in

`autoReloadAll: false` in the chart, deliberately: a workload is reloaded only
when it carries `reloader.stakater.com/auto: "true"`. With the flag on, plus the
`watchGlobally: true` this install uses, one bad value from a failed ESO refresh
or a Vault hiccup would roll **every** Deployment on the cluster at once.
Credentials are worth that trade; arbitrary ConfigMaps are not.

So installing this bundle starts nothing by itself — it makes the annotation
mean something.

**On a cluster that already runs zaehlwerk, that is not nothing.**
`apps/zaehlwerk/install` stamps `reloader.stakater.com/auto: "true"` by default
(`reloader: true`), because zaehlwerk reads its ConfigMap and the panel Secret
only at start — a changed panel URL otherwise sits unnoticed until someone
restarts the Deployment by hand, which is what happened on labda-dev-a. So the
controller has work from the moment it lands there. That is the point of it, but
check that Application's sync status on the first rollout rather than assuming.

> [!NOTE]
> **Why `reloadStrategy: annotations` and not `env-vars`.** Reloader has to write
> into the live Deployment either way. With this strategy it writes under
> `spec.template.metadata.annotations`, a path no chart here declares — Argo's
> three-way diff treats it as a field it does not own, and `selfHeal` leaves it
> alone. The `env-vars` strategy injects a hash into the container spec, which
> Argo *does* render from Git: the two would then take turns restarting the Pod.
>
> If a workload ever does turn OutOfSync from a reload, the fix is an
> `ignoreDifferences` entry on the Application that owns it, for whatever
> Reloader stamped.

The bundle also does not change how anything is deployed. The annotation is put
there by each app's own chart; this only supplies the controller that reads it.

## Versions

`chartVersion` is not overridden by the AppSet — it inherits
`infra/reloader/install/values.yaml`, which is deliberately held at the version
`stuttgart-things/flux` runs in `infra/reloader`, so both fleets stay on one
controller version. Renovate keeps that single copy bumped.

## Opt-out and teardown

`base-platform/reloader: "false"` removes the parent Application and leaves the
controller running, unmanaged — no `preserveResourcesOnDeletion`, because what
that flag preserves on an app-of-apps AppSet are child *Applications*, and those
orphans then block their AppProject ([#324](https://github.com/stuttgart-things/argocd/issues/324)).

To actually remove Reloader, delete the parent Application by hand with the
cascade you want. Annotated workloads are unaffected — the annotation simply
stops meaning anything.

## Related

- [`infra/reloader`](../../infra/reloader/) — the chart this bundle renders.
- [`platforms/tabletennis`](../tabletennis/) — the bundle that wanted it first.
