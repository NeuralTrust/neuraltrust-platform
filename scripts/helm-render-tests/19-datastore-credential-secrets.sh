#!/usr/bin/env bash
# Render scenarios 18. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

blue "==> Scenario 18: operator-supplied datastore credential Secrets"

# Naming a pre-created Secret must move the credential out of the chart Secret
# entirely, not merely duplicate it: a copy left behind would still land in
# release history, which is the whole point of the hook.
CREDENTIAL_HOOKS=(
  --set global.deploymentMode=external
  --set agentgateway.database.existingSecret.name=ag-db
  --set agentgateway.database.existingSecret.key=password
  --set agentgateway.redis.existingSecret.name=cache
  --set trustguard.database.existingSecret.name=tg-db
  --set trustguard.redis.existingSecret.name=cache
  --set alertengine.database.existingSecret.name=ae-db
  --set datacore.database.existingSecret.name=dc-db
  --set data-plane-api.dataPlane.components.api.redis.existingSecret.name=dp-cache
  --set data-plane-api.dataPlane.components.api.redis.existingSecret.key=url
)
out18="$TMP/scenario-credential-hooks.yaml"
render_default "$out18" "${CREDENTIAL_HOOKS[@]}"
ruby -ryaml -e '
  docs = []
  YAML.load_stream(File.read(ARGV.fetch(0), encoding: "UTF-8")) { |d| docs << d if d.is_a?(Hash) }
  # postgresql-secrets keeps POSTGRES_PASSWORD: the control-plane role also feeds
  # the composed DSNs, which the chart cannot assemble from a Secret it may not read.
  owned = { "postgresql-secrets" => ["POSTGRES_PASSWORD"] }
  docs.select { |d| d["kind"] == "Secret" }.each do |d|
    name = d.dig("metadata", "name")
    fields = (d["data"] || {}).merge(d["stringData"] || {})
    leaked = fields.keys.grep(/\A(DB_PASSWORD|REDIS_PASSWORD|POSTGRES_PASSWORD|REDIS_URL)\z/) - (owned[name] || [])
    abort "#{name} still carries #{leaked.inspect}" unless leaked.empty?
  end
  want = {
    ["agentgateway-admin", "DB_PASSWORD"]            => ["ag-db", "password"],
    ["agentgateway-proxy", "DB_PASSWORD"]            => ["ag-db", "password"],
    ["agentgateway-mcp", "DB_PASSWORD"]              => ["ag-db", "password"],
    ["agentgateway-proxy", "REDIS_PASSWORD"]         => ["cache", "REDIS_PASSWORD"],
    ["trustguard-control-plane", "DB_PASSWORD"]      => ["tg-db", "DB_PASSWORD"],
    ["trustguard-data-plane", "REDIS_PASSWORD"]      => ["cache", "REDIS_PASSWORD"],
    ["alertengine-api", "DB_PASSWORD"]               => ["ae-db", "DB_PASSWORD"],
    ["alertengine-worker", "DB_PASSWORD"]            => ["ae-db", "DB_PASSWORD"],
    ["datacore", "POSTGRES_PASSWORD"]                => ["dc-db", "POSTGRES_PASSWORD"],
    ["data-plane-api", "REDIS_URL"]                  => ["dp-cache", "url"],
  }
  want.each do |(workload, env), (secret, key)|
    d = docs.find { |x| x["kind"] == "Deployment" && x.dig("metadata", "name") == workload }
    abort "#{workload} not rendered" if d.nil?
    entry = d["spec"]["template"]["spec"]["containers"].flat_map { |c| c["env"] || [] }.find { |e| e["name"] == env }
    abort "#{workload} does not read #{env} from a Secret" if entry.nil?
    ref = entry.dig("valueFrom", "secretKeyRef") || {}
    got = [ref["name"], ref["key"]]
    abort "#{workload}/#{env} reads #{got.inspect}, want #{[secret, key].inspect}" unless got == [secret, key]
  end
' "$out18" || { red "FAIL: pre-created credential Secrets are not wired end to end"; exit 1; }
green "ok  - external: pre-created Secrets own the credential and every workload reads it directly"

# Hybrid takes both passwords from the shared postgresql-secrets / redis-secrets,
# so the per-service hooks have nothing to bind to and must stay inert.
out18hy="$TMP/scenario-credential-hooks-hybrid.yaml"
render_default "$out18hy" \
  --set agentgateway.database.existingSecret.name=ag-db \
  --set agentgateway.redis.existingSecret.name=cache \
  --set trustguard.database.existingSecret.name=tg-db
ruby -ryaml -e '
  docs = []
  YAML.load_stream(File.read(ARGV.fetch(0), encoding: "UTF-8")) { |d| docs << d if d.is_a?(Hash) }
  bound = docs.select { |d| d["kind"] == "Deployment" }.flat_map do |d|
    d["spec"]["template"]["spec"]["containers"].flat_map { |c| c["env"] || [] }.select do |e|
      %w[ag-db tg-db cache].include?(e.dig("valueFrom", "secretKeyRef", "name"))
    end.map { |e| "#{d.dig("metadata", "name")}/#{e["name"]}" }
  end
  abort "hybrid bound the external hooks: #{bound.inspect}" unless bound.empty?
' "$out18hy" || { red "FAIL: hybrid should ignore the per-service credential hooks"; exit 1; }
green "ok  - hybrid ignores the hooks and keeps using the shared datastore Secrets"

# An inline password next to a hook is silently unused, so reject the combination
# rather than leave the operator guessing which one the pods received.
assert_render_fails "a hook plus an inline database password is rejected" \
  --set global.deploymentMode=external \
  --set agentgateway.database.existingSecret.name=ag-db \
  --set agentgateway.database.password=ignored
assert_render_fails "a hook plus an inline cache password is rejected" \
  --set global.deploymentMode=external \
  --set trustguard.redis.existingSecret.name=cache \
  --set trustguard.redis.password=ignored

# IAM auth mints a token per connection, so there is no static password to point
# at and the hook must not smuggle one back in.
out18iam="$TMP/scenario-credential-hooks-iam.yaml"
render_default "$out18iam" --set global.deploymentMode=external \
  --set agentgateway.database.iamAuth=true \
  --set agentgateway.database.awsRegion=eu-west-1 \
  --set agentgateway.database.existingSecret.name=ag-db
assert_not_contains "$out18iam" 'name: "ag-db"' \
  "IAM database auth ignores the credential hook"

# One Redis password reference: with only global.redis.existingSecret, every
# external consumer reads the password from it, optionally (a Redis without auth
# may hold none). Before, TrustGate and TrustGuard got no password at all.
blue "==> Scenario 18b: global.redis.existingSecret reaches every Redis consumer"
o="$TMP/redis-global-ref.yaml"
render_default "$o" --set global.deploymentMode=external --set global.redis.deploy=false \
  --set global.redis.host=cache.example.com --set global.redis.existingSecret.name=external-redis
for d in "agentgateway-proxy proxy" "agentgateway-admin admin" "trustguard-control-plane control-plane" "trustguard-data-plane data-plane" "firewall gateway"; do
  read -r dep ctr <<< "$d"
  assert_env_value "$o" "$dep" "$ctr" REDIS_PASSWORD secretKeyRef:external-redis/REDIS_PASSWORD \
    "global Redis Secret: $dep reads REDIS_PASSWORD from it"
done
if ! ruby -ryaml -e '
  docs = YAML.load_stream(File.read(ARGV[0])).compact
  docs.select { |d| %w[Deployment StatefulSet].include?(d["kind"]) }.each do |d|
    (d.dig("spec", "template", "spec", "containers") || []).each do |c|
      (c["env"] || []).select { |e| e["name"] == "REDIS_PASSWORD" && e.dig("valueFrom", "secretKeyRef", "name") == "external-redis" }.each do |e|
        abort "#{d["metadata"]["name"]}: required" unless e.dig("valueFrom", "secretKeyRef", "optional") == true
      end
    end
  end
  %w[agentgateway-secrets trustguard-secrets].each do |n|
    s = docs.find { |x| x["kind"] == "Secret" && x.dig("metadata", "name") == n }
    abort "#{n} still copies REDIS_PASSWORD" if s && (s["data"] || {}).key?("REDIS_PASSWORD")
  end
' "$o"; then
  red "FAIL: the global Redis reference is optional and has no copies"; exit 1
fi
green "ok  - global Redis Secret: optional everywhere, no copies in the gateway Secrets"
o="$TMP/redis-own-ref.yaml"
render_default "$o" --set global.deploymentMode=external --set global.redis.deploy=false \
  --set global.redis.host=cache.example.com --set global.redis.existingSecret.name=external-redis \
  --set trustguard.redis.existingSecret.name=tg-cache
assert_env_value "$o" trustguard-data-plane data-plane REDIS_PASSWORD secretKeyRef:tg-cache/REDIS_PASSWORD \
  "a service's own redis.existingSecret still wins over the global one"
