{{/*
Construct image path with optional global registry prefix.
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
Gateway labels
*/}}
{{- define "firewall.gateway.labels" -}}
app.kubernetes.io/name: firewall
app.kubernetes.io/component: gateway
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Gateway selector labels
*/}}
{{- define "firewall.gateway.selectorLabels" -}}
app.kubernetes.io/name: firewall
{{- end }}

{{/*
Worker labels — call with (dict "name" "toxicity" "context" .)
*/}}
{{- define "firewall.worker.labels" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/component: worker
app.kubernetes.io/instance: {{ .context.Release.Name }}
app.kubernetes.io/managed-by: {{ .context.Release.Service }}
{{- end }}

{{/*
Worker selector labels — call with (dict "name" "toxicity")
*/}}
{{- define "firewall.worker.selectorLabels" -}}
app.kubernetes.io/name: {{ .name }}
{{- end }}

{{/*
Resolve a worker setting: per-worker override → workerDefaults → fallback.
Usage: {{ include "firewall.worker.value" (dict "worker" $workerCfg "defaults" $.Values.firewall.workerDefaults "key" "replicas" "fallback" 1) }}
*/}}
{{- define "firewall.worker.value" -}}
{{- $worker := .worker -}}
{{- $defaults := .defaults -}}
{{- $key := .key -}}
{{- $fallback := .fallback -}}
{{- if hasKey $worker $key -}}
  {{- index $worker $key -}}
{{- else if hasKey $defaults $key -}}
  {{- index $defaults $key -}}
{{- else -}}
  {{- $fallback -}}
{{- end -}}
{{- end }}
