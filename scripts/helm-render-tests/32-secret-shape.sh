#!/usr/bin/env bash
# Render scenarios 44. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

# ---------------------------------------------------------------------------
# 44. Secrets hold credentials, and only ones something reads
#
# Configuration (hosts, ports, users, URLs without a password, the TrustGuard
# client id) is set on the workloads, not stored in a Secret, and a Secret with
# nothing left to hold is not rendered. postgresql-secrets keeps its name and
# its connection keys: operators and DataAgent read it as a contract.
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

# Every rendered Secret has keys and at least one of them is a credential, and
# every required Secret reference resolves to a Secret the render or the
# in-cluster generator creates, or to one an operator is told to supply.
assert_secret_shape() {
  local file="$1" label="$2"
  if ! ruby -ryaml -e '
    docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
    config = %w[CLICKHOUSE_HOST CLICKHOUSE_PORT CLICKHOUSE_DATABASE CLICKHOUSE_USER CLICKHOUSE_ENDPOINT
                CLIENT_ID FIREWALL_API_URL resend-alert-sender resend-reply-to REDIS_HOST REDIS_PORT
                REDIS_TLS REDIS_USERNAME]
    frozen = %w[postgresql-secrets redis-secrets]
    # Secrets SECRETS.md tells the operator to create: console-issued tokens, the
    # first admin, the external firewall key, the pull secret.
    operator = %w[onprem-superadmin operator-firewall gcr-secret agentgateway-config-sync trustguard-config-sync
                  dataagent-enrolment-trustgate dataagent-enrolment-trustguard]
    errors = []
    rendered = []
    docs.each do |d|
      next unless d["kind"] == "Secret"
      next if (d.dig("metadata", "annotations") || {})["helm.sh/hook"]
      name = d.dig("metadata", "name")
      rendered << name
      keys = ((d["data"] || {}).keys + (d["stringData"] || {}).keys).uniq
      next if d["type"].to_s.start_with?("kubernetes.io/")
      errors << "#{name} is rendered with no keys" if keys.empty?
      errors << "#{name} holds only configuration: #{keys.sort.join(", ")}" if !keys.empty? && (keys - config).empty? && !frozen.include?(name)
    end
    # Created in the cluster by the generator and the keygen hook Jobs.
    known = rendered + %w[agentgateway-m2m-keys mcp-oauth-signing] + operator
    if docs.any? { |d| d["kind"] == "Job" && d.dig("metadata", "labels", "app.kubernetes.io/component") == "secrets-generator" }
      known += %w[platform-secrets trustguard-configsync-tls agentgateway-configsync-tls neuraltrust-ingress-tls]
    end
    docs.each do |d|
      next unless %w[Deployment StatefulSet Job].include?(d["kind"])
      pod = d.dig("spec", "template", "spec") || {}
      ((pod["containers"] || []) + (pod["initContainers"] || [])).each do |c|
        (c["env"] || []).each do |e|
          r = e.dig("valueFrom", "secretKeyRef")
          next if r.nil? || r["optional"] || known.include?(r["name"])
          errors << "#{d["metadata"]["name"]}/#{c["name"]} #{e["name"]} needs #{r["name"]}, which nothing creates"
        end
        (c["envFrom"] || []).each do |ef|
          r = ef["secretRef"]
          next if r.nil? || r["optional"] || known.include?(r["name"])
          errors << "#{d["metadata"]["name"]}/#{c["name"]} envFrom needs #{r["name"]}, which nothing creates"
        end
      end
    end
    unless errors.empty?
      warn errors.join("\n  ")
      abort
    end
  ' "$file"; then
    red "FAIL: $label"
    exit 1
  fi
  green "ok  - $label"
}

blue "==> Scenario 44a: every documented shape stores only credentials"
o="$TMP/shape-external-gen.yaml"
render_default "$o" --set global.deploymentMode=external "${GEN[@]}"
assert_secret_shape "$o" "external, generator"
o="$TMP/shape-external.yaml"
render_default "$o" --set global.deploymentMode=external
assert_secret_shape "$o" "external, render-time"
o="$TMP/shape-guard-only.yaml"
render_default "$o" --set global.deploymentMode=external --set global.products.trustgate=false \
  "${EXTERNAL_FIREWALL[@]}" "${GATEWAY_API[@]}" "${GEN[@]}"
assert_secret_shape "$o" "external, TrustGuard only, external firewall, gateway-api, generator"
o="$TMP/shape-hybrid.yaml"
render_default "$o" --set global.deploymentMode=hybrid
assert_secret_shape "$o" "hybrid"
o="$TMP/shape-saas.yaml"
render_default "$o" --set global.deploymentMode=saas
assert_secret_shape "$o" "saas, render-time"
o="$TMP/shape-saas-gen.yaml"
render_default "$o" --set global.deploymentMode=saas "${GEN[@]}"
assert_secret_shape "$o" "saas, generator"
o="$TMP/shape-watchdog.yaml"
render_default "$o" --set global.deploymentMode=external --set watchdog.enabled=true "${GEN[@]}"
assert_secret_shape "$o" "external with watchdog, generator"

blue "==> Scenario 44b: a Secret with nothing to hold is not rendered"
# autoGenerateSecrets=false is the operator's promise to supply the credentials:
# the firewall subchart renders firewall-secrets from a pinned value, never one
# it invents, which under Argo changed on every sync.
o="$TMP/shape-firewall-operator.yaml"
render_default "$o" --set global.deploymentMode=external --set global.autoGenerateSecrets=false
assert_resource_count "$o" Secret firewall-secrets 0 \
  "autoGenerateSecrets=false: no invented firewall JWT_SECRET"
o="$TMP/shape-firewall-pinned.yaml"
render_default "$o" --set global.deploymentMode=external --set global.autoGenerateSecrets=false \
  --set firewall.firewall.secrets.jwtSecret=pinned-jwt
assert_contains "$o" "JWT_SECRET: $(printf pinned-jwt | base64)\$" \
  "autoGenerateSecrets=false: firewall-secrets carries the pinned JWT_SECRET"
o="$TMP/shape-guard-only.yaml"
for s in alertengine-secrets trustguard-secrets datacore-secrets clickstack-collector-secrets \
         data-plane-jwt-secret control-plane-secrets trustguard-client-credentials clickhouse-secrets; do
  assert_resource_count "$o" Secret "$s" 0 "TrustGuard only, generator: no $s"
done
assert_env_value "$o" datacore datacore CLICKHOUSE_USER neuraltrust \
  "the ClickHouse user is plain configuration on DataCore"
assert_env_value "$o" clickstack-collector collector CLICKHOUSE_USER neuraltrust \
  "the ClickHouse user is plain configuration on the collector"
assert_env_value "$o" data-plane-api api REDIS_URL redis://redis:6379/0 \
  "a passwordless Redis URL is plain configuration on data-plane-api"
o="$TMP/shape-external-gen.yaml"
assert_env_value "$o" trustguard-data-plane data-plane TRUSTGUARD_PLATFORM_CLIENT_ID agentgateway-platform \
  "generator: the TrustGuard client id is plain configuration"
assert_resource_count "$o" Secret trustguard-client-credentials 0 \
  "generator: trustguard-client-credentials has nothing to hold"
o="$TMP/shape-client-override.yaml"
render_default "$o" --set global.deploymentMode=external --set global.v2.trustguardClientSecretName=my-client "${GEN[@]}"
assert_resource_count "$o" Secret trustguard-client-credentials 0 \
  "trustguardClientSecretName: the chart renders no Secret of its own"
assert_contains "$o" 'name: my-client' \
  "trustguardClientSecretName: both halves come from the operator's Secret"
o="$TMP/shape-redis-password.yaml"
render_default "$o" --set global.deploymentMode=external \
  --set global.redis.deploy=false --set global.redis.host=cache.example.com --set global.redis.password=example-pw
assert_secret_key "$o" data-plane-jwt-secret present REDIS_URL \
  "a Redis URL with a password stays in data-plane-jwt-secret"

blue "==> Scenario 44c: optional envFrom while the chart owns the Secret, required when the operator does"
optional_envfrom() {
  ruby -ryaml -e '
    YAML.load_stream(File.read(ARGV.fetch(0))).compact.each do |d|
      next unless d["kind"] == "Deployment"
      (d.dig("spec", "template", "spec", "containers") || []).each do |c|
        (c["envFrom"] || []).each do |ef|
          r = ef["secretRef"] or next
          puts "#{r["name"]} #{r["optional"] ? "optional" : "required"}" if r["name"] == ARGV.fetch(1)
        end
      end
    end
  ' "$1" "$2" | sort -u
}
o="$TMP/shape-external-gen.yaml"
for s in agentgateway-secrets trustguard-secrets; do
  [[ "$(optional_envfrom "$o" "$s")" == "$s optional" ]] || { red "FAIL: chart-owned $s envFrom is not optional"; exit 1; }
  green "ok  - chart-owned: envFrom of $s is optional"
done
o="$TMP/shape-preserve.yaml"
render_default "$o" --set global.deploymentMode=external --set global.preserveExistingSecrets=true
for s in agentgateway-secrets trustguard-secrets; do
  [[ "$(optional_envfrom "$o" "$s")" == "$s required" ]] || { red "FAIL: preserve mode lost the required envFrom of $s"; exit 1; }
  green "ok  - preserveExistingSecrets: envFrom of $s stays required"
done

blue "==> Scenario 44d: watchdog reads the ClickHouse password every consumer reads"
o="$TMP/shape-watchdog.yaml"
ruby -ryaml -e '
  docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
  w = docs.find { |d| d["kind"] == "StatefulSet" && d.dig("metadata", "name") == "neuraltrust-watchdog" }
  abort "watchdog not rendered" if w.nil?
  env = w.dig("spec", "template", "spec", "containers", 0, "env")
  pw = env.find { |e| e["name"] == "CLICKHOUSE_PASSWORD" }&.dig("valueFrom", "secretKeyRef")
  dc = docs.find { |d| d["kind"] == "Deployment" && d.dig("metadata", "name") == "datacore" }
  want = dc.dig("spec", "template", "spec", "containers", 0, "env").find { |e| e["name"] == "CLICKHOUSE_PASSWORD" }.dig("valueFrom", "secretKeyRef")
  abort "watchdog reads #{pw.inspect}, DataCore #{want.inspect}" unless pw && pw["name"] == want["name"] && pw["key"] == want["key"]
' "$o" || { red "FAIL: watchdog's ClickHouse password does not follow the platform"; exit 1; }
green "ok  - watchdog's ClickHouse password follows the platform, under the generator too"

blue "==> Scenario 44e: generator spec objects never outlive the render that asked for them"
o="$TMP/shape-external-gen.yaml"
ruby -ryaml -e '
  docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
  specs = docs.select { |d| d.dig("metadata", "name").to_s =~ /^neuraltrust-generator-(spec|pins)-/ }
  abort "no spec objects rendered" if specs.empty?
  specs.each do |d|
    n = d.dig("metadata", "name")
    abort "#{n} lacks the format label" unless d.dig("metadata", "labels", "neuraltrust.ai/generator-spec") == "2"
    pol = d.dig("metadata", "annotations", "helm.sh/hook-delete-policy").to_s
    abort "#{n} is not deleted once the sync succeeds: #{pol}" unless pol.split(",").include?("hook-succeeded")
  end
  job = docs.find { |d| d["kind"] == "Job" && d.dig("metadata", "name").to_s.end_with?("secrets-generator") }
  env = job.dig("spec", "template", "spec", "containers", 0, "env").to_h { |e| [e["name"], e["value"]] }
  abort "the Job is not told the format: #{env.inspect}" unless env["SPEC_LABEL"] == "neuraltrust.ai/generator-spec" && env["SPEC_FORMAT"] == "2"
  script = job.dig("spec", "template", "spec", "containers", 0, "command").last
  abort "the Job does not skip spec objects left by an earlier chart" unless script.include?("left by an earlier chart")
  role = docs.find { |d| d["kind"] == "Role" && d.dig("metadata", "name").to_s.end_with?("secrets-generator") }
  dels = role["rules"].select { |r| r["verbs"].include?("delete") }
  abort "the Job cannot remove stale spec objects" if dels.empty?
  dels.each do |r|
    abort "delete reaches beyond the spec objects: #{r["resourceNames"].inspect}" \
      unless r["resourceNames"] && r["resourceNames"].all? { |n| n =~ /^neuraltrust-generator-(spec|pins)-/ }
  end
' "$o" || { red "FAIL: generator spec objects can go stale"; exit 1; }
green "ok  - spec objects are labelled, deleted on success, and stale ones are removed by name"

# The generator's program runs in the customer's cluster, so a runtime error
# (not just a syntax error) would fail every upgrade. Run the rendered script
# against an in-memory API: it adopts a legacy value, generates a missing one,
# removes a spec an earlier chart left, and changes nothing on a second run.
if command -v node >/dev/null 2>&1; then
  ruby -ryaml -e '
    docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
    job = docs.find { |d| d["kind"] == "Job" && d.dig("metadata", "name").to_s.end_with?("secrets-generator") }
    File.write(ARGV.fetch(1), job.dig("spec", "template", "spec", "containers", 0, "command").last)
  ' "$TMP/shape-external-gen.yaml" "$TMP/generator.js"
  b64() { printf '%s' "$1" | base64; }
  cat > "$TMP/fake-state.json" <<JSON
{"configmaps": {
  "neuraltrust-generator-spec-platform": {"metadata": {"labels": {"neuraltrust.ai/generator-spec": "2"}},
    "data": {"spec.json": "[{\"key\":\"ADOPTED\",\"type\":\"alnum\",\"length\":16,\"adopt\":[[\"legacy-secrets\",\"OLD\"]]},{\"key\":\"FRESH\",\"type\":\"alnum\",\"length\":24}]"}},
  "neuraltrust-generator-spec-ingress": {"metadata": {"labels": {}},
    "data": {"spec.json": "[{\"key\":\"STALE\",\"type\":\"alnum\",\"length\":8}]"}}},
 "secrets": {
  "legacy-secrets": {"metadata": {}, "data": {"OLD": "$(b64 kept-legacy-value)"}},
  "neuraltrust-generator-pins-ingress": {"metadata": {"labels": {}}, "data": {"STALE": "$(b64 pinned)"}}}}
JSON
  run_generator() {
    FAKE_STATE="$TMP/fake-state.json" GENERATED_SECRET=platform-secrets SPEC_COMPONENTS="platform ingress" \
      SPEC_LABEL=neuraltrust.ai/generator-spec SPEC_FORMAT=2 PREVIOUS_SECRET=neuraltrust-generated \
      MARKER=neuraltrust.ai/secrets-generator \
      node --require "$(cd "$(dirname "$0")" && pwd)/fake-kube-api.js" "$TMP/generator.js"
  }
  run_generator > "$TMP/generator-1.log" 2>&1 || { red "FAIL: the generator script fails at runtime"; sed 's/^/  /' "$TMP/generator-1.log"; exit 1; }
  ruby -rjson -rbase64 -e '
    s = JSON.parse(File.read(ARGV.fetch(0)))
    gen = s.dig("secrets", "platform-secrets") or abort "no generated Secret was created"
    d = gen["data"].transform_values { |v| Base64.decode64(v) }
    abort "ADOPTED=#{d["ADOPTED"].inspect}, want the legacy value" unless d["ADOPTED"] == "kept-legacy-value"
    abort "FRESH was not generated" unless d["FRESH"].to_s.length == 24
    abort "a stale spec was acted on: #{d.keys.inspect}" if d.key?("STALE")
    abort "the stale spec ConfigMap was left in place" if s["configmaps"].key?("neuraltrust-generator-spec-ingress")
    abort "the stale pins Secret was left in place" if s["secrets"].key?("neuraltrust-generator-pins-ingress")
    abort "the current spec was removed" unless s["configmaps"].key?("neuraltrust-generator-spec-platform")
  ' "$TMP/fake-state.json" || { red "FAIL: the generator did not adopt, generate and clean up as specified"; sed 's/^/  /' "$TMP/generator-1.log"; exit 1; }
  green "ok  - generator run: adopts, generates, and removes specs left by an earlier chart"
  cp "$TMP/fake-state.json" "$TMP/fake-state-1.json"
  run_generator > "$TMP/generator-2.log" 2>&1 || { red "FAIL: a second generator run fails"; sed 's/^/  /' "$TMP/generator-2.log"; exit 1; }
  cmp -s "$TMP/fake-state.json" "$TMP/fake-state-1.json" || { red "FAIL: a second generator run changed something"; exit 1; }
  grep -q 'nothing to do' "$TMP/generator-2.log" || { red "FAIL: a second generator run did not report nothing to do"; exit 1; }
  green "ok  - generator run: a second run changes nothing"
else
  yellow "skip - node not available to run the generator script"
fi
