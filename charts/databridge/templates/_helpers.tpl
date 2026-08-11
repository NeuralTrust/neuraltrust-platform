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

Fails closed on replicas > 1 with discovery off. An agent's stream lives in the
memory of exactly one pod and DataCore pins one pod per channel, so without
forwarding most raw reads land on a pod holding no stream — a per-tenant,
intermittent failure that looks like a broken data plane rather than a
misconfigured chart. Refusing the render is the only place this is cheap to see.
*/}}
{{- define "databridge.peerDiscovery" -}}
{{- $peers := default dict .Values.peers -}}
{{- $mode := $peers.discovery | default "off" | toString | trim | lower -}}
{{- if not (has $mode (list "off" "headless")) -}}
{{- fail (printf "databridge.peers.discovery must be \"off\" or \"headless\" (got %q)" $mode) -}}
{{- end -}}
{{- $replicas := int (.Values.replicas | default 1) -}}
{{- if and (gt $replicas 1) (eq $mode "off") -}}
{{- fail (printf "databridge.replicas=%d requires databridge.peers.discovery=headless. A DataAgent's stream is a live connection held in one pod's memory: it cannot be shared or moved between replicas. DataCore opens one channel per pod and pins it, so with several replicas and no forwarding roughly (N-1)/N of raw reads reach a pod that holds no stream for that tenant and fail with agent_unavailable — intermittently, per tenant, and only for tenants whose agent happened to connect elsewhere. Set databridge.peers.discovery=headless so a replica that misses locally asks its siblings, or keep databridge.replicas=1." $replicas) -}}
{{- end -}}
{{- $mode -}}
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
