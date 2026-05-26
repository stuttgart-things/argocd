{{/*
homerun2-kargo.envValuesPath -- expands `envValuesRepo.pathTemplate` for a given
Stage name. The template MUST contain literal `{env}` (enforced by schema).
Usage: include "homerun2-kargo.envValuesPath" (dict "Values" .Values "env" "dev")
*/}}
{{- define "homerun2-kargo.envValuesPath" -}}
{{- $tmpl := .Values.envValuesRepo.pathTemplate -}}
{{- $env := .env -}}
{{- $tmpl | replace "{env}" $env -}}
{{- end -}}

{{/*
homerun2-kargo.applicationName -- expands `applicationNameTemplate` for a given
Stage name.
Usage: include "homerun2-kargo.applicationName" (dict "Values" .Values "env" "dev")
*/}}
{{- define "homerun2-kargo.applicationName" -}}
{{- $tmpl := .Values.applicationNameTemplate -}}
{{- $env := .env -}}
{{- $tmpl | replace "{env}" $env -}}
{{- end -}}

{{/*
homerun2-kargo.credSecretName -- canonical name for a credential Secret. Kargo
discovers project credentials by label, not by name, so the name is purely for
human readability and matches `<project>-<type>-creds`.
Usage: include "homerun2-kargo.credSecretName" (dict "project" .Values.project "type" "git")
*/}}
{{- define "homerun2-kargo.credSecretName" -}}
{{- printf "%s-%s-creds" .project .type -}}
{{- end -}}
