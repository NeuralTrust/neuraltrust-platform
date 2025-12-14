{{/*
Common labels
*/}}
{{- define "neuraltrust-data-plane.labels" -}}
helm.sh/chart: {{ include "neuraltrust-data-plane.chart" . }}
{{ include "neuraltrust-data-plane.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "neuraltrust-data-plane.selectorLabels" -}}
app.kubernetes.io/name: {{ include "neuraltrust-data-plane.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "neuraltrust-data-plane.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "neuraltrust-data-plane.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Helper to construct image path with optional registry prefix
Usage: {{ include "data-plane.image" (dict "repository" .Values.dataPlane.components.api.image.repository "tag" .Values.dataPlane.components.api.image.tag "global" .Values.global) }}
*/}}
{{- define "data-plane.image" -}}
{{- $registry := "" }}
{{- $repository := .repository }}
{{- $tag := .tag }}
{{- if and .global .global.imageRegistry .global.imageRegistry }}
  {{- $registry = .global.imageRegistry }}
{{- end }}
{{- if $registry }}
  {{- /* Check if repository already starts with registry (e.g., "europe-west1-docker.pkg.dev/project/repo/...") */}}
  {{- if hasPrefix $registry $repository }}
    {{- /* Repository already has registry, use as-is */}}
    {{- printf "%s:%s" $repository $tag }}
  {{- else }}
    {{- /* Prepend registry */}}
    {{- printf "%s/%s:%s" $registry $repository $tag }}
  {{- end }}
{{- else }}
  {{- printf "%s:%s" $repository $tag }}
{{- end }}
{{- end }}

{{/*
Helper to get secret value - supports both direct values and secret references
Usage: {{ include "data-plane.getSecretValue" (dict "value" .Values.dataPlane.secrets.openaiApiKey "secretName" "my-secret" "secretKey" "OPENAI_API_KEY" "context" $) }}
*/}}
{{- define "data-plane.getSecretValue" -}}
{{- $value := .value }}
{{- $secretName := .secretName }}
{{- $secretKey := .secretKey }}
{{- $context := .context }}
{{- $preserveSecrets := false }}
{{- if and $context.Values.dataPlane $context.Values.dataPlane.preserveExistingSecrets }}
  {{- $preserveSecrets = $context.Values.dataPlane.preserveExistingSecrets }}
{{- end }}

{{- if kindIs "map" $value }}
  {{- /* Value is a secret reference object */}}
  {{- if and (hasKey $value "secretName") (hasKey $value "secretKey") }}
    {{- $refSecretName := $value.secretName }}
    {{- $refSecretKey := $value.secretKey }}
    {{- $refSecret := (lookup "v1" "Secret" $context.Release.Namespace $refSecretName) }}
    {{- if and $refSecret (hasKey $refSecret.data $refSecretKey) }}
      {{- /* Use value from referenced secret */}}
      {{- index $refSecret.data $refSecretKey | quote }}
    {{- else }}
      {{- /* Referenced secret doesn't exist, use empty string */}}
      {{- "" | b64enc | quote }}
    {{- end }}
  {{- else }}
    {{- /* Invalid secret reference format */}}
    {{- "" | b64enc | quote }}
  {{- end }}
{{- else }}
  {{- /* Value is a direct string - check if we should preserve existing secret */}}
  {{- $existingSecret := (lookup "v1" "Secret" $context.Release.Namespace $secretName) }}
  {{- if and $preserveSecrets $existingSecret (hasKey $existingSecret.data $secretKey) }}
    {{- /* Preserve existing value */}}
    {{- index $existingSecret.data $secretKey | quote }}
  {{- else if $value }}
    {{- /* Use provided value */}}
    {{- $value | b64enc }}
  {{- else }}
    {{- /* Empty value */}}
    {{- "" | b64enc | quote }}
  {{- end }}
{{- end }}
{{- end }}
