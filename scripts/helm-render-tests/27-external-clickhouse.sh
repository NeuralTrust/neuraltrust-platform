#!/usr/bin/env bash
# Render scenarios 10c3. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

blue "==> Scenario 10c3: external ClickHouse resolves for every consumer"

CH_EXT_ARGS=(
  --set global.deploymentMode=external
  --set watchdog.enabled=true
  --set infrastructure.clickhouse.deploy=false
  --set global.clickhouse.host=ch.managed.example.com
  --set global.clickhouse.httpPort=8443
  --set global.clickhouse.nativePort=9440
  --set global.clickhouse.tls=true
  --set global.clickhouse.user=ch_operator
  --set global.clickhouse.existingSecret.name=managed-ch-secret
  --set global.clickhouse.existingSecret.key=ch-password
)
out10c3="$TMP/scenario-ch-external.yaml"
render_default "$out10c3" "${CH_EXT_ARGS[@]}"

# --- native-protocol consumers: DataCore and both AlertEngine workloads -----
assert_contains "$out10c3" '^  CLICKHOUSE_ADDR: "ch\.managed\.example\.com:9440"$' \
  "external CH: CLICKHOUSE_ADDR follows global.clickhouse for DataCore and AlertEngine"
assert_not_contains "$out10c3" 'CLICKHOUSE_ADDR: "clickhouse:' \
  "external CH: no consumer is left pointing at the in-cluster Service"
assert_contains "$out10c3" '^  CLICKHOUSE_TLS: "true"$' \
  "external CH: DataCore gets CLICKHOUSE_TLS from global.clickhouse.tls"
assert_contains "$out10c3" '^  CLICKHOUSE_SECURE: "true"$' \
  "external CH: AlertEngine gets CLICKHOUSE_SECURE from the same key"
assert_contains "$out10c3" '^  CLICKHOUSE_USERNAME: "ch_operator"$' \
  "external CH: AlertEngine user follows global.clickhouse.user"

# --- HTTP consumers: the ClickStack collector composes a URL -----------------
# This chart is the only one configured by URL, and the scheme has to follow tls
# or a TLS-only managed endpoint refuses the connection.
assert_env_value "$out10c3" clickstack-collector collector CLICKHOUSE_ENDPOINT https://ch.managed.example.com:8443 \
  "external CH: the collector composes an https endpoint from host + httpPort + tls"

# --- data-plane-api: plain env, no Secret for connection settings -----------
assert_env_value "$out10c3" data-plane-api api CLICKHOUSE_HOST ch.managed.example.com \
  "external CH: data-plane-api dials the managed host"
assert_env_value "$out10c3" data-plane-api api CLICKHOUSE_PORT 8443 \
  "external CH: data-plane-api uses the managed HTTP port"
assert_env_value "$out10c3" data-plane-api api CLICKHOUSE_USER ch_operator \
  "external CH: data-plane-api's user follows global.clickhouse.user"
assert_resource_count "$out10c3" Secret clickhouse-secrets 0 \
  "external CH: connection settings are not stored in a Secret"

# A dotted host must pass through verbatim rather than being expanded to an
# in-cluster FQDN. That heuristic uses "is it dotted?" as the proxy for "is it
# external", so a managed host suffixed with .svc.cluster.local would be a bug.
assert_not_contains "$out10c3" 'ch\.managed\.example\.com\.default\.svc\.cluster\.local' \
  "external CH: a dotted managed host is not expanded into an in-cluster FQDN"

# --- watchdog's ClickStack sink was a hardcoded literal ----------------------
assert_contains "$out10c3" 'address: "ch\.managed\.example\.com:9440"' \
  "external CH: watchdog's ClickStack sink follows global.clickhouse, not the old literal"

# --- the migration initContainer needs the NATIVE port, not HTTP -------------
# It was hardcoded to 9000, so a managed endpoint on a TLS native port failed
# every migration while the API itself connected fine over HTTP -- a split-brain
# failure that looks like a broken database rather than a config error.
assert_contains "$out10c3" 'CLICKHOUSE_NATIVE_PORT="9440"' \
  "external CH: the ClickHouse migration job uses the resolved native port"
assert_not_contains "$out10c3" 'CLICKHOUSE_NATIVE_PORT="9000"' \
  "external CH: the migration job no longer hardcodes native 9000"

# --- the password Secret moves with it --------------------------------------
pw_refs=$(grep -c 'managed-ch-secret' "$out10c3" || true)
if [[ "$pw_refs" -lt 4 ]]; then
  red "FAIL: external CH: expected >=4 references to managed-ch-secret, got $pw_refs"
  exit 1
fi
green "ok  - external CH: every consumer reads the password from global.clickhouse.existingSecret"

# --- the ClickHouse wait invariant must still hold on the external path --------
# Re-asserted here, not just for the in-cluster default: a wait pointing at the
# old Service would fail an install that would otherwise have worked.
for _dep in datacore alertengine-api alertengine-worker; do
  _cmd=$(yq -N "select(.kind == \"Deployment\" and .metadata.name == \"$_dep\") | .spec.template.spec.initContainers[] | select(.name == \"wait-for-clickhouse\") | .command[-1]" "$out10c3" 2>/dev/null)
  _h=$(printf '%s' "$_cmd" | sed -n 's/^ *HOST="\(.*\)"$/\1/p' | head -1)
  _p=$(printf '%s' "$_cmd" | sed -n 's/^ *PORT="\(.*\)"$/\1/p' | head -1)
  if [[ "$_h" != "ch.managed.example.com" || "$_p" != "9440" ]]; then
    red "FAIL: external CH: $_dep waits on ${_h}:${_p}, but the app is configured for ch.managed.example.com:9440"
    exit 1
  fi
done
green "ok  - external CH: every wait-for-clickhouse targets the managed endpoint"

# --- the in-cluster default must be untouched -------------------------------
out10c3d="$TMP/scenario-ch-incluster-default.yaml"
render_default "$out10c3d" --set global.deploymentMode=external --set watchdog.enabled=true
assert_contains "$out10c3d" '^  CLICKHOUSE_ADDR: "clickhouse:9000"$' \
  "in-cluster default: CLICKHOUSE_ADDR unchanged by the global.clickhouse rewiring"
assert_env_value "$out10c3d" clickstack-collector collector CLICKHOUSE_ENDPOINT http://clickhouse:8123 \
  "in-cluster default: the collector endpoint is unchanged"
assert_contains "$out10c3d" '^  CLICKHOUSE_TLS: "false"$' \
  "in-cluster default: TLS stays off"
assert_contains "$out10c3d" '^  CLICKHOUSE_USERNAME: "neuraltrust"$' \
  "in-cluster default: the ClickHouse user is unchanged"
assert_contains "$out10c3d" 'CLICKHOUSE_NATIVE_PORT="9000"' \
  "in-cluster default: migrations still use native 9000"

# --- a per-consumer override still wins over global ------------------------
# The point of keeping the local keys: one service can be moved on its own.
out10c3o="$TMP/scenario-ch-local-override.yaml"
render_default "$out10c3o" --set global.deploymentMode=external \
  --set global.clickhouse.host=shared.example.com \
  --set global.clickhouse.nativePort=9440 \
  --set datacore.clickhouse.host=datacore-only.example.com
dc_addr=$(yq -N 'select(.kind == "ConfigMap" and .metadata.name == "datacore-env-vars") | .data.CLICKHOUSE_ADDR' "$out10c3o" | head -1)
ae_addr=$(yq -N 'select(.kind == "ConfigMap" and .metadata.name == "alertengine-env-vars") | .data.CLICKHOUSE_ADDR' "$out10c3o" | head -1)
if [[ "$dc_addr" != "datacore-only.example.com:9440" ]]; then
  red "FAIL: a per-consumer clickhouse.host must beat global (datacore got: $dc_addr)"
  exit 1
fi
if [[ "$ae_addr" != "shared.example.com:9440" ]]; then
  red "FAIL: AlertEngine should still follow global.clickhouse (got: $ae_addr)"
  exit 1
fi
green "ok  - a per-consumer clickhouse.host overrides global for that service alone"

# --- the deprecated block fails closed instead of being ignored -------------
# It was accepted silently while doing nothing, which is the whole bug. The fail
# is deliberately narrow: setting it alongside a real endpoint still renders, so
# the one values file that made it work (values-managed-datastores.yaml.example)
# keeps installing.
# Bypasses render_default deliberately: this render must FAIL, so it cannot go
# through a helper that pipes to a file and validates. Same base values, though,
# or it would not be testing the same install.
render_raw() {
  helm template nt-legacy "$CHART_DIR" --namespace default \
    -f "$CHART_DIR/values-required.yaml" "${CLICKSTACK_DEFAULT_ARGS[@]}" "$@" >/dev/null 2>&1
}
if render_raw \
    --set global.deploymentMode=external \
    --set infrastructure.clickhouse.deploy=false \
    --set infrastructure.clickhouse.external.host=ch.legacy.example.com; then
  red "FAIL: infrastructure.clickhouse.external.host alone should fail the render, not be silently ignored"
  exit 1
fi
green "ok  - the inert infrastructure.clickhouse.external block now fails closed"
for _combo in "--set global.clickhouse.host=ch.legacy.example.com" "--set datacore.clickhouse.host=ch.legacy.example.com"; do
  # shellcheck disable=SC2086  # $_combo is a deliberate two-token --set pair
  if ! render_raw \
      --set global.deploymentMode=external \
      --set infrastructure.clickhouse.deploy=false \
      --set infrastructure.clickhouse.external.host=ch.legacy.example.com \
      $_combo; then
    red "FAIL: the deprecated block alongside a real endpoint ($_combo) must still render"
    exit 1
  fi
done
green "ok  - the deprecated block alongside a real endpoint still installs"

# The documented managed-datastore example predates global.clickhouse and works by
# restating the endpoint per consumer. It must keep installing.
# The example file is self-contained (it sets its own deploymentMode and
# datastores), so it is rendered on its own rather than layered on values-required.
if ! helm template nt-example "$CHART_DIR" --namespace default \
    -f "$CHART_DIR/values-managed-datastores.yaml.example" >/dev/null 2>&1; then
  red "FAIL: values-managed-datastores.yaml.example no longer renders"
  exit 1
fi
green "ok  - values-managed-datastores.yaml.example still renders"
