#!/usr/bin/env bash
# Render scenarios 42. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

# ---------------------------------------------------------------------------
# 42. Gateway API — HTTPRoutes replace every Ingress, host for host
# ---------------------------------------------------------------------------
blue "==> Scenario 42: global.ingress.provider=gateway-api"
GATEWAY_API_ARGS=(
  --set global.domain=platform.example.com
  --set global.ingress.provider=gateway-api
  --set 'global.ingress.gatewayApi.parentRefs[0].name=shared'
  --set 'global.ingress.gatewayApi.parentRefs[0].namespace=gateway-system'
  --set 'global.ingress.gatewayApi.parentRefs[0].sectionName=https'
)
# Ingress rules and HTTPRoute hostnames as sorted "host backend" lines, so the
# two providers can be compared for the same values.
route_table() {
  ruby -ryaml -e '
    rows = YAML.load_stream(File.read(ARGV.fetch(0))).compact.flat_map do |d|
      case d["kind"]
      when "Ingress"
        d["spec"]["rules"].map { |r| [r["host"] || "*", r["http"]["paths"][0]["backend"]["service"]["name"]] }
      when "HTTPRoute"
        svc = d["spec"]["rules"][0]["backendRefs"][0]["name"]
        (d["spec"]["hostnames"] || ["*"]).map { |h| [h, svc] }
      else []
      end
    end
    puts rows.map { |r| r.join(" ") }.sort' "$1"
}
for mode in hybrid external saas; do
  out42i="$TMP/gwapi-$mode-ingress.yaml"
  out42r="$TMP/gwapi-$mode-routes.yaml"
  render_default "$out42i" --set global.deploymentMode="$mode" --set global.domain=platform.example.com
  render_default "$out42r" --set global.deploymentMode="$mode" "${GATEWAY_API_ARGS[@]}"
  assert_occurrences "$out42r" '^kind: Ingress$' 0 \
    "gateway-api ($mode): no Ingress objects"
  if [[ "$(route_table "$out42i")" != "$(route_table "$out42r")" ]]; then
    red "FAIL: gateway-api ($mode): HTTPRoutes cover the same hosts and backends as the Ingresses"
    diff <(route_table "$out42i") <(route_table "$out42r") | head -20
    exit 1
  fi
  green "ok  - gateway-api ($mode): HTTPRoutes cover the same hosts and backends as the Ingresses"
done
assert_contains "$out42r" '^    - "\*\.llm\.platform\.example\.com"$' \
  "gateway-api: the per-gateway wildcard host is a route hostname"
assert_contains "$out42r" '^      sectionName: https$' \
  "gateway-api: parentRefs pass through, sectionName included"
assert_not_contains "$out42r" '^kind: HealthCheckPolicy$' \
  "gateway-api: no GKE HealthCheckPolicy where the CRD is not served"
assert_not_contains "$out42r" '^      timeouts:$' \
  "gateway-api: no rule timeouts unless set"

out42g="$TMP/gwapi-gke.yaml"
render_default "$out42g" "${GATEWAY_API_ARGS[@]}" \
  --set global.ingress.gatewayApi.timeouts.request=300s \
  --api-versions networking.gke.io/v1/HealthCheckPolicy
doc42g="$TMP/gwapi-gke-proxy-hc.yaml"
document_named_kind "$out42g" HealthCheckPolicy agentgateway-proxy-healthcheck "$doc42g"
assert_contains "$doc42g" 'requestPath: /readyz' \
  "gateway-api on GKE: the proxy is health-checked on its readiness path"
assert_contains "$out42g" '^        request: 300s$' \
  "gateway-api: rule timeouts render when set"

assert_render_fails_with 'needs global.ingress.gatewayApi.parentRefs' \
  "gateway-api: fails closed without a parent Gateway" \
  --set global.ingress.provider=gateway-api

# NOTES must print the hosts the routes actually claim, so with every
# hostPrefix overridden the two sets are equal (wildcards are route-only).
HOST_PREFIX_ARGS=(
  --set global.deploymentMode=external
  --set agentgateway.ingress.dataPlane.hostPrefix=t-gateway
  --set agentgateway.ingress.mcp.hostPrefix=t-mcp
  --set agentgateway.ingress.controlPlane.hostPrefix=t-admin
  --set trustguard.ingress.dataPlane.hostPrefix=t-trustguard
  --set trustguard.ingress.controlPlane.hostPrefix=t-trustguard-admin
  --set control-plane-api.controlPlane.components.api.hostPrefix=t-api
  --set control-plane-app.controlPlane.components.app.hostPrefix=t-app
  --set data-plane-api.dataPlane.components.api.hostPrefix=t-data-plane-api
  # A moved app host must name the issuers it no longer derives from app.<domain>.
  --set global.mcpOAuth.issuer=https://t-app.platform.example.com/api/mcp/oauth
  --set global.agentgatewayM2m.issuer=https://t-app.platform.example.com
)
for provider in ingress gateway-api; do
  if [[ "$provider" == gateway-api ]]; then
    provider_args=("${GATEWAY_API_ARGS[@]}")
  else
    provider_args=(--set global.domain=platform.example.com)
  fi
  out42h="$TMP/hostprefix-$provider.yaml"
  notes42h="$TMP/hostprefix-$provider-notes.txt"
  render_default "$out42h" "${HOST_PREFIX_ARGS[@]}" "${provider_args[@]}"
  render_notes "$notes42h" "${HOST_PREFIX_ARGS[@]}" "${provider_args[@]}"
  route_hosts="$(route_table "$out42h" | awk '$1 !~ /^\*/ {print $1}' | sort -u)"
  notes_hosts="$(grep -E '^  - [^:]+: +https://' "$notes42h" | grep -oE 'https://[^ ]+' | sed 's#^https://##' | sort -u)"
  if [[ -z "$notes_hosts" || "$route_hosts" != "$notes_hosts" ]]; then
    red "FAIL: NOTES ($provider): endpoints follow each component's hostPrefix"
    diff <(echo "$route_hosts") <(echo "$notes_hosts") | head -20
    exit 1
  fi
  green "ok  - NOTES ($provider): endpoints follow each component's hostPrefix"
done
