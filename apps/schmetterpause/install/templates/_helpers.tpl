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

{{/*
schmetterpause.releaseName -- a Helm release name for an Application this chart renders.
Helm refuses names longer than 53 characters, and these are derived from the
cluster name, so a long cluster broke the sync with "invalid release name"
(tabletennis-rancher-join-test9-schmetterpause-delegate-db, 57, #464). A name
that fits is returned UNCHANGED; a longer one keeps its first 44 characters and
gets an 8-character hash of the full name, so two long names cannot collide.
*/}}
{{- define "schmetterpause.releaseName" -}}
{{- if le (len .) 53 -}}
{{- . -}}
{{- else -}}
{{- printf "%s-%s" (trunc 44 . | trimSuffix "-") (sha1sum . | trunc 8) -}}
{{- end -}}
{{- end -}}
