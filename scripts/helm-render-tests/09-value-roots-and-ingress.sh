#!/usr/bin/env bash
# Render scenarios 4, 6, 8, 8b. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

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
assert_resource_count "$out4" Service dataagent 0 \
  "external: TrustGate DataAgent health Service absent"
assert_resource_count "$out4" Service dataagent-trustguard 0 \
  "external: TrustGuard DataAgent health Service absent"
assert_not_contains "$out4" 'dataagent-(trustgate|trustguard)-(readyz|deployment-health)' \
  "external: no orphan DataAgent watchdog checks"

# ---------------------------------------------------------------------------
# 6. watchdog telemetry wiring
# ---------------------------------------------------------------------------
blue "==> Scenario 6: watchdog telemetry wiring"
out6wd="$TMP/scenario-watchdog-external.yaml"
render_default "$out6wd" --set global.deploymentMode=external --set watchdog.enabled=true
# external watchdog → in-cluster ClickStack (signal-neutral base + headers).
assert_env_value "$out6wd" neuraltrust-watchdog watchdog OTEL_EXPORTER_OTLP_ENDPOINT \
  'http://clickstack-collector.default.svc.cluster.local:4318' \
  "watchdog external: OTLP is signal-neutral clickstack-collector :4318"
assert_env_value "$out6wd" neuraltrust-watchdog watchdog OTEL_EXPORTER_OTLP_HEADERS \
  'secretKeyRef:clickstack-collector-secrets/OTEL_EXPORTER_OTLP_HEADERS' \
  "watchdog external: mounts OTEL_EXPORTER_OTLP_HEADERS from clickstack-collector-secrets"
assert_env_value "$out6wd" neuraltrust-watchdog watchdog OPENTELEMETRY_AUTH_TOKEN ABSENT \
  "watchdog external: no hosted OPENTELEMETRY_AUTH_TOKEN"
assert_contains "$out6wd" 'clickstack:' \
  "watchdog external: runner.clickstack block present"
assert_contains "$out6wd" 'address: "clickhouse:9000"' \
  "watchdog external: runner.clickstack defaults to in-cluster ClickHouse native port"
assert_contains "$out6wd" 'database: "otel"' \
  "watchdog external: runner.clickstack database is otel"
assert_contains "$out6wd" 'kind: otlp_freshness' \
  "watchdog external: self-freshness is otlp_freshness (not scrape_staleness)"
# hybrid must NOT wire a local ClickStack address (no in-cluster CH).
out6wd_h="$TMP/scenario-watchdog-hybrid-clickstack.yaml"
render_product_slice "$out6wd_h" -f "$CHART_DIR/values-trustgate.yaml.example" --set watchdog.enabled=true
if awk '/name: neuraltrust-watchdog-config/,/^---/' "$out6wd_h" | grep -q 'clickstack:'; then
  red "FAIL: watchdog hybrid must not default runner.clickstack (no local ClickHouse)"
  awk '/name: neuraltrust-watchdog-config/,/^---/' "$out6wd_h" | head -40
  exit 1
fi
green "ok  - watchdog hybrid: no runner.clickstack default (central SaaS evaluates RED)"

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

# Cloud providers share the same Ingress template path; one representative is enough.
provider=aws
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

# Dual discovery default: empty additionalHosts → auto wildcards + llm./mcp. bases.
blue "==> Scenario 8b: dual discovery auto-derives base domains and wildcards"
outw_auto="$TMP/scenario-wildcard-autoderive.yaml"
render_default "$outw_auto" \
  --set global.domain=platform.example.com
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
