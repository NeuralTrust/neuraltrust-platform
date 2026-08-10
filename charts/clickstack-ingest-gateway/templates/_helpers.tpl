{{/*
Expand the name of the chart.
*/}}
{{- define "clickstack-ingest-gateway.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name. Pinned via fullnameOverride to a stable name.
*/}}
{{- define "clickstack-ingest-gateway.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "clickstack-ingest-gateway.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "clickstack-ingest-gateway.labels" -}}
helm.sh/chart: {{ include "clickstack-ingest-gateway.chart" . }}
app.kubernetes.io/name: {{ include "clickstack-ingest-gateway.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: neuraltrust-platform
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels (immutable fields)
*/}}
{{- define "clickstack-ingest-gateway.selectorLabels" -}}
app.kubernetes.io/name: {{ include "clickstack-ingest-gateway.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Service account name
*/}}
{{- define "clickstack-ingest-gateway.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default "clickstack-ingest-gateway" .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Whether this release deploys the ingest gateway. Only saas mode has senders it
does not already trust; external mode's collectors are all in-cluster and talk
to clickstack-collector directly.
*/}}
{{- define "clickstack-ingest-gateway.deploy" -}}
{{- if eq (include "neuraltrust-platform.isSaas" .) "true" }}true{{- end }}
{{- end }}

{{/*
Resolve the image reference, honoring global.imageRegistry (mirror support).
Same shape as dataagent.image: the default repository is already fully qualified,
so a mirror has to replace that registry rather than be prepended to it —
otherwise an air-gapped install ends up pulling <mirror>/europe-west1-docker.pkg.dev/…
Usage: {{ include "clickstack-ingest-gateway.image" (dict "repository" … "tag" … "global" .Values.global) }}
*/}}
{{- define "clickstack-ingest-gateway.image" -}}
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
imagePullSecrets block. Priority: .Values.imagePullSecrets > global.imagePullSecrets.
Emits nothing when unset or "none".
Usage: {{- include "clickstack-ingest-gateway.imagePullSecrets" . | nindent 6 }}
*/}}
{{- define "clickstack-ingest-gateway.imagePullSecrets" -}}
{{- $secrets := list -}}
{{- $src := .Values.imagePullSecrets -}}
{{- if not $src -}}
  {{- if and .Values.global .Values.global.imagePullSecrets -}}
    {{- $src = .Values.global.imagePullSecrets -}}
  {{- end -}}
{{- end -}}
{{- if kindIs "string" $src -}}
  {{- if and (ne $src "") (ne $src "none") -}}{{- $secrets = append $secrets $src -}}{{- end -}}
{{- else if kindIs "slice" $src -}}
  {{- range $src -}}
    {{- if kindIs "string" . -}}{{- $secrets = append $secrets . -}}
    {{- else if kindIs "map" . -}}{{- if .name -}}{{- $secrets = append $secrets .name -}}{{- end -}}{{- end -}}
  {{- end -}}
{{- end -}}
{{- if gt (len $secrets) 0 -}}
imagePullSecrets:
{{- range $secrets }}
  - name: {{ . }}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
OIDC issuer the collector validates telemetry JWTs against.

Must be byte-identical to DataCore's TELEMETRY_JWT_ISSUER_URL: the collector
fetches <issuer>/.well-known/openid-configuration and then rejects any token
whose `iss` differs from what it asked for. Both sides derive it here so a
namespace change cannot desynchronise them.
*/}}
{{- define "clickstack-ingest-gateway.issuerUrl" -}}
{{- $auth := default dict .Values.auth -}}
{{- if $auth.issuerUrl -}}
{{- trimSuffix "/" $auth.issuerUrl -}}
{{- else -}}
{{- include "neuraltrust-platform.datacore.internalUrl" . -}}
{{- end -}}
{{- end }}

{{/*
Where verified batches are forwarded.
*/}}
{{- define "clickstack-ingest-gateway.downstreamEndpoint" -}}
{{- $ds := default dict .Values.downstream -}}
{{- if $ds.endpoint -}}
{{- $ds.endpoint -}}
{{- else -}}
{{- /* clickstack-otel-collector pins fullnameOverride to this name. */ -}}
{{- printf "clickstack-collector.%s.svc.cluster.local:4317" .Release.Namespace -}}
{{- end -}}
{{- end }}

{{/*
Whether the chart mints the ingress certificate itself. An operator-supplied
secretName always wins: it is the only one that can carry a certificate a public
trust store already accepts.
*/}}
{{- define "clickstack-ingest-gateway.tlsAutoGenerate" -}}
{{- $tls := default dict (default dict .Values.ingress).tls -}}
{{- $enabled := include "neuraltrust-platform.boolish" (dict "value" $tls.enabled "default" true) -}}
{{- $auto := include "neuraltrust-platform.boolish" (dict "value" $tls.autoGenerate "default" false) -}}
{{- if and (eq $enabled "true") (eq $auto "true") (not $tls.secretName) }}true{{- end }}
{{- end }}

{{/*
Secret the Ingress references for TLS. Empty means "no secretName", which hands
TLS to the ingress controller's default certificate.
*/}}
{{- define "clickstack-ingest-gateway.tlsSecretName" -}}
{{- $tls := default dict (default dict .Values.ingress).tls -}}
{{- if $tls.secretName -}}
{{- $tls.secretName -}}
{{- else if eq (include "clickstack-ingest-gateway.tlsAutoGenerate" .) "true" -}}
{{- printf "%s-tls" (include "clickstack-ingest-gateway.fullname" .) -}}
{{- end -}}
{{- end }}

{{/*
Public hostname senders reach this gateway on. Same derivation the DataAgent
egress sidecar uses for its OTLP endpoint.
*/}}
{{- define "clickstack-ingest-gateway.host" -}}
{{- if .Values.ingress.host -}}
{{- .Values.ingress.host -}}
{{- else -}}
{{- printf "telemetry.%s" (include "neuraltrust-platform.saas.domain" .) -}}
{{- end -}}
{{- end }}
