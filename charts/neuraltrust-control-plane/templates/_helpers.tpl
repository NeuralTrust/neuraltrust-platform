{{/*
Helper to construct image path with optional registry prefix
Usage: {{ include "control-plane.image" (dict "repository" .Values.controlPlane.components.api.image.repository "tag" .Values.controlPlane.components.api.image.tag "global" .Values.global) }}
*/}}
{{- define "control-plane.image" -}}
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
Usage: {{ include "control-plane.getSecretValue" (dict "value" .Values.controlPlane.secrets.openaiApiKey "secretName" "my-secret" "secretKey" "OPENAI_API_KEY" "context" $) }}
*/}}
{{- define "control-plane.getSecretValue" -}}
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
Helper to get secret value as raw string (decoded) - for use in connection strings
Usage: {{ include "control-plane.getSecretValueRaw" (dict "value" .Values.controlPlane.components.postgresql.secrets.password "secretName" "my-secret" "secretKey" "POSTGRES_PASSWORD" "context" $) }}
*/}}
{{- define "control-plane.getSecretValueRaw" -}}
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
      {{- /* Use value from referenced secret - decode from base64 */}}
      {{- index $refSecret.data $refSecretKey | b64dec }}
    {{- else }}
      {{- /* Referenced secret doesn't exist, use empty string */}}
      {{- "" }}
    {{- end }}
  {{- else }}
    {{- /* Invalid secret reference format */}}
    {{- "" }}
  {{- end }}
{{- else }}
  {{- /* Value is a direct string - check if we should preserve existing secret */}}
  {{- $existingSecret := (lookup "v1" "Secret" $context.Release.Namespace $secretName) }}
  {{- if and $preserveSecrets $existingSecret (hasKey $existingSecret.data $secretKey) }}
    {{- /* Preserve existing value - decode from base64 */}}
    {{- index $existingSecret.data $secretKey | b64dec }}
  {{- else if $value }}
    {{- /* Use provided value directly */}}
    {{- $value }}
  {{- else }}
    {{- /* Empty value */}}
    {{- "" }}
  {{- end }}
{{- end }}
{{- end }}

{{/*
Helper to check if PostgreSQL should be deployed
Checks infrastructure.postgresql.deploy from parent chart first, then subchart values
Also supports legacy installInCluster variable for backward compatibility
Explicitly respects deploy: false to disable deployment
Usage: {{ include "control-plane.postgresql.deploy" . }}
*/}}
{{- define "control-plane.postgresql.deploy" -}}
{{- $deploy := true }}
{{- $found := false }}
{{- /* Check if passed via subchart values (when parent passes infrastructure to subchart via neuraltrust-control-plane.infrastructure.postgresql.deploy) */}}
{{- if and .Values.infrastructure .Values.infrastructure.postgresql }}
  {{- if hasKey .Values.infrastructure.postgresql "deploy" }}
    {{- $deploy = .Values.infrastructure.postgresql.deploy }}
    {{- $found = true }}
  {{- else if hasKey .Values.infrastructure.postgresql "installInCluster" }}
    {{- /* Legacy support: installInCluster as alternative to deploy */}}
    {{- $deploy = .Values.infrastructure.postgresql.installInCluster }}
    {{- $found = true }}
  {{- end }}
{{- end }}
{{- /* Fallback: Try to get from parent chart values (infrastructure.postgresql.deploy or installInCluster) */}}
{{- if and (not $found) .Release.Parent }}
  {{- if and .Release.Parent.Values.infrastructure .Release.Parent.Values.infrastructure.postgresql }}
    {{- if hasKey .Release.Parent.Values.infrastructure.postgresql "deploy" }}
      {{- $deploy = .Release.Parent.Values.infrastructure.postgresql.deploy }}
    {{- else if hasKey .Release.Parent.Values.infrastructure.postgresql "installInCluster" }}
      {{- /* Legacy support: installInCluster as alternative to deploy */}}
      {{- $deploy = .Release.Parent.Values.infrastructure.postgresql.installInCluster }}
    {{- end }}
  {{- end }}
{{- end }}
{{- /* Also check controlPlane.components.postgresql.installInCluster for backward compatibility */}}
{{- if and (not $found) .Values.controlPlane .Values.controlPlane.components .Values.controlPlane.components.postgresql (hasKey .Values.controlPlane.components.postgresql "installInCluster") }}
  {{- $deploy = .Values.controlPlane.components.postgresql.installInCluster }}
{{- end }}
{{- /* Return empty string for false, non-empty for true - Helm's include returns strings, and empty string is falsy */}}
{{- if $deploy }}{{- "true" }}{{- end }}
{{- end }}

