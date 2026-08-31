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
Peer discovery mode, validated. "off" or "headless".

HA is the product default (replicas=2, headless). Singleton escape hatch:
  databridge.replicas: 1  →  forces discovery off (no peer Service / POD_IP).

Fails closed when replicas >= 2 and the operator explicitly sets discovery=off
(unsafe multi-replica without forwarding).
*/}}
{{- define "databridge.peerDiscovery" -}}
{{- $replicas := int (.Values.replicas | default 2) -}}
{{- /* Singleton opt-down: ignore peer knobs entirely. */ -}}
{{- if lt $replicas 2 -}}
off
{{- else -}}
{{- $peers := default dict .Values.peers -}}
{{- $mode := $peers.discovery | default "headless" | toString | trim | lower -}}
{{- if not (has $mode (list "off" "headless")) -}}
{{- fail (printf "databridge.peers.discovery must be \"off\" or \"headless\" (got %q)" $mode) -}}
{{- end -}}
{{- if eq $mode "off" -}}
{{- fail (printf "databridge.replicas=%d requires peer forwarding (peers.discovery=headless, the default). A DataAgent's stream lives in one pod's memory; without forwarding most raw reads hit a pod with no stream and fail agent_unavailable. Keep the default, or set databridge.replicas=1 for a singleton." $replicas) -}}
{{- end -}}
{{- $mode -}}
{{- end -}}
{{- end }}

{{/*
Whether peer forwarding is on. Gates the headless Service and the peer env.
*/}}
{{- define "databridge.peersEnabled" -}}
{{- if eq (include "databridge.peerDiscovery" .) "headless" -}}true{{- end -}}
{{- end }}

{{/*
FQDN of the headless Service replicas resolve to enumerate their siblings.
Fully qualified so the lookup does not depend on the pod's search domains.
*/}}
{{- define "databridge.peerServiceFQDN" -}}
{{- printf "%s-peers.%s.svc.cluster.local" (include "databridge.fullname" .) .Release.Namespace -}}
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
Accepts a string or a list of strings/maps. Emits nothing when unset, "" or "none".

Delegates to the umbrella resolver (AUT-427). This body used to be one of nine
byte-identical copies, and every copy dropped the "none" check in the list branch
-- so global.imagePullSecrets: ["none"] rendered a phantom `- name: none` despite
the line above promising otherwise. Keep the wrapper: the name is what templates
call, and it keeps the value key local to this chart.
Usage: {{- include "databridge.imagePullSecrets" . | nindent 6 }}
*/}}
{{- define "databridge.imagePullSecrets" -}}
{{- include "neuraltrust-platform.subchart.imagePullSecrets" (dict "local" .Values.imagePullSecrets "global" .Values.global) -}}
{{- end }}

{{/*
Name of the Secret holding the southbound TLS keypair. Operator-supplied wins;
otherwise cert-manager or the chart's own generator writes to a chart-named
Secret — only one of those two can be active, so they can share the name.
Empty only when autoGenerate is explicitly false and no other source is set.
*/}}
{{- define "databridge.tlsSecretName" -}}
{{- $tls := default dict .Values.tls -}}
{{- $certManager := include "neuraltrust-platform.boolish" (dict "value" (default dict $tls.certManager).enabled "default" false) -}}
{{- /* Happy path: mint self-signed when no BYO secret / cert-manager. */ -}}
{{- $auto := include "neuraltrust-platform.boolish" (dict "value" $tls.autoGenerate "default" true) -}}
{{- if $tls.existingSecret -}}
{{- $tls.existingSecret -}}
{{- else if or (eq $certManager "true") (eq $auto "true") -}}
{{- printf "%s-southbound-tls" (include "databridge.fullname" .) -}}
{{- end -}}
{{- end }}

{{/*
Whether the chart mints the southbound keypair itself. Default true when no
existingSecret and cert-manager is off (private-network happy path). BYO secret
or cert-manager always wins.
*/}}
{{- define "databridge.tlsAutoGenerate" -}}
{{- $tls := default dict .Values.tls -}}
{{- $certManager := include "neuraltrust-platform.boolish" (dict "value" (default dict $tls.certManager).enabled "default" false) -}}
{{- $auto := include "neuraltrust-platform.boolish" (dict "value" $tls.autoGenerate "default" true) -}}
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
