#!/usr/bin/env bash
# Render scenarios 1, 1b, 1b2, 1c, 1c2. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"

# ---------------------------------------------------------------------------
# 1. Minimal v2 hybrid — shared PG/Redis + enrolment-backed ClickStack egress
# ---------------------------------------------------------------------------
blue "==> Scenario 1: minimal v2 hybrid (shared PG/Redis + ClickStack egress)"
out1="$TMP/scenario-hybrid-minimal.yaml"
render_default "$out1"

assert_contains "$out1" 'kind: Deployment' \
  "hybrid: at least one Deployment renders"
assert_contains "$out1" 'name: control-plane-postgresql' \
  "hybrid: in-cluster PostgreSQL Deployment/Service"
# Private AR postgres image must default to gcr-secret (same as Redis).
assert_contains "$out1" 'app: control-plane-postgresql'$'\n''    spec:'$'\n''      securityContext:' \
  "hybrid: postgresql pod template present"
assert_contains "$out1" 'runAsNonRoot: true'$'\n''      imagePullSecrets:'$'\n''        - name: gcr-secret' \
  "hybrid: postgresql Deployment defaults imagePullSecrets to gcr-secret"
assert_contains "$out1" 'name: postgresql-secrets' \
  "hybrid: postgresql-secrets rendered"
# postgresql-secrets stores ONE canonical family. The DB_* and DATABASE_* aliases it
# used to store are renamed at each consumption site instead, so storage cannot
# drift from what any single service reads.
assert_secret_keys "$out1" postgresql-secrets present \
  "hybrid: postgresql-secrets stores canonical" \
  POSTGRES_HOST POSTGRES_PORT POSTGRES_USER POSTGRES_PASSWORD \
  POSTGRES_DB POSTGRES_SSLMODE POSTGRES_LOGIN POSTGRES_AUTH_MODE \
  POSTGRES_CONNECTION_TYPE
assert_secret_keys "$out1" postgresql-secrets absent \
  "hybrid: postgresql-secrets no longer stores" \
  DB_HOST DB_PORT DB_USER DB_PASSWORD DB_NAME DB_SSL_MODE \
  DATABASE_AUTH_MODE DATABASE_IAM_AUTH DATABASE_URL SENSIBLE_PG_DSN
# Prisma is the control-plane app's reader and hybrid does not deploy it.
assert_secret_key "$out1" postgresql-secrets absent POSTGRES_PRISMA_URL \
  "hybrid: postgresql-secrets omits the Prisma URL it has no reader for"
# The three Go services read DB_*; POSTGRES_LOGIN is the IAM switch. Telemetry
# falls back to those same DB_* parts — no SENSIBLE_PG_DSN.
for wl in agentgateway-proxy:proxy agentgateway-mcp:mcp trustguard-data-plane:data-plane; do
  assert_datastore_env "$out1" "${wl%%:*}" "${wl##*:}" \
    'DB_HOST,DB_NAME,DB_PASSWORD,DB_PORT,DB_SSL_MODE,DB_USER,POSTGRES_LOGIN' \
    "hybrid: ${wl%%:*} receives only the datastore keys it reads"
done
# DataAgent builds its connection from discrete POSTGRES_* parts.
# POSTGRES_LOGIN resolves to "default" on this password install, as it does for
# the gateways above; the IAM providers are covered in 2c.
assert_datastore_env "$out1" dataagent dataagent \
  'POSTGRES_DB,POSTGRES_HOST,POSTGRES_LOGIN,POSTGRES_PASSWORD,POSTGRES_PORT,POSTGRES_SSLMODE,POSTGRES_USER' \
  "hybrid: DataAgent receives discrete POSTGRES_* parts"
assert_datastore_env "$out1" dataagent-trustguard dataagent \
  'POSTGRES_DB,POSTGRES_HOST,POSTGRES_LOGIN,POSTGRES_PASSWORD,POSTGRES_PORT,POSTGRES_SSLMODE,POSTGRES_USER' \
  "hybrid: TrustGuard DataAgent receives discrete POSTGRES_* parts"
# A wholesale Postgres envFrom creeping back would silently undo the collapse.
assert_no_envfrom_secret "$out1" postgresql-secrets \
  "hybrid: no workload injects postgresql-secrets wholesale"

# Renaming is only safe for a Secret the chart writes. Two modes hand it to the
# operator instead, and both must keep the envFrom passthrough: the chart cannot
# rename keys it does not control, and because these refs are optional a mismatch
# would be silent — DB_SSL_MODE would simply vanish and the gateways would fall
# back to their built-in "disable", turning opportunistic TLS into plaintext.
out1_pg_existing="$TMP/scenario-hybrid-pg-existing.yaml"
render_default "$out1_pg_existing" --set global.postgresql.existingSecret.name=my-pg
assert_not_contains "$out1_pg_existing" 'key: "POSTGRES_SSLMODE"' \
  "hybrid with an operator existingSecret: chart does not rename keys it does not own"
assert_contains "$out1_pg_existing" '- secretRef:'$'\n''            name: "my-pg"' \
  "hybrid with an operator existingSecret: Postgres envFrom passthrough is kept"

# preserveExistingSecrets skips both postgresql-secrets emitters, so the same
# passthrough applies. DataAgent needs its own pre-created Secret in that mode.
out1_pg_preserve="$TMP/scenario-hybrid-pg-preserve.yaml"
render_default "$out1_pg_preserve" \
  --set global.preserveExistingSecrets=true \
  --set agentgateway.dataagent.existingSecret.name=my-da \
  --set trustguard.dataagent.existingSecret.name=my-da2
assert_not_contains "$out1_pg_preserve" 'key: "POSTGRES_SSLMODE"' \
  "hybrid with preserveExistingSecrets: chart does not rename keys it does not own"
assert_contains "$out1_pg_preserve" '- secretRef:'$'\n''            name: "postgresql-secrets"' \
  "hybrid with preserveExistingSecrets: Postgres envFrom passthrough is kept"

# An operator-named Secret is required: a missing or misspelt one must stop the
# pod with an error naming it, not start it without datastore settings. The
# chart always renders its own redis-secrets, and preserveExistingSecrets keeps
# whatever an earlier release wrote, so those refs stay optional.
envfrom_opt() {  # file, workload, secret -> the envFrom ref's optional field
  yq -N "select(.kind == \"Deployment\" and .metadata.name == \"$2\")
    | .spec.template.spec.containers[].envFrom[] | select(.secretRef.name == \"$3\")
    | .secretRef.optional" "$1" 2>/dev/null | head -1
}
check_envfrom_opt() {  # file, workload, secret, want, message
  got="$(envfrom_opt "$1" "$2" "$3")"
  if [ "$got" != "$4" ]; then
    red "FAIL: $2: $5 (envFrom $3 optional=${got:-<no ref>}, want $4)"
    exit 1
  fi
}
out1_redis_existing="$TMP/scenario-hybrid-redis-existing.yaml"
render_default "$out1_redis_existing" --set global.redis.existingSecret.name=my-redis
for w in agentgateway-proxy agentgateway-mcp trustguard-data-plane; do
  check_envfrom_opt "$out1_pg_existing" "$w" my-pg null "an operator Postgres Secret must be required"
  check_envfrom_opt "$out1_redis_existing" "$w" my-redis null "an operator Redis Secret must be required"
  check_envfrom_opt "$out1" "$w" redis-secrets true "the chart's own redis-secrets stays optional"
  check_envfrom_opt "$out1_pg_preserve" "$w" postgresql-secrets true "preserveExistingSecrets keeps the Postgres ref optional"
done
green "ok  - hybrid: operator-named Redis and Postgres Secrets are required refs; chart-managed ones stay optional"
assert_contains "$out1" 'name: POSTGRES_SCHEMA'$'\n''          value: "public"' \
  "data-plane PostgreSQL: default schema reaches the runtime"
assert_pg_migration_runner "$out1" \
  "data-plane PostgreSQL: schema applied by the API image, no psql image or DDL ConfigMap"
assert_env_value "$out1" data-plane-api postgres-migrations POSTGRES_SCHEMA public \
  "data-plane PostgreSQL: default schema reaches the migration"
assert_env_value "$out1" data-plane-api postgres-migrations PYTHONPATH /app \
  "data-plane PostgreSQL: migration runs from the image's package root"
assert_contains "$out1" 'name: redis-secrets' \
  "hybrid: redis-secrets rendered"
assert_contains "$out1" 'name: agentgateway-proxy' \
  "hybrid: trustgate (agentgateway) proxy renders"
assert_contains "$out1" 'name: trustguard-data-plane' \
  "hybrid: trustguard data-plane renders"
assert_contains "$out1" 'name: dataagent-trustguard' \
  "hybrid: trustguard DataAgent renders"
assert_resource_count "$out1" Service dataagent 1 \
  "hybrid: TrustGate DataAgent health Service renders once"
assert_resource_count "$out1" Service dataagent-trustguard 1 \
  "hybrid: TrustGuard DataAgent health Service renders once"
assert_contains "$out1" 'name: data-plane-api' \
  "hybrid: data-plane-api shim renders"
assert_contains "$out1" 'name: clickstack-egress-collector' \
  "hybrid: local OTLP egress ClusterIP Service renders"
# Exactly one egress Service metadata.name (ConfigMap uses -config suffix).
assert_occurrences "$out1" '^  name: clickstack-egress-collector$' 1 \
  "hybrid: single clickstack-egress-collector Service"
assert_contains "$out1" 'name: clickstack-egress-collector'$'\n''        image:' \
  "hybrid: OTLP egress sidecar on primary DataAgent renders"
assert_contains "$out1" 'name: POSTGRES_HOST'$'\n''          valueFrom:'$'\n''            secretKeyRef:'$'\n''              name: "postgresql-secrets"'$'\n''              key: POSTGRES_HOST' \
  "hybrid: DataAgent reads POSTGRES_HOST from postgresql-secrets"
assert_contains "$out1" 'TELEMETRY_EXPORTERS_METADATA: .*name.*metadata-otlp.*type.*otlp' \
  "hybrid: metadata exporter is a named otlp list"
assert_contains "$out1" 'TELEMETRY_EXPORTERS_RAW: .*name.*raw-postgres.*type.*postgres' \
  "hybrid: raw exporter is a named postgres list"
assert_not_contains "$out1" 'TELEMETRY_EXPORTERS_RAW: .*raw-otlp' \
  "hybrid: raw payloads stay in local Postgres, not OTLP"
assert_contains "$out1" 'TELEMETRY_EXPORTERS_FILE: ""' \
  "hybrid: exporters file is empty so env vars are the only source"

# Plan/tier limiting is SaaS metering with no entitlement source on a customer
# cluster, and the binaries default it ON — so the key must be rendered false,
# not omitted. Guards both a dropped template line and a flipped chart default.
assert_contains "$out1" 'RATE_LIMIT_ENABLED: "false"' \
  "hybrid: plan/tier rate limiting is explicitly off"
assert_not_contains "$out1" 'RATE_LIMIT_ENABLED: "true"' \
  "hybrid: no workload turns plan/tier rate limiting on by default"
assert_not_contains "$out1" 'name: trustguard-telemetry' \
  "hybrid: no TrustGuard telemetry ConfigMap"
assert_not_contains "$out1" 'name: agentgateway-telemetry' \
  "hybrid: no AgentGateway telemetry ConfigMap"
assert_not_contains "$out1" 'mountPath: /etc/telemetry' \
  "hybrid: no telemetry volume mount"
assert_contains "$out1" 'name: OAUTH_BROKER_ADDR'$'\n''          value: "127.0.0.1:9465"' \
  "hybrid: DataAgent enables loopback OAuth broker for egress sidecar"
assert_contains "$out1" 'token_url: "http://127.0.0.1:9465/oauth/token"' \
  "hybrid: egress sidecar token_url is DataAgent loopback broker"
assert_contains "$out1" 'client_secret: "unused"' \
  "hybrid: egress sidecar uses non-secret oauth2client placeholder"
assert_not_contains "$out1" 'client_secret: ${env:ENROLMENT_TOKEN}' \
  "hybrid: egress sidecar must not read ENROLMENT_TOKEN"
assert_contains "$out1" 'http://clickstack-egress-collector.default.svc.cluster.local:4318/v1/logs' \
  "hybrid: apps OTLP endpoint points at local egress"
# Operational telemetry is consent-gated: in hybrid it leaves the cluster for
# NeuralTrust, so the default render must carry none of it.
assert_not_contains "$out1" 'OPENTELEMETRY_ENABLED' \
  "hybrid: TrustGuard operational telemetry is off by default (opt-in)"
assert_not_contains "$out1" 'OPS_TRACES_ENABLED' \
  "hybrid: AgentGateway operational traces are off by default (opt-in)"
assert_not_contains "$out1" 'OPS_METRICS_ENABLED' \
  "hybrid: AgentGateway operational metrics are off by default (opt-in)"
out1_ot="$TMP/scenario-hybrid-operational-telemetry.yaml"
render_default "$out1_ot" --set global.observability.operationalTelemetry=true
assert_contains "$out1_ot" 'OPENTELEMETRY_ENABLED: "true"' \
  "hybrid opt-in: TrustGuard traces/metrics are on"
assert_contains "$out1_ot" 'OPENTELEMETRY_TRACES_ENDPOINT: "clickstack-egress-collector.default.svc.cluster.local:4318"' \
  "hybrid opt-in: TrustGuard traces use local egress host:port (WithEndpoint appends /v1/traces)"
assert_contains "$out1_ot" 'OPENTELEMETRY_METRICS_ENDPOINT: "clickstack-egress-collector.default.svc.cluster.local:4318"' \
  "hybrid opt-in: TrustGuard metrics use local egress host:port (WithEndpoint appends /v1/metrics)"
assert_contains "$out1_ot" 'OPS_TRACES_ENABLED: "true"' \
  "hybrid opt-in: AgentGateway operational traces are on"
assert_contains "$out1_ot" 'OPS_METRICS_ENABLED: "true"' \
  "hybrid opt-in: AgentGateway operational metrics are on"
assert_contains "$out1_ot" 'OTEL_EXPORTER_OTLP_TRACES_ENDPOINT: "http://clickstack-egress-collector.default.svc.cluster.local:4318/v1/traces"' \
  "hybrid opt-in: AgentGateway traces go to local egress (enabled without an endpoint fails startup)"
assert_contains "$out1_ot" 'OTEL_EXPORTER_OTLP_METRICS_ENDPOINT: "http://clickstack-egress-collector.default.svc.cluster.local:4318/v1/metrics"' \
  "hybrid opt-in: AgentGateway metrics go to local egress (enabled without an endpoint fails startup)"
# Brackets escaped — assert_contains uses grep -E ([::] is a char class).
assert_contains "$out1" 'endpoint: "\[::\]:4317"' \
  "hybrid: egress OTLP gRPC binds dual-stack ([::]) for IPv6-only clusters"
assert_contains "$out1" 'endpoint: "\[::\]:4318"' \
  "hybrid: egress OTLP HTTP binds dual-stack ([::]) for IPv6-only clusters"
assert_contains "$out1" 'endpoint: "\[::\]:13133"' \
  "hybrid: egress health_check binds dual-stack ([::]) for IPv6-only clusters"
assert_not_contains "$out1" 'name: control-plane-app' \
  "hybrid: control-plane-app must not render (hosted control plane)"
assert_not_contains "$out1" 'name: control-plane-api' \
  "hybrid: control-plane-api must not render (hosted control plane)"
assert_not_contains "$out1" 'OTEL_EXPORTER_OTLP_HEADERS:' \
  "hybrid: apps do not carry remote Authorization headers"
assert_not_contains "$out1" 'TENANT_ID:' \
  "hybrid: DataAgent env omits TENANT_ID when identity comes from enrolment JWT"
assert_not_contains "$out1" 'INSTANCE_ID:' \
  "hybrid: DataAgent env never emits unused INSTANCE_ID"

# ClickStack fail-closed without a fully enabled DataAgent (egress is a sidecar)
blue "==> Scenario 1b: hybrid ClickStack without enrolment must fail (fail-closed)"
assert_render_fails "hybrid without enrolment fails render" \
  --set agentgateway.dataagent.enrolment.existingSecret.name= \
  --set trustguard.dataagent.enrolment.existingSecret.name=

blue "==> Scenario 1b2: legacy clickstack/egress opt-out keys must fail"
assert_render_fails "legacy global.clickstack.enabled=false is rejected" \
  --set global.clickstack.enabled=false
assert_render_fails "legacy global.clickstack.egress.enabled=false is rejected" \
  --set global.clickstack.egress.enabled=false

blue "==> Scenario 1c: product selector rejects invalid keys and types"
assert_render_fails "product selector values must be booleans" \
  --set-string global.products.trustgate=false
if suite_full; then
  assert_render_fails "unknown product selector keys are rejected" \
    --set global.products.unknown=true
fi

blue "==> Scenario 1c2: hybrid raw=remote is gated off (postgres-less parked)"
assert_render_fails_with 'global.telemetry.raw must be "local" or "remote"' \
  "invalid global.telemetry.raw is rejected" \
  --set global.telemetry.raw=otlp
assert_render_fails_with 'global.telemetry.raw=remote is experimental and unsupported' \
  "hybrid raw=remote is rejected without the experimental hatch" \
  --set global.telemetry.raw=remote \
  --set global.products.dataPlane=false

out1c2="$TMP/scenario-hybrid-raw-remote-experimental.yaml"
render_default "$out1c2" \
  --set global.telemetry.raw=remote \
  --set global.telemetry.rawRemoteExperimental=true \
  --set global.products.dataPlane=false
assert_not_contains "$out1c2" 'name: postgresql-secrets' \
  "experimental raw=remote: postgresql-secrets is not rendered"
assert_contains "$out1c2" 'STORE_BACKEND: "none"' \
  "experimental raw=remote: DataAgent store is none"
