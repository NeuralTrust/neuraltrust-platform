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
{{- if $context.Values }}
  {{- if $context.Values.controlPlane }}
    {{- $cp := $context.Values.controlPlane }}
    {{- if kindIs "map" $cp }}
      {{- if hasKey $cp "preserveExistingSecrets" }}
        {{- $preserveVal := index $cp "preserveExistingSecrets" }}
        {{- if $preserveVal }}
          {{- $preserveSecrets = $preserveVal }}
        {{- end }}
      {{- end }}
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
{{- if $context.Values }}
  {{- if $context.Values.controlPlane }}
    {{- $cp := $context.Values.controlPlane }}
    {{- if kindIs "map" $cp }}
      {{- if hasKey $cp "preserveExistingSecrets" }}
        {{- $preserveVal := index $cp "preserveExistingSecrets" }}
        {{- if $preserveVal }}
          {{- $preserveSecrets = $preserveVal }}
        {{- end }}
      {{- end }}
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

