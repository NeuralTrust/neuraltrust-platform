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
Resolve an image reference while honoring global.imageRegistry.
*/}}
{{- define "neuraltrust-platform.image" -}}
{{- $registry := "" -}}
{{- $repository := .repository -}}
{{- $tag := .tag -}}
{{- $defaultRegistry := "europe-west1-docker.pkg.dev/neuraltrust-app-prod/nt-docker" -}}
{{- if and .global .global.imageRegistry -}}
  {{- $registry = .global.imageRegistry -}}
{{- end -}}
{{- if $registry -}}
  {{- if hasPrefix $registry $repository -}}
    {{- printf "%s:%s" $repository $tag -}}
  {{- else if hasPrefix (printf "%s/" $defaultRegistry) $repository -}}
    {{- $shortName := trimPrefix (printf "%s/" $defaultRegistry) $repository -}}
    {{- printf "%s/%s:%s" $registry $shortName $tag -}}
  {{- else -}}
    {{- printf "%s/%s:%s" $registry $repository $tag -}}
  {{- end -}}
{{- else -}}
  {{- printf "%s:%s" $repository $tag -}}
{{- end -}}
{{- end -}}

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

{{/* Kafka connection helpers live in templates/_kafka_helpers.tpl */}}

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
Resolve the product generation switch.
`global.platformVersion` selects which stack the umbrella chart deploys:
  - "v2" (default / empty / null) → next-gen stack.
  - "v1"                          → explicit legacy escape hatch.
This is intentionally NOT `global.platform` (that selects the cloud provider).
Usage: {{ include "neuraltrust-platform.platformVersion" . }}
*/}}
{{- define "neuraltrust-platform.platformVersion" -}}
{{- $global := default dict .Values.global }}
{{- $global.platformVersion | default "v2" }}
{{- end }}

{{/*
Returns "true" (non-empty) when the v2 stack is selected, empty otherwise.
Guard every v2 subchart template with:
  {{- if eq (include "neuraltrust-platform.isV2" .) "true" }}
Under explicit v1 the block renders to empty.
Usage: {{- if eq (include "neuraltrust-platform.isV2" .) "true" }}
*/}}
{{- define "neuraltrust-platform.isV2" -}}
{{- $global := default dict .Values.global }}
{{- if eq ($global.platformVersion | default "v2") "v2" }}true{{- end }}
{{- end }}

{{/*
Deployment mode for the v2 stack (ignored under v1).
`global.deploymentMode`:
  - "hybrid" (default) → only data-plane components deploy at the customer
                         (control-planes stay in NeuralTrust SaaS). DataAgent
                         bridges local reads to SaaS DataBridge.
  - "external"         → control-plane AND data-plane components deploy on-prem
                         PLUS the self-hosted analytics stack
                         (clickstack-otel-collector + DataCore reading local
                         ClickHouse). No SaaS dependency; DataAgent is not
                         deployed.
  - "full"             → DEPRECATED alias for "external". Renders identically.
Returns "true" (non-empty) only when deploymentMode is "external" (or the
deprecated "full" alias) — the zero-SaaS-dependency install that also renders
the self-hosted analytics stack (clickstack-otel-collector + DataCore + local
ClickHouse). Guard the analytics subcharts with BOTH isV2 and isExternal.
Usage: {{- if and (eq (include "neuraltrust-platform.isV2" .) "true") (eq (include "neuraltrust-platform.isExternal" .) "true") }}
*/}}
{{- define "neuraltrust-platform.isExternal" -}}
{{- $global := default dict .Values.global }}
{{- $mode := $global.deploymentMode | default "hybrid" }}
{{- if or (eq $mode "external") (eq $mode "full") }}true{{- end }}
{{- end }}

{{/*
DEPRECATED alias of isExternal, kept so existing control-plane template guards
keep working. "full" and "external" now render identically (both deploy the
control-planes). Returns "true" (non-empty) when control-planes should deploy,
i.e. mode is "external" (or the deprecated "full" alias).
Usage: {{- if and (eq (include "neuraltrust-platform.isV2" .) "true") (eq (include "neuraltrust-platform.isFull" .) "true") }}
*/}}
{{- define "neuraltrust-platform.isFull" -}}
{{- include "neuraltrust-platform.isExternal" . }}
{{- end }}

{{/*
Returns "true" (non-empty) only when deploymentMode is "hybrid" — the default
split-plane install where DataAgent bridges local reads to SaaS DataBridge.
Guard the DataAgent subchart with BOTH isV2 and isHybrid.
Usage: {{- if and (eq (include "neuraltrust-platform.isV2" .) "true") (eq (include "neuraltrust-platform.isHybrid" .) "true") }}
*/}}
{{- define "neuraltrust-platform.isHybrid" -}}
{{- $global := default dict .Values.global }}
{{- if eq ($global.deploymentMode | default "hybrid") "hybrid" }}true{{- end }}
{{- end }}

{{/*
Return "true" when DataAgent has a complete deployable configuration.
Every DataAgent resource MUST use this single guard so partial configuration
cannot leave dangling Secrets, ConfigMaps, ServiceAccounts, or PDBs.

Required:
  - Platform v2
  - hybrid deployment mode
  - non-empty tenantId
  - either an inline enrolmentToken, an existing Secret name, or a previously
    generated dataagent-secrets/ENROLMENT_TOKEN from an earlier release
  - database credentials generated by this chart or supplied through
    existingSecret.name

The enrolment token is issued by SaaS and is never generated by this chart.
Usage: {{- if eq (include "neuraltrust-platform.dataagentEnabled" .) "true" }}
*/}}
{{- define "neuraltrust-platform.dataagentEnabled" -}}
{{- $cfg := .Values -}}
{{- if hasKey .Values "dataagent" -}}{{- $cfg = default dict .Values.dataagent -}}{{- end -}}
{{- $tenantId := $cfg.tenantId | default "" -}}
{{- $token := $cfg.enrolmentToken | default "" -}}
{{- $existing := default dict $cfg.enrolmentTokenExistingSecret -}}
{{- $existingName := $existing.name | default "" -}}
{{- $managedSecret := lookup "v1" "Secret" .Release.Namespace "dataagent-secrets" -}}
{{- $managedData := dict -}}
{{- if and $managedSecret (kindIs "map" $managedSecret) $managedSecret.data -}}
  {{- $managedData = $managedSecret.data -}}
{{- end -}}
{{- $hasManagedToken := and (hasKey $managedData "ENROLMENT_TOKEN") (ne (index $managedData "ENROLMENT_TOKEN") "") -}}
{{- $dataSecret := default dict $cfg.existingSecret -}}
{{- $dataSecretName := $dataSecret.name | default "" -}}
{{- $hasManagedDatabase := and (hasKey $managedData "DATABASE_URL") (ne (index $managedData "DATABASE_URL") "") -}}
{{- $preserve := dig "preserveExistingSecrets" false (.Values.global | default dict) -}}
{{- $chartGeneratesDatabase := and (eq (include "neuraltrust-platform.autoGenerateSecrets" .) "true") (not $preserve) -}}
{{- $tokenReady := or $existingName $hasManagedToken (and $token $chartGeneratesDatabase) -}}
{{- if and
  (eq (include "neuraltrust-platform.isV2" .) "true")
  (eq (include "neuraltrust-platform.isHybrid" .) "true")
  $tenantId
  $tokenReady
  (or $chartGeneratesDatabase $dataSecretName $hasManagedDatabase)
-}}true{{- end -}}
{{- end }}

{{/*
Effective v2 service database name, keyed on deployment mode:
  - external: each service owns a private database (defaults to its own name), because
    the control planes run on-prem and own their migrations.
  - hybrid: the data planes share ONE database ("trustdata"); isolation is by schema
    (see v2-postgres-init.yaml), so DataAgent's single connection can read both.
An explicit database.name always wins over the mode default.
Usage: {{ include "neuraltrust-platform.v2.dbName" (dict "ctx" . "explicit" .Values.database.name "external" "agentgateway") }}
*/}}
{{- define "neuraltrust-platform.v2.dbName" -}}
{{- if .explicit -}}
{{- .explicit -}}
{{- else if eq (include "neuraltrust-platform.isExternal" .ctx) "true" -}}
{{- .external -}}
{{- else -}}
trustdata
{{- end -}}
{{- end }}

{{/*
Resolve the PostgreSQL host for a v2 service. Subcharts only see .Values.global,
so we cannot inspect the parent's infrastructure.postgresql.deploy from here:
default to the in-cluster Service name (control-plane-postgresql) and require an
explicit host override for external/hosted Postgres. This makes local deploys
zero-config while external deploys just overlay the host.
Usage: {{ include "neuraltrust-platform.postgres.host" (dict "host" .Values.database.host) }}
*/}}
{{- define "neuraltrust-platform.postgres.host" -}}
{{- .host | default "control-plane-postgresql" }}
{{- end }}

{{/*
Render the shared TrustGuard client-credentials env (client_credentials pair the
AgentGateway proxy presents to TrustGuard and TrustGuard validates). Both values
come from one Secret so the id/secret stay identical across services. During
externally managed upgrades, the prerelease Secret name remains usable without
requiring lookup access.
*/}}
{{- define "neuraltrust-platform.trustguardClientSecretName" -}}
{{- $ctx := .ctx -}}
{{- $global := default dict $ctx.Values.global -}}
{{- $v2 := default dict $global.v2 -}}
{{- $explicit := $v2.trustguardClientSecretName | default "" -}}
{{- if $explicit -}}
{{- $explicit -}}
{{- else if ($global.preserveExistingSecrets | default false) -}}
  {{- $current := lookup "v1" "Secret" $ctx.Release.Namespace "trustguard-client-credentials" -}}
  {{- if $current -}}trustguard-client-credentials
  {{- else if $ctx.Release.IsUpgrade -}}v2-trustguard-client-secret
  {{- else -}}trustguard-client-credentials
  {{- end -}}
{{- else -}}
trustguard-client-credentials
{{- end -}}
{{- end }}

{{/*
Render the shared client credential pair. optional:true keeps workloads bootable
when platform-scope authentication is intentionally disabled.
Usage: {{ include "neuraltrust-platform.trustguardClientEnv" (dict "ctx" . "idVar" "TRUSTGUARD_CLIENT_ID" "secretVar" "TRUSTGUARD_CLIENT_SECRET") }}
*/}}
{{- define "neuraltrust-platform.trustguardClientEnv" -}}
{{- $secretName := include "neuraltrust-platform.trustguardClientSecretName" (dict "ctx" .ctx) }}
- name: {{ .idVar }}
  valueFrom:
    secretKeyRef:
      name: {{ $secretName }}
      key: CLIENT_ID
      optional: true
- name: {{ .secretVar }}
  valueFrom:
    secretKeyRef:
      name: {{ $secretName }}
      key: CLIENT_SECRET
      optional: true
{{- end }}

{{/*
Returns "true" (non-empty) when the in-cluster ClickHouse subchart is allowed to
render. Allowed in v1 (any mode) and v2 EXTERNAL only — NOT v2 hybrid. In hybrid
the analytics store lives in NeuralTrust SaaS (data planes write raw telemetry to
Postgres, DataAgent bridges it out), so nothing writes to a local ClickHouse; the
optional data-plane-api read shim, if wanted, points at an external ClickHouse
instead. In v2 external the self-hosted analytics stack (clickstack-otel-collector
+ DataCore + data-plane-api) needs it. Rendering is still gated by the Chart.yaml
`infrastructure.clickhouse.deploy` condition, so external/v1 operators using a
hosted ClickHouse set deploy: false to skip it. Guard every charts/clickhouse
template with this.
Usage: {{- if eq (include "neuraltrust-platform.clickhouseAllowed" .) "true" }}
*/}}
{{- define "neuraltrust-platform.clickhouseAllowed" -}}
{{- if eq (include "neuraltrust-platform.isV2" .) "true" -}}
{{- if eq (include "neuraltrust-platform.isExternal" .) "true" -}}true{{- end -}}
{{- else -}}
true
{{- end -}}
{{- end }}

{{/*
Resolve the neuraltrust-data-plane `dataPlane.components` dict from EITHER the
umbrella root context (.Values["neuraltrust-data-plane"].dataPlane.components) or
the neuraltrust-data-plane subchart context (.Values.dataPlane.components) —
whichever resolves a non-empty dict wins, so this is safe to call from either
chart (mirrors dataPlaneApi.redisConfig).
Usage: {{ include "neuraltrust-platform.dataPlane.components" . | fromYaml }}
*/}}
{{- define "neuraltrust-platform.dataPlane.components" -}}
{{- $root := default dict (index .Values "neuraltrust-data-plane") }}
{{- $rootComp := default dict (default dict $root.dataPlane).components }}
{{- $subComp := default dict (default dict .Values.dataPlane).components }}
{{- $comp := $rootComp }}
{{- if not $comp }}{{- $comp = $subComp }}{{- end }}
{{- default dict $comp | toYaml }}
{{- end }}

{{/*
Resolve the SQL backend the data-plane-api reads from: "postgres" | "clickhouse".
The data-plane-api image (>= v1.40.0) selects its analytics/evaluation store via
SQL_DATABASE. Resolution order:
  1. Explicit dataPlane.components.api.database.backend ("postgres"/"postgresql"
     or "clickhouse") always wins — for rollback or advanced deployments.
  2. Empty/"auto" in v2 HYBRID: PostgreSQL by default, EXCEPT when a dotted
     (external) ClickHouse host is configured — then ClickHouse, preserving
     existing hybrid installs that opted into an external ClickHouse read shim.
  3. Empty/"auto" in v2 external or v1: ClickHouse (unchanged legacy behavior).
Unknown explicit values fall through to ClickHouse here; validate-values.yaml
fails the render for them so misconfiguration surfaces loudly.
Safe to call from either the umbrella root or the neuraltrust-data-plane subchart
context (see dataPlane.components above).
Usage: {{ include "neuraltrust-platform.dataPlaneApi.sqlBackend" . }}
*/}}
{{- define "neuraltrust-platform.dataPlaneApi.sqlBackend" -}}
{{- $comp := include "neuraltrust-platform.dataPlane.components" . | fromYaml }}
{{- $api := default dict $comp.api }}
{{- $db := default dict $api.database }}
{{- $backend := $db.backend | default "" | toString | lower }}
{{- $ch := default dict $comp.clickhouse }}
{{- $chHost := $ch.host | default "clickhouse" }}
{{- $chDotted := contains "." $chHost }}
{{- $isV2 := eq (include "neuraltrust-platform.isV2" .) "true" }}
{{- $isHybrid := eq (include "neuraltrust-platform.isHybrid" .) "true" }}
{{- if or (eq $backend "postgres") (eq $backend "postgresql") -}}
postgres
{{- else if eq $backend "clickhouse" -}}
clickhouse
{{- else if and $isV2 $isHybrid -}}
{{- if $chDotted -}}clickhouse{{- else -}}postgres{{- end -}}
{{- else -}}
clickhouse
{{- end -}}
{{- end }}

{{/*
Returns "true" (non-empty) when the temporary v2 data-plane-api shim should
render. In v2 the legacy data-plane subchart is disabled, but the read/analytics
API (data-plane-api) is kept alive until TrustLens replaces it. Its SQL store is
resolved by dataPlaneApi.sqlBackend:
  - PostgreSQL backend: renders whenever dataPlane.enabled AND api.enabled (the
    v2 hybrid default — it reuses the umbrella PostgreSQL, no ClickHouse needed).
  - ClickHouse backend: renders whenever dataPlane.enabled AND api.enabled in v2
    EXTERNAL (or v1); in v2 HYBRID it renders ONLY when pointed at an EXTERNAL
    (dotted) ClickHouse host so it never boots without a store.
Only the API component renders — kafka-workers and kafka-connect stay off.
MUST be invoked from the neuraltrust-data-plane subchart context so `.Values`
resolves to that subchart's values (.Values.dataPlane...).
Usage: {{- if eq (include "neuraltrust-platform.dataPlaneApiV2.enabled" .) "true" }}
*/}}
{{- define "neuraltrust-platform.dataPlaneApiV2.enabled" -}}
{{- if eq (include "neuraltrust-platform.isV2" .) "true" }}
{{- $dp := default dict .Values.dataPlane }}
{{- $dpOn := true }}{{- if hasKey $dp "enabled" }}{{- $dpOn = $dp.enabled }}{{- end }}
{{- $components := default dict $dp.components }}
{{- $api := default dict $components.api }}
{{- $apiOn := true }}{{- if hasKey $api "enabled" }}{{- $apiOn = $api.enabled }}{{- end }}
{{- $backend := include "neuraltrust-platform.dataPlaneApi.sqlBackend" . }}
{{- $render := false }}
{{- if eq $backend "postgres" }}
{{- $render = true }}
{{- else }}
{{- if eq (include "neuraltrust-platform.isHybrid" .) "true" }}
{{- $ch := default dict $components.clickhouse }}
{{- $chHost := $ch.host | default "clickhouse" }}
{{- if contains "." $chHost }}{{- $render = true }}{{- end }}
{{- else }}
{{- $render = true }}
{{- end }}
{{- end }}
{{- if and $dpOn $apiOn $render }}true{{- end }}
{{- end }}
{{- end }}

{{/*
Resolve the data-plane-api evaluation-progress cache dict
(neuraltrust-data-plane.dataPlane.components.api.redis) from EITHER the
umbrella root context (.Values["neuraltrust-data-plane"]...) or the
neuraltrust-data-plane subchart context (.Values.dataPlane...) — whichever
resolves a non-empty dict wins, so this is safe to call from either chart.
Usage: {{ include "neuraltrust-platform.dataPlaneApi.redisConfig" . }}
*/}}
{{- define "neuraltrust-platform.dataPlaneApi.redisConfig" -}}
{{- $root := default dict (index .Values "neuraltrust-data-plane") }}
{{- $rootApi := default dict (default dict (default dict $root.dataPlane).components).api }}
{{- $sub := default dict .Values.dataPlane }}
{{- $subApi := default dict (default dict $sub.components).api }}
{{- $cfg := $rootApi.redis }}
{{- if not $cfg }}{{- $cfg = $subApi.redis }}{{- end }}
{{- default dict $cfg | toYaml }}
{{- end }}

{{/*
Resolve the data-plane-api evaluation-progress cache backend ("redis" | "kafka").
v1 default: "kafka" — Kafka already deploys and is wired into data-plane-api,
so no Redis dependency is introduced for existing v1 releases. v2 default:
"redis" — v2 ships without Kafka, pointed at the same umbrella-managed Redis
AgentGateway/TrustGuard use (infrastructure.redis / service "redis"). Set
neuraltrust-data-plane.dataPlane.components.api.redis.backend explicitly to
override either default.
Usage: {{ include "neuraltrust-platform.dataPlaneApi.redisBackend" . }}
*/}}
{{- define "neuraltrust-platform.dataPlaneApi.redisBackend" -}}
{{- $cfg := include "neuraltrust-platform.dataPlaneApi.redisConfig" . | fromYaml }}
{{- if $cfg.backend -}}
{{- if not (or (eq ($cfg.backend | toString) "redis") (eq ($cfg.backend | toString) "kafka")) -}}
{{- fail "neuraltrust-data-plane.dataPlane.components.api.redis.backend must be \"redis\" or \"kafka\"" -}}
{{- end -}}
{{- $cfg.backend -}}
{{- else if eq (include "neuraltrust-platform.isV2" .) "true" -}}
redis
{{- else -}}
kafka
{{- end -}}
{{- end -}}

{{/*
Build the data-plane-api REDIS_URL (redis://[user:pass@]host:port/db, or
rediss:// when TLS/IAM). Returns "" when the resolved backend is not "redis".
Contains the password in plaintext — callers MUST place the result in a
Secret, never a ConfigMap. Safe to call from either the umbrella root or the
neuraltrust-data-plane subchart context (see redisConfig above).
Usage: {{ include "neuraltrust-platform.dataPlaneApi.redisUrl" . }}
*/}}
{{- define "neuraltrust-platform.dataPlaneApi.redisUrl" -}}
{{- if eq (include "neuraltrust-platform.dataPlaneApi.redisBackend" .) "redis" }}
{{- $cfg := include "neuraltrust-platform.dataPlaneApi.redisConfig" . | fromYaml }}
{{- $host := $cfg.host | default "redis" }}
{{- $port := $cfg.port | default 6379 }}
{{- $db := $cfg.db | default "0" }}
{{- $tls := $cfg.tls | default "" }}
{{- $iamAuth := $cfg.iamAuth | default false }}
{{- $scheme := "redis" }}
{{- if or $iamAuth (eq ($tls | toString) "true") }}{{- $scheme = "rediss" }}{{- end }}
{{- $authority := "" }}
{{- if not $iamAuth }}
  {{- $user := $cfg.username | default "" }}
  {{- $pw := $cfg.password | default "" }}
  {{- if $user }}
    {{- $authority = printf "%s:%s@" ($user | urlquery) ($pw | urlquery) }}
  {{- else if $pw }}
    {{- $authority = printf ":%s@" ($pw | urlquery) }}
  {{- end }}
{{- end }}
{{- printf "%s://%s%s:%v/%s" $scheme $authority $host $port $db -}}
{{- end }}
{{- end -}}

{{/*
Resolve the data-plane-api PostgreSQL connection dict
(neuraltrust-data-plane.dataPlane.components.api.database.postgresql) from EITHER
the umbrella root or the neuraltrust-data-plane subchart context — whichever
resolves a non-empty dict wins.
Usage: {{ include "neuraltrust-platform.dataPlaneApi.postgresConfig" . | fromYaml }}
*/}}
{{- define "neuraltrust-platform.dataPlaneApi.postgresConfig" -}}
{{- $comp := include "neuraltrust-platform.dataPlane.components" . | fromYaml }}
{{- $api := default dict $comp.api }}
{{- $db := default dict $api.database }}
{{- default dict $db.postgresql | toYaml }}
{{- end }}

{{/*
Emit the data-plane-api PostgreSQL connection env vars (SQL_DATABASE=postgres +
the five POSTGRES_* the binary reads). Precedence per connection field:
  1. non-empty scalar value under api.database.postgresql (host/port/user/database)
  2. the mapped key from the configured existingSecret (default: postgresql-secrets)
The password is ALWAYS read from a Secret via secretKeyRef (never inlined),
defaulting to postgresql-secrets/POSTGRES_PASSWORD. The platform Secret stores
the database name under POSTGRES_DB, which is mapped to the binary's expected
POSTGRES_DATABASE. secretKeyRef references are required (not optional) so an
incomplete PostgreSQL configuration fails visibly instead of booting half-wired.
Also emits PGSSLMODE from api.database.postgresql.sslMode (default "prefer") so a
single default works against the non-TLS in-cluster PostgreSQL and TLS hosted DBs.
Usage: {{- include "neuraltrust-platform.dataPlaneApi.postgresEnv" . | nindent 10 }}
*/}}
{{- define "neuraltrust-platform.dataPlaneApi.postgresEnv" -}}
{{- $pg := include "neuraltrust-platform.dataPlaneApi.postgresConfig" . | fromYaml }}
{{- $es := default dict $pg.existingSecret }}
{{- $secretName := $es.name | default "postgresql-secrets" }}
{{- $keys := default dict $es.keys }}
{{- $hostKey := $keys.host | default "POSTGRES_HOST" }}
{{- $portKey := $keys.port | default "POSTGRES_PORT" }}
{{- $userKey := $keys.user | default "POSTGRES_USER" }}
{{- $passwordKey := $keys.password | default "POSTGRES_PASSWORD" }}
{{- $databaseKey := $keys.database | default "POSTGRES_DB" }}
- name: SQL_DATABASE
  value: "postgres"
- name: POSTGRES_HOST
{{- if $pg.host }}
  value: {{ $pg.host | quote }}
{{- else }}
  valueFrom:
    secretKeyRef:
      name: {{ $secretName | quote }}
      key: {{ $hostKey | quote }}
{{- end }}
- name: POSTGRES_PORT
{{- if $pg.port }}
  value: {{ $pg.port | quote }}
{{- else }}
  valueFrom:
    secretKeyRef:
      name: {{ $secretName | quote }}
      key: {{ $portKey | quote }}
{{- end }}
- name: POSTGRES_USER
{{- if $pg.user }}
  value: {{ $pg.user | quote }}
{{- else }}
  valueFrom:
    secretKeyRef:
      name: {{ $secretName | quote }}
      key: {{ $userKey | quote }}
{{- end }}
- name: POSTGRES_DATABASE
{{- if $pg.database }}
  value: {{ $pg.database | quote }}
{{- else }}
  valueFrom:
    secretKeyRef:
      name: {{ $secretName | quote }}
      key: {{ $databaseKey | quote }}
{{- end }}
- name: POSTGRES_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ $secretName | quote }}
      key: {{ $passwordKey | quote }}
- name: PGSSLMODE
  value: {{ $pg.sslMode | default "prefer" | quote }}
{{- end -}}

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
Config-sync data-plane environment.
Emits the non-secret env that turns a workload into a DB-less config-sync data
plane. The endpoint and transport are derived from the deployment mode:
  hybrid: dial the fixed public SaaS endpoint <product>-configsync.<saasDomain>:443
          over TLS verified against the public root store (no CA distribution).
  full:   dial the in-cluster control-plane Service over plaintext by default
          (configSync.tlsInsecure), since both planes live in the same cluster.
The shared token and the local LKG key arrive via the workload's existing envFrom
secretRef, so they are not emitted here. Rendered only when configSync.enabled.
Usage: {{- include "neuraltrust-platform.configSyncEnv" (dict "ctx" . "product" "trustguard") | nindent 8 }}
*/}}
{{- define "neuraltrust-platform.configSyncEnv" -}}
{{- $ctx := .ctx -}}
{{- $product := .product -}}
{{- $tlsCaPath := .tlsCaPath | default "" -}}
{{- $cs := default dict $ctx.Values.configSync -}}
{{- if $cs.enabled -}}
{{- $isFull := eq (include "neuraltrust-platform.isFull" $ctx) "true" -}}
{{- $endpoint := $cs.endpoint -}}
{{- $insecure := false -}}
{{- $caPath := "" -}}
{{- if $isFull -}}
  {{- /* Full: dial the in-cluster control plane. When the caller provides a
         generated CA path (tlsCaPath), the listener runs TLS (deployed APP_ENV)
         and we verify against that CA. Otherwise fall back to plaintext, which
         the app only accepts under a non-prod APP_ENV. */ -}}
  {{- if $tlsCaPath -}}
    {{- $caPath = $tlsCaPath -}}
  {{- else -}}
    {{- $insecure = ternary $cs.tlsInsecure true (hasKey $cs "tlsInsecure") -}}
    {{- $caPath = $cs.tlsCa -}}
  {{- end -}}
  {{- if not $endpoint -}}
    {{- $endpoint = printf "%s.%s.svc.cluster.local:%v" $ctx.Values.controlPlane.name $ctx.Release.Namespace $ctx.Values.controlPlane.ports.grpc -}}
  {{- end -}}
{{- else -}}
  {{- /* Hybrid: fixed public SaaS endpoint, verified against public roots. */ -}}
  {{- $saasDomain := $cs.saasDomain | default "neuraltrust.ai" -}}
  {{- $caPath = $cs.tlsCa -}}
  {{- if not $endpoint -}}
    {{- $endpoint = printf "%s-configsync.%s:443" $product $saasDomain -}}
  {{- end -}}
{{- end -}}
- name: CONFIG_SYNC_DATA_PLANE_ENABLED
  value: "true"
- name: CONFIG_SYNC_GRPC_ENDPOINT
  value: {{ $endpoint | quote }}
{{- if $insecure }}
- name: CONFIG_SYNC_TLS_INSECURE
  value: "true"
{{- else }}
- name: CONFIG_SYNC_TLS_INSECURE
  value: "false"
- name: CONFIG_SYNC_TLS_SERVER_NAME
  value: {{ $cs.serverName | default (regexReplaceAll ":[0-9]+$" $endpoint "") | quote }}
{{- with $caPath }}
- name: CONFIG_SYNC_TLS_CA
  value: {{ . | quote }}
{{- end }}
{{- end }}
{{- end -}}
{{- end }}

{{/*
Config-sync shared token. Priority: explicit configSync.token > value preserved
from the existing cluster secret > empty. Never auto-generated: it MUST match the
SaaS control plane, so an empty result means the operator delivers it out-of-band
(pre-created secret + global.preserveExistingSecrets, or --set configSync.token).
Usage: {{ include "neuraltrust-platform.configSync.token" (dict "ctx" . "existingSecret" $existing) }}
*/}}
{{- define "neuraltrust-platform.configSync.token" -}}
{{- $cs := default dict .ctx.Values.configSync -}}
{{- $existing := .existingSecret -}}
{{- if and $cs.token (ne ($cs.token | toString) "") -}}
{{- $cs.token -}}
{{- else if and $existing (kindIs "map" $existing) (index $existing "data") (hasKey $existing.data "CONFIG_SYNC_TOKEN") -}}
{{- index $existing.data "CONFIG_SYNC_TOKEN" | b64dec -}}
{{- end -}}
{{- end }}

{{/*
Config-sync local LKG cache key (base64 of exactly 32 bytes). Priority: explicit
configSync.lkgKey > value preserved from the existing cluster secret > generated.
Unlike the token this is local-only, so auto-generating a fresh 32-byte key is safe.
Usage: {{ include "neuraltrust-platform.configSync.lkgKey" (dict "ctx" . "existingSecret" $existing) }}
*/}}
{{- define "neuraltrust-platform.configSync.lkgKey" -}}
{{- $cs := default dict .ctx.Values.configSync -}}
{{- $existing := .existingSecret -}}
{{- if and $cs.lkgKey (ne ($cs.lkgKey | toString) "") -}}
{{- $cs.lkgKey -}}
{{- else if and $existing (kindIs "map" $existing) (index $existing "data") (hasKey $existing.data "CONFIG_SYNC_LKG_KEY") -}}
{{- index $existing.data "CONFIG_SYNC_LKG_KEY" | b64dec -}}
{{- else -}}
{{- randBytes 32 -}}
{{- end -}}
{{- end }}

{{/*
ClickStack OTLP export for the v2 data planes in HYBRID mode.

Returns "true" (non-empty) only when the deployment is v2 + hybrid AND
global.clickstack.enabled is set. External mode has its own always-on ClickStack
wiring and does NOT go through this helper. When true, the AgentGateway and
TrustGuard data planes ALSO emit product data (meta/raw) over OTLP to the
configured collector, in addition to the Postgres raw path used by DataAgent.
Usage: {{- if eq (include "neuraltrust-platform.clickstackHybridEnabled" .) "true" }}
*/}}
{{- define "neuraltrust-platform.clickstackHybridEnabled" -}}
{{- $global := default dict .Values.global -}}
{{- $cfg := default dict $global.clickstack -}}
{{- if and (eq (include "neuraltrust-platform.isV2" .) "true") (eq (include "neuraltrust-platform.isHybrid" .) "true") $cfg.enabled -}}
true
{{- end -}}
{{- end }}

{{/*
Non-secret OTLP exporter env for the hybrid ClickStack export. Emits the
endpoint + protocol (+ insecure only when explicitly requested). The bearer
token is injected separately via the data-plane Secret so it never lands in a
ConfigMap. Call with the deployment context and nindent to the data: block.
Usage: {{- include "neuraltrust-platform.clickstack.otlpEnv" . | nindent 2 }}
*/}}
{{- define "neuraltrust-platform.clickstack.otlpEnv" -}}
{{- $cfg := default dict (default dict .Values.global).clickstack -}}
OTEL_EXPORTER_OTLP_ENDPOINT: {{ $cfg.endpoint | quote }}
OTEL_EXPORTER_OTLP_PROTOCOL: {{ $cfg.protocol | default "http/protobuf" | quote }}
{{- if $cfg.insecure }}
OTEL_EXPORTER_OTLP_INSECURE: "true"
{{- end }}
{{- end }}

{{/*
Resolve the OTEL_EXPORTER_OTLP_HEADERS value for the hybrid ClickStack export.
Priority: inline global.clickstack.authToken (formatted as an Authorization
Bearer header) > value preserved from the existing data-plane Secret > empty.
An empty result means no auth header is shipped (collector auth disabled, or the
operator supplies OTEL_EXPORTER_OTLP_HEADERS out-of-band).
Usage: {{ include "neuraltrust-platform.clickstack.otlpHeaders" (dict "ctx" . "existingSecret" $existing) }}
*/}}
{{- define "neuraltrust-platform.clickstack.otlpHeaders" -}}
{{- $cfg := default dict (default dict .ctx.Values.global).clickstack -}}
{{- $existing := .existingSecret -}}
{{- $token := $cfg.authToken | default "" -}}
{{- if and $token (ne ($token | toString) "") -}}
{{- printf "authorization=%s" $token -}}
{{- else if and $existing (kindIs "map" $existing) (index $existing "data") (hasKey $existing.data "OTEL_EXPORTER_OTLP_HEADERS") -}}
{{- index $existing.data "OTEL_EXPORTER_OTLP_HEADERS" | b64dec -}}
{{- end -}}
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
Global AWS IRSA service account annotations.

When global.irsa.roleArn is set and global.irsa.applyGlobally is true, every
ServiceAccount template that includes this helper receives the role annotation.
Leave applyGlobally false and set per-component serviceAccount.annotations for
least privilege.
*/}}
{{- define "neuraltrust-platform.irsa.annotations" -}}
{{- $irsa := (default dict (default dict .Values.global).irsa) -}}
{{- if and $irsa.roleArn $irsa.applyGlobally }}
eks.amazonaws.com/role-arn: {{ $irsa.roleArn | quote }}
{{- end }}
{{- end }}

{{/*
Merged ServiceAccount annotations (global IRSA + per-component), rendered as a
clean YAML block with no leading blank line. Returns empty when there are none,
so callers can guard the `annotations:` key with `with`. Per-component keys win
over the global IRSA role (least privilege).
Usage:
  {{- $saAnn := include "neuraltrust-platform.serviceAccount.annotationsBlock" (dict "ctx" . "annotations" $annotations) }}
  {{- with $saAnn }}
  annotations:
    {{- . | nindent 4 }}
  {{- end }}
*/}}
{{- define "neuraltrust-platform.serviceAccount.annotationsBlock" -}}
{{- $ctx := .ctx -}}
{{- $irsa := (default dict (default dict $ctx.Values.global).irsa) -}}
{{- $merged := dict -}}
{{- if and $irsa.roleArn $irsa.applyGlobally -}}
{{- $_ := set $merged "eks.amazonaws.com/role-arn" ($irsa.roleArn | toString) -}}
{{- end -}}
{{- range $k, $v := (default dict .annotations) -}}
{{- $_ := set $merged $k $v -}}
{{- end -}}
{{- if $merged -}}
{{- toYaml $merged -}}
{{- end -}}
{{- end }}

{{/*
True when the neuraltrust-watchdog subchart is enabled at the umbrella level.
Used to gate the OTel Collector's Prometheus exporter (the bundled or reused
watchdog Prometheus is its only scraper).
*/}}
{{- define "neuraltrust-platform.watchdogEnabled" -}}
{{- $wd := default dict (index .Values "neuraltrust-watchdog") -}}
{{- if $wd.enabled -}}true{{- end -}}
{{- end }}

{{/*
Merged pod nodeSelector (global.nodeSelector + per-component nodeSelector).
Lets operators pin the entire platform to a dedicated node pool with a single
global.nodeSelector, while per-component values still work and win on key
conflicts. Default OFF — when both are empty nothing is emitted, so existing
releases are unaffected.

Emits the full `nodeSelector:` block (key + values) or nothing.
Usage: {{- include "neuraltrust-platform.nodeSelector" (dict "ctx" . "local" .Values.x.nodeSelector) | nindent 6 }}
*/}}
{{- define "neuraltrust-platform.nodeSelector" -}}
{{- $global := (default dict (default dict .ctx.Values.global).nodeSelector) -}}
{{- $local := default dict .local -}}
{{- $merged := merge (deepCopy $local) $global -}}
{{- with $merged }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{/*
Merged pod tolerations (global.tolerations + per-component tolerations).
A truly exclusive node pool is usually tainted, so global.tolerations is the
companion to global.nodeSelector. Global tolerations are concatenated with any
per-component tolerations (both apply). Default OFF — empty emits nothing.

Emits the full `tolerations:` block or nothing.
Usage: {{- include "neuraltrust-platform.tolerations" (dict "ctx" . "local" .Values.x.tolerations) | nindent 6 }}
*/}}
{{- define "neuraltrust-platform.tolerations" -}}
{{- $global := (default (list) (default dict .ctx.Values.global).tolerations) -}}
{{- $local := default (list) .local -}}
{{- $merged := concat $global $local -}}
{{- with $merged }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{/*
Merged map of nodeSelector keys (global + per-component), per-component wins.
For workloads that express node selection as nodeAffinity (e.g. firewall
workers) rather than a plain nodeSelector field. Returns the merged dict (or an
empty dict) for the caller to range over.
Usage: {{- $sel := include "neuraltrust-platform.nodeSelectorMap" (dict "ctx" . "local" $cfg.nodeSelector) | fromYaml }}
*/}}
{{- define "neuraltrust-platform.nodeSelectorMap" -}}
{{- $global := (default dict (default dict .ctx.Values.global).nodeSelector) -}}
{{- $local := default dict .local -}}
{{- merge (deepCopy $local) $global | toYaml -}}
{{- end -}}

{{/*
Render user-supplied pod volumes from component values.
*/}}
{{- define "neuraltrust-platform.extraVolumes" -}}
{{- with .items }}
{{- toYaml . }}
{{- end }}
{{- end }}

{{/*
Render user-supplied container volume mounts from component values.
*/}}
{{- define "neuraltrust-platform.extraVolumeMounts" -}}
{{- with .items }}
{{- toYaml . }}
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
Return true when a confirmed v1-to-v2 upgrade can prove that cluster lookup is
working. This lets the first live migration create new v2 Secrets without
turning confirmV2Migration into permission to regenerate them in lookup-less
renderers on every reconciliation.
*/}}
{{- define "neuraltrust-platform.confirmedMigrationCanGenerateSecrets" -}}
{{- $global := default dict .Values.global -}}
{{- if and .Release.IsUpgrade ($global.confirmV2Migration | default false) -}}
  {{- $trustgate := lookup "apps/v1" "Deployment" .Release.Namespace "trustgate-control-plane" -}}
  {{- $kafka := lookup "apps/v1" "StatefulSet" .Release.Namespace "kafka" -}}
  {{- $worker := lookup "apps/v1" "Deployment" .Release.Namespace "data-plane-worker" -}}
  {{- $controlPlane := lookup "apps/v1" "Deployment" .Release.Namespace "control-plane-api" -}}
  {{- $dataPlane := lookup "apps/v1" "Deployment" .Release.Namespace "data-plane-api" -}}
  {{- $postgresSecret := lookup "v1" "Secret" .Release.Namespace "postgresql-secrets" -}}
  {{- if or $trustgate $kafka $worker $controlPlane $dataPlane $postgresSecret -}}true{{- end -}}
{{- end -}}
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

