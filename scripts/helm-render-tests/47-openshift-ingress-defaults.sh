#!/usr/bin/env bash
# Render scenarios 47. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"

# ---------------------------------------------------------------------------
# 47. OpenShift with the default Ingress exposure. restricted-v2 must admit
#     every hook Job, the console must advertise the host the router serves,
#     and the router's default certificate must not be replaced by the chart's
#     self-signed placeholder.
# ---------------------------------------------------------------------------
blue "==> Scenario 47: OpenShift Ingress defaults (SCC, public URL, router TLS)"

ocp_args=(
  -f "$CHART_DIR/values-required.yaml" -f "$DATA_PLANE_ON_FILE"
  "${CLICKSTACK_DEFAULT_ARGS[@]}"
  --api-versions route.openshift.io/v1
  --set global.deploymentMode=external
  --set global.platform=openshift
  --set global.domain=apps.example.com
  --set global.mcpOAuth.enabled=true
)

out="$TMP/scenario-47-openshift.yaml"
helm template test "$CHART_DIR" --namespace default "${ocp_args[@]}" > "$out"

# restricted-v2 assigns the UID from the namespace range: no hook may pin one.
assert_not_contains "$out" 'runAsUser: 1001' \
  "openshift: hook Jobs do not pin runAsUser"
assert_not_contains "$out" 'runAsGroup: 1001' \
  "openshift: hook Jobs do not pin runAsGroup"
gen="$TMP/scenario-47-generator.yaml"
document_named_kind "$out" Job neuraltrust-platform-secrets-generator "$gen"
assert_occurrences "$gen" 'type: RuntimeDefault' 2 \
  "openshift: generator Job sets seccompProfile on pod and container"
# The keygen hooks render when the in-cluster generator is off.
out_keygen="$TMP/scenario-47-openshift-keygen.yaml"
helm template test "$CHART_DIR" --namespace default "${ocp_args[@]}" \
  --set global.secrets.generator.enabled=false > "$out_keygen"
assert_not_contains "$out_keygen" 'runAsUser: 1001' \
  "openshift: keygen Jobs do not pin runAsUser"
keygen="$TMP/scenario-47-keygen.yaml"
document_named_kind "$out_keygen" Job neuraltrust-platform-mcp-signing-key "$keygen"
assert_occurrences "$keygen" 'type: RuntimeDefault' 2 \
  "openshift: keygen Job sets seccompProfile on pod and container"

# The console advertises the host its Ingress serves.
assert_env_value "$out" control-plane-app app APP_URL "https://app.apps.example.com" \
  "openshift Ingress: APP_URL is the Ingress host"
assert_env_value "$out" control-plane-app app NEXTAUTH_URL "https://app.apps.example.com" \
  "openshift Ingress: NEXTAUTH_URL is the Ingress host"

# No tls block, so the router's trusted default certificate serves the hosts.
for ing in control-plane-app-ingress control-plane-api-ingress data-plane-api; do
  doc="$TMP/scenario-47-$ing.yaml"
  document_named_kind "$out" Ingress "\"$ing\"" "$doc"
  assert_not_contains "$doc" 'secretName:' \
    "openshift Ingress: $ing leaves TLS to the router"
done
assert_not_contains "$out" 'neuraltrust.local' \
  "openshift Ingress: no self-signed placeholder certificate is issued"

# An operator certificate still lands on the Ingress.
out_cert="$TMP/scenario-47-openshift-cert.yaml"
helm template test "$CHART_DIR" --namespace default "${ocp_args[@]}" \
  --set control-plane-app.controlPlane.components.app.ingress.tls.secretName=app-tls \
  --set global.ingress.tls.autoGenerate=false \
  --set global.ingress.tls.secretName=corp-wildcard \
  > "$out_cert"
doc="$TMP/scenario-47-app-cert.yaml"
document_named_kind "$out_cert" Ingress '"control-plane-app-ingress"' "$doc"
assert_contains "$doc" 'secretName: app-tls' \
  "openshift Ingress: a component secretName is kept"
doc="$TMP/scenario-47-api-cert.yaml"
document_named_kind "$out_cert" Ingress '"control-plane-api-ingress"' "$doc"
assert_contains "$doc" 'secretName: corp-wildcard' \
  "openshift Ingress: autoGenerate=false keeps the operator's shared secret"

# Route exposure (Ingress off) keeps its long host, and the URL follows it.
out_route="$TMP/scenario-47-openshift-route.yaml"
helm template test "$CHART_DIR" --namespace default "${ocp_args[@]}" \
  --set control-plane-app.controlPlane.components.app.ingress.enabled=false \
  > "$out_route"
assert_contains "$out_route" 'host: "control-plane-app.apps.example.com"' \
  "openshift Route: app Route host unchanged"
assert_env_value "$out_route" control-plane-app app APP_URL "https://control-plane-app.apps.example.com" \
  "openshift Route: APP_URL is the Route host"

# Other platforms are unchanged.
out_k8s="$TMP/scenario-47-kubernetes.yaml"
helm template test "$CHART_DIR" --namespace default \
  -f "$CHART_DIR/values-required.yaml" -f "$DATA_PLANE_ON_FILE" \
  "${CLICKSTACK_DEFAULT_ARGS[@]}" \
  --set global.deploymentMode=external \
  --set global.domain=example.com \
  > "$out_k8s"
gen="$TMP/scenario-47-generator-k8s.yaml"
document_named_kind "$out_k8s" Job neuraltrust-platform-secrets-generator "$gen"
assert_contains "$gen" 'runAsUser: 1001' \
  "kubernetes: generator Job keeps runAsUser 1001"
doc="$TMP/scenario-47-app-k8s.yaml"
document_named_kind "$out_k8s" Ingress '"control-plane-app-ingress"' "$doc"
assert_contains "$doc" 'secretName:' \
  "kubernetes: app Ingress keeps its tls block"
