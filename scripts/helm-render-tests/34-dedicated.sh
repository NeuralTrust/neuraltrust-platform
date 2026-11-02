#!/usr/bin/env bash
# Render scenario 34. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

# ---------------------------------------------------------------------------
# dedicated mode: one product data plane NeuralTrust runs for a single instance,
# in a NeuralTrust cluster, rendered by DataCore. Wired like a hybrid data plane,
# minus DataAgent, Postgres, the in-cluster Redis and the shared SaaS hostnames.
# values-required.yaml is a hybrid customer file, so these renders start clean.
# ---------------------------------------------------------------------------
blue "==> Scenario 34: dedicated mode (single-instance data plane)"

DEDICATED_ARGS=(
  --set global.platform=gcp
  --set global.domain=dev.example.com
  --set global.deploymentMode=dedicated
  --set global.products.trustgate=true
  --set global.platformSecret.existingSecret.name=trustgate-abc-credentials
  --set global.redis.deploy=false
  --set global.redis.host=10.0.0.5
  --set global.clickstack.endpoint=http://clickstack-collector.otel.svc.cluster.local:4318
  --set global.secrets.generator.enabled=false
  --set global.ingress.provider=gateway-api
  --set 'global.ingress.gatewayApi.parentRefs[0].name=internal-gateway'
  --set 'global.ingress.gatewayApi.parentRefs[0].namespace=gateway-internal'
  --set global.ingress.tls.autoGenerate=false
  --set agentgateway.config.autoWildcardHosts=false
  --set agentgateway.configSync.endpoint=agentgateway-admin.agentgateway.svc.cluster.local:8083
  --set agentgateway.configSync.existingSecret.name=trustgate-abc-credentials
  --set agentgateway.ingress.dataPlane.host=abc.trustgate.dp.eu.dev.example.com
  --set agentgateway.ingress.mcp.host=abc.mcp.dp.eu.dev.example.com
  --set-string agentgateway.redis.db=3
)

render_dedicated() {
  local out="$1"
  shift
  helm template trustgate-abc "$CHART_DIR" --namespace dp-abc "${DEDICATED_ARGS[@]}" "$@" > "$out"
  validate_yaml "$out"
}

dedicated_fails_with() {
  local needle="$1" msg="$2"
  shift 2
  local err
  err="$(mktemp)"
  if helm template trustgate-abc "$CHART_DIR" --namespace dp-abc "${DEDICATED_ARGS[@]}" "$@" >/dev/null 2>"$err"; then
    red "FAIL: $msg"
    red "  the render succeeded; expected it to fail with: $needle"
    rm -f "$err"
    exit 1
  fi
  if ! grep -qF -- "$needle" "$err"; then
    red "FAIL: $msg"
    red "  the render failed for the wrong reason; expected: $needle"
    red "  got: $(tr '\n' ' ' < "$err")"
    rm -f "$err"
    exit 1
  fi
  rm -f "$err"
  green "ok  - $msg"
}

out34="$TMP/scenario-dedicated.yaml"
render_dedicated "$out34"
assert_contains "$out34" 'name: agentgateway-proxy' \
  "dedicated: renders the TrustGate proxy"
assert_contains "$out34" 'name: agentgateway-mcp' \
  "dedicated: renders the TrustGate MCP server"
for absent in dataagent clickstack-egress-collector control-plane-postgresql 'name: redis$' data-plane-api 'name: agentgateway-admin$' 'name: trustguard-data-plane$' neuraltrust-ingress-tls; do
  assert_not_contains "$out34" "$absent" "dedicated: does not render $absent"
done
assert_not_contains "$out34" '^kind: Ingress$' \
  "dedicated: attaches HTTPRoutes to the cluster Gateway instead of creating a load balancer"
assert_contains "$out34" '"abc.trustgate.dp.eu.dev.example.com"' \
  "dedicated: the proxy route serves the plane's own host"
assert_contains "$out34" '"abc.mcp.dp.eu.dev.example.com"' \
  "dedicated: the MCP route serves the plane's own MCP host"
assert_not_contains "$out34" '\*\.' \
  "dedicated: no wildcard host that would overlap the shared SaaS hosts"
assert_contains "$out34" 'name: CONFIG_SYNC_DATA_PLANE_ENABLED'$'\n''          value: "true"' \
  "dedicated: the proxy is a config-sync data plane"
assert_contains "$out34" 'OTEL_EXPORTER_OTLP_ENDPOINT: "http://clickstack-collector.otel.svc.cluster.local:4318/v1/logs"' \
  "dedicated: OTLP goes straight to the NeuralTrust collector"
assert_contains "$out34" 'TELEMETRY_EXPORTERS_RAW: "\[\{\\"name\\":\\"raw-otlp\\"' \
  "dedicated: raw telemetry is exported, never stored locally"
assert_contains "$out34" 'name: OTEL_EXPORTER_OTLP_HEADERS'$'\n''          valueFrom:'$'\n''            secretKeyRef:'$'\n''              name: "trustgate-abc-credentials"' \
  "dedicated: the collector auth header comes from the DataCore Secret"
assert_contains "$out34" 'SOLE_GATEWAY_FALLBACK: "true"' \
  "dedicated: the plane serves its only gateway on hosts without the slug"
assert_contains "$out34" 'REDIS_DB: "3"' \
  "dedicated: Redis DB follows agentgateway.redis.db"
assert_not_contains "$out34" 'name: (DB_HOST|POSTGRES_HOST)' \
  "dedicated: no Postgres wiring"
assert_contains "$out34" 'name: "?trustgate-abc-credentials"?'$'\n''              key: "?SERVER_SECRET_KEY"?' \
  "dedicated: SERVER_SECRET_KEY comes from the DataCore Secret"
assert_contains "$out34" 'REDIS_HOST: "?MTAuMC4wLjU="?' \
  "dedicated: Redis points at the cluster's Redis"

dedicated_fails_with "exactly one of global.products.trustgate and global.products.trustguard" \
  "dedicated: refuses two products in one plane" --set global.products.trustguard=true
dedicated_fails_with "global.products.dataPlane is not supported" \
  "dedicated: refuses the data-plane product" --set global.products.dataPlane=true
dedicated_fails_with "global.platformSecret.existingSecret.name" \
  "dedicated: refuses a release without DataCore's Secret" --set global.platformSecret.existingSecret.name=
dedicated_fails_with "set global.redis.deploy=false and global.redis.host" \
  "dedicated: refuses an in-cluster Redis" --set global.redis.deploy=true
dedicated_fails_with "global.clickstack.endpoint" \
  "dedicated: refuses a release with no collector" --set global.clickstack.endpoint=
dedicated_fails_with "agentgateway.configSync.existingSecret.name" \
  "dedicated: refuses a release without the config-sync token" --set agentgateway.configSync.existingSecret.name=
dedicated_fails_with "agentgateway.ingress.dataPlane.host" \
  "dedicated: refuses to fall back to a shared SaaS host" --set agentgateway.ingress.dataPlane.host=
