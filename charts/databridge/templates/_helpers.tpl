{{/*
Expand the name of the chart.
*/}}
{{- define "databridge.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name. Pinned via fullnameOverride to a stable name.
*/}}
{{- define "databridge.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "databridge.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "databridge.labels" -}}
helm.sh/chart: {{ include "databridge.chart" . }}
app.kubernetes.io/name: {{ include "databridge.name" . }}
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
{{- define "databridge.selectorLabels" -}}
app.kubernetes.io/name: {{ include "databridge.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Service account name
*/}}
{{- define "databridge.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default "databridge" .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Whether this release deploys DataBridge at all. Only saas mode has data planes
outside the cluster for it to broker, so nothing else renders it.
*/}}
{{- define "databridge.deploy" -}}
{{- if eq (include "neuraltrust-platform.isSaas" .) "true" }}true{{- end }}
{{- end }}

{{/*
Resolve the image reference, honoring global.imageRegistry (mirror support).
*/}}
{{- define "databridge.image" -}}
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
*/}}
{{- define "databridge.imagePullSecrets" -}}
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
Name of the Secret holding the southbound TLS keypair. Operator-supplied wins;
otherwise cert-manager or the chart's own generator writes to a chart-named
Secret — only one of those two can be active, so they can share the name.
Empty when none is configured, which validate-values.yaml already refuses.
*/}}
{{- define "databridge.tlsSecretName" -}}
{{- $tls := default dict .Values.tls -}}
{{- $certManager := include "neuraltrust-platform.boolish" (dict "value" (default dict $tls.certManager).enabled "default" false) -}}
{{- $auto := include "neuraltrust-platform.boolish" (dict "value" $tls.autoGenerate "default" false) -}}
{{- if $tls.existingSecret -}}
{{- $tls.existingSecret -}}
{{- else if or (eq $certManager "true") (eq $auto "true") -}}
{{- printf "%s-southbound-tls" (include "databridge.fullname" .) -}}
{{- end -}}
{{- end }}

{{/*
Whether the chart mints the southbound keypair itself. An operator-supplied
Secret and cert-manager both take precedence, so this only fires when neither
is configured and the operator opted in.
*/}}
{{- define "databridge.tlsAutoGenerate" -}}
{{- $tls := default dict .Values.tls -}}
{{- $certManager := include "neuraltrust-platform.boolish" (dict "value" (default dict $tls.certManager).enabled "default" false) -}}
{{- $auto := include "neuraltrust-platform.boolish" (dict "value" $tls.autoGenerate "default" false) -}}
{{- if and (not $tls.existingSecret) (ne $certManager "true") (eq $auto "true") -}}
true
{{- end -}}
{{- end }}

{{/*
Public southbound hostname agents dial and the TLS certificate must cover.
Same derivation the DataAgent side uses, so the two cannot disagree.
*/}}
{{- define "databridge.southboundHost" -}}
{{- include "neuraltrust-platform.saas.databridgeHost" . -}}
{{- end }}

{{/*
DataCore's enrolment introspection endpoint. Derived from the in-cluster DataCore
Service by default, because in saas mode this chart deploys both sides and an
operator should not have to restate an address the chart already knows.
*/}}
{{- define "databridge.introspectionURL" -}}
{{- $auth := default dict .Values.auth -}}
{{- if $auth.datacoreIntrospectionURL -}}
{{- $auth.datacoreIntrospectionURL -}}
{{- else -}}
{{- /* The DataCore subchart pins fullnameOverride to "datacore" precisely so
       siblings can address it, and a subchart cannot read that value anyway.
       Its Service listens on :80, so no port here. */ -}}
{{- printf "http://datacore.%s.svc.cluster.local/internal/v1/enrolment/introspect" .Release.Namespace -}}
{{- end -}}
{{- end }}
