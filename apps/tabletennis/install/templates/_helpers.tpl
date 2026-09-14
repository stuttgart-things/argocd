{{/*
tabletennis.appName -- per-cluster base name (sha-suffixed) for the rendered
Applications. Hashes whichever destination identifier is set:
`destination.name` (Argo-registered cluster name) or `destination.server` (URL).

The suffix is not decoration. Every Application lands in the `argocd` namespace
of ONE management cluster, so a fixed name would make two clusters' deployments
collide on the same object — each sync fighting the other's destination. The
catalog verifier fails a chart whose names do not vary with the destination
(argocd#41).
*/}}
{{- define "tabletennis.appName" -}}
{{- $destKey := .Values.destination.name | default .Values.destination.server -}}
{{- $defaultName := printf "tabletennis-%s" (sha1sum $destKey | trunc 8) -}}
{{- .Values.applicationName | default $defaultName -}}
{{- end -}}

{{/*
tabletennis.hostname -- a component's FQDN: its own `hostname` if set, else
`<component>.<domain>`. One decision, two ways to express it.
Usage: include "tabletennis.hostname" (dict "root" . "name" "schmetterpause")
*/}}
{{- define "tabletennis.hostname" -}}
{{- $c := index .root.Values .name -}}
{{- if $c.hostname -}}
{{- $c.hostname -}}
{{- else -}}
{{- printf "%s.%s" .name .root.Values.domain -}}
{{- end -}}
{{- end -}}

{{/*
tabletennis.destination -- the destination block, one of `name` or `server`
plus the namespace the caller passes in.
Usage: include "tabletennis.destination" (dict "root" . "namespace" "zaehlwerk")
*/}}
{{- define "tabletennis.destination" -}}
{{- if .root.Values.destination.name }}
name: {{ .root.Values.destination.name | quote }}
{{- else }}
server: {{ .root.Values.destination.server | quote }}
{{- end }}
namespace: {{ .namespace | quote }}
{{- end -}}

{{/*
tabletennis.subValues -- the values for a delegated sub-chart: what this chart
computes, with the component's own `values` block merged on top.

mergeOverwrite is the right way round on purpose: a consumer setting
`schmetterpause.values.database.storage.size` must win over the computed
defaults, and deepCopy keeps mergeOverwrite from mutating the computed dict in
place (it merges into its first argument).

Usage: include "tabletennis.subValues" (dict "computed" $computed "override" .Values.schmetterpause.values)
*/}}
{{- define "tabletennis.subValues" -}}
{{- $merged := mergeOverwrite (deepCopy .computed) (deepCopy (.override | default dict)) -}}
{{- toYaml $merged -}}
{{- end -}}
