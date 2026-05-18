{{/*
Expand the name of the chart.
*/}}
{{- define "neuraltrust-watchdog.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name.
*/}}
{{- define "neuraltrust-watchdog.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "neuraltrust-watchdog.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "neuraltrust-watchdog.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: neuraltrust-platform
{{- end }}

{{/*
Selector labels (immutable subset).
*/}}
{{- define "neuraltrust-watchdog.selectorLabels" -}}
app.kubernetes.io/name: {{ include "neuraltrust-watchdog.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
ServiceAccount name resolver.
*/}}
{{- define "neuraltrust-watchdog.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "neuraltrust-watchdog.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Resolved image reference. Honors umbrella global.imageRegistry if set.
*/}}
{{- define "neuraltrust-watchdog.image" -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion -}}
{{- $registryOverride := "" -}}
{{- if and .Values.global .Values.global.imageRegistry -}}
{{- $registryOverride = .Values.global.imageRegistry -}}
{{- end -}}
{{- $repo := .Values.image.repository -}}
{{- if $registryOverride -}}
{{- $defaultPrefix := "europe-west1-docker.pkg.dev/neuraltrust-app-prod/nt-docker" -}}
{{- if hasPrefix $registryOverride $repo -}}
{{- printf "%s:%s" $repo $tag -}}
{{- else if hasPrefix (printf "%s/" $defaultPrefix) $repo -}}
{{- $shortName := trimPrefix (printf "%s/" $defaultPrefix) $repo -}}
{{- printf "%s/%s:%s" $registryOverride $shortName $tag -}}
{{- else -}}
{{- printf "%s/%s:%s" $registryOverride $repo $tag -}}
{{- end -}}
{{- else -}}
{{- printf "%s:%s" $repo $tag -}}
{{- end -}}
{{- end }}

{{/*
Resolve secret name for the auth token.
*/}}
{{- define "neuraltrust-watchdog.authSecretName" -}}
{{- if .Values.server.authToken.existingSecret -}}
{{- .Values.server.authToken.existingSecret -}}
{{- else -}}
{{- printf "%s-auth" (include "neuraltrust-watchdog.fullname" .) -}}
{{- end -}}
{{- end }}

{{/*
Resolve secret name for the slack webhook.
*/}}
{{- define "neuraltrust-watchdog.slackSecretName" -}}
{{- if .Values.actions.slack.existingSecret -}}
{{- .Values.actions.slack.existingSecret -}}
{{- else -}}
{{- printf "%s-slack" (include "neuraltrust-watchdog.fullname" .) -}}
{{- end -}}
{{- end }}

{{/*
Optional egress proxy environment variables, only when umbrella
global.proxy.enabled is true.
*/}}
{{- define "neuraltrust-watchdog.proxyEnv" -}}
{{- if and .Values.global .Values.global.proxy .Values.global.proxy.enabled }}
- name: HTTP_PROXY
  value: {{ .Values.global.proxy.httpProxy | quote }}
- name: HTTPS_PROXY
  value: {{ .Values.global.proxy.httpsProxy | quote }}
- name: NO_PROXY
  value: {{ .Values.global.proxy.noProxy | quote }}
- name: http_proxy
  value: {{ .Values.global.proxy.httpProxy | quote }}
- name: https_proxy
  value: {{ .Values.global.proxy.httpsProxy | quote }}
- name: no_proxy
  value: {{ .Values.global.proxy.noProxy | quote }}
{{- end }}
{{- end }}
