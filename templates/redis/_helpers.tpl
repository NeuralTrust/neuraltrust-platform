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
else fall back to the chart-wide gcr-secret default. There is no per-component
key here -- the umbrella owns this Deployment.

A "none" element suppresses entirely (AUT-427). It previously rendered a phantom
`- name: none` pointing at a Secret that does not exist, which is a pull failure
on the IAM / Workload Identity clusters that set it precisely to opt out.
*/}}
{{- define "neuraltrust-platform.v2Redis.imagePullSecrets" -}}
{{- $global := default dict .Values.global -}}
{{- $names := list -}}
{{- $suppress := false -}}
{{- range (default (list) $global.imagePullSecrets) -}}
  {{- $name := "" -}}
  {{- if kindIs "string" . -}}{{- $name = . -}}
  {{- else if kindIs "map" . -}}{{- $name = .name | default "" -}}
  {{- end -}}
  {{- if eq $name "none" -}}
    {{- $suppress = true -}}
    {{- $names = list -}}
  {{- else if and $name (ne $name "") (not $suppress) -}}
    {{- $names = append $names $name -}}
  {{- end -}}
{{- end -}}
{{- if gt (len $names) 0 -}}
imagePullSecrets:
{{- range $names }}
  - name: {{ . }}
{{- end }}
{{- else if not $suppress -}}
imagePullSecrets:
  - name: gcr-secret
{{- end -}}
{{- end -}}
