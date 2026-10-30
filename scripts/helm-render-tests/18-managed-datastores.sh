#!/usr/bin/env bash
# Render scenarios 17. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

# Managed endpoints used to be declared once per service, because empty
# per-service hosts fell straight through to the in-cluster Service names.
blue "==> Scenario 17: managed datastores declared once on the global blocks"
MANAGED_DATASTORES=(
  --set global.postgresql.deploy=false
  --set global.postgresql.host=aurora.example.com
  --set global.postgresql.port=5433
  --set global.postgresql.sslMode=require
  --set global.redis.deploy=false
  --set global.redis.host=cache.example.com
  --set global.redis.port=6380
  --set global.redis.username=neuraltrust
  --set global.redis.tls=true
)

out17="$TMP/scenario-datastore-inherit.yaml"
render_default "$out17" --set global.deploymentMode=external \
  "${MANAGED_DATASTORES[@]}"
ruby -ryaml -e '
  docs = []
  YAML.load_stream(File.read(ARGV.fetch(0), encoding: "UTF-8")) { |d| docs << d if d.is_a?(Hash) }
  cm = ->(name) do
    d = docs.find { |x| x["kind"] == "ConfigMap" && x.dig("metadata", "name") == name }
    abort "#{name} not rendered" if d.nil?
    d.fetch("data")
  end
  # Each service names the same endpoint under its own variable convention.
  { "agentgateway-env-vars" => %w[DB_HOST DB_PORT DB_SSL_MODE],
    "trustguard-env-vars"   => %w[DB_HOST DB_PORT DB_SSL_MODE],
    "alertengine-env-vars"  => %w[DB_HOST DB_PORT DB_SSL_MODE],
    "datacore-env-vars"     => %w[POSTGRES_HOST POSTGRES_PORT POSTGRES_SSLMODE] }.each do |name, (hk, pk, sk)|
    data = cm.call(name)
    abort "#{name} #{hk}=#{data[hk].inspect}" unless data[hk] == "aurora.example.com"
    abort "#{name} #{pk}=#{data[pk].inspect}" unless data[pk].to_s == "5433"
    abort "#{name} #{sk}=#{data[sk].inspect}" unless data[sk] == "require"
  end
  # Redis: TrustGate reads REDIS_TLS_ENABLED, TrustGuard reads REDIS_TLS.
  { "agentgateway-env-vars" => "REDIS_TLS_ENABLED",
    "trustguard-env-vars"   => "REDIS_TLS" }.each do |name, tlsk|
    data = cm.call(name)
    abort "#{name} REDIS_HOST=#{data["REDIS_HOST"].inspect}" unless data["REDIS_HOST"] == "cache.example.com"
    abort "#{name} REDIS_PORT=#{data["REDIS_PORT"].inspect}" unless data["REDIS_PORT"].to_s == "6380"
    abort "#{name} REDIS_USERNAME=#{data["REDIS_USERNAME"].inspect}" unless data["REDIS_USERNAME"] == "neuraltrust"
    abort "#{name} #{tlsk}=#{data[tlsk].inspect}" unless data[tlsk].to_s == "true"
  end
' "$out17" || { red "FAIL: a service ignored the global blocks and dialed an in-cluster Service"; exit 1; }
green "ok  - external: every service inherits the managed endpoints from the global blocks"

# data-plane-api composes its cache DSN in a Secret rather than reading env.
ruby -ryaml -rbase64 -e '
  docs = []
  YAML.load_stream(File.read(ARGV.fetch(0), encoding: "UTF-8")) { |d| docs << d if d.is_a?(Hash) }
  s = docs.find { |d| d["kind"] == "Secret" && d.dig("metadata", "name") == "data-plane-jwt-secret" }
  abort "data-plane-jwt-secret not rendered" if s.nil?
  url = Base64.decode64(s.fetch("data").fetch("REDIS_URL"))
  abort "REDIS_URL=#{url.inspect} does not target the managed cache" unless url.include?("cache.example.com:6380")
  abort "REDIS_URL=#{url.inspect} should use the TLS scheme" unless url.start_with?("rediss://")
' "$out17" || { red "FAIL: the data-plane cache DSN ignored global.redis"; exit 1; }
green "ok  - external: the data-plane cache DSN follows global.redis, TLS scheme included"

# An explicit global host is honoured whatever `deploy` says: the shared
# postgresql-secrets already resolve that way, and disagreeing here would split
# the platform across two databases.
out17deploy="$TMP/scenario-datastore-inherit-deploy.yaml"
render_default "$out17deploy" --set global.deploymentMode=external \
  --set global.postgresql.host=aurora.example.com \
  --set global.postgresql.port=5433
ruby -ryaml -rbase64 -e '
  docs = []
  YAML.load_stream(File.read(ARGV.fetch(0), encoding: "UTF-8")) { |d| docs << d if d.is_a?(Hash) }
  shared = docs.find { |d| d["kind"] == "Secret" && d.dig("metadata", "name") == "postgresql-secrets" }
  abort "postgresql-secrets not rendered" if shared.nil?
  host = Base64.decode64(shared.fetch("data").fetch("POSTGRES_HOST"))
  ag = docs.find { |d| d["kind"] == "ConfigMap" && d.dig("metadata", "name") == "agentgateway-env-vars" }
  abort "agentgateway-env-vars not rendered" if ag.nil?
  runtime = ag.fetch("data").fetch("DB_HOST")
  abort "split brain: postgresql-secrets=#{host.inspect} but runtime=#{runtime.inspect}" unless host == runtime
' "$out17deploy" || { red "FAIL: the control plane and the runtimes disagree on the Postgres host"; exit 1; }
green "ok  - deploy=true: the control plane and the runtimes agree on one host"

out17override="$TMP/scenario-datastore-inherit-override.yaml"
render_default "$out17override" --set global.deploymentMode=external \
  "${MANAGED_DATASTORES[@]}" \
  --set agentgateway.database.host=gateway-pg.example.com \
  --set agentgateway.database.port=6432 \
  --set agentgateway.redis.host=gateway-cache.example.com
ruby -ryaml -e '
  docs = []
  YAML.load_stream(File.read(ARGV.fetch(0), encoding: "UTF-8")) { |d| docs << d if d.is_a?(Hash) }
  ag = docs.find { |d| d["kind"] == "ConfigMap" && d.dig("metadata", "name") == "agentgateway-env-vars" }.fetch("data")
  abort "agentgateway host override lost" unless ag["DB_HOST"] == "gateway-pg.example.com"
  abort "agentgateway port override lost" unless ag["DB_PORT"].to_s == "6432"
  abort "agentgateway redis override lost" unless ag["REDIS_HOST"] == "gateway-cache.example.com"
  tg = docs.find { |d| d["kind"] == "ConfigMap" && d.dig("metadata", "name") == "trustguard-env-vars" }.fetch("data")
  abort "trustguard should still inherit" unless tg["DB_HOST"] == "aurora.example.com"
  abort "trustguard redis should still inherit" unless tg["REDIS_HOST"] == "cache.example.com"
' "$out17override" || { red "FAIL: a per-service endpoint no longer wins over the global one"; exit 1; }
green "ok  - a per-service host/port still overrides the inherited one"

# Hybrid: DataAgent builds its own DSN, so inheritance has to reach the string.
out17dsn="$TMP/scenario-datastore-inherit-dsn.yaml"
render_default "$out17dsn" "${MANAGED_DATASTORES[@]}" \
  --set dataagent.database.password=render-test
assert_contains "$out17dsn" 'aurora.example.com:5433' \
  "hybrid: the DataAgent DSN points at the managed endpoint"
assert_contains "$out17dsn" 'sslmode=require' \
  "hybrid: the DataAgent DSN inherits the global sslMode"
assert_not_contains "$out17dsn" 'DATABASE_URL: "postgresql://[^"]*@control-plane-postgresql' \
  "hybrid: no DataAgent DSN is left on the in-cluster Service"

# The cache credential has three consumers and used to be declared once for each.
out17pw="$TMP/scenario-datastore-inherit-redis-pw.yaml"
render_default "$out17pw" --set global.deploymentMode=external \
  "${MANAGED_DATASTORES[@]}" \
  --set global.redis.password=inherited-cache-pw
ruby -ryaml -rbase64 -e '
  docs = []
  YAML.load_stream(File.read(ARGV.fetch(0), encoding: "UTF-8")) { |d| docs << d if d.is_a?(Hash) }
  # The gateway Secrets ship stringData; only the umbrella ones are base64 data.
  fields = ->(name) do
    d = docs.find { |x| x["kind"] == "Secret" && x.dig("metadata", "name") == name }
    abort "#{name} not rendered" if d.nil?
    d["stringData"] || d["data"] || {}
  end
  %w[agentgateway-secrets trustguard-secrets].each do |name|
    got = fields.call(name)["REDIS_PASSWORD"]
    abort "#{name} carries no REDIS_PASSWORD" if got.nil?
    abort "#{name} REDIS_PASSWORD=#{got.inspect}" unless got == "inherited-cache-pw"
  end
  url = Base64.decode64(fields.call("data-plane-jwt-secret").fetch("REDIS_URL"))
  abort "REDIS_URL=#{url.inspect} carries no inherited credential" unless url.include?(":inherited-cache-pw@")
' "$out17pw" || { red "FAIL: global.redis.password did not reach all three cache consumers"; exit 1; }
green "ok  - one global.redis.password reaches both gateways and the data-plane DSN"

# A per-service cache password still wins, so split credentials stay possible.
out17pwover="$TMP/scenario-datastore-inherit-redis-pw-override.yaml"
render_default "$out17pwover" --set global.deploymentMode=external \
  "${MANAGED_DATASTORES[@]}" \
  --set global.redis.password=inherited-cache-pw \
  --set agentgateway.redis.password=gateway-only-pw
ruby -ryaml -rbase64 -e '
  docs = []
  YAML.load_stream(File.read(ARGV.fetch(0), encoding: "UTF-8")) { |d| docs << d if d.is_a?(Hash) }
  pw = ->(name) do
    d = docs.find { |x| x["kind"] == "Secret" && x.dig("metadata", "name") == name }
    abort "#{name} not rendered" if d.nil?
    (d["stringData"] || {}).fetch("REDIS_PASSWORD")
  end
  abort "agentgateway override lost" unless pw.call("agentgateway-secrets") == "gateway-only-pw"
  abort "trustguard should still inherit" unless pw.call("trustguard-secrets") == "inherited-cache-pw"
' "$out17pwover" || { red "FAIL: a per-service cache password no longer wins"; exit 1; }
green "ok  - a per-service cache password still overrides the inherited one"

# Nothing inherits when the global blocks are left at their defaults.
out17def="$TMP/scenario-datastore-inherit-default.yaml"
render_default "$out17def" --set global.deploymentMode=external
assert_contains "$out17def" 'DB_HOST: "control-plane-postgresql"' \
  "defaults: Postgres still resolves to the in-cluster Service"
assert_contains "$out17def" 'REDIS_HOST: "redis"' \
  "defaults: Redis still resolves to the in-cluster Service"
assert_contains "$out17def" 'DB_SSL_MODE: "prefer"' \
  "defaults: sslMode still resolves to prefer"
