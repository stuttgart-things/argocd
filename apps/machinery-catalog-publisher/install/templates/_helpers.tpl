{{/*
publisher.appName — the child Application's name. Explicit applicationName
wins; otherwise derive a stable name from the destination server hash so two
clusters don't collide in argocd ns.
*/}}
{{- define "publisher.appName" -}}
{{- .Values.applicationName | default (printf "machinery-catalog-publisher-%s" (sha1sum .Values.destination.server | trunc 8)) -}}
{{- end -}}

{{/*
publisher.kustomizeRepo — tolerate repoURL with or without the oci:// prefix.
Argo CD 2.13+ treats a bare repoURL as git and fails to list refs on a ghcr
package; the prefix is what makes it a kustomize OCI source.
*/}}
{{- define "publisher.kustomizeRepo" -}}
{{- $r := .Values.kustomize.repoURL -}}
{{- if not (hasPrefix "oci://" $r) -}}oci://{{ $r }}{{- else -}}{{ $r }}{{- end -}}
{{- end -}}

{{/*
publisher.configYaml — the config.yaml document patched into the base
ConfigMap (machinery-catalog-publisher-config). Shape matches the publisher's
config.File struct (interval / owner / source / sink). Secret material is NOT
here — it comes from the connection Secret via envFrom.
*/}}
{{- define "publisher.configYaml" -}}
interval: {{ .Values.config.interval | quote }}
owner: {{ .Values.config.owner | quote }}
source:
  machineryAddr: {{ .Values.config.source.machineryAddr | quote }}
  kinds:
{{- range .Values.config.source.kinds }}
    - {{ . | quote }}
{{- end }}
sink:
  bucket: {{ .Values.config.sink.bucket | quote }}
  keyPrefix: {{ .Values.config.sink.keyPrefix | quote }}
  layout: {{ .Values.config.sink.layout | quote }}
  entityNamespace: {{ .Values.config.sink.entityNamespace | quote }}
{{- end -}}
