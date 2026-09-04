{{/*
schmetterpause.appName -- per-cluster base name (sha-suffixed) for the rendered
Applications. Hashes whichever destination identifier is set: `destination.server`
(URL) or `destination.name` (Argo-registered cluster name).

The suffix is not decoration. Both Applications land in the `argocd` namespace of
ONE management cluster, so a fixed name would make two clusters' deployments of
this app collide on the same object — each sync fighting the other's destination.
The catalog verifier fails a chart whose names do not vary with the destination
(argocd#41).

Consumers that deploy this to exactly one cluster can set `applicationName` to
get a readable name instead.
*/}}
{{- define "schmetterpause.appName" -}}
{{- $destKey := .Values.destination.name | default .Values.destination.server -}}
{{- $defaultName := printf "schmetterpause-%s" (sha1sum $destKey | trunc 8) -}}
{{- .Values.applicationName | default $defaultName -}}
{{- end -}}
