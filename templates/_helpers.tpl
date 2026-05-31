{{/*
Expand the name of the chart.
*/}}
{{- define "neuraltrust-platform.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "neuraltrust-platform.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "neuraltrust-platform.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "neuraltrust-platform.labels" -}}
helm.sh/chart: {{ include "neuraltrust-platform.chart" . }}
{{ include "neuraltrust-platform.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "neuraltrust-platform.selectorLabels" -}}
app.kubernetes.io/name: {{ include "neuraltrust-platform.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Get ClickHouse connection details
Returns host, port, user, database based on whether ClickHouse is deployed or external
*/}}
{{- define "neuraltrust-platform.clickhouse.host" -}}
{{- if .Values.infrastructure.clickhouse.deploy }}
{{/* Service name is `clickhouse` (no release prefix) because values.yaml pins
     clickhouse.fullnameOverride: "clickhouse". Keep these in sync. */}}
{{- "clickhouse" }}
{{- else }}
{{- .Values.infrastructure.clickhouse.external.host }}
{{- end }}
{{- end }}

{{- define "neuraltrust-platform.clickhouse.port" -}}
{{- if .Values.infrastructure.clickhouse.deploy }}
{{- "8123" }}
{{- else }}
{{- .Values.infrastructure.clickhouse.external.port }}
{{- end }}
{{- end }}

{{- define "neuraltrust-platform.clickhouse.user" -}}
{{- if .Values.infrastructure.clickhouse.deploy }}
{{- .Values.infrastructure.clickhouse.chart.auth.username }}
{{- else }}
{{- .Values.infrastructure.clickhouse.external.user }}
{{- end }}
{{- end }}

{{- define "neuraltrust-platform.clickhouse.database" -}}
{{- if .Values.infrastructure.clickhouse.deploy }}
{{- "default" }}
{{- else }}
{{- .Values.infrastructure.clickhouse.external.database }}
{{- end }}
{{- end }}

{{/*
Get Kafka connection details
*/}}
{{- define "neuraltrust-platform.kafka.bootstrapServers" -}}
{{- if .Values.infrastructure.kafka.deploy }}
{{/* Service name is `kafka` (no release prefix) because values.yaml pins
     kafka.fullnameOverride: "kafka". Keep these in sync. */}}
{{- "kafka:9092" }}
{{- else }}
{{- if .Values.infrastructure.kafka.external.bootstrapServers }}
{{- .Values.infrastructure.kafka.external.bootstrapServers }}
{{- else if .Values.infrastructure.kafka.external.brokers }}
{{- join "," .Values.infrastructure.kafka.external.brokers }}
{{- else }}
{{- "kafka:9092" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Get PostgreSQL connection details
Uses neuraltrust-control-plane.infrastructure.postgresql.deploy to determine if deployed
Uses neuraltrust-control-plane.controlPlane.components.postgresql.secrets for external connection
*/}}
{{- define "neuraltrust-platform.postgresql.host" -}}
{{- $cpValues := index .Values "neuraltrust-control-plane" }}
{{- $deploy := false }}
{{- if and $cpValues $cpValues.infrastructure $cpValues.infrastructure.postgresql (hasKey $cpValues.infrastructure.postgresql "deploy") }}
  {{- $deploy = $cpValues.infrastructure.postgresql.deploy }}
{{- end }}
{{- if $deploy }}
{{- printf "control-plane-postgresql" }}
{{- else if and $cpValues $cpValues.controlPlane $cpValues.controlPlane.components $cpValues.controlPlane.components.postgresql $cpValues.controlPlane.components.postgresql.secrets $cpValues.controlPlane.components.postgresql.secrets.host }}
{{- $cpValues.controlPlane.components.postgresql.secrets.host }}
{{- else }}
{{- "control-plane-postgresql" }}
{{- end }}
{{- end }}

{{- define "neuraltrust-platform.postgresql.port" -}}
{{- $cpValues := index .Values "neuraltrust-control-plane" }}
{{- $deploy := false }}
{{- if and $cpValues $cpValues.infrastructure $cpValues.infrastructure.postgresql (hasKey $cpValues.infrastructure.postgresql "deploy") }}
  {{- $deploy = $cpValues.infrastructure.postgresql.deploy }}
{{- end }}
{{- if $deploy }}
{{- "5432" }}
{{- else if and $cpValues $cpValues.controlPlane $cpValues.controlPlane.components $cpValues.controlPlane.components.postgresql $cpValues.controlPlane.components.postgresql.secrets $cpValues.controlPlane.components.postgresql.secrets.port }}
{{- $cpValues.controlPlane.components.postgresql.secrets.port }}
{{- else }}
{{- "5432" }}
{{- end }}
{{- end }}

{{- define "neuraltrust-platform.postgresql.user" -}}
{{- $cpValues := index .Values "neuraltrust-control-plane" }}
{{- $deploy := false }}
{{- if and $cpValues $cpValues.infrastructure $cpValues.infrastructure.postgresql (hasKey $cpValues.infrastructure.postgresql "deploy") }}
  {{- $deploy = $cpValues.infrastructure.postgresql.deploy }}
{{- end }}
{{- if $deploy }}
{{- "neuraltrust" }}
{{- else if and $cpValues $cpValues.controlPlane $cpValues.controlPlane.components $cpValues.controlPlane.components.postgresql $cpValues.controlPlane.components.postgresql.secrets $cpValues.controlPlane.components.postgresql.secrets.user }}
{{- $cpValues.controlPlane.components.postgresql.secrets.user }}
{{- else }}
{{- "neuraltrust" }}
{{- end }}
{{- end }}

{{- define "neuraltrust-platform.postgresql.database" -}}
{{- $cpValues := index .Values "neuraltrust-control-plane" }}
{{- $deploy := false }}
{{- if and $cpValues $cpValues.infrastructure $cpValues.infrastructure.postgresql (hasKey $cpValues.infrastructure.postgresql "deploy") }}
  {{- $deploy = $cpValues.infrastructure.postgresql.deploy }}
{{- end }}
{{- if $deploy }}
{{- "neuraltrust" }}
{{- else if and $cpValues $cpValues.controlPlane $cpValues.controlPlane.components $cpValues.controlPlane.components.postgresql $cpValues.controlPlane.components.postgresql.secrets $cpValues.controlPlane.components.postgresql.secrets.database }}
{{- $cpValues.controlPlane.components.postgresql.secrets.database }}
{{- else }}
{{- "neuraltrust" }}
{{- end }}
{{- end }}

{{/*
Resolve a secret value with auto-generation support.
Priority: explicit value > existing value in cluster > generate random.

Usage:
  {{ include "neuraltrust-platform.resolveSecret" (dict "value" $myValue "existingSecret" $existingSecretObj "secretKey" "MY_KEY" "length" 64) }}

Parameters:
  - value:          The explicit value from helm values (string). Empty or nil means "not provided".
  - existingSecret: The result of (lookup "v1" "Secret" .Release.Namespace "secret-name"). Can be nil.
  - secretKey:      The key to look up in the existing secret's data.
  - length:         (Optional) Length of the generated random string. Default: 64.
*/}}
{{- define "neuraltrust-platform.resolveSecret" -}}
{{- $value := .value }}
{{- $existingSecret := .existingSecret }}
{{- $secretKey := .secretKey }}
{{- $length := 64 }}
{{- if .length }}
  {{- $length = .length | int }}
{{- end }}
{{- /* Priority 1: Use explicitly provided value (non-empty string) */}}
{{- if and $value (ne ($value | toString) "") }}
  {{- $value }}
{{- /* Priority 2: Reuse existing value from cluster secret */}}
{{- else if and $existingSecret (kindIs "map" $existingSecret) }}
  {{- if and (index $existingSecret "data") (hasKey (index $existingSecret "data") $secretKey) }}
    {{- index $existingSecret.data $secretKey | b64dec }}
  {{- else }}
    {{- /* Existing secret doesn't have this key - generate */}}
    {{- randAlphaNum $length }}
  {{- end }}
{{- /* Priority 3: Generate new random value */}}
{{- else }}
  {{- randAlphaNum $length }}
{{- end }}
{{- end }}

{{/*
Check if the current platform is OpenShift.
Returns "true" (non-empty) if OpenShift, empty string otherwise.
Supports both new (global.platform) and deprecated (global.openshift) values.
Usage: {{- if include "neuraltrust-platform.isOpenshift" . }}
*/}}
{{- define "neuraltrust-platform.isOpenshift" -}}
{{- $global := default dict .Values.global }}
{{- if or (eq ($global.platform | default "") "openshift") $global.openshift }}true{{- end }}
{{- end }}

{{/*
Resolve the base domain for URL generation.
Priority: global.domain > global.openshiftDomain (deprecated).
Usage: {{ include "neuraltrust-platform.domain" . }}
*/}}
{{- define "neuraltrust-platform.domain" -}}
{{- $global := default dict .Values.global }}
{{- $global.domain | default $global.openshiftDomain | default "" }}
{{- end }}

{{/*
Resolve the effective ingress hostname for a service.
Priority:
  1. Explicit host (full hostname) — wins if non-empty
  2. <prefix>.<global.domain> (or global.openshiftDomain fallback) when both are set
  3. Empty (catch-all)
Usage: {{ include "neuraltrust-platform.ingress.host" (dict "host" .Values.x.host "prefix" "api" "global" .Values.global) }}
*/}}
{{- define "neuraltrust-platform.ingress.host" -}}
{{- $explicit := .host | default "" }}
{{- if $explicit }}
{{- $explicit }}
{{- else }}
  {{- $global := default dict .global }}
  {{- $domain := $global.domain | default $global.openshiftDomain | default "" }}
  {{- $prefix := .prefix | default "" }}
  {{- if and $domain $prefix }}
{{- printf "%s.%s" $prefix $domain }}
  {{- end }}
{{- end }}
{{- end }}

{{/*
Resolve the effective ingress provider.
Priority: global.ingress.provider (explicit) > auto-detect from global.platform.
Platform mapping: aws→aws, gcp→gcp, azure→azure, openshift→openshift, kubernetes→none.
Usage: {{ include "neuraltrust-platform.ingress.provider" . }}
*/}}
{{- define "neuraltrust-platform.ingress.provider" -}}
{{- $global := default dict .Values.global }}
{{- $globalIngress := default dict $global.ingress }}
{{- $platform := $global.platform | default "kubernetes" }}
{{- if $globalIngress.provider }}
  {{- $globalIngress.provider }}
{{- else if eq $platform "aws" }}
  {{- "aws" }}
{{- else if eq $platform "gcp" }}
  {{- "gcp" }}
{{- else if eq $platform "azure" }}
  {{- "azure" }}
{{- else if eq $platform "openshift" }}
  {{- "openshift" }}
{{- else }}
  {{- "none" }}
{{- end }}
{{- end }}

{{/*
Resolve the ingress class name.
Priority: local (per-service) > global.ingress.className > auto-detect from provider.
Provider defaults: aws→"alb", azure→"azure-application-gateway", openshift→"openshift-default".
GCP uses annotation (kubernetes.io/ingress.class) instead of spec.ingressClassName because
GKE (especially Autopilot) does not register an IngressClass resource.
Usage: {{ include "neuraltrust-platform.ingress.className" (dict "global" .Values.global "local" .Values.ingress.className) }}
*/}}
{{- define "neuraltrust-platform.ingress.className" -}}
{{- $local := .local }}
{{- $globalIngress := default dict (default dict .global).ingress }}
{{- $global := default dict .global }}
{{- $platform := $global.platform | default "kubernetes" }}
{{- $provider := $globalIngress.provider | default "" }}
{{- if not $provider }}
  {{- if eq $platform "aws" }}{{ $provider = "aws" }}
  {{- else if eq $platform "gcp" }}{{ $provider = "gcp" }}
  {{- else if eq $platform "azure" }}{{ $provider = "azure" }}
  {{- else if eq $platform "openshift" }}{{ $provider = "openshift" }}
  {{- else }}{{ $provider = "none" }}
  {{- end }}
{{- end }}
{{- if $local }}
  {{- $local }}
{{- else if $globalIngress.className }}
  {{- $globalIngress.className }}
{{- else if eq $provider "aws" }}
  {{- "alb" }}
{{- else if eq $provider "azure" }}
  {{- "azure-application-gateway" }}
{{- else if eq $provider "openshift" }}
  {{- "openshift-default" }}
{{- end }}
{{- /* GCP: no ingressClassName — uses annotation kubernetes.io/ingress.class instead */}}
{{- end }}

{{/*
Generate merged ingress annotations.
Merges (in priority order, highest wins):
  1. Cloud provider auto-generated annotations based on global.ingress.provider (lowest)
  2. Global ingress annotations
  3. Local (per-service) annotations (highest)
Usage: {{ include "neuraltrust-platform.ingress.annotations" (dict "global" .Values.global "local" .Values.ingress.annotations) }}
*/}}
{{- define "neuraltrust-platform.ingress.annotations" -}}
{{- $merged := dict }}
{{- $globalIngress := default dict (default dict .global).ingress }}
{{- $global := default dict .global }}
{{- $platform := $global.platform | default "kubernetes" }}
{{- $provider := $globalIngress.provider | default "" }}
{{- if not $provider }}
  {{- if eq $platform "aws" }}{{ $provider = "aws" }}
  {{- else if eq $platform "gcp" }}{{ $provider = "gcp" }}
  {{- else if eq $platform "azure" }}{{ $provider = "azure" }}
  {{- else if eq $platform "openshift" }}{{ $provider = "openshift" }}
  {{- else }}{{ $provider = "none" }}
  {{- end }}
{{- end }}
{{- /* 1a. AWS ALB annotations (provider=aws) */}}
{{- if eq $provider "aws" }}
  {{- $aws := default dict $globalIngress.aws }}
  {{- $_ := set $merged "alb.ingress.kubernetes.io/scheme" ($aws.scheme | default "internet-facing") }}
  {{- $_ := set $merged "alb.ingress.kubernetes.io/target-type" ($aws.targetType | default "ip") }}
  {{- if $aws.groupName }}
    {{- $_ := set $merged "alb.ingress.kubernetes.io/group.name" $aws.groupName }}
  {{- end }}
  {{- if $aws.certificateArn }}
    {{- $_ := set $merged "alb.ingress.kubernetes.io/certificate-arn" $aws.certificateArn }}
    {{- $_ := set $merged "alb.ingress.kubernetes.io/listen-ports" `[{"HTTPS":443}]` }}
    {{- if $aws.sslRedirect }}
      {{- $_ := set $merged "alb.ingress.kubernetes.io/ssl-redirect" ($aws.sslRedirect | toString) }}
    {{- end }}
  {{- end }}
  {{- if $aws.wafAclArn }}
    {{- $_ := set $merged "alb.ingress.kubernetes.io/wafv2-acl-arn" $aws.wafAclArn }}
  {{- end }}
  {{- range $k, $v := (default dict $aws.additionalAnnotations) }}
    {{- $_ := set $merged $k ($v | toString) }}
  {{- end }}
{{- end }}
{{- /* 1b. GCP GCE annotations (provider=gcp) */}}
{{- /* GKE Autopilot does not register an IngressClass resource, so we use the annotation */}}
{{- if eq $provider "gcp" }}
  {{- $gcp := default dict $globalIngress.gcp }}
  {{- $_ := set $merged "kubernetes.io/ingress.class" "gce" }}
  {{- if $gcp.staticIpName }}
    {{- $_ := set $merged "kubernetes.io/ingress.global-static-ip-name" $gcp.staticIpName }}
  {{- end }}
  {{- if $gcp.managedCertificates }}
    {{- $_ := set $merged "networking.gke.io/managed-certificates" $gcp.managedCertificates }}
  {{- end }}
  {{- if $gcp.sslRedirect }}
    {{- $_ := set $merged "networking.gke.io/v1beta1.FrontendConfig" "ssl-redirect" }}
  {{- end }}
  {{- range $k, $v := (default dict $gcp.additionalAnnotations) }}
    {{- $_ := set $merged $k ($v | toString) }}
  {{- end }}
{{- end }}
{{- /* 1c. Azure AGIC annotations (provider=azure) */}}
{{- if eq $provider "azure" }}
  {{- $azure := default dict $globalIngress.azure }}
  {{- if $azure.appGatewayName }}
    {{- $_ := set $merged "appgw.ingress.kubernetes.io/appgw-name" $azure.appGatewayName }}
  {{- end }}
  {{- if $azure.sslCertificate }}
    {{- $_ := set $merged "appgw.ingress.kubernetes.io/appgw-ssl-certificate" $azure.sslCertificate }}
    {{- $_ := set $merged "appgw.ingress.kubernetes.io/appgw-ssl-profile" $azure.sslCertificate }}
  {{- end }}
  {{- if $azure.sslRedirect }}
    {{- $_ := set $merged "appgw.ingress.kubernetes.io/ssl-redirect" "true" }}
  {{- end }}
  {{- if $azure.wafPolicyId }}
    {{- $_ := set $merged "appgw.ingress.kubernetes.io/waf-policy-for-path" $azure.wafPolicyId }}
  {{- end }}
  {{- if $azure.requestTimeout }}
    {{- $_ := set $merged "appgw.ingress.kubernetes.io/request-timeout" ($azure.requestTimeout | toString) }}
  {{- end }}
  {{- range $k, $v := (default dict $azure.additionalAnnotations) }}
    {{- $_ := set $merged $k ($v | toString) }}
  {{- end }}
{{- end }}
{{- /* 1d. OpenShift annotations (provider=openshift) */}}
{{- if eq $provider "openshift" }}
  {{- $_ := set $merged "route.openshift.io/termination" "edge" }}
  {{- $_ := set $merged "route.openshift.io/insecure-edge-termination-policy" "Redirect" }}
{{- end }}
{{- /* 2. Global ingress annotations */}}
{{- range $k, $v := (default dict $globalIngress.annotations) }}
  {{- $_ := set $merged $k ($v | toString) }}
{{- end }}
{{- /* 3. Local (per-service) annotations - highest priority */}}
{{- range $k, $v := (default dict .local) }}
  {{- $_ := set $merged $k ($v | toString) }}
{{- end }}
{{- /* Output merged annotations as YAML */}}
{{- if $merged }}
{{- toYaml $merged }}
{{- end }}
{{- end }}

{{/*
Return the shared fallback TLS secret name for ingress resources.
Usage: {{ include "neuraltrust-platform.ingress.defaultTLSSecretName" (dict "global" .Values.global) }}
*/}}
{{- define "neuraltrust-platform.ingress.defaultTLSSecretName" -}}
{{- $globalIngress := default dict (default dict .global).ingress }}
{{- $tls := default dict $globalIngress.tls }}
{{- if $tls.secretName }}
{{- $tls.secretName -}}
{{- else -}}
neuraltrust-ingress-tls
{{- end }}
{{- end }}

{{/*
Check if shared ingress TLS secret auto-generation is enabled.
Usage: {{ include "neuraltrust-platform.ingress.autoGenerateTLSSecret" (dict "global" .Values.global) }}
*/}}
{{- define "neuraltrust-platform.ingress.autoGenerateTLSSecret" -}}
{{- $globalIngress := default dict (default dict .global).ingress }}
{{- $tls := default dict $globalIngress.tls }}
{{- $enabled := true }}
{{- if hasKey $tls "autoGenerate" }}
  {{- $enabled = $tls.autoGenerate }}
{{- end }}
{{- if $enabled }}true{{- end }}
{{- end }}

{{/*
Resolve the effective TLS secret name for an ingress.
Priority: local secretName > shared global secretName > default fallback name.
Usage: {{ include "neuraltrust-platform.ingress.effectiveTLSSecretName" (dict "global" .Values.global "localSecretName" .Values.ingress.tls.secretName) }}
*/}}
{{- define "neuraltrust-platform.ingress.effectiveTLSSecretName" -}}
{{- $localSecretName := .localSecretName | default "" }}
{{- if $localSecretName }}
{{- $localSecretName -}}
{{- else -}}
{{- include "neuraltrust-platform.ingress.defaultTLSSecretName" (dict "global" .global) -}}
{{- end }}
{{- end }}

{{/*
Check if TLS section should be rendered for Ingress.
When a cloud provider handles TLS via annotations (ACM, Google-managed certs, AGIC SSL),
TLS is NOT rendered in the Ingress spec. Returns "true" if Ingress TLS spec should be rendered.
Usage: {{- if include "neuraltrust-platform.ingress.renderTLS" (dict "global" .Values.global "tlsEnabled" .Values.ingress.tls.enabled) }}
*/}}
{{- define "neuraltrust-platform.ingress.renderTLS" -}}
{{- $globalIngress := default dict (default dict .global).ingress }}
{{- $global := default dict .global }}
{{- $platform := $global.platform | default "kubernetes" }}
{{- $provider := $globalIngress.provider | default "" }}
{{- if not $provider }}
  {{- if eq $platform "aws" }}{{ $provider = "aws" }}
  {{- else if eq $platform "gcp" }}{{ $provider = "gcp" }}
  {{- else if eq $platform "azure" }}{{ $provider = "azure" }}
  {{- else }}{{ $provider = "none" }}
  {{- end }}
{{- end }}
{{- $cloudTLS := false }}
{{- if eq $provider "aws" }}
  {{- $aws := default dict $globalIngress.aws }}
  {{- if $aws.certificateArn }}{{ $cloudTLS = true }}{{- end }}
{{- else if eq $provider "gcp" }}
  {{- $gcp := default dict $globalIngress.gcp }}
  {{- if $gcp.managedCertificates }}{{ $cloudTLS = true }}{{- end }}
{{- else if eq $provider "azure" }}
  {{- $azure := default dict $globalIngress.azure }}
  {{- if $azure.sslCertificate }}{{ $cloudTLS = true }}{{- end }}
{{- end }}
{{- if and .tlsEnabled (not $cloudTLS) }}true{{- end }}
{{- end }}

{{/*
Generate service annotations for GCP NEG (Network Endpoint Groups) support.
On non-autopilot GKE clusters, the GCE ingress controller requires either NodePort/LoadBalancer
services OR the cloud.google.com/neg annotation on ClusterIP services for container-native
load balancing. This helper adds the NEG annotation when the platform is GCP.
If global.psc.negNames contains a key matching pscServiceKey, the service gets a standalone
NEG annotation (PSC-only, no "ingress": true). This works on any GCP platform regardless of
ingress provider. Services without a negName get {"ingress": true} when provider=gcp.
Controlled by: global.ingress.gcp.neg.enabled (default: true when provider=gcp)
Usage: {{ include "neuraltrust-platform.service.negAnnotations" (dict "global" .Values.global "pscServiceKey" "trustgate-data-plane") }}
*/}}
{{- define "neuraltrust-platform.service.negAnnotations" -}}
{{- $global := default dict .global }}
{{- $globalIngress := default dict $global.ingress }}
{{- $platform := $global.platform | default "kubernetes" }}
{{- $provider := $globalIngress.provider | default "" }}
{{- if not $provider }}
  {{- if eq $platform "gcp" }}{{ $provider = "gcp" }}{{- end }}
{{- end }}
{{- $pscNegName := "" }}
{{- if and (eq $platform "gcp") .pscServiceKey }}
  {{- $negNames := default dict (default dict $global.psc).negNames }}
  {{- if hasKey $negNames .pscServiceKey }}
    {{- $pscNegName = index $negNames .pscServiceKey }}
  {{- end }}
{{- end }}
{{- if $pscNegName }}
cloud.google.com/neg: '{"exposed_ports":{"80":{"name":"{{ $pscNegName }}"}}}'
{{- else if eq $provider "gcp" }}
  {{- $gcp := default dict $globalIngress.gcp }}
  {{- $neg := default dict $gcp.neg }}
  {{- $negEnabled := true }}
  {{- if hasKey $neg "enabled" }}
    {{- $negEnabled = $neg.enabled }}
  {{- end }}
  {{- if $negEnabled }}
cloud.google.com/neg: '{"ingress": true}'
  {{- end }}
{{- end }}
{{- if eq $provider "gcp" }}
  {{- $backendConfigName := include "neuraltrust-platform.service.gkeBackendConfigName" (dict "global" $global "localName" (.backendConfigName | default "")) }}
  {{- if $backendConfigName }}
cloud.google.com/backend-config: {{ printf "{\"default\":\"%s\"}" $backendConfigName | squote }}
  {{- end }}
{{- end }}
{{- end }}

{{/*
Return the BackendConfig name for a GKE service.
- If global.ingress.gcp.backendConfig is set, reuse that existing BackendConfig.
- Otherwise, use the local generated name passed by the caller.
Returns empty for non-GKE providers.
Usage: {{ include "neuraltrust-platform.service.gkeBackendConfigName" (dict "global" .Values.global "localName" "data-plane-api-backendconfig") }}
*/}}
{{- define "neuraltrust-platform.service.gkeBackendConfigName" -}}
{{- $global := default dict .global }}
{{- $globalIngress := default dict $global.ingress }}
{{- $platform := $global.platform | default "kubernetes" }}
{{- $provider := $globalIngress.provider | default "" }}
{{- if not $provider }}
  {{- if eq $platform "gcp" }}{{ $provider = "gcp" }}{{- end }}
{{- end }}
{{- if eq $provider "gcp" }}
  {{- $gcp := default dict $globalIngress.gcp }}
  {{- if $gcp.backendConfig }}
    {{- $gcp.backendConfig -}}
  {{- else if .localName }}
    {{- .localName -}}
  {{- end }}
{{- end }}
{{- end }}

{{/*
Emit HTTP proxy environment variables when global.proxy.enabled is true.
Outputs both uppercase (HTTP_PROXY) and lowercase (http_proxy) variants.
Usage: {{- include "neuraltrust-platform.proxy-env" . | nindent 8 }}
*/}}
{{- define "neuraltrust-platform.proxy-env" -}}
{{- if and .Values.global .Values.global.proxy .Values.global.proxy.enabled }}
- name: HTTP_PROXY
  value: {{ .Values.global.proxy.httpProxy | quote }}
- name: HTTPS_PROXY
  value: {{ .Values.global.proxy.httpsProxy | quote }}
- name: NO_PROXY
  value: {{ .Values.global.proxy.noProxy | quote }}
- name: http_proxy
  value: {{ .Values.global.proxy.httpProxy | quote }}
- name: https_proxy
  value: {{ .Values.global.proxy.httpsProxy | quote }}
- name: no_proxy
  value: {{ .Values.global.proxy.noProxy | quote }}
{{- end }}
{{- end }}

{{/*
Custom corporate CA certificate trust.

When global.customCaCert.enabled is true and a secretName is provided, the
referenced secret key is mounted as a single file into every workload and the
runtime-appropriate trust env var is injected. Default OFF — existing releases
are unaffected. The secret is referenced, never created, by this chart
(existingSecret pattern); create it out-of-band, e.g.
  kubectl create secret generic <name> --from-file=ca.crt=<bundle>.pem

These helpers are defined in the parent chart and called from every subchart
deployment, mirroring the neuraltrust-platform.proxy-env pattern.
*/}}

{{/*
Returns a non-empty string when the custom CA cert feature is active
(enabled AND a secretName is set). Empty otherwise. Use as a guard around
volumes:/volumeMounts: blocks in deployments that have no other volumes.
Usage: {{- if include "neuraltrust-platform.customCaCert.enabled" . }}
*/}}
{{- define "neuraltrust-platform.customCaCert.enabled" -}}
{{- $ca := (default dict (default dict .Values.global).customCaCert) -}}
{{- if and $ca.enabled $ca.secretName -}}true{{- end -}}
{{- end }}

{{/*
Resolved mount path for the CA bundle file. */}}
{{- define "neuraltrust-platform.customCaCert.path" -}}
{{- $ca := (default dict (default dict .Values.global).customCaCert) -}}
{{- $ca.mountPath | default "/etc/ssl/certs/custom-ca.crt" -}}
{{- end }}

{{/*
Pod-level volume for the CA bundle.
Usage: {{- include "neuraltrust-platform.customCaCert.volume" . | nindent 6 }}
*/}}
{{- define "neuraltrust-platform.customCaCert.volume" -}}
{{- $ca := (default dict (default dict .Values.global).customCaCert) -}}
{{- if and $ca.enabled $ca.secretName }}
- name: custom-ca-cert
  secret:
    secretName: {{ $ca.secretName | quote }}
    items:
    - key: {{ $ca.key | default "ca.crt" | quote }}
      path: ca.crt
{{- end }}
{{- end }}

{{/*
Container-level volume mount for the CA bundle.
Usage: {{- include "neuraltrust-platform.customCaCert.volumeMount" . | nindent 8 }}
*/}}
{{- define "neuraltrust-platform.customCaCert.volumeMount" -}}
{{- $ca := (default dict (default dict .Values.global).customCaCert) -}}
{{- if and $ca.enabled $ca.secretName }}
- name: custom-ca-cert
  mountPath: {{ include "neuraltrust-platform.customCaCert.path" . | quote }}
  subPath: ca.crt
  readOnly: true
{{- end }}
{{- end }}

{{/*
Runtime-specific CA trust env vars.
Usage: {{- include "neuraltrust-platform.customCaCert.env" (dict "runtime" "go" "ctx" .) | nindent 8 }}
runtime: node | go | python | java (defaults to go -> SSL_CERT_FILE).
*/}}
{{- define "neuraltrust-platform.customCaCert.env" -}}
{{- $ctx := .ctx -}}
{{- $ca := (default dict (default dict $ctx.Values.global).customCaCert) -}}
{{- if and $ca.enabled $ca.secretName }}
{{- $path := include "neuraltrust-platform.customCaCert.path" $ctx }}
{{- $runtime := .runtime | default "go" }}
{{- if eq $runtime "node" }}
- name: NODE_EXTRA_CA_CERTS
  value: {{ $path | quote }}
{{- else if eq $runtime "python" }}
- name: REQUESTS_CA_BUNDLE
  value: {{ $path | quote }}
- name: SSL_CERT_FILE
  value: {{ $path | quote }}
{{- else }}
- name: SSL_CERT_FILE
  value: {{ $path | quote }}
{{- end }}
{{- end }}
{{- end }}

{{/*
APPLICATION_VERSION env var, paired with a component's resolved image tag so the
deployed version can be confirmed at runtime (e.g. via a /health endpoint).
Best-effort and additive: emits nothing when no tag is resolvable, so it never
breaks a deployment and apps that don't read it simply ignore it.
Usage: {{- include "neuraltrust-platform.appVersionEnv" (dict "tag" $imageTag) | nindent 8 }}
*/}}
{{- define "neuraltrust-platform.appVersionEnv" -}}
{{- $tag := .tag | toString -}}
{{- if and $tag (ne $tag "") -}}
- name: APPLICATION_VERSION
  value: {{ $tag | quote }}
{{- end -}}
{{- end }}

{{/*
Check if autoGenerateSecrets is enabled.
Returns "true" (non-empty string) if enabled, empty string if disabled.
Usage: {{- if include "neuraltrust-platform.autoGenerateSecrets" . }}
*/}}
{{- define "neuraltrust-platform.autoGenerateSecrets" -}}
{{- $autoGenerate := true }}
{{- if and .Values.global (hasKey .Values.global "autoGenerateSecrets") }}
  {{- $autoGenerate = .Values.global.autoGenerateSecrets }}
{{- end }}
{{- if $autoGenerate }}true{{- end }}
{{- end }}

{{/*
Returns "true" iff the operator opted in via global.monitoring.enabled AND
the cluster ships the Prometheus Operator CRDs (monitoring.coreos.com/v1).

Subcharts MUST guard every ServiceMonitor/PrometheusRule template with:

  {{- if eq (include "neuraltrust-platform.monitoring.enabled" .) "true" }}
  ...
  {{- end }}

The double-condition (flag AND capability) means clusters without the
operator never fail to install — the blocks render to empty. This is
why we don't alias the helper to a Boolean output.
*/}}
{{- define "neuraltrust-platform.monitoring.enabled" -}}
{{- $g := default dict .Values.global -}}
{{- $m := default dict $g.monitoring -}}
{{- if and $m.enabled (.Capabilities.APIVersions.Has "monitoring.coreos.com/v1") -}}
true
{{- end -}}
{{- end -}}

{{/*
Common labels for monitoring CRDs. Pass `.` as the context.
Includes operator-specific selector labels from
global.monitoring.additionalLabels so the customer can target a specific
Prometheus Operator install (e.g. release: kube-prometheus-stack).
*/}}
{{- define "neuraltrust-platform.monitoring.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service | quote }}
app.kubernetes.io/instance: {{ .Release.Name | quote }}
app.kubernetes.io/part-of: neuraltrust-platform
{{- $g := default dict .Values.global -}}
{{- $m := default dict $g.monitoring -}}
{{- with $m.additionalLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Default scrape interval and alert labels resolved from
global.monitoring. Use as:
  interval: {{ include "neuraltrust-platform.monitoring.interval" . }}
*/}}
{{- define "neuraltrust-platform.monitoring.interval" -}}
{{- $g := default dict .Values.global -}}
{{- $m := default dict $g.monitoring -}}
{{- default "30s" $m.interval -}}
{{- end -}}

{{- define "neuraltrust-platform.monitoring.alertLabels" -}}
{{- $g := default dict .Values.global -}}
{{- $m := default dict $g.monitoring -}}
{{- $labels := default dict $m.alertLabels -}}
{{- range $k, $v := $labels }}
{{ $k }}: {{ $v | quote }}
{{- end -}}
{{- end -}}

{{/*
HTTP liveness + readiness probe block.

Pass a dict with:
  - cfg:  the per-component .healthProbes map (may be nil/empty -> falls back to defaults)
  - port: container port (int)
  - path: HTTP path (string)
The probes are emitted only when (cfg.enabled is true) OR (cfg is unset).
That preserves backward compatibility — existing customer overrides that
explicitly set healthProbes.enabled=false continue to opt out.

Usage:
  {{- include "neuraltrust-platform.healthProbes" (dict
        "cfg"  $appHealthProbes
        "port" 3000
        "path" "/api/health") | nindent 8 }}
*/}}
{{- define "neuraltrust-platform.healthProbes" -}}
{{- $cfg := default dict .cfg -}}
{{- $enabled := true -}}
{{- if hasKey $cfg "enabled" -}}{{- $enabled = $cfg.enabled -}}{{- end -}}
{{- if $enabled -}}
{{- $port := .port -}}
{{- $path := default "/health" .path -}}
{{- $live := default dict $cfg.liveness -}}
{{- $ready := default dict $cfg.readiness -}}
livenessProbe:
  httpGet:
    path: {{ default $path $live.path | quote }}
    port: {{ default $port $live.port }}
  initialDelaySeconds: {{ default 30 $live.initialDelaySeconds }}
  periodSeconds: {{ default 30 $live.periodSeconds }}
  timeoutSeconds: {{ default 5 $live.timeoutSeconds }}
  failureThreshold: {{ default 5 $live.failureThreshold }}
readinessProbe:
  httpGet:
    path: {{ default $path $ready.path | quote }}
    port: {{ default $port $ready.port }}
  initialDelaySeconds: {{ default 10 $ready.initialDelaySeconds }}
  periodSeconds: {{ default 10 $ready.periodSeconds }}
  timeoutSeconds: {{ default 3 $ready.timeoutSeconds }}
  failureThreshold: {{ default 3 $ready.failureThreshold }}
{{- end -}}
{{- end -}}

{{/*
Optional PodDisruptionBudget renderer.

Pass a dict with:
  - cfg:           the per-component .podDisruptionBudget map (may be nil)
  - name:          PDB metadata.name
  - selectorLabels: map of labels matching the workload
  - namespace:     (optional) override; defaults to .Release.Namespace via caller

The PDB is emitted only when cfg.enabled is true and at least one of
cfg.minAvailable / cfg.maxUnavailable is set. Default values when both
omitted: minAvailable=1.

Usage (caller already sets metadata; this returns just the spec block):
  {{- include "neuraltrust-platform.pdbSpec" (dict
        "cfg" $cfg
        "selectorLabels" (dict "app" "control-plane-app")) }}
*/}}
{{- define "neuraltrust-platform.pdbSpec" -}}
{{- $cfg := default dict .cfg -}}
{{- if not (hasKey $cfg "minAvailable") -}}
  {{- if not (hasKey $cfg "maxUnavailable") -}}
    {{- $_ := set $cfg "minAvailable" 1 -}}
  {{- end -}}
{{- end -}}
{{- if hasKey $cfg "maxUnavailable" -}}
maxUnavailable: {{ $cfg.maxUnavailable }}
{{ else -}}
minAvailable: {{ $cfg.minAvailable }}
{{ end -}}
selector:
  matchLabels:
{{ toYaml .selectorLabels | indent 4 }}
{{- end -}}

{{/*
Stable annotations dict for triggering Deployment rollouts when any
ConfigMap/Secret it depends on changes content. Caller passes a list of
file paths under templates/ to checksum.

Usage:
  metadata:
    annotations:
      {{- include "neuraltrust-platform.checksumAnnotations" (dict
            "context" $
            "files"   (list "/configmap.yaml" "/secret.yaml")) | nindent 8 }}
*/}}
{{- define "neuraltrust-platform.checksumAnnotations" -}}
{{- $ctx := .context -}}
{{- range .files -}}
checksum/{{ . | base | replace ".yaml" "" }}: {{ include (print $ctx.Template.BasePath .) $ctx | sha256sum }}
{{ end -}}
{{- end -}}

