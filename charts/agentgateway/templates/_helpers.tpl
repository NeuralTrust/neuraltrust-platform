{{/*
Expand the name of the chart.
*/}}
{{- define "agentgateway.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name. Pinned via fullnameOverride to a stable, release-independent
name (external tooling references it), matching the platform naming rule.
*/}}
{{- define "agentgateway.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "agentgateway.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "agentgateway.labels" -}}
helm.sh/chart: {{ include "agentgateway.chart" . }}
app.kubernetes.io/name: {{ include "agentgateway.name" . }}
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
{{- define "agentgateway.selectorLabels" -}}
app.kubernetes.io/name: {{ include "agentgateway.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Service account name
*/}}
{{- define "agentgateway.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default "agentgateway" .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Resolve the image reference, honoring global.imageRegistry (mirror support).
Usage: {{ include "agentgateway.image" (dict "repository" .Values.image.repository "tag" .Values.image.tag "global" .Values.global) }}
*/}}
{{- define "agentgateway.image" -}}
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
Accepts a string or a list of strings/maps. Emits nothing when unset or "none".
Usage: {{- include "agentgateway.imagePullSecrets" . | nindent 6 }}
*/}}
{{- define "agentgateway.imagePullSecrets" -}}
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
Effective GATEWAY_BASE_DOMAIN.
  explicit config.gatewayBaseDomain → use it
  empty → llm.<global.domain> (subdomain slug zone; primary host stays gateway.<domain>)
*/}}
{{- define "agentgateway.config.effectiveGatewayBaseDomain" -}}
{{- $explicit := .Values.config.gatewayBaseDomain | default "" | toString | trim -}}
{{- if $explicit -}}
{{- $explicit -}}
{{- else -}}
{{- printf "llm.%s" (include "neuraltrust-platform.domain" .) -}}
{{- end -}}
{{- end }}

{{/*
Effective MCP_BASE_DOMAIN.
  explicit config.mcpBaseDomain → use it
  empty → mcp.<global.domain>
*/}}
{{- define "agentgateway.config.effectiveMcpBaseDomain" -}}
{{- $explicit := .Values.config.mcpBaseDomain | default "" | toString | trim -}}
{{- if $explicit -}}
{{- $explicit -}}
{{- else -}}
{{- printf "mcp.%s" (include "neuraltrust-platform.domain" .) -}}
{{- end -}}
{{- end }}

{{/*
Effective additionalHosts for a proxy/MCP plane.
Args: dict "ctx" . "plane" "dataPlane"|"mcp"
  non-empty additionalHosts → authoritative (no auto-merge)
  empty + config.autoWildcardHosts (default true) → ["*.<effective-base-domain>"]
  empty + autoWildcardHosts false → []
*/}}
{{- define "agentgateway.ingress.effectiveAdditionalHosts" -}}
{{- $ctx := .ctx -}}
{{- $plane := .plane -}}
{{- $cfg := default dict $ctx.Values.config -}}
{{- $ing := default dict $ctx.Values.ingress -}}
{{- $planeCfg := dict -}}
{{- if eq $plane "mcp" -}}
  {{- $planeCfg = default dict $ing.mcp -}}
{{- else -}}
  {{- $planeCfg = default dict $ing.dataPlane -}}
{{- end -}}
{{- $explicit := default (list) $planeCfg.additionalHosts -}}
{{- $auto := true -}}
{{- if hasKey $cfg "autoWildcardHosts" -}}
  {{- $auto = $cfg.autoWildcardHosts -}}
{{- end -}}
{{- if gt (len $explicit) 0 -}}
{{- toYaml $explicit -}}
{{- else if $auto -}}
{{- $base := "" -}}
{{- if eq $plane "mcp" -}}
  {{- $base = include "agentgateway.config.effectiveMcpBaseDomain" $ctx -}}
{{- else -}}
  {{- $base = include "agentgateway.config.effectiveGatewayBaseDomain" $ctx -}}
{{- end -}}
{{- if $base -}}
{{- toYaml (list (printf "*.%s" $base)) -}}
{{- else -}}
{{- toYaml (list) -}}
{{- end -}}
{{- else -}}
{{- toYaml (list) -}}
{{- end -}}
{{- end }}

{{/*
Ordered unique public hosts for an AgentGateway ingress plane.
Args: dict "host" "" "prefix" "" "additionalHosts" list "global" .Values.global
Returns a YAML list: primary host (if resolved) then additionalHosts, de-duped.
*/}}
{{- define "agentgateway.ingress.hosts" -}}
{{- $hosts := list -}}
{{- $primary := include "neuraltrust-platform.ingress.host" (dict "host" .host "prefix" .prefix "global" .global) -}}
{{- if $primary -}}
  {{- $hosts = append $hosts $primary -}}
{{- end -}}
{{- range (default (list) .additionalHosts) -}}
  {{- $h := . | toString | trim -}}
  {{- if and $h (not (has $h $hosts)) -}}
    {{- $hosts = append $hosts $h -}}
  {{- end -}}
{{- end -}}
{{- toYaml $hosts -}}
{{- end }}

{{/*
Whether AgentGateway should render networking.k8s.io Ingress resources.
resourceType: auto|ingress|route
  auto    → Ingress unless OpenShift (then Routes)
  ingress → always Ingress
  route   → never Ingress (OpenShift Routes instead)
*/}}
{{- define "agentgateway.ingress.useIngress" -}}
{{- $rt := (.Values.ingress.resourceType | default "auto") -}}
{{- if eq $rt "ingress" -}}
true
{{- else if eq $rt "route" -}}
{{- else if include "neuraltrust-platform.isOpenshift" . -}}
{{- else -}}
true
{{- end -}}
{{- end }}

{{/*
Whether AgentGateway should render OpenShift Route resources.
*/}}
{{- define "agentgateway.ingress.useRoutes" -}}
{{- if and .Values.ingress.enabled (include "neuraltrust-platform.isOpenshift" .) -}}
  {{- $rt := (.Values.ingress.resourceType | default "auto") -}}
  {{- if or (eq $rt "route") (eq $rt "auto") -}}
true
  {{- end -}}
{{- end -}}
{{- end }}

{{/*
Convert an Ingress-style host to an OpenShift Route host + wildcardPolicy.
  *.llm.example.com → host=llm.example.com, wildcardPolicy=Subdomain
  exact.example.com → host=exact.example.com, wildcardPolicy=None
Returns YAML: host / wildcardPolicy
*/}}
{{- define "agentgateway.route.fromHost" -}}
{{- $h := . | toString | trim -}}
{{- if hasPrefix "*." $h -}}
host: {{ trimPrefix "*." $h | quote }}
wildcardPolicy: Subdomain
{{- else -}}
host: {{ $h | quote }}
wildcardPolicy: None
{{- end -}}
{{- end }}

{{/*
Stable OpenShift Route metadata.name from a host string (wildcard-safe).
*/}}
{{- define "agentgateway.route.name" -}}
{{- $prefix := .prefix -}}
{{- $host := .host | toString | trim -}}
{{- $suffix := $host | trimPrefix "*." | replace "." "-" | trunc 40 | trimSuffix "-" -}}
{{- printf "%s-%s" $prefix $suffix | trunc 63 | trimSuffix "-" -}}
{{- end }}
