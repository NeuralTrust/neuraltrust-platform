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

# v2 hybrid ClickStack fails render when no token is configured. Wire a dummy
# token by default so scenarios that aren't specifically about the ClickStack
# contract don't have to opt in.
CLICKSTACK_DEFAULT_ARGS=(--set global.clickstack.authToken=render-test-token)

render_default() {
  local out="$1"
  shift
  helm template test "$CHART_DIR" --namespace default -f "$CHART_DIR/values-required.yaml" \
    "${CLICKSTACK_DEFAULT_ARGS[@]}" "$@" > "$out"
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
# 1. Minimal v2 hybrid — shared PG/Redis + mandatory ClickStack token
# ---------------------------------------------------------------------------
blue "==> Scenario 1: minimal v2 hybrid (shared PG/Redis + mandatory ClickStack)"
out1="$TMP/scenario-hybrid-minimal.yaml"
render_default "$out1"

assert_contains "$out1" 'kind: Deployment' \
  "hybrid: at least one Deployment renders"
assert_contains "$out1" 'name: control-plane-postgresql' \
  "hybrid: in-cluster PostgreSQL Deployment/Service"
assert_contains "$out1" 'name: postgresql-secrets' \
  "hybrid: postgresql-secrets rendered"
assert_contains "$out1" 'name: redis-secrets' \
  "hybrid: redis-secrets rendered"
assert_contains "$out1" 'name: agentgateway-proxy' \
  "hybrid: agentgateway proxy renders"
assert_contains "$out1" 'name: trustguard-data-plane' \
  "hybrid: trustguard data-plane renders"
assert_contains "$out1" 'name: data-plane-api' \
  "hybrid: data-plane-api shim renders"
assert_not_contains "$out1" 'name: control-plane-app' \
  "hybrid: control-plane-app must not render (SaaS-side)"
assert_not_contains "$out1" 'name: control-plane-api' \
  "hybrid: control-plane-api must not render (SaaS-side)"

# ClickStack fail-closed
blue "==> Scenario 1b: ClickStack token missing must fail (fail-closed)"
assert_render_fails "hybrid without a ClickStack token fails render" \
  --set global.clickstack.authToken=

# Air-gap escape hatch
blue "==> Scenario 1c: ClickStack air-gap escape hatch renders"
out1c="$TMP/scenario-hybrid-airgap.yaml"
helm template test "$CHART_DIR" --namespace default -f "$CHART_DIR/values-required.yaml" \
  --set global.clickstack.enabled=false > "$out1c"
assert_contains "$out1c" 'name: agentgateway-proxy' \
  "air-gap: gateway still renders with ClickStack disabled"

# Config-sync fail-closed and writable LKG storage
blue "==> Scenario 1d: config-sync token references and LKG storage"
assert_render_fails "config-sync without a SaaS token source fails render" \
  --set agentgateway.configSync.enabled=true
out1d="$TMP/scenario-hybrid-config-sync.yaml"
render_default "$out1d" \
  --set agentgateway.configSync.enabled=true \
  --set agentgateway.configSync.existingSecret.name=agentgateway-config-sync \
  --set trustguard.configSync.enabled=true \
  --set trustguard.configSync.existingSecret.name=trustguard-config-sync
assert_contains "$out1d" 'name: "?agentgateway-config-sync"?' \
  "config-sync: AgentGateway references its operator-owned token Secret"
assert_contains "$out1d" 'name: "?trustguard-config-sync"?' \
  "config-sync: TrustGuard references its operator-owned token Secret"
assert_contains "$out1d" 'key: "?CONFIG_SYNC_LKG_KEY"?' \
  "config-sync: existing Secret also supplies the LKG encryption key"
assert_contains "$out1d" 'mountPath: /var/lib/trustgate' \
  "config-sync: AgentGateway LKG path is writable"
assert_contains "$out1d" 'mountPath: /var/lib/trustguard' \
  "config-sync: TrustGuard LKG path is writable"
assert_render_fails "inline config-sync token fails when auto-generation is disabled" \
  --set global.autoGenerateSecrets=false \
  --set agentgateway.configSync.enabled=true \
  --set agentgateway.configSync.token=inline-test-token
assert_render_fails "inline config-sync token fails when managed Secrets are preserved" \
  --set global.preserveExistingSecrets=true \
  --set agentgateway.configSync.enabled=true \
  --set agentgateway.configSync.token=inline-test-token
out1e="$TMP/scenario-config-sync-inline-upgrade.yaml"
render_default "$out1e" --is-upgrade \
  --set agentgateway.configSync.enabled=true \
  --set agentgateway.configSync.token=inline-test-token
assert_contains "$out1e" 'name: agentgateway-secrets' \
  "config-sync upgrade: inline token forces managed Secret rendering"
assert_contains "$out1e" 'CONFIG_SYNC_TOKEN: "inline-test-token"' \
  "config-sync upgrade: managed Secret carries the inline token"
assert_contains "$out1e" 'CONFIG_SYNC_LKG_KEY:' \
  "config-sync upgrade: managed Secret carries an LKG encryption key"

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
render_default "$out2b" \
  --set global.autoGenerateSecrets=false \
  --set global.preserveExistingSecrets=false \
  --set global.postgresql.password=fallback-pg-secret

assert_contains "$out2b" 'name: postgresql-secrets' \
  "autoGenerate=false: postgresql-secrets fallback renders"
assert_contains "$out2b" 'ZmFsbGJhY2stcGctc2VjcmV0' \
  "autoGenerate=false: explicit password reaches postgresql-secrets"

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
  --set firewall.enabled=true \
  --set watchdog.enabled=true

assert_contains "$out4" 'kind: Deployment' \
  "unprefixed roots: chart still renders"
assert_contains "$out4" 'name: firewall' \
  "firewall root: firewall Deployment renders when firewall.enabled=true"
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
if grep -RqE '(platformVersion|confirmV2Migration|hybridRoleLayout|sharedWriter|initJob|neuraltrust-control-plane:|neuraltrust-data-plane:|neuraltrust-firewall:|neuraltrust-watchdog:|trustgate:|^kafka:)' \
    values.yaml values-required.yaml; then
  red "FAIL: retired values keys still present in values.yaml / values-required.yaml"
  exit 1
fi
green "ok  - values.yaml / values-required.yaml free of retired keys"

# ---------------------------------------------------------------------------
# 8. AgentGateway exact + wildcard routing (AWS / Azure / GCP Ingress)
# ---------------------------------------------------------------------------
blue "==> Scenario 8: AgentGateway wildcard Ingress (cloud providers)"
WILDCARD_COMMON=(
  --set global.domain=platform.example.com
  --set agentgateway.config.gatewayDiscoveryMode=subdomain
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
  assert_contains "$outw" 'GATEWAY_DISCOVERY_MODE: "subdomain"' \
    "${provider}: subdomain discovery in ConfigMap"
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

# Default (empty additionalHosts) still renders only the primary host.
outw_default="$TMP/scenario-wildcard-default.yaml"
render_default "$outw_default" \
  --set global.deploymentMode=hybrid \
  --set global.domain=platform.example.com
assert_contains "$outw_default" 'name: agentgateway-gateway' \
  "default: proxy Ingress still renders"
assert_not_contains "$outw_default" 'host: "\*\.' \
  "default: no wildcard hosts when additionalHosts empty"

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
  --set agentgateway.config.gatewayDiscoveryMode=subdomain \
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
assert_not_contains "$out10" 'url: http://opentelemetry-collector.opentelemetry:13133/' \
  "watchdog: obsolete collector health URL is gone"
# Hybrid render must not enable the clickhouse check by default.
assert_contains "$out10" 'enabled: false'$'\n''        id: clickhouse' \
  "watchdog: clickhouse check stays off in hybrid defaults"

blue "==> Scenario 10b: firewall disable requires all three gates"
out10b="$TMP/scenario-firewall-disabled.yaml"
render_default "$out10b" \
  --set firewall.enabled=false \
  --set firewall.firewall.enabled=false \
  --set trustguard.firewall.enabled=false
assert_not_contains "$out10b" 'name: firewall$' \
  "firewall off: gateway Deployment/Service absent"
assert_not_contains "$out10b" 'name: prompt-moderation-worker' \
  "firewall off: workers absent"
assert_not_contains "$out10b" 'NEURAL_TRUST_FIREWALL_BASE_URL' \
  "firewall off: TrustGuard does not wire Firewall URL"

blue "==> Scenario 10c: hybrid has no ClickStack collector; ClickStack env present"
out10c="$TMP/scenario-hybrid-clickstack-channels.yaml"
render_default "$out10c"
assert_not_contains "$out10c" 'name: clickstack-collector' \
  "hybrid: in-cluster ClickStack collector must not render"
assert_not_contains "$out10c" 'kind: StatefulSet' \
  "hybrid: ClickHouse StatefulSet must not render"
assert_contains "$out10c" 'clickstack-collector.neuraltrust.ai' \
  "hybrid: product events target SaaS ClickStack endpoint"

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

green ""
green "All v2 render scenarios passed."
