# reloader

Stakater Reloader — restarts a workload when a ConfigMap or Secret it references changes.

## Why this exists

A `Secret` consumed through `env.valueFrom.secretKeyRef` is injected once, when
the Pod is created, and **never** updates in a running container. A mounted
ConfigMap does update in place, but only on the filesystem — a process that
parses its config at startup keeps the old one.

Both cases look fine from the outside: the ExternalSecret is `SecretSynced`, the
ConfigMap holds the new value, the ArgoCD Application is `Synced/Healthy`, and
the workload quietly carries on with the old configuration.

Every homerun2 component reads its credentials as `env` from a `secretKeyRef`,
so today a rotation in Vault needs eight manual restarts and nothing signals
that they are due.

## What it does not replace

Where a chart *knows* the content it deploys, a content hash on the pod template
is the better tool: it is deterministic, it lives in Git, and the diff shows
that a Pod will roll before anything is applied. See
`apps/homerun2/install/templates/k8s-pitcher.yaml`.

Reloader covers what a chart cannot see — an out-of-band ConfigMap, or a Secret
whose value ESO pulls from Vault. The two are complementary.

## Deploy it on the workload cluster

Not on the management cluster. Reloader watches the ConfigMaps/Secrets and
patches the Deployments that live beside it; pointed at the ArgoCD cluster it
watches the wrong objects and never fires.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: reloader-<cluster>
  namespace: argocd
spec:
  project: <cluster>
  source:
    repoURL: https://github.com/stuttgart-things/argocd.git
    targetRevision: main
    path: infra/reloader/install
    helm:
      valuesObject:
        applicationName: reloader-<cluster>
        project: <cluster>
        destination:
          name: <cluster>
          namespace: reloader
```

## Opting a workload in

Nothing reloads without an explicit annotation — `autoReloadAll` is `false` on
purpose. Combined with `watchGlobally: true`, turning it on would let one bad
value from a failed ESO refresh restart every Deployment on the cluster at once.

```yaml
spec:
  template:
    metadata:
      annotations:
        reloader.stakater.com/auto: "true"
```

## Before annotating the first workload

Reloader patches the live Deployment, and ArgoCD renders that Deployment from
Git with `selfHeal: true`. Unless the owning Application ignores whatever
Reloader stamps, Argo reverts the patch and the two take turns restarting the
Pod.

`reloadStrategy: annotations` is chosen so the patch lands on the pod template's
annotations rather than in the container spec, which is the smaller thing to
ignore. Check what actually appears on the first annotated workload and add the
matching `ignoreDifferences` entry — do not assume the field name.

No workload in this repo is annotated yet, so nothing is being patched today.

## Version

Pinned to the version `stuttgart-things/flux` runs in its own `infra/reloader`,
so both fleets stay on one controller version.
