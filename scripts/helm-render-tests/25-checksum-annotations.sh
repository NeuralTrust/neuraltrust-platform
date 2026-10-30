#!/usr/bin/env bash
# Render scenarios 24. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

# ---------------------------------------------------------------------------
# ConfigMap/Secret checksum annotations roll envFrom consumers.
# ---------------------------------------------------------------------------
blue "==> Scenario 24: checksum annotations change on config edits and stay stable on no-op"

# Helper: print "deploy|annotation|value" lines for the named Deployments.
aut403_ann() {
  local file=$1
  shift
  ruby -ryaml -e '
    want = ARGV[1..]
    docs = YAML.load_stream(File.read(ARGV[0])).compact
    docs.select { |d| d["kind"] == "Deployment" && want.include?(d.dig("metadata", "name")) }.each do |d|
      name = d.dig("metadata", "name")
      ann = d.dig("spec", "template", "metadata", "annotations") || {}
      ann.keys.sort.each { |k| puts "#{name}|#{k}|#{ann[k]}" if k.start_with?("checksum/") }
    end
  ' "$file" "$@"
}

out24a="$TMP/scenario-aut403-baseline.yaml"
render_default "$out24a"
out24b="$TMP/scenario-aut403-baseline-rerun.yaml"
render_default "$out24b"
out24c="$TMP/scenario-aut403-loglevel.yaml"
render_default "$out24c" --set agentgateway.config.logLevel=debug
out24d="$TMP/scenario-aut403-redis-host.yaml"
render_default "$out24d" --set global.redis.host=cache.example.com
out24e="$TMP/scenario-aut403-external.yaml"
render_default "$out24e" --set global.deploymentMode=external
out24f="$TMP/scenario-aut403-external-fw.yaml"
render_default "$out24f" --set global.deploymentMode=external \
  --set firewall.firewall.config.otelEnvironment=aut403-test

# Every envFrom v2 workload must carry at least the env ConfigMap checksum.
# Secrets checksum is also required where the chart owns the Secret; its value
# is intentionally NOT asserted for byte-stability across bare helm template
# runs, because resolveSecret/randAlphaNum regenerates without cluster lookup.
# Live upgrades stay stable via lookup — that is the helm-diff gate.
if ! ruby -ryaml -e '
  docs = YAML.load_stream(File.read(ARGV[0])).compact
  # Hybrid profile (values-required): no agentgateway-admin / trustguard-control-plane.
  required = {
    "agentgateway-proxy" => %w[checksum/env-configmap checksum/secrets checksum/redis-secrets],
    "agentgateway-mcp" => %w[checksum/env-configmap checksum/secrets checksum/redis-secrets],
    "trustguard-data-plane" => %w[checksum/env-configmap checksum/secrets checksum/redis-secrets],
    "dataagent" => %w[checksum/env-configmap],
    "dataagent-trustguard" => %w[checksum/env-configmap],
    "firewall" => %w[checksum/configmap],
  }
  docs.select { |d| d["kind"] == "Deployment" }.each do |d|
    name = d.dig("metadata", "name")
    next unless required.key?(name)
    ann = d.dig("spec", "template", "metadata", "annotations") || {}
    required[name].each do |key|
      abort "#{name} missing #{key}" unless ann[key].to_s =~ /\A[0-9a-f]{64}\z/
    end
  end
' "$out24a"; then
  red "FAIL: hybrid workloads missing checksum annotations"
  exit 1
fi
green "ok  - hybrid envFrom workloads carry ConfigMap/Secret/redis checksums"

if ! ruby -ryaml -e '
  docs = YAML.load_stream(File.read(ARGV[0])).compact
  required = {
    "agentgateway-admin" => %w[checksum/env-configmap checksum/secrets],
    "agentgateway-proxy" => %w[checksum/env-configmap checksum/secrets],
    "agentgateway-mcp" => %w[checksum/env-configmap checksum/secrets],
    "trustguard-control-plane" => %w[checksum/env-configmap checksum/secrets],
    "trustguard-data-plane" => %w[checksum/env-configmap checksum/secrets],
    "datacore" => %w[checksum/env-configmap checksum/secrets],
    "alertengine-api" => %w[checksum/env-configmap checksum/secrets],
    "alertengine-worker" => %w[checksum/env-configmap checksum/secrets],
    "firewall" => %w[checksum/configmap],
    "clickstack-collector" => %w[checksum/config checksum/secrets],
  }
  # Firewall workers share the gateway ConfigMap checksum.
  docs.select { |d| d["kind"] == "Deployment" }.each do |d|
    name = d.dig("metadata", "name").to_s
    keys = required[name]
    if keys.nil? && name.end_with?("-worker") && name != "alertengine-worker"
      # firewall toxicity-worker etc.
      keys = %w[checksum/configmap] if name.match?(/^(toxicity|indirect-prompt-injections|prompt-jailbreak|topic-guard|complexity)-worker$/)
    end
    next if keys.nil?
    ann = d.dig("spec", "template", "metadata", "annotations") || {}
    keys.each do |key|
      abort "#{name} missing #{key}" unless ann[key].to_s =~ /\A[0-9a-f]{64}\z/
    end
  end
' "$out24e"; then
  red "FAIL: external workloads missing checksum annotations"
  exit 1
fi
green "ok  - external envFrom workloads carry ConfigMap/Secret checksums"

# Deterministic ConfigMap checksums must be byte-identical across two no-op renders.
env_a=$(aut403_ann "$out24a" agentgateway-proxy | awk -F'|' '$2=="checksum/env-configmap"{print $3}')
env_b=$(aut403_ann "$out24b" agentgateway-proxy | awk -F'|' '$2=="checksum/env-configmap"{print $3}')
redis_a=$(aut403_ann "$out24a" agentgateway-proxy | awk -F'|' '$2=="checksum/redis-secrets"{print $3}')
redis_b=$(aut403_ann "$out24b" agentgateway-proxy | awk -F'|' '$2=="checksum/redis-secrets"{print $3}')
if [ -z "$env_a" ] || [ "$env_a" != "$env_b" ]; then
  red "FAIL: env-configmap checksum not stable across identical renders"
  exit 1
fi
if [ -z "$redis_a" ] || [ "$redis_a" != "$redis_b" ]; then
  red "FAIL: redis-secrets checksum not stable across identical renders"
  exit 1
fi
green "ok  - env-configmap and redis-secrets checksums are byte-stable on no-op"

# A ConfigMap value edit must flip only the env checksum.
env_c=$(aut403_ann "$out24c" agentgateway-proxy | awk -F'|' '$2=="checksum/env-configmap"{print $3}')
redis_c=$(aut403_ann "$out24c" agentgateway-proxy | awk -F'|' '$2=="checksum/redis-secrets"{print $3}')
if [ "$env_a" = "$env_c" ]; then
  red "FAIL: logLevel change did not flip checksum/env-configmap"
  exit 1
fi
if [ "$redis_a" != "$redis_c" ]; then
  red "FAIL: logLevel change unexpectedly flipped checksum/redis-secrets"
  exit 1
fi
green "ok  - ConfigMap edit flips env-configmap checksum only"

# A Redis host edit must flip the umbrella redis checksum, not the env ConfigMap.
env_d=$(aut403_ann "$out24d" agentgateway-proxy | awk -F'|' '$2=="checksum/env-configmap"{print $3}')
redis_d=$(aut403_ann "$out24d" agentgateway-proxy | awk -F'|' '$2=="checksum/redis-secrets"{print $3}')
if [ "$redis_a" = "$redis_d" ]; then
  red "FAIL: redis host change did not flip checksum/redis-secrets"
  exit 1
fi
if [ "$env_a" != "$env_d" ]; then
  red "FAIL: redis host change unexpectedly flipped checksum/env-configmap"
  exit 1
fi
green "ok  - umbrella redis-secrets checksum tracks global.redis.host"

fw_e=$(aut403_ann "$out24e" firewall | awk -F'|' '$2=="checksum/configmap"{print $3}')
fw_f=$(aut403_ann "$out24f" firewall | awk -F'|' '$2=="checksum/configmap"{print $3}')
if [ -z "$fw_e" ] || [ "$fw_e" = "$fw_f" ]; then
  red "FAIL: firewall config edit did not flip checksum/configmap"
  exit 1
fi
green "ok  - firewall ConfigMap edit flips checksum/configmap"
