{{/* Decision settings belong only on the gateway, never the shared worker ConfigMap. */}}
{{- define "firewall.decision.env" -}}
{{- $d := default dict .Values.firewall.gateway.decision -}}
{{- if $d.enabled -}}
{{- $settings := dict
  "PROVIDER" $d.provider
  "MODEL" $d.model
  "URL" $d.url
  "AUTH" $d.auth
  "CLOUDFLARE_ACCOUNT_ID" $d.cloudflareAccountId
  "ENTRA_SCOPE" $d.entraScope
  "PROJECT" $d.project
  "LOCATION" $d.location
  "TIMEOUT_S" $d.timeoutSeconds
  "MAX_RETRIES" $d.maxRetries
  "RETRY_BACKOFF_S" $d.retryBackoffSeconds
  "HEALTH_CACHE_S" $d.healthCacheSeconds
  "DOUBLE_CHECK" $d.doubleCheck
  "DOUBLE_CHECK_TIMEOUT_S" $d.doubleCheckTimeoutSeconds -}}
{{- range $name, $value := $settings -}}
{{- /* toString preserves false and zero; empty optional fields use app defaults. */ -}}
{{- if and (ne $value nil) (ne (toString $value) "") }}
- name: DECISION_SERVICE_{{ $name }}
  value: {{ $value | toString | quote }}
{{- end -}}
{{- end -}}
{{- $secret := default dict $d.apiKeyExistingSecret -}}
{{- if and (ne $d.provider "vertex") (ne $d.auth "entra") $secret.name }}
- name: DECISION_SERVICE_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $secret.name | quote }}
      key: {{ $secret.key | default "DECISION_SERVICE_API_KEY" | quote }}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* DECISION_SERVICE_* names the decision block owns. Others (for example
     TRUNCATE_CHARS) stay settable through gateway.extraEnv. */}}
{{- define "firewall.decision.managedEnv" -}}
PROVIDER MODEL URL AUTH CLOUDFLARE_ACCOUNT_ID ENTRA_SCOPE PROJECT LOCATION TIMEOUT_S MAX_RETRIES RETRY_BACKOFF_S HEALTH_CACHE_S DOUBLE_CHECK DOUBLE_CHECK_TIMEOUT_S API_KEY
{{- end -}}
