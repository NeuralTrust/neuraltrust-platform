#!/usr/bin/env bash
# Render scenario 36. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

# ---------------------------------------------------------------------------
# dedicated mode: one product data plane for a single instance, in a cluster that
# already runs its control plane, Redis and collector. Wired like a hybrid data
# plane, minus DataAgent, Postgres, the in-cluster Redis and the shared hostnames.
# values-required.yaml is a hybrid customer file, so these renders start clean.
# ---------------------------------------------------------------------------
blue "==> Scenario 36: dedicated mode (single-instance data plane)"

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
  --set agentgateway.trustguard.baseURL=http://trustguard-data.trustguard.svc.cluster.local:8081
  --set global.v2.trustguardClientSecretName=trustgate-abc-credentials
  --set agentgateway.configSync.existingSecret.name=trustgate-abc-credentials
  --set agentgateway.ingress.dataPlane.host=acme.llm.dev.example.com
  --set agentgateway.ingress.mcp.host=acme.mcp.dev.example.com
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

out36="$TMP/scenario-dedicated.yaml"
render_dedicated "$out36"
assert_contains "$out36" 'name: agentgateway-proxy' \
  "dedicated: renders the TrustGate proxy"
assert_contains "$out36" 'name: agentgateway-mcp' \
  "dedicated: renders the TrustGate MCP server"
for absent in dataagent clickstack-egress-collector control-plane-postgresql 'name: redis$' data-plane-api 'name: agentgateway-admin$' 'name: trustguard-data-plane$' neuraltrust-ingress-tls; do
  assert_not_contains "$out36" "$absent" "dedicated: does not render $absent"
done
assert_not_contains "$out36" '^kind: Ingress$' \
  "dedicated: attaches HTTPRoutes to the cluster Gateway instead of creating a load balancer"
assert_contains "$out36" '"acme.llm.dev.example.com"' \
  "dedicated: the proxy route serves the plane's own host"
assert_contains "$out36" '"acme.mcp.dev.example.com"' \
  "dedicated: the MCP route serves the plane's own MCP host"
assert_not_contains "$out36" '\*\.' \
  "dedicated: no wildcard host that would overlap the shared SaaS hosts"
assert_contains "$out36" 'name: CONFIG_SYNC_DATA_PLANE_ENABLED'$'\n''          value: "true"' \
  "dedicated: the proxy is a config-sync data plane"
assert_contains "$out36" 'OTEL_EXPORTER_OTLP_ENDPOINT: "http://clickstack-collector.otel.svc.cluster.local:4318/v1/logs"' \
  "dedicated: OTLP goes straight to the cluster's collector"
assert_contains "$out36" 'TELEMETRY_EXPORTERS_RAW: "\[\{\\"name\\":\\"raw-otlp\\"' \
  "dedicated: raw telemetry is exported, never stored locally"
assert_contains "$out36" 'name: OTEL_EXPORTER_OTLP_HEADERS'$'\n''          valueFrom:'$'\n''            secretKeyRef:'$'\n''              name: "trustgate-abc-credentials"' \
  "dedicated: the collector auth header comes from the platform Secret"
assert_contains "$out36" 'REDIS_DB: "3"' \
  "dedicated: Redis DB follows agentgateway.redis.db"
assert_contains "$out36" 'TRUSTGUARD_BASE_URL: "http://trustguard-data.trustguard.svc.cluster.local:8081"' \
  "dedicated: the plane calls the TrustGuard the controller names"
assert_contains "$out36" 'name: TRUSTGUARD_CLIENT_SECRET'$'\n''          valueFrom:'$'\n''            secretKeyRef:'$'\n''              name: trustgate-abc-credentials' \
  "dedicated: the TrustGuard client comes from the controller's Secret"
out36b="$TMP/scenario-dedicated-no-guard.yaml"
render_dedicated "$out36b" --set agentgateway.trustguard.baseURL=
assert_not_contains "$out36b" 'TRUSTGUARD_BASE_URL' \
  "dedicated: no TrustGuard URL unless the controller names one"
assert_not_contains "$out36" 'name: (DB_HOST|POSTGRES_HOST)' \
  "dedicated: no Postgres wiring"
assert_contains "$out36" 'name: "?trustgate-abc-credentials"?'$'\n''              key: "?SERVER_SECRET_KEY"?' \
  "dedicated: SERVER_SECRET_KEY comes from the platform Secret"
assert_contains "$out36" 'REDIS_HOST: "?MTAuMC4wLjU="?' \
  "dedicated: Redis points at the cluster's Redis"

dedicated_fails_with "exactly one of global.products.trustgate and global.products.trustguard" \
  "dedicated: refuses two products in one plane" --set global.products.trustguard=true
dedicated_fails_with "exactly one of global.products.trustgate and global.products.trustguard" \
  "dedicated: refuses a plane with no product" --set global.products.trustgate=false
dedicated_fails_with "global.products.dataPlane is not supported" \
  "dedicated: refuses the data-plane product" --set global.products.dataPlane=true
dedicated_fails_with "global.platformSecret.existingSecret.name" \
  "dedicated: refuses a release without the platform Secret" --set global.platformSecret.existingSecret.name=
dedicated_fails_with "set global.redis.deploy=false and global.redis.host" \
  "dedicated: refuses an in-cluster Redis" --set global.redis.deploy=true
dedicated_fails_with "global.clickstack.endpoint" \
  "dedicated: refuses a release with no collector" --set global.clickstack.endpoint=
dedicated_fails_with "agentgateway.configSync.existingSecret.name" \
  "dedicated: refuses a release without the config-sync token" --set agentgateway.configSync.existingSecret.name=
dedicated_fails_with "agentgateway.ingress.dataPlane.host" \
  "dedicated: refuses to fall back to a shared SaaS host" --set agentgateway.ingress.dataPlane.host=
