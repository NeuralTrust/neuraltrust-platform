#!/usr/bin/env bash
# scripts/test-helm-render.sh
#
# Render the umbrella chart in the representative v2 scenarios and assert
# structural invariants. Runs in CI via
# .github/workflows/helm-render-tests.yml and locally:
#
#   ./scripts/test-helm-render.sh
#
# v2-only: v1 (TrustGate/Kafka/scheduler) is retired on `main` — its
# absence is asserted here. Historical v1 users stay on the `v1.14.x`
# release line.
#
# Exits non-zero on the first assertion failure.

set -euo pipefail

cd "$(dirname "$0")/.."

CHART_DIR="."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
blue()  { printf '\033[34m%s\033[0m\n' "$*"; }

helm dependency update "$CHART_DIR" >/dev/null

# v2 hybrid always exports product OTLP via the DataAgent egress sidecar and
# enables config-sync by default. Tests supply per-product enrolment +
# config-sync Secret refs. External mode ignores DataAgent (does not render).
CLICKSTACK_DEFAULT_ARGS=(
  --set agentgateway.dataagent.enrolment.existingSecret.name=dataagent-enrolment-trustgate
  --set trustguard.dataagent.enrolment.existingSecret.name=dataagent-enrolment-trustguard
)

validate_yaml() {
  local file="$1"
  ruby -ryaml -e 'YAML.load_stream(File.read(ARGV.fetch(0)))' "$file"
}

helm lint "$CHART_DIR" -f "$CHART_DIR/values-required.yaml" \
  "${CLICKSTACK_DEFAULT_ARGS[@]}" >/dev/null
green "ok  - helm lint passes"

render_default() {
  local out="$1"
  shift
  helm template test "$CHART_DIR" --namespace default -f "$CHART_DIR/values-required.yaml" \
    "${CLICKSTACK_DEFAULT_ARGS[@]}" "$@" > "$out"
  validate_yaml "$out"
}

# Hybrid product slices start from values-required with every product off
# (values file, so later -f product examples can turn flags back on), then
# apply positive-only product examples. --set must not clear products: Helm
# gives --set higher precedence than -f.
PRODUCTS_OFF_FILE="$TMP/products-off.yaml"
cat > "$PRODUCTS_OFF_FILE" <<'EOF'
global:
  products:
    trustgate: false
    trustguard: false
    dataPlane: false
EOF

HYBRID_NO_PRODUCTS=(
  --set global.products.trustgate=false
  --set global.products.trustguard=false
  --set global.products.dataPlane=false
)

render_product_slice() {
  local out="$1"
  shift
  helm template test "$CHART_DIR" --namespace default \
    -f "$CHART_DIR/values-required.yaml" \
    -f "$PRODUCTS_OFF_FILE" \
    "${CLICKSTACK_DEFAULT_ARGS[@]}" \
    "$@" > "$out"
  validate_yaml "$out"
}

assert_render_fails() {
  local msg="$1"
  shift
  if helm template test "$CHART_DIR" --namespace default -f "$CHART_DIR/values-required.yaml" \
      "${CLICKSTACK_DEFAULT_ARGS[@]}" "$@" >/dev/null 2>&1; then
    red "FAIL: $msg"
    exit 1
  fi
  green "ok  - $msg"
}

assert_contains() {
  local file="$1" needle="$2" msg="$3"
  if ! grep -qE -- "$needle" "$file"; then
    red "FAIL: $msg"
    red "  expected to find pattern: $needle"
    red "  in: $file"
    exit 1
  fi
  green "ok  - $msg"
}

assert_not_contains() {
  local file="$1" needle="$2" msg="$3"
  if grep -qE -- "$needle" "$file"; then
    red "FAIL: $msg"
    red "  unexpected pattern present: $needle"
    red "  in: $file"
    grep -nE -- "$needle" "$file" | head -3 | while IFS= read -r line; do
      red "  > $line"
    done
    exit 1
  fi
  green "ok  - $msg"
}

assert_occurrences() {
  local file="$1" needle="$2" expected="$3" msg="$4" count
  count="$(grep -cE -- "$needle" "$file" || true)"
  if [[ "$count" -ne "$expected" ]]; then
    red "FAIL: $msg"
    red "  expected $expected occurrences of pattern: $needle"
    red "  found: $count"
    exit 1
  fi
  green "ok  - $msg"
}

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
assert_contains "$out1" 'name: redis-secrets' \
  "hybrid: redis-secrets rendered"
assert_contains "$out1" 'name: agentgateway-proxy' \
  "hybrid: trustgate (agentgateway) proxy renders"
assert_contains "$out1" 'name: trustguard-data-plane' \
  "hybrid: trustguard data-plane renders"
assert_contains "$out1" 'name: dataagent$' \
  "hybrid: trustgate DataAgent preserves stable name"
assert_contains "$out1" 'name: dataagent-trustguard' \
  "hybrid: trustguard DataAgent renders"
assert_contains "$out1" 'name: data-plane-api' \
  "hybrid: data-plane-api shim renders"
assert_contains "$out1" 'name: clickstack-egress-collector' \
  "hybrid: local OTLP egress ClusterIP Service renders"
# Exactly one egress Service metadata.name (ConfigMap uses -config suffix).
assert_occurrences "$out1" '^  name: clickstack-egress-collector$' 1 \
  "hybrid: single clickstack-egress-collector Service"
assert_contains "$out1" 'name: clickstack-egress-collector'$'\n''        image:' \
  "hybrid: OTLP egress sidecar on primary DataAgent renders"
assert_contains "$out1" 'name: DATABASE_URL'$'\n''          valueFrom:'$'\n''            secretKeyRef:'$'\n''              name: "postgresql-secrets"'$'\n''              key: SENSIBLE_PG_DSN' \
  "hybrid: DataAgent DATABASE_URL overrides Prisma DSN with SENSIBLE_PG_DSN"
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
# Brackets escaped — assert_contains uses grep -E ([::] is a char class).
assert_contains "$out1" 'endpoint: "\[::\]:4317"' \
  "hybrid: egress OTLP gRPC binds dual-stack ([::]) for IPv6-only clusters"
assert_contains "$out1" 'endpoint: "\[::\]:4318"' \
  "hybrid: egress OTLP HTTP binds dual-stack ([::]) for IPv6-only clusters"
assert_contains "$out1" 'endpoint: "\[::\]:13133"' \
  "hybrid: egress health_check binds dual-stack ([::]) for IPv6-only clusters"
assert_not_contains "$out1" 'name: control-plane-app' \
  "hybrid: control-plane-app must not render (SaaS-side)"
assert_not_contains "$out1" 'name: control-plane-api' \
  "hybrid: control-plane-api must not render (SaaS-side)"
assert_not_contains "$out1" 'OTEL_EXPORTER_OTLP_HEADERS:' \
  "hybrid: apps do not carry SaaS Authorization headers"
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
assert_render_fails "unknown product selector keys are rejected" \
  --set global.products.unknown=true

# Config-sync fail-closed (hybrid default-on) and writable LKG storage
blue "==> Scenario 1d: config-sync token references and LKG storage"
assert_render_fails "hybrid config-sync without a SaaS token source fails render" \
  --set agentgateway.configSync.existingSecret.name= \
  --set trustguard.configSync.existingSecret.name=
out1d="$TMP/scenario-hybrid-config-sync.yaml"
render_default "$out1d"
assert_contains "$out1d" 'name: "?agentgateway-config-sync"?' \
  "config-sync: TrustGate references its operator-owned token Secret"
assert_contains "$out1d" 'name: "?trustguard-config-sync"?' \
  "config-sync: TrustGuard references its operator-owned token Secret"
assert_contains "$out1d" 'key: "?CONFIG_SYNC_LKG_KEY"?' \
  "config-sync: existing Secret also supplies the LKG encryption key"
assert_contains "$out1d" 'mountPath: /var/lib/trustgate' \
  "config-sync: TrustGate LKG path is writable"
assert_contains "$out1d" 'mountPath: /var/lib/trustguard' \
  "config-sync: TrustGuard LKG path is writable"
assert_contains "$out1d" 'name: CONFIG_SYNC_DATA_PLANE_ENABLED'$'\n''          value: "true"' \
  "config-sync: hybrid defaults enable data-plane sync"
assert_render_fails "inline config-sync token fails when auto-generation is disabled" \
  --set global.autoGenerateSecrets=false \
  --set agentgateway.configSync.existingSecret.name= \
  --set agentgateway.configSync.token=inline-test-token \
  --set agentgateway.dataagent.existingSecret.name=dataagent-trustgate-secrets \
  --set trustguard.dataagent.existingSecret.name=dataagent-trustguard-secrets
assert_render_fails "inline config-sync token fails when managed Secrets are preserved" \
  --set global.preserveExistingSecrets=true \
  --set agentgateway.configSync.existingSecret.name= \
  --set agentgateway.configSync.token=inline-test-token
out1e="$TMP/scenario-config-sync-inline-upgrade.yaml"
render_default "$out1e" --is-upgrade \
  --set agentgateway.configSync.existingSecret.name= \
  --set agentgateway.configSync.token=inline-test-token
assert_contains "$out1e" 'name: agentgateway-secrets' \
  "config-sync upgrade: inline token forces managed Secret rendering"
assert_contains "$out1e" 'CONFIG_SYNC_TOKEN: "inline-test-token"' \
  "config-sync upgrade: managed Secret carries the inline token"
assert_contains "$out1e" 'CONFIG_SYNC_LKG_KEY:' \
  "config-sync upgrade: managed Secret carries an LKG encryption key"

blue "==> Scenario 1e: preserved shared PostgreSQL supports DataAgent"
out1f="$TMP/scenario-preserved-shared-postgres.yaml"
render_default "$out1f" \
  --set global.preserveExistingSecrets=true \
  --set global.postgresql.existingSecret.name=external-postgresql
assert_contains "$out1f" 'name: dataagent$' \
  "preserved Secrets: TrustGate DataAgent still renders"
assert_contains "$out1f" 'name: dataagent-trustguard$' \
  "preserved Secrets: TrustGuard DataAgent still renders"
assert_contains "$out1f" 'name: "?external-postgresql"?' \
  "preserved Secrets: DataAgents reference shared PostgreSQL Secret"
assert_not_contains "$out1f" 'name: dataagent-secrets' \
  "preserved Secrets: no unnecessary per-agent Secret reference"

# ---------------------------------------------------------------------------
# 2. Hybrid with external datastores (existing secrets)
# ---------------------------------------------------------------------------
blue "==> Scenario 2: hybrid with external PG/Redis"
out2="$TMP/scenario-hybrid-external-ds.yaml"
render_default "$out2" \
  --set global.postgresql.deploy=false \
  --set global.postgresql.host=pg.internal.example.com \
  --set global.postgresql.password=external-pg-secret \
  --set global.redis.deploy=false \
  --set global.redis.host=redis.internal.example.com \
  --set global.redis.password=external-redis-secret

assert_not_contains "$out2" '^  name: control-plane-postgresql$' \
  "external PG: no in-cluster Postgres Deployment"
# Host is base64-encoded inside postgresql-secrets:
#   $ echo -n pg.internal.example.com | base64 → cGcuaW50ZXJuYWwuZXhhbXBsZS5jb20=
assert_contains "$out2" 'cGcuaW50ZXJuYWwuZXhhbXBsZS5jb20=' \
  "external PG: host reaches templates (base64-encoded in Secret)"

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
assert_contains "$out2b" 'SENSIBLE_PG_DSN:' \
  "autoGenerate=false: shared fallback includes DataAgent-compatible DSN"
assert_contains "$out2b" 'name: dataagent$' \
  "autoGenerate=false: TrustGate DataAgent reuses shared fallback Secret"
assert_contains "$out2b" 'name: dataagent-trustguard$' \
  "autoGenerate=false: TrustGuard DataAgent reuses shared fallback Secret"
assert_not_contains "$out2b" 'name: dataagent-secrets' \
  "autoGenerate=false: no TrustGate per-agent DB Secret"
assert_not_contains "$out2b" 'name: dataagent-trustguard-secrets' \
  "autoGenerate=false: no TrustGuard per-agent DB Secret"

# ---------------------------------------------------------------------------
# 3. External mode — full on-prem
# ---------------------------------------------------------------------------
blue "==> Scenario 3: external (full on-prem) mode"
out3="$TMP/scenario-external.yaml"
render_default "$out3" --set global.deploymentMode=external

assert_contains "$out3" 'name: control-plane-api' \
  "external: control-plane-api Deployment/Service renders"
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
assert_contains "$out3" 'OTEL_EXPORTER_OTLP_ENDPOINT: "http://clickstack-collector.default.svc.cluster.local:4318/v1/logs"' \
  "external: product OTLP logs endpoint includes /v1/logs (WithEndpointURL)"
assert_contains "$out3" 'OPENTELEMETRY_TRACES_ENDPOINT: "clickstack-collector.default.svc.cluster.local:4318"' \
  "external: runtime traces stay host:port (WithEndpoint appends /v1/traces)"
assert_not_contains "$out3" 'name: clickstack-egress-collector' \
  "external: SaaS egress collector must not render (air-gap in-cluster path)"
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

blue "==> Scenario 3-superadmin: ONPREM_SUPERADMIN_* when global.superadmin set"
out3sa="$TMP/scenario-external-superadmin.yaml"
render_default "$out3sa" \
  --set global.deploymentMode=external \
  --set global.superadmin.email=admin@example.com \
  --set global.superadmin.password=s3cret
assert_contains "$out3sa" 'name: ONPREM_SUPERADMIN_EMAIL'$'\n''          value: "admin@example.com"' \
  "external+superadmin: ONPREM_SUPERADMIN_EMAIL set on control-plane-app"
assert_contains "$out3sa" 'name: ONPREM_SUPERADMIN_PASSWORD'$'\n''          value: "s3cret"' \
  "external+superadmin: ONPREM_SUPERADMIN_PASSWORD set on control-plane-app"

# External config-sync servers and clients must share each component's
# operator-owned credentials.
blue "==> Scenario 3a: external config-sync uses shared operator Secrets"
out3a="$TMP/scenario-external-config-sync.yaml"
render_default "$out3a" \
  --set global.deploymentMode=external \
  --set agentgateway.configSync.enabled=true \
  --set agentgateway.configSync.existingSecret.name=agentgateway-config-sync \
  --set trustguard.configSync.enabled=true \
  --set trustguard.configSync.existingSecret.name=trustguard-config-sync
assert_occurrences "$out3a" 'name: "?agentgateway-config-sync"?' 6 \
  "external config-sync: AgentGateway proxy, MCP, and admin share credentials"
assert_occurrences "$out3a" 'name: "?trustguard-config-sync"?' 4 \
  "external config-sync: TrustGuard data and control planes share credentials"

# ---------------------------------------------------------------------------
# 3b. Control-plane RDS IAM env contract (api + app) + DataCore IAM
# ---------------------------------------------------------------------------
blue "==> Scenario 3b: control-plane Postgres IAM env contract"
out3b="$TMP/scenario-external-cp-iam.yaml"
render_default "$out3b" \
  --set global.deploymentMode=external \
  --set global.postgresql.deploy=false \
  --set global.postgresql.host=pg.iam.example.com \
  --set global.postgresql.authMode=iam \
  --set global.postgresql.awsRegion=eu-west-1 \
  --set global.postgresql.user=neuraltrust_iam \
  --set datacore.database.iamAuth=true \
  --set datacore.database.host=pg.iam.example.com \
  --set datacore.database.user=datacore_iam \
  --set datacore.database.sslMode=require \
  --set datacore.database.awsRegion=eu-west-1 \
  --set control-plane-api.controlPlane.components.postgresql.authMode=iam \
  --set control-plane-api.controlPlane.components.postgresql.awsRegion=eu-west-1 \
  --set control-plane-app.controlPlane.components.postgresql.authMode=iam \
  --set control-plane-app.controlPlane.components.postgresql.awsRegion=eu-west-1

# Secret carries app/API-facing keys (base64):
#   POSTGRES_AUTH_MODE=iam          → aWFt
#   POSTGRES_CONNECTION_TYPE=aurora → YXVyb3Jh
assert_contains "$out3b" 'POSTGRES_AUTH_MODE: "aWFt"' \
  "cp IAM: postgresql-secrets emits POSTGRES_AUTH_MODE=iam"
assert_contains "$out3b" 'POSTGRES_CONNECTION_TYPE: "YXVyb3Jh"' \
  "cp IAM: postgresql-secrets emits POSTGRES_CONNECTION_TYPE=aurora"
assert_contains "$out3b" 'name: AWS_REGION' \
  "cp IAM: Deployments emit AWS_REGION"
assert_contains "$out3b" 'value: "eu-west-1"' \
  "cp IAM: AWS_REGION=eu-west-1"
assert_contains "$out3b" 'postgres-iam-url.mjs' \
  "cp IAM: app init-db mints Prisma URL via postgres-iam-url.mjs"
assert_contains "$out3b" 'POSTGRES_LOGIN: "aws"' \
  "datacore IAM: emits POSTGRES_LOGIN=aws"
assert_contains "$out3b" 'POSTGRES_USER: "datacore_iam"' \
  "datacore IAM: POSTGRES_USER is the _iam role"
assert_contains "$out3b" 'AWS_REGION: "eu-west-1"' \
  "datacore IAM: ConfigMap carries AWS_REGION"
# datacore-secrets keeps AUTH_JWT + CLICKHOUSE_USER only (no POSTGRES_PASSWORD).
assert_contains "$out3b" 'name: datacore-secrets'$'\n''  annotations:'$'\n''    helm.sh/resource-policy: keep' \
  "datacore IAM: datacore-secrets still renders"
assert_contains "$out3b" 'AUTH_JWT_HS256_SECRET:'$'\n''  CLICKHOUSE_USER:' \
  "datacore IAM: omits POSTGRES_PASSWORD between JWT and CLICKHOUSE_USER"

# ---------------------------------------------------------------------------
# 4. New unprefixed value roots are honoured
# ---------------------------------------------------------------------------
blue "==> Scenario 4: unprefixed value roots (control-plane-api / control-plane-app / data-plane-api / firewall / watchdog)"
out4="$TMP/scenario-unprefixed-roots.yaml"
render_default "$out4" \
  --set global.deploymentMode=external \
  --set watchdog.enabled=true

assert_contains "$out4" 'kind: Deployment' \
  "unprefixed roots: chart still renders"
assert_contains "$out4" 'name: firewall' \
  "firewall: Deployment follows enabled TrustGuard"
assert_contains "$out4" 'name: neuraltrust-watchdog' \
  "watchdog root: stable K8s name neuraltrust-watchdog preserved"

# ---------------------------------------------------------------------------
# 5. ABSENCE of retired v1 components
# ---------------------------------------------------------------------------
blue "==> Scenario 5: retired v1 components MUST be absent"
for scenario_file in "$out1" "$out2" "$out3" "$out4"; do
  assert_not_contains "$scenario_file" '^kind: Deployment$.*trustgate' \
    "no TrustGate Deployment in $(basename "$scenario_file")" || true
  assert_not_contains "$scenario_file" 'app.kubernetes.io/name: trustgate' \
    "no TrustGate labels in $(basename "$scenario_file")"
  assert_not_contains "$scenario_file" 'app.kubernetes.io/name: kafka' \
    "no Kafka labels in $(basename "$scenario_file")"
  assert_not_contains "$scenario_file" 'app.kubernetes.io/name: zookeeper' \
    "no Zookeeper labels in $(basename "$scenario_file")"
  # Zookeeper/Kafka were the only StatefulSets in v1; ClickHouse's StatefulSet is legitimate.
  if grep -qE '^kind: StatefulSet' "$scenario_file"; then
    while IFS= read -r sts_name; do
      case "$sts_name" in
        clickhouse|clickhouse-*|neuraltrust-watchdog|neuraltrust-watchdog-*) ;;
        *)
          red "FAIL: unexpected StatefulSet '$sts_name' in $(basename "$scenario_file")"
          exit 1
          ;;
      esac
    done < <(awk '/^kind: StatefulSet/{sts=1; next} sts && /^metadata:/{next} sts && /^  name:/{sub("^  name: ", ""); print; sts=0}' "$scenario_file")
  fi
  green "ok  - only legit (ClickHouse) StatefulSets in $(basename "$scenario_file")"
  assert_not_contains "$scenario_file" 'name: scheduler' \
    "no scheduler Deployment/Service in $(basename "$scenario_file")"
  assert_not_contains "$scenario_file" 'name: kafka-connect' \
    "no Kafka Connect Deployment/Service in $(basename "$scenario_file")"
  assert_not_contains "$scenario_file" 'name: v2-postgresql-init' \
    "no v2-postgresql-init Job in $(basename "$scenario_file")"
done

# ---------------------------------------------------------------------------
# 6. Stable Kubernetes names after physical chart moves
# ---------------------------------------------------------------------------
blue "==> Scenario 6: stable Kubernetes names preserved after chart rebrand"
out6="$TMP/scenario-external-names.yaml"
render_default "$out6" --set global.deploymentMode=external

for name in \
  control-plane-api \
  control-plane-app \
  control-plane-postgresql \
  postgresql-secrets \
  redis \
  data-plane-api \
  agentgateway-proxy \
  agentgateway-admin \
  trustguard-data-plane \
  trustguard-control-plane
do
  assert_contains "$out6" "name: $name" \
    "stable name preserved: $name"
done
# redis-secrets is a hybrid-only shared Secret.
assert_contains "$out1" 'name: redis-secrets' \
  "stable name preserved (hybrid): redis-secrets"

# watchdog keeps its stable resource name after charts/neuraltrust-watchdog -> charts/watchdog.
out6wd="$TMP/scenario-watchdog-names.yaml"
render_default "$out6wd" --set global.deploymentMode=external --set watchdog.enabled=true
assert_contains "$out6wd" 'name: neuraltrust-watchdog' \
  "stable name preserved after rename: neuraltrust-watchdog"

# ---------------------------------------------------------------------------
# 7. Retired helpers / values must not appear in the values contract or rendered output
# ---------------------------------------------------------------------------
blue "==> Scenario 7: retired concepts must not surface in values contract"
if grep -RqE '(platformVersion|confirmV2Migration|hybridRoleLayout|sharedWriter|initJob|neuraltrust-control-plane:|neuraltrust-data-plane:|neuraltrust-firewall:|neuraltrust-watchdog:|^kafka:|gatewayDiscoveryMode|GATEWAY_DISCOVERY_MODE|^trustgate:)' \
    values.yaml values-required.yaml charts/agentgateway/values.yaml; then
  red "FAIL: retired values keys still present in values.yaml / values-required.yaml / agentgateway values"
  exit 1
fi
green "ok  - values.yaml / values-required.yaml free of retired keys"

# ---------------------------------------------------------------------------
# 8. AgentGateway exact + wildcard routing (AWS / Azure / GCP Ingress)
# ---------------------------------------------------------------------------
blue "==> Scenario 8: AgentGateway exact + wildcard Ingress (cloud providers)"
WILDCARD_COMMON=(
  --set global.domain=platform.example.com
  --set agentgateway.config.gatewayBaseDomain=llm.platform.example.com
  --set agentgateway.config.mcpBaseDomain=mcp.platform.example.com
  --set agentgateway.ingress.dataPlane.host=gateway.platform.example.com
  --set agentgateway.ingress.dataPlane.additionalHosts[0]="*.llm.platform.example.com"
  --set agentgateway.ingress.mcp.host=mcp.platform.example.com
  --set agentgateway.ingress.mcp.additionalHosts[0]="*.mcp.platform.example.com"
)

for provider in aws azure gcp; do
  outw="$TMP/scenario-wildcard-${provider}.yaml"
  render_default "$outw" \
    --set global.deploymentMode=external \
    --set "global.platform=${provider}" \
    "${WILDCARD_COMMON[@]}"
  assert_contains "$outw" 'name: agentgateway-gateway' \
    "${provider}: proxy Ingress name stable"
  assert_contains "$outw" 'host: "gateway.platform.example.com"' \
    "${provider}: proxy exact host"
  assert_contains "$outw" 'host: "\*\.llm\.platform\.example\.com"' \
    "${provider}: proxy wildcard host rule"
  assert_contains "$outw" 'name: agentgateway-proxy' \
    "${provider}: proxy backend Service"
  assert_contains "$outw" 'name: agentgateway-mcp' \
    "${provider}: MCP Ingress/Service present"
  assert_contains "$outw" 'host: "mcp.platform.example.com"' \
    "${provider}: MCP exact host"
  assert_contains "$outw" 'host: "\*\.mcp\.platform\.example\.com"' \
    "${provider}: MCP wildcard host rule"
  assert_not_contains "$outw" 'GATEWAY_DISCOVERY_MODE' \
    "${provider}: discovery mode env retired"
  assert_contains "$outw" 'GATEWAY_BASE_DOMAIN: "llm.platform.example.com"' \
    "${provider}: gateway base domain"
  assert_contains "$outw" 'MCP_BASE_DOMAIN: "mcp.platform.example.com"' \
    "${provider}: MCP base domain"
  # Admin must stay exact-only (no wildcard rule on admin Ingress).
  if python3 - "$outw" <<'PY'
import re, sys
for doc in open(sys.argv[1]).read().split("---"):
    if "kind: Ingress" in doc and re.search(r"(?m)^\s+name:\s*agentgateway-admin\s*$", doc):
        if re.search(r'host:\s*"?\*\.', doc):
            sys.exit(1)
sys.exit(0)
PY
  then
    green "ok  - ${provider}: admin Ingress has no wildcard hosts"
  else
    red "FAIL: ${provider}: admin Ingress must not include wildcard hosts"
    exit 1
  fi
  assert_not_contains "$outw" 'kind: Route' \
    "${provider}: no OpenShift Routes on cloud platform"
done

# Dual discovery default: empty additionalHosts → auto wildcards + llm./mcp. bases.
blue "==> Scenario 8b: dual discovery auto-derives base domains and wildcards"
outw_auto="$TMP/scenario-wildcard-autoderive.yaml"
render_default "$outw_auto" \
  --set global.domain=platform.example.com
assert_not_contains "$outw_auto" 'GATEWAY_DISCOVERY_MODE' \
  "auto: discovery mode env retired"
assert_contains "$outw_auto" 'GATEWAY_BASE_DOMAIN: "llm.platform.example.com"' \
  "auto: GATEWAY_BASE_DOMAIN=llm.<global.domain>"
assert_contains "$outw_auto" 'MCP_BASE_DOMAIN: "mcp.platform.example.com"' \
  "auto: MCP_BASE_DOMAIN=mcp.<global.domain>"
assert_contains "$outw_auto" 'host: "\*\.llm\.platform\.example\.com"' \
  "auto: proxy wildcard host from global.domain"
assert_contains "$outw_auto" 'host: "\*\.mcp\.platform\.example\.com"' \
  "auto: MCP wildcard host from global.domain"
assert_contains "$outw_auto" 'host: "gateway.platform.example.com"' \
  "auto: exact gateway primary host retained"
# Opt out of auto wildcards (exact hosts only).
outw_no_auto="$TMP/scenario-wildcard-no-auto.yaml"
render_default "$outw_no_auto" \
  --set global.domain=platform.example.com \
  --set agentgateway.config.autoWildcardHosts=false
assert_contains "$outw_no_auto" 'host: "gateway.platform.example.com"' \
  "no-auto: exact gateway primary host retained"
assert_not_contains "$outw_no_auto" 'host: "\*\.' \
  "no-auto: autoWildcardHosts=false skips wildcards"
assert_contains "$outw_no_auto" 'GATEWAY_BASE_DOMAIN: "llm.platform.example.com"' \
  "no-auto: base domains still derived for dual-mode app"
# Explicit additionalHosts stays authoritative (no auto-merge).
outw_override="$TMP/scenario-wildcard-override.yaml"
render_default "$outw_override" \
  --set global.domain=platform.example.com \
  --set agentgateway.ingress.dataPlane.additionalHosts[0]="custom.platform.example.com"
assert_contains "$outw_override" 'host: "custom.platform.example.com"' \
  "override: explicit additionalHosts rendered"
assert_not_contains "$outw_override" 'host: "\*\.llm\.platform\.example\.com"' \
  "override: non-empty additionalHosts skips auto *.llm wildcard"

# ---------------------------------------------------------------------------
# 9. AgentGateway OpenShift Routes (exact + wildcardPolicy Subdomain)
# ---------------------------------------------------------------------------
blue "==> Scenario 9: AgentGateway OpenShift Routes + Ingress override"
out_ocp="$TMP/scenario-wildcard-openshift-routes.yaml"
helm template test "$CHART_DIR" --namespace default \
  -f "$CHART_DIR/values-required.yaml" \
  "${CLICKSTACK_DEFAULT_ARGS[@]}" \
  --api-versions route.openshift.io/v1 \
  --set global.deploymentMode=external \
  --set global.platform=openshift \
  --set global.domain=apps.example.com \
  --set agentgateway.config.gatewayBaseDomain=llm.apps.example.com \
  --set agentgateway.config.mcpBaseDomain=mcp.apps.example.com \
  --set agentgateway.ingress.dataPlane.host=gateway.apps.example.com \
  --set agentgateway.ingress.dataPlane.additionalHosts[0]="*.llm.apps.example.com" \
  --set agentgateway.ingress.mcp.host=mcp.apps.example.com \
  --set agentgateway.ingress.mcp.additionalHosts[0]="*.mcp.apps.example.com" \
  > "$out_ocp"

assert_contains "$out_ocp" 'kind: Route' \
  "openshift auto: Routes render"
assert_contains "$out_ocp" 'host: "gateway.apps.example.com"' \
  "openshift: exact proxy Route host"
assert_contains "$out_ocp" 'host: "llm.apps.example.com"' \
  "openshift: wildcard proxy Route host strips *."
assert_contains "$out_ocp" 'wildcardPolicy: Subdomain' \
  "openshift: wildcard Routes use Subdomain policy"
assert_contains "$out_ocp" 'wildcardPolicy: None' \
  "openshift: exact Routes use None policy"
assert_contains "$out_ocp" 'name: agentgateway-proxy' \
  "openshift: proxy Route backend Service"
assert_not_contains "$out_ocp" 'name: agentgateway-gateway' \
  "openshift auto: proxy Ingress not rendered"

# Explicit Ingress on OpenShift still works.
out_ocp_ing="$TMP/scenario-wildcard-openshift-ingress.yaml"
helm template test "$CHART_DIR" --namespace default \
  -f "$CHART_DIR/values-required.yaml" \
  "${CLICKSTACK_DEFAULT_ARGS[@]}" \
  --api-versions route.openshift.io/v1 \
  --set global.deploymentMode=hybrid \
  --set global.platform=openshift \
  --set global.domain=apps.example.com \
  --set agentgateway.ingress.resourceType=ingress \
  --set agentgateway.ingress.dataPlane.additionalHosts[0]="*.llm.apps.example.com" \
  > "$out_ocp_ing"
assert_contains "$out_ocp_ing" 'name: agentgateway-gateway' \
  "openshift resourceType=ingress: Ingress renders"
assert_contains "$out_ocp_ing" 'host: "\*\.llm\.apps\.example\.com"' \
  "openshift resourceType=ingress: wildcard Ingress rule"
assert_not_contains "$out_ocp_ing" 'name: agentgateway-proxy-' \
  "openshift resourceType=ingress: AgentGateway proxy Routes absent"
assert_not_contains "$out_ocp_ing" 'name: agentgateway-mcp-' \
  "openshift resourceType=ingress: AgentGateway MCP Routes absent"

# ---------------------------------------------------------------------------
# 10. Watchdog defaults + firewall disable sync + hybrid ClickStack channels
# ---------------------------------------------------------------------------
blue "==> Scenario 10: watchdog otel-collector target and topology-neutral checks"
out10="$TMP/scenario-watchdog-defaults.yaml"
render_default "$out10" \
  --set global.observability.enabled=true \
  --set global.observability.hostedExport.enabled=false \
  --set watchdog.enabled=true
assert_contains "$out10" 'url: http://otel-collector:13133/' \
  "watchdog: otel-collector check targets umbrella Service"
assert_contains "$out10" 'labelSelector: app.kubernetes.io/component=otel-collector' \
  "watchdog: otel-collector selector matches umbrella labels"
assert_contains "$out10" 'endpoint: \[::\]:4317' \
  "observability: umbrella otel-collector OTLP gRPC binds dual-stack"
assert_contains "$out10" 'endpoint: \[::\]:13133' \
  "observability: umbrella otel-collector health binds dual-stack"
assert_contains "$out10" 'host: "::"' \
  "observability: umbrella otel-collector telemetry metrics host is ::"
assert_not_contains "$out10" 'url: http://opentelemetry-collector.opentelemetry:13133/' \
  "watchdog: obsolete collector health URL is gone"
# Hybrid render must not enable the clickhouse check by default.
assert_contains "$out10" 'enabled: false'$'\n''        id: clickhouse' \
  "watchdog: clickhouse check stays off in hybrid defaults"

blue "==> Scenario 10b: Firewall follows the TrustGuard product gate"
out10b="$TMP/scenario-firewall-disabled.yaml"
render_default "$out10b" --set global.products.trustguard=false
assert_not_contains "$out10b" 'name: firewall$' \
  "trustguard off: Firewall gateway absent"
assert_not_contains "$out10b" 'name: prompt-moderation-worker' \
  "trustguard off: Firewall workers absent"
assert_not_contains "$out10b" 'name: firewall-secrets' \
  "trustguard off: Firewall Secret absent"
assert_not_contains "$out10b" 'NEURAL_TRUST_FIREWALL_BASE_URL' \
  "trustguard off: no Firewall client wiring"

blue "==> Scenario 10b2: Firewall v2.15 production worker module set"
out10b2="$TMP/scenario-firewall-workers.yaml"
render_default "$out10b2"
assert_contains "$out10b2" 'name: firewall$' \
  "firewall workers: gateway Deployment present"
assert_contains "$out10b2" 'name: toxicity-worker' \
  "firewall workers: toxicity present"
assert_contains "$out10b2" 'name: prompt-jailbreak-worker' \
  "firewall workers: prompt-jailbreak present"
assert_contains "$out10b2" 'name: prompt-moderation-worker' \
  "firewall workers: prompt-moderation present"
assert_contains "$out10b2" 'name: response-jailbreak-worker' \
  "firewall workers: response-jailbreak present"
assert_contains "$out10b2" 'name: indirect-prompt-injections-worker' \
  "firewall workers: IPI present"
assert_contains "$out10b2" 'src.workers.indirect_prompt_injections.app:app' \
  "firewall workers: IPI module arg"
assert_contains "$out10b2" 'INDIRECT_PROMPT_INJECTIONS_WORKER_URL: "http://indirect-prompt-injections-worker:80"' \
  "firewall workers: IPI worker URL in ConfigMap"
assert_contains "$out10b2" 'europe-west1-docker.pkg.dev/neuraltrust-app-prod/nt-docker/firewall-cpu:v2.15.0' \
  "firewall workers: default image tag is v2.15.0"
assert_not_contains "$out10b2" 'name: toolguard-worker' \
  "firewall workers: retired toolguard worker absent"
assert_not_contains "$out10b2" 'TOOLGUARD_WORKER_URL' \
  "firewall workers: TOOLGUARD_WORKER_URL absent"
assert_not_contains "$out10b2" 'src.workers.toolguard.app:app' \
  "firewall workers: retired toolguard module absent"

blue "==> Scenario 10c: hybrid has no in-cluster ClickStack; egress to SaaS"
out10c="$TMP/scenario-hybrid-clickstack-channels.yaml"
render_default "$out10c"
assert_not_contains "$out10c" 'name: clickstack-collector' \
  "hybrid: in-cluster ClickStack collector must not render"
assert_not_contains "$out10c" 'kind: StatefulSet' \
  "hybrid: ClickHouse StatefulSet must not render"
assert_contains "$out10c" 'name: clickstack-egress-collector' \
  "hybrid: local egress ClusterIP Service renders"
assert_contains "$out10c" 'name: clickstack-egress-collector'$'\n''        image:' \
  "hybrid: egress sidecar co-located on DataAgent"
assert_contains "$out10c" 'token_url: "http://127.0.0.1:9465/oauth/token"' \
  "hybrid: egress sidecar exchanges via DataAgent loopback broker"
assert_contains "$out10c" 'endpoint: "https://telemetry.neuraltrust.ai"' \
  "hybrid: egress sidecar exports to SaaS ingest host"
assert_contains "$out10c" 'http://clickstack-egress-collector.default.svc.cluster.local:4318/v1/logs' \
  "hybrid: apps send OTLP to local egress only"

blue "==> Scenario 10d: GPU Firewall workers (dataplane-gpu example shape)"
out10d="$TMP/scenario-firewall-gpu.yaml"
render_default "$out10d" \
  --set firewall.firewall.workerDefaults.image.repository=europe-west1-docker.pkg.dev/neuraltrust-app-prod/nt-docker/firewall-gpu \
  --set 'firewall.firewall.workerDefaults.resources.requests.nvidia\.com/gpu=1' \
  --set 'firewall.firewall.workerDefaults.resources.limits.nvidia\.com/gpu=1' \
  --set firewall.firewall.workerDefaults.hostIPC=true
assert_contains "$out10d" 'nvidia.com/gpu' \
  "gpu: Firewall workers request GPU resources"
assert_contains "$out10d" 'hostIPC: true' \
  "gpu: Firewall workers share host IPC for CUDA MPS"

# ---------------------------------------------------------------------------
# 11. Positive hybrid product selection
# ---------------------------------------------------------------------------
blue "==> Scenario 11: hybrid with no product selected fails fast"
assert_render_fails "hybrid no-selection: requires at least one product" \
  "${HYBRID_NO_PRODUCTS[@]}"

blue "==> Scenario 11a: trustgate-only hybrid"
out11a="$TMP/scenario-trustgate-only.yaml"
render_product_slice "$out11a" -f "$CHART_DIR/values-trustgate.yaml.example"
assert_contains "$out11a" 'name: agentgateway-proxy' \
  "trustgate-only: proxy renders"
assert_contains "$out11a" 'name: dataagent$' \
  "trustgate-only: single DataAgent keeps stable name dataagent"
assert_not_contains "$out11a" 'name: trustguard-data-plane' \
  "trustgate-only: trustguard absent"
assert_not_contains "$out11a" 'TRUSTGUARD_BASE_URL:' \
  "trustgate-only: TRUSTGUARD_BASE_URL omitted"
assert_contains "$out11a" 'name: clickstack-egress-collector' \
  "trustgate-only: egress Service present"

blue "==> Scenario 11b: trustguard-only hybrid"
out11b="$TMP/scenario-trustguard-only.yaml"
render_product_slice "$out11b" -f "$CHART_DIR/values-trustguard.yaml.example"
assert_contains "$out11b" 'name: trustguard-data-plane' \
  "trustguard-only: data-plane renders"
assert_contains "$out11b" 'name: dataagent-trustguard$' \
  "trustguard-only: fixed TrustGuard DataAgent name"
assert_not_contains "$out11b" 'name: agentgateway-proxy' \
  "trustguard-only: trustgate absent"
assert_contains "$out11b" 'name: firewall$' \
  "trustguard-only: Firewall follows TrustGuard"
assert_contains "$out11b" 'name: clickstack-egress-collector' \
  "trustguard-only: egress Service on primary DataAgent"

blue "==> Scenario 11c: data-plane-only (red-teaming) hybrid — no DataAgent"
out11c="$TMP/scenario-red-teaming-only.yaml"
render_product_slice "$out11c" -f "$CHART_DIR/values-red-teaming.yaml.example"
assert_contains "$out11c" 'name: data-plane-api' \
  "red-teaming: data-plane-api renders"
assert_not_contains "$out11c" 'name: dataagent' \
  "red-teaming: no DataAgent"
assert_not_contains "$out11c" 'name: clickstack-egress-collector' \
  "red-teaming: no ClickStack egress"
assert_not_contains "$out11c" 'name: agentgateway-proxy' \
  "red-teaming: trustgate absent"
assert_not_contains "$out11c" 'name: trustguard-data-plane' \
  "red-teaming: trustguard absent"

blue "==> Scenario 11d: positive slices compose pairwise and all together"
out11d1="$TMP/scenario-trustgate-trustguard.yaml"
render_product_slice "$out11d1" \
  -f "$CHART_DIR/values-trustgate.yaml.example" \
  -f "$CHART_DIR/values-trustguard.yaml.example"
assert_contains "$out11d1" 'name: dataagent$' \
  "trustgate+trustguard: stable TrustGate DataAgent"
assert_contains "$out11d1" 'name: dataagent-trustguard$' \
  "trustgate+trustguard: fixed TrustGuard DataAgent"
assert_occurrences "$out11d1" '^  name: clickstack-egress-collector$' 1 \
  "trustgate+trustguard: exactly one egress Service"

out11d2="$TMP/scenario-trustgate-red-teaming.yaml"
render_product_slice "$out11d2" \
  -f "$CHART_DIR/values-red-teaming.yaml.example" \
  -f "$CHART_DIR/values-trustgate.yaml.example"
assert_contains "$out11d2" 'name: agentgateway-proxy' \
  "trustgate+red-teaming: TrustGate renders"
assert_contains "$out11d2" 'name: data-plane-api' \
  "trustgate+red-teaming: data-plane-api renders"

out11d3="$TMP/scenario-trustguard-red-teaming.yaml"
render_product_slice "$out11d3" \
  -f "$CHART_DIR/values-trustguard.yaml.example" \
  -f "$CHART_DIR/values-red-teaming.yaml.example"
assert_contains "$out11d3" 'name: trustguard-data-plane' \
  "trustguard+red-teaming: TrustGuard renders"
assert_contains "$out11d3" 'name: data-plane-api' \
  "trustguard+red-teaming: data-plane-api renders"

out11d4="$TMP/scenario-all-products.yaml"
render_product_slice "$out11d4" \
  -f "$CHART_DIR/values-red-teaming.yaml.example" \
  -f "$CHART_DIR/values-trustguard.yaml.example" \
  -f "$CHART_DIR/values-trustgate.yaml.example"
assert_contains "$out11d4" 'name: agentgateway-proxy' \
  "all products: TrustGate renders"
assert_contains "$out11d4" 'name: trustguard-data-plane' \
  "all products: TrustGuard renders"
assert_contains "$out11d4" 'name: data-plane-api' \
  "all products: data-plane-api renders"
assert_occurrences "$out11d4" '^  name: clickstack-egress-collector$' 1 \
  "all products: exactly one egress Service"

blue "==> Scenario 11e: external overlay without global.products still full stack"
out11e="$TMP/scenario-external-no-products.yaml"
helm template test "$CHART_DIR" --namespace default \
  -f "$CHART_DIR/values-v2-external.yaml.example" > "$out11e"
validate_yaml "$out11e"
assert_contains "$out11e" 'name: agentgateway-admin' \
  "external no-products: AgentGateway admin renders"
assert_contains "$out11e" 'name: trustguard-control-plane' \
  "external no-products: TrustGuard control plane renders"
assert_contains "$out11e" 'name: data-plane-api' \
  "external no-products: data-plane-api renders"
assert_contains "$out11e" 'name: firewall$' \
  "external no-products: Firewall renders"

green ""
green "All v2 render scenarios passed."
