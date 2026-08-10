{{- define "dataagent.envConfigMap" -}}
{{- /* Empty addr derives the regional SaaS host from global.saasRegion; an
       explicit addr keeps its own host as SNI unless serverName overrides. */ -}}
{{- $addr := .Values.databridge.addr | default (include "neuraltrust-platform.saas.databridgeAddr" .) -}}
{{- $serverName := .Values.databridge.serverName | default (regexReplaceAll ":[0-9]+$" $addr "") -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "dataagent.envConfigMapName" . }}
  labels:
    {{- include "dataagent.labels" . | nindent 4 }}
data:
  DATABRIDGE_ADDR: {{ $addr | quote }}
  DATABRIDGE_SERVER_NAME: {{ $serverName | quote }}
  TLS_MODE: {{ .Values.databridge.tlsMode | quote }}
{{- with .Values.databridge.tlsCa }}
  TLS_CA_FILE: {{ . | quote }}
{{- end }}
{{- if eq .Values.databridge.tlsMode "insecure" }}
  {{- /* The binary refuses to start on insecure transport without this explicit
         opt-in, so omitting it would make tlsMode=insecure a crash loop. */}}
  ALLOW_INSECURE_TRANSPORT: "true"
{{- end }}
  STORE_BACKEND: {{ .Values.store.backend | quote }}
  HEALTH_ADDR: {{ printf ":%v" .Values.ports.health | quote }}
  BACKOFF_MIN: {{ .Values.supervisor.backoffMin | quote }}
  BACKOFF_MAX: {{ .Values.supervisor.backoffMax | quote }}
  KEEPALIVE_TIME: {{ .Values.supervisor.keepaliveTime | quote }}
  KEEPALIVE_TIMEOUT: {{ .Values.supervisor.keepaliveTimeout | quote }}
  MAX_CONCURRENT_QUERIES: {{ .Values.supervisor.maxConcurrentQueries | quote }}
{{- end }}
