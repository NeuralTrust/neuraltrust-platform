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
Resolve the single data-plane image pull secret NAME in priority order:
  1. .Values.imagePullSecrets             (subchart root, set via parent's `neuraltrust-data-plane.imagePullSecrets`)
  2. .Values.dataPlane.imagePullSecrets   (component-tier override)
  3. "gcr-secret"                          (hardcoded default for backward compat)
The literal string "none" or "" suppresses it entirely (used to opt out when
nodes pull via IAM / Workload Identity and no Secret exists).
Returns the resolved secret name, or empty string when suppressed.
Usage: {{ include "data-plane.imagePullSecretName" . }}
*/}}
{{- define "data-plane.imagePullSecretName" -}}
{{- $imagePullSecret := "gcr-secret" -}}
{{- if .Values.imagePullSecrets -}}
  {{- $imagePullSecret = .Values.imagePullSecrets -}}
{{- else if and .Values.dataPlane (hasKey .Values.dataPlane "imagePullSecrets") -}}
  {{- if and .Values.dataPlane.imagePullSecrets (ne .Values.dataPlane.imagePullSecrets "none") (ne .Values.dataPlane.imagePullSecrets "") -}}
    {{- $imagePullSecret = .Values.dataPlane.imagePullSecrets -}}
  {{- end -}}
{{- end -}}
{{- if and $imagePullSecret (ne $imagePullSecret "none") (ne $imagePullSecret "") -}}
{{- $imagePullSecret -}}
{{- end -}}
{{- end }}

{{/*
Resolve data-plane imagePullSecrets as an inlineable YAML block. Wraps
`data-plane.imagePullSecretName` and renders nothing when suppressed.
Usage:
  spec:
    {{- include "data-plane.imagePullSecrets" . | nindent 6 }}
*/}}
{{- define "data-plane.imagePullSecrets" -}}
{{- $name := include "data-plane.imagePullSecretName" . -}}
{{- if $name -}}
imagePullSecrets:
  - name: {{ $name }}
{{- end -}}
{{- end }}

{{/*
Create the name of the service account to use for data-plane workloads.
*/}}
{{- define "data-plane.serviceAccountName" -}}
{{- $sa := default dict (default dict .Values.dataPlane).serviceAccount -}}
{{- if hasKey $sa "name" -}}
{{- default "data-plane" $sa.name -}}
{{- else -}}
data-plane
{{- end -}}
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
{{- if $context.Values.global }}
  {{- if hasKey $context.Values.global "preserveExistingSecrets" }}
    {{- if $context.Values.global.preserveExistingSecrets }}
      {{- $preserveSecrets = true }}
    {{- end }}
  {{- end }}
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

{{/*
Helper that returns the resolved OTel collector endpoint for data-plane
components. Resolution order:
  1. global.observability.collector.endpoint (umbrella-wide override)
  2. dataPlane.components.<name>.config.otelExporterOtlpEndpoint
Empty string when neither is set — caller skips the OTel ConfigMap and
envFrom block to preserve backward compat.
Usage: {{ include "data-plane.otelEndpoint" (dict "component" "api" "context" .) }}
*/}}
{{- define "data-plane.otelEndpoint" -}}
{{- $ctx := .context -}}
{{- $component := .component -}}
{{- $endpoint := "" -}}
{{- if and $ctx.Values.dataPlane $ctx.Values.dataPlane.components -}}
  {{- $cmp := index $ctx.Values.dataPlane.components $component -}}
  {{- if and $cmp $cmp.config $cmp.config.otelExporterOtlpEndpoint -}}
    {{- $endpoint = $cmp.config.otelExporterOtlpEndpoint -}}
  {{- end -}}
{{- end -}}
{{- $globalObs := default dict (default dict $ctx.Values.global).observability -}}
{{- $globalColl := default dict $globalObs.collector -}}
{{- if $globalColl.endpoint -}}
  {{- $endpoint = $globalColl.endpoint -}}
{{- end -}}
{{- $endpoint -}}
{{- end }}

{{/*
Helper that emits the merged envFrom list for a data-plane component:
the OTel ConfigMap (when an endpoint is resolved) plus any per-component
extraEnvFrom items. Emits nothing when the list is empty.
Usage: {{- include "data-plane.envFrom" (dict "component" "api" "extraEnvFrom" .Values.dataPlane.components.api.extraEnvFrom "context" .) | nindent 8 }}
*/}}
{{- define "data-plane.envFrom" -}}
{{- $component := .component -}}
{{- $extra := .extraEnvFrom -}}
{{- $context := .context -}}
{{- $items := list -}}
{{- $endpoint := include "data-plane.otelEndpoint" (dict "component" $component "context" $context) -}}
{{- if $endpoint -}}
  {{- $items = append $items (dict "configMapRef" (dict "name" (printf "data-plane-%s-otel" $component))) -}}
{{- end -}}
{{- if $extra -}}
  {{- range $extra -}}
    {{- $items = append $items . -}}
  {{- end -}}
{{- end -}}
{{- if $items -}}
envFrom:
{{ toYaml $items }}
{{- end -}}
{{- end }}

{{/*
================================================================================
data-plane-api k8sJobs helpers
================================================================================
The data-plane-api process can spawn evaluation workloads as Kubernetes Jobs
instead of FastAPI background tasks. The helpers below resolve the k8sJobs
config block with safe defaults so the calling templates stay readable.
*/}}

{{/*
Returns "true" when data-plane-api k8sJobs is enabled, empty string otherwise.
Default: disabled (matches data-plane-api K8S_JOBS_ENABLED=false when unset).
Usage: {{- if eq (include "data-plane.api.k8sJobs.enabled" .) "true" }}
*/}}
{{- define "data-plane.api.k8sJobs.enabled" -}}
{{- $cfg := dict -}}
{{- if and .Values.dataPlane .Values.dataPlane.components .Values.dataPlane.components.api .Values.dataPlane.components.api.k8sJobs -}}
  {{- $cfg = .Values.dataPlane.components.api.k8sJobs -}}
{{- end -}}
{{- if hasKey $cfg "enabled" -}}
  {{- if $cfg.enabled -}}true{{- end -}}
{{- end -}}
{{- end }}

{{/*
Returns the namespace where Jobs are created. Empty value in values.yaml
falls back to the release namespace.
*/}}
{{- define "data-plane.api.k8sJobs.namespace" -}}
{{- $ns := .Release.Namespace -}}
{{- if and .Values.dataPlane .Values.dataPlane.components .Values.dataPlane.components.api .Values.dataPlane.components.api.k8sJobs .Values.dataPlane.components.api.k8sJobs.namespace -}}
  {{- $ns = .Values.dataPlane.components.api.k8sJobs.namespace -}}
{{- end -}}
{{- $ns -}}
{{- end }}

{{/*
Returns the image string used by Job pods. Falls back to the API image when
k8sJobs.jobImage.{repository,tag} is empty so a single image bump covers
both the API Deployment and its Jobs.
*/}}
{{- define "data-plane.api.k8sJobs.image" -}}
{{- $apiRepo := "europe-west1-docker.pkg.dev/neuraltrust-app-prod/nt-docker/data-plane-api" -}}
{{- $apiTag := "v1.24.0" -}}
{{- if and .Values.dataPlane .Values.dataPlane.components .Values.dataPlane.components.api .Values.dataPlane.components.api.image -}}
  {{- if .Values.dataPlane.components.api.image.repository -}}{{- $apiRepo = .Values.dataPlane.components.api.image.repository -}}{{- end -}}
  {{- if .Values.dataPlane.components.api.image.tag -}}{{- $apiTag = .Values.dataPlane.components.api.image.tag -}}{{- end -}}
{{- end -}}
{{- $repo := $apiRepo -}}
{{- $tag := $apiTag -}}
{{- if and .Values.dataPlane .Values.dataPlane.components .Values.dataPlane.components.api .Values.dataPlane.components.api.k8sJobs .Values.dataPlane.components.api.k8sJobs.jobImage -}}
  {{- if .Values.dataPlane.components.api.k8sJobs.jobImage.repository -}}{{- $repo = .Values.dataPlane.components.api.k8sJobs.jobImage.repository -}}{{- end -}}
  {{- if .Values.dataPlane.components.api.k8sJobs.jobImage.tag -}}{{- $tag = .Values.dataPlane.components.api.k8sJobs.jobImage.tag -}}{{- end -}}
{{- end -}}
{{- include "data-plane.image" (dict "repository" $repo "tag" $tag "global" .Values.global) -}}
{{- end }}
