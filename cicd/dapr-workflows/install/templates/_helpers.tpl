{{- define "daprWorkflows.appName" -}}
{{- .Values.applicationName | default (printf "dapr-workflows-%s" (sha1sum .Values.destination.server | trunc 8)) -}}
{{- end }}

{{/* Argo CD treats only an `oci://` repoURL as an OCI source; without the
     prefix it falls back to git ("repository not found"). Same helper as
     apps/machinery. */}}
{{- define "daprWorkflows.oci" -}}
{{- if hasPrefix "oci://" . }}{{ . }}{{ else }}{{ printf "oci://%s" . }}{{ end -}}
{{- end }}

{{- define "daprWorkflows.redisHost" -}}
{{- printf "redis-stack.%s.svc.cluster.local:6379" .Values.redis.namespace -}}
{{- end }}

{{/* Leaf metadata: a resources-finalizer only with cascadingDelete. */}}
{{- define "daprWorkflows.leafFinalizer" -}}
{{- if .Values.cascadingDelete }}
  finalizers:
    - resources-finalizer.argocd.argoproj.io
{{- end }}
{{- end }}
