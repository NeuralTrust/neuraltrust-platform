{{/*
Expand the name of the chart.
*/}}
{{- define "trustguard.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name. Pinned via fullnameOverride to a stable name.
*/}}
{{- define "trustguard.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "trustguard.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "trustguard.labels" -}}
helm.sh/chart: {{ include "trustguard.chart" . }}
app.kubernetes.io/name: {{ include "trustguard.name" . }}
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
{{- define "trustguard.selectorLabels" -}}
app.kubernetes.io/name: {{ include "trustguard.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Service account name
*/}}
{{- define "trustguard.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default "trustguard" .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Resolve the image reference, honoring global.imageRegistry (mirror support).
Usage: {{ include "trustguard.image" (dict "repository" .Values.image.repository "tag" .Values.image.tag "global" .Values.global) }}
*/}}
{{- define "trustguard.image" -}}
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
Usage: {{- include "trustguard.imagePullSecrets" . | nindent 6 }}
*/}}
{{- define "trustguard.imagePullSecrets" -}}
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

{{/*
config-sync gRPC TLS: fixed secret name, mount path and verified server name.
The control plane's config-sync gRPC listener REQUIRES TLS (cert+key) whenever
APP_ENV is a deployed environment (prod/production/staging/stage); the data plane
verifies the listener against the generated CA using this DNS server name.
*/}}
{{- define "trustguard.configSyncTls.secretName" -}}
{{- $tls := (default dict .Values.configSync).grpcTls | default dict -}}
{{- $tls.existingSecret | default "trustguard-configsync-tls" -}}
{{- end }}

{{- define "trustguard.configSyncTls.mountPath" -}}/etc/trustguard/configsync-tls{{- end }}

{{- define "trustguard.configSyncTls.serverName" -}}
{{- printf "%s.%s.svc.cluster.local" .Values.controlPlane.name .Release.Namespace -}}
{{- end }}

{{/*
Returns "true" (non-empty) when the config-sync gRPC listener must run with TLS:
v2 + external/full + a deployed APP_ENV. In that case the chart provisions a
server cert/key (auto-generated CA, or an operator-provided existingSecret).
*/}}
{{- define "trustguard.configSyncTls.active" -}}
{{- $isV2 := eq (include "neuraltrust-platform.isV2" .) "true" -}}
{{- $isFull := eq (include "neuraltrust-platform.isFull" .) "true" -}}
{{- $appEnv := lower (trim (.Values.config.appEnv | default "")) -}}
{{- $deployed := has $appEnv (list "prod" "production" "staging" "stage") -}}
{{- $tls := (default dict .Values.configSync).grpcTls | default dict -}}
{{- $provisioned := or ($tls.existingSecret | default "") (ne ($tls.autoGenerate | default true) false) -}}
{{- if and $isV2 $isFull $deployed $provisioned }}true{{- end -}}
{{- end }}
