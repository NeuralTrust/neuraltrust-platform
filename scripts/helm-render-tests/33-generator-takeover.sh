#!/usr/bin/env bash
# Render scenarios 45. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

# ---------------------------------------------------------------------------
# 45. The generator writes platform-secrets and the TLS Secrets' own names
#
# Before 3.7 the chart rendered those Secrets, so on an upgrade they exist and
# Helm or Argo tracks them; from 3.7 to 3.9 the generator wrote the same values
# to neuraltrust-generated. The Job takes a rendered Secret over before writing
# anything (Argo tracking removed, Prune=false), adopts the earlier generator's
# values first, never writes a Secret the operator supplies, and stops at the
# first refused takeover.
# ---------------------------------------------------------------------------
GEN=(--set global.secrets.generator.enabled=true)

blue "==> Scenario 45a: consumers and the Job use the original names"
o="$TMP/takeover-external.yaml"
render_default "$o" --set global.deploymentMode=external --set global.products.trustgate=true "${GEN[@]}"
assert_resource_count "$o" Secret platform-secrets 0 \
  "generator: platform-secrets is not rendered, the Job writes it"
assert_env_value "$o" control-plane-postgresql postgresql POSTGRES_PASSWORD secretKeyRef:platform-secrets/POSTGRES_PASSWORD \
  "generator: a generated password is read from platform-secrets"
assert_not_contains "$o" 'secretName: neuraltrust-generated' \
  "generator: nothing mounts the 3.7 to 3.9 TLS names"
if ! ruby -ryaml -rjson -e '
  docs = YAML.load_stream(File.read(ARGV[0])).compact
  job = docs.find { |d| d["kind"] == "Job" && d.dig("metadata", "name").to_s.end_with?("secrets-generator") } or abort "no generator Job"
  env = job.dig("spec", "template", "spec", "containers", 0, "env").to_h { |e| [e["name"], e["value"]] }
  abort "GENERATED_SECRET=#{env["GENERATED_SECRET"]}" unless env["GENERATED_SECRET"] == "platform-secrets"
  abort "PREVIOUS_SECRET=#{env["PREVIOUS_SECRET"]}" unless env["PREVIOUS_SECRET"] == "neuraltrust-generated"
  prev = JSON.parse(env["PREVIOUS_TLS"])
  abort "PREVIOUS_TLS=#{prev}" unless prev["trustguard-configsync-tls"] == "neuraltrust-generated-trustguard-configsync-tls"
  role = docs.find { |d| d["kind"] == "Role" && d.dig("metadata", "name").to_s.end_with?("secrets-generator") }
  get = role["rules"].select { |r| r["resources"] == ["secrets"] && r["verbs"] == ["get"] }.flat_map { |r| r["resourceNames"] }
  patch = role["rules"].select { |r| r["resources"] == ["secrets"] && r["verbs"] == ["patch"] }.flat_map { |r| r["resourceNames"] }
  (prev.values + ["neuraltrust-generated"]).each { |n| abort "the Role cannot read #{n}" unless get.include?(n) }
  %w[platform-secrets trustguard-configsync-tls agentgateway-configsync-tls neuraltrust-ingress-tls].each { |n| abort "the Role cannot patch #{n}" unless patch.include?(n) }
' "$o"; then
  red "FAIL: generator Job wiring for the original names"
  exit 1
fi
green "ok  - generator Job writes the original names and may read the earlier ones"

o="$TMP/takeover-operator-shared.yaml"
render_default "$o" --set global.deploymentMode=external "${GEN[@]}" \
  --set global.platformSecret.existingSecret.name=platform-secrets
assert_env_value "$o" neuraltrust-platform-secrets-generator generate OPERATOR_SECRETS platform-secrets \
  "operator platform-secrets: the Job checks it and never writes it"
assert_not_contains "$o" 'name: neuraltrust-generator-spec-platform$' \
  "operator platform-secrets: the registry keys are the operator's"

# saas: the generator also issues the certificates other clusters dial, and
# names them as the chart did, so scripts/export-controlplane-ca.sh reads them.
o="$TMP/takeover-saas.yaml"
render_default "$o" --set global.deploymentMode=saas --set global.domain=cp.example.com "${GEN[@]}"
assert_resource_count "$o" Secret platform-secrets 0 \
  "saas generator: platform-secrets is not rendered"
for tls in trustguard-configsync-tls agentgateway-configsync-tls databridge-southbound-tls; do
  assert_resource_count "$o" Secret "$tls" 0 \
    "saas generator: $tls is issued by the Job, not rendered"
done
if ! ruby -ryaml -rjson -e '
  docs = YAML.load_stream(File.read(ARGV[0])).compact
  specs = docs.select { |d| d["kind"] == "ConfigMap" && d.dig("metadata", "name").to_s.start_with?("neuraltrust-generator-spec-") }
  tls = specs.flat_map { |c| JSON.parse(c.dig("data", "spec.json")) }.select { |e| e["type"] == "tls" }.to_h { |e| [e["secret"], e] }
  { "trustguard-configsync-tls" => "trustguard-configsync.cp.example.com", "agentgateway-configsync-tls" => "agentgateway-configsync.cp.example.com",
    "databridge-southbound-tls" => "databridge.cp.example.com" }.each do |name, host|
    e = tls[name] or abort "no spec for #{name}"
    abort "#{name}: not reissued on a name change" unless e["reissue"] == true
    abort "#{name}: SANs #{e["sans"]} lack #{host}" unless e["sans"].include?(host)
  end
  abort "the ingress certificate is in-cluster only, never reissued" if tls.dig("neuraltrust-ingress-tls", "reissue")
  abort "databridge: southbound host annotation" unless tls.dig("databridge-southbound-tls", "annotations", "neuraltrust.ai/southbound-host") == "databridge.cp.example.com"
  role = docs.find { |d| d["kind"] == "Role" && d.dig("metadata", "name").to_s.end_with?("secrets-generator") }
  patch = role["rules"].select { |r| r["resources"] == ["secrets"] && r["verbs"] == ["patch"] }.flat_map { |r| r["resourceNames"] }
  abort "the Role cannot patch databridge-southbound-tls" unless patch.include?("databridge-southbound-tls")
  job = docs.find { |d| d["kind"] == "Job" && d.dig("metadata", "name").to_s.end_with?("secrets-generator") }
  comps = job.dig("spec", "template", "spec", "containers", 0, "env").find { |v| v["name"] == "SPEC_COMPONENTS" }["value"].split
  abort "the Job does not read the databridge spec" unless comps.include?("databridge")
  db = docs.find { |d| d["kind"] == "Deployment" && d.dig("metadata", "name") == "databridge" }
  vols = db.dig("spec", "template", "spec", "volumes").map { |v| v.dig("secret", "secretName") }.compact
  abort "databridge mounts #{vols}" unless vols.include?("databridge-southbound-tls")
' "$o"; then
  red "FAIL: saas generator wiring for the published certificates"
  exit 1
fi
green "ok  - saas generator issues the published certificates, reissued when their names change"
o="$TMP/takeover-saas-telemetry.yaml"
render_default "$o" --set global.deploymentMode=saas --set global.domain=cp.example.com "${GEN[@]}" \
  --set clickstack-ingest-gateway.ingress.tls.autoGenerate=true
assert_resource_count "$o" Secret clickstack-ingest-gateway-tls 0 \
  "saas generator: the telemetry certificate is issued by the Job, not rendered"
assert_contains "$o" '^  name: neuraltrust-generator-spec-clickstack-ingest-gateway$' \
  "saas generator: the telemetry certificate has a spec"
assert_contains "$o" 'secretName: "clickstack-ingest-gateway-tls"' \
  "saas generator: the telemetry Ingress serves the generated certificate"
assert_env_value "$o" clickstack-ingest-gateway collector OTLP_AUTH_TOKEN secretKeyRef:platform-secrets/OTLP_AUTH_TOKEN \
  "saas generator: the ingest gateway reads the collector token from platform-secrets"

# The RSA keys the keygen hooks minted (TrustGate machine credentials, MCP OAuth
# signing): the generator mints them into platform-secrets, adopting the hooks'
# Secrets first, so an install needs no hook beyond the generator's.
o="$TMP/takeover-keys.yaml"
render_default "$o" --set global.deploymentMode=external --set global.products.trustgate=true "${GEN[@]}"
assert_not_contains "$o" 'name: neuraltrust-platform-agentgateway-m2m-keys$' \
  "generator: no machine-credential keygen hook"
assert_not_contains "$o" 'name: neuraltrust-platform-mcp-signing-key$' \
  "generator: no MCP signing-key keygen hook"
assert_env_value "$o" control-plane-app app AGENTGATEWAY_M2M_PRIVATE_KEY secretKeyRef:platform-secrets/AGENTGATEWAY_M2M_PRIVATE_KEY \
  "generator: the app signs with the private half from platform-secrets"
assert_env_value "$o" agentgateway-admin admin ADMIN_M2M_PUBLIC_KEYS secretKeyRef:platform-secrets/ADMIN_M2M_PUBLIC_KEYS \
  "generator: TrustGate admin verifies with the public half from platform-secrets"
assert_env_value "$o" control-plane-app app MCP_OAUTH_SIGNING_KEY secretKeyRef:platform-secrets/MCP_OAUTH_SIGNING_KEY \
  "generator: the app reads the MCP signing key from platform-secrets"
o="$TMP/takeover-keys-off.yaml"
render_default "$o" --set global.deploymentMode=external --set global.products.trustgate=true
assert_contains "$o" 'name: neuraltrust-platform-agentgateway-m2m-keys$' \
  "generator off: the keygen hook still mints the pair"
assert_env_value "$o" agentgateway-admin admin ADMIN_M2M_PUBLIC_KEYS secretKeyRef:agentgateway-m2m-keys/ADMIN_M2M_PUBLIC_KEYS \
  "generator off: TrustGate admin reads the hook's Secret"

for off in "opt-out|--set global.secrets.generator.enabled=false" "hybrid|--set global.deploymentMode=hybrid"; do
  label="${off%%|*}"
  read -r -a oargs <<< "${off#*|}"
  o="$TMP/takeover-off-$label.yaml"
  render_default "$o" --set global.deploymentMode=external "${oargs[@]}"
  assert_resource_count "$o" Secret platform-secrets 1 \
    "$label: the chart still renders platform-secrets"
done

blue "==> Scenario 45b: the Job program, against an in-memory API"
if ! command -v node >/dev/null 2>&1; then
  yellow "skip - node not available to run the generator script"
  exit 0
fi
ruby -ryaml -e '
  docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
  job = docs.find { |d| d["kind"] == "Job" && d.dig("metadata", "name").to_s.end_with?("secrets-generator") }
  File.write(ARGV.fetch(1), job.dig("spec", "template", "spec", "containers", 0, "command").last)
' "$TMP/takeover-external.yaml" "$TMP/generator.js"
FAKE_API="$(cd "$(dirname "$0")" && pwd)/fake-kube-api.js"
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
CERT_A="$(b64 cert-a)"; KEY_A="$(b64 key-a)"; CA_A="$(b64 ca-a)"
CERT_B="$(b64 cert-b)"; KEY_B="$(b64 key-b)"; CA_B="$(b64 ca-b)"
# One registry-style key with a legacy source, one the install never had, and an
# install-only key (encrypts data at rest), plus the TrustGuard config-sync pair.
SPEC='[{"key":"K1","type":"alnum","length":16,"adopt":[["platform-secrets","K1"]]},{"key":"NEW","type":"alnum","length":20},{"key":"AT_REST","type":"install","length":20,"freshIf":["platform-secrets"]},{"type":"tls","secret":"trustguard-configsync-tls","cn":"tg","caCn":"tg-ca","sans":["tg"],"adopt":[["trustguard-configsync-tls"]]}]'
SPEC_JSON="$(ruby -rjson -e 'print JSON.generate(ARGV[0])' "$SPEC")"
specs() {
  printf '{"neuraltrust-generator-spec-platform": {"metadata": {"labels": {"neuraltrust.ai/generator-spec": "2"}}, "data": {"spec.json": %s}}}' "$SPEC_JSON"
}
# A Secret as Helm rendered it under Argo, before 3.7.
rendered() {  # name type data-json
  printf '{"metadata": {"labels": {"app.kubernetes.io/instance": "nt", "app.kubernetes.io/managed-by": "Helm"}, "annotations": {"argocd.argoproj.io/tracking-id": "nt:/Secret:ns/%s", "meta.helm.sh/release-name": "nt", "helm.sh/resource-policy": "keep"}}, "type": "%s", "data": %s}' "$1" "$2" "$3"
}
run() {  # state-file [env...]
  local f="$1"; shift
  env FAKE_STATE="$f" GENERATED_SECRET=platform-secrets SPEC_COMPONENTS=platform \
    SPEC_LABEL=neuraltrust.ai/generator-spec SPEC_FORMAT=2 PREVIOUS_SECRET=neuraltrust-generated \
    PREVIOUS_TLS='{"trustguard-configsync-tls":"neuraltrust-generated-trustguard-configsync-tls"}' \
    MARKER=neuraltrust.ai/secrets-generator "$@" \
    node --require "$FAKE_API" "$TMP/generator.js"
}
check() {  # state-file log label ruby-body
  if ! ruby -rjson -rbase64 -e '
    s = JSON.parse(File.read(ARGV.fetch(0)))
    sec = ->(n) { s.dig("secrets", n) }
    val = ->(n, k) { v = sec.(n)&.dig("data", k); v && Base64.decode64(v) }
    ann = ->(n) { sec.(n)&.dig("metadata", "annotations") || {} }
    lab = ->(n) { sec.(n)&.dig("metadata", "labels") || {} }
    log = s["log"] || []
    eval(ARGV.fetch(1))
  ' "$1" "$4"; then
    red "FAIL: $3"
    sed 's/^/  /' "$2"
    exit 1
  fi
  green "ok  - $3"
}

# Upgrade from before 3.7 under Argo: platform-secrets and the TLS Secret are
# the ones the chart rendered, tracked by the Application.
st="$TMP/state-pre37.json"
cat > "$st" <<JSON
{"configmaps": $(specs), "secrets": {
  "platform-secrets": $(rendered platform-secrets Opaque "{\"K1\": \"$(b64 rendered-k1)\", \"EXTRA\": \"$(b64 extra)\"}"),
  "trustguard-configsync-tls": $(rendered trustguard-configsync-tls kubernetes.io/tls "{\"tls.crt\": \"$CERT_A\", \"tls.key\": \"$KEY_A\", \"ca.crt\": \"$CA_A\"}")}}
JSON
run "$st" > "$TMP/pre37.log" 2>&1 || { red "FAIL: the generator fails taking over a rendered platform-secrets"; sed 's/^/  /' "$TMP/pre37.log"; exit 1; }
check "$st" "$TMP/pre37.log" "before 3.7 under Argo: both Secrets are taken over before any value is written" '
  takeovers = log.each_index.select { |i| log[i].end_with?(" metadata") }
  writes = log.each_index.select { |i| log[i] =~ /^(create|patch secrets\/\S+ data)/ }
  abort "log: #{log}" unless takeovers.size == 2 && writes.all? { |w| w > takeovers.max }
  %w[platform-secrets trustguard-configsync-tls].each do |n|
    abort "#{n} still tracked: #{ann.(n)} #{lab.(n)}" if ann.(n).key?("argocd.argoproj.io/tracking-id") || lab.(n).key?("app.kubernetes.io/instance")
    abort "#{n} not protected: #{ann.(n)}" unless ann.(n)["argocd.argoproj.io/sync-options"] == "Prune=false,Delete=false" && ann.(n)["neuraltrust.ai/secrets-generator"] == "managed"
    abort "#{n} lost what Helm needs to roll back to it" unless lab.(n)["app.kubernetes.io/managed-by"] == "Helm" && ann.(n)["meta.helm.sh/release-name"] == "nt"
  end'
check "$st" "$TMP/pre37.log" "before 3.7: values are kept, missing ones generated, an install-only key is not" '
  abort "K1=#{val.("platform-secrets", "K1")}" unless val.("platform-secrets", "K1") == "rendered-k1"
  abort "EXTRA was dropped" unless val.("platform-secrets", "EXTRA") == "extra"
  abort "NEW was not generated" unless val.("platform-secrets", "NEW").to_s.size == 20
  abort "AT_REST was generated on an upgrade" if val.("platform-secrets", "AT_REST")
  abort "the certificate changed" unless val.("trustguard-configsync-tls", "tls.crt") == "cert-a"'
cp "$st" "$TMP/state-pre37-1.json"
run "$st" > "$TMP/pre37-2.log" 2>&1 || { red "FAIL: a second run fails"; sed 's/^/  /' "$TMP/pre37-2.log"; exit 1; }
check "$st" "$TMP/pre37-2.log" "taken over: a second run writes nothing" '
  first = JSON.parse(File.read(ARGV.fetch(0).sub(".json", "-1.json")))
  abort "wrote: #{log - first["log"]}" unless log == first["log"] && s["secrets"] == first["secrets"]'

# Upgrade from 3.7 to 3.9: the services read neuraltrust-generated; the copies
# an earlier chart rendered still hold older values.
st="$TMP/state-37.json"
cat > "$st" <<JSON
{"configmaps": $(specs), "secrets": {
  "neuraltrust-generated": {"metadata": {"labels": {"app.kubernetes.io/managed-by": "neuraltrust-secrets-generator"}}, "data": {"K1": "$(b64 generated-k1)", "NEW": "$(b64 generated-new)", "AT_REST": "$(b64 generated-at-rest)", "ONLY_37": "$(b64 only-37)"}},
  "neuraltrust-generated-trustguard-configsync-tls": {"metadata": {}, "type": "kubernetes.io/tls", "data": {"tls.crt": "$CERT_A", "tls.key": "$KEY_A", "ca.crt": "$CA_A"}},
  "platform-secrets": $(rendered platform-secrets Opaque "{\"K1\": \"$(b64 stale-k1)\"}"),
  "trustguard-configsync-tls": $(rendered trustguard-configsync-tls kubernetes.io/tls "{\"tls.crt\": \"$CERT_B\", \"tls.key\": \"$KEY_B\", \"ca.crt\": \"$CA_B\"}")}}
JSON
run "$st" > "$TMP/37.log" 2>&1 || { red "FAIL: the generator fails upgrading from 3.7"; sed 's/^/  /' "$TMP/37.log"; exit 1; }
check "$st" "$TMP/37.log" "from 3.7 to 3.9: the values the services read win over an older rendered copy" '
  { "K1" => "generated-k1", "NEW" => "generated-new", "AT_REST" => "generated-at-rest", "ONLY_37" => "only-37" }.each do |k, v|
    abort "#{k}=#{val.("platform-secrets", k).inspect}, want #{v}" unless val.("platform-secrets", k) == v
  end
  abort "certificate: #{val.("trustguard-configsync-tls", "tls.crt")}" unless val.("trustguard-configsync-tls", "tls.crt") == "cert-a" && val.("trustguard-configsync-tls", "ca.crt") == "ca-a"
  abort "the earlier Secret was touched" unless sec.("neuraltrust-generated")["data"].size == 4'

# Fresh on 3.7, upgraded: nothing rendered platform-secrets, so it is created.
st="$TMP/state-37-fresh.json"
cat > "$st" <<JSON
{"configmaps": $(specs), "secrets": {
  "neuraltrust-generated": {"metadata": {}, "data": {"K1": "$(b64 generated-k1)"}},
  "neuraltrust-generated-trustguard-configsync-tls": {"metadata": {}, "type": "kubernetes.io/tls", "data": {"tls.crt": "$CERT_A", "tls.key": "$KEY_A", "ca.crt": "$CA_A"}}}}
JSON
run "$st" > "$TMP/37-fresh.log" 2>&1 || { red "FAIL: the generator fails on a 3.7 fresh install"; sed 's/^/  /' "$TMP/37-fresh.log"; exit 1; }
check "$st" "$TMP/37-fresh.log" "installed on 3.7: created with the earlier values, and marked" '
  abort "K1=#{val.("platform-secrets", "K1")}" unless val.("platform-secrets", "K1") == "generated-k1"
  abort "AT_REST generated though the install predates it" if val.("platform-secrets", "AT_REST")
  abort "not marked: #{ann.("platform-secrets")}" unless ann.("platform-secrets")["neuraltrust.ai/secrets-generator"] == "managed"
  abort "certificate not adopted" unless val.("trustguard-configsync-tls", "tls.crt") == "cert-a"'

# A fresh install: the install-only key is generated.
st="$TMP/state-fresh.json"
printf '{"configmaps": %s, "secrets": {"neuraltrust-generated-trustguard-configsync-tls": {"metadata": {}, "type": "kubernetes.io/tls", "data": {"tls.crt": "%s", "tls.key": "%s", "ca.crt": "%s"}}}}' "$(specs)" "$CERT_A" "$KEY_A" "$CA_A" > "$st"
run "$st" > "$TMP/fresh.log" 2>&1 || { red "FAIL: the generator fails on a fresh install"; sed 's/^/  /' "$TMP/fresh.log"; exit 1; }
check "$st" "$TMP/fresh.log" "fresh install: every key generated, the install-only one too" '
  %w[K1 NEW AT_REST].each { |k| abort "#{k} missing" unless val.("platform-secrets", k).to_s.size > 0 }'

# The operator's own Secret, by ownerReferences (External Secrets) or by name in
# values: checked, never written.
for how in "owner" "values"; do
  st="$TMP/state-operator-$how.json"
  owners='[]'; extra=()
  if [ "$how" = owner ]; then owners='[{"apiVersion": "external-secrets.io/v1", "kind": "ExternalSecret", "name": "platform"}]'; else extra=(OPERATOR_SECRETS=platform-secrets); fi
  cat > "$st" <<JSON
{"configmaps": $(specs), "secrets": {
  "platform-secrets": {"metadata": {"ownerReferences": $owners, "annotations": {"argocd.argoproj.io/tracking-id": "theirs"}}, "data": {"K1": "$(b64 theirs)"}},
  "trustguard-configsync-tls": {"metadata": {}, "type": "kubernetes.io/tls", "data": {"tls.crt": "$CERT_A", "tls.key": "$KEY_A", "ca.crt": "$CA_A"}}}}
JSON
  if run "$st" ${extra[@]+"${extra[@]}"} > "$TMP/operator-$how.log" 2>&1; then
    red "FAIL: operator platform-secrets ($how) missing a key: the Job succeeded"; sed 's/^/  /' "$TMP/operator-$how.log"; exit 1
  fi
  check "$st" "$TMP/operator-$how.log" "operator platform-secrets ($how), missing a key: fails, names it, writes nothing" '
    abort "wrote: #{log}" unless log.none? { |l| l.include?("platform-secrets") }
    abort "tracking changed" unless ann.("platform-secrets")["argocd.argoproj.io/tracking-id"] == "theirs"
    abort "the error does not name the missing keys" unless File.read(ARGV.fetch(0).sub(/state-operator-(\w+)\.json/, "operator-\\1.log")).include?("lacks: NEW")'
done

# A refused takeover (no patch right, an admission policy) stops the Job before
# it writes anything, so Argo stops the sync before pruning.
st="$TMP/state-denied.json"
cat > "$st" <<JSON
{"configmaps": $(specs), "secrets": {
  "platform-secrets": $(rendered platform-secrets Opaque "{\"K1\": \"$(b64 rendered-k1)\"}"),
  "trustguard-configsync-tls": $(rendered trustguard-configsync-tls kubernetes.io/tls "{\"tls.crt\": \"$CERT_A\", \"tls.key\": \"$KEY_A\", \"ca.crt\": \"$CA_A\"}")}}
JSON
if run "$st" FAKE_DENY_TAKEOVER=1 > "$TMP/denied.log" 2>&1; then
  red "FAIL: a refused takeover did not fail the Job"; sed 's/^/  /' "$TMP/denied.log"; exit 1
fi
check "$st" "$TMP/denied.log" "refused takeover: the Job fails and writes nothing" '
  abort "wrote: #{log}" unless log.empty?
  abort "values changed" unless val.("platform-secrets", "K1") == "rendered-k1" && !sec.("platform-secrets")["data"].key?("NEW")'

# A certificate other clusters dial (saas): kept while it covers the names in the
# spec, reissued when they change, which is what retargeting
# global.controlPlane.domain relies on. The SANs digest is the annotation the
# chart's own template wrote, so an upgrade adopts its certificate.
PUB_SPEC='[{"type":"tls","secret":"databridge-southbound-tls","cn":"databridge.cp.example.com","caCn":"databridge-southbound-ca","sans":["databridge.cp.example.com","databridge-southbound"],"reissue":true,"annotations":{"neuraltrust.ai/southbound-host":"databridge.cp.example.com"},"adopt":[["databridge-southbound-tls"]]}]'
PUB_HASH="$(printf '%s' 'databridge.cp.example.com,databridge-southbound' | shasum -a 256 | cut -c1-16)"
pub_state() {  # file sans-digest
  printf '{"configmaps": {"neuraltrust-generator-spec-databridge": {"metadata": {"labels": {"neuraltrust.ai/generator-spec": "2"}}, "data": {"spec.json": %s}}}, "secrets": {"databridge-southbound-tls": {"metadata": {"labels": {"app.kubernetes.io/instance": "nt"}, "annotations": {"neuraltrust.ai/tls-sans": "%s", "argocd.argoproj.io/tracking-id": "nt:/Secret:ns/databridge-southbound-tls"}}, "type": "kubernetes.io/tls", "data": {"tls.crt": "%s", "tls.key": "%s", "ca.crt": "%s"}}}}' \
    "$(ruby -rjson -e 'print JSON.generate(ARGV[0])' "$PUB_SPEC")" "$2" "$CERT_A" "$KEY_A" "$CA_A" > "$1"
}
st="$TMP/state-published.json"
pub_state "$st" "$PUB_HASH"
run "$st" SPEC_COMPONENTS=databridge > "$TMP/published.log" 2>&1 || { red "FAIL: the generator fails on a published certificate"; sed 's/^/  /' "$TMP/published.log"; exit 1; }
check "$st" "$TMP/published.log" "published certificate, same names: taken over and kept" '
  abort "reissued: #{log}" unless val.("databridge-southbound-tls", "tls.crt") == "cert-a"
  abort "not taken over: #{ann.("databridge-southbound-tls")}" unless ann.("databridge-southbound-tls")["neuraltrust.ai/secrets-generator"] == "managed"'
st="$TMP/state-retargeted.json"
pub_state "$st" "0000000000000000"
run "$st" SPEC_COMPONENTS=databridge > "$TMP/retargeted.log" 2>&1 || { red "FAIL: the generator fails reissuing a certificate"; sed 's/^/  /' "$TMP/retargeted.log"; exit 1; }
check "$st" "$TMP/retargeted.log" "published certificate, domain retargeted: reissued for the new names" '
  crt = val.("databridge-southbound-tls", "tls.crt")
  abort "kept the old certificate" if crt == "cert-a"
  abort "not a certificate" unless crt.to_s.include?("BEGIN CERTIFICATE")
  a = ann.("databridge-southbound-tls")
  abort "annotations: #{a}" unless a["neuraltrust.ai/tls-sans"] == "'"$PUB_HASH"'" && a["neuraltrust.ai/southbound-host"] == "databridge.cp.example.com"'
cp "$st" "$TMP/state-retargeted-1.json"
run "$st" SPEC_COMPONENTS=databridge > "$TMP/retargeted-2.log" 2>&1 || { red "FAIL: a second run fails"; sed 's/^/  /' "$TMP/retargeted-2.log"; exit 1; }
check "$st" "$TMP/retargeted-2.log" "reissued: a second run keeps it" '
  first = JSON.parse(File.read(ARGV.fetch(0).sub(".json", "-1.json")))
  abort "wrote again: #{log - first["log"]}" unless log == first["log"]'

# The keys the keygen hooks minted: the private key is adopted from the hook's
# Secret, and the public half derived from it is byte-identical to what the hook
# stored, so TrustGate keeps verifying every token the app signs.
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$TMP/m2m.pem" 2>/dev/null
openssl pkey -in "$TMP/m2m.pem" -pubout -out "$TMP/m2m.pub" 2>/dev/null
KEY_SPEC='[{"key":"AGENTGATEWAY_M2M_PRIVATE_KEY","type":"rsa-pkcs8","bits":2048,"adopt":[["agentgateway-m2m-keys","AGENTGATEWAY_M2M_PRIVATE_KEY"]]},{"key":"ADMIN_M2M_PUBLIC_KEYS","type":"public-key","source":"AGENTGATEWAY_M2M_PRIVATE_KEY"}]'
key_state() {  # file [with-hook]
  local hook=''
  # As the hook wrote them: the private PEM, and base64 of the public PEM, each
  # with its trailing newline.
  [ "${2:-}" = with-hook ] && hook="\"agentgateway-m2m-keys\": {\"metadata\": {}, \"data\": {\"AGENTGATEWAY_M2M_PRIVATE_KEY\": \"$(base64 < "$TMP/m2m.pem" | tr -d '\n')\", \"ADMIN_M2M_PUBLIC_KEYS\": \"$(b64 "$(base64 < "$TMP/m2m.pub" | tr -d '\n')")\"}}"
  printf '{"configmaps": {"neuraltrust-generator-spec-platform": {"metadata": {"labels": {"neuraltrust.ai/generator-spec": "2"}}, "data": {"spec.json": %s}}}, "secrets": {%s}}' \
    "$(ruby -rjson -e 'print JSON.generate(ARGV[0])' "$KEY_SPEC")" "$hook" > "$1"
}
st="$TMP/state-keys.json"
key_state "$st" with-hook
run "$st" > "$TMP/keys.log" 2>&1 || { red "FAIL: the generator fails adopting the keygen pair"; sed 's/^/  /' "$TMP/keys.log"; exit 1; }
check "$st" "$TMP/keys.log" "keygen pair: the private key is adopted, the public half matches the hook's" '
  hook = sec.("agentgateway-m2m-keys")["data"]
  abort "private key not adopted" unless val.("platform-secrets", "AGENTGATEWAY_M2M_PRIVATE_KEY") == Base64.decode64(hook["AGENTGATEWAY_M2M_PRIVATE_KEY"])
  abort "public half differs from the hook" unless val.("platform-secrets", "ADMIN_M2M_PUBLIC_KEYS") == Base64.decode64(hook["ADMIN_M2M_PUBLIC_KEYS"])'
st="$TMP/state-keys-fresh.json"
key_state "$st"
run "$st" > "$TMP/keys-fresh.log" 2>&1 || { red "FAIL: the generator fails minting the pair"; sed 's/^/  /' "$TMP/keys-fresh.log"; exit 1; }
check "$st" "$TMP/keys-fresh.log" "fresh install: a 2048-bit PKCS#8 pair whose halves match" '
  priv = val.("platform-secrets", "AGENTGATEWAY_M2M_PRIVATE_KEY").to_s
  abort "not PKCS#8" unless priv.start_with?("-----BEGIN PRIVATE KEY-----")
  File.write(ARGV.fetch(0) + ".pem", priv)
  want = Base64.strict_encode64(IO.popen(["openssl", "pkey", "-in", ARGV.fetch(0) + ".pem", "-pubout"], &:read))
  abort "the halves do not match" unless val.("platform-secrets", "ADMIN_M2M_PUBLIC_KEYS") == want
  bits = IO.popen(["openssl", "pkey", "-in", ARGV.fetch(0) + ".pem", "-noout", "-text"], &:read)[/(\d+) bit/, 1]
  abort "#{bits} bits" unless bits == "2048"'
