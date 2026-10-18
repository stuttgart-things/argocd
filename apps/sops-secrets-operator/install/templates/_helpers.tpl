{{/*
sopsOperator.appName -- per-cluster base name (sha-suffixed) for the rendered
Applications. Hashes whichever destination identifier is set. The Applications
land in the `argocd` namespace of ONE management cluster, so a fixed name would
make two destinations collide on the same object (argocd#41).
*/}}
{{- define "sopsOperator.appName" -}}
{{- $destKey := .Values.destination.name | default .Values.destination.server -}}
{{- $defaultName := printf "sops-secrets-operator-%s" (sha1sum $destKey | trunc 8) -}}
{{- .Values.applicationName | default $defaultName -}}
{{- end -}}

{{/*
sopsOperator.namespace -- the operator's namespace. NOT a value: the base names
it on every object, and overriding it would rewrite the Deployment while
leaving the RBAC subjects behind (the flux catalog sets no targetNamespace for
the same reason).
*/}}
{{- define "sopsOperator.namespace" -}}
sops-secrets-operator-system
{{- end -}}

{{/*
sopsOperator.destination -- the destination block's cluster selector.
*/}}
{{- define "sopsOperator.destination" -}}
{{- if .Values.destination.name -}}
name: {{ .Values.destination.name | quote }}
{{- else -}}
server: {{ .Values.destination.server | quote }}
{{- end -}}
{{- end -}}
