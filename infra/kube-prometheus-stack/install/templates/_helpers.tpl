{{/* Grafana role_attribute_path for the ZITADEL project-roles claim:
     adminRole -> Admin, editorRole -> Editor (skipped when empty),
     viewerRole -> Viewer. Same expression as flux's
     kube-prometheus-stack-grafana-oidc component. */}}
{{- define "kps.grafanaRolePath" -}}
{{- $c := .claim -}}
{{- $o := .oidc -}}
{{- $parts := list (printf "contains(%s, '%s') && 'Admin'" $c $o.adminRole) -}}
{{- if $o.editorRole -}}
{{- $parts = append $parts (printf "contains(%s, '%s') && 'Editor'" $c $o.editorRole) -}}
{{- end -}}
{{- $parts = append $parts (printf "contains(%s, '%s') && 'Viewer'" $c $o.viewerRole) -}}
{{- join " || " $parts -}}
{{- end -}}
