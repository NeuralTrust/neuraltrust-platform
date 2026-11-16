#!/usr/bin/env bash
# Render scenario 45. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

# ---------------------------------------------------------------------------
# 45. global.proxy works on a cluster whose only egress is a corporate proxy.
#
# In-cluster URLs use short Service names, which `.svc` / `.cluster.local` /
# CIDR entries do not match, so global.proxy.noProxy is additive over every
# in-cluster host the chart creates. Node's fetch ignores HTTP(S)_PROXY unless
# NODE_USE_ENV_PROXY=1, so the console's SSO calls would bypass the proxy
# without it. The hybrid egress sidecar ships telemetry out and the console's
# init-db fetches cloud IAM tokens, so both need the proxy too.
# ---------------------------------------------------------------------------
blue "==> Scenario 45: global.proxy NO_PROXY is additive, Node honours the proxy"
proxy_values="$TMP/global-proxy.yaml"
cat > "$proxy_values" <<'EOF'
global:
  proxy:
    enabled: true
    httpProxy: "http://proxy.corp.example:3128"
    httpsProxy: "http://proxy.corp.example:3128"
    noProxy: " .corp.example ,10.0.0.0/8,.svc"
EOF

cluster_hosts="localhost,127.0.0.1,::1,.cluster.local,\$(KUBERNETES_SERVICE_HOST)"
cluster_hosts+=",169.254.169.254,metadata.google.internal,169.254.170.23,fd00:ec2::254,fd00:ec2::23"
cluster_hosts+=",control-plane-api-service,control-plane-app-service,data-plane-api-service"
cluster_hosts+=",control-plane-postgresql,redis,clickhouse,datacore,databridge-northbound,alertengine-api"
cluster_hosts+=",agentgateway-admin,agentgateway-proxy,agentgateway-mcp"
cluster_hosts+=",trustguard-control-plane,trustguard-data-plane,dataagent,dataagent-trustguard"
cluster_hosts+=",clickstack-collector,firewall,neuraltrust-watchdog"
cluster_hosts+=",toxicity-worker,indirect-prompt-injections-worker,prompt-jailbreak-worker"
cluster_hosts+=",complexity-worker,topic-guard-worker,otel-collector,clickstack-egress-collector"
# Operator entries first, trimmed; `.svc` is already theirs, so it is not repeated.
want_no_proxy=".corp.example,10.0.0.0/8,.svc,${cluster_hosts}"

out45e="$TMP/scenario-45-external.yaml"
render_default "$out45e" -f "$proxy_values" --set global.deploymentMode=external \
  --set global.firewall.deploy=true --set watchdog.enabled=true
for wc in control-plane-app:app control-plane-app:init-db control-plane-api:control-plane-api \
          neuraltrust-watchdog:watchdog datacore:datacore; do
  assert_env_value "$out45e" "${wc%%:*}" "${wc##*:}" NO_PROXY "$want_no_proxy" \
    "${wc}: NO_PROXY is the operator's entries plus every in-cluster host"
  assert_env_value "$out45e" "${wc%%:*}" "${wc##*:}" NODE_USE_ENV_PROXY "1" \
    "${wc}: NODE_USE_ENV_PROXY=1"
done
assert_env_value "$out45e" control-plane-app init-db HTTPS_PROXY "http://proxy.corp.example:3128" \
  "control-plane-app init-db: HTTPS_PROXY (cloud IAM token fetch)"

# Firewall workers are <key>-worker; a key added by the operator reaches the
# gateway, the only caller of the workers.
out45f="$TMP/scenario-45-firewall.yaml"
render_default "$out45f" -f "$proxy_values" --set global.deploymentMode=external \
  --set global.firewall.deploy=true --set-json 'firewall.firewall.workers.custom-model={"enabled":true}'
assert_env_value "$out45f" firewall gateway NO_PROXY "${want_no_proxy},custom-model-worker" \
  "firewall gateway: NO_PROXY includes an operator-added worker"

out45h="$TMP/scenario-45-hybrid.yaml"
render_default "$out45h" -f "$proxy_values"
assert_env_value "$out45h" dataagent clickstack-egress-collector HTTPS_PROXY "http://proxy.corp.example:3128" \
  "hybrid egress sidecar: HTTPS_PROXY (telemetry to NeuralTrust)"
assert_env_value "$out45h" dataagent clickstack-egress-collector NO_PROXY "$want_no_proxy" \
  "hybrid egress sidecar: NO_PROXY"

# A name the operator already sets through a container's extraEnv is not
# emitted again: a duplicate `name:` in one env list fails `helm upgrade`. Covers
# moving from a per-container proxy override to global.proxy, and a CA variable
# set by hand next to global.customCaCert.
dup_values="$TMP/global-proxy-extraenv.yaml"
cat > "$dup_values" <<'EOF'
global:
  customCaCert:
    enabled: true
    secretName: corp-ca
control-plane-app:
  controlPlane:
    components:
      app:
        extraEnv:
          - name: NODE_USE_ENV_PROXY
            value: "1"
          - name: HTTPS_PROXY
            value: "http://app-only.corp.example:8080"
          - name: NODE_EXTRA_CA_CERTS
            value: /etc/ssl/certs/custom-ca.crt
control-plane-api:
  controlPlane:
    components:
      api:
        extraEnv:
          - name: SSL_CERT_FILE
            value: /etc/ssl/certs/custom-ca.crt
EOF
out45d="$TMP/scenario-45-extraenv.yaml"
render_default "$out45d" -f "$proxy_values" -f "$dup_values" --set global.deploymentMode=external
ruby -ryaml -e '
  docs = []
  YAML.load_stream(File.read(ARGV[0])) { |d| docs << d if d.is_a?(Hash) }
  docs.each do |d|
    spec = d.dig("spec", "template", "spec") or next
    ((spec["containers"] || []) + (spec["initContainers"] || [])).each do |c|
      names = (c["env"] || []).map { |e| e["name"] }
      dup = names.select { |n| names.count(n) > 1 }.uniq
      abort "#{d["kind"]}/#{d.dig("metadata","name")} [#{c["name"]}] duplicate env: #{dup}" unless dup.empty?
    end
  end
' "$out45d" \
  && green "ok  - extraEnv-owned proxy and CA names are not emitted twice" \
  || { red "FAIL: duplicate env names with extraEnv overrides"; exit 1; }
assert_env_value "$out45d" control-plane-app app HTTPS_PROXY "http://app-only.corp.example:8080" \
  "control-plane-app: the operator's extraEnv value wins over global.proxy"
assert_env_value "$out45d" control-plane-app app HTTP_PROXY "http://proxy.corp.example:3128" \
  "control-plane-app: names the operator did not set still come from global.proxy"
# control-plane-api runs Python: it needs the Python trust variables, not Node's.
assert_env_value "$out45d" control-plane-api control-plane-api REQUESTS_CA_BUNDLE "/etc/ssl/certs/custom-ca.crt" \
  "control-plane-api: customCaCert sets REQUESTS_CA_BUNDLE (Python)"
assert_env_value "$out45d" control-plane-api control-plane-api NODE_EXTRA_CA_CERTS ABSENT \
  "control-plane-api: no Node-only CA variable"

# Proxy off (the default): nothing proxy-related renders anywhere.
out45o="$TMP/scenario-45-off.yaml"
render_default "$out45o" --set global.deploymentMode=external \
  --set global.firewall.deploy=true --set watchdog.enabled=true
assert_not_contains "$out45o" "NODE_USE_ENV_PROXY" "proxy off: no NODE_USE_ENV_PROXY"
assert_not_contains "$out45o" "name: NO_PROXY" "proxy off: no NO_PROXY"
