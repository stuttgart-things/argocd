{{- define "harborCicd.appName" -}}
{{- .Values.applicationName | default (printf "harbor-%s" (sha1sum .Values.destination.server | trunc 8)) -}}
{{- end }}

{{/* Secret name -> (key in the Secret -> KV property). The names are what the
     upstream values below reference. The token signing key is not here: it
     comes from cert-manager (token-cert). harbor-eso-registry-credentials is
     templated below: REGISTRY_HTPASSWD is the bcrypt of the fetched password,
     built by ESO, so every KV value is one the stack can generate. */}}
{{- define "harborCicd.secretMap" -}}
harbor-eso-admin:
  HARBOR_ADMIN_PASSWORD: admin_password
harbor-eso-secretkey:
  secretKey: secret_key
harbor-eso-core-secret:
  secret: core_secret
harbor-eso-xsrf:
  CSRF_KEY: xsrf_key
harbor-eso-jobservice:
  JOBSERVICE_SECRET: jobservice_secret
harbor-eso-registry-http:
  REGISTRY_HTTP_SECRET: registry_http_secret
harbor-eso-registry-credentials:
  registry_password: registry_password
{{- end }}
