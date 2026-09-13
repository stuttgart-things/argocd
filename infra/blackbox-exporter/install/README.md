# blackbox-exporter

Renders one ArgoCD `Application` over the upstream
`prometheus-community/prometheus-blackbox-exporter` chart, together with the
`ServiceMonitor` per target that turns a URL into a scrape, and generic
`PrometheusRule`s over the resulting `probe_*` metrics.

## What it is for

Watching a service the way its users reach it: DNS, the gateway, the
certificate and the application, from outside the cluster the service runs in.
An in-cluster metric cannot see any of the first three, and a perfectly healthy
pod behind a broken HTTPRoute is a failure mode that has already happened here.

It is therefore the cheapest useful monitoring for a workload on a cluster with
no Prometheus of its own — no agent there, no code change, nothing to deploy
beside the workload.

## Usage

```yaml
project: default
destination:
  server: https://kubernetes.default.svc
  namespace: monitoring

targets:
  - name: example
    url: https://example.com/readyz
    module: http_2xx
```

Probe an endpoint that means what you want to alert on. `/readyz` beats `/`
wherever it also checks the dependencies the service cannot work without — a
service that answers 200 on `/` with a dead database is not up.

## Two things worth knowing before adding a target

**Certificates from an internal CA.** The exporter image trusts the public
roots and nothing else, so a host whose certificate comes from an internal CA
fails the probe on the handshake — which looks exactly like an outage. Use
`module: http_2xx_untrusted_ca` for those. It still exports
`probe_ssl_earliest_cert_expiry`, so the expiry alert keeps working; what it
gives up is validity. Mounting the CA bundle (trust-manager publishes one)
turns that back on, and is the better answer once someone wires it.

**The alerts assume a route.** They carry `severity: critical` and `warning`
because kube-prometheus-stack on the platform cluster routes
`severity =~ "warning|critical"` onward and drops the rest. Where Alertmanager
is disabled or routes elsewhere, the rules still fire and show in the
Prometheus UI — they simply reach nobody. Check the route before believing the
alert works; a rule that fires into nothing is worse than no rule, because it
looks like coverage.

## Release drift targets

A target with `additionalMetricsRelabels: {probe_kind: release}` checks which
version a service runs rather than whether it answers. Pair it with a module
that fetches the endpoint the service reports its version on and sets
`fail_if_body_not_matches_regexp` to the release it should run:

```yaml
config:
  modules:
    myapp_newest_release:
      prober: http
      http:
        preferred_ip_protocol: ip4
        fail_if_body_not_matches_regexp:
          - '^v1.2.3\s*$'

targets:
  - name: myapp-version
    url: https://myapp.example.com/version
    module: myapp_newest_release
    additionalMetricsRelabels:
      probe_kind: release
```

The label keeps the target out of `BlackboxProbeFailed` and
`BlackboxCertificateExpiringSoon` — a release behind is not an outage — and
puts it into `BlackboxReleaseDrift` at `severity: info`. That rule also counts a
404, so a release older than the version endpoint shows as drift instead of
passing unnoticed.

The expected version is only as current as whatever writes it. Keep it moving
without a human (a Renovate rule with automerge), or it lags exactly like the
deployment pin it is meant to watch.
