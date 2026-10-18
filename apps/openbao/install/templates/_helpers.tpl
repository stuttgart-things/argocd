{{- define "openbao-install.appName" -}}
{{- $defaultName := printf "openbao-%s" (sha1sum .Values.destination.server | trunc 8) }}
{{- .Values.applicationName | default $defaultName }}
{{- end }}

{{- /* The Secret the selected seal reads, as a dict (name, key), or an empty
       dict with seal none. self-init-userpass reads its passwords from the
       SAME Secret: the one Secret this instance already depends on. */}}
{{- define "openbao-install.sealSecret" -}}
{{- if eq .Values.seal.type "static" }}
{{- dict "name" .Values.seal.static.secretName "key" .Values.seal.static.secretKey | toJson }}
{{- else if eq .Values.seal.type "transit" }}
{{- dict "name" .Values.seal.transit.secretName "key" .Values.seal.transit.secretKey | toJson }}
{{- else }}
{{- dict | toJson }}
{{- end }}
{{- end }}
