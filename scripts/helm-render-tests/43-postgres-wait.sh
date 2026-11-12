#!/usr/bin/env bash
# Render scenarios 43, 43b, 43c. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

# Postgres clients wait for the chart's own PostgreSQL. On a fresh install they
# otherwise race it, exhaust their startup probes and restart several times when
# PostgreSQL lands on a node the autoscaler is still adding.
blue "==> Scenario 43: wait-for-postgresql on the chart's own PostgreSQL"

init_names() {
  local file="$1" workload="$2"
  ruby -ryaml -e '
    YAML.load_stream(File.read(ARGV.fetch(0), encoding: "UTF-8")) do |d|
      next unless d.is_a?(Hash) && d["kind"] == "Deployment" && d.dig("metadata", "name") == ARGV.fetch(1)
      puts((d.dig("spec", "template", "spec", "initContainers") || []).map { |c| c["name"] }.join(","))
    end
  ' "$file" "$workload"
}

assert_init() {
  local file="$1" workload="$2" expected="$3" msg="$4" actual
  actual="$(init_names "$file" "$workload")"
  if [[ "$actual" == "$expected" ]]; then
    green "ok  - $msg"
  else
    red "FAIL: $msg"
    red "  $workload initContainers expected: '$expected', actual: '$actual'"
    exit 1
  fi
}

out43="$TMP/pg-wait-external.yaml"
render_default "$out43" --set global.deploymentMode=external
for w in agentgateway-admin agentgateway-proxy agentgateway-mcp; do
  assert_init "$out43" "$w" wait-for-postgresql \
    "external, in-cluster PostgreSQL: $w waits for it"
done
for w in alertengine-api alertengine-worker; do
  assert_init "$out43" "$w" wait-for-clickhouse,wait-for-postgresql \
    "external, in-cluster PostgreSQL: $w waits for ClickHouse and PostgreSQL"
done

# 43b. Hybrid with the data plane runs the chart's PostgreSQL too.
blue "==> Scenario 43b: hybrid with in-cluster PostgreSQL"
out43b="$TMP/pg-wait-hybrid.yaml"
render_default "$out43b" --set global.products.dataPlane=true
for w in agentgateway-proxy agentgateway-mcp; do
  assert_init "$out43b" "$w" wait-for-postgresql \
    "hybrid, in-cluster PostgreSQL: $w waits for it"
done

# 43c. A managed database renders exactly as before: nothing to wait for.
blue "==> Scenario 43c: managed PostgreSQL renders no wait"
out43c="$TMP/pg-wait-managed.yaml"
render_default "$out43c" --set global.deploymentMode=external \
  --set global.postgresql.deploy=false --set global.postgresql.host=pg.example.com
for w in agentgateway-admin agentgateway-proxy agentgateway-mcp; do
  assert_init "$out43c" "$w" "" "managed PostgreSQL: $w has no wait"
done
assert_init "$out43c" alertengine-api wait-for-clickhouse \
  "managed PostgreSQL: alertengine-api keeps only its ClickHouse wait"
out43c_svc="$TMP/pg-wait-service-host.yaml"
render_default "$out43c_svc" --set global.deploymentMode=external \
  --set agentgateway.database.host=pg-agentgateway.example.com
assert_init "$out43c_svc" agentgateway-admin "" \
  "a per-service host elsewhere: agentgateway does not wait for the in-cluster PostgreSQL"
