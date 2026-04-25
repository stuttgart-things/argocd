{{/*
homerun2.appName -- per-cluster base name (sha-suffixed) for Argo Applications.
*/}}
{{- define "homerun2.appName" -}}
{{- $defaultName := printf "homerun2-%s" (sha1sum .Values.destination.server | trunc 8) -}}
{{- .Values.applicationName | default $defaultName -}}
{{- end -}}

{{/*
homerun2.kustomizeRepo -- OCI repo URL for a homerun2-<name>-kustomize artifact.
Usage: include "homerun2.kustomizeRepo" "omni-pitcher"
*/}}
{{- define "homerun2.kustomizeRepo" -}}
ghcr.io/stuttgart-things/homerun2-{{ . }}-kustomize
{{- end -}}

{{/*
homerun2.imagePatch -- emits a Deployment patch that overrides the container image.
Usage: include "homerun2.imagePatch" (dict "name" "homerun2-omni-pitcher" "tag" "v1.6.2")
*/}}
{{- define "homerun2.imagePatch" -}}
{{- $patch := dict
      "apiVersion" "apps/v1"
      "kind" "Deployment"
      "metadata" (dict "name" .name)
      "spec" (dict "template" (dict "spec" (dict "containers" (list
        (dict "name" .name "image" (printf "ghcr.io/stuttgart-things/%s:%s" .name .tag))
      ))))
-}}
{{ toYaml $patch }}
{{- end -}}

{{/*
homerun2.redisPasswordPatch -- emits a Secret patch overriding the per-component
redis Secret's `password` key with the shared homerun2 redis password.
Usage: include "homerun2.redisPasswordPatch" (dict "secretName" "homerun2-omni-pitcher-redis" "password" .Values.redisPassword)
*/}}
{{- define "homerun2.redisPasswordPatch" -}}
{{- $patch := dict
      "apiVersion" "v1"
      "kind" "Secret"
      "metadata" (dict "name" .secretName)
      "stringData" (dict "password" .password)
-}}
{{ toYaml $patch }}
{{- end -}}

{{/*
homerun2.authTokenPatch -- emits a Secret patch overriding the per-component
auth-token Secret's `auth-token` key with the shared homerun2 auth token.
Usage: include "homerun2.authTokenPatch" (dict "secretName" "homerun2-omni-pitcher-token" "token" .Values.authToken)
*/}}
{{- define "homerun2.authTokenPatch" -}}
{{- $patch := dict
      "apiVersion" "v1"
      "kind" "Secret"
      "metadata" (dict "name" .secretName)
      "stringData" (dict "auth-token" .token)
-}}
{{ toYaml $patch }}
{{- end -}}

{{/*
homerun2.redisAddrPatch -- emits a Deployment patch injecting REDIS_ADDR + REDIS_PORT
env vars pointing at the co-deployed redis-stack Service. Optionally appends extra env entries.
Usage: include "homerun2.redisAddrPatch" (dict
  "name" "homerun2-omni-pitcher"
  "namespace" "homerun2"
  "extraEnv" (list (dict "name" "CATCHER_MODE" "value" "web"))
)
*/}}
{{- define "homerun2.redisAddrPatch" -}}
{{- $env := list
      (dict "name" "REDIS_ADDR" "value" (printf "redis-stack.%s.svc.cluster.local" .namespace))
      (dict "name" "REDIS_PORT" "value" "6379")
-}}
{{- range .extraEnv }}
  {{- $env = append $env . }}
{{- end }}
{{- $patch := dict
      "apiVersion" "apps/v1"
      "kind" "Deployment"
      "metadata" (dict "name" .name)
      "spec" (dict "template" (dict "spec" (dict "containers" (list
        (dict "name" .name "env" $env)
      ))))
-}}
{{ toYaml $patch }}
{{- end -}}

{{/*
homerun2.deletePatch -- emits a $patch: delete on a target by kind+name.
Usage: include "homerun2.deletePatch" (dict "apiVersion" "networking.k8s.io/v1" "kind" "Ingress" "name" "homerun2-omni-pitcher")
*/}}
{{- define "homerun2.deletePatch" -}}
{{- $patch := dict
      "apiVersion" .apiVersion
      "kind" .kind
      "metadata" (dict "name" .name)
      "$patch" "delete"
-}}
{{ toYaml $patch }}
{{- end -}}
