{{/*
Construct image path with optional global registry prefix.
Usage: {{ include "aispm.image" (dict "repository" "repo" "tag" "v1" "global" .Values.global) }}
*/}}
{{- define "aispm.image" -}}
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
Common labels shared by every aispm workload.
Usage: {{ include "aispm.labels" (dict "component" "api" "context" .) }}
*/}}
{{- define "aispm.labels" -}}
app.kubernetes.io/name: aispm
app.kubernetes.io/component: {{ .component }}
app.kubernetes.io/instance: {{ .context.Release.Name }}
app.kubernetes.io/managed-by: {{ .context.Release.Service }}
{{- end }}

{{/*
Selector labels — call with (dict "component" "api")
*/}}
{{- define "aispm.selectorLabels" -}}
app.kubernetes.io/name: aispm
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Resolve the Redis host. Empty value falls back to the bundled TrustGate redis service.
Usage: {{ include "aispm.redis.host" . }}
*/}}
{{- define "aispm.redis.host" -}}
{{- if and .Values.aispm.redis .Values.aispm.redis.host (ne (.Values.aispm.redis.host | toString) "") -}}
{{- .Values.aispm.redis.host -}}
{{- else -}}
{{- printf "%s-redis-master" .Release.Name -}}
{{- end -}}
{{- end }}

{{/*
Resolve the Kafka bootstrap servers. Empty value falls back to the in-cluster Kafka service.
Usage: {{ include "aispm.kafka.bootstrapServers" . }}
*/}}
{{- define "aispm.kafka.bootstrapServers" -}}
{{- if and .Values.aispm.kafka .Values.aispm.kafka.bootstrapServers (ne (.Values.aispm.kafka.bootstrapServers | toString) "") -}}
{{- .Values.aispm.kafka.bootstrapServers -}}
{{- else -}}
{{- printf "%s-kafka:9092" .Release.Name -}}
{{- end -}}
{{- end }}

{{/*
Resolve the public AISPM API URL. Empty value falls back to the in-cluster Service FQDN.
Usage: {{ include "aispm.apiUrl" . }}
*/}}
{{- define "aispm.apiUrl" -}}
{{- if and .Values.aispm.config .Values.aispm.config.aispmApiUrl (ne (.Values.aispm.config.aispmApiUrl | toString) "") -}}
{{- .Values.aispm.config.aispmApiUrl -}}
{{- else -}}
{{- printf "http://aispm-api-service.%s.svc.cluster.local:80" .Release.Namespace -}}
{{- end -}}
{{- end }}

{{/*
Common env block injected into the api / worker / beat containers.
Usage: {{ include "aispm.commonEnv" . | nindent 12 }}
*/}}
{{- define "aispm.commonEnv" -}}
- name: DATABASE_HOST
  value: {{ .Values.aispm.database.host | quote }}
- name: DATABASE_PORT
  value: {{ .Values.aispm.database.port | quote }}
- name: DATABASE_USER
  value: {{ .Values.aispm.database.user | quote }}
- name: DATABASE_NAME
  value: {{ .Values.aispm.database.name | quote }}
- name: DATABASE_SSL_MODE
  value: {{ .Values.aispm.database.sslMode | quote }}
- name: DATABASE_PASSWORD
  valueFrom:
    secretKeyRef:
      name: aispm-secrets
      key: DATABASE_PASSWORD
- name: AUTH_ENCRYPTION_KEY
  valueFrom:
    secretKeyRef:
      name: aispm-secrets
      key: AUTH_ENCRYPTION_KEY
- name: OPENAI_API_KEY
  valueFrom:
    secretKeyRef:
      name: aispm-secrets
      key: OPENAI_API_KEY
      optional: true
- name: GITHUB_APP_ID
  valueFrom:
    secretKeyRef:
      name: aispm-secrets
      key: GITHUB_APP_ID
      optional: true
- name: GITHUB_APP_PRIVATE_KEY
  valueFrom:
    secretKeyRef:
      name: aispm-secrets
      key: GITHUB_APP_PRIVATE_KEY
      optional: true
- name: GITHUB_WEBHOOK_SECRET
  valueFrom:
    secretKeyRef:
      name: aispm-secrets
      key: GITHUB_WEBHOOK_SECRET
      optional: true
- name: AZURE_TENANT_ID
  valueFrom:
    secretKeyRef:
      name: aispm-secrets
      key: AZURE_TENANT_ID
      optional: true
- name: AZURE_CLIENT_ID
  valueFrom:
    secretKeyRef:
      name: aispm-secrets
      key: AZURE_CLIENT_ID
      optional: true
- name: AZURE_CLIENT_SECRET
  valueFrom:
    secretKeyRef:
      name: aispm-secrets
      key: AZURE_CLIENT_SECRET
      optional: true
- name: RESEND_API_KEY
  valueFrom:
    secretKeyRef:
      name: aispm-secrets
      key: RESEND_API_KEY
      optional: true
- name: ADMIN_API_KEY
  valueFrom:
    secretKeyRef:
      name: aispm-secrets
      key: ADMIN_API_KEY
      optional: true
- name: JWT_SECRET
  valueFrom:
    secretKeyRef:
      name: data-plane-jwt-secret
      key: DATA_PLANE_JWT_SECRET
      optional: true
- name: REDIS_HOST
  value: {{ include "aispm.redis.host" . | quote }}
- name: REDIS_PORT
  value: {{ .Values.aispm.redis.port | quote }}
- name: REDIS_DATABASE
  value: {{ .Values.aispm.redis.database | quote }}
- name: KAFKA_BOOTSTRAP_SERVERS
  value: {{ include "aispm.kafka.bootstrapServers" . | quote }}
- name: AISPM_API_URL
  value: {{ include "aispm.apiUrl" . | quote }}
{{- end }}

{{/*
Resolve a security context, adding readOnlyRootFilesystem when securityHardening is on.
Usage: {{ include "aispm.securityContext" . | nindent 12 }}
*/}}
{{- define "aispm.securityContext" -}}
{{- $sc := .Values.aispm.securityContext | default dict }}
{{- if .Values.securityHardening }}
{{- $sc = mustMergeOverwrite $sc (dict "readOnlyRootFilesystem" true) }}
{{- end }}
{{- if $sc }}
{{- toYaml $sc }}
{{- end }}
{{- end }}
