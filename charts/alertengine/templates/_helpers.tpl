{{/*
Expand the name of the chart.
*/}}
{{- define "alertengine.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name. Pinned via fullnameOverride to a stable name.
*/}}
{{- define "alertengine.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "alertengine.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "alertengine.labels" -}}
helm.sh/chart: {{ include "alertengine.chart" . }}
app.kubernetes.io/name: {{ include "alertengine.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: neuraltrust-platform
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels (immutable fields)
*/}}
{{- define "alertengine.selectorLabels" -}}
app.kubernetes.io/name: {{ include "alertengine.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Service account name
*/}}
{{- define "alertengine.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default "alertengine" .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Renders ONLY when global.deploymentMode=external
AND the subchart is enabled.
*/}}
{{- define "alertengine.deploy" -}}
{{- if and (eq (include "neuraltrust-platform.isExternal" .) "true") .Values.enabled -}}
true
{{- end -}}
{{- end }}

{{/*
Resolve the image reference, honoring global.imageRegistry (mirror support).
*/}}
{{- define "alertengine.image" -}}
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
imagePullSecrets block. Priority: .Values.imagePullSecrets > global.imagePullSecrets.
Accepts a string or a list of strings/maps. Emits nothing when unset, "" or "none".

Delegates to the umbrella resolver (AUT-427). This body used to be one of nine
byte-identical copies, and every copy dropped the "none" check in the list branch
-- so global.imagePullSecrets: ["none"] rendered a phantom `- name: none` despite
the line above promising otherwise. Keep the wrapper: the name is what templates
call, and it keeps the value key local to this chart.
Usage: {{- include "alertengine.imagePullSecrets" . | nindent 6 }}
*/}}
{{- define "alertengine.imagePullSecrets" -}}
{{- include "neuraltrust-platform.subchart.imagePullSecrets" (dict "local" .Values.imagePullSecrets "global" .Values.global) -}}
{{- end }}
