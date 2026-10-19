{{- define "harborCicd.appName" -}}
{{- .Values.applicationName | default (printf "harbor-%s" (sha1sum .Values.destination.server | trunc 8)) -}}
{{- end }}

{{/* Secret name -> (key in the Secret -> KV property). The names are what the
     upstream values below reference. */}}
{{- define "harborCicd.secretMap" -}}
harbor-eso-admin:
  HARBOR_ADMIN_PASSWORD: admin_password
harbor-eso-secretkey:
  secretKey: secret_key
harbor-eso-core-secret:
  secret: core_secret
harbor-eso-core-token:
  tls.key: token_key
  tls.crt: token_crt
harbor-eso-xsrf:
  CSRF_KEY: xsrf_key
harbor-eso-jobservice:
  JOBSERVICE_SECRET: jobservice_secret
harbor-eso-registry-http:
  REGISTRY_HTTP_SECRET: registry_http_secret
harbor-eso-registry-credentials:
  REGISTRY_PASSWD: registry_password
  REGISTRY_HTPASSWD: registry_htpasswd
{{- end }}
