{{- define "dataagent.secrets" -}}
{{- if and (include "neuraltrust-platform.autoGenerateSecrets" .) (not .Values.global.preserveExistingSecrets) (not (default dict .Values.existingSecret).name) }}
{{- /*
DataAgent secret. ENROLMENT_TOKEN is issued by SaaS and is never auto-generated —
we source it from values, falling back to the existing in-cluster secret on upgrade.

v2 hybrid: DB_* and SENSIBLE_PG_DSN (as DATABASE_URL) are supplied through the
shared `postgresql-secrets` Secret (via envFrom + env override on the
Deployment), so this Secret only carries ENROLMENT_TOKEN when using shared PG.
*/}}
{{- $secretName := include "dataagent.secretName" . }}
{{- $existing := (lookup "v1" "Secret" .Release.Namespace $secretName) }}
{{- $enrolment := default dict .Values.enrolment }}
{{- $enrolmentExisting := default dict $enrolment.existingSecret }}
{{- $hasExplicit := or $enrolment.token $enrolmentExisting.name .Values.databaseUrl .Values.database.password }}
{{- if or .Release.IsInstall $existing $hasExplicit }}
{{- $existingData := dict }}
{{- if and $existing (kindIs "map" $existing) $existing.data }}
  {{- $existingData = $existing.data }}
{{- end }}
{{- $token := $enrolment.token | default "" }}
{{- if and (not $token) (hasKey $existingData "ENROLMENT_TOKEN") }}
  {{- $token = index $existingData "ENROLMENT_TOKEN" | b64dec }}
{{- end }}
{{- $useExplicitDb := or .Values.databaseUrl .Values.database.password }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ $secretName }}
  annotations:
    helm.sh/resource-policy: keep
  labels:
    {{- include "dataagent.labels" . | nindent 4 }}
type: Opaque
stringData:
  {{- if $token }}
  ENROLMENT_TOKEN: {{ $token | quote }}
  {{- end }}
  {{- if $useExplicitDb }}
  {{- $db := default dict .Values.database }}
  {{- $dbPw := include "neuraltrust-platform.resolveSecret" (dict "value" $db.password "existingSecret" $existing "secretKey" "DB_PASSWORD" "length" 32) }}
  {{- $dsn := .Values.databaseUrl }}
  {{- if not $dsn }}
    {{- $host := include "neuraltrust-platform.postgres.host" (dict "host" $db.host) }}
    {{- $port := $db.port | default 5432 }}
    {{- $name := $db.name | default (include "neuraltrust-platform.v2.hybridPg.database" .) }}
    {{- $user := $db.user | default (include "neuraltrust-platform.v2.hybridPg.user" .) }}
    {{- $ssl := $db.sslMode | default "prefer" }}
    {{- $dsn = printf "postgresql://%s:%s@%s:%v/%s?sslmode=%s" ($user | urlquery) ($dbPw | urlquery) $host $port $name $ssl }}
  {{- end }}
  DATABASE_URL: {{ $dsn | quote }}
  DB_PASSWORD: {{ $dbPw | quote }}
  {{- end }}
{{- end }}
{{- end }}
{{- end }}
