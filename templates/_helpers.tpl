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
{{- printf "%s-clickhouse" .Release.Name }}
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
{{- printf "%s-kafka:9092" .Release.Name }}
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
  {{- if $gcp.backendConfig }}
    {{- $_ := set $merged "cloud.google.com/backend-config" (printf `{"default":"%s"}` $gcp.backendConfig) }}
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

