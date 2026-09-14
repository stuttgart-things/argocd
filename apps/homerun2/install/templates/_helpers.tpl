{{/*
homerun2.appName -- per-cluster base name (sha-suffixed) for Argo Applications.
Hashes whichever destination identifier is set: `destination.server` (URL) or
`destination.name` (Argo-registered cluster name). One of the two must be set.
*/}}
{{- define "homerun2.appName" -}}
{{- $destKey := .Values.destination.server | default .Values.destination.name -}}
{{- $defaultName := printf "homerun2-%s" (sha1sum $destKey | trunc 8) -}}
{{- .Values.applicationName | default $defaultName -}}
{{- end -}}

{{/*
homerun2.routesContent -- the effective omni-pitcher routing file.

Three outcomes, in precedence order:

  1. `omniPitcher.routesContent` set  -> that file, verbatim. An environment that
     needs alerts or github-events streams writes them here; see the block in
     values.yaml.
  2. `omniPitcher.tabletennisStream`  -> the minimal file that adds the one
     stream zaehlwerk needs, keeping `messages` as the catch-all.
  3. neither                          -> EMPTY, which is the single-stream path:
     no ConfigMap, no volume, no ROUTES_CONFIG, and REDIS_STREAM takes every
     message.

Why (2) exists at all: zaehlwerk pitches with `system: tabletennis` and nothing
routes that anywhere by default, so the scores land on `messages`. The pitch
returns 200, every Pod reports Healthy, and the tabletennis catcher shows an
empty stream — the failure has no error in it. A boolean is the smallest thing
that closes that gap without turning routing on for consumers who never asked
for it: flipping the default would move /pitch/grafana onto an `alerts` stream
that this chart's notification-catcher does not consume by default, and their
Teams notifications would stop.

Usage: include "homerun2.routesContent" .
*/}}
{{- define "homerun2.routesContent" -}}
{{- if .Values.omniPitcher.routesContent -}}
{{- .Values.omniPitcher.routesContent -}}
{{- else if .Values.omniPitcher.tabletennisStream -}}
# Rendered by apps/homerun2/install from `omniPitcher.tabletennisStream`.
# Every stream named below must appear in `streams`, else omni-pitcher fails
# startup.
streams:
  - messages
  - tabletennis
default_stream: messages
routes:
  # zaehlwerk pitches its scores with system: tabletennis; they go to the stream
  # it also switches the led-catcher onto during a match.
  - match:
      system: tabletennis
    stream: tabletennis
{{- end -}}
{{- end -}}

{{/*
homerun2.kustomizeRepo -- OCI repo URL for a homerun2-<name>-kustomize artifact.
The `oci://` prefix is required — Argo CD treats `repoURL` without it as a git
URL and fails with "failed to list refs: repository not found".
Usage: include "homerun2.kustomizeRepo" "omni-pitcher"
*/}}
{{- define "homerun2.kustomizeRepo" -}}
oci://ghcr.io/stuttgart-things/homerun2-{{ . }}-kustomize
{{- end -}}

{{/*
homerun2.imagePatch -- emits a Deployment patch that overrides the container image.
Usage: include "homerun2.imagePatch" (dict "name" "homerun2-omni-pitcher" "tag" "v1.6.2")
*/}}
{{- define "homerun2.imagePatch" -}}
{{- $patch := dict
      "apiVersion" "apps/v1"
      "kind" "Deployment"
      "metadata" (dict "name" .name)
      "spec" (dict "template" (dict "spec" (dict "containers" (list
        (dict "name" .name "image" (printf "ghcr.io/stuttgart-things/%s:%s" .name .tag))
      ))))
-}}
{{ toYaml $patch }}
{{- end -}}

{{/*
homerun2.redisPasswordPatch -- emits a Secret patch overriding the per-component
redis Secret's `password` key with the shared homerun2 redis password.
Usage: include "homerun2.redisPasswordPatch" (dict "secretName" "homerun2-omni-pitcher-redis" "password" .Values.redisPassword)
*/}}
{{- define "homerun2.redisPasswordPatch" -}}
{{- $patch := dict
      "apiVersion" "v1"
      "kind" "Secret"
      "metadata" (dict "name" .secretName)
      "stringData" (dict "password" .password)
-}}
{{ toYaml $patch }}
{{- end -}}

{{/*
homerun2.authTokenPatch -- emits a Secret patch overriding the per-component
auth-token Secret's `auth-token` key with the shared homerun2 auth token.
Usage: include "homerun2.authTokenPatch" (dict "secretName" "homerun2-omni-pitcher-token" "token" .Values.authToken)
*/}}
{{- define "homerun2.authTokenPatch" -}}
{{- $patch := dict
      "apiVersion" "v1"
      "kind" "Secret"
      "metadata" (dict "name" .secretName)
      "stringData" (dict "auth-token" .token)
-}}
{{ toYaml $patch }}
{{- end -}}

{{/*
homerun2.redisAddrPatch -- emits a Deployment patch injecting REDIS_ADDR + REDIS_PORT
env vars pointing at the co-deployed redis-stack Service. Optionally appends extra env entries.
Usage: include "homerun2.redisAddrPatch" (dict
  "name" "homerun2-omni-pitcher"
  "namespace" "homerun2"
  "extraEnv" (list (dict "name" "CATCHER_MODE" "value" "web"))
)
*/}}
{{- define "homerun2.redisAddrPatch" -}}
{{- $env := list
      (dict "name" "REDIS_ADDR" "value" (printf "redis-stack.%s.svc.cluster.local" .namespace))
      (dict "name" "REDIS_PORT" "value" "6379")
-}}
{{- range .extraEnv }}
  {{- $env = append $env . }}
{{- end }}
{{- $patch := dict
      "apiVersion" "apps/v1"
      "kind" "Deployment"
      "metadata" (dict "name" .name)
      "spec" (dict "template" (dict "spec" (dict "containers" (list
        (dict "name" .name "env" $env)
      ))))
-}}
{{ toYaml $patch }}
{{- end -}}

{{/*
homerun2.httpRouteJSONPatch -- emits JSON-Patch ops that replace parentRefs +
hostnames on a kustomize-rendered HTTPRoute. Used when a component's
kustomize OCI inlines its own HTTPRoute (Option B from
stuttgart-things/argocd#116) so Service + HTTPRoute land in the same apply.

JSON-Patch (not strategic merge) because parentRefs is a list with a
compound identity (name + namespace) and hostnames is a list of strings —
strategic merge can't reliably replace either.

Usage:
  include "homerun2.httpRouteJSONPatch" (dict
    "gateway"  .Values.httpRoute.gateway
    "hostname" .Values.omniPitcher.hostname)
*/}}
{{- define "homerun2.httpRouteJSONPatch" -}}
- op: replace
  path: /spec/parentRefs
  value:
    # group + kind included so the replace matches the admission-defaulted
    # live resource (Cilium / Gateway API webhook defaults them in). Skipping
    # them here keeps the App perpetually OutOfSync.
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: {{ .gateway.name | quote }}
      namespace: {{ .gateway.namespace | quote }}
- op: replace
  path: /spec/hostnames
  value:
    - {{ .hostname | quote }}
{{- end -}}

{{/*
homerun2.deletePatch -- emits a $patch: delete on a target by kind+name.
Usage: include "homerun2.deletePatch" (dict "apiVersion" "networking.k8s.io/v1" "kind" "Ingress" "name" "homerun2-omni-pitcher")
*/}}
{{- define "homerun2.deletePatch" -}}
{{- $patch := dict
      "apiVersion" .apiVersion
      "kind" .kind
      "metadata" (dict "name" .name)
      "$patch" "delete"
-}}
{{ toYaml $patch }}
{{- end -}}

{{/*
homerun2.inlineRouteIgnoreDifferences -- server-defaulted fields on an HTTPRoute
that the kustomize OCI base does not declare.

A base whose route omits `group`/`kind` on parentRefs/backendRefs (and `weight`
on a backendRef) gets them defaulted by the API server, so the Application is
permanently OutOfSync while server-side-applying cleanly every time. Whether it
bites depends on the base: omni-pitcher v2.0.0 spells all of them out and stays
Synced; core-catcher v1.0.0 spells none of them out and does not.

The standalone httproute sub-chart solves the same problem the other way, by
rendering `weight` explicitly (see stuttgart-things/argocd#114). That is not
available here — the route lives inside the OCI artifact — and enumerating the
rest would mean tracking Gateway API defaulting rules per version in a JSON
patch, so these are ignored instead of asserted.

Usage: include "homerun2.inlineRouteIgnoreDifferences" "homerun2-core-catcher"
*/}}
{{- define "homerun2.inlineRouteIgnoreDifferences" -}}
ignoreDifferences:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: {{ . | quote }}
    jqPathExpressions:
      - .spec.parentRefs[].group
      - .spec.parentRefs[].kind
      - .spec.rules[].backendRefs[].group
      - .spec.rules[].backendRefs[].kind
      - .spec.rules[].backendRefs[].weight
{{- end -}}
