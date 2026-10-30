#!/usr/bin/env bash
# Render scenarios 15, 15b. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

# TrustGate reads REDIS_TLS_ENABLED; TrustGuard reads REDIS_TLS. The shared
# hybrid Secret stores the latter, so without a rename AgentGateway connects in
# plaintext to a TLS-only Redis and nothing in the manifest says so.
blue "==> Scenario 15: hybrid Redis TLS reaches both naming conventions"
out15="$TMP/scenario-redis-tls-hybrid.yaml"
render_default "$out15" --set global.redis.tls=true
assert_secret_key "$out15" redis-secrets present REDIS_TLS \
  "hybrid: the shared Secret stores the canonical REDIS_TLS"
for wl in agentgateway-proxy agentgateway-mcp; do
  c=proxy; [ "$wl" = agentgateway-mcp ] && c=mcp
  assert_contains "$out15" 'name: REDIS_TLS_ENABLED' \
    "hybrid: $wl is given the name TrustGate actually reads"
done
ruby -ryaml -rbase64 -e '
  docs = []
  YAML.load_stream(File.read(ARGV.fetch(0), encoding: "UTF-8")) { |d| docs << d if d.is_a?(Hash) }
  s = docs.find { |d| d["kind"] == "Secret" && d.dig("metadata", "name") == "redis-secrets" }
  val = Base64.decode64(s.fetch("data").fetch("REDIS_TLS"))
  abort "expected REDIS_TLS=true, got #{val.inspect}" unless val == "true"
  %w[agentgateway-proxy agentgateway-mcp].each do |w|
    d = docs.find { |x| x["kind"] == "Deployment" && x.dig("metadata", "name") == w }
    c = d.dig("spec", "template", "spec", "containers").first
    e = (c["env"] || []).find { |x| x["name"] == "REDIS_TLS_ENABLED" }
    abort "#{w} missing REDIS_TLS_ENABLED" if e.nil?
    ref = e.dig("valueFrom", "secretKeyRef")
    abort "#{w} REDIS_TLS_ENABLED not sourced from redis-secrets/REDIS_TLS" unless
      ref && ref["name"] == "redis-secrets" && ref["key"] == "REDIS_TLS"
  end
  # TrustGuard reads REDIS_TLS directly, so a rename there would be noise.
  tg = docs.find { |x| x["kind"] == "Deployment" && x.dig("metadata", "name") == "trustguard-data-plane" }
  if tg
    c = tg.dig("spec", "template", "spec", "containers").first
    abort "trustguard should not get the TrustGate-only name" if
      (c["env"] || []).any? { |x| x["name"] == "REDIS_TLS_ENABLED" }
  end
' "$out15" || { red "FAIL: hybrid Redis TLS is not delivered under both names"; exit 1; }
green "ok  - the flag resolves to true for TrustGate without renaming it for TrustGuard"

# A boolean here used to reach b64enc unconverted and abort the whole render.
# Covered by out15 above (already rendered with --set global.redis.tls=true).
green "ok  - a boolean global.redis.tls renders instead of aborting"

out15off="$TMP/scenario-redis-tls-unset.yaml"
render_default "$out15off"
assert_not_contains "$out15off" 'name: REDIS_TLS_ENABLED' \
  "hybrid: no TLS flag is invented when global.redis.tls is unset"

# The root filesystem is read-only, so with persistence on Redis crash-loops on
# "Can't open or create append-only dir" unless its --dir is the mounted PVC.
blue "==> Scenario 15b: persistent in-cluster Redis writes to its PVC"
out15p="$TMP/scenario-redis-persistence.yaml"
render_default "$out15p" --set infrastructure.redis.persistence.enabled=true
ruby -ryaml -e '
  docs = []
  YAML.load_stream(File.read(ARGV.fetch(0), encoding: "UTF-8")) { |d| docs << d if d.is_a?(Hash) }
  dep = docs.find { |d| d["kind"] == "Deployment" && d.dig("metadata", "name") == "redis" }
  abort "redis Deployment not rendered" if dep.nil?
  spec = dep.dig("spec", "template", "spec")
  c = spec.fetch("containers").find { |x| x["name"] == "redis" }
  args = c.fetch("args")
  i = args.index("--dir")
  abort "redis has no --dir, so it writes to the read-only root filesystem" if i.nil?
  vol = spec.fetch("volumes").find { |v| v.dig("persistentVolumeClaim", "claimName") == "redis-data" }
  abort "redis-data PVC is not mounted" if vol.nil?
  mount = c.fetch("volumeMounts").find { |m| m["name"] == vol["name"] }
  abort "--dir #{args[i + 1]} is not the PVC mount #{mount && mount["mountPath"]}" unless
    mount && mount["mountPath"] == args[i + 1]
' "$out15p" || { red "FAIL: persistent Redis does not write to its PVC"; exit 1; }
green "ok  - persistent Redis writes RDB/AOF to the PVC, not the read-only root"
