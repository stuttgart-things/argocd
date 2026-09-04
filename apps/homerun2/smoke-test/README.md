# apps/homerun2/smoke-test

A one-shot `Job` that proves a deployed **omni-pitcher** actually works — the
`helm test` idea, without Helm. Rendered as an ArgoCD **PostSync hook**, so it
re-runs on every sync of its Application and a failed assertion fails the sync.

Consumed as a sub-Application by [`apps/homerun2/install`](../install/) via
`smokeTest.enabled: true`, or standalone with `helm template`.

## What it asserts

Two passes over the same API. The **internal** pass talks to the in-cluster
Service; the **external** pass repeats it through the public HTTPRoute, which
additionally exercises the Gateway, the route's hostname match and the TLS
chain.

| # | Probe | Passes when |
|---|---|---|
| 1 | `GET /health` on `http://<service>:<port>` | 200 within `healthCheck.attempts × intervalSeconds` |
| 2 | `POST /pitch` **without** an `Authorization` header | status == `unauthenticated.expectStatus` (401) |
| 3 | `POST /pitch` with the bearer token, once per `events` entry | 200/201/202 |
| 4-6 | the same three through `https://<external.hostname>` | as above, with the certificate verified |

Probe 2 is the one worth having. A stack whose auth-token Secret never
materialised looks perfectly healthy — pod Running, `/health` 200 — while
`/pitch` accepts anything from anyone. Only a negative probe catches that.

## Reaching the public hostname from inside the cluster

A Cilium L2-announced LoadBalancer VIP is **not reachable from Pods on the same
cluster**. A Job that simply curls the public FQDN therefore hangs until its
retry budget runs out, even though the route works fine from outside.

`external.connectTo` solves it with `curl --connect-to`: the request is dialled
at the gateway's own Service while the original hostname is kept for SNI, the
`Host` header and certificate validation. Everything except the VIP itself is
exercised. `apps/homerun2/install` derives the value from `httpRoute.gateway`
(`cilium-gateway-<gateway>.<ns>.svc.cluster.local`).

## TLS

`external.caConfigMap` (default `cluster-trust-bundle`, the trust-manager
Bundle) is mounted at `/etc/ssl/bundle` and passed as `--cacert`. The bundle
must contain the CA that issued the **gateway** certificate.

> On clusterbook clusters the Vault PKI root is only added to that bundle when
> the label `network-platform/cert-manager-vault-pki` is `'true'` (see
> `platforms/network/appset-trust-manager-bundle.yaml`). A cluster that gets its
> Vault issuer from elsewhere — e.g. the ClusterStack XR's `vaultIssuer` branch,
> which creates `vault-pki-k8s` — has that label `'false'` and therefore a trust
> bundle that cannot verify its own gateway. The external pass fails with
> `unable to get local issuer certificate`, correctly. Fix the bundle rather
> than reaching for `external.insecure: true`, which would prove routing while
> hiding a broken chain.

## Security context

`podSecurityContext.runAsUser` must stay **numeric**. `curlimages/curl` declares
`USER curl_user`, and with `runAsNonRoot: true` but no numeric uid the kubelet
cannot prove the user is non-root: the container never starts, and the only
evidence is `CreateContainerConfigError` on the pod — no logs, no event that
names the chart.

## Re-running

The Job is a hook with `hook-delete-policy: BeforeHookCreation`, so the finished
Job and its logs survive until the next run:

```bash
kubectl -n <ns> logs job/<release>-smoke-test
argocd app sync <release>-smoke-test     # or hit Sync in the UI
```

Set `hook.enabled: false` to render a plain Job instead (runs once on create;
ArgoCD then treats it as ordinary desired state).

## Values

See `values.yaml` for the annotated defaults and `values.schema.json` for the
schema. The fields most consumers touch: `external.enabled`, `external.hostname`
(supplied by the install chart from `omniPitcher.hostname`), `events`, and
`unauthenticated.expectStatus`.
