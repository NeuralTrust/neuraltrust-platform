#!/usr/bin/env bash
# Render scenarios 3. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"

# ---------------------------------------------------------------------------
# 3. External mode — full on-prem
# ---------------------------------------------------------------------------
blue "==> Scenario 3: external (full on-prem) mode"
out3="$TMP/scenario-external.yaml"
render_default "$out3" --set global.deploymentMode=external

assert_contains "$out3" 'name: control-plane-api' \
  "external: control-plane-api Deployment/Service renders"
assert_contains "$out3" 'RATE_LIMIT_ENABLED: "false"' \
  "external: plan/tier rate limiting is explicitly off"
assert_not_contains "$out3" 'RATE_LIMIT_ENABLED: "true"' \
  "external: no workload turns plan/tier rate limiting on by default"
assert_contains "$out3" 'name: control-plane-app' \
  "external: control-plane-app Deployment/Service renders"
assert_contains "$out3" 'name: AUTH_EMAIL_FORCE_ENV' \
  "external: AUTH_EMAIL_FORCE_ENV is set on control-plane-app"
assert_contains "$out3" 'name: AUTH_EMAIL_FORCE_ENV'$'\n''          value: "true"' \
  "external: AUTH_EMAIL_FORCE_ENV defaults to true"
assert_contains "$out3" 'name: DEPLOYMENT_MODE' \
  "external: DEPLOYMENT_MODE is set on control-plane-app"
assert_contains "$out3" 'name: DEPLOYMENT_MODE'$'\n''          value: "external"' \
  "external: DEPLOYMENT_MODE is always external"
assert_not_contains "$out3" 'name: ONPREM_SUPERADMIN_EMAIL' \
  "external: ONPREM_SUPERADMIN_EMAIL absent when global.superadmin unset"
assert_not_contains "$out3" 'name: ONPREM_SUPERADMIN_PASSWORD' \
  "external: ONPREM_SUPERADMIN_PASSWORD absent when global.superadmin unset"
assert_contains "$out3" 'name: data-plane-api' \
  "external: data-plane-api still renders"
assert_contains "$out3" 'name: agentgateway-admin' \
  "external: agentgateway admin control plane renders"
assert_contains "$out3" 'name: trustguard-control-plane' \
  "external: trustguard control plane renders"
assert_contains "$out3" 'NEURAL_TRUST_FIREWALL_BASE_URL: "http://firewall.default.svc.cluster.local"' \
  "external: TrustGuard wires in-cluster Firewall base URL"
assert_contains "$out3" 'name: NEURAL_TRUST_FIREWALL_SECRET_KEY'$'\n''          valueFrom:'$'\n''            secretKeyRef:'$'\n''              name: "firewall-secrets"' \
  "external: TrustGuard mounts firewall-secrets JWT_SECRET"
assert_contains "$out3" 'TELEMETRY_EXPORTERS_METADATA: .*name.*metadata-otlp.*type.*otlp' \
  "external: metadata exporter is a named otlp list"
assert_contains "$out3" 'TELEMETRY_EXPORTERS_RAW: .*name.*raw-otlp.*type.*otlp' \
  "external: raw exporter is a named otlp list"
assert_not_contains "$out3" 'TELEMETRY_EXPORTERS_RAW: .*postgres' \
  "external: raw payloads go to ClickStack, not local Postgres"
assert_not_contains "$out3" 'name: trustguard-telemetry' \
  "external: no TrustGuard telemetry ConfigMap"
assert_not_contains "$out3" 'name: agentgateway-telemetry' \
  "external: no AgentGateway telemetry ConfigMap"
assert_contains "$out3" 'OTEL_EXPORTER_OTLP_ENDPOINT: "http://clickstack-collector.default.svc.cluster.local:4318/v1/logs"' \
  "external: product OTLP logs endpoint includes /v1/logs (WithEndpointURL)"
assert_contains "$out3" 'OPENTELEMETRY_TRACES_ENDPOINT: "clickstack-collector.default.svc.cluster.local:4318"' \
  "external: runtime traces stay host:port (WithEndpoint appends /v1/traces)"
assert_not_contains "$out3" 'OPS_TRACES_ENABLED' \
  "external: AgentGateway operational traces are off by default (opt-in)"
assert_not_contains "$out3" 'OPS_METRICS_ENABLED' \
  "external: AgentGateway operational metrics are off by default (opt-in)"
out3_ot="$TMP/scenario-external-operational-telemetry.yaml"
render_default "$out3_ot" --set global.deploymentMode=external --set global.observability.operationalTelemetry=true
assert_contains "$out3_ot" 'OPS_TRACES_ENABLED: "true"' \
  "external opt-in: AgentGateway operational traces are on"
assert_contains "$out3_ot" 'OPS_METRICS_ENABLED: "true"' \
  "external opt-in: AgentGateway operational metrics are on"
assert_contains "$out3_ot" 'OTEL_EXPORTER_OTLP_TRACES_ENDPOINT: "http://clickstack-collector.default.svc.cluster.local:4318/v1/traces"' \
  "external opt-in: AgentGateway traces go to the in-cluster collector (enabled without an endpoint fails startup)"
assert_contains "$out3_ot" 'OTEL_EXPORTER_OTLP_METRICS_ENDPOINT: "http://clickstack-collector.default.svc.cluster.local:4318/v1/metrics"' \
  "external opt-in: AgentGateway metrics go to the in-cluster collector (enabled without an endpoint fails startup)"
assert_not_contains "$out3" 'name: clickstack-egress-collector' \
  "external: hybrid egress collector must not render (in-cluster path)"
assert_not_contains "$out3" 'clickstack-egress-collector.default.svc' \
  "external: product OTLP must not point at hybrid egress"
assert_contains "$out3" 'name: clickstack-collector-secrets' \
  "external: clickstack-collector-secrets Secret renders"
assert_contains "$out3" 'OTEL_EXPORTER_OTLP_HEADERS:' \
  "external: collector Secret carries OTEL_EXPORTER_OTLP_HEADERS"
assert_contains "$out3" 'name: OTEL_EXPORTER_OTLP_HEADERS'$'\n''          valueFrom:'$'\n''            secretKeyRef:'$'\n''              name: "clickstack-collector-secrets"' \
  "external: TrustGuard/AgentGateway mount OTLP headers from collector Secret"
assert_contains "$out3" 'name: datacore-env-vars' \
  "external: datacore-env-vars ConfigMap renders"
assert_contains "$out3" 'POSTGRES_HOST: "control-plane-postgresql"' \
  "external: DataCore POSTGRES_HOST defaults to in-cluster Postgres"
assert_contains "$out3" 'POSTGRES_DATABASE: "datacore"' \
  "external: DataCore POSTGRES_DATABASE defaults to datacore"
assert_contains "$out3" 'POSTGRES_USER: "datacore"' \
  "external: DataCore POSTGRES_USER defaults to datacore"
assert_contains "$out3" 'POSTGRES_PASSWORD:' \
  "external: datacore-secrets carries POSTGRES_PASSWORD"

# Same canonical Postgres family as hybrid, plus the Prisma URL the app needs.
assert_secret_keys "$out3" postgresql-secrets present \
  "external: postgresql-secrets stores canonical" \
  POSTGRES_HOST POSTGRES_PORT POSTGRES_DB POSTGRES_USER \
  POSTGRES_PASSWORD POSTGRES_SSLMODE POSTGRES_LOGIN POSTGRES_AUTH_MODE \
  POSTGRES_CONNECTION_TYPE POSTGRES_PRISMA_URL
# The lib/pq DSN has no external reader: the gateways gate that env entry on
# hybrid and DataAgent is hybrid-only. Storing it anyway meant a credential
# written for nobody, and one more thing to compose at render time.
assert_secret_key "$out3" postgresql-secrets absent SENSIBLE_PG_DSN \
  "external: postgresql-secrets omits the lib/pq DSN it has no reader for"
assert_secret_keys "$out3" postgresql-secrets absent \
  "external: postgresql-secrets no longer stores" \
  DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD DB_SSL_MODE \
  DATABASE_URL DATABASE_AUTH_MODE DATABASE_IAM_AUTH
# The app reads POSTGRES_DATABASE and DATABASE_URL; both are renames of canonical
# keys (POSTGRES_DB, POSTGRES_PRISMA_URL) rather than separately stored duplicates.
# SSLMODE and CONNECTION_LIMIT are the remaining two parts of the URL, so the app
# can rebuild exactly what the chart would have composed when no URL is supplied.
assert_datastore_env "$out3" control-plane-app app \
  'DATABASE_URL POSTGRES_AUTH_MODE POSTGRES_CONNECTION_LIMIT POSTGRES_DATABASE POSTGRES_HOST POSTGRES_PASSWORD POSTGRES_PORT POSTGRES_PRISMA_URL POSTGRES_SSLMODE POSTGRES_USER' \
  "external: control-plane-app renames POSTGRES_DB/POSTGRES_PRISMA_URL at the consumption site"
assert_no_envfrom_secret "$out3" postgresql-secrets \
  "external: no workload injects postgresql-secrets wholesale"
