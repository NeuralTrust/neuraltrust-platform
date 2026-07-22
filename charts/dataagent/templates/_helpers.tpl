{{/*
Instance name for labels/selectors. Uses fullname so dual product agents do not
share selectors (two PDBs/Deployments cannot match the same pods).
*/}}
{{- define "dataagent.name" -}}
{{- include "dataagent.fullname" . }}
{{- end }}

{{/*
Fully qualified app name. Pinned via fullnameOverride to a stable name.
*/}}
{{- define "dataagent.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride | default "dataagent" }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "dataagent.chart" -}}
{{- printf "%s-%s" (.Chart.Name | default "dataagent") (.Chart.Version | default "0.1.8") | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "dataagent.labels" -}}
helm.sh/chart: {{ include "dataagent.chart" . }}
app.kubernetes.io/name: {{ include "dataagent.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: neuraltrust-platform
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- if .Values.product }}
app.kubernetes.io/product: {{ .Values.product | quote }}
{{- end }}
{{- end }}

{{/*
Selector labels (immutable fields) — unique per instance fullname.
*/}}
{{- define "dataagent.selectorLabels" -}}
app.kubernetes.io/name: {{ include "dataagent.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Service account name — defaults to the instance fullname.
*/}}
{{- define "dataagent.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "dataagent.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Per-instance Secret name (ENROLMENT_TOKEN / optional DATABASE_URL).
*/}}
{{- define "dataagent.secretName" -}}
{{- $existing := default dict .Values.existingSecret -}}
{{- if $existing.name -}}
{{- $existing.name -}}
{{- else -}}
{{- printf "%s-secrets" (include "dataagent.fullname" .) -}}
{{- end -}}
{{- end }}

{{/*
Per-instance env ConfigMap name.
*/}}
{{- define "dataagent.envConfigMapName" -}}
{{- printf "%s-env-vars" (include "dataagent.fullname" .) -}}
{{- end }}

{{/*
Resolve the image reference, honoring global.imageRegistry (mirror support).
Usage: {{ include "dataagent.image" (dict "repository" .Values.image.repository "tag" .Values.image.tag "global" .Values.global) }}
*/}}
{{- define "dataagent.image" -}}
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
Usage: {{- include "dataagent.imagePullSecrets" . | nindent 6 }}
*/}}
{{- define "dataagent.imagePullSecrets" -}}
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
