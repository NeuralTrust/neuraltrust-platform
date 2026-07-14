{{/*
Expand the name of the chart.
*/}}
{{- define "datacore.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name. Pinned via fullnameOverride to a stable name.
*/}}
{{- define "datacore.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "datacore.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "datacore.labels" -}}
helm.sh/chart: {{ include "datacore.chart" . }}
app.kubernetes.io/name: {{ include "datacore.name" . }}
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
{{- define "datacore.selectorLabels" -}}
app.kubernetes.io/name: {{ include "datacore.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Service account name
*/}}
{{- define "datacore.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default "datacore" .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Resolve the image reference, honoring global.imageRegistry (mirror support).
Usage: {{ include "datacore.image" (dict "repository" .Values.image.repository "tag" .Values.image.tag "global" .Values.global) }}
*/}}
{{- define "datacore.image" -}}
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
Emits nothing when unset or "none".
Usage: {{- include "datacore.imagePullSecrets" . | nindent 6 }}
*/}}
{{- define "datacore.imagePullSecrets" -}}
{{- $secrets := list -}}
{{- $src := .Values.imagePullSecrets -}}
{{- if not $src -}}
  {{- if and .Values.global .Values.global.imagePullSecrets -}}
    {{- $src = .Values.global.imagePullSecrets -}}
  {{- end -}}
{{- end -}}
{{- if kindIs "string" $src -}}
  {{- if and (ne $src "") (ne $src "none") -}}{{- $secrets = append $secrets $src -}}{{- end -}}
{{- else if kindIs "slice" $src -}}
  {{- range $src -}}
    {{- if kindIs "string" . -}}{{- $secrets = append $secrets . -}}
    {{- else if kindIs "map" . -}}{{- if .name -}}{{- $secrets = append $secrets .name -}}{{- end -}}{{- end -}}
  {{- end -}}
{{- end -}}
{{- if gt (len $secrets) 0 -}}
imagePullSecrets:
{{- range $secrets }}
  - name: {{ . }}
{{- end -}}
{{- end -}}
{{- end }}
