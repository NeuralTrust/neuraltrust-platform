#!/usr/bin/env bash
# Run through scripts/test-helm-render.sh.
source "$(dirname "$0")/lib.sh"
suite_full || exit 0

blue "==> Scenario 48: hostAliases for the Firewall gateway (Azure private endpoints)"
FW_ARGS=(--set global.firewall.deploy=true
  --set firewall.firewall.gateway.decision.enabled=true
  --set firewall.firewall.gateway.decision.provider=azure_foundry
  --set firewall.firewall.gateway.decision.model=gpt-4o-mini
  --set firewall.firewall.gateway.decision.url=https://example-res.openai.azure.com
  --set firewall.firewall.gateway.decision.apiKeyExistingSecret.name=decision-key)

pod_aliases() { # file deployment -> JSON of spec.template.spec.hostAliases ("null" if absent)
  ruby -ryaml -rjson -e '
    d = YAML.load_stream(File.read(ARGV[0])).compact.find { |x| x["kind"] == "Deployment" && x.dig("metadata","name") == ARGV[1] }
    abort "no Deployment #{ARGV[1]}" unless d
    puts JSON.generate(d.dig("spec","template","spec","hostAliases"))' "$1" "$2"
}
others_with_aliases() { # every pod-bearing object other than the firewall gateway that has hostAliases
  ruby -ryaml -e '
    YAML.load_stream(File.read(ARGV[0])).compact.each do |d|
      spec = d.dig("spec","template","spec") || d.dig("spec","jobTemplate","spec","template","spec")
      next unless spec
      next if d["kind"] == "Deployment" && d.dig("metadata","name") == "firewall"
      puts "#{d["kind"]}/#{d.dig("metadata","name")}" if spec.key?("hostAliases")
    end' "$1"
}
check() {
  local got="$1" want="$2" msg="$3"
  if [[ "$got" != "$want" ]]; then
    red "FAIL: $msg"
    red "  want: $want"
    red "  got:  $got"
    exit 1
  fi
  green "ok  - $msg"
}

out="$TMP/ha-default.yaml"
render_default "$out" "${FW_ARGS[@]}"
check "$(pod_aliases "$out" firewall)" null "default: no hostAliases on the gateway"
assert_not_contains "$out" 'hostAliases:' "default: no hostAliases anywhere"

out="$TMP/ha-local.yaml"
render_default "$out" "${FW_ARGS[@]}" \
  --set 'firewall.firewall.gateway.hostAliases[0].ip=10.20.30.40' \
  --set 'firewall.firewall.gateway.hostAliases[0].hostnames[0]=example-res.openai.azure.com' \
  --set 'firewall.firewall.gateway.hostAliases[0].hostnames[1]=example-res.cognitiveservices.azure.com'
check "$(pod_aliases "$out" firewall)" \
  '[{"hostnames":["example-res.openai.azure.com","example-res.cognitiveservices.azure.com"],"ip":"10.20.30.40"}]' \
  "local list reaches the gateway pod spec"
check "$(others_with_aliases "$out")" "" "local list stays on the gateway only"
assert_env_value "$out" firewall gateway DECISION_SERVICE_URL https://example-res.openai.azure.com \
  "decision URL keeps the public hostname (TLS name unchanged)"

out="$TMP/ha-global.yaml"
render_default "$out" "${FW_ARGS[@]}" \
  --set 'global.hostAliases[0].ip=10.0.0.1' \
  --set 'global.hostAliases[0].hostnames[0]=a.services.ai.azure.com' \
  --set 'firewall.firewall.gateway.hostAliases[0].ip=10.0.0.2' \
  --set 'firewall.firewall.gateway.hostAliases[0].hostnames[0]=b.openai.azure.com'
check "$(pod_aliases "$out" firewall)" \
  '[{"hostnames":["a.services.ai.azure.com"],"ip":"10.0.0.1"},{"hostnames":["b.openai.azure.com"],"ip":"10.0.0.2"}]' \
  "global entries come first, then the gateway's own"
check "$(others_with_aliases "$out")" "" "global list reaches no other workload"

out="$TMP/ha-nofw.yaml"
render_default "$out" \
  --set 'global.hostAliases[0].ip=10.0.0.1' \
  --set 'global.hostAliases[0].hostnames[0]=a.example'
assert_not_contains "$out" 'hostAliases:' "firewall off: global list renders nowhere"
