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
Deployment mode selection. v2 supports two topologies:
  - "hybrid" (default) → only data-plane components + DataAgent deploy at the
                         customer; control-planes stay in NeuralTrust SaaS.
  - "external"         → control-plane, data-plane, and the self-hosted
                         analytics stack all deploy on-prem. No SaaS dependency;
                         DataAgent is not deployed.
*/}}
{{- define "neuraltrust-platform.isExternal" -}}
{{- $global := default dict .Values.global }}
{{- if eq ($global.deploymentMode | default "hybrid") "external" }}true{{- end }}
{{- end }}

{{- define "neuraltrust-platform.isHybrid" -}}
{{- $global := default dict .Values.global }}
{{- if eq ($global.deploymentMode | default "hybrid") "hybrid" }}true{{- end }}
{{- end }}

{{/*
Backward-compatible aliases. Every v2 template renders under "true" now that
v1 is retired; keep the guards so subchart templates continue to compile
without a mass rewrite. `isFull` is the historical alias for "external".
*/}}
{{- define "neuraltrust-platform.isV2" -}}true{{- end }}
{{- define "neuraltrust-platform.isFull" -}}
{{- include "neuraltrust-platform.isExternal" . }}
{{- end }}

{{/*
Check if the current platform is OpenShift.
Returns "true" (non-empty) if OpenShift, empty string otherwise.
Usage: {{- if include "neuraltrust-platform.isOpenshift" . }}
*/}}
{{- define "neuraltrust-platform.isOpenshift" -}}
{{- $global := default dict .Values.global }}
{{- if or (eq ($global.platform | default "") "openshift") $global.openshift }}true{{- end }}
{{- end }}

{{/*
Unified accessors for the v2 subchart value namespaces. In chart 2.2 the
values roots are unprefixed (control-plane-api, control-plane-app,
data-plane-api, firewall, watchdog). These helpers return a YAML-encoded dict
consumed via `| fromYaml`, letting callers use the historical helper names
without every template being rewritten.
*/}}
{{- define "neuraltrust-platform.controlPlaneValues" -}}
{{- $api := default dict (index .Values "control-plane-api") -}}
{{- $app := default dict (index .Values "control-plane-app") -}}
{{- /* Deep-merge API + App so consumers see one combined `controlPlane` view. */ -}}
{{- $merged := deepCopy $api -}}
{{- if $app -}}{{- $merged = mergeOverwrite $merged (deepCopy $app) -}}{{- end -}}
{{- $merged | toYaml -}}
{{- end -}}

{{- define "neuraltrust-platform.dataPlaneValues" -}}
{{- default dict (index .Values "data-plane-api") | toYaml -}}
{{- end -}}

{{- define "neuraltrust-platform.firewallValues" -}}
{{- default dict .Values.firewall | toYaml -}}
{{- end -}}

{{- define "neuraltrust-platform.watchdogValues" -}}
{{- default dict .Values.watchdog | toYaml -}}
{{- end -}}

{{/*
Get ClickHouse connection details. In v2 external only.
*/}}
{{- define "neuraltrust-platform.clickhouse.host" -}}
{{- if .Values.infrastructure.clickhouse.deploy }}
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
{{- .Values.clickhouse.auth.username | default "neuraltrust" }}
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
In-cluster PostgreSQL deploy gate.
Returns "true" when global.postgresql.deploy is true (the only path in v2).
*/}}
{{- define "neuraltrust-platform.postgresql.deploy" -}}
{{- $pg := default dict (default dict .Values.global).postgresql -}}
{{- $deploy := true -}}
{{- if hasKey $pg "deploy" -}}{{- $deploy = $pg.deploy -}}{{- end -}}
{{- if $deploy -}}true{{- end -}}
{{- end -}}

{{- define "neuraltrust-platform.postgresql.inClusterDeploy" -}}
{{- include "neuraltrust-platform.postgresql.deploy" . -}}
{{- end -}}

{{/*
PostgreSQL connection scalars. In hybrid every service connects to the shared
`control-plane-postgresql` Service; in external, callers overlay their own
host/port under their subchart values. These helpers always return sensible
defaults matching the in-cluster Service.
*/}}
{{- define "neuraltrust-platform.postgresql.host" -}}
control-plane-postgresql
{{- end }}

{{- define "neuraltrust-platform.postgresql.port" -}}
5432
{{- end }}

{{- define "neuraltrust-platform.postgresql.user" -}}
{{- include "neuraltrust-platform.v2.hybridPg.user" . -}}
{{- end }}

{{- define "neuraltrust-platform.postgresql.database" -}}
{{- include "neuraltrust-platform.v2.hybridPg.database" . -}}
{{- end }}

{{/*
imagePullSecrets for the umbrella-owned in-cluster PostgreSQL Deployment.
Resolves from global.postgresql.image.imagePullSecrets (list) OR
global.imagePullSecrets (list). Emits the full `imagePullSecrets:` block or nothing.
*/}}
{{- define "neuraltrust-platform.postgresql.imagePullSecrets" -}}
{{- $pg := default dict (default dict .Values.global).postgresql -}}
{{- $img := default dict $pg.image -}}
{{- $secrets := list -}}
{{- range $img.imagePullSecrets -}}
  {{- $name := "" -}}
  {{- if kindIs "map" . -}}{{- $name = .name | default "" -}}
  {{- else if kindIs "string" . -}}{{- $name = . -}}
  {{- end -}}
  {{- if and $name (ne $name "") (ne $name "none") -}}
    {{- $secrets = append $secrets $name -}}
  {{- end -}}
{{- end -}}
{{- if eq (len $secrets) 0 -}}
  {{- range (default (list) (default dict .Values.global).imagePullSecrets) -}}
    {{- $name := "" -}}
    {{- if kindIs "map" . -}}{{- $name = .name | default "" -}}
    {{- else if kindIs "string" . -}}{{- $name = . -}}
    {{- end -}}
    {{- if and $name (ne $name "") (ne $name "none") -}}
      {{- $secrets = append $secrets $name -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- if gt (len $secrets) 0 -}}
imagePullSecrets:
{{ range $secrets }}  - name: {{ . }}
{{ end -}}
{{- end -}}
{{- end -}}

{{/*
Component-level PostgreSQL config accessor kept for umbrella templates that
still read via a helper. Empty in v2 because the shared Postgres config lives
under `global.postgresql`.
*/}}
{{- define "neuraltrust-platform.postgresql.componentConfig" -}}
{{- dict | toYaml -}}
{{- end -}}

{{/*
Resolve a secret value with auto-generation support.
Priority: explicit value > existing value in cluster > generate random.
*/}}
{{- define "neuraltrust-platform.resolveSecret" -}}
{{- $value := .value }}
{{- $existingSecret := .existingSecret }}
{{- $secretKey := .secretKey }}
{{- $length := 64 }}
{{- if .length }}
  {{- $length = .length | int }}
{{- end }}
{{- if and $value (ne ($value | toString) "") }}
  {{- $value }}
{{- else if and $existingSecret (kindIs "map" $existingSecret) }}
  {{- if and (index $existingSecret "data") (hasKey (index $existingSecret "data") $secretKey) }}
    {{- index $existingSecret.data $secretKey | b64dec }}
  {{- else }}
    {{- randAlphaNum $length }}
  {{- end }}
{{- else }}
  {{- randAlphaNum $length }}
{{- end }}
{{- end }}

{{/*
Check if autoGenerateSecrets is enabled.
*/}}
{{- define "neuraltrust-platform.autoGenerateSecrets" -}}
{{- $autoGenerate := true }}
{{- if and .Values.global (hasKey .Values.global "autoGenerateSecrets") }}
  {{- $autoGenerate = .Values.global.autoGenerateSecrets }}
{{- end }}
{{- if $autoGenerate }}true{{- end }}
{{- end }}

{{/*
Effective v2 service database name, keyed on deployment mode.
  - hybrid:   all services share one DB (global.postgresql.database).
  - external: each service owns its own DB (falls back to per-service default).
Explicit value always wins.
Usage: {{ include "neuraltrust-platform.v2.dbName" (dict "ctx" . "explicit" .Values.database.name "external" "agentgateway") }}
*/}}
{{- define "neuraltrust-platform.v2.dbName" -}}
{{- if .explicit -}}
{{- .explicit -}}
{{- else if eq (include "neuraltrust-platform.isExternal" .ctx) "true" -}}
{{- .external -}}
{{- else -}}
{{- include "neuraltrust-platform.v2.hybridPg.database" .ctx -}}
{{- end -}}
{{- end }}

{{/*
Resolve the PostgreSQL host for a v2 service. Callers pass an override; empty
falls back to the in-cluster Service name (control-plane-postgresql).
*/}}
{{- define "neuraltrust-platform.postgres.host" -}}
{{- .host | default "control-plane-postgresql" }}
{{- end }}

{{/*
v2 PostgreSQL connection scalars. Callable from either umbrella or subchart
contexts (subcharts see .Values.global via umbrella merge).
*/}}
{{- define "neuraltrust-platform.v2.hybridPg.host" -}}
{{- $pg := default dict (default dict .Values.global).postgresql -}}
{{- $pg.host | default "control-plane-postgresql" -}}
{{- end }}

{{- define "neuraltrust-platform.v2.hybridPg.port" -}}
{{- $pg := default dict (default dict .Values.global).postgresql -}}
{{- $pg.port | default 5432 -}}
{{- end }}

{{- define "neuraltrust-platform.v2.hybridPg.user" -}}
{{- $pg := default dict (default dict .Values.global).postgresql -}}
{{- $pg.user | default "neuraltrust" -}}
{{- end }}

{{- define "neuraltrust-platform.v2.hybridPg.database" -}}
{{- $pg := default dict (default dict .Values.global).postgresql -}}
{{- $pg.database | default "neuraltrust" -}}
{{- end }}

{{- define "neuraltrust-platform.v2.hybridPg.sslMode" -}}
{{- $pg := default dict (default dict .Values.global).postgresql -}}
{{- $pg.sslMode | default "prefer" -}}
{{- end }}

{{/*
Resolve the Kubernetes Secret name that holds the shared v2 Postgres credential.
When `global.postgresql.existingSecret.name` is set, the chart does NOT render
its own `postgresql-secrets` — every consumer envFrom's that Secret directly.
*/}}
{{- define "neuraltrust-platform.v2.hybridPg.secretName" -}}
{{- $pg := default dict (default dict .Values.global).postgresql -}}
{{- $existing := default dict $pg.existingSecret -}}
{{- $existing.name | default "postgresql-secrets" -}}
{{- end }}

{{- define "neuraltrust-platform.v2.hybridPg.chartManagedSecret" -}}
{{- $pg := default dict (default dict .Values.global).postgresql -}}
{{- $existing := default dict $pg.existingSecret -}}
{{- if not ($existing.name | default "") -}}true{{- end -}}
{{- end }}

{{/*
Effective DB_USER for a v2 telemetry writer (AgentGateway / TrustGuard).
  - hybrid:   all writers share global.postgresql.user
  - external: the service's own value wins (falling back to the per-service default)
*/}}
{{- define "neuraltrust-platform.v2.writerUser" -}}
{{- if eq (include "neuraltrust-platform.isHybrid" .ctx) "true" -}}
{{- include "neuraltrust-platform.v2.hybridPg.user" .ctx -}}
{{- else -}}
{{- .explicit | default .default -}}
{{- end -}}
{{- end }}

{{/*
v2 Redis connection scalars.
*/}}
{{- define "neuraltrust-platform.v2.hybridRedis.host" -}}
{{- $r := default dict (default dict .Values.global).redis -}}
{{- $r.host | default "redis" -}}
{{- end }}

{{- define "neuraltrust-platform.v2.hybridRedis.port" -}}
{{- $r := default dict (default dict .Values.global).redis -}}
{{- $r.port | default 6379 -}}
{{- end }}

{{- define "neuraltrust-platform.v2.hybridRedis.username" -}}
{{- $r := default dict (default dict .Values.global).redis -}}
{{- $r.username | default "" -}}
{{- end }}

{{- define "neuraltrust-platform.v2.hybridRedis.tls" -}}
{{- $r := default dict (default dict .Values.global).redis -}}
{{- $r.tls | default "" -}}
{{- end }}

{{- define "neuraltrust-platform.v2.hybridRedis.password" -}}
{{- $r := default dict (default dict .Values.global).redis -}}
{{- $r.password | default "" -}}
{{- end }}

{{- define "neuraltrust-platform.v2.hybridRedis.secretName" -}}
{{- $r := default dict (default dict .Values.global).redis -}}
{{- $existing := default dict $r.existingSecret -}}
{{- $existing.name | default "redis-secrets" -}}
{{- end }}

{{- define "neuraltrust-platform.v2.hybridRedis.chartManagedSecret" -}}
{{- $r := default dict (default dict .Values.global).redis -}}
{{- $existing := default dict $r.existingSecret -}}
{{- if not ($existing.name | default "") -}}true{{- end -}}
{{- end }}

{{- define "neuraltrust-platform.v2.hybridRedis.emitSecret" -}}
{{- if eq (include "neuraltrust-platform.v2.hybridRedis.chartManagedSecret" .) "true" -}}true{{- end -}}
{{- end }}

{{/*
Shared TrustGuard client credential Secret name.
*/}}
{{- define "neuraltrust-platform.trustguardClientSecretName" -}}
{{- $ctx := .ctx -}}
{{- $global := default dict $ctx.Values.global -}}
{{- $v2 := default dict $global.v2 -}}
{{- $explicit := $v2.trustguardClientSecretName | default "" -}}
{{- if $explicit -}}
{{- $explicit -}}
{{- else -}}
trustguard-client-credentials
{{- end -}}
{{- end }}

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
ClickHouse is allowed to render only in v2 external.
*/}}
{{- define "neuraltrust-platform.clickhouseAllowed" -}}
{{- if eq (include "neuraltrust-platform.isExternal" .) "true" -}}true{{- end -}}
{{- end }}

{{/*
DataAgent enablement gate. Requires:
  - hybrid mode
  - non-empty tenantId
  - enrolment token (inline, existingSecret, or previously generated)
  - database credentials (chart-generated or existingSecret)
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
  (eq (include "neuraltrust-platform.isHybrid" .) "true")
  $tenantId
  $tokenReady
  (or $chartGeneratesDatabase $dataSecretName $hasManagedDatabase)
-}}true{{- end -}}
{{- end }}

{{/*
data-plane-api SQL backend and enablement helpers. In v2 the shim is always
enabled when its own dataPlane.enabled + api.enabled are true and the SQL
backend is resolvable. Postgres backend is default in hybrid; ClickHouse
backend requires an external (dotted) ClickHouse host.
*/}}
{{- define "neuraltrust-platform.dataPlane.components" -}}
{{- $root := include "neuraltrust-platform.dataPlaneValues" . | fromYaml }}
{{- $rootComp := default dict (default dict $root.dataPlane).components }}
{{- $subComp := default dict (default dict .Values.dataPlane).components }}
{{- $comp := $rootComp }}
{{- if not $comp }}{{- $comp = $subComp }}{{- end }}
{{- default dict $comp | toYaml }}
{{- end }}

{{- define "neuraltrust-platform.dataPlaneApi.sqlBackend" -}}
{{- $comp := include "neuraltrust-platform.dataPlane.components" . | fromYaml }}
{{- $api := default dict $comp.api }}
{{- $db := default dict $api.database }}
{{- $backend := $db.backend | default "" | toString | lower }}
{{- $ch := default dict $comp.clickhouse }}
{{- $chHost := $ch.host | default "clickhouse" }}
{{- $chDotted := contains "." $chHost }}
{{- $isHybrid := eq (include "neuraltrust-platform.isHybrid" .) "true" }}
{{- if or (eq $backend "postgres") (eq $backend "postgresql") -}}
postgres
{{- else if eq $backend "clickhouse" -}}
clickhouse
{{- else if $isHybrid -}}
{{- if $chDotted -}}clickhouse{{- else -}}postgres{{- end -}}
{{- else -}}
clickhouse
{{- end -}}
{{- end }}

{{- define "neuraltrust-platform.dataPlaneApiV2.enabled" -}}
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

{{/*
data-plane-api evaluation-progress cache config accessor.
*/}}
{{- define "neuraltrust-platform.dataPlaneApi.redisConfig" -}}
{{- $root := include "neuraltrust-platform.dataPlaneValues" . | fromYaml }}
{{- $rootApi := default dict (default dict (default dict $root.dataPlane).components).api }}
{{- $sub := default dict .Values.dataPlane }}
{{- $subApi := default dict (default dict $sub.components).api }}
{{- $cfg := $rootApi.redis }}
{{- if not $cfg }}{{- $cfg = $subApi.redis }}{{- end }}
{{- default dict $cfg | toYaml }}
{{- end }}

{{- define "neuraltrust-platform.dataPlaneApi.redisBackend" -}}
{{- $cfg := include "neuraltrust-platform.dataPlaneApi.redisConfig" . | fromYaml }}
{{- if $cfg.backend -}}
{{- if not (eq ($cfg.backend | toString) "redis") -}}
{{- fail "data-plane-api.dataPlane.components.api.redis.backend must be \"redis\"" -}}
{{- end -}}
{{- $cfg.backend -}}
{{- else -}}
redis
{{- end -}}
{{- end -}}

{{- define "neuraltrust-platform.dataPlaneApi.redisUrl" -}}
{{- if eq (include "neuraltrust-platform.dataPlaneApi.redisBackend" .) "redis" }}
{{- $cfg := include "neuraltrust-platform.dataPlaneApi.redisConfig" . | fromYaml }}
{{- $global := default dict .Values.global }}
{{- $globalRedis := default dict $global.redis }}
{{- $host := $cfg.host | default $globalRedis.host | default "redis" }}
{{- $port := $cfg.port | default $globalRedis.port | default 6379 }}
{{- $db := $cfg.db | default "0" }}
{{- $tls := $cfg.tls | default $globalRedis.tls | default "" }}
{{- $iamAuth := $cfg.iamAuth | default false }}
{{- $scheme := "redis" }}
{{- if or $iamAuth (eq ($tls | toString) "true") }}{{- $scheme = "rediss" }}{{- end }}
{{- $authority := "" }}
{{- if not $iamAuth }}
  {{- $user := $cfg.username | default $globalRedis.username | default "" }}
  {{- $pw := $cfg.password | default $globalRedis.password | default "" }}
  {{- if $user }}
    {{- $authority = printf "%s:%s@" ($user | urlquery) ($pw | urlquery) }}
  {{- else if $pw }}
    {{- $authority = printf ":%s@" ($pw | urlquery) }}
  {{- end }}
{{- end }}
{{- printf "%s://%s%s:%v/%s" $scheme $authority $host $port $db -}}
{{- end }}
{{- end -}}

{{- define "neuraltrust-platform.dataPlaneApi.postgresConfig" -}}
{{- $comp := include "neuraltrust-platform.dataPlane.components" . | fromYaml }}
{{- $api := default dict $comp.api }}
{{- $db := default dict $api.database }}
{{- default dict $db.postgresql | toYaml }}
{{- end }}

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
*/}}
{{- define "neuraltrust-platform.domain" -}}
{{- $global := default dict .Values.global }}
{{- $global.domain | default "" }}
{{- end }}

{{/*
Ingress helpers.
*/}}
{{- define "neuraltrust-platform.ingress.host" -}}
{{- $explicit := .host | default "" }}
{{- if $explicit }}
{{- $explicit }}
{{- else }}
  {{- $global := default dict .global }}
  {{- $domain := $global.domain | default "" }}
  {{- $prefix := .prefix | default "" }}
  {{- if and $domain $prefix }}
{{- printf "%s.%s" $prefix $domain }}
  {{- end }}
{{- end }}
{{- end }}

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
{{- end }}

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
{{- if eq $provider "openshift" }}
  {{- $_ := set $merged "route.openshift.io/termination" "edge" }}
  {{- $_ := set $merged "route.openshift.io/insecure-edge-termination-policy" "Redirect" }}
{{- end }}
{{- range $k, $v := (default dict $globalIngress.annotations) }}
  {{- $_ := set $merged $k ($v | toString) }}
{{- end }}
{{- range $k, $v := (default dict .local) }}
  {{- $_ := set $merged $k ($v | toString) }}
{{- end }}
{{- if $merged }}
{{- toYaml $merged }}
{{- end }}
{{- end }}

{{- define "neuraltrust-platform.ingress.defaultTLSSecretName" -}}
{{- $globalIngress := default dict (default dict .global).ingress }}
{{- $tls := default dict $globalIngress.tls }}
{{- if $tls.secretName }}
{{- $tls.secretName -}}
{{- else -}}
neuraltrust-ingress-tls
{{- end }}
{{- end }}

{{- define "neuraltrust-platform.ingress.autoGenerateTLSSecret" -}}
{{- $globalIngress := default dict (default dict .global).ingress }}
{{- $tls := default dict $globalIngress.tls }}
{{- $enabled := true }}
{{- if hasKey $tls "autoGenerate" }}
  {{- $enabled = $tls.autoGenerate }}
{{- end }}
{{- if $enabled }}true{{- end }}
{{- end }}

{{- define "neuraltrust-platform.ingress.effectiveTLSSecretName" -}}
{{- $localSecretName := .localSecretName | default "" }}
{{- if $localSecretName }}
{{- $localSecretName -}}
{{- else -}}
{{- include "neuraltrust-platform.ingress.defaultTLSSecretName" (dict "global" .global) -}}
{{- end }}
{{- end }}

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
HTTP proxy environment variables.
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
Config-sync data-plane environment (hybrid: dial the fixed public SaaS endpoint
over TLS; external: dial the in-cluster control-plane Service). Rendered only
when configSync.enabled at the caller.
Usage: {{- include "neuraltrust-platform.configSyncEnv" (dict "ctx" . "product" "trustguard") | nindent 8 }}
*/}}
{{- define "neuraltrust-platform.configSyncEnv" -}}
{{- $ctx := .ctx -}}
{{- $product := .product -}}
{{- $tlsCaPath := .tlsCaPath | default "" -}}
{{- $cs := default dict $ctx.Values.configSync -}}
{{- if $cs.enabled -}}
{{- $isFull := eq (include "neuraltrust-platform.isExternal" $ctx) "true" -}}
{{- $endpoint := $cs.endpoint -}}
{{- $insecure := false -}}
{{- $caPath := "" -}}
{{- if $isFull -}}
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
Config-sync credentials from a dedicated operator-owned Secret. Explicit env
wins over the chart-managed service Secret loaded through envFrom.
*/}}
{{- define "neuraltrust-platform.configSyncTokenEnv" -}}
{{- $cs := default dict .Values.configSync -}}
{{- $existing := default dict $cs.existingSecret -}}
{{- if and $cs.enabled $existing.name }}
- name: CONFIG_SYNC_TOKEN
  valueFrom:
    secretKeyRef:
      name: {{ $existing.name | quote }}
      key: {{ $existing.tokenKey | default "CONFIG_SYNC_TOKEN" | quote }}
- name: CONFIG_SYNC_LKG_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $existing.name | quote }}
      key: {{ $existing.lkgKey | default "CONFIG_SYNC_LKG_KEY" | quote }}
{{- end }}
{{- end }}

{{/*
Config-sync shared token / LKG cache key.
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
ClickStack defaults + OTLP env helpers.
*/}}
{{- define "neuraltrust-platform.clickstack.defaultEndpoint" -}}
https://clickstack-collector.neuraltrust.ai/v1/logs
{{- end }}
{{- define "neuraltrust-platform.clickstack.defaultProtocol" -}}
http/protobuf
{{- end }}

{{- define "neuraltrust-platform.clickstackHybridEnabled" -}}
{{- $global := default dict .Values.global -}}
{{- $cfg := default dict $global.clickstack -}}
{{- $enabled := true -}}
{{- if hasKey $cfg "enabled" -}}{{- $enabled = $cfg.enabled -}}{{- end -}}
{{- if and (eq (include "neuraltrust-platform.isHybrid" .) "true") $enabled -}}
true
{{- end -}}
{{- end }}

{{/*
Enrolment credential is resolvable for DataAgent and/or OTLP egress exchange.

Works from the umbrella (`.Values.dataagent`) and the dataagent subchart
(`.Values` is the dataagent block). AgentGateway/TrustGuard use
clickstackEgress.useLocalEndpoint (global-only) for the OTLP endpoint switch.
*/}}
{{- define "neuraltrust-platform.clickstack.enrolmentReady" -}}
{{- $cfg := .Values -}}
{{- if hasKey .Values "dataagent" -}}{{- $cfg = default dict .Values.dataagent -}}{{- end -}}
{{- $token := $cfg.enrolmentToken | default "" -}}
{{- $existing := default dict $cfg.enrolmentTokenExistingSecret -}}
{{- $existingName := $existing.name | default "" -}}
{{- $managedSecret := lookup "v1" "Secret" .Release.Namespace "dataagent-secrets" -}}
{{- $managedData := dict -}}
{{- if and $managedSecret (kindIs "map" $managedSecret) $managedSecret.data -}}
  {{- $managedData = $managedSecret.data -}}
{{- end -}}
{{- $hasManagedToken := and (hasKey $managedData "ENROLMENT_TOKEN") (ne (index $managedData "ENROLMENT_TOKEN") "") -}}
{{- $preserve := dig "preserveExistingSecrets" false (.Values.global | default dict) -}}
{{- $chartGenerates := and (eq (include "neuraltrust-platform.autoGenerateSecrets" .) "true") (not $preserve) -}}
{{- if or $existingName $hasManagedToken (and $token $chartGenerates) -}}true{{- end -}}
{{- end }}

{{/*
Hybrid OTLP egress is on by default (v2 hybrid has no direct SaaS ClickStack
token path). Set global.clickstack.egress.enabled=false only together with
global.clickstack.enabled=false, or validation fails.
Missing key ⇒ true.
*/}}
{{- define "neuraltrust-platform.clickstackEgress.optIn" -}}
{{- $cfg := default dict (default dict (default dict .Values.global).clickstack).egress -}}
{{- $enabled := true -}}
{{- if hasKey $cfg "enabled" -}}{{- $enabled = $cfg.enabled -}}{{- end -}}
{{- if $enabled -}}true{{- end -}}
{{- end }}

{{/*
True when hybrid should co-locate the OTLP egress sidecar on DataAgent.

Requires a fully enabled DataAgent (tenantId + enrolment + DB) because the
collector is a sidecar, not a standalone Deployment. EXTERNAL / air-gapped
installs never enable this: they keep the in-cluster clickstack-otel-collector
→ ClickHouse path with no internet hop.
*/}}
{{- define "neuraltrust-platform.clickstackEgress.enabled" -}}
{{- if and
  (eq (include "neuraltrust-platform.clickstackHybridEnabled" .) "true")
  (eq (include "neuraltrust-platform.clickstackEgress.optIn" .) "true")
  (eq (include "neuraltrust-platform.dataagentEnabled" .) "true")
-}}true{{- end -}}
{{- end }}

{{/*
True when AgentGateway/TrustGuard should send plain OTLP to the local egress
ClusterIP (DataAgent sidecar). Hybrid ClickStack has no direct SaaS Authorization
path — apps always talk to the local egress Service when product dual-write is on.
*/}}
{{- define "neuraltrust-platform.clickstackEgress.useLocalEndpoint" -}}
{{- if and
  (eq (include "neuraltrust-platform.clickstackHybridEnabled" .) "true")
  (eq (include "neuraltrust-platform.clickstackEgress.optIn" .) "true")
-}}true{{- end -}}
{{- end }}

{{- define "neuraltrust-platform.clickstackEgress.fullname" -}}
{{- $cfg := default dict (default dict (default dict .Values.global).clickstack).egress -}}
{{- default "clickstack-egress-collector" $cfg.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{- define "neuraltrust-platform.clickstackEgress.endpointHost" -}}
{{- printf "%s.%s.svc.cluster.local" (include "neuraltrust-platform.clickstackEgress.fullname" .) .Release.Namespace -}}
{{- end }}

{{- define "neuraltrust-platform.clickstackEgress.otlpHTTPEndpoint" -}}
{{- printf "http://%s:4318/v1/logs" (include "neuraltrust-platform.clickstackEgress.endpointHost" .) -}}
{{- end }}

{{/*
Loopback OAuth broker on the DataAgent container. Not overridable — trust is
pod-local; public DataCore token URLs are intentionally unsupported.
*/}}
{{- define "neuraltrust-platform.clickstackEgress.tokenURL" -}}
http://127.0.0.1:9465/oauth/token
{{- end }}

{{- define "neuraltrust-platform.clickstackEgress.clientId" -}}
{{- $cfg := default dict (default dict (default dict .Values.global).clickstack).egress -}}
{{- default "otlp-egress" $cfg.clientId -}}
{{- end }}

{{/*
Non-secret placeholder for oauth2client (required by the extension). Real auth
is the DataAgent loopback broker + enrolment on the DataAgent gRPC connection.
*/}}
{{- define "neuraltrust-platform.clickstackEgress.clientSecret" -}}
{{- $cfg := default dict (default dict (default dict .Values.global).clickstack).egress -}}
{{- default "unused" $cfg.clientSecret -}}
{{- end }}

{{/*
SaaS OTLP/HTTP base URL for the egress collector exporter (no /v1/logs suffix).
Defaults to the public ingest host; override via global.clickstack.egress.endpoint
or the legacy global.clickstack.endpoint (strip path if present).
*/}}
{{- define "neuraltrust-platform.clickstackEgress.saasEndpoint" -}}
{{- $clickstack := default dict (default dict .Values.global).clickstack -}}
{{- $cfg := default dict $clickstack.egress -}}
{{- $raw := $cfg.endpoint | default ($clickstack.endpoint | default "https://clickstack-collector.neuraltrust.ai") -}}
{{- trimSuffix "/v1/logs" (trimSuffix "/" $raw) -}}
{{- end }}

{{- define "neuraltrust-platform.clickstackEgress.image" -}}
{{- $cfg := default dict (default dict (default dict .Values.global).clickstack).egress -}}
{{- $img := default dict $cfg.image -}}
{{- $repo := $img.repository | default "europe-west1-docker.pkg.dev/neuraltrust-app-prod/nt-docker/opentelemetry-collector-contrib" -}}
{{- $tag := $img.tag | default "0.156.0" -}}
{{- printf "%s:%s" $repo $tag -}}
{{- end }}

{{- define "neuraltrust-platform.clickstack.otlpEnv" -}}
{{- /* Hybrid: plain OTLP to local egress (enrolment exchange owns SaaS auth). */ -}}
OTEL_EXPORTER_OTLP_ENDPOINT: {{ include "neuraltrust-platform.clickstackEgress.otlpHTTPEndpoint" . | quote }}
OTEL_EXPORTER_OTLP_PROTOCOL: {{ include "neuraltrust-platform.clickstack.defaultProtocol" . | quote }}
OTEL_EXPORTER_OTLP_INSECURE: "true"
{{- end }}

{{/*
External-mode OTLP auth: mount the shared header from clickstack-collector-secrets
(same token the collector enforces on :4318). Stable name matches fullnameOverride.
*/}}
{{- define "neuraltrust-platform.clickstack.externalCollectorSecretName" -}}
clickstack-collector-secrets
{{- end }}

{{- define "neuraltrust-platform.clickstack.externalOtlpHeadersEnv" -}}
- name: OTEL_EXPORTER_OTLP_HEADERS
  valueFrom:
    secretKeyRef:
      name: {{ include "neuraltrust-platform.clickstack.externalCollectorSecretName" . | quote }}
      key: OTEL_EXPORTER_OTLP_HEADERS
{{- end }}

{{/*
Custom corporate CA certificate trust helpers.
*/}}
{{- define "neuraltrust-platform.customCaCert.enabled" -}}
{{- $ca := (default dict (default dict .Values.global).customCaCert) -}}
{{- if and $ca.enabled $ca.secretName -}}true{{- end -}}
{{- end }}

{{- define "neuraltrust-platform.customCaCert.path" -}}
{{- $ca := (default dict (default dict .Values.global).customCaCert) -}}
{{- $ca.mountPath | default "/etc/ssl/certs/custom-ca.crt" -}}
{{- end }}

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

{{- define "neuraltrust-platform.customCaCert.volumeMount" -}}
{{- $ca := (default dict (default dict .Values.global).customCaCert) -}}
{{- if and $ca.enabled $ca.secretName }}
- name: custom-ca-cert
  mountPath: {{ include "neuraltrust-platform.customCaCert.path" . | quote }}
  subPath: ca.crt
  readOnly: true
{{- end }}
{{- end }}

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
AWS IRSA helpers.
*/}}
{{- define "neuraltrust-platform.irsa.annotations" -}}
{{- $irsa := (default dict (default dict .Values.global).irsa) -}}
{{- if and $irsa.roleArn $irsa.applyGlobally }}
eks.amazonaws.com/role-arn: {{ $irsa.roleArn | quote }}
{{- end }}
{{- end }}

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
Watchdog enable gate at the umbrella level.
*/}}
{{- define "neuraltrust-platform.watchdogEnabled" -}}
{{- $wd := default dict .Values.watchdog -}}
{{- if $wd.enabled -}}true{{- end -}}
{{- end }}

{{/*
Global scheduling helpers.
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

{{- define "neuraltrust-platform.tolerations" -}}
{{- $global := (default (list) (default dict .ctx.Values.global).tolerations) -}}
{{- $local := default (list) .local -}}
{{- $merged := concat $global $local -}}
{{- with $merged }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{- define "neuraltrust-platform.nodeSelectorMap" -}}
{{- $global := (default dict (default dict .ctx.Values.global).nodeSelector) -}}
{{- $local := default dict .local -}}
{{- merge (deepCopy $local) $global | toYaml -}}
{{- end -}}

{{- define "neuraltrust-platform.extraVolumes" -}}
{{- with .items }}
{{- toYaml . }}
{{- end }}
{{- end }}

{{- define "neuraltrust-platform.extraVolumeMounts" -}}
{{- with .items }}
{{- toYaml . }}
{{- end }}
{{- end }}

{{- define "neuraltrust-platform.appVersionEnv" -}}
{{- $tag := .tag | toString -}}
{{- if and $tag (ne $tag "") -}}
- name: APPLICATION_VERSION
  value: {{ $tag | quote }}
{{- end -}}
{{- end }}

{{/*
Monitoring CRDs (opt-in + capability gated).
*/}}
{{- define "neuraltrust-platform.monitoring.enabled" -}}
{{- $g := default dict .Values.global -}}
{{- $m := default dict $g.monitoring -}}
{{- if and $m.enabled (.Capabilities.APIVersions.Has "monitoring.coreos.com/v1") -}}
true
{{- end -}}
{{- end -}}

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
Health probes block (opt-in-out).
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
PodDisruptionBudget spec block.
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
Config-map/Secret checksum annotations for Deployment restart-on-change.
*/}}
{{- define "neuraltrust-platform.checksumAnnotations" -}}
{{- $ctx := .context -}}
{{- range .files -}}
checksum/{{ . | base | replace ".yaml" "" }}: {{ include (print $ctx.Template.BasePath .) $ctx | sha256sum }}
{{ end -}}
{{- end -}}
