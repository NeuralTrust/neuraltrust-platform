{{/*
Expand the name of the chart.
*/}}
{{- define "trustgate.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "trustgate.fullname" -}}
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
Create chart name and version as used by the chart label.
*/}}
{{- define "trustgate.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "trustgate.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "trustgate.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "trustgate.selectorLabels" -}}
app.kubernetes.io/name: {{ include "trustgate.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "trustgate.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "trustgate.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Redis host
*/}}
{{- define "trustgate.redis.host" -}}
{{- printf "%s-redis" (include "trustgate.fullname" .) }}
{{- end }}

{{/*
Redis secret name
*/}}
{{- define "trustgate.redis.secretName" -}}
{{- printf "%s-redis" (include "trustgate.fullname" .) }}
{{- end }}


{{/*
Construct image path with optional global registry prefix.
Strips the known default registry prefix when a custom global.imageRegistry is set,
so users only need to mirror images under short names.
Usage: {{ include "trustgate.image" (dict "repository" "europe-west1-docker.pkg.dev/.../trustgate-ee" "tag" "v1.26.7" "global" .Values.global) }}
*/}}
{{- define "trustgate.image" -}}
{{- $registry := "" }}
{{- $repository := .repository }}
{{- $tag := .tag }}
{{- $defaultRegistry := "europe-west1-docker.pkg.dev/neuraltrust-app-prod/nt-docker" }}
{{- if and .global .global.imageRegistry }}
  {{- $registry = .global.imageRegistry }}
{{- end }}
{{- if $registry }}
  {{- if hasPrefix $registry $repository }}
    {{- printf "%s:%s" $repository $tag }}
  {{- else if hasPrefix (printf "%s/" $defaultRegistry) $repository }}
    {{- $shortName := trimPrefix (printf "%s/" $defaultRegistry) $repository }}
    {{- printf "%s/%s:%s" $registry $shortName $tag }}
  {{- else }}
    {{- printf "%s/%s:%s" $registry $repository $tag }}
  {{- end }}
{{- else }}
  {{- printf "%s:%s" $repository $tag }}
{{- end }}
{{- end }}

{{/*
Control Plane labels
*/}}
{{- define "trustgate.controlPlane.labels" -}}
{{ include "trustgate.labels" . }}
app.kubernetes.io/component: control-plane
{{- end }}

{{/*
Data Plane labels
*/}}
{{- define "trustgate.dataPlane.labels" -}}
{{ include "trustgate.labels" . }}
app.kubernetes.io/component: data-plane
{{- end }}

{{/*
Actions labels
*/}}
{{- define "trustgate.actions.labels" -}}
{{ include "trustgate.labels" . }}
app.kubernetes.io/component: actions
{{- end }}

{{/*
Control Plane selector labels (for immutable selector fields)
*/}}
{{- define "trustgate.controlPlane.selectorLabels" -}}
{{ include "trustgate.selectorLabels" . }}
app.kubernetes.io/component: control-plane
{{- end }}

{{/*
Data Plane selector labels (for immutable selector fields)
*/}}
{{- define "trustgate.dataPlane.selectorLabels" -}}
{{ include "trustgate.selectorLabels" . }}
app.kubernetes.io/component: data-plane
{{- end }}

{{/*
Actions selector labels (for immutable selector fields)
*/}}
{{- define "trustgate.actions.selectorLabels" -}}
{{ include "trustgate.selectorLabels" . }}
app.kubernetes.io/component: actions
{{- end }}