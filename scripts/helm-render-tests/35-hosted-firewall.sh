#!/usr/bin/env bash
# Render scenarios 35. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

# Every mode calls the NeuralTrust-hosted firewall by default. values-required.yaml
# points TrustGuard at its FIREWALL_JWT in the trustguard-firewall Secret.
NO_TG_JWT=(--set trustguard.firewall.jwtExistingSecret.name=)
IN_CLUSTER=(--set global.firewall.deploy=true)
SAAS=(--set global.deploymentMode=saas --set global.domain=cp.example.com)
JWT="test-firewall-jwt"

firewall_docs() {  # rendered file, prefix -> TrustGuard data plane + env ConfigMap
  document_named_kind "$1" Deployment trustguard-data-plane "$2-dp.yaml"
  document_named "$1" trustguard-env-vars "$2-cm.yaml"
}

blue "==> Scenario 35a: every mode defaults to the NeuralTrust-hosted firewall"
for mode in hybrid external saas; do
  out35a="$TMP/scenario-hosted-$mode.yaml"
  if [[ "$mode" == saas ]]; then
    render_default "$out35a" "${SAAS[@]}"
  else
    render_default "$out35a" --set global.deploymentMode="$mode"
  fi
  firewall_docs "$out35a" "$TMP/hosted-$mode"
  assert_not_contains "$out35a" 'name: firewall$' \
    "hosted ($mode default): no in-release Firewall gateway"
  assert_not_contains "$out35a" 'name: toxicity-worker' \
    "hosted ($mode default): no in-release Firewall workers"
  assert_platform_key "$out35a" absent JWT_SECRET \
    "hosted ($mode default): no firewall JWT_SECRET is generated"
  assert_contains "$TMP/hosted-$mode-dp.yaml" 'name: "trustguard-firewall"' \
    "hosted ($mode default): TrustGuard reads FIREWALL_JWT from jwtExistingSecret"
  assert_not_contains "$TMP/hosted-$mode-dp.yaml" 'NEURAL_TRUST_FIREWALL_SECRET_KEY' \
    "hosted ($mode default): no firewall signing key reaches TrustGuard"
  assert_not_contains "$TMP/hosted-$mode-cm.yaml" 'NEURAL_TRUST_FIREWALL_BASE_URL' \
    "hosted ($mode default): no derived URL overriding the token's"
  assert_not_contains "$out35a" 'name: FIREWALL_SECRET_KEY|^  FIREWALL_BASE_URL' \
    "hosted ($mode default): TrustGate without its own JWT gets no firewall wiring"
done
render_notes "$TMP/hosted-notes.txt"
assert_contains "$TMP/hosted-notes.txt" 'Firewall: NeuralTrust-hosted' \
  "hosted: NOTES says where the firewall runs"

out35a2="$TMP/scenario-hosted-url.yaml"
render_default "$out35a2" --set trustguard.firewall.baseURL=https://firewall.us.neuraltrust.ai
document_named "$out35a2" trustguard-env-vars "$TMP/hosted-url-cm.yaml"
assert_contains "$TMP/hosted-url-cm.yaml" 'NEURAL_TRUST_FIREWALL_BASE_URL: "https://firewall\.us\.neuraltrust\.ai"$' \
  "hosted: an explicit trustguard.firewall.baseURL still wins"

blue "==> Scenario 35b: TrustGuard without a firewall JWT fails closed"
assert_render_fails_with "that app.neuraltrust.ai showed" \
  "hosted (hybrid): no JWT fails the render, pointing at the console" "${NO_TG_JWT[@]}"
assert_render_fails_with "set global.firewall.deploy: true" \
  "hosted (hybrid): no JWT fails a helm upgrade too, naming the opt-out" "${NO_TG_JWT[@]}" --is-upgrade
assert_render_fails_with "ask NeuralTrust for this install's FIREWALL_JWT" \
  "hosted (external): no JWT fails the render, pointing at NeuralTrust" \
  --set global.deploymentMode=external "${NO_TG_JWT[@]}"
assert_render_fails_with "ask NeuralTrust for this install's FIREWALL_JWT" \
  "hosted (saas): no JWT fails the render, pointing at NeuralTrust" "${SAAS[@]}" "${NO_TG_JWT[@]}"
out35b="$TMP/scenario-hosted-trustgate-only.yaml"
render_product_slice "$out35b" --set global.products.trustgate=true "${NO_TG_JWT[@]}"
assert_contains "$out35b" 'name: agentgateway-proxy' \
  "hosted: a TrustGate-only install needs no firewall JWT"

blue "==> Scenario 35c: global.firewall.deploy=true keeps the in-cluster firewall"
for mode in hybrid external; do
  out35c="$TMP/scenario-incluster-$mode.yaml"
  render_default "$out35c" --set global.deploymentMode="$mode" "${IN_CLUSTER[@]}"
  firewall_docs "$out35c" "$TMP/incluster-$mode"
  assert_contains "$out35c" 'name: firewall$' \
    "in-cluster ($mode): Firewall gateway renders"
  assert_platform_key "$out35c" present JWT_SECRET \
    "in-cluster ($mode): firewall JWT_SECRET is generated"
  assert_contains "$TMP/incluster-$mode-cm.yaml" 'NEURAL_TRUST_FIREWALL_BASE_URL: "http://firewall\.default\.svc\.cluster\.local"$' \
    "in-cluster ($mode): TrustGuard calls the in-release Service"
  assert_contains "$TMP/incluster-$mode-dp.yaml" 'name: NEURAL_TRUST_FIREWALL_SECRET_KEY' \
    "in-cluster ($mode): TrustGuard signs with the shared key"
  assert_not_contains "$TMP/incluster-$mode-dp.yaml" 'FIREWALL_JWT' \
    "in-cluster ($mode): the firewall JWT is ignored"
done
render_notes "$TMP/incluster-notes.txt" "${IN_CLUSTER[@]}"
assert_contains "$TMP/incluster-notes.txt" 'Firewall \(in this cluster\)' \
  "in-cluster: NOTES says where the firewall runs"

blue "==> Scenario 35d: inline trustguard.firewall.jwt"
out35d="$TMP/scenario-hosted-inline.yaml"
render_default "$out35d" "${NO_TG_JWT[@]}" --set trustguard.firewall.jwt="$JWT"
document_named_kind "$out35d" Secret trustguard-secrets "$TMP/hosted-inline-secret.yaml"
assert_contains "$TMP/hosted-inline-secret.yaml" '^  FIREWALL_JWT: "test-firewall-jwt"$' \
  "inline jwt: stored in trustguard-secrets"
document_named_kind "$out35d" Deployment trustguard-data-plane "$TMP/hosted-inline-dp.yaml"
assert_contains "$TMP/hosted-inline-dp.yaml" 'name: trustguard-secrets' \
  "inline jwt: data plane loads trustguard-secrets"
assert_not_contains "$TMP/hosted-inline-dp.yaml" 'NEURAL_TRUST_FIREWALL_SECRET_KEY' \
  "inline jwt: no firewall signing key reaches TrustGuard"
out35d2="$TMP/scenario-hosted-inline-generator.yaml"
render_default "$out35d2" "${NO_TG_JWT[@]}" --set trustguard.firewall.jwt="$JWT" \
  --set global.secrets.generator.enabled=true
document_named_kind "$out35d2" Secret trustguard-secrets "$TMP/hosted-inline-generator-secret.yaml"
assert_contains "$TMP/hosted-inline-generator-secret.yaml" '^  FIREWALL_JWT: "test-firewall-jwt"$' \
  "inline jwt, secrets generator on: still stored in trustguard-secrets"
assert_render_fails_with "set jwt or jwtExistingSecret.name, not both" \
  "inline jwt and jwtExistingSecret together fail the render" \
  --set global.secrets.generator.enabled=false --set trustguard.firewall.jwt="$JWT"
assert_render_fails_with "set trustguard.firewall.jwtExistingSecret.name instead" \
  "inline jwt without chart Secret generation fails the render" \
  --set global.secrets.generator.enabled=false --set global.preserveExistingSecrets=true \
  "${NO_TG_JWT[@]}" --set trustguard.firewall.jwt="$JWT"

blue "==> Scenario 35e: external control plane also uses the firewall JWT"
out35e="$TMP/scenario-hosted-external-cp.yaml"
render_default "$out35e" --set global.deploymentMode=external
document_named_kind "$out35e" Deployment trustguard-control-plane "$TMP/hosted-external-cp.yaml"
assert_contains "$TMP/hosted-external-cp.yaml" 'name: "trustguard-firewall"' \
  "hosted (external): the TrustGuard control plane reads FIREWALL_JWT too"
assert_not_contains "$TMP/hosted-external-cp.yaml" 'NEURAL_TRUST_FIREWALL_SECRET_KEY' \
  "hosted (external): no firewall signing key on the control plane"

blue "==> Scenario 35f: a firewall the operator runs outranks the JWT"
out35f="$TMP/scenario-hosted-operator-firewall.yaml"
render_default "$out35f" --set global.firewall.deploy=false \
  --set global.firewall.baseURL=http://firewall.firewall.svc.cluster.local \
  --set global.firewall.existingSecret.name=firewall-jwt
firewall_docs "$out35f" "$TMP/hosted-operator-firewall"
assert_contains "$TMP/hosted-operator-firewall-cm.yaml" 'NEURAL_TRUST_FIREWALL_BASE_URL: "http://firewall\.firewall\.svc\.cluster\.local"$' \
  "operator firewall: TrustGuard calls the operator's URL"
assert_not_contains "$TMP/hosted-operator-firewall-dp.yaml" 'FIREWALL_JWT' \
  "operator firewall: the firewall JWT is ignored"

blue "==> Scenario 35g: watchdog probes only an in-release firewall"
out35g="$TMP/scenario-hosted-watchdog.yaml"
render_default "$out35g" --set watchdog.enabled=true
assert_contains "$out35g" 'enabled: false'$'\n''        id: firewall-health' \
  "hosted: watchdog firewall-health stays off"
out35g2="$TMP/scenario-hosted-watchdog-incluster.yaml"
render_default "$out35g2" --set watchdog.enabled=true "${IN_CLUSTER[@]}"
assert_contains "$out35g2" 'enabled: true'$'\n''        id: firewall-health' \
  "in-cluster: watchdog firewall-health is on"
