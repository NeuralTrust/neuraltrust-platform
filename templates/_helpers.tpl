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
Uses neuraltrust-control-plane.infrastructure.postgresql.deploy to determine if deployed
Uses neuraltrust-control-plane.controlPlane.components.postgresql.secrets for external connection
*/}}
{{- define "neuraltrust-platform.postgresql.host" -}}
{{- $cpValues := index .Values "neuraltrust-control-plane" }}
{{- $deploy := false }}
{{- if and $cpValues $cpValues.infrastructure $cpValues.infrastructure.postgresql (hasKey $cpValues.infrastructure.postgresql "deploy") }}
  {{- $deploy = $cpValues.infrastructure.postgresql.deploy }}
{{- end }}
{{- if $deploy }}
{{- printf "control-plane-postgresql" }}
{{- else if and $cpValues $cpValues.controlPlane $cpValues.controlPlane.components $cpValues.controlPlane.components.postgresql $cpValues.controlPlane.components.postgresql.secrets $cpValues.controlPlane.components.postgresql.secrets.host }}
{{- $cpValues.controlPlane.components.postgresql.secrets.host }}
{{- else }}
{{- "control-plane-postgresql" }}
{{- end }}
{{- end }}

{{- define "neuraltrust-platform.postgresql.port" -}}
{{- $cpValues := index .Values "neuraltrust-control-plane" }}
{{- $deploy := false }}
{{- if and $cpValues $cpValues.infrastructure $cpValues.infrastructure.postgresql (hasKey $cpValues.infrastructure.postgresql "deploy") }}
  {{- $deploy = $cpValues.infrastructure.postgresql.deploy }}
{{- end }}
{{- if $deploy }}
{{- "5432" }}
{{- else if and $cpValues $cpValues.controlPlane $cpValues.controlPlane.components $cpValues.controlPlane.components.postgresql $cpValues.controlPlane.components.postgresql.secrets $cpValues.controlPlane.components.postgresql.secrets.port }}
{{- $cpValues.controlPlane.components.postgresql.secrets.port }}
{{- else }}
{{- "5432" }}
{{- end }}
{{- end }}

{{- define "neuraltrust-platform.postgresql.user" -}}
{{- $cpValues := index .Values "neuraltrust-control-plane" }}
{{- $deploy := false }}
{{- if and $cpValues $cpValues.infrastructure $cpValues.infrastructure.postgresql (hasKey $cpValues.infrastructure.postgresql "deploy") }}
  {{- $deploy = $cpValues.infrastructure.postgresql.deploy }}
{{- end }}
{{- if $deploy }}
{{- "neuraltrust" }}
{{- else if and $cpValues $cpValues.controlPlane $cpValues.controlPlane.components $cpValues.controlPlane.components.postgresql $cpValues.controlPlane.components.postgresql.secrets $cpValues.controlPlane.components.postgresql.secrets.user }}
{{- $cpValues.controlPlane.components.postgresql.secrets.user }}
{{- else }}
{{- "neuraltrust" }}
{{- end }}
{{- end }}

{{- define "neuraltrust-platform.postgresql.database" -}}
{{- $cpValues := index .Values "neuraltrust-control-plane" }}
{{- $deploy := false }}
{{- if and $cpValues $cpValues.infrastructure $cpValues.infrastructure.postgresql (hasKey $cpValues.infrastructure.postgresql "deploy") }}
  {{- $deploy = $cpValues.infrastructure.postgresql.deploy }}
{{- end }}
{{- if $deploy }}
{{- "neuraltrust" }}
{{- else if and $cpValues $cpValues.controlPlane $cpValues.controlPlane.components $cpValues.controlPlane.components.postgresql $cpValues.controlPlane.components.postgresql.secrets $cpValues.controlPlane.components.postgresql.secrets.database }}
{{- $cpValues.controlPlane.components.postgresql.secrets.database }}
{{- else }}
{{- "neuraltrust" }}
{{- end }}
{{- end }}

{{/*
Resolve a secret value with auto-generation support.
Priority: explicit value > existing value in cluster > generate random.

Usage:
  {{ include "neuraltrust-platform.resolveSecret" (dict "value" $myValue "existingSecret" $existingSecretObj "secretKey" "MY_KEY" "length" 64) }}

Parameters:
  - value:          The explicit value from helm values (string). Empty or nil means "not provided".
  - existingSecret: The result of (lookup "v1" "Secret" .Release.Namespace "secret-name"). Can be nil.
  - secretKey:      The key to look up in the existing secret's data.
  - length:         (Optional) Length of the generated random string. Default: 64.
*/}}
{{- define "neuraltrust-platform.resolveSecret" -}}
{{- $value := .value }}
{{- $existingSecret := .existingSecret }}
{{- $secretKey := .secretKey }}
{{- $length := 64 }}
{{- if .length }}
  {{- $length = .length | int }}
{{- end }}
{{- /* Priority 1: Use explicitly provided value (non-empty string) */}}
{{- if and $value (ne ($value | toString) "") }}
  {{- $value }}
{{- /* Priority 2: Reuse existing value from cluster secret */}}
{{- else if and $existingSecret (kindIs "map" $existingSecret) }}
  {{- if and (index $existingSecret "data") (hasKey (index $existingSecret "data") $secretKey) }}
    {{- index $existingSecret.data $secretKey | b64dec }}
  {{- else }}
    {{- /* Existing secret doesn't have this key - generate */}}
    {{- randAlphaNum $length }}
  {{- end }}
{{- /* Priority 3: Generate new random value */}}
{{- else }}
  {{- randAlphaNum $length }}
{{- end }}
{{- end }}

{{/*
Check if autoGenerateSecrets is enabled.
Returns "true" (non-empty string) if enabled, empty string if disabled.
Usage: {{- if include "neuraltrust-platform.autoGenerateSecrets" . }}
*/}}
{{- define "neuraltrust-platform.autoGenerateSecrets" -}}
{{- $autoGenerate := true }}
{{- if and .Values.global (hasKey .Values.global "autoGenerateSecrets") }}
  {{- $autoGenerate = .Values.global.autoGenerateSecrets }}
{{- end }}
{{- if $autoGenerate }}true{{- end }}
{{- end }}

