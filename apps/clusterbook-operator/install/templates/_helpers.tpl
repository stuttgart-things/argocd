{{/*
clusterbookOperator.appName -- per-cluster base name (sha-suffixed) for the
rendered Application. Hashes whichever destination identifier is set. The
Application lands in the `argocd` namespace of ONE management cluster, so a
fixed name would make two destinations collide on the same object; the catalog
verifier fails a chart whose names do not vary with the destination (argocd#41).
*/}}
{{- define "clusterbookOperator.appName" -}}
{{- $destKey := .Values.destination.name | default .Values.destination.server -}}
{{- $defaultName := printf "clusterbook-operator-%s" (sha1sum $destKey | trunc 8) -}}
{{- .Values.applicationName | default $defaultName -}}
{{- end -}}
