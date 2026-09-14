{{/*
zaehlwerk.appName -- per-cluster base name (sha-suffixed) for the rendered
Application. Hashes whichever destination identifier is set:
`destination.server` (URL) or `destination.name` (Argo-registered cluster name).

The suffix is not decoration. The Application lands in the `argocd` namespace of
ONE management cluster, so a fixed name would make two clusters' deployments of
this app collide on the same object — each sync fighting the other's
destination. The catalog verifier fails a chart whose names do not vary with the
destination (argocd#41).

Consumers that deploy this to exactly one cluster can set `applicationName` to
get a readable name instead.
*/}}
{{- define "zaehlwerk.appName" -}}
{{- $destKey := .Values.destination.name | default .Values.destination.server -}}
{{- $defaultName := printf "zaehlwerk-%s" (sha1sum $destKey | trunc 8) -}}
{{- .Values.applicationName | default $defaultName -}}
{{- end -}}

{{/*
zaehlwerk.panelOmniPitcherURL -- the omni-pitcher URL, explicit value first,
otherwise derived from `panel.homerun2Namespace`. Empty means no panel.
*/}}
{{- define "zaehlwerk.panelOmniPitcherURL" -}}
{{- $p := .Values.panel | default dict -}}
{{- if $p.omniPitcherURL -}}
{{- $p.omniPitcherURL -}}
{{- else if $p.homerun2Namespace -}}
{{- printf "http://homerun2-omni-pitcher.%s.svc.cluster.local" $p.homerun2Namespace -}}
{{- end -}}
{{- end -}}

{{/*
zaehlwerk.panelCatcherURL -- the led-catcher URL, explicit value first,
otherwise derived from `panel.homerun2Namespace`. Empty leaves CATCHER_URL out
of the ConfigMap, which is how the base ships it.
*/}}
{{- define "zaehlwerk.panelCatcherURL" -}}
{{- $p := .Values.panel | default dict -}}
{{- if $p.catcherURL -}}
{{- $p.catcherURL -}}
{{- else if $p.homerun2Namespace -}}
{{- printf "http://homerun2-led-catcher.%s.svc.cluster.local" $p.homerun2Namespace -}}
{{- end -}}
{{- end -}}

{{/*
zaehlwerk.configData -- the ConfigMap keys this environment sets, as a map.
Only keys with a value are included: `configmap.k` leaves an empty value out
entirely rather than setting it to "", because main.go decides what is enabled
by asking whether a variable is set. A key set to "" here would therefore read
as "enabled, with an empty value" — which for OMNI_PITCHER_URL means dialling
the empty string forever.
*/}}
{{- define "zaehlwerk.configData" -}}
{{- $p := .Values.panel | default dict -}}
{{- $data := dict -}}
{{- with include "zaehlwerk.panelOmniPitcherURL" . }}{{ $_ := set $data "OMNI_PITCHER_URL" . }}{{ end -}}
{{- with include "zaehlwerk.panelCatcherURL" . }}{{ $_ := set $data "CATCHER_URL" . }}{{ end -}}
{{- with $p.matchStreams }}{{ $_ := set $data "CATCHER_MATCH_STREAMS" . }}{{ end -}}
{{- with $p.idleStreams }}{{ $_ := set $data "CATCHER_IDLE_STREAMS" . }}{{ end -}}
{{- with $p.idleTimeout }}{{ $_ := set $data "CATCHER_IDLE_TIMEOUT" . }}{{ end -}}
{{- with .Values.allowedOrigins }}{{ $_ := set $data "ALLOWED_ORIGINS" . }}{{ end -}}
{{- /* Empty renders as nothing rather than `{}`, so the caller can skip the
       patch entirely instead of emitting one that changes no key. */ -}}
{{- if $data }}{{ toYaml $data }}{{ end -}}
{{- end -}}
