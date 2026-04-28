{{/*
Expand the name of the chart.
*/}}
{{- define "clickhouse.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "clickhouse.fullname" -}}
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
{{- define "clickhouse.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "clickhouse.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "clickhouse.selectorLabels" -}}
app.kubernetes.io/name: {{ include "clickhouse.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Backup: resolve ServiceAccount name.
Priority: .Values.backup.serviceAccount.name > auto-generated "<fullname>-backup"
*/}}
{{- define "clickhouse.backup.serviceAccountName" -}}
{{- if .Values.backup.serviceAccount.name }}
  {{- .Values.backup.serviceAccount.name }}
{{- else }}
  {{- printf "%s-backup" (include "clickhouse.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Backup: resolve the Secret name that holds storage credentials.
Priority: existingSecret (per-storage-type) > auto-generated "<fullname>-backup-credentials"
*/}}
{{- define "clickhouse.backup.credentialsSecretName" -}}
{{- $type := .Values.backup.storage.type | default "s3" }}
{{- if eq $type "s3" }}
  {{- if .Values.backup.storage.s3.existingSecret }}
    {{- .Values.backup.storage.s3.existingSecret }}
  {{- else }}
    {{- printf "%s-backup-credentials" (include "clickhouse.fullname" .) | trunc 63 | trimSuffix "-" }}
  {{- end }}
{{- else if eq $type "azblob" }}
  {{- if .Values.backup.storage.azblob.existingSecret }}
    {{- .Values.backup.storage.azblob.existingSecret }}
  {{- else }}
    {{- printf "%s-backup-credentials" (include "clickhouse.fullname" .) | trunc 63 | trimSuffix "-" }}
  {{- end }}
{{- end }}
{{- end }}

{{/*
Backup: resolve the container image.
Defaults to the main ClickHouse image so no extra image pull is needed.
*/}}
{{- define "clickhouse.backup.image" -}}
{{- $repo := .Values.backup.image.repository | default .Values.image.repository }}
{{- $tag := .Values.backup.image.tag | default .Values.image.tag }}
{{- $registry := "" }}
{{- if and .Values.global .Values.global.imageRegistry }}
  {{- $registry = .Values.global.imageRegistry }}
{{- end }}
{{- if $registry }}
  {{- printf "%s/%s:%s" $registry $repo $tag }}
{{- else }}
  {{- printf "%s:%s" $repo $tag }}
{{- end }}
{{- end }}

{{/*
Construct image path with optional global registry prefix.
*/}}
{{- define "clickhouse.image" -}}
{{- $registry := "" }}
{{- if and .Values.global .Values.global.imageRegistry }}
  {{- $registry = .Values.global.imageRegistry }}
{{- end }}
{{- if $registry }}
  {{- printf "%s/%s:%s" $registry .Values.image.repository .Values.image.tag }}
{{- else }}
  {{- printf "%s:%s" .Values.image.repository .Values.image.tag }}
{{- end }}
{{- end }}
