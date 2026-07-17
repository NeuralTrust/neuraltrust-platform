{{/*
In-cluster Redis (umbrella-managed parent template). Renders when
`global.redis.deploy` is true (default). Service name is the stable "redis" so
AgentGateway / TrustGuard / DataAgent / data-plane-api default to it.
*/}}
{{- define "neuraltrust-platform.v2Redis.enabled" -}}
{{- $global := default dict .Values.global -}}
{{- $globalRedis := default dict $global.redis -}}
{{- $deploy := true -}}
{{- if hasKey $globalRedis "deploy" -}}{{- $deploy = $globalRedis.deploy -}}{{- end -}}
{{- if $deploy }}true{{- end -}}
{{- end -}}

{{- define "neuraltrust-platform.v2Redis.labels" -}}
app.kubernetes.io/name: redis
app.kubernetes.io/component: redis
app.kubernetes.io/part-of: neuraltrust-platform
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "neuraltrust-platform.v2Redis.selectorLabels" -}}
app.kubernetes.io/name: redis
app.kubernetes.io/component: redis
{{- end -}}

{{/*
Fully-qualified Redis image (repository:tag) with sane mirror defaults.
*/}}
{{- define "neuraltrust-platform.v2Redis.image" -}}
{{- $img := default dict (default dict (default dict .Values.infrastructure).redis).image -}}
{{- $repo := default "europe-west1-docker.pkg.dev/neuraltrust-app-prod/nt-docker/redis-stack-server" $img.repository -}}
{{- $tag := $img.tag | default "7.2.0-v20" -}}
{{- include "neuraltrust-platform.image" (dict "repository" $repo "tag" $tag "global" (default dict .Values.global)) -}}
{{- end -}}

{{/*
imagePullSecrets block: honor global.imagePullSecrets (list of strings/maps),
else fall back to the chart-wide gcr-secret default.
*/}}
{{- define "neuraltrust-platform.v2Redis.imagePullSecrets" -}}
{{- $global := default dict .Values.global -}}
{{- if $global.imagePullSecrets -}}
imagePullSecrets:
{{- range $global.imagePullSecrets }}
{{- if kindIs "string" . }}
  - name: {{ . }}
{{- else if kindIs "map" . }}
  - {{ toYaml . | nindent 4 | trim }}
{{- end }}
{{- end }}
{{- else -}}
imagePullSecrets:
  - name: gcr-secret
{{- end -}}
{{- end -}}
