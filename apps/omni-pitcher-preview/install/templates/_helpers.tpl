{{/*
omni-pitcher.imagePatch -- Deployment patch that overrides the container image.
Usage: include "omni-pitcher.imagePatch" (dict "name" "homerun2-omni-pitcher" "tag" "<sha>")
*/}}
{{- define "omni-pitcher.imagePatch" -}}
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
omni-pitcher.redisPasswordPatch -- Secret patch overriding `password`.
*/}}
{{- define "omni-pitcher.redisPasswordPatch" -}}
{{- $patch := dict
      "apiVersion" "v1"
      "kind" "Secret"
      "metadata" (dict "name" .secretName)
      "stringData" (dict "password" .password)
-}}
{{ toYaml $patch }}
{{- end -}}

{{/*
omni-pitcher.authTokenPatch -- Secret patch overriding `auth-token`.
*/}}
{{- define "omni-pitcher.authTokenPatch" -}}
{{- $patch := dict
      "apiVersion" "v1"
      "kind" "Secret"
      "metadata" (dict "name" .secretName)
      "stringData" (dict "auth-token" .token)
-}}
{{ toYaml $patch }}
{{- end -}}

{{/*
omni-pitcher.redisAddrPatch -- Deployment patch injecting REDIS_ADDR + REDIS_PORT.
The redis-stack child Application uses inner helm releaseName `redis-stack`,
so the Service resolves to redis-stack.<namespace>.svc.cluster.local.
*/}}
{{- define "omni-pitcher.redisAddrPatch" -}}
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
omni-pitcher.deletePatch -- $patch: delete on a target by kind+name.
*/}}
{{- define "omni-pitcher.deletePatch" -}}
{{- $patch := dict
      "apiVersion" .apiVersion
      "kind" .kind
      "metadata" (dict "name" .name)
      "$patch" "delete"
-}}
{{ toYaml $patch }}
{{- end -}}
