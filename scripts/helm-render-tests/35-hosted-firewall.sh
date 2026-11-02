#!/usr/bin/env bash
# Render scenarios 35. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

# Opt-in NeuralTrust-hosted firewall: TrustGuard authenticates with the
# console-issued FIREWALL_JWT in the trustguard-firewall Secret.
TG_JWT=(--set trustguard.firewall.jwtExistingSecret.name=trustguard-firewall)
HOSTED=(--set global.firewall.deploy=false "${TG_JWT[@]}")
JWT="test-firewall-jwt"

firewall_docs() {  # rendered file, prefix -> TrustGuard data plane + env ConfigMap
  document_named_kind "$1" Deployment trustguard-data-plane "$2-dp.yaml"
  document_named "$1" trustguard-env-vars "$2-cm.yaml"
}

blue "==> Scenario 35a: hybrid keeps the in-cluster firewall by default"
out35a="$TMP/scenario-firewall-hybrid-default.yaml"
render_default "$out35a" "${TG_JWT[@]}"
firewall_docs "$out35a" "$TMP/firewall-hybrid-default"
assert_contains "$out35a" 'name: firewall$' \
  "in-cluster (hybrid default): Firewall gateway renders"
assert_platform_key "$out35a" present JWT_SECRET \
  "in-cluster (hybrid default): firewall JWT_SECRET is generated"
assert_contains "$TMP/firewall-hybrid-default-cm.yaml" 'NEURAL_TRUST_FIREWALL_BASE_URL: "http://firewall\.default\.svc\.cluster\.local"$' \
  "in-cluster (hybrid default): TrustGuard calls the in-release Service"
assert_contains "$TMP/firewall-hybrid-default-dp.yaml" 'name: NEURAL_TRUST_FIREWALL_SECRET_KEY' \
  "in-cluster (hybrid default): TrustGuard signs with the shared key"
assert_not_contains "$TMP/firewall-hybrid-default-dp.yaml" 'FIREWALL_JWT' \
  "in-cluster (hybrid default): a console firewall JWT is ignored"
render_notes "$TMP/firewall-hybrid-default-notes.txt" "${TG_JWT[@]}"
assert_contains "$TMP/firewall-hybrid-default-notes.txt" 'Firewall \(in this cluster\)' \
  "in-cluster (hybrid default): NOTES says where the firewall runs"

blue "==> Scenario 35b: hybrid opts into the NeuralTrust-hosted firewall"
out35b="$TMP/scenario-hosted-hybrid.yaml"
render_default "$out35b" "${HOSTED[@]}"
firewall_docs "$out35b" "$TMP/hosted-hybrid"
assert_not_contains "$out35b" 'name: firewall$' \
  "hosted (hybrid): no in-release Firewall gateway"
assert_not_contains "$out35b" 'name: toxicity-worker' \
  "hosted (hybrid): no in-release Firewall workers"
assert_platform_key "$out35b" absent JWT_SECRET \
  "hosted (hybrid): no firewall JWT_SECRET is generated"
assert_contains "$TMP/hosted-hybrid-dp.yaml" 'name: FIREWALL_JWT' \
  "hosted (hybrid): TrustGuard reads FIREWALL_JWT"
assert_contains "$TMP/hosted-hybrid-dp.yaml" 'name: "trustguard-firewall"' \
  "hosted (hybrid): FIREWALL_JWT comes from jwtExistingSecret"
assert_not_contains "$TMP/hosted-hybrid-dp.yaml" 'NEURAL_TRUST_FIREWALL_SECRET_KEY' \
  "hosted (hybrid): no firewall signing key reaches TrustGuard"
assert_not_contains "$TMP/hosted-hybrid-cm.yaml" 'NEURAL_TRUST_FIREWALL_BASE_URL' \
  "hosted (hybrid): no derived URL overriding the token's"
assert_not_contains "$out35b" 'name: FIREWALL_SECRET_KEY|^  FIREWALL_BASE_URL' \
  "hosted (hybrid): TrustGate without its own JWT gets no firewall wiring"

out35b2="$TMP/scenario-hosted-hybrid-url.yaml"
render_default "$out35b2" "${HOSTED[@]}" --set trustguard.firewall.baseURL=https://firewall.us.neuraltrust.ai
document_named "$out35b2" trustguard-env-vars "$TMP/hosted-hybrid-url-cm.yaml"
assert_contains "$TMP/hosted-hybrid-url-cm.yaml" 'NEURAL_TRUST_FIREWALL_BASE_URL: "https://firewall\.us\.neuraltrust\.ai"$' \
  "hosted: an explicit trustguard.firewall.baseURL still wins"

assert_render_fails_with "global.firewall.deploy=false leaves TrustGuard without a firewall" \
  "hosted (hybrid): no JWT and no baseURL fails the render" --set global.firewall.deploy=false
out35b3="$TMP/scenario-hosted-trustgate-only.yaml"
render_product_slice "$out35b3" --set global.products.trustgate=true --set global.firewall.deploy=false
assert_contains "$out35b3" 'name: agentgateway-proxy' \
  "hosted (hybrid): a TrustGate-only install needs no firewall JWT"

blue "==> Scenario 35c: inline trustguard.firewall.jwt"
out35c="$TMP/scenario-hosted-inline.yaml"
render_default "$out35c" --set global.firewall.deploy=false --set trustguard.firewall.jwt="$JWT"
document_named_kind "$out35c" Secret trustguard-secrets "$TMP/hosted-inline-secret.yaml"
assert_contains "$TMP/hosted-inline-secret.yaml" '^  FIREWALL_JWT: "test-firewall-jwt"$' \
  "inline jwt: stored in trustguard-secrets"
document_named_kind "$out35c" Deployment trustguard-data-plane "$TMP/hosted-inline-dp.yaml"
assert_contains "$TMP/hosted-inline-dp.yaml" 'name: trustguard-secrets' \
  "inline jwt: data plane loads trustguard-secrets"
assert_not_contains "$TMP/hosted-inline-dp.yaml" 'NEURAL_TRUST_FIREWALL_SECRET_KEY' \
  "inline jwt: no firewall signing key reaches TrustGuard"
out35c2="$TMP/scenario-hosted-inline-generator.yaml"
render_default "$out35c2" --set global.firewall.deploy=false --set trustguard.firewall.jwt="$JWT" \
  --set global.secrets.generator.enabled=true
document_named_kind "$out35c2" Secret trustguard-secrets "$TMP/hosted-inline-generator-secret.yaml"
assert_contains "$TMP/hosted-inline-generator-secret.yaml" '^  FIREWALL_JWT: "test-firewall-jwt"$' \
  "inline jwt, secrets generator on: still stored in trustguard-secrets"
assert_render_fails_with "set jwt or jwtExistingSecret.name, not both" \
  "inline jwt and jwtExistingSecret together fail the render" \
  --set global.secrets.generator.enabled=false "${HOSTED[@]}" --set trustguard.firewall.jwt="$JWT"
assert_render_fails_with "set trustguard.firewall.jwtExistingSecret.name instead" \
  "inline jwt without chart Secret generation fails the render" \
  --set global.secrets.generator.enabled=false --set global.preserveExistingSecrets=true \
  --set global.firewall.deploy=false --set trustguard.firewall.jwt="$JWT"

blue "==> Scenario 35d: external keeps the in-cluster firewall; hosted is opt-in"
out35d="$TMP/scenario-hosted-external-default.yaml"
render_default "$out35d" --set global.deploymentMode=external "${TG_JWT[@]}"
document_named_kind "$out35d" Deployment trustguard-data-plane "$TMP/hosted-external-default-dp.yaml"
assert_contains "$out35d" 'name: firewall$' \
  "external default: Firewall gateway renders"
assert_not_contains "$TMP/hosted-external-default-dp.yaml" 'FIREWALL_JWT' \
  "external default: a firewall JWT is ignored while the firewall runs here"
out35d2="$TMP/scenario-hosted-external-optin.yaml"
render_default "$out35d2" --set global.deploymentMode=external "${HOSTED[@]}"
document_named_kind "$out35d2" Deployment trustguard-data-plane "$TMP/hosted-external-optin-dp.yaml"
assert_not_contains "$out35d2" 'name: firewall$' \
  "external hosted opt-in: no in-release Firewall gateway"
assert_contains "$TMP/hosted-external-optin-dp.yaml" 'name: FIREWALL_JWT' \
  "external hosted opt-in: TrustGuard reads the key NeuralTrust issued"
assert_not_contains "$out35d2" 'NEURAL_TRUST_FIREWALL_SECRET_KEY|name: FIREWALL_SECRET_KEY' \
  "external hosted opt-in: no firewall signing key anywhere"

blue "==> Scenario 35e: a firewall the operator runs outranks the JWT"
out35e="$TMP/scenario-hosted-operator-firewall.yaml"
render_default "$out35e" "${HOSTED[@]}" \
  --set global.firewall.baseURL=http://firewall.firewall.svc.cluster.local \
  --set global.firewall.existingSecret.name=firewall-jwt
firewall_docs "$out35e" "$TMP/hosted-operator-firewall"
assert_contains "$TMP/hosted-operator-firewall-cm.yaml" 'NEURAL_TRUST_FIREWALL_BASE_URL: "http://firewall\.firewall\.svc\.cluster\.local"$' \
  "operator firewall: TrustGuard calls the operator's URL"
assert_not_contains "$TMP/hosted-operator-firewall-dp.yaml" 'FIREWALL_JWT' \
  "operator firewall: the console's firewall JWT is ignored"

blue "==> Scenario 35f: watchdog probes only an in-release firewall"
out35f="$TMP/scenario-hosted-watchdog.yaml"
render_default "$out35f" --set watchdog.enabled=true "${HOSTED[@]}"
assert_contains "$out35f" 'enabled: false'$'\n''        id: firewall-health' \
  "hosted: watchdog firewall-health stays off"
out35f2="$TMP/scenario-hosted-watchdog-incluster.yaml"
render_default "$out35f2" --set watchdog.enabled=true
assert_contains "$out35f2" 'enabled: true'$'\n''        id: firewall-health' \
  "in-cluster: watchdog firewall-health is on"
