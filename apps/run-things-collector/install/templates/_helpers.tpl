{{/*
Common labels applied to every rendered resource.
*/}}
{{- define "run-things-collector.labels" -}}
app.kubernetes.io/name: {{ .Values.applicationName | quote }}
app.kubernetes.io/instance: {{ .Values.applicationName | quote }}
app.kubernetes.io/component: cluster-collector
app.kubernetes.io/part-of: run-things
app.kubernetes.io/managed-by: {{ .Release.Service | quote }}
{{- end -}}

{{/*
Selector labels (subset that must remain stable across upgrades).
*/}}
{{- define "run-things-collector.selectorLabels" -}}
app.kubernetes.io/name: {{ .Values.applicationName | quote }}
app.kubernetes.io/instance: {{ .Values.applicationName | quote }}
{{- end -}}
