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
Usage: include "homerun2.imagePatch" (dict "name" "homerun2-omni-pitcher" "tag" "v1.6.2" "reloader" true)
*/}}
{{- define "homerun2.imagePatch" -}}
{{- $meta := dict "name" .name }}
{{- /* reloader: Stakater Reloader rolls the Deployment when a Secret or
       ConfigMap it references changes. Every homerun2 component reads its
       Redis password and token only at start, so a rotated secret otherwise
       sits unused until someone restarts each Deployment by hand — which is
       exactly what the switch of homerun2-test1 to its own entry needed
       (crossplane-configurations#464 step 7). */}}
{{- if .reloader }}
{{- $_ := set $meta "annotations" (dict "reloader.stakater.com/auto" "true") }}
{{- end }}
{{- $patch := dict
      "apiVersion" "apps/v1"
      "kind" "Deployment"
      "metadata" $meta
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

{{/*
homerun2.releaseName -- a Helm release name for an Application this chart renders.
Helm refuses names longer than 53 characters, and these are derived from the
cluster name, so a long cluster broke the sync with "invalid release name"
(tabletennis-rancher-join-test9-schmetterpause-delegate-db, 57, #464). A name
that fits is returned UNCHANGED; a longer one keeps its first 44 characters and
gets an 8-character hash of the full name, so two long names cannot collide.
*/}}
{{- define "homerun2.releaseName" -}}
{{- if le (len .) 53 -}}
{{- . -}}
{{- else -}}
{{- printf "%s-%s" (trunc 44 . | trimSuffix "-") (sha1sum . | trunc 8) -}}
{{- end -}}
{{- end -}}

{{/*
homerun2.schedulePitcherProfile -- the schedule-pitcher's profile.yaml.
`schedulePitcher.profileContent` verbatim when set; otherwise a minimal
central profile: no checks of its own, delivery to the in-cluster omni-pitcher
in grafana format (what the notification-catcher's teams-grafana outputs
match), Europe/Berlin. It still takes findings from agents (POST /findings)
and sends the daily heartbeat. One definition, so the ConfigMap and the Pod's
profile-hash can never describe two different profiles.
*/}}
{{- define "homerun2.schedulePitcherProfile" -}}
{{- if .Values.schedulePitcher.profileContent -}}
{{- .Values.schedulePitcher.profileContent -}}
{{- else -}}
apiVersion: homerun2.sthings.io/v1alpha1
kind: SchedulePitcherProfile
metadata:
  name: {{ .Values.destination.name | default "homerun2" }}
spec:
  pitcher:
    addr: http://homerun2-omni-pitcher.{{ .Values.destination.namespace }}.svc.cluster.local/pitch/grafana
    format: grafana
  defaults:
    timezone: Europe/Berlin
{{- end -}}
{{- end -}}

{{/*
homerun2.aiPitcherSystems -- every system the ai-pitcher pitches as (one per
mode plus the LED ticker). scout leaves them out of its digests, so no digest
counts an AI summary (homerun2-ai-pitcher README, "Modes").
*/}}
{{- define "homerun2.aiPitcherSystems" -}}
ai-digest,ai-evening,ai-week-ahead,ai-weekly,ai-ticker
{{- end -}}

{{/*
homerun2.scoutProfile -- the effective ScoutProfile as YAML
`{render: bool, spec: map}`, for templates/scout-profile.yaml (the CR) and
templates/scout.yaml (which env scout needs). `scout.profile.content` (a YAML
string, what a cluster annotation carries) replaces `scout.profile.spec` and
renders the profile on its own; otherwise `enabled` + `spec` as before.

A profile's non-empty fields win over scout's env, so a profile that lists
digest.excludeSystems would let the AI summaries back into the digest that
DIGEST_EXCLUDE_SYSTEMS keeps them out of: with aiPitcher on, the ai-* systems
are added to that list.
Usage: include "homerun2.scoutProfile" . | fromYaml
*/}}
{{- define "homerun2.scoutProfile" -}}
{{- $p := .Values.scout.profile -}}
{{- $render := $p.enabled -}}
{{- $spec := deepCopy (default (dict) $p.spec) -}}
{{- if $p.content -}}
  {{- $spec = fromYaml $p.content -}}
  {{- if hasKey $spec "Error" -}}
    {{- fail (printf "scout.profile.content must be a YAML map (the ScoutProfile spec): %s" (get $spec "Error")) -}}
  {{- end -}}
  {{- $render = true -}}
{{- end -}}
{{- if .Values.aiPitcher.enabled -}}
  {{- $excl := dig "digest" "excludeSystems" (list) $spec -}}
  {{- if $excl -}}
    {{- $_ := set $spec.digest "excludeSystems" (uniq (concat $excl (splitList "," (include "homerun2.aiPitcherSystems" .)))) -}}
  {{- end -}}
{{- end -}}
{{- toYaml (dict "render" $render "spec" $spec) -}}
{{- end -}}

{{/*
homerun2.portalServices -- PORTAL_SERVICES for homerun2-portal: `key=url`
pairs, comma-separated, in navigation order. `portal.services` wins when set;
otherwise every enabled UI component with a `basePath` is listed, its key
being the basePath without the slash (`/led` -> `led=http://homerun2-led-catcher`).
The portal forwards /<key>/... unchanged, so key and basePath must agree —
deriving one from the other keeps them from drifting apart.
*/}}
{{- define "homerun2.portalServices" -}}
{{- if .Values.portal.services }}
{{- join "," .Values.portal.services }}
{{- else }}
{{- $services := list }}
{{- range $c := list (list "ledCatcher" "led-catcher") (list "coreCatcher" "core-catcher") (list "lightCatcher" "light-catcher") (list "demoPitcher" "demo-pitcher") }}
  {{- $v := index $.Values (index $c 0) }}
  {{- if and $v.enabled $v.basePath }}
    {{- $services = append $services (printf "%s=http://homerun2-%s" (trimPrefix "/" $v.basePath) (index $c 1)) }}
  {{- end }}
{{- end }}
{{- /* The notification-catcher's basePath belongs to its UI. */}}
{{- with .Values.notificationCatcher }}
  {{- if and .enabled .ui.enabled .ui.basePath }}
    {{- $services = append $services (printf "%s=http://homerun2-notification-catcher" (trimPrefix "/" .ui.basePath)) }}
  {{- end }}
{{- end }}
{{- join "," $services }}
{{- end }}
{{- end -}}

{{/*
homerun2.k8sPitcherPreset -- the K8sPitcherProfile and the ClusterRole rules
of `k8sPitcher.preset`, as YAML `{profile: string, rules: list}`. Empty when
no preset is set, so a cluster without one keeps today's contract
(profileContent or the out-of-band ConfigMap, the base's ClusterRole).

important-events is homerun2-k8s-pitcher's profiles/important-events.yaml
(homerun2-k8s-pitcher#88): Ready flips of nodes, Warning Events with a reason
worth a message, a cooldown and a rate limit, no collectors, no inventory on
restart. The Flux informers of the reference profile are opt-in
(`k8sPitcher.fluxInformers`): an informer on a resource the API server does not
serve never syncs and its reflector retries the list forever, logging an
error each time, so on a cluster without Flux CRDs they would be noise.

`rules` is exactly what the profile reads: get/list/watch on what the
informers watch, get on the token Secret only. templates/k8s-pitcher.yaml
replaces the base's rules with it.
Usage: include "homerun2.k8sPitcherPreset" . | fromYaml
*/}}
{{- define "homerun2.k8sPitcherPreset" -}}
{{- $k := .Values.k8sPitcher -}}
{{- if eq $k.preset "important-events" -}}
{{- $addr := printf "http://homerun2-omni-pitcher.%s.svc.cluster.local/pitch" .Values.destination.namespace -}}
{{- if $k.central.url }}{{ $addr = $k.central.url }}{{ end -}}
{{- $watch := list (dict "group" "" "version" "v1" "resource" "nodes" "events" (list "update") "updates" "conditions") -}}
{{- if $k.fluxInformers -}}
{{- $watch = append $watch (dict "group" "kustomize.toolkit.fluxcd.io" "version" "v1" "resource" "kustomizations" "events" (list "update") "updates" "conditions") -}}
{{- $watch = append $watch (dict "group" "helm.toolkit.fluxcd.io" "version" "v2" "resource" "helmreleases" "events" (list "update") "updates" "conditions") -}}
{{- end -}}
{{- $watch = append $watch (dict "group" "" "version" "v1" "resource" "events" "events" (list "add") "types" (list "Warning") "reasons" (list "BackOff" "OOMKilling" "Evicted" "FailedMount" "FailedAttachVolume" "BackoffLimitExceeded" "ProvisioningFailed" "NodeNotReady")) -}}
{{- $spec := dict
      "pitcher" (dict "addr" $addr)
      "auth" (dict "tokenFrom" (dict "secretKeyRef" (dict "name" $k.central.tokenSecret.name "namespace" $k.namespace "key" $k.central.tokenSecret.key)))
      "cooldown" "1h"
      "rateLimit" (dict "max" 20 "per" "10m")
      "informers" $watch
-}}
{{- with $k.cluster }}{{ $_ := set $spec "cluster" . }}{{ end -}}
{{- $profile := dict
      "apiVersion" "homerun2.sthings.io/v1alpha1"
      "kind" "K8sPitcherProfile"
      "metadata" (dict "name" "important-events")
      "spec" $spec
-}}
{{- $rules := list -}}
{{- range $watch -}}
{{- $rules = append $rules (dict "apiGroups" (list .group) "resources" (list .resource) "verbs" (list "get" "list" "watch")) -}}
{{- end -}}
{{- $rules = append $rules (dict "apiGroups" (list "") "resources" (list "secrets") "resourceNames" (list $k.central.tokenSecret.name) "verbs" (list "get")) -}}
{{- dict "profile" (toYaml $profile) "rules" $rules | toYaml -}}
{{- end -}}
{{- end -}}
