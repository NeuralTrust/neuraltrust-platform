{{/*
platform-v2 in-cluster Redis (umbrella-managed parent template).
Renders only under global.platformVersion=v2 when infrastructure.redis.deploy is
true (default). Service name is the stable "redis" so agentgateway/trustguard
default their redis.host to it.
*/}}

{{/*
Returns "true" (non-empty) when the v2 in-cluster Redis should render.
*/}}
{{- define "neuraltrust-platform.v2Redis.enabled" -}}
{{- $isV2 := eq (include "neuraltrust-platform.isV2" .) "true" -}}
{{- $redis := default dict (default dict .Values.infrastructure).redis -}}
{{- $deploy := true -}}
{{- if hasKey $redis "deploy" }}{{- $deploy = $redis.deploy -}}{{- end -}}
{{- if and $isV2 $deploy }}true{{- end -}}
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
{{- $tag := default "7.4.0-v0" $img.tag -}}
{{- printf "%s:%s" $repo $tag -}}
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
