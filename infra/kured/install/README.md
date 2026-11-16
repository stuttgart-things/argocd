# kured

[kured](https://kured.dev) (Kubernetes Reboot Daemon, CNCF) — reboots a node
when the OS asks for it, one node at a time, with cordon and drain.

## Why this exists

Ubuntu writes `/var/run/reboot-required` after a kernel or libc update and then
waits for someone to reboot. On a cluster that someone never comes: the fleet
analysis found nine VMs with pending reboots, some carrying two kernel
generations (stuttgart-things/stuttgart-things#4590).

kured does not install anything. Updates come from unattended-upgrades on the
node; kured only does the reboot that follows, safely.

## What one reboot looks like

1. Every `period` (1h) each kured pod checks the sentinel on its node.
2. Inside the window (`rebootDays`, `startTime`–`endTime`, `timeZone`) it takes
   the cluster-wide lock — an annotation on the kured DaemonSet — so only
   `concurrency` nodes reboot at once.
3. Cordon, drain (`drainTimeout`), reboot, wait for the node, uncordon, release
   the lock.

Defaults here: weekdays 04:00–06:00 UTC, one node at a time, drain timeout 15m,
then `forceReboot`.

## Single-node clusters and stuck drains

On a single-node cluster the drain has nowhere to move pods to, and a
single-instance CloudNativePG cluster keeps a PodDisruptionBudget on its
primary. Both block a drain indefinitely. `forceReboot: true` reboots after
`drainTimeout` anyway — the pods come back with the node. Set it to `false` to
leave such a node cordoned instead.

## Deploy it on the workload cluster

`destination` must be the workload cluster: kured reboots the nodes it runs on.
Rolled out by `platforms/base/appset-kured.yaml`, opt-**in** per cluster with
`base-platform/kured: "true"`.

## Values

| Value | Default | |
|---|---|---|
| `chartVersion` | `6.1.0` | upstream chart (`kubereboot/charts`) |
| `period` | `1h` | sentinel check interval |
| `rebootDays` / `startTime` / `endTime` / `timeZone` | mo–fr, `04:00`–`06:00`, `UTC` | reboot window |
| `concurrency` | `1` | nodes rebooting at once |
| `drainTimeout` / `forceReboot` | `15m` / `true` | see above |
| `blockingPodSelector` | `[]` | pods that block a reboot (e.g. running CI jobs) |
| `preferNoScheduleTaint` | `weave.works/kured-node-reboot` | taint while the node waits |
| `annotateNodes` | `true` | reboot annotations on the node |
| `prometheusUrl` / `alertFilterRegexp` | empty | skip while alerts fire |
| `notifyUrl` | empty | plain shoutrrr URL (no secrets: it lands in the Application spec) |
| `notify.*` | off | messages to the central homerun2, see below |
| `cluster` / `catalog` | — | cluster name for the messages; this repo for the notify Application |
| `tolerations` | control-plane, master, etcd, CriticalAddonsOnly | run on server nodes too |
| `extraValues` | `{}` | deep-merged into the upstream values |

## Messages to homerun2 (`notify`)

With `notify.enabled` kured reports every node it handles to the central
omni-pitcher (`/pitch`): "Draining node X", "Rebooting node X", "Node X rebooted
& uncordoned successfully!" -- system `kured`, author `kured-<cluster>`, tags
`kured,cluster=<cluster>`, severity `notify.severity` (info).

```
infra/kured/install  ──>  Application <name>-notify  (infra/kured/resources, wave -11)
                            ├─ ExternalSecret kured-notify   token from notify.secretStore / remoteKey
                            │    └─ Secret kured-notify: url = generic://<omni>/pitch?@Authorization=Bearer+<token>&template=json&$title=…&$system=kured…
                            └─ ConfigMap kured-central-ca    notify.centralCa (optional)
                     ──>  Application <name>             kured DaemonSet
                            env KURED_NOTIFY_URL  <- Secret kured-notify/url   (kured reads every flag as KURED_<FLAG>)
                            env SSL_CERT_DIR=/etc/kured-ca <- ConfigMap         (Go keeps the image's system bundle file)
                            annotation secret.reloader.stakater.com/reload: kured-notify
```

- The token never sits in Git or an Application spec: the ExternalSecret
  builds the whole URL.
- The pods wait for the Secret (non-optional `secretKeyRef`) and start on their
  own once it exists. Reloader restarts them when the Secret changes.
- shoutrrr v0.8.0 (kured 1.23.0), tested: `generic://`, not `generic+https://`
  -- with the custom scheme `template=json` is passed to the target and the body
  is plain text. The title goes in as `$title`, because `title=` never reaches
  the JSON, and omni-pitcher requires a title.

In `platforms/base/appset-kured.yaml` the switch is `base-platform/kured-notify`,
and URL, CA, token entry and store come from the cluster's annotations (the
K8sGPT reporter's, unless kured-specific ones are set).
