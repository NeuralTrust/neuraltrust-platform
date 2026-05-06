{{/*
Construct image path with optional global registry prefix.
*/}}
{{- define "siemConnectors.image" -}}
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
Common labels.
*/}}
{{- define "siemConnectors.labels" -}}
app.kubernetes.io/name: siem-connectors
app.kubernetes.io/component: connector
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "siemConnectors.selectorLabels" -}}
app.kubernetes.io/name: siem-connectors
{{- end }}

{{/*
Resolve the Kafka brokers. Empty value falls back to the in-cluster Kafka service.
The default `kafka:9092` matches the parent chart's `kafka.fullnameOverride: "kafka"` default
(values.yaml). If a downstream values file overrides `kafka.fullnameOverride`, the operator
must also set `siemConnectors.kafka.brokers` to point at the right hostname.
*/}}
{{- define "siemConnectors.kafka.brokers" -}}
{{- if and .Values.siemConnectors.kafka .Values.siemConnectors.kafka.brokers (ne (.Values.siemConnectors.kafka.brokers | toString) "") -}}
{{- .Values.siemConnectors.kafka.brokers -}}
{{- else -}}
{{- "kafka:9092" -}}
{{- end -}}
{{- end }}

{{/*
Resolve the ClickHouse host. Empty value falls back to the in-cluster ClickHouse service.
The default `http://clickhouse:8123` matches the parent chart's
`clickhouse.fullnameOverride: "clickhouse"` default (values.yaml). Override
`siemConnectors.clickhouse.host` if you change `clickhouse.fullnameOverride`.
*/}}
{{- define "siemConnectors.clickhouse.host" -}}
{{- if and .Values.siemConnectors.clickhouse .Values.siemConnectors.clickhouse.host (ne (.Values.siemConnectors.clickhouse.host | toString) "") -}}
{{- .Values.siemConnectors.clickhouse.host -}}
{{- else -}}
{{- "http://clickhouse:8123" -}}
{{- end -}}
{{- end }}

{{/*
Resolve the security context, adding readOnlyRootFilesystem when securityHardening is on.
*/}}
{{- define "siemConnectors.securityContext" -}}
{{- $sc := .Values.siemConnectors.securityContext | default dict }}
{{- if .Values.securityHardening }}
{{- $sc = mustMergeOverwrite $sc (dict "readOnlyRootFilesystem" true) }}
{{- end }}
{{- if $sc }}
{{- toYaml $sc }}
{{- end }}
{{- end }}
