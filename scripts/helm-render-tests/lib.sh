#!/usr/bin/env bash
# scripts/helm-render-tests/lib.sh
#
# Setup and assertion helpers shared by the render scenarios in this
# directory. Each scenario file sources it; scripts/test-helm-render.sh runs
# the files and owns the one-time dependency build and lint.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

HELM_SUITE="${HELM_SUITE:-full}"
case "$HELM_SUITE" in
  full|compat) ;;
  *)
    printf '\033[31m%s\033[0m\n' "FAIL: HELM_SUITE must be full or compat (got: $HELM_SUITE)"
    exit 1
    ;;
esac
suite_full() { [[ "$HELM_SUITE" == full ]]; }

CHART_DIR="."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
blue()  { printf '\033[34m%s\033[0m\n' "$*"; }
# Used by optional checks that skip. Undefined, this aborted the whole suite
# under set -e on any machine without node, silently skipping later scenarios.
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }

# v2 hybrid always exports product OTLP via the DataAgent egress sidecar and
# enables config-sync by default. Tests supply per-product enrolment +
# config-sync Secret refs. External mode ignores DataAgent (does not render).
CLICKSTACK_DEFAULT_ARGS=(
  --set agentgateway.dataagent.enrolment.existingSecret.name=dataagent-enrolment-trustgate
  --set trustguard.dataagent.enrolment.existingSecret.name=dataagent-enrolment-trustguard
)

# Optional post-render parse check. Off by default — helm template already
# fails on template errors; set VALIDATE_YAML=1 to catch malformed YAML.
validate_yaml() {
  local file="$1"
  [[ "${VALIDATE_YAML:-0}" == "1" ]] || return 0
  ruby -ryaml -e 'YAML.load_stream(File.read(ARGV.fetch(0)))' "$file"
}

# Scenarios below test the render-time contracts, which the in-cluster secrets
# generator's opt-out (and hybrid/saas) still ship, so render_default turns the
# generator off; a scenario can turn it back on. The generator's own contract,
# the default for external installs, has its dedicated fences.
render_default() {
  local out="$1"
  shift
  helm template test "$CHART_DIR" --namespace default -f "$CHART_DIR/values-required.yaml" \
    "${CLICKSTACK_DEFAULT_ARGS[@]}" --set global.secrets.generator.enabled=false "$@" > "$out"
  validate_yaml "$out"
}

# NOTES.txt is not a Kubernetes object. Helm 4 has no `template --notes`;
# client-side install dry-run is the supported way to render it.
render_notes() {
  local out="$1"
  shift
  helm install nt-notes "$CHART_DIR" --dry-run=client --namespace default \
    -f "$CHART_DIR/values-required.yaml" \
    "${CLICKSTACK_DEFAULT_ARGS[@]}" "$@" 2>/dev/null \
    | awk '/^NOTES:/,0' > "$out"
}

# Hybrid product slices start from values-required with every product off
# (values file, so later -f product examples can turn flags back on), then
# apply positive-only product examples. --set must not clear products: Helm
# gives --set higher precedence than -f.
PRODUCTS_OFF_FILE="$TMP/products-off.yaml"
cat > "$PRODUCTS_OFF_FILE" <<'EOF'
global:
  products:
    trustgate: false
    trustguard: false
    dataPlane: false
EOF

HYBRID_NO_PRODUCTS=(
  --set global.products.trustgate=false
  --set global.products.trustguard=false
  --set global.products.dataPlane=false
)

render_product_slice() {
  local out="$1"
  shift
  helm template test "$CHART_DIR" --namespace default \
    -f "$CHART_DIR/values-required.yaml" \
    -f "$PRODUCTS_OFF_FILE" \
    "${CLICKSTACK_DEFAULT_ARGS[@]}" \
    "$@" > "$out"
  validate_yaml "$out"
}

assert_render_fails() {
  local msg="$1"
  shift
  if helm template test "$CHART_DIR" --namespace default -f "$CHART_DIR/values-required.yaml" \
      "${CLICKSTACK_DEFAULT_ARGS[@]}" "$@" >/dev/null 2>&1; then
    red "FAIL: $msg"
    exit 1
  fi
  green "ok  - $msg"
}

# Same, but pinned to the message the guard raises. Without this a guard that was
# deleted or replaced by an unrelated nil-pointer error still "passes".
assert_render_fails_with() {
  local needle="$1" msg="$2"
  shift 2
  local err
  err="$(mktemp)"
  if helm template test "$CHART_DIR" --namespace default -f "$CHART_DIR/values-required.yaml" \
      "${CLICKSTACK_DEFAULT_ARGS[@]}" "$@" >/dev/null 2>"$err"; then
    red "FAIL: $msg"
    red "  the render succeeded; expected it to fail with: $needle"
    rm -f "$err"
    exit 1
  fi
  if ! grep -qF -- "$needle" "$err"; then
    red "FAIL: $msg"
    red "  the render failed for the wrong reason; expected: $needle"
    red "  got: $(tr '\n' ' ' < "$err")"
    rm -f "$err"
    exit 1
  fi
  rm -f "$err"
  green "ok  - $msg"
}

assert_contains() {
  local file="$1" needle="$2" msg="$3"
  if ! grep -qE -- "$needle" "$file"; then
    red "FAIL: $msg"
    red "  expected to find pattern: $needle"
    red "  in: $file"
    exit 1
  fi
  green "ok  - $msg"
}

assert_not_contains() {
  local file="$1" needle="$2" msg="$3"
  if grep -qE -- "$needle" "$file"; then
    red "FAIL: $msg"
    red "  unexpected pattern present: $needle"
    red "  in: $file"
    grep -nE -- "$needle" "$file" | head -3 | while IFS= read -r line; do
      red "  > $line"
    done
    exit 1
  fi
  green "ok  - $msg"
}

# Write the single rendered document whose metadata.name matches, so an
# assertion about one ConfigMap is not satisfied (or broken) by a same-named
# key in a sibling component's ConfigMap.
document_named() {
  local file="$1" name="$2" out="$3"
  awk -v want="$name" '
    /^---$/ { if (keep) exit; buf = ""; keep = 0; next }
    { buf = buf $0 "\n" }
    $0 == "  name: " want { keep = 1 }
    END { if (keep) printf "%s", buf }
  ' "$file" > "$out"
  if [[ ! -s "$out" ]]; then
    red "FAIL: no rendered document named $name in $file"
    exit 1
  fi
}

# document_named returns the FIRST document carrying the name, and helm emits
# manifests in install order, so a Service always precedes the Deployment it
# shares a name with. Use this when the assertion is about one specific kind.
document_named_kind() {
  local file="$1" kind="$2" name="$3" out="$4"
  awk -v want="$name" -v wantkind="kind: $kind" '
    /^---$/ { if (keep && kindok) exit; buf = ""; keep = 0; kindok = 0; next }
    { buf = buf $0 "\n" }
    $0 == wantkind { kindok = 1 }
    $0 == "  name: " want { keep = 1 }
    END { if (keep && kindok) printf "%s", buf }
  ' "$file" > "$out"
  if [[ ! -s "$out" ]]; then
    red "FAIL: no rendered $kind named $name in $file"
    exit 1
  fi
}

assert_occurrences() {
  local file="$1" needle="$2" expected="$3" msg="$4" count
  count="$(grep -cE -- "$needle" "$file" || true)"
  if [[ "$count" -ne "$expected" ]]; then
    red "FAIL: $msg"
    red "  expected $expected occurrences of pattern: $needle"
    red "  found: $count"
    exit 1
  fi
  green "ok  - $msg"
}

# Asserts the exact set of datastore env names a container ends up with, expanding
# envFrom against the Secrets and ConfigMaps in the same render. Comparing the
# effective set is what makes the canonical-family collapse testable: a plain grep
# cannot tell that a pod stopped receiving eleven keys it never read, and would not
# notice an envFrom creeping back in. Expected names may be separated by spaces or
# commas and given in any order.
assert_datastore_env() {
  local file="$1" workload="$2" container="$3" expected="$4" msg="$5" actual
  expected="$(printf '%s' "$expected" | tr ', ' '\n\n' | sed '/^$/d' | sort -u | paste -sd, -)"
  actual="$(ruby -ryaml -e '
    docs = []
    YAML.load_stream(File.read(ARGV.fetch(0), encoding: "UTF-8")) { |d| docs << d if d.is_a?(Hash) }
    src = {}
    docs.each do |d|
      next unless %w[Secret ConfigMap].include?(d["kind"])
      src[[d["kind"], d.dig("metadata", "name")]] = ((d["data"] || {}).keys + (d["stringData"] || {}).keys).uniq
    end
    want_w, want_c = ARGV.fetch(1), ARGV.fetch(2)
    names = nil
    docs.each do |d|
      spec = d.dig("spec", "template", "spec") || d.dig("spec", "jobTemplate", "spec", "template", "spec")
      next unless spec && d.dig("metadata", "name") == want_w
      ((spec["containers"] || []) + (spec["initContainers"] || [])).each do |c|
        next unless c["name"] == want_c
        names = (c["env"] || []).map { |e| e["name"] }
        (c["envFrom"] || []).each do |f|
          if (r = f["secretRef"]) then names.concat(src[["Secret", r["name"]]] || [])
          elsif (r = f["configMapRef"]) then names.concat(src[["ConfigMap", r["name"]]] || [])
          end
        end
      end
    end
    abort "container not found" if names.nil?
    puts names.uniq.grep(/\A(DB_|POSTGRES_|DATABASE_|SENSIBLE_)/).sort.join(",")
  ' "$file" "$workload" "$container")"
  if [[ "$actual" != "$expected" ]]; then
    red "FAIL: $msg"
    red "  expected datastore env: $expected"
    red "  actual datastore env:   $actual"
    exit 1
  fi
  green "ok  - $msg"
}

# Asserts no container injects a Secret wholesale via envFrom. Checked structurally
# rather than by grep: an embedded newline in a grep -E pattern is alternation, not a
# sequence, so a textual version of this passes on unrelated lines.
assert_no_envfrom_secret() {
  local file="$1" secret="$2" msg="$3" hits
  hits="$(ruby -ryaml -e '
    docs = []
    YAML.load_stream(File.read(ARGV.fetch(0), encoding: "UTF-8")) { |d| docs << d if d.is_a?(Hash) }
    want = ARGV.fetch(1)
    out = []
    docs.each do |d|
      spec = d.dig("spec", "template", "spec") || d.dig("spec", "jobTemplate", "spec", "template", "spec")
      next unless spec
      ((spec["containers"] || []) + (spec["initContainers"] || [])).each do |c|
        (c["envFrom"] || []).each do |f|
          out << "#{d["kind"]}/#{d.dig("metadata", "name")}:#{c["name"]}" if f.dig("secretRef", "name") == want
        end
      end
    end
    puts out.join(" ")
  ' "$file" "$secret")"
  if [[ -n "$hits" ]]; then
    red "FAIL: $msg"
    red "  $secret injected wholesale into: $hits"
    exit 1
  fi
  green "ok  - $msg"
}

# Asserts a container's literal env value, or that the variable is absent.
# Scoped to one container so a sibling workload cannot satisfy the assertion.
# Pass the expected value, or the word ABSENT.
assert_env_value() {
  local file="$1" workload="$2" container="$3" name="$4" expected="$5" msg="$6" actual
  if ! actual="$(ruby -ryaml -e '
    docs = []
    YAML.load_stream(File.read(ARGV.fetch(0), encoding: "UTF-8")) { |d| docs << d if d.is_a?(Hash) }
    want_w, want_c, want_n = ARGV.fetch(1), ARGV.fetch(2), ARGV.fetch(3)
    found = nil
    seen = false
    docs.each do |d|
      spec = d.dig("spec", "template", "spec")
      next unless spec && d.dig("metadata", "name") == want_w
      ((spec["containers"] || []) + (spec["initContainers"] || [])).each do |c|
        next unless c["name"] == want_c
        seen = true
        e = (c["env"] || []).find { |x| x["name"] == want_n }
        next unless e
        if e.key?("value")
          found = e["value"].to_s
        elsif (ref = e.dig("valueFrom", "secretKeyRef"))
          found = "secretKeyRef:#{ref["name"]}/#{ref["key"]}"
        elsif (ref = e.dig("valueFrom", "fieldRef"))
          found = "fieldRef:#{ref["fieldPath"]}"
        end
      end
    end
    abort "container #{want_w}/#{want_c} not found" unless seen
    puts(found.nil? ? "ABSENT" : found)
  ' "$file" "$workload" "$container" "$name")"; then
    red "FAIL: $msg"
    exit 1
  fi
  if [[ "$actual" != "$expected" ]]; then
    red "FAIL: $msg"
    red "  $workload/$container $name expected: $expected"
    red "  actual:   $actual"
    exit 1
  fi
  green "ok  - $msg"
}

# The data-plane Postgres schema is applied by the API image itself
# (`python -m src.migrate`), so the initContainer must be that exact image, with
# no psql image, no chart-rendered DDL ConfigMap and no volume to mount it.
assert_pg_migration_runner() {
  local file="$1" label="$2" result
  if ! result="$(ruby -ryaml -e '
    docs = []
    YAML.load_stream(File.read(ARGV.fetch(0), encoding: "UTF-8")) { |d| docs << d if d.is_a?(Hash) }
    d = docs.find { |x| x["kind"] == "Deployment" && x.dig("metadata", "name") == "data-plane-api" }
    abort "no data-plane-api Deployment" unless d
    spec = d.dig("spec", "template", "spec")
    init = (spec["initContainers"] || []).find { |c| c["name"] == "postgres-migrations" }
    abort "no postgres-migrations initContainer" unless init
    api = spec["containers"].find { |c| c["name"] == "api" }
    abort "image #{init["image"]} != api #{api["image"]}" unless init["image"] == api["image"]
    abort "pull policy differs" unless init["imagePullPolicy"] == api["imagePullPolicy"]
    abort "command #{init["command"].inspect}" unless init["command"] == ["python", "-m", "src.migrate"]
    images = ((spec["initContainers"] || []) + spec["containers"]).map { |c| c["image"] }
    abort "psql image still in data-plane-api: #{images.inspect}" if images.any? { |i| i =~ %r{/postgres:} }
    abort "postgres-init-db volume still mounted" if (spec["volumes"] || []).any? { |v| v["name"] == "postgres-init-db" }
    abort "data-plane-postgres-init ConfigMap still rendered" if docs.any? { |x| x["kind"] == "ConfigMap" && x.dig("metadata", "name") == "data-plane-postgres-init" }
    puts "ok"
  ' "$file" 2>&1)"; then
    red "FAIL: $label"
    red "  $result"
    exit 1
  fi
  green "ok  - $label"
}

# Asserts a key is present/absent in a specific Secret. Scoped to one document so
# an unrelated Secret carrying the same key cannot mask a regression.
assert_secret_key() {
  local file="$1" secret="$2" mode="$3" key="$4" label="$5"
  assert_secret_keys "$file" "$secret" "$mode" "$label" "$key"
}

# Batch form: one YAML parse for many keys. Label is used as-is for a single key,
# or as a prefix ("… ${key}") when checking multiple keys.
assert_secret_keys() {
  local file="$1" secret="$2" mode="$3" label="$4"
  shift 4
  local -a keys=("$@")
  [[ ${#keys[@]} -gt 0 ]] || { red "FAIL: assert_secret_keys called with no keys"; exit 1; }
  local result
  if ! result=$(ruby -ryaml -e '
    docs = []
    YAML.load_stream(File.read(ARGV.fetch(0), encoding: "UTF-8")) { |d| docs << d if d.is_a?(Hash) }
    secret, mode = ARGV.fetch(1), ARGV.fetch(2)
    d = docs.find { |x| x["kind"] == "Secret" && x.dig("metadata", "name") == secret }
    abort "#{secret} not rendered" if d.nil?
    data = d["data"] || {}
    ARGV.drop(3).each do |key|
      has = data.key?(key)
      if mode == "present" && !has
        abort "MISSING #{key}"
      elsif mode == "absent" && has
        abort "PRESENT #{key}"
      end
    end
  ' "$file" "$secret" "$mode" "${keys[@]}"); then
    local key="${keys[0]}"
    if [[ ${#keys[@]} -eq 1 ]]; then
      red "FAIL: $label"
    else
      # ruby abort text is on stderr; surface keys from mode mismatch heuristically
      red "FAIL: ${label} (batch ${mode})"
    fi
    if [ "$mode" = present ]; then
      red "  $secret is missing one of: ${keys[*]}"
    else
      red "  $secret unexpectedly carries one of: ${keys[*]}"
    fi
    exit 1
  fi
  if [[ ${#keys[@]} -eq 1 ]]; then
    green "ok  - $label"
  else
    for key in "${keys[@]}"; do
      green "ok  - ${label} ${key}"
    done
  fi
  unset result
}

assert_platform_key() {
  assert_secret_key "$1" platform-secrets "$2" "$3" "$4"
}

assert_platform_keys() {
  local file="$1" mode="$2" label="$3"
  shift 3
  assert_secret_keys "$file" platform-secrets "$mode" "$label" "$@"
}

assert_resource_count() {
  local file="$1" kind="$2" name="$3" expected="$4" msg="$5" count
  count="$(ruby -ryaml -e 'puts YAML.load_stream(File.read(ARGV.fetch(0))).count { |doc| doc.is_a?(Hash) && doc["kind"] == ARGV.fetch(1) && doc.dig("metadata", "name") == ARGV.fetch(2) }' "$file" "$kind" "$name")"
  if [[ "$count" -ne "$expected" ]]; then
    red "FAIL: $msg"
    red "  expected $expected $kind resource(s) named $name; found: $count"
    exit 1
  fi
  green "ok  - $msg"
}

# Cloud-identity datastore overlays shared by the external IAM scenarios (3c,
# 3d) and the firewall Redis cache scenario (22).
gcp_args=(
  --set global.deploymentMode=external
  --set global.postgresql.deploy=false
  --set global.postgresql.host=10.0.0.5
  --set global.postgresql.authMode=iam
  --set global.postgresql.sslMode=require
  --set global.postgresql.user=cp-db@example-project.iam
  --set global.gcpIdentity.method=workload-identity
  --set trustguard.database.user=trustguard-db@example-project.iam
  --set datacore.database.user=datacore-db@example-project.iam
  --set alertengine.database.user=alertengine-db@example-project.iam
)
redis_args=(
  --set global.redis.deploy=false
  --set global.redis.host=10.0.0.6
  --set global.redis.tls=true
  --set global.redis.authMode=iam
  --set global.redis.cluster=true
  --set global.redis.caSecret.name=redis-ca
)

# The subjectAltName extension of a rendered TLS Secret's certificate.
cert_sans() {
  yq -N "select(.kind==\"Secret\" and .metadata.name==\"$2\") | .data.\"tls.crt\"" "$1" \
    | base64 -d 2>/dev/null | openssl x509 -noout -ext subjectAltName 2>/dev/null
}
