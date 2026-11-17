{{/*
True when TrustGate (AgentGateway) templates should render.
Hybrid: global.products.trustgate must be true. External: on unless global.products.trustgate=false.
*/}}
{{- define "agentgateway.enabled" -}}
{{- if eq (include "neuraltrust-platform.product.enabled" (dict "ctx" . "product" "trustgate")) "true" -}}true{{- end -}}
{{- end }}

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
Accepts a string or a list of strings/maps. Emits nothing when unset, "" or "none".

Delegates to the umbrella resolver (AUT-427). This body used to be one of nine
byte-identical copies, and every copy dropped the "none" check in the list branch
-- so global.imagePullSecrets: ["none"] rendered a phantom `- name: none` despite
the line above promising otherwise. Keep the wrapper: the name is what templates
call, and it keeps the value key local to this chart.
Usage: {{- include "agentgateway.imagePullSecrets" . | nindent 6 }}
*/}}
{{- define "agentgateway.imagePullSecrets" -}}
{{- include "neuraltrust-platform.subchart.imagePullSecrets" (dict "local" .Values.imagePullSecrets "global" .Values.global) -}}
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
global.ingress.provider=gateway-api overrides all three: HTTPRoutes only.
*/}}
{{- define "agentgateway.ingress.useIngress" -}}
{{- $rt := (.Values.ingress.resourceType | default "auto") -}}
{{- if include "neuraltrust-platform.ingress.gatewayApi" (dict "global" .Values.global) -}}
{{- else if eq $rt "ingress" -}}
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
{{- if and .Values.ingress.enabled (include "neuraltrust-platform.isOpenshift" .) (not (include "neuraltrust-platform.ingress.gatewayApi" (dict "global" .Values.global))) -}}
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

{{/*
AWS region for RDS IAM token minting. Subchart value wins, else the umbrella's
global.postgresql.awsRegion, so one setting covers every IAM-authenticated
service instead of being repeated per chart.
*/}}
{{- define "agentgateway.awsRegion" -}}
{{- $global := default dict (default dict .Values.global).postgresql -}}
{{- (default dict .Values.database).awsRegion | default $global.awsRegion | default "" -}}
{{- end }}

{{/*
config-sync gRPC TLS: fixed secret name, mount path and verified server name.
The control plane's config-sync gRPC listener REQUIRES TLS (cert+key) whenever
APP_ENV is a deployed environment (prod/production/staging/stage); the data plane
verifies the listener against the generated CA using this DNS server name.
Mirrors the TrustGuard implementation so both gateways behave identically.
*/}}
{{- define "agentgateway.configSyncTls.secretName" -}}
{{- $tls := (default dict .Values.configSync).grpcTls | default dict -}}
{{- if eq (include "agentgateway.configSyncTls.generated" .) "true" -}}
{{- include "neuraltrust-platform.secretsGenerator.tlsName" (dict "id" "agentgateway-configsync") -}}
{{- else -}}
{{- $tls.existingSecret | default "agentgateway-configsync-tls" -}}
{{- end -}}
{{- end }}

{{/*
Whether the in-cluster secrets generator issues the config-sync keypair instead
of this chart rendering it: the chart would generate it here (active,
autoGenerate, no existingSecret). A published listener's CA is handed to other
clusters out of band (scripts/export-controlplane-ca.sh), which reads the
Secret by the same name either way; the generator reissues it only when the
names it covers change, as the rendered one was.
*/}}
{{- define "agentgateway.configSyncTls.generated" -}}
{{- $tls := (default dict .Values.configSync).grpcTls | default dict -}}
{{- if and
  (eq (include "neuraltrust-platform.secretsGenerator.active" .) "true")
  (eq (include "agentgateway.configSyncTls.active" .) "true")
  (eq (include "agentgateway.configSyncTls.autoGenerate" .) "true")
  (not ($tls.existingSecret | default "")) -}}true{{- end -}}
{{- end }}

{{- define "agentgateway.configSyncTls.mountPath" -}}/etc/agentgateway/configsync-tls{{- end }}

{{- define "agentgateway.configSyncTls.serverName" -}}
{{- printf "%s.%s.svc.cluster.local" .Values.controlPlane.name .Release.Namespace -}}
{{- end }}

{{/*
Whether the chart generates the keypair. Resolved through hasKey because sprig's
`default` treats boolean false as empty, so `autoGenerate | default true` would
read an explicit false back as true.
*/}}
{{- define "agentgateway.configSyncTls.autoGenerate" -}}
{{- $tls := (default dict .Values.configSync).grpcTls | default dict -}}
{{- if hasKey $tls "autoGenerate" -}}
{{- if $tls.autoGenerate }}true{{- end -}}
{{- else -}}
true
{{- end -}}
{{- end }}

{{/*
Returns "true" (non-empty) when the config-sync gRPC listener must run with TLS:
external/full + a deployed APP_ENV. In that case the chart provisions a server
cert/key (auto-generated CA, or an operator-provided existingSecret).

TrustGate enforces both halves of this: the control plane refuses to build its
listener without cert+key, and the data plane refuses to start with
CONFIG_SYNC_TLS_INSECURE=true, once APP_ENV is deployed.
*/}}
{{- define "agentgateway.configSyncTls.active" -}}
{{- $isExternal := eq (include "neuraltrust-platform.isExternal" .) "true" -}}
{{- $appEnv := lower (trim (.Values.config.appEnv | default "")) -}}
{{- $deployed := has $appEnv (list "prod" "production" "staging" "stage") -}}
{{- $tls := (default dict .Values.configSync).grpcTls | default dict -}}
{{- $provisioned := or ($tls.existingSecret | default "") (eq (include "agentgateway.configSyncTls.autoGenerate" .) "true") -}}
{{- if and $isExternal $deployed $provisioned }}true{{- end -}}
{{- end }}

{{/*
Env entries for datastore credentials the operator pre-created (AUT-411).

Hybrid takes both passwords wholesale from the shared `postgresql-secrets` /
`redis-secrets`, and IAM auth mints a token per connection, so neither case has a
static password to point at. Emits nothing unless an `existingSecret.name` is set.
*/}}
{{- define "agentgateway.datastoreCredentialEnv" -}}
{{- $entries := list -}}
{{- if ne (include "neuraltrust-platform.isHybrid" .) "true" -}}
{{- if ne (include "neuraltrust-platform.postgres.iamAuth" (dict "ctx" . "database" .Values.database)) "true" -}}
{{- $db := include "neuraltrust-platform.datastore.credentialEnv" (dict "ref" (include "neuraltrust-platform.dbPasswordRef" (dict "ctx" . "db" .Values.database "key" "AGENTGATEWAY_DB_PASSWORD") | fromYaml) "envName" "DB_PASSWORD") -}}
{{- if $db }}{{- $entries = append $entries $db }}{{- end -}}
{{- end -}}
{{- if not .Values.redis.iamAuth -}}
{{- $redis := include "neuraltrust-platform.datastore.credentialEnv" (dict "ref" (include "neuraltrust-platform.redis.passwordRef" (dict "ctx" . "redis" .Values.redis) | fromYaml) "envName" "REDIS_PASSWORD") -}}
{{- if $redis }}{{- $entries = append $entries $redis }}{{- end -}}
{{- end -}}
{{- end -}}
{{- /* agentgateway-secrets no longer carries the STS key under the generator,
       so read it from the generated Secret instead of through envFrom. */ -}}
{{- if eq (include "agentgateway.stsSigningKey.generated" .) "true" -}}
{{- $entries = append $entries (include "neuraltrust-platform.datastore.credentialEnv" (dict "ref" (dict "name" (include "neuraltrust-platform.secretsGenerator.name" .) "key" "STS_SIGNING_KEY") "envName" "STS_SIGNING_KEY")) -}}
{{- end -}}
{{- join "\n" $entries -}}
{{- end }}

{{/*
"true" when the data plane authenticates to the firewall with its own OAuth
client (firewall.jwt or firewall.existingSecret.name) instead of the shared
firewall JWT_SECRET.
*/}}
{{- define "agentgateway.firewallJwt.configured" -}}
{{- $fw := default dict .Values.firewall -}}
{{- if or $fw.jwt (default dict $fw.existingSecret).name -}}true{{- end -}}
{{- end }}

{{/*
FIREWALL_JWT env entry for an operator-managed Secret. An inline firewall.jwt
reaches the pod through agentgateway-secrets (envFrom) instead. Fails the render
on an ambiguous or unstorable configuration.
*/}}
{{- define "agentgateway.firewallJwtEnv" -}}
{{- $fw := default dict .Values.firewall -}}
{{- $es := default dict $fw.existingSecret -}}
{{- if and $fw.jwt $es.name -}}
{{- fail "agentgateway.firewall: set jwt or existingSecret.name, not both" -}}
{{- end -}}
{{- if and $fw.jwt (not (and (include "neuraltrust-platform.autoGenerateSecrets" .) (not .Values.global.preserveExistingSecrets))) -}}
{{- fail "agentgateway.firewall.jwt is stored in agentgateway-secrets, which this chart only writes while global.autoGenerateSecrets=true and global.preserveExistingSecrets=false: put the FIREWALL_JWT the console showed in a Secret and set agentgateway.firewall.existingSecret.name instead" -}}
{{- end -}}
{{- with $es.name }}
- name: FIREWALL_JWT
  valueFrom:
    secretKeyRef:
      name: {{ . | quote }}
      key: {{ $es.key | default "FIREWALL_JWT" | quote }}
{{- end -}}
{{- end }}

{{/*
Operational traces and metrics (the gateway's own server spans and RED
metrics), sent to the same collector as product logs. The binary defaults both
switches off, and an enabled signal with no endpoint fails startup, so the
switches and endpoints always render together. Takes the collector base URL.
Rendered only when global.observability.operationalTelemetry is true.
*/}}
{{- define "agentgateway.opsTelemetryEnv" -}}
OPS_TRACES_ENABLED: "true"
OPS_TRACES_SAMPLING_RATIO: "1.0"
OPS_TRACES_PROBE_SAMPLING_RATIO: "0.01"
OTEL_EXPORTER_OTLP_TRACES_ENDPOINT: {{ printf "%s/v1/traces" . | quote }}
OPS_METRICS_ENABLED: "true"
OTEL_EXPORTER_OTLP_METRICS_ENDPOINT: {{ printf "%s/v1/metrics" . | quote }}
{{ end }}

{{/*
Whether the in-cluster secrets generator owns STS_SIGNING_KEY. The chart could
only adopt a live key through lookup, so under `helm template` it minted a new
one on every render and every MCP session token stopped verifying.
*/}}
{{- define "agentgateway.stsSigningKey.generated" -}}
{{- if eq (include "neuraltrust-platform.secretsGenerator.active" .) "true" -}}true{{- end -}}
{{- end }}

{{/*
Secret stores (secretStores.*). The stores are rendered into the TrustGate
store file, mounted as a directory so the binary's watcher sees ConfigMap
updates without a pod roll. Credentials never go in values: each *Secret
field names a Kubernetes Secret, mounted read-only and written into the store
file as the matching *_file path. NeuralTrust-hosted dedicated planes never
load a store file.
*/}}
{{- define "agentgateway.secretStores.enabled" -}}
{{- if gt (len (default list (default dict .Values.secretStores).stores)) 0 }}true{{- end }}
{{- end }}

{{- define "agentgateway.secretStores.configMapName" -}}agentgateway-secret-stores{{- end }}
{{- define "agentgateway.secretStores.fileDir" -}}/etc/trustgate/secret-stores{{- end }}
{{- define "agentgateway.secretStores.credentialsDir" -}}/etc/trustgate/secret-store-credentials{{- end }}

{{/*
Which gateways may hold secret references: hybrid where NeuralTrust runs the
control plane, all where the customer runs every plane (external, saas).
*/}}
{{- define "agentgateway.secretStores.gateways" -}}
{{- $v := toString (default "" (default dict .Values.secretStores).gateways) }}
{{- if $v }}
{{- if not (has $v (list "hybrid" "all")) }}
{{- fail (printf "agentgateway.secretStores.gateways must be \"hybrid\" or \"all\" (got %q)" $v) }}
{{- end }}
{{- $v }}
{{- else if eq (include "neuraltrust-platform.isExternal" .) "true" }}all
{{- else }}hybrid
{{- end }}
{{- end }}

{{/*
Builds the store file from secretStores.stores and returns YAML with "file"
(the store file document) and "mounts" (the credential Secrets to mount).
The chart checks only what it generates itself: the store name (it becomes a
mount path), inline credentials (they would land in a ConfigMap) and the
*Secret translation. Every other setting passes through in snake_case and is
validated by TrustGate, which decodes the file strictly and refuses to start
on an invalid one, so new TrustGate settings need no chart change.
*/}}
{{- define "agentgateway.secretStores.compiled" -}}
{{- if eq (include "neuraltrust-platform.isDedicated" .) "true" }}
{{- fail "agentgateway.secretStores is not available with global.deploymentMode=dedicated: dedicated planes run on NeuralTrust infrastructure and never load a store file" }}
{{- end }}
{{- $credDir := include "agentgateway.secretStores.credentialsDir" . }}
{{- $stores := list }}
{{- $acc := dict "mounts" list }}
{{- $names := dict }}
{{- range $i, $s := (default list (default dict .Values.secretStores).stores) }}
{{- if not (kindIs "map" $s) }}
{{- fail (printf "agentgateway.secretStores.stores[%d] must be a map" $i) }}
{{- end }}
{{- $name := toString (default "" $s.name) }}
{{- if not (regexMatch "^[a-z0-9][a-z0-9_-]{0,62}$" $name) }}
{{- fail (printf "agentgateway.secretStores.stores[%d].name %q must be 1-63 characters of [a-z0-9_-] starting with a letter or digit" $i $name) }}
{{- end }}
{{- if hasKey $names $name }}
{{- fail (printf "agentgateway.secretStores.stores: store %q is declared twice" $name) }}
{{- end }}
{{- $_ := set $names $name true }}
{{- $o := dict }}
{{- $_ := include "agentgateway.secretStores.walk" (dict "src" $s "dst" $o "acc" $acc "index" $i "dir" (printf "%s/%s" $credDir $name) "where" (printf "agentgateway.secretStores.stores[%s]" $name)) }}
{{- $stores = append $stores $o }}
{{- end }}
{{- toYaml (dict "file" (dict "version" 1 "stores" $stores) "mounts" $acc.mounts) }}
{{- end }}

{{/*
Copies one level of a store into the store file, recursing into maps. Keys
become snake_case. <x>Secret: {name, key} mounts that Secret key read-only
and writes <x>_file (caCertSecret → ca_cert_file, tokenSecret → token_file,
...); the key defaults to ca.crt for caCert and to the kebab-case name
otherwise. existingSecret mounts a whole Secret and writes root (file stores).
*/}}
{{- define "agentgateway.secretStores.walk" -}}
{{- $a := . }}
{{- range $k, $v := $a.src }}
{{- $where := printf "%s.%s" $a.where $k }}
{{- if has (snakecase $k) (list "token" "secret_id" "jwt" "password" "api_key" "client_secret") }}
{{- fail (printf "%s must not be written inline: name a Kubernetes Secret with the matching *Secret field (tokenSecret, secretIdSecret, apiKeySecret, jwtSecret) or use workload identity" $where) }}
{{- else if eq $k "existingSecret" }}
{{- if hasKey $a.src "root" }}
{{- fail (printf "%s and root are mutually exclusive" $where) }}
{{- end }}
{{- if not (and (kindIs "string" $v) $v) }}
{{- fail (printf "%s must name a Kubernetes Secret" $where) }}
{{- end }}
{{- $dir := printf "%s/files" $a.dir }}
{{- $_ := set $a.dst "root" $dir }}
{{- $_ := set $a.acc "mounts" (append $a.acc.mounts (dict "volume" (printf "secret-store-%d-files" (int $a.index)) "secretName" $v "mountPath" $dir)) }}
{{- else if hasSuffix "Secret" $k }}
{{- $field := trimSuffix "Secret" $k }}
{{- if hasKey $a.src (printf "%sFile" $field) }}
{{- fail (printf "%s and %sFile are mutually exclusive" $where $field) }}
{{- end }}
{{- if or (not (kindIs "map" $v)) (not $v.name) }}
{{- fail (printf "%s needs the name of a Kubernetes Secret: {name: <secret>, key: <key>}" $where) }}
{{- end }}
{{- $sub := kebabcase $field }}
{{- $key := toString (default (ternary "ca.crt" $sub (eq $field "caCert")) $v.key) }}
{{- $dir := printf "%s/%s" $a.dir $sub }}
{{- $_ := set $a.dst (printf "%s_file" (snakecase $field)) (printf "%s/%s" $dir $key) }}
{{- $_ := set $a.acc "mounts" (append $a.acc.mounts (dict "volume" (printf "secret-store-%d-%s" (int $a.index) $sub) "secretName" $v.name "key" $key "mountPath" $dir)) }}
{{- else if kindIs "map" $v }}
{{- $child := dict }}
{{- $_ := set $a.dst (snakecase $k) $child }}
{{- $_ := include "agentgateway.secretStores.walk" (dict "src" $v "dst" $child "acc" $a.acc "index" $a.index "dir" $a.dir "where" $where) }}
{{- else }}
{{- $_ := set $a.dst (snakecase $k) $v }}
{{- end }}
{{- end }}
{{- end }}

{{/* Env for a workload that loads the store file; empty without stores. */}}
{{- define "agentgateway.secretStores.env" -}}
{{- if eq (include "agentgateway.secretStores.enabled" .) "true" }}
{{- $cfg := .Values.secretStores }}
- name: SECRET_STORES_FILE
  value: {{ printf "%s/stores.yaml" (include "agentgateway.secretStores.fileDir" .) | quote }}
- name: SECRET_STORES_GATEWAYS
  value: {{ include "agentgateway.secretStores.gateways" . | quote }}
{{- range $k, $env := dict "fetchTimeout" "SECRET_STORES_FETCH_TIMEOUT" "refreshInterval" "SECRET_STORES_REFRESH_INTERVAL" "probeInterval" "SECRET_STORES_PROBE_INTERVAL" }}
{{- with get $cfg $k }}
- name: {{ $env }}
  value: {{ . | toString | quote }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{- define "agentgateway.secretStores.volumes" -}}
{{- if eq (include "agentgateway.secretStores.enabled" .) "true" }}
{{- $c := include "agentgateway.secretStores.compiled" . | fromYaml }}
- name: secret-stores
  configMap:
    name: {{ include "agentgateway.secretStores.configMapName" . }}
{{- range $c.mounts }}
- name: {{ .volume }}
  secret:
    secretName: {{ .secretName | quote }}
    {{- with .key }}
    items:
    - key: {{ . | quote }}
      path: {{ . | quote }}
    {{- end }}
{{- end }}
{{- end }}
{{- end }}

{{- define "agentgateway.secretStores.volumeMounts" -}}
{{- if eq (include "agentgateway.secretStores.enabled" .) "true" }}
{{- $c := include "agentgateway.secretStores.compiled" . | fromYaml }}
- name: secret-stores
  mountPath: {{ include "agentgateway.secretStores.fileDir" . | quote }}
  readOnly: true
{{- range $c.mounts }}
- name: {{ .volume }}
  mountPath: {{ .mountPath | quote }}
  readOnly: true
{{- end }}
{{- end }}
{{- end }}
