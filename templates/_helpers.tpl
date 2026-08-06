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
deploymentMode: hybrid (default) → data planes + DataAgent; hosted control planes.
external → control + data + in-cluster analytics; no DataAgent.
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
Gate for the bootstrap Job that creates the platform's roles and databases on the
chart's own PostgreSQL (see templates/postgresql/bootstrap-job.yaml).

Requires all of:
  - `deploy` is on, so the chart is running the instance itself
  - `host` is empty, so nobody has pointed the platform at another instance. With
    a host set the Job would have a managed endpoint within reach, and creating
    roles on a customer's instance is not ours to do
  - password auth. IAM means a managed instance mints tokens instead
  - `bootstrapJob.enabled` has not been turned off
*/}}
{{- define "neuraltrust-platform.postgresql.bootstrapJob.enabled" -}}
{{- $pg := default dict (default dict .Values.global).postgresql -}}
{{- $job := default dict $pg.bootstrapJob -}}
{{- $on := true -}}
{{- if hasKey $job "enabled" -}}{{- $on = $job.enabled -}}{{- end -}}
{{- $host := "" -}}
{{- if $pg.host -}}{{- $host = $pg.host | toString -}}{{- end -}}
{{- if and $on (include "neuraltrust-platform.postgresql.deploy" .) (eq $host "") (ne ($pg.authMode | default "password" | toString) "iam") -}}true{{- end -}}
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
Priority: global.postgresql.image.imagePullSecrets → global.imagePullSecrets →
chart default `gcr-secret`. Set either list to ["none"] to suppress (IAM /
Workload Identity clusters that pull without a pull secret).
*/}}
{{- define "neuraltrust-platform.postgresql.imagePullSecrets" -}}
{{- $pg := default dict (default dict .Values.global).postgresql -}}
{{- $img := default dict $pg.image -}}
{{- $global := default dict .Values.global -}}
{{- $secrets := list -}}
{{- $suppress := false -}}
{{- range (default (list) $img.imagePullSecrets) -}}
  {{- $name := "" -}}
  {{- if kindIs "map" . -}}{{- $name = .name | default "" -}}
  {{- else if kindIs "string" . -}}{{- $name = . -}}
  {{- end -}}
  {{- if eq $name "none" -}}{{- $suppress = true -}}
  {{- else if and $name (ne $name "") -}}
    {{- $secrets = append $secrets $name -}}
  {{- end -}}
{{- end -}}
{{- if and (eq (len $secrets) 0) (not $suppress) -}}
  {{- range (default (list) $global.imagePullSecrets) -}}
    {{- $name := "" -}}
    {{- if kindIs "map" . -}}{{- $name = .name | default "" -}}
    {{- else if kindIs "string" . -}}{{- $name = . -}}
    {{- end -}}
    {{- if eq $name "none" -}}{{- $suppress = true -}}
    {{- else if and $name (ne $name "") -}}
      {{- $secrets = append $secrets $name -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- if and (eq (len $secrets) 0) (not $suppress) -}}
  {{- $secrets = append $secrets "gcr-secret" -}}
{{- end -}}
{{- if gt (len $secrets) 0 -}}
imagePullSecrets:
{{ range $secrets }}  - name: {{ . }}
{{ end -}}
{{- end -}}
{{- end -}}

{{/*
imagePullSecrets for control-plane-app / control-plane-api (and the MCP
signing-key Job that must pull the same image).

Precedence (most specific first):
  1. <subchart>.controlPlane.imagePullSecrets  (string; hasKey so ""/"none" suppress)
  2. <subchart>.imagePullSecrets               (string; unset/empty falls through)
  3. global.imagePullSecrets                   (list of names or {name}; ["none"] suppresses)
  4. chart default `gcr-secret`

Call with a dict so the umbrella Job can resolve against control-plane-app
values while subchart Deployments pass their own .Values root:

  {{- include "neuraltrust-platform.controlPlane.imagePullSecrets" (dict "root" .Values "global" .Values.global) | nindent 6 }}
*/}}
{{- define "neuraltrust-platform.controlPlane.imagePullSecrets" -}}
{{- $root := default dict .root -}}
{{- $global := default dict .global -}}
{{- $cp := default dict $root.controlPlane -}}
{{- $secrets := list -}}
{{- $suppress := false -}}
{{- $chosen := false -}}
{{- if hasKey $cp "imagePullSecrets" -}}
  {{- $chosen = true -}}
  {{- $v := $cp.imagePullSecrets -}}
  {{- if or (not $v) (eq ($v | toString) "") (eq ($v | toString) "none") -}}
    {{- $suppress = true -}}
  {{- else if kindIs "string" $v -}}
    {{- $secrets = append $secrets $v -}}
  {{- end -}}
{{- end -}}
{{- if not $chosen -}}
  {{- $v := $root.imagePullSecrets | default "" -}}
  {{- if $v -}}
    {{- $chosen = true -}}
    {{- if eq ($v | toString) "none" -}}
      {{- $suppress = true -}}
    {{- else if kindIs "string" $v -}}
      {{- $secrets = append $secrets $v -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- if and (not $chosen) (not $suppress) -}}
  {{- range (default (list) $global.imagePullSecrets) -}}
    {{- $name := "" -}}
    {{- if kindIs "map" . -}}{{- $name = .name | default "" -}}
    {{- else if kindIs "string" . -}}{{- $name = . -}}
    {{- end -}}
    {{- if eq $name "none" -}}
      {{- $suppress = true -}}
      {{- $secrets = list -}}
    {{- else if and $name (ne $name "") -}}
      {{- $secrets = append $secrets $name -}}
    {{- end -}}
  {{- end -}}
  {{- if or $suppress (gt (len $secrets) 0) -}}
    {{- $chosen = true -}}
  {{- end -}}
{{- end -}}
{{- if and (not $suppress) (eq (len $secrets) 0) -}}
  {{- $secrets = append $secrets "gcr-secret" -}}
{{- end -}}
{{- if gt (len $secrets) 0 -}}
imagePullSecrets:
{{- range $secrets }}
  - name: {{ . }}
{{- end -}}
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
Resolve one datastore connection scalar for a v2 service, in precedence order:
  1. the per-service override (`<service>.database.*` / `<service>.redis.*`)
  2. the matching `global.postgresql.*` / `global.redis.*` entry
  3. the chart default

Step 2 is what lets a managed Aurora/ElastiCache endpoint be declared once on
the global block instead of repeated in every per-service block.

Inheritance is deliberately NOT gated on `global.<block>.deploy`. The shared
`postgresql-secrets` / `redis-secrets` that the control plane and data-plane-api
consume already honour an explicit global host whatever `deploy` says (see
`neuraltrust-platform.v2.hybridPg.host` and
`neuraltrust-platform.dataPlaneApi.redisUrl`), so gating it here would let half
the platform dial the managed endpoint while the runtimes dialled the in-cluster
Service. `deploy` decides whether the chart also runs a datastore of its own;
it does not decide who is allowed to read the endpoint.

An empty per-service value inherits, and Helm renders a boolean `false` as an
empty string here, so `--set <service>.redis.tls=false` does NOT opt out of an
inherited `global.redis.tls: true` — it inherits. Use the quoted string instead,
`--set-string <service>.redis.tls=false` or `tls: "false"` in a values file,
which is non-empty and therefore wins. Same for `username`, where `""` cannot
mean "AUTH as the default user" while a global ACL username is set. This matches
how `dataPlaneApi.redisUrl` has always resolved `tls`/`username`.

Only these keys inherit: `host`, `port` and `sslMode` under `<service>.database`,
and `host`, `port`, `username`, `tls` and `password` under `<service>.redis`.
Neighbours such as `tlsInsecureVerify`, `db`, `iamAuth`, `awsRegion`, `cacheName`
and `awsServerless` have no `global.*` counterpart and stay per-service; setting
them on a global block does nothing.

`ctx` is optional; without it only the per-service value and the default apply.

Usage: {{ include "neuraltrust-platform.datastore.scalar" (dict "ctx" . "block" "postgresql" "key" "host" "value" .Values.database.host "default" "control-plane-postgresql") }}
*/}}
{{- define "neuraltrust-platform.datastore.scalar" -}}
{{- $global := default dict (default dict (default dict .ctx).Values).global -}}
{{- $block := default dict (index $global .block) -}}
{{- $inherited := "" -}}
{{- if hasKey $block .key -}}
{{- $inherited = index $block .key -}}
{{- end -}}
{{- .value | default $inherited | default (.default | default "") -}}
{{- end }}

{{/*
PostgreSQL connection scalars for a v2 service.
Usage: {{ include "neuraltrust-platform.postgres.host" (dict "ctx" . "host" .Values.database.host) }}
*/}}
{{- define "neuraltrust-platform.postgres.host" -}}
{{- include "neuraltrust-platform.datastore.scalar" (dict "ctx" .ctx "block" "postgresql" "key" "host" "value" .host "default" "control-plane-postgresql") -}}
{{- end }}

{{- define "neuraltrust-platform.postgres.port" -}}
{{- include "neuraltrust-platform.datastore.scalar" (dict "ctx" .ctx "block" "postgresql" "key" "port" "value" .port "default" 5432) -}}
{{- end }}

{{- define "neuraltrust-platform.postgres.sslMode" -}}
{{- include "neuraltrust-platform.datastore.scalar" (dict "ctx" .ctx "block" "postgresql" "key" "sslMode" "value" .sslMode "default" "prefer") -}}
{{- end }}

{{/*
Redis connection scalars for a v2 service. `username` and `tls` have no default:
callers emit the env var only when the resolved value is non-empty.
*/}}
{{- define "neuraltrust-platform.redis.host" -}}
{{- include "neuraltrust-platform.datastore.scalar" (dict "ctx" .ctx "block" "redis" "key" "host" "value" .host "default" "redis") -}}
{{- end }}

{{- define "neuraltrust-platform.redis.port" -}}
{{- include "neuraltrust-platform.datastore.scalar" (dict "ctx" .ctx "block" "redis" "key" "port" "value" .port "default" 6379) -}}
{{- end }}

{{- define "neuraltrust-platform.redis.username" -}}
{{- include "neuraltrust-platform.datastore.scalar" (dict "ctx" .ctx "block" "redis" "key" "username" "value" .username) -}}
{{- end }}

{{- define "neuraltrust-platform.redis.tls" -}}
{{- include "neuraltrust-platform.datastore.scalar" (dict "ctx" .ctx "block" "redis" "key" "tls" "value" .tls) -}}
{{- end }}

{{/*
Operator-supplied datastore credentials (AUT-411).

A service's password normally lands in the Secret the chart renders for it, which
means it has to be written into the values file first. Naming a pre-created
Secret under `<datastore>.existingSecret` instead keeps the credential out of
values and out of Helm release history: the key is omitted from the rendered
Secret (see `datastore.credentialIsExternal`) and the container reads it straight
from the operator's Secret through the env entry below.

An explicit `env` entry outranks the same name arriving via `envFrom`, but we do
not rely on that — the key is absent from the chart Secret whenever this fires,
so there is only ever one source.

  ctx      the subchart context
  ref      the `existingSecret` map (name, key)
  envName  the variable the runtime reads
  default  key to read when `ref.key` is unset, normally envName
*/}}
{{- define "neuraltrust-platform.datastore.credentialEnv" -}}
{{- $ref := default dict .ref -}}
{{- if $ref.name -}}
- name: {{ .envName }}
  valueFrom:
    secretKeyRef:
      name: {{ $ref.name | quote }}
      key: {{ $ref.key | default (.default | default .envName) | quote }}
{{- end -}}
{{- end }}

{{/*
True when a pre-created Secret owns the credential, so the chart must not write
that key itself. Kept separate from the env helper so Secret templates can ask
the question without emitting anything.
*/}}
{{- define "neuraltrust-platform.datastore.credentialIsExternal" -}}
{{- $ref := default dict .ref -}}
{{- if $ref.name -}}true{{- end -}}
{{- end }}

{{/*
The same hook for the control-plane PostgreSQL role (AUT-413).

It needed its own pair of helpers because that password is not just a key in a
Secret: the chart used to bake it into `POSTGRES_PRISMA_URL` and
`SENSIBLE_PG_DSN` while rendering, which is why it was the last credential that
had to sit in a values file. Nothing composes a DSN from this password any more
— the app, the telemetry exporters (RUN-1086) and DataAgent (RUN-1093) all build
connections from the discrete POSTGRES_* / DB_* parts — so the password can
arrive as a reference in both external and hybrid.

Requires TrustGate / TrustGuard / DataAgent images that fall back to discrete
parts when no DSN is configured. Older images still expect SENSIBLE_PG_DSN.

Callable from the umbrella or from a subchart, since `global` is merged into
both. Takes the whole `.Values.global.postgresql.passwordSecret` map.
*/}}
{{- define "neuraltrust-platform.postgresql.passwordSecretRef" -}}
{{- default dict (default dict (default dict .Values.global).postgresql).passwordSecret | toYaml -}}
{{- end }}

{{/*
Whether the control-plane password comes from an operator Secret.

IAM auth answers false however the hook is set: there is no static password to
redirect, and every doc says the credential hooks are ignored under IAM. Keeping
that here rather than in each call site means one answer for the env entries, the
omitted Secret keys and the validation.
*/}}
{{- define "neuraltrust-platform.postgresql.passwordIsExternal" -}}
{{- $ref := (include "neuraltrust-platform.postgresql.passwordSecretRef" . | fromYaml) -}}
{{- $pg := default dict (default dict .Values.global).postgresql -}}
{{- if and $ref.name (ne ($pg.authMode | default "password") "iam") -}}true{{- end -}}
{{- end }}

{{/*
The POSTGRES_PASSWORD env entry, pointing at the operator's Secret when the hook
is set and at the chart's own otherwise.

Strictness follows ownership rather than the call site. A reference into the
chart's own Secret stays optional, so a pre-provisioned Secret without the key
leaves the service to fail its own config validation instead of leaving the pod
unable to start. A reference the operator wrote by hand is hard: a typo in
`passwordSecret.key` should stop the pod with CreateContainerConfigError, not
quietly build a password-less connection and surface as an authentication
failure with nothing pointing at the cause.

  ctx       the subchart context
  secret    Secret holding the chart's own copy, when the hook is unset
  optional  pass false to force a hard reference to the chart's own Secret too
*/}}
{{- define "neuraltrust-platform.postgresql.passwordEnv" -}}
{{- $isExternal := eq (include "neuraltrust-platform.postgresql.passwordIsExternal" .ctx) "true" -}}
{{- $ref := (include "neuraltrust-platform.postgresql.passwordSecretRef" .ctx | fromYaml) -}}
{{- $name := .secret -}}
{{- $key := "POSTGRES_PASSWORD" -}}
{{- if $isExternal -}}
{{- $name = $ref.name -}}
{{- $key = $ref.key | default "POSTGRES_PASSWORD" -}}
{{- end -}}
{{- /* envName lets hybrid gateways inject the same credential as DB_PASSWORD
       (what TrustGate/TrustGuard read) while control-plane consumers keep
       POSTGRES_PASSWORD. The Secret key is always the Postgres family name
       unless passwordSecret redirects it. */}}
- name: {{ .envName | default "POSTGRES_PASSWORD" }}
  valueFrom:
    secretKeyRef:
      name: {{ $name | quote }}
      key: {{ $key | quote }}
      {{- if and (not $isExternal) (ne (.optional | toString) "false") }}
      optional: true
      {{- end }}
{{- end }}

{{/*
The one Redis credential, resolved the same way as the endpoint. External mode
has three consumers of it — the two gateway Secrets and the DSN composed into
`data-plane-jwt-secret` — and they used to need the password written out once
each. Postgres deliberately has no equivalent: external gives every service its
own role, so a single inherited password would be wrong more often than right.

Note the chart's own Redis has no `--requirepass`, so `global.redis.password`
belongs to a managed cache only. `validate-values.yaml` rejects the unambiguous
mistake (a password set while we deploy Redis ourselves and no host is named)
rather than letting all three consumers fail to authenticate at runtime.
*/}}
{{- define "neuraltrust-platform.redis.password" -}}
{{- include "neuraltrust-platform.datastore.scalar" (dict "ctx" .ctx "block" "redis" "key" "password" "value" .password) -}}
{{- end }}

{{/*
Firewall REDIS_URL composed from the shared Redis helpers (AUT-386).

The firewall Python client reads only REDIS_URL and otherwise falls back to
redis://localhost:6379/0, which is never reachable in-cluster. Emit a URL only
when a host resolves so that fallback is never shipped silently.

ElastiCache IAM is unsupported: the client has no SigV4 / REDIS_LOGIN path, so
an IAM-only cache needs a static password (or an in-cluster Redis) instead.
*/}}
{{- define "neuraltrust-platform.firewall.redisUrl" -}}
{{- $host := include "neuraltrust-platform.redis.host" (dict "ctx" . "host" "") -}}
{{- if $host -}}
{{- $port := include "neuraltrust-platform.redis.port" (dict "ctx" . "port" "") -}}
{{- $user := include "neuraltrust-platform.redis.username" (dict "ctx" . "username" "") -}}
{{- $tls := include "neuraltrust-platform.redis.tls" (dict "ctx" . "tls" "") -}}
{{- $pw := include "neuraltrust-platform.redis.password" (dict "ctx" . "password" "") -}}
{{- $scheme := "redis" -}}
{{- if eq ($tls | toString) "true" }}{{- $scheme = "rediss" }}{{- end -}}
{{- $authority := "" -}}
{{- if $user -}}
  {{- $authority = printf "%s:%s@" ($user | urlquery) ($pw | urlquery) -}}
{{- else if $pw -}}
  {{- $authority = printf ":%s@" ($pw | urlquery) -}}
{{- end -}}
{{- printf "%s://%s%s:%v/0" $scheme $authority $host $port -}}
{{- end -}}
{{- end }}

{{/*
Whether the composed firewall REDIS_URL carries a password (must live in a
Secret, never a ConfigMap).
*/}}
{{- define "neuraltrust-platform.firewall.redisUrl.hasPassword" -}}
{{- $pw := include "neuraltrust-platform.redis.password" (dict "ctx" . "password" "") -}}
{{- if $pw }}true{{- end -}}
{{- end }}

{{/*
Per-service Postgres IAM resolution (AUT-392).

An explicit `<service>.database.iamAuth` true/false always wins, so mixed-auth
external installs stay expressible and existing `--set …iamAuth=true` overlays
keep working. When the key is unset, inherit global.postgresql.authMode=iam —
but only against a managed Postgres (`deploy=false`); the chart's own Postgres
has no IAM path.
Usage: {{ include "neuraltrust-platform.postgres.iamAuth" (dict "ctx" . "database" .Values.database) }}
*/}}
{{- define "neuraltrust-platform.postgres.iamAuth" -}}
{{- $ctx := .ctx -}}
{{- $db := default dict .database -}}
{{- $globalPg := default dict (default dict $ctx.Values.global).postgresql -}}
{{- if hasKey $db "iamAuth" -}}
  {{- if $db.iamAuth }}true{{- end -}}
{{- else if eq (include "neuraltrust-platform.postgresql.deploy" $ctx) "true" -}}
{{- else if eq ($globalPg.authMode | default "password" | toString | lower) "iam" -}}
true
{{- end -}}
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
{{- $global := default dict .Values.global -}}
{{- $pg := default dict $global.postgresql -}}
{{- $existing := default dict $pg.existingSecret -}}
{{- /* preserveExistingSecrets skips both postgresql-secrets emitters, so the
       live Secret is whatever an earlier release wrote — under the old key
       names. Renaming from POSTGRES_* would resolve nothing, and because these
       refs are optional the loss would be silent: DB_SSL_MODE would vanish and
       the gateways would fall back to their built-in "disable", turning an
       install configured for opportunistic TLS into a plaintext one. Treat the
       Secret as operator-owned instead and keep the envFrom passthrough. */}}
{{- if and (not ($existing.name | default "")) (not $global.preserveExistingSecrets) -}}true{{- end -}}
{{- end }}

{{/*
Explicit Postgres env for one consumer, renamed to the names that consumer reads.

`postgresql-secrets` stores a single canonical POSTGRES_* family. The Go services
read DB_*, TrustLens reads DATABASE_*, so that translation happens here instead of
storing every alias in the Secret and injecting the whole set with envFrom — which
handed each pod eighteen datastore variables to read six, with no manifest showing
which ones it used.

Only valid for the chart-managed Secret. When an operator supplies
global.postgresql.existingSecret the key names in it are theirs, so callers keep
the envFrom passthrough for that case.

TrustLens reads DATABASE_* but is deliberately not handled here: it owns a separate
database identity (its own user, database and password), so pointing it at the
shared credential would change which database it connects to.

Usage: (dict "ctx" $ "skip" .Values.dataPlane.extraEnv)
  skip    env entries that already define these names, so an operator override in
          extraEnv is not duplicated; duplicate env names fail the upgrade patch

SENSIBLE_PG_DSN is no longer injected: TrustGate/TrustGuard telemetry exporters
fall back to the service DatabaseConfig (DB_*) when no dsn_env is set (RUN-1086).
*/}}
{{- define "neuraltrust-platform.postgresEnv" -}}
{{- $ctx := .ctx -}}
{{- $secret := include "neuraltrust-platform.v2.hybridPg.secretName" $ctx -}}
{{- /* DB_PASSWORD is handled separately via passwordEnv so passwordSecret
       redirects work in hybrid too. */}}
{{- $map := dict "DB_HOST" "POSTGRES_HOST" "DB_PORT" "POSTGRES_PORT" "DB_USER" "POSTGRES_USER" "DB_NAME" "POSTGRES_DB" "DB_SSL_MODE" "POSTGRES_SSLMODE" -}}
{{- /* POSTGRES_LOGIN is the only IAM switch these services read, and hybrid never
       delivered it: the gateways got it solely from their own subchart flag, so a
       hybrid install against an IAM-authenticated Postgres quietly attempted
       password auth. It resolves to "default" for password installs. */}}
{{- $_ := set $map "POSTGRES_LOGIN" "POSTGRES_LOGIN" -}}
{{- $skip := list -}}
{{- range $e := (default list .skip) -}}{{- $skip = append $skip $e.name -}}{{- end -}}
{{- range $envName, $key := $map }}
{{- if not (has $envName $skip) }}
- name: {{ $envName }}
  valueFrom:
    secretKeyRef:
      name: {{ $secret | quote }}
      key: {{ $key | quote }}
      {{- /* The envFrom this replaces was optional, and installs that deploy a
             gateway without a rendered postgresql-secrets rely on that: a required
             ref would turn a service that fails its own config validation into a
             pod that never starts. */}}
      optional: true
{{- end }}
{{- end }}
{{- if not (has "DB_PASSWORD" $skip) }}
{{- include "neuraltrust-platform.postgresql.passwordEnv" (dict "ctx" $ctx "secret" $secret "envName" "DB_PASSWORD") }}
{{- end }}
{{- end -}}

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
Fingerprint of the chart-managed `redis-secrets` payload for AUT-403 checksums.

Subchart Deployments envFrom `redis-secrets`, but `$.Template.BasePath` points at
the subchart so they cannot `include` `templates/platform-secrets.yaml`. This
helper mirrors the Secret's keys from the same `global.redis` inputs (and the
lookup-adopted password) so a Redis host/password change rolls the pods that
read it. Operator `global.redis.existingSecret` is intentionally omitted — the
chart has no content to hash, and that Secret is out of scope for checksum
rollouts.
*/}}
{{- define "neuraltrust-platform.v2.hybridRedis.secretChecksum" -}}
{{- $r := default dict (default dict .Values.global).redis -}}
{{- $host := $r.host | default "redis" -}}
{{- $port := $r.port | default 6379 | toString -}}
{{- $user := $r.username | default "" -}}
{{- $tls := "" -}}
{{- if hasKey $r "tls" }}{{- $tls = $r.tls | toString }}{{- end -}}
{{- $password := "" -}}
{{- if and $r.password (ne ($r.password | toString) "") -}}
  {{- $password = $r.password | toString -}}
{{- else -}}
  {{- $existing := lookup "v1" "Secret" .Release.Namespace "redis-secrets" -}}
  {{- if and $existing (kindIs "map" $existing) (index $existing "data") (hasKey $existing.data "REDIS_PASSWORD") -}}
    {{- $password = index $existing.data "REDIS_PASSWORD" | b64dec -}}
  {{- end -}}
{{- end -}}
REDIS_HOST={{ $host }}
REDIS_PORT={{ $port }}
REDIS_PASSWORD={{ $password }}
REDIS_USERNAME={{ $user }}
REDIS_TLS={{ $tls }}
{{- end }}

{{/*
Renames the shared Redis TLS flag for TrustGate, which reads REDIS_TLS_ENABLED
while TrustGuard reads REDIS_TLS. `redis-secrets` stores the canonical
REDIS_TLS, so without this the AgentGateway data planes never see the flag and
connect in plaintext to a TLS-only Redis. Emitted only when global.redis.tls is
set, so a subchart-level redis.tls arriving through the ConfigMap still wins
where the global is unset.

Usage: {{- include "neuraltrust-platform.hybridRedisTlsEnv" . | nindent 8 }}
*/}}
{{- define "neuraltrust-platform.hybridRedisTlsEnv" -}}
{{- $redis := default dict (default dict .Values.global).redis -}}
{{- if and (eq (include "neuraltrust-platform.isHybrid" .) "true") ($redis.tls | default "" | toString) -}}
- name: REDIS_TLS_ENABLED
  valueFrom:
    secretKeyRef:
      name: {{ include "neuraltrust-platform.v2.hybridRedis.secretName" . | quote }}
      key: REDIS_TLS
      optional: true
{{- end -}}
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
Product enable flag from the shared global.products contract.
- external: always on (full stack; product flags are ignored)
- hybrid: positive opt-in — true only when the flag is explicitly true
Usage: {{ include "neuraltrust-platform.product.enabled" (dict "ctx" . "product" "trustgate") }}
*/}}
{{- define "neuraltrust-platform.product.enabled" -}}
{{- if eq (include "neuraltrust-platform.isExternal" .ctx) "true" -}}
true
{{- else -}}
{{- $products := default dict (default dict .ctx.Values.global).products -}}
{{- $on := false -}}
{{- if hasKey $products .product -}}{{- $on = index $products .product -}}{{- end -}}
{{- if $on -}}true{{- end -}}
{{- end -}}
{{- end }}

{{/*
Map commercial product id → component values root.
trustgate (product) → agentgateway (values); trustguard → trustguard.
Usage: {{ include "neuraltrust-platform.product.valuesRoot" (dict "product" "trustgate") }}
*/}}
{{- define "neuraltrust-platform.product.valuesRoot" -}}
{{- $product := .product | default . -}}
{{- if eq $product "trustgate" -}}agentgateway
{{- else -}}{{ $product }}
{{- end -}}
{{- end }}

{{/*
Primary product for ClickStack egress ownership: TrustGate when enabled,
otherwise TrustGuard.
*/}}
{{- define "neuraltrust-platform.dataagent.primaryProduct" -}}
{{- if eq (include "neuraltrust-platform.product.enabled" (dict "ctx" . "product" "trustgate")) "true" -}}
trustgate
{{- else if eq (include "neuraltrust-platform.product.enabled" (dict "ctx" . "product" "trustguard")) "true" -}}
trustguard
{{- end -}}
{{- end }}

{{/*
True when a hybrid product slice needs a DataAgent (trustgate or trustguard on).
*/}}
{{- define "neuraltrust-platform.dataagent.required" -}}
{{- if and
  (eq (include "neuraltrust-platform.isHybrid" .) "true")
  (or
    (eq (include "neuraltrust-platform.product.enabled" (dict "ctx" . "product" "trustgate")) "true")
    (eq (include "neuraltrust-platform.product.enabled" (dict "ctx" . "product" "trustguard")) "true")
  )
-}}true{{- end -}}
{{- end }}

{{/*
Nested enrolment helpers for a product dataagent block.
Usage: (dict "cfg" $merged)
*/}}
{{- define "neuraltrust-platform.dataagent.cfg.enrolment.token" -}}
{{- $enrolment := default dict .cfg.enrolment -}}
{{- $enrolment.token | default "" -}}
{{- end }}

{{- define "neuraltrust-platform.dataagent.cfg.enrolment.existingSecretName" -}}
{{- $enrolment := default dict .cfg.enrolment -}}
{{- $existing := default dict $enrolment.existingSecret -}}
{{- $existing.name | default "" -}}
{{- end }}

{{/*
Merged values for one DataAgent instance.
Usage: {{ include "neuraltrust-platform.dataagent.instanceValues" (dict "ctx" $ "product" "trustgate") }}
*/}}
{{- define "neuraltrust-platform.dataagent.instanceValues" -}}
{{- $root := .ctx -}}
{{- $product := .product -}}
{{- $valuesKey := include "neuraltrust-platform.product.valuesRoot" (dict "product" $product) -}}
{{- $productRoot := default dict (index $root.Values $valuesKey) -}}
{{- $nested := default dict $productRoot.dataagent -}}
{{- $primary := include "neuraltrust-platform.dataagent.primaryProduct" $root -}}
{{- /* Helm coalesces the library chart defaults into .Values.dataagent. */ -}}
{{- $merged := mergeOverwrite (deepCopy (default dict $root.Values.dataagent)) $nested -}}
{{- $fullname := "dataagent" -}}
{{- if eq $product "trustguard" -}}{{- $fullname = "dataagent-trustguard" -}}{{- end -}}
{{- $_ := set $merged "fullnameOverride" $fullname -}}
{{- $sa := default dict $merged.serviceAccount -}}
{{- $_ := set $sa "name" $fullname -}}
{{- $_ := set $merged "serviceAccount" $sa -}}
{{- $_ := set $merged "product" $product -}}
{{- $_ := set $merged "egressPrimary" (and (eq $product $primary) (eq (include "neuraltrust-platform.clickstackHybridEnabled" $root) "true")) -}}
{{- $_ := set $merged "global" (default dict $root.Values.global) -}}
{{- toYaml $merged -}}
{{- end }}

{{/*
Credential readiness for a merged instance cfg (dict "ctx" $ "cfg" $merged).
*/}}
{{- define "neuraltrust-platform.dataagent.cfgReady" -}}
{{- $root := .ctx -}}
{{- $cfg := .cfg -}}
{{- $token := include "neuraltrust-platform.dataagent.cfg.enrolment.token" (dict "cfg" $cfg) -}}
{{- $existingName := include "neuraltrust-platform.dataagent.cfg.enrolment.existingSecretName" (dict "cfg" $cfg) -}}
{{- $secretName := "" -}}
{{- if (default dict $cfg.existingSecret).name -}}
  {{- $secretName = $cfg.existingSecret.name -}}
{{- else if $cfg.fullnameOverride -}}
  {{- $secretName = printf "%s-secrets" $cfg.fullnameOverride -}}
{{- else -}}
  {{- $secretName = "dataagent-secrets" -}}
{{- end -}}
{{- $managedSecret := lookup "v1" "Secret" $root.Release.Namespace $secretName -}}
{{- $managedData := dict -}}
{{- if and $managedSecret (kindIs "map" $managedSecret) $managedSecret.data -}}
  {{- $managedData = $managedSecret.data -}}
{{- end -}}
{{- $hasManagedToken := and (hasKey $managedData "ENROLMENT_TOKEN") (ne (index $managedData "ENROLMENT_TOKEN") "") -}}
{{- $dataSecretName := (default dict $cfg.existingSecret).name | default "" -}}
{{- $hasManagedDatabase := and (hasKey $managedData "DATABASE_URL") (ne (index $managedData "DATABASE_URL") "") -}}
{{- $globalPg := default dict (default dict $root.Values.global).postgresql -}}
{{- $globalPgExisting := default dict $globalPg.existingSecret -}}
{{- $sharedPgSecretName := $globalPgExisting.name | default "postgresql-secrets" -}}
{{- $sharedPgSecret := lookup "v1" "Secret" $root.Release.Namespace $sharedPgSecretName -}}
{{- $sharedPgData := dict -}}
{{- if and $sharedPgSecret (kindIs "map" $sharedPgSecret) $sharedPgSecret.data -}}
  {{- $sharedPgData = $sharedPgSecret.data -}}
{{- end -}}
{{- /* POSTGRES_HOST is the readiness signal now that SENSIBLE_PG_DSN is gone
       (RUN-1086 / RUN-1093). existingSecret.name still wins without a lookup. */}}
{{- $sharedPgReady := or ($globalPgExisting.name | default "") (and (hasKey $sharedPgData "POSTGRES_HOST") (ne (index $sharedPgData "POSTGRES_HOST") "")) -}}
{{- $preserve := dig "preserveExistingSecrets" false ($root.Values.global | default dict) -}}
{{- $autoGenerate := eq (include "neuraltrust-platform.autoGenerateSecrets" $root) "true" -}}
{{- $chartGeneratesDatabase := and $autoGenerate (not $preserve) -}}
{{- $pgDeploy := true -}}
{{- if hasKey $globalPg "deploy" -}}{{- $pgDeploy = $globalPg.deploy -}}{{- end -}}
{{- $pgIam := and (eq ($globalPg.authMode | default "password" | toString | lower) "iam") (not $pgDeploy) -}}
{{- $fallbackSharedPgReady := and (not $autoGenerate) (not $preserve) (not ($globalPgExisting.name | default "")) (or ($globalPg.password | default "") $pgIam) -}}
{{- $tokenReady := or $existingName $hasManagedToken (and $token $chartGeneratesDatabase) -}}
{{/* tenant_id / instance_id live in the enrolment JWT — not Helm values. */}}
{{- if and $tokenReady (or $chartGeneratesDatabase $fallbackSharedPgReady $sharedPgReady $dataSecretName $hasManagedDatabase) -}}true{{- end -}}
{{- end }}

{{/*
Whether a product's DataAgent should render.
Usage: (dict "ctx" $ "product" "trustgate")
*/}}
{{- define "neuraltrust-platform.dataagent.instanceEnabled" -}}
{{- $root := .ctx -}}
{{- $product := .product -}}
{{- if ne (include "neuraltrust-platform.isHybrid" $root) "true" -}}
{{- else if ne (include "neuraltrust-platform.product.enabled" (dict "ctx" $root "product" $product)) "true" -}}
{{- else -}}
  {{- $vals := include "neuraltrust-platform.dataagent.instanceValues" (dict "ctx" $root "product" $product) | fromYaml -}}
  {{- if eq (include "neuraltrust-platform.dataagent.cfgReady" (dict "ctx" $root "cfg" $vals)) "true" -}}true{{- end -}}
{{- end -}}
{{- end }}

{{/*
Any product DataAgent enabled (hybrid).
*/}}
{{- define "neuraltrust-platform.dataagentEnabled" -}}
{{- if or
  (eq (include "neuraltrust-platform.dataagent.instanceEnabled" (dict "ctx" . "product" "trustgate")) "true")
  (eq (include "neuraltrust-platform.dataagent.instanceEnabled" (dict "ctx" . "product" "trustguard")) "true")
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
{{- if ne (include "neuraltrust-platform.product.enabled" (dict "ctx" . "product" "dataPlane")) "true" -}}
{{- else -}}
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
{{- end -}}
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

{{/*
Prisma `connection_limit` for the generated Postgres DSN.

Each app pod opens up to this many connections, so it multiplies with
replicaCount against the server's max_connections. A shared or small Postgres
needs this tunable. Prefer `global.postgresql.connectionLimit`, else 15.
*/}}
{{- define "neuraltrust-platform.postgresql.connectionLimit" -}}
{{- $globalPg := default dict (default dict .Values.global).postgresql -}}
{{- if and (hasKey $globalPg "connectionLimit") (ne ($globalPg.connectionLimit | toString) "") -}}
{{- $globalPg.connectionLimit | toString -}}
{{- else -}}
15
{{- end -}}
{{- end }}

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

{{- define "neuraltrust-platform.dataPlaneApi.postgresSchema" -}}
{{- $pg := include "neuraltrust-platform.dataPlaneApi.postgresConfig" . | fromYaml }}
{{- $schema := $pg.schema | default "public" }}
{{- if not (regexMatch "^[a-z_][a-z0-9_]*$" $schema) }}
{{- fail "data-plane-api PostgreSQL schema must be a lowercase SQL identifier" }}
{{- end }}
{{- $schema }}
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
{{- /* Reading the chart's own Secret with the default key means connecting as the
       control-plane role, so the password has to follow wherever that role's
       password lives (global.postgresql.passwordSecret). A redirected Secret or a
       renamed key is the operator's own wiring and is left alone. Both default to
       the chart's own names here rather than to empty, so they have to be compared
       rather than just tested. */}}
{{- if or (ne $secretName "postgresql-secrets") (ne $passwordKey "POSTGRES_PASSWORD") }}
- name: POSTGRES_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ $secretName | quote }}
      key: {{ $passwordKey | quote }}
{{- else }}
{{ include "neuraltrust-platform.postgresql.passwordEnv" (dict "ctx" . "secret" $secretName "optional" false) }}
{{- end }}
- name: POSTGRES_SCHEMA
  value: {{ include "neuraltrust-platform.dataPlaneApi.postgresSchema" . | quote }}
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

{{/*
Resolved outbound-email settings, as a YAML dict for `fromYaml`.

The control-plane app builds exactly one transport, chosen by provider
(resend | ses | smtp). Credentials always arrive through a Secret: either the
operator's own via global.email.existingSecret.name, or chart-managed
control-plane-secrets. Legacy controlPlane.secrets.resend* values stay as
fallbacks so existing Resend installs need no changes.

Args: the root context.
*/}}
{{- define "neuraltrust-platform.email.config" -}}
{{- $email := default dict (default dict .Values.global).email }}
{{- $existing := default dict $email.existingSecret }}
{{- $smtp := default dict $email.smtp }}
{{- $ses := default dict $email.ses }}
provider: {{ $email.provider | default "resend" | quote }}
secretName: {{ $existing.name | default "control-plane-secrets" | quote }}
{{- /* With an operator-supplied Secret the chart cannot guarantee a key exists,
       so credential refs are optional: a missing SES key then falls through to
       the pod IAM role rather than blocking startup. */}}
secretOptional: {{ if $existing.name }}true{{ else }}false{{ end }}
resendApiKeyKey: {{ $existing.resendApiKeyKey | default "RESEND_API_KEY" | quote }}
smtpPasswordKey: {{ $existing.smtpPasswordKey | default "SMTP_PASSWORD" | quote }}
sesAccessKeyIdKey: {{ $existing.sesAccessKeyIdKey | default "SES_ACCESS_KEY_ID" | quote }}
sesSecretAccessKeyKey: {{ $existing.sesSecretAccessKeyKey | default "SES_SECRET_ACCESS_KEY" | quote }}
sesRegion: {{ $ses.region | default "" | quote }}
{{- /* Booleans stay unquoted so `fromYaml` yields real bools for `if` checks.
       smtpSecure is quoted at the call site when emitted as an env value. */}}
sesStaticCredentials: {{ if or $ses.accessKeyId $existing.name }}true{{ else }}false{{ end }}
smtpHost: {{ $smtp.host | default "" | quote }}
smtpPort: {{ $smtp.port | default 587 | quote }}
smtpSecure: {{ if kindIs "invalid" $smtp.secure }}true{{ else }}{{ $smtp.secure }}{{ end }}
smtpUser: {{ $smtp.user | default "" | quote }}
{{- /* A user means an authenticated relay, so the password ref is emitted
       whether the password is inline or in the operator's Secret. */}}
smtpAuth: {{ if and $smtp.user (or $smtp.password $existing.name) }}true{{ else }}false{{ end }}
{{- end }}

{{/*
Renders the spec.tls body of an OpenShift Route.

A Route is readable by anyone holding `route/get`, so private key material must
never be copied into it. When `tls.secretName` is set the Route references the
Secret through `spec.tls.externalCertificate` (OpenShift 4.17+, GA) instead of
inlining the PEM. Inline `certificate` / `key` are emitted only when the
operator supplies them explicitly in values.

Args: dict "tls" <ingress tls config map>
*/}}
{{- define "neuraltrust-platform.route.tls" -}}
{{- $tls := default dict .tls }}
termination: {{ $tls.termination | default "edge" }}
{{- if $tls.secretName }}
externalCertificate:
  name: {{ $tls.secretName | quote }}
{{- end }}
{{- if $tls.certificate }}
certificate: {{ $tls.certificate | quote }}
{{- end }}
{{- if $tls.key }}
key: {{ $tls.key | quote }}
{{- end }}
{{- if $tls.caCertificate }}
caCertificate: {{ $tls.caCertificate | quote }}
{{- end }}
{{- if $tls.destinationCACertificate }}
destinationCACertificate: {{ $tls.destinationCACertificate | quote }}
{{- end }}
insecureEdgeTerminationPolicy: {{ $tls.insecureEdgeTerminationPolicy | default "Redirect" }}
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
Effective config-sync enablement.
  explicit bool → use it
  null / omitted → true in hybrid, false in external
Usage (subchart): {{ include "neuraltrust-platform.configSync.enabled" . }}
Usage (umbrella): {{ include "neuraltrust-platform.configSync.enabledFrom" (dict "mode" $mode "configSync" $cs) }}
*/}}
{{- define "neuraltrust-platform.configSync.enabled" -}}
{{- $cs := default dict .Values.configSync -}}
{{- $isHybrid := eq (include "neuraltrust-platform.isHybrid" .) "true" -}}
{{- if hasKey $cs "enabled" -}}
  {{- if kindIs "bool" $cs.enabled -}}
    {{- if $cs.enabled }}true{{- end -}}
  {{- else if $isHybrid -}}
true
  {{- end -}}
{{- else if $isHybrid -}}
true
{{- end -}}
{{- end }}

{{- define "neuraltrust-platform.configSync.enabledFrom" -}}
{{- $cs := default dict .configSync -}}
{{- $isHybrid := eq (.mode | default "hybrid") "hybrid" -}}
{{- if hasKey $cs "enabled" -}}
  {{- if kindIs "bool" $cs.enabled -}}
    {{- if $cs.enabled }}true{{- end -}}
  {{- else if $isHybrid -}}
true
  {{- end -}}
{{- else if $isHybrid -}}
true
{{- end -}}
{{- end }}

{{/*
Config-sync env. Hybrid: public config-sync host:443. External: in-cluster Service.
Usage: {{- include "neuraltrust-platform.configSyncEnv" (dict "ctx" . "product" "trustguard") | nindent 8 }}
*/}}
{{- define "neuraltrust-platform.configSyncEnv" -}}
{{- $ctx := .ctx -}}
{{- $product := .product -}}
{{- $tlsCaPath := .tlsCaPath | default "" -}}
{{- $cs := default dict $ctx.Values.configSync -}}
{{- if eq (include "neuraltrust-platform.configSync.enabled" $ctx) "true" -}}
{{- $isExternal := eq (include "neuraltrust-platform.isExternal" $ctx) "true" -}}
{{- $endpoint := $cs.endpoint -}}
{{- $insecure := false -}}
{{- $caPath := "" -}}
{{- if $isExternal -}}
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

Only the SaaS-issued token is taken from the operator Secret. The LKG key
encrypts a local snapshot file, so it is generated by the chart and arrives
through the envFrom those workloads already carry.

Whether it is referenced here depends solely on Secret ownership, never on
`lookup`. That is deliberate: a gate that reads the cluster renders one way
under `helm upgrade` and another under `helm template`, ArgoCD, `--dry-run`, or
any CI identity without RBAC to read Secrets — same values, different pod spec,
and the divergence only surfaces in production. So when the chart owns the
service Secret the key always comes from there, and when it owns nothing
(autoGenerateSecrets=false or preserveExistingSecrets) the operator Secret is
the only possible source and the reference is always emitted.

The cost is that a pre-2.6 operator Secret carrying its own LKG key is no longer
read on the default path. That is safe: the key only decrypts a cache on an
emptyDir that is discarded on restart regardless, and a mismatch costs one
refetch. Operators who need a specific value set `configSync.lkgKey`, which is
deterministic and does not depend on how the chart was rendered.
*/}}
{{- define "neuraltrust-platform.configSyncTokenEnv" -}}
{{- $cs := default dict .Values.configSync -}}
{{- $existing := default dict $cs.existingSecret -}}
{{- if and (eq (include "neuraltrust-platform.configSync.enabled" .) "true") $existing.name }}
- name: CONFIG_SYNC_TOKEN
  valueFrom:
    secretKeyRef:
      name: {{ $existing.name | quote }}
      key: {{ $existing.tokenKey | default "CONFIG_SYNC_TOKEN" | quote }}
{{- $chartOwnsServiceSecret := and (include "neuraltrust-platform.autoGenerateSecrets" .) (not .Values.global.preserveExistingSecrets) }}
{{- if not $chartOwnsServiceSecret }}
- name: CONFIG_SYNC_LKG_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $existing.name | quote }}
      key: {{ $existing.lkgKey | default "CONFIG_SYNC_LKG_KEY" | quote }}
{{- end }}
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
https://telemetry.neuraltrust.ai/v1/logs
{{- end }}
{{- define "neuraltrust-platform.clickstack.defaultProtocol" -}}
http/protobuf
{{- end }}

{{/*
Hybrid product OTLP dual-write is always on (no opt-out). EXTERNAL ignores this.
*/}}
{{- define "neuraltrust-platform.clickstackHybridEnabled" -}}
{{- if eq (include "neuraltrust-platform.isHybrid" .) "true" -}}
true
{{- end -}}
{{- end }}

{{/*
Enrolment credential is resolvable for at least one DataAgent instance.
*/}}
{{- define "neuraltrust-platform.clickstack.enrolmentReady" -}}
{{- if eq (include "neuraltrust-platform.dataagentEnabled" .) "true" -}}true{{- end -}}
{{- end }}

{{/*
True when hybrid should co-locate the OTLP egress sidecar on the primary
DataAgent. EXTERNAL installs never enable this.
*/}}
{{- define "neuraltrust-platform.clickstackEgress.enabled" -}}
{{- if and
  (eq (include "neuraltrust-platform.clickstackHybridEnabled" .) "true")
  (eq (include "neuraltrust-platform.dataagentEnabled" .) "true")
-}}true{{- end -}}
{{- end }}

{{/*
True when apps send plain OTLP to the local egress ClusterIP (DataAgent sidecar).
*/}}
{{- define "neuraltrust-platform.clickstackEgress.useLocalEndpoint" -}}
{{- if eq (include "neuraltrust-platform.clickstackHybridEnabled" .) "true" -}}
true
{{- end -}}
{{- end }}

{{- define "neuraltrust-platform.clickstackEgress.fullname" -}}
{{- $cfg := default dict (default dict (default dict .Values.global).clickstack).egress -}}
{{- default "clickstack-egress-collector" $cfg.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{/*
OTel listen endpoint host:port for the egress sidecar (health / OTLP).
Call with (dict "ctx" $ "port" 4317). Default listenHost "::" → "[::]:port"
(dual-stack on Linux). IPv4 literals (e.g. 0.0.0.0) are emitted unbracketed.
*/}}
{{- define "neuraltrust-platform.clickstackEgress.listenEndpoint" -}}
{{- $cfg := default dict (default dict (default dict .ctx.Values.global).clickstack).egress -}}
{{- $host := default "::" $cfg.listenHost -}}
{{- $port := .port -}}
{{- if hasPrefix "[" $host -}}
{{- printf "%s:%v" $host $port -}}
{{- else if contains ":" $host -}}
{{- printf "[%s]:%v" $host $port -}}
{{- else -}}
{{- printf "%s:%v" $host $port -}}
{{- end -}}
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
OTLP/HTTP base for the egress exporter (no /v1/logs). Default
https://telemetry.neuraltrust.ai; override via global.clickstack.egress.endpoint
or legacy global.clickstack.endpoint (path stripped if present).
*/}}
{{- define "neuraltrust-platform.clickstackEgress.saasEndpoint" -}}
{{- $clickstack := default dict (default dict .Values.global).clickstack -}}
{{- $cfg := default dict $clickstack.egress -}}
{{- $raw := $cfg.endpoint | default ($clickstack.endpoint | default "https://telemetry.neuraltrust.ai") -}}
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
{{- /* Hybrid: plain OTLP to local egress (enrolment owns auth). */ -}}
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
ConfigMap/Secret checksum annotations for Deployment restart-on-change (AUT-403).

Usage from a subchart pod template:
  annotations:
    {{- include "neuraltrust-platform.checksumAnnotations" (dict "context" . "files" (list "/env-configmap.yaml" "/secrets.yaml")) | nindent 8 }}

`files` are paths under the caller's `$.Template.BasePath`. For umbrella-owned
Secrets consumed via envFrom (hybrid `redis-secrets`), add
`checksum/redis-secrets` from `neuraltrust-platform.v2.hybridRedis.secretChecksum`
separately — BasePath cannot reach `templates/platform-secrets.yaml`.

Operator-owned `existingSecret` references are deliberately not checksummed:
the chart has no template content to hash, and a lookup-dependent annotation
would render differently under `helm template` / ArgoCD than under `helm upgrade`.
*/}}
{{- define "neuraltrust-platform.checksumAnnotations" -}}
{{- $ctx := .context -}}
{{- range .files -}}
checksum/{{ . | base | replace ".yaml" "" }}: {{ include (print $ctx.Template.BasePath .) $ctx | sha256sum }}
{{ end -}}
{{- end -}}

{{/*
================================================================================
Shared platform Secret (`platform-secrets`)
================================================================================
One Secret holds every cross-service application credential, replacing the
hand-duplicated per-service Secrets that silently drifted apart.

`platform-secrets` is the sole *generator* of these values. Legacy per-service
Secrets keep emitting them for one release so a rollback still finds them, but
no workload reads a legacy copy for a migrated key: consumers reference
`platform-secrets` through `neuraltrust-platform.secretRef`, and Kubernetes
gives an explicit `env` entry precedence over `envFrom`. Two independent
`resolveSecret` calls cannot agree on a freshly generated value (`lookup`
returns nothing during install), so a single generator is the only way to keep
both sides identical.

`neuraltrust-platform.platformSecret.registry` maps each logical key to the
legacy Secret it adopts from on upgrade, and to a `generate` policy:
  random  → generated when absent (chart owns the value)
  adopt   → only ever adopted; omitted when no source has it (operator owns it)
  install → generated on install only, adopted on upgrade. For a key that some
            existing installs are already using at an application default: a
            fresh install gets a real credential, while an upgrade leaves the
            key absent rather than rotating it out from under data already
            encrypted with that default (AUTH_SECRET_KEY).

`requires` lists the install shapes that consume the key, and a key is emitted
when any of them is in play:
  external   → the full stack
  trustgate / trustguard / dataPlane → the product claims it in hybrid
  trustlens  → the opt-in subchart is enabled, in either mode. External deploys
               the full stack, so shape alone would not gate an opt-in chart.
  alertengine → the AlertEngine subchart is enabled in external mode. External
               alone must not mint its credentials when the subchart is off
               (`alertengine.enabled=false`); hybrid never deploys AlertEngine.
  mcpOAuth   → MCP OAuth resolved as active: external, and a signing key exists.
               On by default in external, but only once the key the app needs is
               available — external alone must not conjure credentials for a
               feature that cannot serve logins yet. External-only, because the
               authorization server is the control-plane app and hybrid uses the
               hosted platform instead.
  watchdog   → watchdog usage export is on. It calls the control-plane and
               data-plane APIs, so it needs their keys even in hybrid.
A hybrid install therefore carries only the credentials its in-cluster services
actually read. Keys already present in a live `platform-secrets` are always
kept, so an upgrade never drops one an existing install may depend on.

Only credentials with a real consumer on this Secret belong here. An
operator-owned key that keeps its own dedicated Secret (third-party API keys,
client credential pairs) would just become a second copy nobody reads — the
drift this Secret exists to prevent.

`aliasOf` marks a key that must hold the same value as another key. Aliases are
resolved from their target rather than independently, which is what keeps
documented invariants (NEXTAUTH_SECRET == AUTH_SECRET) true on a fresh install
too.

Notes on the cross-service keys that carry a constraint the row cannot express:

MCP_OAUTH_CLIENT_SECRET — the control-plane app is the MCP OAuth authorization
server and TrustGate a pre-registered confidential client, so this value has to
be byte identical on both sides or the token exchange fails. The app compares it
with a timing-safe equality check; TrustGate reads it as
MCP_DEFAULT_IDP_CLIENT_SECRET, so the two env names differ while the value does
not.

MCP_OAUTH_SIGNING_KEY — RS256 key for the tokens that server mints, and
adopt-only on purpose. The app loads it with `importPKCS8`, while Helm's
`genPrivateKey "rsa"` emits PKCS#1, so anything the chart generated would fail
to parse. SECRETS.md carries the `openssl genpkey` command. While it is absent
the app mints an ephemeral key per replica, which only works with one replica.

AUTH_SECRET_KEY — encrypts SSO client secrets and SMTP credentials at rest
(scrypt into AES-256-GCM). Deliberately independent of AUTH_SECRET, which signs
sessions: one value for both signing and encryption is key reuse. Uses the
`install` policy because the app has a committed default, and replacing that
default on a live install would make every already-encrypted row undecryptable.
*/}}
{{- define "neuraltrust-platform.platformSecret.registry" -}}
SERVER_SECRET_KEY: {legacyName: agentgateway-secrets, legacyKey: SERVER_SECRET_KEY, generate: random, length: 64, requires: external trustgate}
ADMIN_JWT_SECRET: {legacyName: trustguard-secrets, legacyKey: ADMIN_JWT_SECRET, generate: random, length: 64, requires: external trustguard}
TRUSTGUARD_TOKEN_SIGNING_SECRET: {legacyName: trustguard-secrets, legacyKey: TRUSTGUARD_TOKEN_SIGNING_SECRET, generate: random, length: 64, requires: external trustguard}
REDIS_EVENTS_SECRET: {legacyName: trustguard-secrets, legacyKey: REDIS_EVENTS_SECRET, generate: random, length: 64, requires: external trustguard}
AUTH_JWT_HS256_SECRET: {legacyName: datacore-secrets, legacyKey: AUTH_JWT_HS256_SECRET, generate: random, length: 64, requires: external}
AUTH_JWT_SECRET: {legacyName: alertengine-secrets, legacyKey: AUTH_JWT_SECRET, generate: random, length: 64, requires: alertengine}
APP_ENCRYPTION_KEY: {legacyName: alertengine-secrets, legacyKey: APP_ENCRYPTION_KEY, generate: random, length: 32, requires: alertengine}
TRUSTLENS_JWT_SECRET: {legacyName: trustlens-secrets, legacyKey: JWT_SECRET, generate: random, length: 64, requires: trustlens}
ENCRYPTION_KEYSET: {legacyName: trustlens-secrets, legacyKey: ENCRYPTION_KEYSET, generate: random, length: 64, requires: trustlens}
JWT_SECRET: {legacyName: firewall-secrets, legacyKey: JWT_SECRET, generate: random, length: 64, requires: external trustguard}
DATA_PLANE_JWT_SECRET: {legacyName: data-plane-jwt-secret, legacyKey: DATA_PLANE_JWT_SECRET, generate: random, length: 64, requires: external dataPlane watchdog}
CONTROL_PLANE_JWT_SECRET: {legacyName: control-plane-secrets, legacyKey: CONTROL_PLANE_JWT_SECRET, generate: random, length: 64, requires: external watchdog}
AUTH_SECRET: {legacyName: control-plane-secrets, legacyKey: AUTH_SECRET, generate: random, length: 64, requires: external}
NEXTAUTH_SECRET: {legacyName: control-plane-secrets, legacyKey: NEXTAUTH_SECRET, aliasOf: AUTH_SECRET, requires: external}
MODEL_SCANNER_SECRET: {legacyName: control-plane-secrets, legacyKey: MODEL_SCANNER_SECRET, generate: adopt, requires: external}
MCP_OAUTH_CLIENT_SECRET: {legacyName: control-plane-secrets, legacyKey: MCP_OAUTH_CLIENT_SECRET, generate: random, length: 64, requires: mcpOAuth}
MCP_OAUTH_SIGNING_KEY: {legacyName: control-plane-secrets, legacyKey: MCP_OAUTH_SIGNING_KEY, generate: adopt, requires: mcpOAuth}
AUTH_SECRET_KEY: {legacyName: control-plane-secrets, legacyKey: AUTH_SECRET_KEY, generate: install, length: 64, requires: external}
{{- end }}

{{/*
MCP OAuth issuer, shared by the authorization server (the control-plane app) and
by TrustGate as its client. Both sides derive it from the same helper because a
mismatch is silent until TrustGate tries to fetch JWKS from an issuer nobody
serves. Derived from `global` alone, since a subchart cannot read a sibling's
values — so an install that moves the app off the default host has to set
global.mcpOAuth.issuer explicitly (full URL, including the path).
*/}}
{{- define "neuraltrust-platform.mcpOAuth.issuer" -}}
{{- $mcp := default dict (default dict .Values.global).mcpOAuth -}}
{{- $explicit := $mcp.issuer | default "" -}}
{{- if $explicit -}}
{{- trimSuffix "/" $explicit -}}
{{- else -}}
{{- $domain := include "neuraltrust-platform.domain" . -}}
{{- if not $domain -}}
{{- fail "global.mcpOAuth.enabled needs global.domain to build the issuer URL, or an explicit global.mcpOAuth.issuer" -}}
{{- end -}}
{{- $host := printf "app.%s" $domain -}}
{{- if eq (include "neuraltrust-platform.isOpenshift" .) "true" -}}
{{- $host = printf "control-plane-app.%s" $domain -}}
{{- end -}}
{{- printf "https://%s/api/mcp/oauth" $host -}}
{{- end -}}
{{- end }}

{{/*
Whether a stable MCP OAuth signing key is available to this install, checked
against the same sources the shared Secret resolves from: an explicit pin, the
live `platform-secrets`, an operator-owned Secret, and the legacy Secret the key
used to live in.

The app mints an ephemeral key per replica when the key is unset, so tokens one
replica signs fail JWKS verification against another. That makes "is a key
available" the real precondition for the feature, not the operator's intent.
*/}}
{{- define "neuraltrust-platform.mcpOAuth.signingKeyPresent" -}}
{{- $ps := default dict (default dict .Values.global).platformSecret -}}
{{- $pinned := index (default dict $ps.values) "MCP_OAUTH_SIGNING_KEY" | default "" -}}
{{- if and $pinned (not (kindIs "map" $pinned)) (not (kindIs "slice" $pinned)) -}}
true
{{- else -}}
{{- $found := "" -}}
{{- range $name := (list "platform-secrets" ((default dict $ps.existingSecret).name | default "") "control-plane-secrets") -}}
{{- if and $name (not $found) -}}
{{- $live := lookup "v1" "Secret" $.Release.Namespace $name -}}
{{- if and $live $live.data (index $live.data "MCP_OAUTH_SIGNING_KEY") -}}
{{- $found = "true" -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $found -}}
{{- end -}}
{{- end }}

{{/*
The operator's intent for MCP OAuth, normalised to "on", "off" or "auto".

Exists because `enabled` is read in two places — this helper family and
validate-values — and a raw `kindIs "bool"` test disagrees with Go truthiness for
a string. That is not exotic: a Flux HelmRelease sourcing values from a ConfigMap
yields every value as a string, as does Helmfile templating, so `enabled: "false"`
would otherwise turn the feature ON in external and get a hybrid install rejected
for disabling it.

Anything that is neither truthy nor falsy fails loudly rather than being guessed at.
*/}}
{{- define "neuraltrust-platform.mcpOAuth.intent" -}}
{{- $mcp := default dict (default dict .Values.global).mcpOAuth -}}
{{- $raw := $mcp.enabled -}}
{{- if kindIs "invalid" $raw -}}
auto
{{- else if kindIs "bool" $raw -}}
{{- if $raw }}on{{ else }}off{{ end -}}
{{- else -}}
{{- $v := toString $raw | trim | lower -}}
{{- if eq $v "" -}}
auto
{{- else if has $v (list "true" "yes" "on" "1") -}}
on
{{- else if has $v (list "false" "no" "off" "0") -}}
off
{{- else -}}
{{- fail (printf "global.mcpOAuth.enabled must be true, false, or unset for automatic (got %q). Leave it unset to have MCP OAuth follow the deployment mode." $raw) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Whether the chart can actually deliver `MCP_OAUTH_CLIENT_SECRET` to both sides.

The app and TrustGate must hold the same client secret, and both read it from the
Secret `secretRef` resolves to. When the shared Secret is out of play — through
platformSecret.enabled=false, preserveExistingSecrets, or autoGenerateSecrets=false
— those refs fall back to legacy per-service Secrets that this chart never writes
this key into. The refs are `optional`, so the env is simply absent and the login
fails at request time with nothing pointing at the cause.

An operator-owned `existingSecret` is a separate case: it may well carry the key,
but the chart cannot see inside it, so it does not auto-enable on that basis.
*/}}
{{- define "neuraltrust-platform.mcpOAuth.clientSecretDeliverable" -}}
{{- $shared := default dict (default dict .Values.global).platformSecret -}}
{{- $existing := default dict $shared.existingSecret -}}
{{- if and (include "neuraltrust-platform.platformSecret.name" .) (not $existing.name) -}}
true
{{- end -}}
{{- end }}

{{/*
Callback origins the app will accept, shared by the app deployment and by
validate-values so the two cannot disagree about whether one exists.

Empty is dangerous rather than merely unset: the app treats an empty allowlist as
"any https origin", which turns the authorization-code redirect into an open
redirect. Callers must refuse to enable the feature without one.
*/}}
{{- define "neuraltrust-platform.mcpOAuth.allowedRedirectHosts" -}}
{{- $mcp := default dict (default dict .Values.global).mcpOAuth -}}
{{- $hosts := $mcp.allowedRedirectHosts | default "" -}}
{{- if $hosts -}}
{{- $hosts -}}
{{- else -}}
{{- $domain := include "neuraltrust-platform.domain" . -}}
{{- if $domain }}{{- printf "https://*.mcp.%s" $domain -}}{{- end -}}
{{- end -}}
{{- end }}

{{/*
Name of the hook-owned Secret holding the generated signing key. Deliberately
separate from `platform-secrets`: the generator runs as a pre-install hook, before
Helm has created any manifest, so writing into the chart-owned Secret would
collide with Helm's ownership metadata on a fresh install.
*/}}
{{- define "neuraltrust-platform.mcpOAuth.generatedSecretName" -}}
mcp-oauth-signing
{{- end }}

{{/*
Whether the chart generates the signing key itself, via the pre-install hook in
templates/mcp-oauth-signing-key.yaml.

On when nothing else provides a key, so a fresh external install gets MCP OAuth
with no operator action. Off as soon as the operator supplies one, leaving their
key untouched, and off when they set global.mcpOAuth.generateSigningKey=false to
own the key themselves.

Must not call mcpOAuth.enabled — that helper calls this one to decide whether a
key will exist.
*/}}
{{- define "neuraltrust-platform.mcpOAuth.generateSigningKey" -}}
{{- $mcp := default dict (default dict .Values.global).mcpOAuth -}}
{{- $wanted := true -}}
{{- if kindIs "bool" $mcp.generateSigningKey -}}{{- $wanted = $mcp.generateSigningKey -}}{{- end -}}
{{- if eq (include "neuraltrust-platform.mcpOAuth.intent" .) "off" -}}{{- $wanted = false -}}{{- end -}}
{{- /* No point minting a signing key when the client secret cannot reach both
       sides: the login would fail anyway, and the Job would leave a credential
       nobody reads. */ -}}
{{- if ne (include "neuraltrust-platform.mcpOAuth.clientSecretDeliverable" .) "true" -}}{{- $wanted = false -}}{{- end -}}
{{- if and $wanted
      (eq (include "neuraltrust-platform.isExternal" .) "true")
      (ne (include "neuraltrust-platform.mcpOAuth.signingKeyPresent" .) "true") -}}
true
{{- end -}}
{{- end }}

{{/*
Where the app reads its signing key from. The generated Secret when the chart owns
the key, otherwise the usual shared-or-legacy resolution.

An operator who later pins their own key moves this reference to
`platform-secrets` and orphans the generated Secret. That is a key rotation and
invalidates tokens signed by the old key, which is why nothing does it implicitly.
*/}}
{{- define "neuraltrust-platform.mcpOAuth.signingKeyRef" -}}
{{- if eq (include "neuraltrust-platform.mcpOAuth.generateSigningKey" .) "true" -}}
name: {{ include "neuraltrust-platform.mcpOAuth.generatedSecretName" . | quote }}
key: "MCP_OAUTH_SIGNING_KEY"
optional: true
{{- else -}}
{{- include "neuraltrust-platform.secretRef" (dict "ctx" . "logical" "MCP_OAUTH_SIGNING_KEY" "optional" true) -}}
{{- end -}}
{{- end }}

{{/*
Whether MCP OAuth is active. Three-state, because the operator's intent and the
material needed to honour it are separate questions:

  unset  → auto. On in external, because the chart generates the signing key when
           nothing else provides one. Off if the operator disabled the generator
           and supplied no key of their own.
  true   → required. Fails the render when no signing key is available, rather
           than silently serving logins that fail on half the replicas.
  false  → never.

Always off in hybrid: the authorization server is the control-plane app, which a
hybrid install does not deploy. An explicit `true` there is rejected by
validate-values with a message about the mode, so this helper stays silent.
*/}}
{{- define "neuraltrust-platform.mcpOAuth.enabled" -}}
{{- $intent := include "neuraltrust-platform.mcpOAuth.intent" . -}}
{{- $explicit := eq $intent "on" -}}
{{- if eq $intent "off" -}}
{{- else if ne (include "neuraltrust-platform.isExternal" .) "true" -}}
{{- /* Both sides must read one client secret from a Secret this chart writes. */ -}}
{{- else if ne (include "neuraltrust-platform.mcpOAuth.clientSecretDeliverable" .) "true" -}}
{{- if $explicit -}}
{{- fail "global.mcpOAuth.enabled=true cannot be honoured while the shared platform Secret is out of play: platformSecret.enabled=false, preserveExistingSecrets, autoGenerateSecrets=false, or an operator-owned platformSecret.existingSecret all leave MCP_OAUTH_CLIENT_SECRET pointing at a legacy Secret this chart never writes it into, so the app and TrustGate would never agree on a client secret and every login would fail. Enable the shared Secret, or add MCP_OAUTH_CLIENT_SECRET and MCP_OAUTH_SIGNING_KEY to your own Secret and wire them through extraEnv." -}}
{{- end -}}
{{- else if not (include "neuraltrust-platform.mcpOAuth.allowedRedirectHosts" .) -}}
{{- /* An empty allowlist means the app accepts a callback on any https origin. */ -}}
{{- if $explicit -}}
{{- fail "global.mcpOAuth.enabled=true needs a callback allowlist: with none the app accepts an OAuth redirect to ANY https origin, which hands the authorization code to whoever asks. Set global.mcpOAuth.allowedRedirectHosts (e.g. \"https://*.mcp.example.com\"), or set global.domain so it can be derived." -}}
{{- end -}}
{{- else if eq (include "neuraltrust-platform.mcpOAuth.signingKeyPresent" .) "true" -}}
true
{{- else if eq (include "neuraltrust-platform.mcpOAuth.generateSigningKey" .) "true" -}}
{{- /* The pre-install hook writes the key before any pod starts. */ -}}
true
{{- else if $explicit -}}
{{- fail "global.mcpOAuth.enabled=true needs an RS256 signing key, but global.mcpOAuth.generateSigningKey=false leaves the chart unable to create one: every app replica would sign with its own ephemeral key and MCP logins would fail JWKS verification. Either drop generateSigningKey=false to have the chart generate the key, or supply your own as global.platformSecret.values.MCP_OAUTH_SIGNING_KEY (see SECRETS.md)." -}}
{{- end -}}
{{- end }}

{{/*
TrustGate's built-in default identity provider for MCP consumers, with the
control-plane app as the OAuth2 authorization server. Lets an MCP consumer log in
without the operator standing up an identity provider first.

External only. A hybrid install has no control-plane app — it talks to the hosted
platform — so there is no in-cluster issuer to point at and no client secret the
two sides could agree on locally.

Only the MCP plane brokers these logins, so this stays an explicit env block on
that workload rather than joining the ConfigMap every agentgateway pod reads —
otherwise admin and proxy would advertise an IdP they hold no client secret for.

AUTHORIZE_URL / TOKEN_URL / JWKS_URL are deliberately left unset: TrustGate
derives them as {issuer}/authorize, /token and /jwks, which is what the app
serves.

Usage:
  {{- include "neuraltrust-platform.mcpDefaultIdpEnv" (dict "ctx" . "skip" .Values.mcp.extraEnv) | nindent 8 }}
*/}}
{{- define "neuraltrust-platform.mcpDefaultIdpEnv" -}}
{{- $ctx := .ctx -}}
{{- $skip := list -}}
{{- range (default list .skip) }}
  {{- if .name }}{{- $skip = append $skip .name }}{{- end }}
{{- end }}
{{- $mcp := default dict (default dict $ctx.Values.global).mcpOAuth -}}
{{- /* External only, and only once a signing key exists: in hybrid the
       authorization server is the hosted platform, not an app this chart deploys,
       so there is nothing in-cluster to point at and no shared client secret to
       agree on. */ -}}
{{- if eq (include "neuraltrust-platform.mcpOAuth.enabled" $ctx) "true" }}
{{- if not (has "MCP_DEFAULT_IDP_ISSUER" $skip) }}
- name: MCP_DEFAULT_IDP_ISSUER
  value: {{ include "neuraltrust-platform.mcpOAuth.issuer" $ctx | quote }}
{{- end }}
{{- if not (has "MCP_DEFAULT_IDP_CLIENT_ID" $skip) }}
- name: MCP_DEFAULT_IDP_CLIENT_ID
  value: {{ $mcp.clientId | default "trustgate" | quote }}
{{- end }}
{{- with $mcp.audience }}
{{- if not (has "MCP_DEFAULT_IDP_AUDIENCE" $skip) }}
- name: MCP_DEFAULT_IDP_AUDIENCE
  value: {{ . | quote }}
{{- end }}
{{- end }}
{{- with $mcp.scopes }}
{{- if not (has "MCP_DEFAULT_IDP_SCOPES" $skip) }}
- name: MCP_DEFAULT_IDP_SCOPES
  value: {{ . | quote }}
{{- end }}
{{- end }}
{{- /* Same value the app reads as MCP_OAUTH_CLIENT_SECRET. Optional so the pod
       still starts while an operator is mid-migration on the Secret. */}}
{{- if not (has "MCP_DEFAULT_IDP_CLIENT_SECRET" $skip) }}
- name: MCP_DEFAULT_IDP_CLIENT_SECRET
  valueFrom:
    secretKeyRef:
      {{- include "neuraltrust-platform.secretRef" (dict "ctx" $ctx "logical" "MCP_OAUTH_CLIENT_SECRET" "optional" true) | nindent 6 }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Name of the Secret that holds the shared platform credentials.
Empty when the shared Secret is not in play, which tells `secretRef` to fall
back to the legacy per-service Secret.
*/}}
{{- define "neuraltrust-platform.platformSecret.name" -}}
{{- $global := default dict .Values.global -}}
{{- $shared := default dict $global.platformSecret -}}
{{- $existing := default dict $shared.existingSecret -}}
{{- $enabled := true -}}
{{- if hasKey $shared "enabled" }}{{- $enabled = $shared.enabled }}{{- end }}
{{- /* With preserveExistingSecrets the operator pre-creates the per-service
       Secrets, so redirecting consumers would point them at a Secret nobody
       created. Keep the legacy contract for those installs. */}}
{{- if $global.preserveExistingSecrets }}{{- $enabled = false }}{{- end }}
{{- /* Same reasoning for autoGenerateSecrets=false: the chart mints nothing, so
       there is no `platform-secrets` to point at. An operator-supplied Secret is
       exempt — they created it themselves, so it exists either way. */}}
{{- if and (not $existing.name) (ne (include "neuraltrust-platform.autoGenerateSecrets" .) "true") }}
  {{- $enabled = false }}
{{- end }}
{{- if not $enabled }}
{{- else if $existing.name }}{{- $existing.name -}}
{{- else -}}platform-secrets{{- end }}
{{- end }}

{{/*
Resolve a logical shared-secret key to the `name`/`key` pair a `secretKeyRef`
needs. Returns the shared Secret when it is in play, else the legacy
per-service Secret, so the same call site works before and after migration.

Usage:
  valueFrom:
    secretKeyRef:
      {{- include "neuraltrust-platform.secretRef" (dict "ctx" . "logical" "SERVER_SECRET_KEY") | nindent 6 }}
*/}}
{{- define "neuraltrust-platform.secretRef" -}}
{{- $ctx := .ctx -}}
{{- $logical := .logical -}}
{{- $registry := fromYaml (include "neuraltrust-platform.platformSecret.registry" $ctx) -}}
{{- $entry := index $registry $logical -}}
{{- if not $entry }}{{- fail (printf "neuraltrust-platform.secretRef: unknown logical secret %q" $logical) }}{{- end }}
{{- $shared := include "neuraltrust-platform.platformSecret.name" $ctx -}}
{{- if $shared -}}
name: {{ $shared | quote }}
key: {{ $logical | quote }}
{{- else -}}
name: {{ $entry.legacyName | quote }}
key: {{ $entry.legacyKey | quote }}
{{- end }}
{{- if .optional }}
optional: true
{{- end }}
{{- end }}

{{/*
Emit `env` entries sourcing shared credentials from `platform-secrets`.

Services whose Deployment `envFrom`s a legacy per-service Secret still receive
the legacy copy of a migrated key. An explicit `env` entry takes precedence over
`envFrom` in Kubernetes, so adding one here makes `platform-secrets` the value
the container actually sees, while the legacy Secret stays in place for rollback.

Emits nothing when the shared Secret is not in play, leaving those installs on
the legacy contract unchanged.

Usage:
  {{- include "neuraltrust-platform.platformSecretEnv" (dict "ctx" . "keys" (dict "JWT_SECRET" "TRUSTLENS_JWT_SECRET") "skip" .Values.extraEnv) | nindent 8 }}

  keys: envVarName → logical shared key
  skip: optional list of `{name: ...}` env entries (e.g. an operator's extraEnv)
        whose names must not be emitted, so an operator override still wins and
        the Deployment never carries a duplicate env name.
*/}}
{{- define "neuraltrust-platform.platformSecretEnv" -}}
{{- $ctx := .ctx -}}
{{- $skip := list -}}
{{- range (default list .skip) }}
  {{- if .name }}{{- $skip = append $skip .name }}{{- end }}
{{- end }}
{{- if include "neuraltrust-platform.platformSecret.name" $ctx }}
{{- range $envName, $logical := .keys }}
{{- if not (has $envName $skip) }}
- name: {{ $envName }}
  valueFrom:
    secretKeyRef:
      {{- include "neuraltrust-platform.secretRef" (dict "ctx" $ctx "logical" $logical) | nindent 6 }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
