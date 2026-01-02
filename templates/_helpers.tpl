{{/*
Expand the name of the chart.
*/}}
{{- define "neuraltrust-platform.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "neuraltrust-platform.fullname" -}}
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
{{- define "neuraltrust-platform.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "neuraltrust-platform.labels" -}}
helm.sh/chart: {{ include "neuraltrust-platform.chart" . }}
{{ include "neuraltrust-platform.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "neuraltrust-platform.selectorLabels" -}}
app.kubernetes.io/name: {{ include "neuraltrust-platform.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Get ClickHouse connection details
Returns host, port, user, database based on whether ClickHouse is deployed or external
*/}}
{{- define "neuraltrust-platform.clickhouse.host" -}}
{{- if .Values.infrastructure.clickhouse.deploy }}
{{- printf "%s-clickhouse" .Release.Name }}
{{- else }}
{{- .Values.infrastructure.clickhouse.external.host }}
{{- end }}
{{- end }}

{{- define "neuraltrust-platform.clickhouse.port" -}}
{{- if .Values.infrastructure.clickhouse.deploy }}
{{- "8123" }}
{{- else }}
{{- .Values.infrastructure.clickhouse.external.port }}
{{- end }}
{{- end }}

{{- define "neuraltrust-platform.clickhouse.user" -}}
{{- if .Values.infrastructure.clickhouse.deploy }}
{{- .Values.infrastructure.clickhouse.chart.auth.username }}
{{- else }}
{{- .Values.infrastructure.clickhouse.external.user }}
{{- end }}
{{- end }}

{{- define "neuraltrust-platform.clickhouse.database" -}}
{{- if .Values.infrastructure.clickhouse.deploy }}
{{- "default" }}
{{- else }}
{{- .Values.infrastructure.clickhouse.external.database }}
{{- end }}
{{- end }}

{{/*
Get Kafka connection details
*/}}
{{- define "neuraltrust-platform.kafka.bootstrapServers" -}}
{{- if .Values.infrastructure.kafka.deploy }}
{{- printf "%s-kafka:9092" .Release.Name }}
{{- else }}
{{- if .Values.infrastructure.kafka.external.bootstrapServers }}
{{- .Values.infrastructure.kafka.external.bootstrapServers }}
{{- else if .Values.infrastructure.kafka.external.brokers }}
{{- join "," .Values.infrastructure.kafka.external.brokers }}
{{- else }}
{{- "kafka:9092" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Get PostgreSQL connection details
*/}}
{{- define "neuraltrust-platform.postgresql.host" -}}
{{- if .Values.infrastructure.postgresql.deploy }}
{{- printf "control-plane-postgresql" }}
{{- else }}
{{- .Values.infrastructure.postgresql.external.host }}
{{- end }}
{{- end }}

{{- define "neuraltrust-platform.postgresql.port" -}}
{{- if .Values.infrastructure.postgresql.deploy }}
{{- "5432" }}
{{- else }}
{{- .Values.infrastructure.postgresql.external.port }}
{{- end }}
{{- end }}

{{- define "neuraltrust-platform.postgresql.user" -}}
{{- if .Values.infrastructure.postgresql.deploy }}
{{- "neuraltrust" }}
{{- else }}
{{- .Values.infrastructure.postgresql.external.user }}
{{- end }}
{{- end }}

{{- define "neuraltrust-platform.postgresql.database" -}}
{{- if .Values.infrastructure.postgresql.deploy }}
{{- "neuraltrust" }}
{{- else }}
{{- .Values.infrastructure.postgresql.external.database }}
{{- end }}
{{- end }}

