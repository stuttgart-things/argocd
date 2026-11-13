{{/* k8sgpt.appName -- prefix of the rendered Applications. */}}
{{- define "k8sgpt.appName" -}}
{{- .Values.applicationName | default (printf "k8sgpt-%s" (sha1sum .Values.destination.server | trunc 8)) -}}
{{- end -}}
