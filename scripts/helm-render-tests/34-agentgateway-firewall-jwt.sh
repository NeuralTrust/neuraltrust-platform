#!/usr/bin/env bash
# Render scenarios 34. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

blue "==> Scenario 34: TrustGate data plane firewall client (FIREWALL_JWT)"
DP_NAME="$(ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).dig("dataPlane", "name")' charts/agentgateway/values.yaml)"
JWT="eyJhbGciOiJIUzI1NiJ9.eyJ0eXAiOiJmaXJld2FsbC1jbGllbnQifQ.c2ln"
# agentgateway-secrets is written as stringData, which assert_secret_key does not read.
assert_ag_secret() {
  local file="$1" mode="$2" msg="$3" doc="$TMP/ag-secret-$RANDOM.yaml"
  if [[ "$mode" == absent ]] && ! grep -q '^  name: agentgateway-secrets$' "$file"; then
    green "ok  - $msg"
    return
  fi
  document_named_kind "$file" Secret agentgateway-secrets "$doc"
  if [[ "$mode" == present ]]; then
    assert_contains "$doc" '^  FIREWALL_JWT: ' "$msg"
  else
    assert_not_contains "$doc" 'FIREWALL_JWT' "$msg"
  fi
}

out34a="$TMP/scenario-fwjwt-inline.yaml"
render_default "$out34a" --set agentgateway.firewall.jwt="$JWT"
dp34a="$TMP/scenario-fwjwt-inline-dp.yaml"
document_named_kind "$out34a" Deployment "$DP_NAME" "$dp34a"
cm34a="$TMP/scenario-fwjwt-inline-cm.yaml"
document_named "$out34a" agentgateway-env-vars "$cm34a"
assert_ag_secret "$out34a" present \
  "inline jwt: stored in agentgateway-secrets"
assert_contains "$dp34a" 'name: agentgateway-secrets' \
  "inline jwt: data plane loads agentgateway-secrets"
assert_not_contains "$dp34a" 'name: FIREWALL_SECRET_KEY' \
  "inline jwt: no shared firewall signing key on the data plane"
assert_not_contains "$cm34a" '^  FIREWALL_BASE_URL' \
  "inline jwt: no derived FIREWALL_BASE_URL overriding the token's URL"

out34b="$TMP/scenario-fwjwt-existing.yaml"
render_default "$out34b" --set agentgateway.firewall.existingSecret.name=gw-firewall \
  --set agentgateway.firewall.existingSecret.key=jwt
dp34b="$TMP/scenario-fwjwt-existing-dp.yaml"
document_named_kind "$out34b" Deployment "$DP_NAME" "$dp34b"
assert_contains "$dp34b" 'name: FIREWALL_JWT' \
  "existingSecret: FIREWALL_JWT env entry"
assert_contains "$dp34b" 'name: "gw-firewall"' \
  "existingSecret: reads the operator Secret"
assert_contains "$dp34b" 'key: "jwt"' \
  "existingSecret: honours the configured key"
assert_not_contains "$dp34b" 'name: FIREWALL_SECRET_KEY' \
  "existingSecret: no shared firewall signing key on the data plane"
assert_ag_secret "$out34b" absent \
  "existingSecret: nothing copied into agentgateway-secrets"

out34c="$TMP/scenario-fwjwt-explicit-url.yaml"
render_default "$out34c" --set agentgateway.firewall.jwt="$JWT" \
  --set agentgateway.config.firewallBaseURL=https://fw.example
cm34c="$TMP/scenario-fwjwt-explicit-url-cm.yaml"
document_named "$out34c" agentgateway-env-vars "$cm34c"
assert_contains "$cm34c" '^  FIREWALL_BASE_URL: "https://fw\.example"$' \
  "inline jwt: an explicit config.firewallBaseURL still wins"

out34d="$TMP/scenario-fwjwt-trustgate-only.yaml"
render_product_slice "$out34d" --set global.products.trustgate=true \
  --set agentgateway.firewall.jwt="$JWT"
assert_ag_secret "$out34d" present \
  "TrustGate without TrustGuard: the client still reaches the data plane"
assert_not_contains "$out34d" 'FIREWALL_SECRET_KEY|^  FIREWALL_BASE_URL' \
  "TrustGate without TrustGuard: nothing else firewall-related is wired"

out34e="$TMP/scenario-fwjwt-unset.yaml"
render_default "$out34e"
assert_ag_secret "$out34e" absent \
  "unset: no FIREWALL_JWT"
assert_contains "$out34e" 'name: FIREWALL_SECRET_KEY' \
  "unset: shared firewall signing key wiring unchanged"

assert_render_fails_with "set jwt or existingSecret.name, not both" \
  "jwt and existingSecret together fail the render" \
  --set global.secrets.generator.enabled=false \
  --set agentgateway.firewall.jwt="$JWT" --set agentgateway.firewall.existingSecret.name=gw-firewall
assert_render_fails_with "set agentgateway.firewall.existingSecret.name instead" \
  "inline jwt without chart Secret generation fails the render" \
  --set global.secrets.generator.enabled=false \
  --set global.preserveExistingSecrets=true --set agentgateway.firewall.jwt="$JWT"
