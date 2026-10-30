#!/usr/bin/env bash
# Render scenarios 14. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

# The console rejects in-cluster hosts in customer-facing snippets, so a
# TRUSTGUARD_PUBLIC_URL that does not resolve publicly is the same as none.
blue "==> Scenario 14: customer-facing TrustGuard origin"
out14="$TMP/scenario-trustguard-public-url.yaml"
render_default "$out14" --set global.deploymentMode=external --set global.domain=example.com
assert_env_value "$out14" control-plane-app app TRUSTGUARD_PUBLIC_URL \
  "https://trustguard.example.com" "external: the console gets a public TrustGuard origin"
ruby -ryaml -e '
  docs = []
  YAML.load_stream(File.read(ARGV.fetch(0), encoding: "UTF-8")) { |d| docs << d if d.is_a?(Hash) }
  hosts = docs.select { |d| d["kind"] == "Ingress" }
              .flat_map { |d| (d.dig("spec", "rules") || []).map { |r| r["host"] } }.compact
  app = docs.find { |d| d["kind"] == "Deployment" && d.dig("metadata", "name") == "control-plane-app" }
  env = (app.dig("spec", "template", "spec", "containers") || []).flat_map { |c| c["env"] || [] }
  url = env.find { |e| e["name"] == "TRUSTGUARD_PUBLIC_URL" }&.fetch("value")
  abort "TRUSTGUARD_PUBLIC_URL not set" if url.nil?
  host = url.sub(%r{\Ahttps?://}, "")
  abort "#{host} is not a rendered ingress host (have: #{hosts.inspect})" unless hosts.include?(host)
' "$out14" || { red "FAIL: the advertised origin is not a host the chart actually serves"; exit 1; }
green "ok  - the advertised origin matches a rendered TrustGuard ingress host"

out14ov="$TMP/scenario-trustguard-public-url-override.yaml"
render_default "$out14ov" --set global.deploymentMode=external --set global.domain=example.com \
  --set 'control-plane-app.controlPlane.components.app.config.trustguardPublicUrl=https://guard.corp.example'
assert_env_value "$out14ov" control-plane-app app TRUSTGUARD_PUBLIC_URL \
  "https://guard.corp.example" "an explicit origin wins over the derived one"
