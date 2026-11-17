#!/usr/bin/env bash
# Render scenario 45. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

# ---------------------------------------------------------------------------
# agentgateway.secretStores: the store file TrustGate's planes resolve secret
# references against. Without stores nothing renders. With stores: hybrid
# loads it on proxy + mcp, external and saas on admin + proxy + mcp, and
# dedicated (NeuralTrust-hosted) refuses it. Credentials come from Secrets
# mounted read-only, never from values.
# ---------------------------------------------------------------------------
blue "==> Scenario 45: agentgateway secret stores"

STORES_FILE="$TMP/secret-stores.yaml"
cat > "$STORES_FILE" <<'YAML'
agentgateway:
  secretStores:
    fetchTimeout: 3s
    stores:
    - name: corp-vault
      type: hashicorp_vault
      allowedPaths: ["ai/"]
      allowedDestinations: ["api.openai.com"]
      cache: {ttl: 5m, maxStale: 1h}
      hashicorpVault:
        address: https://vault.corp.example:8200
        mount: secret
        kvVersion: 2
        caCertSecret: {name: vault-ca}
        auth:
          method: approle
          roleId: trustgate
          secretIdSecret: {name: vault-approle, key: secret_id}
    - name: aws
      type: aws_secrets_manager
      allowedPaths: ["prod/ai/"]
      awsSecretsManager: {region: eu-west-1}
    - name: local
      type: file
      allowedPaths: ["llm-"]
      file: {existingSecret: llm-keys}
YAML

STORE_FILE_PATH=/etc/trustgate/secret-stores/stores.yaml

# --- no stores: nothing renders, in any mode -------------------------------
for mode in hybrid external saas; do
  out45n="$TMP/secret-stores-none-$mode.yaml"
  render_default "$out45n" --set global.deploymentMode="$mode"
  assert_not_contains "$out45n" 'agentgateway-secret-stores|SECRET_STORES_|secret-store-credentials' \
    "secret stores ($mode): no stores renders no ConfigMap, env or mount"
  assert_not_contains "$out45n" 'INSTANCE_DEPLOYMENT_TYPE' \
    "secret stores ($mode): the chart never declares a deployment type (saas would refuse the store file)"
done

# --- hybrid: proxy + mcp ----------------------------------------------------
out45h="$TMP/secret-stores-hybrid.yaml"
render_default "$out45h" -f "$STORES_FILE"
cm45="$TMP/secret-stores-cm.yaml"
document_named_kind "$out45h" ConfigMap agentgateway-secret-stores "$cm45"
assert_contains "$cm45" '^    version: 1$' "secret stores: store file version 1"
assert_contains "$cm45" 'type: hashicorp_vault' "secret stores: Vault store rendered"
assert_contains "$cm45" 'allowed_destinations:' "secret stores: allowedDestinations → allowed_destinations"
assert_contains "$cm45" 'max_stale: 1h' "secret stores: cache keys in snake_case"
assert_contains "$cm45" 'kv_version: 2' "secret stores: kvVersion → kv_version"
assert_contains "$cm45" 'role_id: trustgate' "secret stores: auth keys in snake_case"
assert_contains "$cm45" 'secret_id_file: /etc/trustgate/secret-store-credentials/corp-vault/secret-id/secret_id' \
  "secret stores: secretIdSecret becomes the mounted secret_id_file"
assert_contains "$cm45" 'ca_cert_file: /etc/trustgate/secret-store-credentials/corp-vault/ca-cert/ca.crt' \
  "secret stores: caCertSecret key defaults to ca.crt"
assert_contains "$cm45" 'root: /etc/trustgate/secret-store-credentials/local/files' \
  "secret stores: file.existingSecret becomes the file store root"
assert_not_contains "$cm45" 'Secret:|existingSecret|allowedPaths|hashicorpVault' \
  "secret stores: no values-only key reaches the store file"

# Settings the chart does not know pass through in snake_case: TrustGate owns
# the schema and validates the file, so a new TrustGate setting needs no chart
# change. Any *Secret field becomes the matching mounted *_file.
out45p="$TMP/secret-stores-passthrough.yaml"
render_default "$out45p" -f "$STORES_FILE" \
  --set 'agentgateway.secretStores.stores[1].awsSecretsManager.someNewSetting=x' \
  --set 'agentgateway.secretStores.stores[0].hashicorpVault.auth.jwtSecret.name=vault-jwt'
cm45p="$TMP/secret-stores-passthrough-cm.yaml"
document_named_kind "$out45p" ConfigMap agentgateway-secret-stores "$cm45p"
assert_contains "$cm45p" 'some_new_setting: x' "secret stores: an unknown setting passes through in snake_case"
assert_contains "$cm45p" 'jwt_file: /etc/trustgate/secret-store-credentials/corp-vault/jwt/jwt' \
  "secret stores: jwtSecret becomes the mounted jwt_file"

for wl in "agentgateway-proxy proxy" "agentgateway-mcp mcp"; do
  set -- $wl
  assert_env_value "$out45h" "$1" "$2" SECRET_STORES_FILE "$STORE_FILE_PATH" "secret stores (hybrid): $1 loads the store file"
  assert_env_value "$out45h" "$1" "$2" SECRET_STORES_GATEWAYS hybrid "secret stores (hybrid): $1 eligibility defaults to hybrid"
  assert_env_value "$out45h" "$1" "$2" SECRET_STORES_FETCH_TIMEOUT 3s "secret stores (hybrid): $1 gets the fetch timeout override"
  assert_env_value "$out45h" "$1" "$2" SECRET_STORES_PROBE_INTERVAL ABSENT "secret stores (hybrid): $1 keeps unset timings at the binary default"
done
dp45="$TMP/secret-stores-proxy.yaml"
document_named_kind "$out45h" Deployment agentgateway-proxy "$dp45"
assert_contains "$dp45" 'name: agentgateway-secret-stores' "secret stores: proxy mounts the store ConfigMap"
assert_not_contains "$dp45" 'subPath' "secret stores: mounted as a directory so ConfigMap updates reach the watcher"
assert_contains "$dp45" 'mountPath: "/etc/trustgate/secret-store-credentials/corp-vault/secret-id"' \
  "secret stores: the AppRole secret_id Secret is mounted"
assert_contains "$dp45" 'secretName: "llm-keys"' "secret stores: the file store Secret is mounted"
assert_not_contains "$dp45" 'checksum/secret-stores' "secret stores: store edits hot-reload, no pod roll"

# --- external and saas: admin + proxy + mcp, eligibility all ----------------
for mode in external saas; do
  out45e="$TMP/secret-stores-$mode.yaml"
  render_default "$out45e" --set global.deploymentMode="$mode" --set global.domain=cp.example.com -f "$STORES_FILE"
  for wl in "agentgateway-admin admin" "agentgateway-proxy proxy" "agentgateway-mcp mcp"; do
    set -- $wl
    assert_env_value "$out45e" "$1" "$2" SECRET_STORES_FILE "$STORE_FILE_PATH" "secret stores ($mode): $1 loads the store file"
    assert_env_value "$out45e" "$1" "$2" SECRET_STORES_GATEWAYS all "secret stores ($mode): $1 eligibility defaults to all"
  done
done

out45o="$TMP/secret-stores-override.yaml"
render_default "$out45o" --set global.deploymentMode=saas --set global.domain=cp.example.com \
  -f "$STORES_FILE" --set agentgateway.secretStores.gateways=hybrid
assert_env_value "$out45o" agentgateway-admin admin SECRET_STORES_GATEWAYS hybrid \
  "secret stores: an explicit gateways value wins over the mode default"

# --- refusals ----------------------------------------------------------------
assert_render_fails_with 'not available with global.deploymentMode=dedicated' \
  "secret stores: dedicated (NeuralTrust-hosted) planes refuse stores" \
  --set global.deploymentMode=dedicated --set global.products.trustgate=true \
  --set global.platformSecret.existingSecret.name=x --set global.redis.deploy=false \
  --set global.redis.host=10.0.0.5 -f "$STORES_FILE"
assert_render_fails_with 'must not be written inline' "secret stores: an inline Vault token is refused" \
  -f "$STORES_FILE" --set 'agentgateway.secretStores.stores[0].hashicorpVault.auth.token=s.abc'
assert_render_fails_with 'must not be written inline' "secret stores: an inline credential in snake_case is refused too" \
  -f "$STORES_FILE" --set 'agentgateway.secretStores.stores[1].awsSecretsManager.client_secret=x'
assert_render_fails_with 'declared twice' "secret stores: duplicate names are refused" \
  -f "$STORES_FILE" --set 'agentgateway.secretStores.stores[1].name=corp-vault'
assert_render_fails_with 'must be 1-63 characters' "secret stores: names must be lowercase" \
  -f "$STORES_FILE" --set 'agentgateway.secretStores.stores[1].name=AWS'
assert_render_fails_with 'mutually exclusive' "secret stores: caCertSecret and caCertFile together are refused" \
  -f "$STORES_FILE" --set 'agentgateway.secretStores.stores[0].hashicorpVault.caCertFile=/x/ca.pem'
assert_render_fails_with 'must be "hybrid" or "all"' "secret stores: gateways accepts hybrid or all" \
  -f "$STORES_FILE" --set agentgateway.secretStores.gateways=everyone
