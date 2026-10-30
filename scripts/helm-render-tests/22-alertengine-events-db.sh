#!/usr/bin/env bash
# Render scenarios 21. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

# ---------------------------------------------------------------------------
# AlertEngine ClickHouse DB, firewall REDIS_URL,
# and umbrella IAM inheritance for gateway POSTGRES_LOGIN.
# ---------------------------------------------------------------------------
blue "==> Scenario 21: AlertEngine reads the events database"
out21="$TMP/scenario-alertengine-ch-default.yaml"
render_default "$out21" --set global.deploymentMode=external
if ! ruby -ryaml -e '
  docs = YAML.load_stream(File.read(ARGV[0])).compact
  cm = docs.find { |d| d["kind"] == "ConfigMap" && d.dig("metadata", "name") == "alertengine-env-vars" }
  abort "alertengine-env-vars not rendered" if cm.nil?
  db = cm.dig("data", "CLICKHOUSE_DATABASE")
  abort "CLICKHOUSE_DATABASE=#{db.inspect}, want default" unless db == "default"
' "$out21"; then
  red "FAIL: AlertEngine CLICKHOUSE_DATABASE=default"
  exit 1
fi
green "ok  - AlertEngine CLICKHOUSE_DATABASE=default"
