{{/*
Helpers for the in-chart OpenTelemetry Collector.
All helpers are namespaced under `neuraltrust-platform.otelCollector.*`
to avoid clashing with subchart helpers.
*/}}

{{- define "neuraltrust-platform.otelCollector.fullname" -}}
{{- $obs := default dict (default dict .Values.global).observability -}}
{{- $coll := default dict $obs.collector -}}
{{- default "otel-collector" $coll.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "neuraltrust-platform.otelCollector.serviceAccountName" -}}
{{- $obs := default dict (default dict .Values.global).observability -}}
{{- $sa := default dict (default dict $obs.collector).serviceAccount -}}
{{- if and $sa (eq (default true $sa.create | toString) "true") -}}
  {{- default (include "neuraltrust-platform.otelCollector.fullname" .) $sa.name -}}
{{- else -}}
  {{- default "default" $sa.name -}}
{{- end -}}
{{- end -}}

{{/*
True/false-ish helper: returns "true" when the in-chart OTel Collector
should render. Default OFF (`global.observability.enabled: false`).
Also turns on when `neuraltrust-watchdog.enabled` is true — the collector
is the telemetry sink the watchdog stack expects (Prometheus scrapes,
kubeletstats, optional hosted export). Explicit
`global.observability.enabled: true` enables the collector without
watchdog.
*/}}
{{- define "neuraltrust-platform.otelCollector.enabled" -}}
{{- $obs := default dict (default dict .Values.global).observability -}}
{{- $watchdog := index .Values "neuraltrust-watchdog" | default dict -}}
{{- $watchdogOn := default false $watchdog.enabled -}}
{{- $obsOn := default false $obs.enabled -}}
{{- if or $obsOn $watchdogOn -}}true{{- end -}}
{{- end -}}

{{/*
Resolve the in-cluster Service URL components consume to write OTLP/HTTP.
Renders as host:port (no scheme) so callers can choose http:// or grpc.
*/}}
{{- define "neuraltrust-platform.otelCollector.endpointHost" -}}
{{- printf "%s.%s.svc.cluster.local" (include "neuraltrust-platform.otelCollector.fullname" .) .Release.Namespace -}}
{{- end -}}

{{- define "neuraltrust-platform.otelCollector.otlpHTTPEndpoint" -}}
{{- printf "http://%s:4318" (include "neuraltrust-platform.otelCollector.endpointHost" .) -}}
{{- end -}}

{{- define "neuraltrust-platform.otelCollector.otlpGRPCEndpoint" -}}
{{- printf "%s:4317" (include "neuraltrust-platform.otelCollector.endpointHost" .) -}}
{{- end -}}

{{/*
Resolve the hosted-export bearer token. Returns the literal token string
or empty string. Order:
  1. .Values.global.observability.hostedExport.auth.tokenValue
  2. existing Secret (lookup) under tokenSecretName/tokenSecretKey

CRITICAL: this MUST never `fail` when the token is missing. The caller
uses the empty result as the gate for whether to render the
`otlphttp/neuraltrust` exporter at all.
*/}}
{{- define "neuraltrust-platform.otelCollector.hostedToken" -}}
{{- $obs := default dict (default dict .Values.global).observability -}}
{{- $hosted := default dict $obs.hostedExport -}}
{{- $auth := default dict $hosted.auth -}}
{{- if and $auth.tokenValue (ne ($auth.tokenValue | toString) "") -}}
{{- $auth.tokenValue -}}
{{- else if $auth.tokenSecretName -}}
{{- $secret := lookup "v1" "Secret" .Release.Namespace $auth.tokenSecretName -}}
{{- if and $secret (kindIs "map" $secret) (hasKey $secret "data") -}}
  {{- $key := default "token" $auth.tokenSecretKey -}}
  {{- if hasKey $secret.data $key -}}
{{- index $secret.data $key | b64dec -}}
  {{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Returns "true" iff the hosted exporter should be rendered into the
collector pipeline. Both the feature flag must be on AND a token must
be resolvable. If either is false, the exporter is silently omitted —
the collector still runs and continues to scrape locally.
*/}}
{{- define "neuraltrust-platform.otelCollector.hostedExportRender" -}}
{{- $obs := default dict (default dict .Values.global).observability -}}
{{- $hosted := default dict $obs.hostedExport -}}
{{- if $hosted.enabled -}}
  {{- $token := include "neuraltrust-platform.otelCollector.hostedToken" . -}}
  {{- if $token -}}true{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Common labels for OTel collector resources.
*/}}
{{- define "neuraltrust-platform.otelCollector.labels" -}}
{{ include "neuraltrust-platform.labels" . }}
app.kubernetes.io/component: otel-collector
{{- end -}}

{{- define "neuraltrust-platform.otelCollector.selectorLabels" -}}
{{ include "neuraltrust-platform.selectorLabels" . }}
app.kubernetes.io/component: otel-collector
{{- end -}}

{{/*
Resolve imagePullSecrets for the in-chart OTel Collector. Priority:
  1. observability.collector.imagePullSecret == "none"/"" -> suppress entirely
     (nodes pull the private image via IAM / Workload Identity, no Secret).
  2. global.imagePullSecrets (list of strings or {name: ...} maps) -> umbrella-wide override.
  3. observability.collector.imagePullSecret (string) / default "gcr-secret" -> matches the rest of the chart.
Returns an "imagePullSecrets:" YAML block ready to inline, or empty.
Usage:
  spec:
    {{- include "neuraltrust-platform.otelCollector.imagePullSecrets" . | nindent 6 }}
*/}}
{{- define "neuraltrust-platform.otelCollector.imagePullSecrets" -}}
{{- $global := default dict .Values.global -}}
{{- $obs := default dict $global.observability -}}
{{- $coll := default dict $obs.collector -}}
{{- if and (hasKey $coll "imagePullSecret") (or (eq ($coll.imagePullSecret | toString) "none") (eq ($coll.imagePullSecret | toString) "")) -}}
{{- /* explicit opt-out: render nothing */ -}}
{{- else if $global.imagePullSecrets -}}
imagePullSecrets:
{{- range $global.imagePullSecrets }}
{{- if kindIs "string" . }}
  - name: {{ . }}
{{- else if kindIs "map" . }}
  - {{ toYaml . | nindent 4 | trim }}
{{- end }}
{{- end }}
{{- else -}}
imagePullSecrets:
  - name: {{ default "gcr-secret" $coll.imagePullSecret }}
{{- end -}}
{{- end -}}

{{/*
Resolve the storage class for the buffer PVC, falling back to
global.storageClass when the per-collector value is empty.
*/}}
{{- define "neuraltrust-platform.otelCollector.bufferStorageClass" -}}
{{- $obs := default dict (default dict .Values.global).observability -}}
{{- $coll := default dict $obs.collector -}}
{{- $buf := default dict $coll.bufferPVC -}}
{{- $sc := $buf.storageClass | default "" -}}
{{- if eq $sc "" -}}
  {{- $sc = default "" .Values.global.storageClass -}}
{{- end -}}
{{- $sc -}}
{{- end -}}
