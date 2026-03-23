{{/*
Helper to construct image path with optional registry prefix.
Usage: {{ include "firewall.image" (dict "repository" "repo" "tag" "v1" "global" .Values.global) }}
*/}}
{{- define "firewall.image" -}}
{{- $registry := "" }}
{{- $repository := .repository }}
{{- $tag := .tag }}
{{- if and .global .global.imageRegistry .global.imageRegistry }}
  {{- $registry = .global.imageRegistry }}
{{- end }}
{{- if $registry }}
  {{- if hasPrefix $registry $repository }}
    {{- printf "%s:%s" $repository $tag }}
  {{- else }}
    {{- printf "%s/%s:%s" $registry $repository $tag }}
  {{- end }}
{{- else }}
  {{- printf "%s:%s" $repository $tag }}
{{- end }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "firewall.labels" -}}
app.kubernetes.io/name: firewall
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "firewall.selectorLabels" -}}
app.kubernetes.io/name: firewall
{{- end }}
