#!/usr/bin/env bash
# Render scenarios 20. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

blue "==> Scenario 20: the control-plane Postgres password lives in an operator Secret"
# The point of the hook is that a managed-external values file can hold no
# credential at all, so the assertions are about absence: no password and no
# composed connection string anywhere in the render, and every consumer pointed
# at the operator's Secret instead.
out20="$TMP/scenario-pg-password-secret.yaml"
render_default "$out20" \
  --set global.deploymentMode=external \
  --set global.postgresql.deploy=false \
  --set global.postgresql.host=pg.example.com \
  --set global.postgresql.passwordSecret.name=postgres-roles \
  --set global.postgresql.passwordSecret.key=CONTROL_PLANE \
  --set 'data-plane-api.dataPlane.components.api.database.backend=postgres'

# SENSIBLE_PG_DSN is not listed here: external omits it whether or not the hook
# is set (line 683 covers that), so asserting it again would pass either way and
# read as coverage the hook does not actually have.
for absent in POSTGRES_PASSWORD POSTGRES_PRISMA_URL; do
  assert_secret_key "$out20" postgresql-secrets absent "$absent" \
    "passwordSecret: postgresql-secrets omits ${absent}"
done
for present in POSTGRES_HOST POSTGRES_PORT POSTGRES_USER POSTGRES_DB POSTGRES_SSLMODE; do
  assert_secret_key "$out20" postgresql-secrets present "$present" \
    "passwordSecret: postgresql-secrets still stores ${present}"
done

# Every reader of the control-plane role has to follow the password, including
# the init container that runs the migrations and data-plane-api when it is on
# Postgres. One of them left behind would be a crash-loop on first install.
password_refs() {
  ruby -ryaml -e '
    Encoding.default_external = Encoding::UTF_8
    docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
    docs.each do |doc|
      next unless doc["kind"] == "Deployment"
      name = doc.dig("metadata", "name")
      spec = doc.dig("spec", "template", "spec") || {}
      (spec["initContainers"].to_a + spec["containers"].to_a).each do |c|
        (c["env"] || []).each do |e|
          next unless e["name"] == "POSTGRES_PASSWORD"
          ref = e.dig("valueFrom", "secretKeyRef") || {}
          puts "#{name}/#{c["name"]}=#{ref["name"]}:#{ref["key"]}"
        end
      end
    end
  ' "$1" | sort
}
got20="$(password_refs "$out20" | tr '\n' ' ' | sed 's/ $//')"
expected20='control-plane-api/control-plane-api=postgres-roles:CONTROL_PLANE control-plane-app/app=postgres-roles:CONTROL_PLANE control-plane-app/init-db=postgres-roles:CONTROL_PLANE data-plane-api/api=postgres-roles:CONTROL_PLANE data-plane-api/postgres-migrations=postgres-roles:CONTROL_PLANE'
if [[ "$got20" != "$expected20" ]]; then
  red "FAIL: passwordSecret: every control-plane Postgres reader follows the operator Secret"
  red "  expected: $expected20"
  red "  got:      $got20"
  exit 1
fi
green "ok  - passwordSecret: every control-plane Postgres reader follows the operator Secret"

# A reference the operator wrote by hand is hard, so a typo in passwordSecret.key
# stops the pod with CreateContainerConfigError instead of quietly connecting
# without a password and surfacing as an authentication failure.
if ruby -ryaml -e '
  docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
  bad = docs.flat_map do |doc|
    next [] unless doc["kind"] == "Deployment"
    spec = doc.dig("spec", "template", "spec") || {}
    (spec["initContainers"].to_a + spec["containers"].to_a).flat_map do |c|
      (c["env"] || []).select do |e|
        e["name"] == "POSTGRES_PASSWORD" &&
          e.dig("valueFrom", "secretKeyRef", "name") == "postgres-roles" &&
          e.dig("valueFrom", "secretKeyRef", "optional")
      end.map { "#{doc.dig("metadata", "name")}/#{c["name"]}" }
    end
  end
  abort(bad.join(" ")) unless bad.empty?
' "$out20"; then
  green "ok  - passwordSecret: the operator's own reference is required, not optional"
else
  red "FAIL: passwordSecret: the operator's own reference is required, not optional"
  exit 1
fi

# The migration step goes through Prisma's CLI, which reads a URL and nothing
# else, so the init container has to build one when the Secret carries none.
assert_contains "$out20" 'node scripts/postgres-password-url.mjs' \
  "passwordSecret: the init container builds the Prisma URL from the parts"
assert_contains "$out20" 'name: POSTGRES_CONNECTION_LIMIT'$'\n''          value: "15"' \
  "passwordSecret: the app receives the pool size the chart used to bake into the URL"

# Nothing may compose a connection string out of a password the chart cannot
# read — an empty credential in a DSN is a silent authentication failure.
assert_not_contains "$out20" 'postgresql://[^"]*:[^"@]*@pg\.example\.com' \
  "passwordSecret: no rendered DSN carries control-plane credentials"

# The default path keeps composing, so existing installs see no change.
out20def="$TMP/scenario-pg-password-default.yaml"
render_default "$out20def" --set global.deploymentMode=external
for present in POSTGRES_PASSWORD POSTGRES_PRISMA_URL; do
  assert_secret_key "$out20def" postgresql-secrets present "$present" \
    "no passwordSecret: postgresql-secrets still stores ${present}"
done

# Guardrails. Each of these is a configuration that renders happily and then
# fails at runtime, so they have to fail at render instead — and for the stated
# reason, or the guard could be replaced by an unrelated error and still pass.
assert_render_fails_with \
  "global.postgresql.passwordSecret.name and global.postgresql.password are mutually exclusive" \
  "passwordSecret and an inline password are mutually exclusive" \
  --set global.deploymentMode=external \
  --set global.postgresql.deploy=false \
  --set global.postgresql.host=pg.example.com \
  --set global.postgresql.passwordSecret.name=postgres-roles \
  --set global.postgresql.password=inline
assert_render_fails_with \
  "control-plane-api.controlPlane.components.postgresql.secrets.password are mutually exclusive" \
  "passwordSecret and the control-plane-api overlay password are mutually exclusive" \
  --set global.deploymentMode=external \
  --set global.postgresql.deploy=false \
  --set global.postgresql.host=pg.example.com \
  --set global.postgresql.passwordSecret.name=postgres-roles \
  --set 'control-plane-api.controlPlane.components.postgresql.secrets.password=inline'
assert_render_fails_with \
  "global.postgresql.passwordSecret.name and global.postgresql.existingSecret.name are mutually exclusive" \
  "passwordSecret and existingSecret are mutually exclusive" \
  --set global.deploymentMode=external \
  --set global.postgresql.deploy=false \
  --set global.postgresql.host=pg.example.com \
  --set global.postgresql.passwordSecret.name=postgres-roles \
  --set global.postgresql.existingSecret.name=whole-secret
# Hybrid no longer composes SENSIBLE_PG_DSN, so passwordSecret is allowed there
# too. The password must still follow the operator Secret.
out20hyb="$TMP/scenario-pg-password-secret-hybrid.yaml"
render_default "$out20hyb" \
  --set global.postgresql.deploy=false \
  --set global.postgresql.host=pg.example.com \
  --set global.postgresql.passwordSecret.name=postgres-roles \
  --set global.postgresql.passwordSecret.key=CONTROL_PLANE
assert_secret_key "$out20hyb" postgresql-secrets absent POSTGRES_PASSWORD \
  "hybrid passwordSecret: postgresql-secrets omits POSTGRES_PASSWORD"
assert_secret_key "$out20hyb" postgresql-secrets absent SENSIBLE_PG_DSN \
  "hybrid passwordSecret: postgresql-secrets omits SENSIBLE_PG_DSN"
assert_contains "$out20hyb" 'name: DB_PASSWORD'$'\n''          valueFrom:'$'\n''            secretKeyRef:'$'\n''              name: "postgres-roles"'$'\n''              key: "CONTROL_PLANE"' \
  "hybrid passwordSecret: gateway DB_PASSWORD follows the operator Secret"
assert_contains "$out20hyb" 'name: POSTGRES_PASSWORD'$'\n''          valueFrom:'$'\n''            secretKeyRef:'$'\n''              name: "postgres-roles"'$'\n''              key: "CONTROL_PLANE"' \
  "hybrid passwordSecret: DataAgent POSTGRES_PASSWORD follows the operator Secret"
assert_render_fails_with \
  "global.postgresql.passwordSecret requires global.postgresql.deploy=false" \
  "passwordSecret is rejected while the chart runs its own PostgreSQL" \
  --set global.deploymentMode=external \
  --set global.postgresql.passwordSecret.name=postgres-roles

# IAM has no static password to redirect, so the hook is ignored rather than
# rejected — the same way the per-service credential hooks behave.
out20iam="$TMP/scenario-pg-password-iam.yaml"
render_default "$out20iam" \
  --set global.deploymentMode=external \
  --set global.postgresql.deploy=false \
  --set global.postgresql.host=pg.example.com \
  --set global.postgresql.authMode=iam \
  --set global.postgresql.passwordSecret.name=postgres-roles \
  --set global.postgresql.passwordSecret.key=CONTROL_PLANE
assert_not_contains "$out20iam" 'postgres-roles' \
  "passwordSecret: IAM auth ignores the hook entirely"

# The chart cannot omit keys from a Secret it does not write, so the protection
# has to live in the env entries. Both emitters carry the same condition, and
# postgresql/secrets.yaml is the copy this exercises.
out20keep="$TMP/scenario-pg-password-preserved.yaml"
render_default "$out20keep" \
  --set global.deploymentMode=external \
  --set global.autoGenerateSecrets=false \
  --set global.preserveExistingSecrets=true \
  --set global.postgresql.deploy=false \
  --set global.postgresql.host=pg.example.com \
  --set global.postgresql.passwordSecret.name=postgres-roles \
  --set global.postgresql.passwordSecret.key=CONTROL_PLANE
assert_not_contains "$out20keep" 'key: POSTGRES_PRISMA_URL' \
  "passwordSecret: a preserved Secret cannot smuggle a stale connection string back in"

# ---------------------------------------------------------------------------
# port + probe parity against service k8s overlays / health routes.
# A wrong readiness path marks Ready while broken; a missing startupProbe
# CrashLoops migration-bound boots (TrustGate admin).
# ---------------------------------------------------------------------------
blue "==> port and probe parity"
assert_workload_parity() {
  local file="$1" deploy="$2" container="$3"
  local expect_port="$4" ready_path="$5" live_path="$6" start_path="$7"
  ruby -ryaml -e '
    docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
    deploy, cname, port, ready, live, start = ARGV[1], ARGV[2], ARGV[3].to_i, ARGV[4], ARGV[5], ARGV[6]
    d = docs.find { |x| x["kind"] == "Deployment" && x.dig("metadata", "name") == deploy }
    abort "missing Deployment #{deploy}" if d.nil?
    c = (d.dig("spec", "template", "spec", "containers") || []).find { |x| x["name"] == cname }
    abort "missing container #{cname} on #{deploy}" if c.nil?
    ports = (c["ports"] || []).map { |p| p["containerPort"].to_i }
    abort "#{deploy}/#{cname}: expected containerPort #{port}, got #{ports.inspect}" unless ports.include?(port)
    %w[readinessProbe livenessProbe startupProbe].each do |probe|
      abort "#{deploy}/#{cname}: missing #{probe}" if c[probe].nil?
    end
    got_ready = c.dig("readinessProbe", "httpGet", "path")
    got_live  = c.dig("livenessProbe", "httpGet", "path")
    got_start = c.dig("startupProbe", "httpGet", "path")
    abort "#{deploy}: readiness #{got_ready.inspect} != #{ready.inspect}" unless got_ready == ready
    abort "#{deploy}: liveness #{got_live.inspect} != #{live.inspect}" unless got_live == live
    abort "#{deploy}: startup #{got_start.inspect} != #{start.inspect}" unless got_start == start
  ' "$file" "$deploy" "$container" "$expect_port" "$ready_path" "$live_path" "$start_path"
  green "ok  - ${deploy}: port ${expect_port}, ready=${ready_path} live=${live_path} start=${start_path}"
}

out322ext="$TMP/scenario-aut322-external.yaml"
render_default "$out322ext" \
  --set global.deploymentMode=external
assert_workload_parity "$out322ext" agentgateway-admin admin 8080 /readyz /healthz /healthz
assert_workload_parity "$out322ext" agentgateway-proxy proxy 8081 /readyz /healthz /healthz
assert_workload_parity "$out322ext" agentgateway-mcp mcp 8082 /readyz /healthz /healthz
assert_workload_parity "$out322ext" trustguard-control-plane control-plane 8080 /readyz /healthz /healthz
assert_workload_parity "$out322ext" trustguard-data-plane data-plane 8081 /readyz /healthz /healthz
assert_workload_parity "$out322ext" data-plane-api api 8000 /health/ready /health /health

out322hyb="$TMP/scenario-aut322-hybrid.yaml"
render_default "$out322hyb"
# Primary TrustGate DataAgent is named `dataagent`; TrustGuard's slice is
# `dataagent-trustguard` (see charts/dataagent fullname helpers).
for da in dataagent dataagent-trustguard; do
  assert_workload_parity "$out322hyb" "$da" dataagent 8080 /readyz /healthz /healthz
done

# ---------------------------------------------------------------------------
# create-secrets.sh renders the chart to learn what a pre-provisioned install
# reads, so these test what it produces rather than how. Every reference in a
# preserveExistingSecrets render must come out with a value or be reported as one
# only the operator can supply: a key it silently drops is optional in the pod
# spec, so the install starts and fails later at runtime.
# ---------------------------------------------------------------------------
blue "create-secrets.sh: every Secret a pre-provisioned install reads"
cs_check() {  # label, output json, stderr, preserve-mode render
  ruby -ryaml -rjson -e '
    out = JSON.parse(File.read(ARGV[0])); err = File.read(ARGV[1])
    docs = YAML.load_stream(File.read(ARGV[2])).compact
    hooked = docs.select { |d| d.dig("metadata", "annotations", "helm.sh/hook") }
    minted = []
    walk_env = ->(o) { case o
      when Hash then (o["env"] || []).each { |e| minted << e["value"] if e.is_a?(Hash) && e["value"] }; o.each_value { |v| walk_env.(v) }
      when Array then o.each { |v| walk_env.(v) } end }
    hooked.each { |d| walk_env.(d) }
    refs = []
    walk = ->(o) { case o
      when Hash
        r = o["secretKeyRef"]; refs << [r["name"], r["key"]] if r.is_a?(Hash)
        o.each_value { |v| walk.(v) }
      when Array then o.each { |v| walk.(v) } end }
    (docs - hooked).each { |d| walk.(d) }
    lost = refs.uniq.reject { |n, k| minted.include?(n) || out.dig(n, k) || err.include?("#{n}/#{k}") }
    abort "not emitted and not reported: #{lost.map { |n, k| "#{n}/#{k}" }.join(", ")}" unless lost.empty?
    reported = err.scan(%r{^  (\S+/\S+)$}).flatten
    placeheld = out.flat_map { |n, kv| kv.select { |_, v| v == "REPLACE_ME" }.keys.map { |k| "#{n}/#{k}" } }
    abort "REPLACE_ME not reported: #{(placeheld - reported).join(", ")}" unless (placeheld - reported).empty?
  ' "$2" "$3" "$4"
}
cs_render() {  # out json, err, preserve render, values args...
  local json="$1" err="$2" pres="$3"; shift 3
  bash create-secrets.sh print -o json --chart "$CHART_DIR" --namespace neuraltrust "$@" > "$json" 2> "$err" || {
    red "FAIL - create-secrets.sh print $*"; cat "$err"; exit 1; }
  helm template test "$CHART_DIR" --namespace neuraltrust "$@" \
    --set global.autoGenerateSecrets=false --set global.preserveExistingSecrets=true > "$pres"
}

cs_ext="$TMP/cs-external.json"
cs_render "$cs_ext" "$TMP/cs-external.err" "$TMP/cs-external-preserve.yaml" \
  -f "$CHART_DIR/values-required.yaml" -f "$CHART_DIR/values-external.yaml.example"
if ! result="$(cs_check external "$cs_ext" "$TMP/cs-external.err" "$TMP/cs-external-preserve.yaml" 2>&1)"; then
  red "FAIL - create-secrets.sh (external): $result"; exit 1
fi
green "ok  - create-secrets.sh (external): every referenced key is emitted or reported"

# Values hold the shape the chart would have generated, and pairs that must match do.
if ! result="$(ruby -rjson -ropen3 -e '
  out = JSON.parse(File.read(ARGV[0]))
  cp = out.fetch("control-plane-secrets")
  abort "AUTH_SECRET and NEXTAUTH_SECRET differ" unless cp["AUTH_SECRET"] && cp["AUTH_SECRET"] == cp["NEXTAUTH_SECRET"]
  pg = out.fetch("postgresql-secrets")
  %w[POSTGRES_SSLMODE POSTGRES_LOGIN POSTGRES_AUTH_MODE POSTGRES_CONNECTION_TYPE].each { |k| abort "postgresql-secrets lacks #{k}" unless pg.key?(k) }
  %w[DATABASE_URL SENSIBLE_PG_DSN].each { |k| abort "postgresql-secrets carries retired #{k}" if pg.key?(k) }
  abort "POSTGRES_PRISMA_URL does not carry POSTGRES_PASSWORD" unless pg["POSTGRES_PRISMA_URL"].to_s.include?(pg["POSTGRES_PASSWORD"].to_s)
  _, st = Open3.capture2e("openssl", "rsa", "-noout", "-check", stdin_data: out.dig("agentgateway-secrets", "STS_SIGNING_KEY").to_s)
  abort "STS_SIGNING_KEY is not a parseable RSA key" unless st.success?
  tls = out.fetch("trustguard-configsync-tls")
  File.write(ARGV[1] + ".ca", tls["ca.crt"]); File.write(ARGV[1] + ".crt", tls["tls.crt"])
  o, st = Open3.capture2e("openssl", "verify", "-CAfile", ARGV[1] + ".ca", ARGV[1] + ".crt")
  abort "configsync tls.crt does not verify against ca.crt: #{o}" unless st.success?
' "$cs_ext" "$TMP/cs-tls" 2>&1)"; then
  red "FAIL - create-secrets.sh (external) values: $result"; exit 1
fi
green "ok  - create-secrets.sh (external): aliases match, Postgres family canonical, PEMs and TLS chain valid"

# Hybrid preserve renders only with global.postgresql.existingSecret named: the
# DataAgent readiness gate otherwise reads the cluster.
cs_hyb="$TMP/cs-hybrid.json"
cs_render "$cs_hyb" "$TMP/cs-hybrid.err" "$TMP/cs-hybrid-preserve.yaml" \
  -f "$CHART_DIR/values-required.yaml" "${CLICKSTACK_DEFAULT_ARGS[@]}" \
  --set global.postgresql.existingSecret.name=postgresql-secrets
if ! result="$(cs_check hybrid "$cs_hyb" "$TMP/cs-hybrid.err" "$TMP/cs-hybrid-preserve.yaml" 2>&1)"; then
  red "FAIL - create-secrets.sh (hybrid): $result"; exit 1
fi
for cs in agentgateway-config-sync trustguard-config-sync; do
  lkg="$(CS="$cs" yq -r '.[strenv(CS)].CONFIG_SYNC_LKG_KEY // ""' "$cs_hyb")"
  bytes="$(printf '%s' "$lkg" | openssl base64 -d -A 2>/dev/null | wc -c | tr -d ' ')"
  if [ "$bytes" != "32" ]; then
    red "FAIL - create-secrets.sh (hybrid): $cs CONFIG_SYNC_LKG_KEY decodes to ${bytes:-0} bytes, want 32 (AES-256)"; exit 1
  fi
  if [ "$(CS="$cs" yq -r '.[strenv(CS)].CONFIG_SYNC_TOKEN // ""' "$cs_hyb")" != "REPLACE_ME" ]; then
    red "FAIL - create-secrets.sh (hybrid): $cs CONFIG_SYNC_TOKEN must be left to the operator"; exit 1
  fi
done
green "ok  - create-secrets.sh (hybrid): 32-byte LKG keys generated, console tokens left to the operator"

# ---------------------------------------------------------------------------
# In-cluster secrets generator. `helm template` (ArgoCD, Flux) cannot lookup, so
# any value the chart generates while rendering rotates on every render. External
# installs must therefore render byte-identical output twice, and every reference
# into the generated Secret must name a key some component's spec generates.
# ---------------------------------------------------------------------------
blue "secrets generator: external renders are stable and fully specified"
gen_check() {  # render file
  ruby -ryaml -rjson -e '
    docs = YAML.load_stream(File.read(ARGV[0])).compact.select { |d| d.is_a?(Hash) }
    gen = "neuraltrust-generated"
    specs = docs.select { |d| d["kind"] == "ConfigMap" && d.dig("metadata", "name").to_s.start_with?("neuraltrust-generator-spec-") }
    abort "no generator spec rendered" if specs.empty?
    entries = specs.flat_map { |c| JSON.parse(c.dig("data", "spec.json")) }
    scalar = entries.reject { |e| e["type"] == "tls" }.map { |e| e["key"] }
    tls = entries.select { |e| e["type"] == "tls" }.map { |e| e["secret"] }
    role = docs.find { |d| d["kind"] == "Role" && d.dig("metadata", "name").to_s.end_with?("secrets-generator") }
    abort "generator Role not rendered" unless role
    readable = role["rules"].select { |r| r["resources"] == ["secrets"] && r["verbs"].include?("get") }.flat_map { |r| r["resourceNames"] || [] }
    specs_readable = role["rules"].select { |r| r["resources"] == ["configmaps"] }.flat_map { |r| r["resourceNames"] || [] }
    specs.each { |c| n = c.dig("metadata", "name"); abort "#{n} is not readable by the generator Role" unless specs_readable.include?(n) }
    entries.each do |e|
      (e["adopt"] || []).each { |src| abort "#{e["key"] || e["secret"]} adopts from #{src[0]}, which the Role cannot read" unless readable.include?(src[0]) }
    end
    refs = []
    walk = ->(o) { case o
      when Hash
        refs << o["secretKeyRef"] if o["secretKeyRef"].is_a?(Hash)
        refs << { "name" => o["secretName"] } if o["secretName"].is_a?(String)
        o.each_value { |v| walk.(v) }
      when Array then o.each { |v| walk.(v) } end }
    docs.reject { |d| d.dig("metadata", "annotations", "helm.sh/hook") }.each { |d| walk.(d) }
    refs.each do |r|
      if r["name"] == gen
        abort "#{gen}/#{r["key"]} is referenced but no spec generates it" unless scalar.include?(r["key"])
      elsif r["name"].to_s.start_with?("neuraltrust-generated-")
        abort "#{r["name"]} is mounted but no spec issues it" unless tls.include?(r["name"])
      end
    end
    abort "a Secret with a generated value is still rendered: #{docs.select { |d| d["kind"] == "Secret" && d.dig("metadata", "name") == "platform-secrets" }.size}" if docs.any? { |d| d["kind"] == "Secret" && d.dig("metadata", "name") == "platform-secrets" }
  ' "$1"
}
gen_shapes=(
  "external|-f $CHART_DIR/values-required.yaml -f $CHART_DIR/values-external.yaml.example"
  "external-trustguard-only|-f $CHART_DIR/values-required.yaml -f $CHART_DIR/values-external.yaml.example -f $CHART_DIR/values-external-trustguard-only.yaml.example"
  "external-managed|-f $CHART_DIR/values-managed-datastores.yaml.example --set global.autoGenerateSecrets=true --set global.preserveExistingSecrets=false"
  "external-observability|-f $CHART_DIR/values-required.yaml -f $CHART_DIR/values-external.yaml.example -f $CHART_DIR/values-observability-self-hosted.yaml.example"
)
for shape in "${gen_shapes[@]}"; do
  label="${shape%%|*}"
  read -r -a gargs <<< "${shape#*|}"
  helm template test "$CHART_DIR" --namespace neuraltrust "${gargs[@]}" > "$TMP/gen-$label-1.yaml"
  helm template test "$CHART_DIR" --namespace neuraltrust "${gargs[@]}" > "$TMP/gen-$label-2.yaml"
  if ! cmp -s "$TMP/gen-$label-1.yaml" "$TMP/gen-$label-2.yaml"; then
    red "FAIL - secrets generator ($label): two renders differ, so ArgoCD would rotate these:"
    diff "$TMP/gen-$label-1.yaml" "$TMP/gen-$label-2.yaml" | grep '^<' | head -10
    exit 1
  fi
  if ! result="$(gen_check "$TMP/gen-$label-1.yaml" 2>&1)"; then
    red "FAIL - secrets generator ($label): $result"; exit 1
  fi
done
green "ok  - secrets generator: ${#gen_shapes[@]} external shapes render byte-identical, every generated ref has a spec, every adoption is readable"

# The realign starts PostgreSQL itself, before the image's entrypoint has put
# PGDATA back to 0700; fsGroup leaves it group-writable on GKE and other CSI
# volumes, and pg_ctl then refuses to start, so the passwords never realign.
ruby -ryaml -e '
  docs = YAML.load_stream(File.read(ARGV[0])).compact.select { |d| d.is_a?(Hash) }
  pg = docs.find { |d| d["kind"] == "Deployment" && d.dig("metadata", "name") == "control-plane-postgresql" }
  abort "in-cluster PostgreSQL not rendered" unless pg
  init = (pg.dig("spec", "template", "spec", "initContainers") || []).find { |c| c["name"] == "realign-passwords" }
  abort "realign-passwords initContainer not rendered" unless init
  script = init["command"].last
  chmod = script.index(%q{chmod 00700 "$PGDATA"})
  start = script.index("pg_ctl -D")
  abort "realign does not restore PGDATA to 0700 before pg_ctl" unless chmod && start && chmod < start
' "$TMP/gen-external-1.yaml" || { red "FAIL: realign-passwords cannot start PostgreSQL on an fsGroup volume"; exit 1; }
green "ok  - realign-passwords restores PGDATA to 0700 before starting PostgreSQL"

# Off: the opt-out, preserve mode and hybrid keep the render-time Secrets and get no Job.
for off in "opt-out|--set global.secrets.generator.enabled=false" "preserve|--set global.preserveExistingSecrets=true --set global.autoGenerateSecrets=false"; do
  label="${off%%|*}"
  read -r -a oargs <<< "${off#*|}"
  helm template test "$CHART_DIR" --namespace neuraltrust -f "$CHART_DIR/values-required.yaml" -f "$CHART_DIR/values-external.yaml.example" "${oargs[@]}" > "$TMP/gen-off-$label.yaml"
  assert_not_contains "$TMP/gen-off-$label.yaml" 'neuraltrust-generator-spec-' "secrets generator ($label): no generator spec"
  assert_not_contains "$TMP/gen-off-$label.yaml" 'name: neuraltrust-generated' "secrets generator ($label): nothing reads the generated Secret"
done
render_default "$TMP/gen-off-hybrid.yaml" --set global.secrets.generator.enabled=true
assert_not_contains "$TMP/gen-off-hybrid.yaml" 'neuraltrust-generator-spec-' "secrets generator (hybrid): not active yet"

# auto (the default) leaves a platform already deployed with Helm exactly as it
# was: a `helm upgrade` of a release the generator never ran for keeps generating
# while rendering. Without a cluster `lookup` finds nothing, which is that case.
helm template test "$CHART_DIR" --namespace neuraltrust --is-upgrade -f "$CHART_DIR/values-required.yaml" -f "$CHART_DIR/values-external.yaml.example" > "$TMP/gen-upgrade-auto.yaml"
assert_not_contains "$TMP/gen-upgrade-auto.yaml" 'neuraltrust-generator-spec-' "secrets generator (auto, helm upgrade of an existing release): stays off"
assert_contains "$TMP/gen-upgrade-auto.yaml" 'name: platform-secrets' "secrets generator (auto, helm upgrade of an existing release): platform-secrets still rendered"
helm template test "$CHART_DIR" --namespace neuraltrust --is-upgrade -f "$CHART_DIR/values-required.yaml" -f "$CHART_DIR/values-external.yaml.example" --set global.secrets.generator.enabled=true > "$TMP/gen-upgrade-on.yaml"
assert_contains "$TMP/gen-upgrade-on.yaml" 'neuraltrust-generator-spec-platform' "secrets generator (true, helm upgrade): an existing release can opt in"
