{{/*
Expand the name of the chart.
*/}}
{{- define "clickstack-otel-collector.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name. Pinned via fullnameOverride to a stable name.
*/}}
{{- define "clickstack-otel-collector.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "clickstack-otel-collector.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "clickstack-otel-collector.labels" -}}
helm.sh/chart: {{ include "clickstack-otel-collector.chart" . }}
app.kubernetes.io/name: {{ include "clickstack-otel-collector.name" . }}
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
{{- define "clickstack-otel-collector.selectorLabels" -}}
app.kubernetes.io/name: {{ include "clickstack-otel-collector.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Service account name
*/}}
{{- define "clickstack-otel-collector.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default "clickstack-collector" .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Resolve the image reference, honoring global.imageRegistry (mirror support).
Usage: {{ include "clickstack-otel-collector.image" (dict "repository" .Values.image.repository "tag" .Values.image.tag "global" .Values.global) }}
*/}}
{{- define "clickstack-otel-collector.image" -}}
{{- $registry := "" }}
{{- $repository := .repository }}
{{- $tag := .tag }}
{{- /* Default NeuralTrust AR registry. Stripped so an air-gapped mirror gets
       <mirror>/clickstack-otel-collector, not
       <mirror>/europe-west1-docker.pkg.dev/.../clickstack-otel-collector. */}}
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
Usage: {{- include "clickstack-otel-collector.imagePullSecrets" . | nindent 6 }}
*/}}
{{- define "clickstack-otel-collector.imagePullSecrets" -}}
{{- include "neuraltrust-platform.subchart.imagePullSecrets" (dict "local" .Values.imagePullSecrets "global" .Values.global) -}}
{{- end }}

{{/*
The ClickHouse HTTP endpoint URL (AUT-636).

An explicit clickhouse.endpoint wins, so this consumer can still be pointed
somewhere else on its own. Empty composes the URL from global.clickhouse -- host
plus HTTP port, https when global.clickhouse.tls is true -- and finally falls back
to the in-cluster http://clickhouse:8123.

Defined once because the Secret needs the URL and the wait-for-ClickHouse
initContainer needs the same host and port split back out of it.
*/}}
{{- define "clickstack-otel-collector.clickhouseEndpoint" -}}
{{- $explicit := (default dict .Values.clickhouse).endpoint | default "" -}}
{{- if $explicit -}}
{{- $explicit -}}
{{- else -}}
{{- $ch := include "neuraltrust-platform.clickhouse.resolve" (dict "local" .Values.clickhouse "global" .Values.global) | fromYaml -}}
{{- $scheme := ternary "https" "http" $ch.tls -}}
{{- printf "%s://%s:%s" $scheme $ch.host $ch.httpPort -}}
{{- end -}}
{{- end }}
