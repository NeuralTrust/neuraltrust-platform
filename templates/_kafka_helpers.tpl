{{/*
Kafka connection helpers — bootstrap, SASL auth, and TLS.

All connection settings live under global.kafka (merged into every subchart).
Leave bootstrapServers and brokers empty for in-cluster Kafka (kafka:9092,
PLAINTEXT). Set bootstrapServers (or brokers) only when using a pre-installed
broker with infrastructure.kafka.deploy: false.

When external Kafka is active, the chart renders a shared ConfigMap
`kafka-connection` and injects credential env vars from an existing Secret
(existingSecret pattern — never created by this chart).

global.customCaCert is for HTTP/TLS egress only — it must not enable Kafka TLS
on its own; in-cluster Kafka uses PLAINTEXT on kafka:9092.
*/}}

{{/*
True when global.kafka.bootstrapServers or global.kafka.brokers is configured.
Subcharts only see global.* — do not gate on infrastructure.kafka.external.
*/}}
{{- define "neuraltrust-platform.kafka.useExternal" -}}
{{- $kafka := default dict (default dict .Values.global).kafka -}}
{{- if and $kafka.bootstrapServers (ne ($kafka.bootstrapServers | toString) "") -}}true
{{- else if and $kafka.brokers (gt (len $kafka.brokers) 0) -}}true
{{- end -}}
{{- end -}}

{{/*
Resolved global.kafka settings as YAML (bootstrapServers, brokers, auth, tls).
*/}}
{{- define "neuraltrust-platform.kafka.config" -}}
{{- $kafka := default dict (default dict .Values.global).kafka -}}
{{- toYaml $kafka -}}
{{- end -}}

{{/*
Resolved bootstrap server list (comma-separated).
Optional dict key connectOverride: per-component bootstrap override.
*/}}
{{- define "neuraltrust-platform.kafka.bootstrapServers" -}}
{{- $override := "" -}}
{{- if kindIs "map" . -}}
  {{- if .connectOverride -}}
    {{- $override = .connectOverride -}}
  {{- end -}}
{{- end -}}
{{- $ctx := . -}}
{{- if kindIs "map" . -}}
  {{- if .context -}}
    {{- $ctx = .context -}}
  {{- end -}}
{{- end -}}
{{- if and $override (ne $override "") -}}
{{- $override -}}
{{- else if eq (include "neuraltrust-platform.kafka.useExternal" $ctx) "true" -}}
{{- $cfg := include "neuraltrust-platform.kafka.config" $ctx | fromYaml -}}
{{- if $cfg.bootstrapServers -}}
{{- $cfg.bootstrapServers -}}
{{- else if $cfg.brokers -}}
{{- join "," $cfg.brokers -}}
{{- else -}}
{{- "kafka:9092" -}}
{{- end -}}
{{- else -}}
{{- "kafka:9092" -}}
{{- end -}}
{{- end -}}

{{/*
First broker host and port from the resolved bootstrap string.
*/}}
{{- define "neuraltrust-platform.kafka.host" -}}
{{- $bs := include "neuraltrust-platform.kafka.bootstrapServers" . -}}
{{- $first := index (splitList "," $bs) 0 -}}
{{- $hostport := splitList ":" $first -}}
{{- index $hostport 0 -}}
{{- end -}}

{{- define "neuraltrust-platform.kafka.port" -}}
{{- $bs := include "neuraltrust-platform.kafka.bootstrapServers" . -}}
{{- $first := index (splitList "," $bs) 0 -}}
{{- $hostport := splitList ":" $first -}}
{{- if gt (len $hostport) 1 -}}
{{- index $hostport 1 -}}
{{- else -}}
9092
{{- end -}}
{{- end -}}

{{/*
Resolved auth settings (enabled flag, mechanism, secret keys).
*/}}
{{- define "neuraltrust-platform.kafka.authConfig" -}}
{{- $cfg := include "neuraltrust-platform.kafka.config" . | fromYaml -}}
{{- $auth := default dict $cfg.auth -}}
{{- $enabled := $auth.enabled | default false -}}
{{- if and (not $enabled) $auth.existingSecret -}}
  {{- $enabled = true -}}
{{- end -}}
{{- if and (not $enabled) (or $auth.username $auth.password) -}}
  {{- $enabled = true -}}
{{- end -}}
{{- $out := dict
  "enabled" $enabled
  "mechanism" ($auth.mechanism | default "SCRAM-SHA-512")
  "existingSecret" ($auth.existingSecret | default "")
  "usernameKey" ($auth.usernameKey | default "username")
  "passwordKey" ($auth.passwordKey | default "password")
  "jaasConfigKey" ($auth.jaasConfigKey | default "")
  "username" ($auth.username | default "")
-}}
{{- toYaml $out -}}
{{- end -}}

{{/*
Resolved TLS settings. Requires global.kafka.tls.enabled or tls.existingSecret.
global.customCaCert may supply the CA Secret/path when TLS is explicitly enabled,
but must never turn TLS on by itself.
*/}}
{{- define "neuraltrust-platform.kafka.tlsConfig" -}}
{{- $cfg := include "neuraltrust-platform.kafka.config" . | fromYaml -}}
{{- $tls := default dict $cfg.tls -}}
{{- $enabled := $tls.enabled | default false -}}
{{- $caSecret := $tls.existingSecret | default "" -}}
{{- if and (not $caSecret) $enabled -}}
  {{- $customCa := default dict (default dict .Values.global).customCaCert -}}
  {{- if and $customCa.enabled $customCa.secretName -}}
    {{- $caSecret = $customCa.secretName -}}
  {{- end -}}
{{- end -}}
{{- if and (not $enabled) $caSecret -}}
  {{- $enabled = true -}}
{{- end -}}
{{- $mountPath := $tls.mountPath | default "" -}}
{{- if not $mountPath -}}
  {{- if and $enabled (eq (include "neuraltrust-platform.customCaCert.enabled" .) "true") -}}
    {{- $mountPath = include "neuraltrust-platform.customCaCert.path" . -}}
  {{- else -}}
    {{- $mountPath = "/etc/kafka/ssl/ca.crt" -}}
  {{- end -}}
{{- end -}}
{{- toYaml (dict
  "enabled" $enabled
  "existingSecret" $caSecret
  "caKey" ($tls.caKey | default "ca.crt")
  "mountPath" $mountPath
) -}}
{{- end -}}

{{/*
security.protocol derived from auth + TLS flags.
*/}}
{{- define "neuraltrust-platform.kafka.securityProtocol" -}}
{{- $auth := include "neuraltrust-platform.kafka.authConfig" . | fromYaml -}}
{{- $tls := include "neuraltrust-platform.kafka.tlsConfig" . | fromYaml -}}
{{- if and $auth.enabled $tls.enabled -}}SASL_SSL
{{- else if $auth.enabled -}}SASL_PLAINTEXT
{{- else if $tls.enabled -}}SSL
{{- else -}}PLAINTEXT
{{- end -}}
{{- end -}}

{{/*
Non-secret env vars for Python / Go / Node Kafka clients.
Usage: {{- include "neuraltrust-platform.kafka.clientEnv" . | nindent 8 }}
*/}}
{{- define "neuraltrust-platform.kafka.clientEnv" -}}
- name: KAFKA_BOOTSTRAP_SERVERS
  value: {{ include "neuraltrust-platform.kafka.bootstrapServers" . | quote }}
{{- include "neuraltrust-platform.kafka.authEnv" . }}
{{- end -}}

{{/*
SASL/TLS env vars only (no bootstrap). Use when the workload sets its own
broker env shape (KAFKA_BROKERS, KAFKA_HOST/KAFKA_PORT, …).
Usage: {{- include "neuraltrust-platform.kafka.authEnv" . | nindent 8 }}
*/}}
{{- define "neuraltrust-platform.kafka.authEnv" -}}
{{- $auth := include "neuraltrust-platform.kafka.authConfig" . | fromYaml -}}
{{- $tls := include "neuraltrust-platform.kafka.tlsConfig" . | fromYaml -}}
{{- $protocol := include "neuraltrust-platform.kafka.securityProtocol" . -}}
{{- if ne $protocol "PLAINTEXT" }}
- name: KAFKA_SECURITY_PROTOCOL
  value: {{ $protocol | quote }}
{{- end }}
{{- if $auth.enabled }}
- name: KAFKA_SASL_MECHANISM
  value: {{ $auth.mechanism | quote }}
{{- if $auth.username }}
- name: KAFKA_SASL_USERNAME
  value: {{ $auth.username | quote }}
{{- else if and $auth.existingSecret (not $auth.jaasConfigKey) }}
- name: KAFKA_SASL_USERNAME
  valueFrom:
    secretKeyRef:
      name: {{ $auth.existingSecret | quote }}
      key: {{ $auth.usernameKey | quote }}
{{- end }}
{{- if and $auth.existingSecret $auth.jaasConfigKey }}
- name: KAFKA_SASL_JAAS_CONFIG
  valueFrom:
    secretKeyRef:
      name: {{ $auth.existingSecret | quote }}
      key: {{ $auth.jaasConfigKey | quote }}
{{- end }}
{{- if and $auth.existingSecret (not $auth.jaasConfigKey) }}
- name: KAFKA_SASL_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ $auth.existingSecret | quote }}
      key: {{ $auth.passwordKey | quote }}
{{- end }}
{{- end }}
{{- if $tls.enabled }}
- name: KAFKA_SSL_CA_LOCATION
  value: {{ $tls.mountPath | quote }}
{{- end }}
{{- end -}}

{{/*
Kafka Connect worker env vars (CONNECT_* + KAFKA_* consumed by docker-entrypoint.sh).
Usage: {{- include "neuraltrust-platform.kafka.connectEnv" (dict "context" . "connectOverride" $bs) | nindent 12 }}
*/}}
{{- define "neuraltrust-platform.kafka.connectEnv" -}}
{{- $ctx := .context -}}
{{- $bs := include "neuraltrust-platform.kafka.bootstrapServers" . -}}
{{- $auth := include "neuraltrust-platform.kafka.authConfig" $ctx | fromYaml -}}
{{- $tls := include "neuraltrust-platform.kafka.tlsConfig" $ctx | fromYaml -}}
{{- $protocol := include "neuraltrust-platform.kafka.securityProtocol" $ctx -}}
- name: CONNECT_BOOTSTRAP_SERVERS
  value: {{ $bs | quote }}
{{- if ne $protocol "PLAINTEXT" }}
- name: CONNECT_SECURITY_PROTOCOL
  value: {{ $protocol | quote }}
- name: CONNECT_PRODUCER_SECURITY_PROTOCOL
  value: {{ $protocol | quote }}
- name: CONNECT_CONSUMER_SECURITY_PROTOCOL
  value: {{ $protocol | quote }}
{{- end }}
{{- if $auth.enabled }}
- name: CONNECT_SASL_MECHANISM
  value: {{ $auth.mechanism | quote }}
- name: CONNECT_PRODUCER_SASL_MECHANISM
  value: {{ $auth.mechanism | quote }}
- name: CONNECT_CONSUMER_SASL_MECHANISM
  value: {{ $auth.mechanism | quote }}
{{- if $auth.username }}
- name: KAFKA_SASL_USERNAME
  value: {{ $auth.username | quote }}
{{- else if and $auth.existingSecret (not $auth.jaasConfigKey) }}
- name: KAFKA_SASL_USERNAME
  valueFrom:
    secretKeyRef:
      name: {{ $auth.existingSecret | quote }}
      key: {{ $auth.usernameKey | quote }}
{{- end }}
{{- if and $auth.existingSecret $auth.jaasConfigKey }}
- name: CONNECT_SASL_JAAS_CONFIG
  valueFrom:
    secretKeyRef:
      name: {{ $auth.existingSecret | quote }}
      key: {{ $auth.jaasConfigKey | quote }}
- name: CONNECT_PRODUCER_SASL_JAAS_CONFIG
  valueFrom:
    secretKeyRef:
      name: {{ $auth.existingSecret | quote }}
      key: {{ $auth.jaasConfigKey | quote }}
- name: CONNECT_CONSUMER_SASL_JAAS_CONFIG
  valueFrom:
    secretKeyRef:
      name: {{ $auth.existingSecret | quote }}
      key: {{ $auth.jaasConfigKey | quote }}
{{- else if and $auth.existingSecret (not $auth.jaasConfigKey) }}
- name: KAFKA_SASL_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ $auth.existingSecret | quote }}
      key: {{ $auth.passwordKey | quote }}
{{- end }}
{{- end }}
{{- if $tls.enabled }}
- name: CONNECT_SSL_TRUSTSTORE_TYPE
  value: "PEM"
- name: CONNECT_SSL_TRUSTSTORE_LOCATION
  value: {{ $tls.mountPath | quote }}
- name: CONNECT_PRODUCER_SSL_TRUSTSTORE_TYPE
  value: "PEM"
- name: CONNECT_PRODUCER_SSL_TRUSTSTORE_LOCATION
  value: {{ $tls.mountPath | quote }}
- name: CONNECT_CONSUMER_SSL_TRUSTSTORE_TYPE
  value: "PEM"
- name: CONNECT_CONSUMER_SSL_TRUSTSTORE_LOCATION
  value: {{ $tls.mountPath | quote }}
{{- end }}
{{- end -}}

{{/*
Optional envFrom for the shared kafka-connection ConfigMap.
Usage: {{- include "neuraltrust-platform.kafka.envFrom" . | nindent 8 }}
*/}}
{{- define "neuraltrust-platform.kafka.envFrom" -}}
{{- if eq (include "neuraltrust-platform.kafka.useExternal" .) "true" -}}
- configMapRef:
    name: kafka-connection
    optional: true
{{- end -}}
{{- end -}}

{{/*
Pod volume for a dedicated Kafka broker CA (when tls.existingSecret is set and
differs from global.customCaCert).
Usage: {{- include "neuraltrust-platform.kafka.tlsVolume" . | nindent 8 }}
*/}}
{{- define "neuraltrust-platform.kafka.tlsVolume" -}}
{{- $tls := include "neuraltrust-platform.kafka.tlsConfig" . | fromYaml -}}
{{- $customCa := default dict (default dict .Values.global).customCaCert -}}
{{- if and $tls.enabled $tls.existingSecret -}}
{{- if or (not $customCa.enabled) (ne $tls.existingSecret $customCa.secretName) -}}
- name: kafka-broker-ca
  secret:
    secretName: {{ $tls.existingSecret | quote }}
    items:
      - key: {{ $tls.caKey | quote }}
        path: ca.crt
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Volume mount for kafka-broker-ca (subPath ca.crt at tls.mountPath).
*/}}
{{- define "neuraltrust-platform.kafka.tlsVolumeMount" -}}
{{- $tls := include "neuraltrust-platform.kafka.tlsConfig" . | fromYaml -}}
{{- $customCa := default dict (default dict .Values.global).customCaCert -}}
{{- if and $tls.enabled $tls.existingSecret -}}
{{- if or (not $customCa.enabled) (ne $tls.existingSecret $customCa.secretName) -}}
- name: kafka-broker-ca
  mountPath: {{ $tls.mountPath | quote }}
  subPath: ca.crt
  readOnly: true
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Shell snippet for kafka-connect entrypoint wrapper — builds CONNECT_SASL_JAAS_CONFIG
from KAFKA_SASL_USERNAME / KAFKA_SASL_PASSWORD when not supplied via secret key.
*/}}
{{- define "neuraltrust-platform.kafka.connectJaasBootstrap" -}}
{{- $auth := include "neuraltrust-platform.kafka.authConfig" . | fromYaml -}}
{{- if and $auth.enabled (not $auth.jaasConfigKey) -}}
if [ -n "${KAFKA_SASL_USERNAME:-}" ] && [ -n "${KAFKA_SASL_PASSWORD:-}" ]; then
  {{- if eq $auth.mechanism "PLAIN" }}
  JAAS="org.apache.kafka.common.security.plain.PlainLoginModule required username=\"${KAFKA_SASL_USERNAME}\" password=\"${KAFKA_SASL_PASSWORD}\";"
  {{- else }}
  JAAS="org.apache.kafka.common.security.scram.ScramLoginModule required username=\"${KAFKA_SASL_USERNAME}\" password=\"${KAFKA_SASL_PASSWORD}\";"
  {{- end }}
  export CONNECT_SASL_JAAS_CONFIG="${JAAS}"
  export CONNECT_PRODUCER_SASL_JAAS_CONFIG="${JAAS}"
  export CONNECT_CONSUMER_SASL_JAAS_CONFIG="${JAAS}"
fi
{{- end -}}
{{- end -}}

{{/*
Client properties file content for kafka CLI tools (init containers).
*/}}
{{- define "neuraltrust-platform.kafka.clientProperties" -}}
{{- $bs := include "neuraltrust-platform.kafka.bootstrapServers" . -}}
{{- $auth := include "neuraltrust-platform.kafka.authConfig" . | fromYaml -}}
{{- $tls := include "neuraltrust-platform.kafka.tlsConfig" . | fromYaml -}}
{{- $protocol := include "neuraltrust-platform.kafka.securityProtocol" . -}}
bootstrap.servers={{ $bs }}
security.protocol={{ $protocol }}
{{- if $auth.enabled }}
sasl.mechanism={{ $auth.mechanism }}
{{- end }}
{{- if $tls.enabled }}
ssl.truststore.type=PEM
ssl.truststore.location={{ $tls.mountPath }}
{{- end }}
{{- end -}}
