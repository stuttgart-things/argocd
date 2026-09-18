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

{{/*
tabletennis.lightCatcherEnabled -- "true" when the LED strip is on, empty
otherwise, so callers can use a plain `if`.

`lightCatcher.enabled` is compared as a STRING rather than used as a boolean. A
platform AppSet templates it from a cluster label and hands over the string
"true" or "false", and in a Go template the string "false" is TRUTHY -- so a
plain `if` deploys the catcher on every cluster that carries the label at all.
That is not hypothetical: it shipped for one commit here and showed up as an
ExternalSecret (and its namespace) rendered for a catcher that did not exist.

Same treatment as infra/trust-manager/bundle's includeVaultPkiCa.
*/}}
{{- define "tabletennis.lightCatcherEnabled" -}}
{{- if eq (.Values.lightCatcher.enabled | default false | toString) "true" }}true{{ end -}}
{{- end -}}

{{/*
tabletennis.releaseName -- a Helm release name for an Application this chart renders.
Helm refuses names longer than 53 characters, and these are derived from the
cluster name, so a long cluster broke the sync with "invalid release name"
(tabletennis-rancher-join-test9-schmetterpause-delegate-db, 57, #464). A name
that fits is returned UNCHANGED; a longer one keeps its first 44 characters and
gets an 8-character hash of the full name, so two long names cannot collide.
*/}}
{{- define "tabletennis.releaseName" -}}
{{- if le (len .) 53 -}}
{{- . -}}
{{- else -}}
{{- printf "%s-%s" (trunc 44 . | trimSuffix "-") (sha1sum . | trunc 8) -}}
{{- end -}}
{{- end -}}
