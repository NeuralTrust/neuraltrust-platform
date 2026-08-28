{{- define "dataagent.egressConfigmapData" -}}
{{- $egressCfg := default dict (default dict (default dict .Values.global).clickstack).egress -}}
extensions:
  health_check:
    # Default global.clickstack.egress.listenHost "::" → [::]:port (dual-stack
    # on Linux). 0.0.0.0 is IPv4-only and breaks probes/Service on IpFamily=ipv6.
    endpoint: {{ include "neuraltrust-platform.clickstackEgress.listenEndpoint" (dict "ctx" . "port" 13133) | quote }}
  oauth2client:
    client_id: {{ include "neuraltrust-platform.clickstackEgress.clientId" . | quote }}
    client_secret: {{ include "neuraltrust-platform.clickstackEgress.clientSecret" . | quote }}
    token_url: {{ include "neuraltrust-platform.clickstackEgress.tokenURL" . | quote }}
    scopes: ["otlp:write"]
    timeout: 10s
    {{- /* Refresh this far ahead of expiry. The token TTL reads like an hour of
           cover but is not: at 2m the agent refreshed ~58min in, and a broker
           outage spanning that moment failed the mint outright. 10m absorbs a
           short outage using the token's own remaining validity, before the
           queue below has to do anything (AUT-510). */}}
    expiry_buffer: 10m
  {{- /* Disk-backed queue for the exporter. Without it there is no buffer at all:
         a batch in flight when the broker goes away is retried in memory and then
         dropped, and anything held is lost if the collector restarts.

         The directory must be a mounted volume — this container runs
         readOnlyRootFilesystem: true. The chart mounts an emptyDir, so the queue
         survives a collector restart and the outage itself but NOT pod
         rescheduling. That is deliberate: a PersistentVolume here would put a
         storage requirement on every hybrid data plane, including air-gapped and
         edge installs with no dynamic provisioner. */}}
  file_storage/queue:
    directory: /var/lib/otelcol/queue

receivers:
  otlp:
    protocols:
      grpc:
        endpoint: {{ include "neuraltrust-platform.clickstackEgress.listenEndpoint" (dict "ctx" . "port" 4317) | quote }}
      http:
        endpoint: {{ include "neuraltrust-platform.clickstackEgress.listenEndpoint" (dict "ctx" . "port" 4318) | quote }}

processors:
  memory_limiter:
    check_interval: 1s
    limit_percentage: 65
    spike_limit_percentage: 20
  batch:
    send_batch_size: 200
    send_batch_max_size: 200
    timeout: 1s

exporters:
  otlphttp/saas:
    endpoint: {{ include "neuraltrust-platform.clickstackEgress.saasEndpoint" . | quote }}
    auth:
      authenticator: oauth2client
    compression: gzip
    {{- $egressCa := include "neuraltrust-platform.clickstackEgress.tlsCaSecretName" . -}}
    {{- if $egressCa }}
    tls:
      ca_file: /etc/otelcol/ca/ca.crt
      {{- /* ca_file alone replaces system roots (otelcol default). Keep them
             so a chart CA for DataBridge/config-sync does not break a
             publicly-terminated telemetry hop. */}}
      {{- if eq (include "neuraltrust-platform.clickstackEgress.includeSystemCaCerts" .) "true" }}
      include_system_ca_certs_pool: true
      {{- end }}
    {{- end }}
    sending_queue:
      enabled: true
      storage: file_storage/queue
      {{- /* Batches, not bytes. Paired with the 1Gi emptyDir sizeLimit on the
             mount so a long outage cannot fill the node's ephemeral storage. */}}
      queue_size: 1000
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      {{- /* Was 300s, which is why a >5min broker outage lost telemetry: the
             exporter gave up and dropped the batch. 30m is past any plausible
             broker outage and still bounded, so a permanently rejected batch
             cannot wedge the queue forever. */}}
      max_elapsed_time: 1800s

service:
  extensions: [health_check, oauth2client, file_storage/queue]
  pipelines:
    logs:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlphttp/saas]
    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlphttp/saas]
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlphttp/saas]
  telemetry:
    logs:
      level: info
{{- end }}

{{- define "dataagent.egressConfigmap" -}}
{{- if .Values.egressPrimary }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "neuraltrust-platform.clickstackEgress.fullname" . }}-config
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "dataagent.labels" . | nindent 4 }}
    app.kubernetes.io/component: clickstack-egress-collector
data:
  config.yaml: |
    {{- include "dataagent.egressConfigmapData" . | nindent 4 }}
{{- end }}
{{- end }}
