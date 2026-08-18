{{- define "dataagent.envConfigMap" -}}
{{- /* Dial + SNI + CA come from neuraltrust-platform.controlPlane.* so a hybrid
       install can retarget with global.controlPlane.{domain,databridgeAddr,
       caSecretName} alone. Product-level dataagent.databridge.* still wins. */ -}}
{{- $addr := include "neuraltrust-platform.controlPlane.databridgeAddr" . -}}
{{- $serverName := include "neuraltrust-platform.controlPlane.databridgeServerName" . -}}
{{- $tlsCa := include "neuraltrust-platform.controlPlane.databridgeTlsCa" . -}}
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
{{- with $tlsCa }}
  TLS_CA_FILE: {{ . | quote }}
{{- end }}
{{- if eq .Values.databridge.tlsMode "insecure" }}
  {{- /* The binary refuses to start on insecure transport without this explicit
         opt-in, so omitting it would make tlsMode=insecure a crash loop. */}}
  ALLOW_INSECURE_TRANSPORT: "true"
{{- end }}
{{- /* A blank STORE_BACKEND makes DataAgent reject every retrieval query, so
       never emit one. The umbrella resolves this from global.telemetry.raw. */}}
  STORE_BACKEND: {{ (default dict .Values.store).backend | default "postgres" | quote }}
  HEALTH_ADDR: {{ printf ":%v" .Values.ports.health | quote }}
  BACKOFF_MIN: {{ .Values.supervisor.backoffMin | quote }}
  BACKOFF_MAX: {{ .Values.supervisor.backoffMax | quote }}
  KEEPALIVE_TIME: {{ .Values.supervisor.keepaliveTime | quote }}
  KEEPALIVE_TIMEOUT: {{ .Values.supervisor.keepaliveTimeout | quote }}
  MAX_CONCURRENT_QUERIES: {{ .Values.supervisor.maxConcurrentQueries | quote }}
{{- end }}
