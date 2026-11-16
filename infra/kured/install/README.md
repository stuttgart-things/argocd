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
| `notifyUrl` | empty | shoutrrr URL for reboot messages |
| `tolerations` | control-plane, master, etcd, CriticalAddonsOnly | run on server nodes too |
| `extraValues` | `{}` | deep-merged into the upstream values |
