#!/usr/bin/env bash
# Render scenarios 13. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

# The gateway binaries refuse cleartext config-sync once APP_ENV is deployed:
# the control plane will not build its listener without a keypair, and the data
# plane rejects CONFIG_SYNC_TLS_INSECURE=true. Both halves must arrive together.
blue "==> Scenario 13: config-sync gRPC TLS on both gateways"
AGW_TLS_MOUNT="/etc/agentgateway/configsync-tls"
CS_ON=(--set agentgateway.configSync.enabled=true --set agentgateway.configSync.token=tok)

out13="$TMP/scenario-configsync-tls-external.yaml"
render_default "$out13" --set global.deploymentMode=external "${CS_ON[@]}"

for k in tls.crt tls.key ca.crt; do
  assert_secret_key "$out13" agentgateway-configsync-tls present "$k" \
    "external: agentgateway config-sync TLS Secret carries $k"
done
assert_contains "$out13" 'name: agentgateway-configsync-tls' \
  "external: the generated Secret is named after the chart, not TrustGuard's"

assert_env_value "$out13" agentgateway-admin admin CONFIG_SYNC_GRPC_TLS_CERT \
  "$AGW_TLS_MOUNT/tls.crt" "external: the admin plane serves the generated cert"
assert_env_value "$out13" agentgateway-admin admin CONFIG_SYNC_GRPC_TLS_KEY \
  "$AGW_TLS_MOUNT/tls.key" "external: the admin plane serves the generated key"

# Both data planes dial the listener, so both must verify it.
for wl in agentgateway-proxy agentgateway-mcp; do
  c=proxy; [ "$wl" = agentgateway-mcp ] && c=mcp
  assert_env_value "$out13" "$wl" "$c" CONFIG_SYNC_TLS_INSECURE false \
    "external: $wl verifies the config-sync listener instead of dialing cleartext"
  assert_env_value "$out13" "$wl" "$c" CONFIG_SYNC_TLS_CA "$AGW_TLS_MOUNT/ca.crt" \
    "external: $wl trusts the generated CA"
  assert_env_value "$out13" "$wl" "$c" CONFIG_SYNC_TLS_SERVER_NAME \
    "agentgateway-admin.default.svc.cluster.local" \
    "external: $wl verifies the listener's SAN"
done

assert_contains "$out13" 'APP_ENV: "production"' \
  "external: agentgateway declares a deployed APP_ENV"

# A non-deployed APP_ENV keeps the old permissive behaviour, so an operator who
# needs cleartext has a way out that does not involve editing templates.
out13dev="$TMP/scenario-configsync-tls-dev.yaml"
render_default "$out13dev" --set global.deploymentMode=external "${CS_ON[@]}" \
  --set agentgateway.config.appEnv=dev
assert_not_contains "$out13dev" 'agentgateway-configsync-tls' \
  "non-deployed APP_ENV: no keypair is generated"
assert_env_value "$out13dev" agentgateway-proxy proxy CONFIG_SYNC_TLS_INSECURE true \
  "non-deployed APP_ENV: the permissive dial is still available"

# Hybrid has no control plane to secure and dials SaaS over public TLS.
out13hy="$TMP/scenario-configsync-tls-hybrid.yaml"
render_default "$out13hy"
assert_not_contains "$out13hy" 'agentgateway-configsync-tls' \
  "hybrid: no config-sync keypair is generated"
assert_env_value "$out13hy" agentgateway-proxy proxy CONFIG_SYNC_TLS_INSECURE false \
  "hybrid: the SaaS dial stays verified under a deployed APP_ENV"

# Operator-owned keypair: the chart must not mint a competing one.
out13own="$TMP/scenario-configsync-tls-existing.yaml"
render_default "$out13own" --set global.deploymentMode=external "${CS_ON[@]}" \
  --set agentgateway.configSync.grpcTls.existingSecret=my-configsync-tls
assert_not_contains "$out13own" 'name: agentgateway-configsync-tls' \
  "existingSecret: the chart renders no keypair of its own"
assert_contains "$out13own" 'secretName: my-configsync-tls' \
  "existingSecret: the control plane mounts the operator Secret"

# Pre-provisioned installs own every Secret themselves.
out13pre="$TMP/scenario-configsync-tls-preserve.yaml"
render_default "$out13pre" --set global.deploymentMode=external "${CS_ON[@]}" \
  --set global.preserveExistingSecrets=true \
  --set agentgateway.configSync.existingSecret.name=agw-cs \
  --set trustguard.configSync.existingSecret.name=tg-cs
assert_not_contains "$out13pre" 'name: agentgateway-configsync-tls' \
  "preserveExistingSecrets: the chart generates no keypair"

# Turning generation off without supplying a Secret yields a control plane that
# cannot start. sprig reads an explicit false back as true through `default`, so
# this guard only works via hasKey - these cases would silently pass otherwise.
assert_render_fails "autoGenerate=false without existingSecret is rejected" \
  --set global.deploymentMode=external \
  --set agentgateway.configSync.grpcTls.autoGenerate=false
assert_render_fails "the same guard covers trustguard" \
  --set global.deploymentMode=external \
  --set trustguard.configSync.grpcTls.autoGenerate=false


# External keeps an in-cluster-only certificate: publishing is what adds the
# public name, so a mode that publishes nothing must not carry one.
if cert_sans "$out13" agentgateway-configsync-tls | grep -q 'configsync\.'; then
  red "FAIL: external: config-sync certificate carries a public name it never serves"
  exit 1
fi
green "ok  - external: config-sync certificate stays in-cluster only"
