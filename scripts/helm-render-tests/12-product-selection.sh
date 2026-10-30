#!/usr/bin/env bash
# Render scenarios 11, 11a, 11b, 11c, 11d, 11e, 11e2, 11f. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

# ---------------------------------------------------------------------------
# 11. Positive hybrid product selection
# ---------------------------------------------------------------------------
blue "==> Scenario 11: hybrid with no product selected fails fast"
assert_render_fails "hybrid no-selection: requires at least one product" \
  "${HYBRID_NO_PRODUCTS[@]}"

blue "==> Scenario 11a: trustgate-only hybrid"
out11a="$TMP/scenario-trustgate-only.yaml"
render_product_slice "$out11a" -f "$CHART_DIR/values-trustgate.yaml.example" --set watchdog.enabled=true
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
assert_resource_count "$out11a" Service dataagent 1 "trustgate-only: health Service present"
assert_resource_count "$out11a" Service dataagent-trustguard 0 "trustgate-only: TrustGuard health Service absent"
assert_contains "$out11a" 'id: dataagent-trustgate-(readyz|deployment-health)' "trustgate-only: applicable watchdog checks render"
assert_not_contains "$out11a" 'id: dataagent-trustguard-(readyz|deployment-health)' "trustgate-only: TrustGuard watchdog checks omitted"
assert_env_value "$out11a" neuraltrust-watchdog watchdog OTEL_EXPORTER_OTLP_ENDPOINT \
  'http://clickstack-egress-collector.default.svc.cluster.local:4318' \
  "trustgate-only: watchdog OTLP via local egress :4318"
assert_env_value "$out11a" neuraltrust-watchdog watchdog OPENTELEMETRY_AUTH_TOKEN ABSENT \
  "trustgate-only: watchdog has no hosted auth token"

blue "==> Scenario 11b: trustguard-only hybrid"
out11b="$TMP/scenario-trustguard-only.yaml"
render_product_slice "$out11b" -f "$CHART_DIR/values-trustguard.yaml.example" --set watchdog.enabled=true
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
assert_resource_count "$out11b" Service dataagent 0 "trustguard-only: TrustGate health Service absent"
assert_resource_count "$out11b" Service dataagent-trustguard 1 "trustguard-only: health Service present"
assert_contains "$out11b" 'id: dataagent-trustguard-(readyz|deployment-health)' "trustguard-only: applicable watchdog checks render"
assert_not_contains "$out11b" 'id: dataagent-trustgate-(readyz|deployment-health)' "trustguard-only: TrustGate watchdog checks omitted"
assert_env_value "$out11b" neuraltrust-watchdog watchdog OTEL_EXPORTER_OTLP_ENDPOINT \
  'http://clickstack-egress-collector.default.svc.cluster.local:4318' \
  "trustguard-only: watchdog OTLP via local egress :4318"
assert_env_value "$out11b" neuraltrust-watchdog watchdog OPENTELEMETRY_AUTH_TOKEN ABSENT \
  "trustguard-only: watchdog has no hosted auth token"

blue "==> Scenario 11c: data-plane-only (red-teaming) hybrid — no DataAgent"
out11c="$TMP/scenario-red-teaming-only.yaml"
render_product_slice "$out11c" -f "$CHART_DIR/values-red-teaming.yaml.example" --set watchdog.enabled=true
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
assert_resource_count "$out11c" Service dataagent 0 "red-teaming: TrustGate health Service absent"
assert_resource_count "$out11c" Service dataagent-trustguard 0 "red-teaming: TrustGuard health Service absent"
assert_not_contains "$out11c" 'id: dataagent-(trustgate|trustguard)-(readyz|deployment-health)' "red-teaming: no orphan DataAgent watchdog checks"
# no egress → no fabricated OTLP default (override only).
assert_env_value "$out11c" neuraltrust-watchdog watchdog OTEL_EXPORTER_OTLP_ENDPOINT ABSENT \
  "red-teaming: watchdog has no default OTLP endpoint without egress"
assert_env_value "$out11c" neuraltrust-watchdog watchdog OPENTELEMETRY_AUTH_TOKEN ABSENT \
  "red-teaming: watchdog has no hosted auth token"

blue "==> Scenario 11d: positive slices compose pairwise and all together"
out11d1="$TMP/scenario-trustgate-trustguard.yaml"
render_product_slice "$out11d1" \
  -f "$CHART_DIR/values-trustgate.yaml.example" \
  -f "$CHART_DIR/values-trustguard.yaml.example" \
  --set watchdog.enabled=true
assert_contains "$out11d1" 'name: dataagent$' \
  "trustgate+trustguard: stable TrustGate DataAgent"
assert_contains "$out11d1" 'name: dataagent-trustguard$' \
  "trustgate+trustguard: fixed TrustGuard DataAgent"
assert_occurrences "$out11d1" '^  name: clickstack-egress-collector$' 1 \
  "trustgate+trustguard: exactly one egress Service"
assert_resource_count "$out11d1" Service dataagent 1 "trustgate+trustguard: TrustGate health Service renders once"
assert_resource_count "$out11d1" Service dataagent-trustguard 1 "trustgate+trustguard: TrustGuard health Service renders once"
for product in trustgate trustguard; do
  assert_contains "$out11d1" "id: dataagent-${product}-readyz" "trustgate+trustguard: ${product} readyz check renders"
  assert_contains "$out11d1" "id: dataagent-${product}-deployment-health" "trustgate+trustguard: ${product} deployment check renders"
done
assert_occurrences "$out11d1" '^        dryRun: true$' 4 "trustgate+trustguard: all DataAgent checks are explicit dry-run"
assert_occurrences "$out11d1" '^        actions: \[notify\.otlp, notify\.slack\]$' 4 "trustgate+trustguard: all DataAgent checks are notifier-only"

# Pairwise red-teaming combos are covered by 11a–c + all-products (11d4).
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
  -f "$CHART_DIR/values-external.yaml.example" > "$out11e"
validate_yaml "$out11e"
assert_contains "$out11e" 'name: agentgateway-admin' \
  "external no-products: AgentGateway admin renders"
assert_contains "$out11e" 'name: trustguard-control-plane' \
  "external no-products: TrustGuard control plane renders"
assert_contains "$out11e" 'name: data-plane-api' \
  "external no-products: data-plane-api renders"
assert_contains "$out11e" 'name: firewall$' \
  "external no-products: Firewall renders"
assert_contains "$out11e" 'name: complexity-worker$' \
  "external no-products: the TrustGate complexity worker renders"

blue "==> Scenario 11e2: external TrustGuard-only overlay opts TrustGate out"
# External is opt-out: unset products are on (11e), an explicit false removes
# the product and everything that exists only to serve it.
out11e2="$TMP/scenario-external-trustguard-only.yaml"
helm template test "$CHART_DIR" --namespace default \
  -f "$CHART_DIR/values-external.yaml.example" \
  -f "$CHART_DIR/values-external-trustguard-only.yaml.example" > "$out11e2"
validate_yaml "$out11e2"
for _gone in agentgateway-admin agentgateway-proxy agentgateway-mcp agentgateway-secrets \
             complexity-worker neuraltrust-platform-mcp-signing-key \
             neuraltrust-platform-agentgateway-m2m-keys; do
  assert_not_contains "$out11e2" "^  name: \"?${_gone}\"?$" \
    "external trustguard-only: $_gone is not rendered"
done
for _kept in trustguard-control-plane trustguard-data-plane firewall toxicity-worker \
             control-plane-app control-plane-api data-plane-api datacore alertengine-api clickhouse; do
  assert_contains "$out11e2" "^  name: \"?${_kept}\"?$" \
    "external trustguard-only: $_kept still renders"
done
# The app must not reference agentgateway-secrets / SERVER_SECRET_KEY: nothing
# writes it here, and a required secretKeyRef would stop the pod.
assert_not_contains "$out11e2" 'name: AGENTGATEWAY_|name: MCP_OAUTH_|name: AGENTGATEWAY_M2M_' \
  "external trustguard-only: the app carries no TrustGate, MCP OAuth or M2M env"
assert_not_contains "$out11e2" 'SERVER_SECRET_KEY' \
  "external trustguard-only: SERVER_SECRET_KEY is neither generated nor referenced"
assert_contains "$out11e2" 'name: TRUSTGUARD_JWT_SECRET' \
  "external trustguard-only: the app keeps its TrustGuard credentials"
assert_render_fails_with 'global.mcpOAuth.enabled=true requires TrustGate' \
  "external trustguard-only: forcing MCP OAuth on is rejected" \
  --set global.deploymentMode=external --set global.products.trustgate=false \
  --set global.mcpOAuth.enabled=true
assert_render_fails_with 'global.agentgatewayM2m.enabled=true requires TrustGate' \
  "external trustguard-only: forcing Admin API machine credentials on is rejected" \
  --set global.deploymentMode=external --set global.products.trustgate=false \
  --set global.agentgatewayM2m.enabled=true

blue "==> Scenario 11f: global.saasRegion picks the SaaS behind a hybrid install"
# EU is the default, so an install that never sets the knob must render the
# historical hostnames byte-for-byte.
out11f_eu="$TMP/scenario-saas-region-eu.yaml"
render_product_slice "$out11f_eu" \
  -f "$CHART_DIR/values-trustgate.yaml.example" \
  -f "$CHART_DIR/values-trustguard.yaml.example" \
  --set watchdog.enabled=true
assert_contains "$out11f_eu" 'value: "agentgateway-configsync\.neuraltrust\.ai:443"' \
  "saasRegion default: TrustGate config-sync stays EU"
assert_contains "$out11f_eu" 'value: "trustguard-configsync\.neuraltrust\.ai:443"' \
  "saasRegion default: TrustGuard config-sync stays EU"
assert_contains "$out11f_eu" 'DATABRIDGE_ADDR: "databridge\.neuraltrust\.ai:443"' \
  "saasRegion default: DataBridge stays EU"
assert_contains "$out11f_eu" 'endpoint: "https://telemetry\.neuraltrust\.ai"' \
  "saasRegion default: ClickStack egress stays EU"

# One value moves config-sync, DataBridge and telemetry together — the bug was
# that each had to be overridden separately, so US installs silently kept EU.
out11f_us="$TMP/scenario-saas-region-us.yaml"
render_product_slice "$out11f_us" \
  -f "$CHART_DIR/values-trustgate.yaml.example" \
  -f "$CHART_DIR/values-trustguard.yaml.example" \
  --set watchdog.enabled=true \
  --set global.saasRegion=us
assert_contains "$out11f_us" 'value: "agentgateway-configsync\.us\.neuraltrust\.ai:443"' \
  "saasRegion us: TrustGate config-sync targets US"
assert_contains "$out11f_us" 'value: "agentgateway-configsync\.us\.neuraltrust\.ai"' \
  "saasRegion us: TrustGate config-sync SNI targets US"
assert_contains "$out11f_us" 'value: "trustguard-configsync\.us\.neuraltrust\.ai:443"' \
  "saasRegion us: TrustGuard config-sync targets US"
assert_contains "$out11f_us" 'DATABRIDGE_ADDR: "databridge\.us\.neuraltrust\.ai:443"' \
  "saasRegion us: DataBridge targets US"
assert_contains "$out11f_us" 'DATABRIDGE_SERVER_NAME: "databridge\.us\.neuraltrust\.ai"' \
  "saasRegion us: DataBridge SNI follows the address"
assert_contains "$out11f_us" 'endpoint: "https://telemetry\.us\.neuraltrust\.ai"' \
  "saasRegion us: ClickStack egress targets US"
assert_not_contains "$out11f_us" '(configsync|databridge|telemetry)\.neuraltrust\.ai' \
  "saasRegion us: no EU SaaS hostname survives anywhere in the render"
# Watchdog OTLP is in-cluster and must stay that way.
# The region reaches it through the egress sidecar, not through its own endpoint.
assert_env_value "$out11f_us" neuraltrust-watchdog watchdog OTEL_EXPORTER_OTLP_ENDPOINT \
  'http://clickstack-egress-collector.default.svc.cluster.local:4318' \
  "saasRegion us: watchdog OTLP stays in-cluster"
assert_env_value "$out11f_us" neuraltrust-watchdog watchdog OPENTELEMETRY_AUTH_TOKEN ABSENT \
  "saasRegion us: watchdog still has no hosted auth token"

# Per-endpoint overrides predate the region knob and must keep winning.
out11f_override="$TMP/scenario-saas-region-override.yaml"
render_product_slice "$out11f_override" \
  -f "$CHART_DIR/values-trustgate.yaml.example" \
  --set global.saasRegion=us \
  --set agentgateway.configSync.saasDomain=example.com \
  --set dataagent.databridge.addr=databridge.example.com:9443 \
  --set global.clickstack.egress.endpoint=https://telemetry.example.com
assert_contains "$out11f_override" 'value: "agentgateway-configsync\.example\.com:443"' \
  "saasRegion override: explicit saasDomain beats the region"
assert_contains "$out11f_override" 'DATABRIDGE_ADDR: "databridge\.example\.com:9443"' \
  "saasRegion override: explicit DataBridge address beats the region"
assert_contains "$out11f_override" 'DATABRIDGE_SERVER_NAME: "databridge\.example\.com"' \
  "saasRegion override: SNI derives from the overridden address"
assert_contains "$out11f_override" 'endpoint: "https://telemetry\.example\.com"' \
  "saasRegion override: explicit egress endpoint beats the region"

assert_render_fails_with 'global.saasRegion must be "eu" or "us"' \
  "saasRegion: an unknown region fails the render instead of quietly staying EU" \
  --set global.saasRegion=emea
