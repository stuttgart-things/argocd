{{/*
Kind-catalog helpers (the "smart config" path).

A consumer sets `config.watch: [AnsibleRun, HarvesterVM, …]` — a flat list
of display names. Each name is looked up in the `.Values.kinds` catalog
(the single source of truth for both the machinery watch config AND the
RBAC the ServiceAccount needs to list/watch it). From that one list these
helpers derive:

  machinery.configContent   the MACHINERY_CONFIG JSON (resources map)
  machinery.watchRbacRules  the matching ClusterRole rules

Because both come from the same catalog entries selected by the same
`watch` list, the config and RBAC can never drift — which is the failure
mode the chart and the PR-preview appset used to warn about ("both blocks
must move together").

`config.content` (raw JSON) stays supported as an escape hatch and takes
precedence over `watch`. `config.fromConfigMap` references an external CM
and materializes nothing here.
*/}}

{{/*
machinery.configContent — the effective config.json string, or "" when
neither `config.content` nor `config.watch` is set (machinery then runs
its built-in defaultConfig, or mounts the external `fromConfigMap`).

Auth folding is intentionally NOT done here — config.yaml owns that, so
the token-resolution logic lives in exactly one place. This helper only
produces the base resources config.
*/}}
{{- define "machinery.configContent" -}}
{{- if and .Values.config .Values.config.content -}}
{{- .Values.config.content -}}
{{- else if and .Values.config .Values.config.watch -}}
{{- $resources := dict -}}
{{- range .Values.config.watch -}}
{{-   $entry := index $.Values.kinds . -}}
{{-   if not $entry -}}
{{-     fail (printf "config.watch references unknown kind %q — add it to .Values.kinds (apps/machinery/install/values.yaml)" .) -}}
{{-   end -}}
{{-   $_ := set $resources . $entry -}}
{{- end -}}
{{- toJson (dict "port" 50051 "httpPort" 8080 "resources" $resources) -}}
{{- end -}}
{{- end -}}

{{/*
machinery.watchRbacRules — JSON array of ClusterRole rules derived from
`config.watch`, one rule per apiGroup carrying every watched resource in
that group (deduped). Empty array when `watch` is unset. Verbs are left
off; the rbac sub-chart defaults them to get/list/watch.
*/}}
{{- define "machinery.watchRbacRules" -}}
{{- $byGroup := dict -}}
{{- if and .Values.config .Values.config.watch -}}
{{-   range .Values.config.watch -}}
{{-     $entry := index $.Values.kinds . -}}
{{-     if $entry -}}
{{-       $existing := index $byGroup $entry.group | default (list) -}}
{{-       $_ := set $byGroup $entry.group (append $existing $entry.resource | uniq) -}}
{{-     end -}}
{{-   end -}}
{{- end -}}
{{- $rules := list -}}
{{- range $group, $resources := $byGroup -}}
{{-   $rules = append $rules (dict "apiGroups" (list $group) "resources" $resources) -}}
{{- end -}}
{{- toJson $rules -}}
{{- end -}}
