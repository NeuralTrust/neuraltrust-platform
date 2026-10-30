#!/usr/bin/env bash
# Render scenarios 2, 2b. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

# ---------------------------------------------------------------------------
# 2. Hybrid with external datastores (existing secrets)
# ---------------------------------------------------------------------------
blue "==> Scenario 2: hybrid with external PG/Redis"
out2="$TMP/scenario-hybrid-external-ds.yaml"
render_default "$out2" \
  --set global.postgresql.deploy=false \
  --set global.postgresql.host=pg.internal.example.com \
  --set global.postgresql.password=external-pg-secret \
  --set data-plane-api.dataPlane.components.api.database.postgresql.schema=tenant_schema \
  --set global.redis.deploy=false \
  --set global.redis.host=redis.internal.example.com \
  --set global.redis.password=external-redis-secret

assert_not_contains "$out2" '^  name: control-plane-postgresql$' \
  "external PG: no in-cluster Postgres Deployment"
# Host is base64-encoded inside postgresql-secrets:
#   $ echo -n pg.internal.example.com | base64 → cGcuaW50ZXJuYWwuZXhhbXBsZS5jb20=
assert_contains "$out2" 'cGcuaW50ZXJuYWwuZXhhbXBsZS5jb20=' \
  "external PG: host reaches templates (base64-encoded in Secret)"
assert_contains "$out2" 'name: POSTGRES_SCHEMA'$'\n''          value: "tenant_schema"' \
  "external PG: configured schema reaches the runtime"
assert_not_contains "$out2" 'CREATE SCHEMA IF NOT EXISTS' \
  "external PG: custom schema does not require database CREATE"
assert_pg_migration_runner "$out2" \
  "external PG: schema applied by the API image"
assert_env_value "$out2" data-plane-api postgres-migrations POSTGRES_SCHEMA tenant_schema \
  "external PG: configured schema reaches the migration"
assert_env_value "$out2" data-plane-api postgres-migrations POSTGRES_HOST \
  secretKeyRef:postgresql-secrets/POSTGRES_HOST \
  "external PG: migration connects to the same endpoint as the API"
assert_not_contains "$out2" 'SET search_path TO' \
  "external PG: chart renders no search_path of its own"
assert_render_fails "invalid data-plane PostgreSQL schema fails render" \
  --set data-plane-api.dataPlane.components.api.database.postgresql.schema=invalid-schema

# ---------------------------------------------------------------------------
# 2b. autoGenerateSecrets=false fallback still emits postgresql-secrets
# ---------------------------------------------------------------------------
blue "==> Scenario 2b: postgresql-secrets via autoGenerateSecrets=false fallback"
out2b="$TMP/scenario-pg-secrets-fallback.yaml"
# DataAgent reuses the fallback shared PostgreSQL Secret; no per-agent DB Secret.
render_default "$out2b" \
  --set global.autoGenerateSecrets=false \
  --set global.preserveExistingSecrets=false \
  --set global.postgresql.password=fallback-pg-secret

assert_contains "$out2b" 'name: postgresql-secrets' \
  "autoGenerate=false: postgresql-secrets fallback renders"
assert_contains "$out2b" 'ZmFsbGJhY2stcGctc2VjcmV0' \
  "autoGenerate=false: explicit password reaches postgresql-secrets"
assert_not_contains "$out2b" 'SENSIBLE_PG_DSN:' \
  "autoGenerate=false: shared fallback no longer composes SENSIBLE_PG_DSN"
assert_contains "$out2b" 'name: dataagent$' \
  "autoGenerate=false: TrustGate DataAgent reuses shared fallback Secret"
assert_contains "$out2b" 'name: dataagent-trustguard$' \
  "autoGenerate=false: TrustGuard DataAgent reuses shared fallback Secret"
assert_not_contains "$out2b" 'name: dataagent-secrets' \
  "autoGenerate=false: no TrustGate per-agent DB Secret"
assert_not_contains "$out2b" 'name: dataagent-trustguard-secrets' \
  "autoGenerate=false: no TrustGuard per-agent DB Secret"
