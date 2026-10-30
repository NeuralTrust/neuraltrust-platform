#!/usr/bin/env bash
# Render scenarios 9. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"

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

# A Route is readable by anyone holding route/get, so it must never carry key
# material. TLS Secrets are referenced through spec.tls.externalCertificate.
out_ocp_tls="$TMP/scenario-openshift-route-tls.yaml"
helm template test "$CHART_DIR" --namespace default \
  -f "$CHART_DIR/values-required.yaml" \
  "${CLICKSTACK_DEFAULT_ARGS[@]}" \
  --api-versions route.openshift.io/v1 \
  --set global.deploymentMode=external \
  --set global.platform=openshift \
  --set global.domain=apps.example.com \
  --set control-plane-app.controlPlane.components.app.ingress.enabled=false \
  --set control-plane-app.controlPlane.components.app.ingress.tls.secretName=app-tls \
  --set control-plane-api.controlPlane.components.api.ingress.enabled=false \
  --set control-plane-api.controlPlane.components.api.ingress.tls.secretName=api-tls \
  --set data-plane-api.dataPlane.components.api.ingress.enabled=false \
  --set data-plane-api.dataPlane.components.api.ingress.tls.secretName=dp-tls \
  > "$out_ocp_tls"

assert_occurrences "$out_ocp_tls" '^    externalCertificate:$' 3 \
  "openshift Route TLS: all three Routes reference a TLS Secret"
for _s in app-tls api-tls dp-tls; do
  if ! grep -A1 -E '^    externalCertificate:$' "$out_ocp_tls" | grep -qE "name: \"${_s}\""; then
    red "FAIL: openshift Route TLS: externalCertificate does not reference ${_s}"
    exit 1
  fi
  green "ok  - openshift Route TLS: externalCertificate references ${_s}"
done
if awk '/^kind: Route$/{r=1} /^---$/{r=0} r' "$out_ocp_tls" | grep -qE 'PRIVATE KEY|^ +key:'; then
  red "FAIL: openshift Route TLS: a Route contains private key material"
  exit 1
fi
green "ok  - openshift Route TLS: no Route contains private key material"

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
