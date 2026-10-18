{{/*
clusterscope.appName -- per-cluster base name (sha-suffixed) for the rendered
Applications. Hashes whichever destination identifier is set. The suffix is not
decoration: the Applications land in the `argocd` namespace of ONE management
cluster, so a fixed name would make two clusters' deployments collide (the
catalog verifier fails a chart whose names do not vary with the destination,
argocd#41).
*/}}
{{- define "clusterscope.appName" -}}
{{- $destKey := .Values.destination.name | default .Values.destination.server -}}
{{- $defaultName := printf "clusterscope-%s" (sha1sum $destKey | trunc 8) -}}
{{- .Values.applicationName | default $defaultName -}}
{{- end -}}

{{/*
clusterscope.on -- "true" for a switch that is on, "" otherwise. Switches
accept a boolean or the strings "true"/"false", because an ApplicationSet can
only template strings -- and the string "false" is TRUTHY in a Go template, so
it is compared with toString rather than used as a boolean.
*/}}
{{- define "clusterscope.on" -}}
{{- if eq (toString .) "true" }}true{{ end -}}
{{- end -}}

{{/* clusterscope.destination -- the destination block, `name` preferred. */}}
{{- define "clusterscope.destination" -}}
{{- if .root.Values.destination.name }}
name: {{ .root.Values.destination.name | quote }}
{{- else }}
server: {{ .root.Values.destination.server | quote }}
{{- end }}
namespace: {{ .namespace | quote }}
{{- end -}}

{{/* clusterscope.finalizers -- resources-finalizer when cascadingDelete. */}}
{{- define "clusterscope.finalizers" -}}
{{- if .Values.cascadingDelete -}}
finalizers:
  - resources-finalizer.argocd.argoproj.io
{{- end -}}
{{- end -}}

{{/* Mount path of the -config file and of the kubeconfigs Secret. */}}
{{- define "clusterscope.configFile" -}}/etc/clusterscope/config.yaml{{- end -}}
{{- define "clusterscope.kubeconfigDir" -}}
{{- if .Values.clusterscope.kubeconfigDir -}}
{{- .Values.clusterscope.kubeconfigDir -}}
{{- else if include "clusterscope.on" .Values.vaultKubeconfigs.enabled -}}
/kubeconfigs
{{- end -}}
{{- end -}}
