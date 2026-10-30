#!/usr/bin/env bash
# Render scenarios 43. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

# ---------------------------------------------------------------------------
# 43. The chart stores no credential that nothing in the install reads
#
# Each case below used to be generated or written for every install of a mode,
# whether or not a workload of that install read it. Checked in both renders an
# external install can take (the in-cluster generator, the default, and the
# render-time path its opt-out keeps) and in hybrid.
# ---------------------------------------------------------------------------
GEN=(--set global.secrets.generator.enabled=true)
EXTERNAL_FIREWALL=(
  --set global.firewall.deploy=false
  --set global.firewall.baseURL=https://firewall.example.com
  --set global.firewall.existingSecret.name=operator-firewall
)
GATEWAY_API=(
  --set global.ingress.provider=gateway-api
  --set 'global.ingress.gatewayApi.parentRefs[0].name=shared'
  --set 'global.ingress.gatewayApi.parentRefs[0].namespace=gateway-system'
)

# Entries of the generator's spec ConfigMaps: "<component> <key-or-secret>".
spec_entries() {
  ruby -ryaml -rjson -e '
    YAML.load_stream(File.read(ARGV.fetch(0))).compact.each do |d|
      next unless d["kind"] == "ConfigMap"
      n = d.dig("metadata", "name").to_s
      next unless n.start_with?("neuraltrust-generator-spec-")
      JSON.parse(d.dig("data", "spec.json")).each { |e| puts "#{n.delete_prefix("neuraltrust-generator-spec-")} #{e["key"] || e["secret"]}" }
    end
  ' "$1"
}

assert_spec_entry() {
  local file="$1" mode="$2" entry="$3" msg="$4"
  if spec_entries "$file" | grep -qxF -- "$entry"; then
    [[ "$mode" == present ]] || { red "FAIL: $msg"; red "  the generator spec carries: $entry"; exit 1; }
  else
    [[ "$mode" == absent ]] || { red "FAIL: $msg"; red "  the generator spec lacks: $entry"; exit 1; }
  fi
  green "ok  - $msg"
}

# Env names a workload sources from a Secret, as "<workload> <env> <secret>/<key>".
assert_no_env() {
  local file="$1" pattern="$2" msg="$3" hits
  hits="$(ruby -ryaml -e '
    re = Regexp.new(ARGV.fetch(1))
    YAML.load_stream(File.read(ARGV.fetch(0))).compact.each do |d|
      next unless %w[Deployment StatefulSet Job].include?(d["kind"])
      pod = d.dig("spec", "template", "spec") || {}
      ((pod["containers"] || []) + (pod["initContainers"] || [])).each do |c|
        (c["env"] || []).each { |e| puts "#{d.dig("metadata", "name")} #{e["name"]}" if e["name"] =~ re }
      end
    end
  ' "$file" "$pattern")"
  if [[ -n "$hits" ]]; then
    red "FAIL: $msg"; red "  ${hits//$'\n'/$'\n'  }"; exit 1
  fi
  green "ok  - $msg"
}

blue "==> Scenario 43a: the firewall JWT key exists only when the firewall is deployed here"
o="$TMP/unread-fw-ext-gen.yaml"
render_default "$o" --set global.deploymentMode=external "${EXTERNAL_FIREWALL[@]}" "${GEN[@]}"
assert_spec_entry "$o" absent "platform JWT_SECRET" \
  "external firewall, generator: no JWT_SECRET is generated"
assert_contains "$o" 'name: "operator-firewall"' \
  "external firewall, generator: callers sign with the operator's key"
o="$TMP/unread-fw-ext.yaml"
render_default "$o" --set global.deploymentMode=external "${EXTERNAL_FIREWALL[@]}"
assert_platform_key "$o" absent JWT_SECRET \
  "external firewall, render-time: platform-secrets carries no JWT_SECRET"
o="$TMP/unread-fw-hybrid.yaml"
render_default "$o" --set global.deploymentMode=hybrid "${EXTERNAL_FIREWALL[@]}"
assert_platform_key "$o" absent JWT_SECRET \
  "external firewall, hybrid: platform-secrets carries no JWT_SECRET"
o="$TMP/unread-fw-deployed-gen.yaml"
render_default "$o" --set global.deploymentMode=external "${GEN[@]}"
assert_spec_entry "$o" present "platform JWT_SECRET" \
  "firewall deployed, generator: JWT_SECRET is generated"
o="$TMP/unread-fw-deployed-hybrid.yaml"
render_default "$o" --set global.deploymentMode=hybrid
assert_platform_key "$o" present JWT_SECRET \
  "firewall deployed, hybrid: platform-secrets carries JWT_SECRET"

blue "==> Scenario 43b: the TrustGuard client pair needs a client and a server"
o="$TMP/unread-tgc-guard-only-gen.yaml"
render_default "$o" --set global.deploymentMode=external --set global.products.trustgate=false "${GEN[@]}"
assert_spec_entry "$o" absent "trustguard-client TRUSTGUARD_CLIENT_SECRET" \
  "TrustGuard without TrustGate, generator: no client secret is generated"
assert_resource_count "$o" Secret trustguard-client-credentials 0 \
  "TrustGuard without TrustGate: no trustguard-client-credentials Secret"
assert_no_env "$o" '^TRUSTGUARD_(PLATFORM_)?CLIENT_' \
  "TrustGuard without TrustGate: no workload is handed a client pair"
o="$TMP/unread-tgc-guard-only-hybrid.yaml"
render_default "$o" --set global.deploymentMode=hybrid --set global.products.trustgate=false --set global.products.trustguard=true
assert_resource_count "$o" Secret trustguard-client-credentials 0 \
  "hybrid TrustGuard without TrustGate: no trustguard-client-credentials Secret"
o="$TMP/unread-tgc-pinned.yaml"
render_default "$o" --set global.deploymentMode=external --set global.products.trustgate=false \
  --set global.v2.trustguardClientSecret=pinned-client-secret "${GEN[@]}"
assert_spec_entry "$o" present "trustguard-client TRUSTGUARD_CLIENT_SECRET" \
  "a pinned client pair is honoured for a client outside the release"
o="$TMP/unread-tgc-both-gen.yaml"
render_default "$o" --set global.deploymentMode=external "${GEN[@]}"
assert_spec_entry "$o" present "trustguard-client TRUSTGUARD_CLIENT_SECRET" \
  "TrustGate and TrustGuard, generator: the client secret is generated"
assert_contains "$o" 'name: TRUSTGUARD_PLATFORM_CLIENT_SECRET' \
  "TrustGate and TrustGuard: TrustGuard validates the pair"

blue "==> Scenario 43c: the shared ingress certificate only where an Ingress can use it"
o="$TMP/unread-ingress-gwapi-gen.yaml"
render_default "$o" --set global.deploymentMode=external "${GATEWAY_API[@]}" "${GEN[@]}"
assert_spec_entry "$o" absent "ingress neuraltrust-generated-ingress-tls" \
  "gateway-api, generator: no ingress certificate is issued"
o="$TMP/unread-ingress-gwapi.yaml"
render_default "$o" --set global.deploymentMode=external "${GATEWAY_API[@]}"
assert_resource_count "$o" Secret neuraltrust-ingress-tls 0 \
  "gateway-api, render-time: no ingress certificate Secret"
o="$TMP/unread-ingress-gwapi-hybrid.yaml"
render_default "$o" --set global.deploymentMode=hybrid "${GATEWAY_API[@]}"
assert_resource_count "$o" Secret neuraltrust-ingress-tls 0 \
  "gateway-api, hybrid: no ingress certificate Secret"
o="$TMP/unread-ingress-managed.yaml"
render_default "$o" --set global.deploymentMode=external --set global.platform=gcp \
  --set global.ingress.gcp.managedCertificates=true "${GEN[@]}"
assert_spec_entry "$o" absent "ingress neuraltrust-generated-ingress-tls" \
  "cloud-managed certificates: no self-signed certificate is issued"
o="$TMP/unread-ingress-default-gen.yaml"
render_default "$o" --set global.deploymentMode=external "${GEN[@]}"
assert_spec_entry "$o" present "ingress neuraltrust-generated-ingress-tls" \
  "Ingress with TLS, generator: the self-signed certificate is issued"
o="$TMP/unread-ingress-default-hybrid.yaml"
render_default "$o" --set global.deploymentMode=hybrid
assert_resource_count "$o" Secret neuraltrust-ingress-tls 1 \
  "Ingress with TLS, hybrid: the self-signed certificate Secret renders"

blue "==> Scenario 43d: control-plane-secrets carries only configured credentials"
o="$TMP/unread-cp-default.yaml"
render_default "$o" --set global.deploymentMode=external --set global.secrets.generator.enabled=false
assert_secret_keys "$o" control-plane-secrets absent \
  "defaults: control-plane-secrets omits" \
  MODEL_SCANNER_SECRET NEXTAUTH_SECRET RESEND_API_KEY OPENAI_API_KEY resend-api-key SMTP_PASSWORD SES_ACCESS_KEY_ID
o="$TMP/unread-cp-default-gen.yaml"
render_default "$o" --set global.deploymentMode=external "${GEN[@]}"
assert_resource_count "$o" Secret control-plane-secrets 0 \
  "defaults, generator: control-plane-secrets has nothing to hold and is not rendered"
o="$TMP/unread-cp-configured.yaml"
render_default "$o" --set global.deploymentMode=external "${GEN[@]}" \
  --set control-plane-api.controlPlane.secrets.openaiApiKey=sk-example \
  --set global.email.resend.apiKey=re-example
assert_secret_keys "$o" control-plane-secrets present \
  "configured integrations: control-plane-secrets carries" \
  OPENAI_API_KEY resend-api-key
assert_secret_key "$o" control-plane-secrets absent RESEND_API_KEY \
  "configured Resend: the unread RESEND_API_KEY copy is not written"
o="$TMP/unread-cp-smtp.yaml"
render_default "$o" --set global.deploymentMode=external "${GEN[@]}" \
  --set global.email.provider=smtp --set global.email.smtp.host=smtp.example.com \
  --set global.email.smtp.user=mailer --set global.email.smtp.password=smtp-example \
  --set global.email.ses.accessKeyId=AKIAEXAMPLE --set global.email.ses.secretAccessKey=ses-example
assert_secret_key "$o" control-plane-secrets present SMTP_PASSWORD \
  "provider smtp: the SMTP password is written"
assert_secret_keys "$o" control-plane-secrets absent \
  "provider smtp: another provider's credentials are not written:" \
  SES_ACCESS_KEY_ID SES_SECRET_ACCESS_KEY
o="$TMP/unread-cp-ses.yaml"
render_default "$o" --set global.deploymentMode=external "${GEN[@]}" \
  --set global.email.provider=ses --set global.email.ses.region=eu-west-1 \
  --set global.email.ses.accessKeyId=AKIAEXAMPLE --set global.email.ses.secretAccessKey=ses-example \
  --set global.email.smtp.password=smtp-example
assert_secret_keys "$o" control-plane-secrets present \
  "provider ses: the static SES keys are written:" \
  SES_ACCESS_KEY_ID SES_SECRET_ACCESS_KEY
assert_secret_key "$o" control-plane-secrets absent SMTP_PASSWORD \
  "provider ses: the SMTP password is not written"
