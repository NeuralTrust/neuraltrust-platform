#!/usr/bin/env bash
# Render scenario 40. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

blue "==> Scenario 40: firewall Triton cache on the writable mount"
# securityHardening makes the root filesystem read-only, so Triton's default
# ~/.triton cache fails on the first GPU op torch routes to it.
out40="$TMP/scenario-firewall-triton.yaml"
render_default "$out40" --set global.firewall.deploy=true --set global.deploymentMode=external
if ! ruby -ryaml -e '
  docs = YAML.load_stream(File.read(ARGV[0])).compact
  cm = docs.find { |d| d["kind"] == "ConfigMap" && d.dig("metadata", "name") == "firewall-config" }
  abort "firewall-config missing" if cm.nil?
  got = cm["data"]["TRITON_CACHE_DIR"]
  abort "TRITON_CACHE_DIR=#{got.inspect}" unless got == "/root/.cache/triton"
  workers = docs.select { |d| d["kind"] == "Deployment" && d.dig("spec", "template", "spec", "containers", 0, "envFrom").to_a.any? { |e| e.dig("configMapRef", "name") == "firewall-config" } && d.dig("metadata", "name").to_s.end_with?("-worker") }
  abort "no firewall workers rendered" if workers.empty?
  workers.each do |w|
    c = w.dig("spec", "template", "spec", "containers").first
    mounts = c["volumeMounts"].map { |m| m["mountPath"] }
    abort "#{w["metadata"]["name"]} has no /root/.cache mount" unless mounts.include?("/root/.cache")
  end
' "$out40"; then
  red "FAIL: firewall workers cache Triton under the /root/.cache mount"
  exit 1
fi
green "ok  - firewall workers cache Triton under the /root/.cache mount"
