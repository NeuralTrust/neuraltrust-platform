#!/usr/bin/env bash
# scripts/test-helm-render.sh
#
# Render the umbrella chart in the representative v2 scenarios and assert
# structural invariants. Runs in CI via
# .github/workflows/helm-render-tests.yml and locally:
#
#   ./scripts/test-helm-render.sh                 # HELM_SUITE=full (default)
#   HELM_SUITE=compat ./scripts/test-helm-render.sh
#
# Suites:
#   full   — all chart-contract scenarios (CI: Helm v4)
#   compat — smoke + OpenShift Routes + fail-closed guards (CI: Helm v3)
#
# v2-only: v1 (TrustGate/Kafka/scheduler) is retired on `main` — its
# absence is asserted here. Historical v1 users stay on the `v1.14.x`
# release line.
#
# Exits non-zero on the first assertion failure.

set -euo pipefail

cd "$(dirname "$0")/.."

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

blue "==> HELM_SUITE=${HELM_SUITE}"

helm dependency build "$CHART_DIR" >/dev/null 2>&1 \
  || helm dependency update "$CHART_DIR" >/dev/null

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

helm lint "$CHART_DIR" -f "$CHART_DIR/values-required.yaml" \
  "${CLICKSTACK_DEFAULT_ARGS[@]}" >/dev/null
green "ok  - helm lint passes"

render_default() {
  local out="$1"
  shift
  helm template test "$CHART_DIR" --namespace default -f "$CHART_DIR/values-required.yaml" \
    "${CLICKSTACK_DEFAULT_ARGS[@]}" "$@" > "$out"
  validate_yaml "$out"
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
      (spec["containers"] || []).each do |c|
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

# ---------------------------------------------------------------------------
# 1. Minimal v2 hybrid — shared PG/Redis + enrolment-backed ClickStack egress
# ---------------------------------------------------------------------------
blue "==> Scenario 1: minimal v2 hybrid (shared PG/Redis + ClickStack egress)"
out1="$TMP/scenario-hybrid-minimal.yaml"
render_default "$out1"

assert_contains "$out1" 'kind: Deployment' \
  "hybrid: at least one Deployment renders"
assert_contains "$out1" 'name: control-plane-postgresql' \
  "hybrid: in-cluster PostgreSQL Deployment/Service"
# Private AR postgres image must default to gcr-secret (same as Redis).
assert_contains "$out1" 'app: control-plane-postgresql'$'\n''    spec:'$'\n''      securityContext:' \
  "hybrid: postgresql pod template present"
assert_contains "$out1" 'runAsNonRoot: true'$'\n''      imagePullSecrets:'$'\n''        - name: gcr-secret' \
  "hybrid: postgresql Deployment defaults imagePullSecrets to gcr-secret"
assert_contains "$out1" 'name: postgresql-secrets' \
  "hybrid: postgresql-secrets rendered"
# postgresql-secrets stores ONE canonical family. The DB_* and DATABASE_* aliases it
# used to store are renamed at each consumption site instead, so storage cannot
# drift from what any single service reads.
assert_secret_keys "$out1" postgresql-secrets present \
  "hybrid: postgresql-secrets stores canonical" \
  POSTGRES_HOST POSTGRES_PORT POSTGRES_USER POSTGRES_PASSWORD \
  POSTGRES_DB POSTGRES_SSLMODE POSTGRES_LOGIN POSTGRES_AUTH_MODE \
  POSTGRES_CONNECTION_TYPE
assert_secret_keys "$out1" postgresql-secrets absent \
  "hybrid: postgresql-secrets no longer stores" \
  DB_HOST DB_PORT DB_USER DB_PASSWORD DB_NAME DB_SSL_MODE \
  DATABASE_AUTH_MODE DATABASE_IAM_AUTH DATABASE_URL SENSIBLE_PG_DSN
# Prisma is the control-plane app's reader and hybrid does not deploy it.
assert_secret_key "$out1" postgresql-secrets absent POSTGRES_PRISMA_URL \
  "hybrid: postgresql-secrets omits the Prisma URL it has no reader for"
# The three Go services read DB_*; POSTGRES_LOGIN is the IAM switch. Telemetry
# falls back to those same DB_* parts (RUN-1086) — no SENSIBLE_PG_DSN.
for wl in agentgateway-proxy:proxy agentgateway-mcp:mcp trustguard-data-plane:data-plane; do
  assert_datastore_env "$out1" "${wl%%:*}" "${wl##*:}" \
    'DB_HOST,DB_NAME,DB_PASSWORD,DB_PORT,DB_SSL_MODE,DB_USER,POSTGRES_LOGIN' \
    "hybrid: ${wl%%:*} receives only the datastore keys it reads"
done
# DataAgent builds its connection from discrete POSTGRES_* parts (RUN-1093).
assert_datastore_env "$out1" dataagent dataagent \
  'POSTGRES_DB,POSTGRES_HOST,POSTGRES_PASSWORD,POSTGRES_PORT,POSTGRES_SSLMODE,POSTGRES_USER' \
  "hybrid: DataAgent receives discrete POSTGRES_* parts"
assert_datastore_env "$out1" dataagent-trustguard dataagent \
  'POSTGRES_DB,POSTGRES_HOST,POSTGRES_PASSWORD,POSTGRES_PORT,POSTGRES_SSLMODE,POSTGRES_USER' \
  "hybrid: TrustGuard DataAgent receives discrete POSTGRES_* parts"
# A wholesale Postgres envFrom creeping back would silently undo the collapse.
assert_no_envfrom_secret "$out1" postgresql-secrets \
  "hybrid: no workload injects postgresql-secrets wholesale"

# Renaming is only safe for a Secret the chart writes. Two modes hand it to the
# operator instead, and both must keep the envFrom passthrough: the chart cannot
# rename keys it does not control, and because these refs are optional a mismatch
# would be silent — DB_SSL_MODE would simply vanish and the gateways would fall
# back to their built-in "disable", turning opportunistic TLS into plaintext.
out1_pg_existing="$TMP/scenario-hybrid-pg-existing.yaml"
render_default "$out1_pg_existing" --set global.postgresql.existingSecret.name=my-pg
assert_not_contains "$out1_pg_existing" 'key: "POSTGRES_SSLMODE"' \
  "hybrid with an operator existingSecret: chart does not rename keys it does not own"
assert_contains "$out1_pg_existing" '- secretRef:'$'\n''            name: "my-pg"' \
  "hybrid with an operator existingSecret: Postgres envFrom passthrough is kept"

# preserveExistingSecrets skips both postgresql-secrets emitters, so the same
# passthrough applies. DataAgent needs its own pre-created Secret in that mode.
out1_pg_preserve="$TMP/scenario-hybrid-pg-preserve.yaml"
render_default "$out1_pg_preserve" \
  --set global.preserveExistingSecrets=true \
  --set agentgateway.dataagent.existingSecret.name=my-da \
  --set trustguard.dataagent.existingSecret.name=my-da2
assert_not_contains "$out1_pg_preserve" 'key: "POSTGRES_SSLMODE"' \
  "hybrid with preserveExistingSecrets: chart does not rename keys it does not own"
assert_contains "$out1_pg_preserve" '- secretRef:'$'\n''            name: "postgresql-secrets"' \
  "hybrid with preserveExistingSecrets: Postgres envFrom passthrough is kept"
assert_contains "$out1" 'name: POSTGRES_SCHEMA'$'\n''          value: "public"' \
  "data-plane PostgreSQL: default schema reaches the runtime"
assert_contains "$out1" 'SET search_path TO public;' \
  "data-plane PostgreSQL: default schema reaches the migration"
assert_contains "$out1" 'CREATE TABLE IF NOT EXISTS tests' \
  "data-plane PostgreSQL: migration uses the configured search path"
assert_not_contains "$out1" 'CREATE SCHEMA IF NOT EXISTS' \
  "data-plane PostgreSQL: migration does not require database CREATE"
assert_contains "$out1" 'name: redis-secrets' \
  "hybrid: redis-secrets rendered"
assert_contains "$out1" 'name: agentgateway-proxy' \
  "hybrid: trustgate (agentgateway) proxy renders"
assert_contains "$out1" 'name: trustguard-data-plane' \
  "hybrid: trustguard data-plane renders"
assert_contains "$out1" 'name: dataagent$' \
  "hybrid: trustgate DataAgent preserves stable name"
assert_contains "$out1" 'name: dataagent-trustguard' \
  "hybrid: trustguard DataAgent renders"
assert_resource_count "$out1" Service dataagent 1 \
  "hybrid: TrustGate DataAgent health Service renders once"
assert_resource_count "$out1" Service dataagent-trustguard 1 \
  "hybrid: TrustGuard DataAgent health Service renders once"
assert_contains "$out1" 'name: data-plane-api' \
  "hybrid: data-plane-api shim renders"
assert_contains "$out1" 'name: clickstack-egress-collector' \
  "hybrid: local OTLP egress ClusterIP Service renders"
# Exactly one egress Service metadata.name (ConfigMap uses -config suffix).
assert_occurrences "$out1" '^  name: clickstack-egress-collector$' 1 \
  "hybrid: single clickstack-egress-collector Service"
assert_contains "$out1" 'name: clickstack-egress-collector'$'\n''        image:' \
  "hybrid: OTLP egress sidecar on primary DataAgent renders"
assert_contains "$out1" 'name: POSTGRES_HOST'$'\n''          valueFrom:'$'\n''            secretKeyRef:'$'\n''              name: "postgresql-secrets"'$'\n''              key: POSTGRES_HOST' \
  "hybrid: DataAgent reads POSTGRES_HOST from postgresql-secrets"
assert_contains "$out1" 'type: postgres'$'\n' \
  "hybrid: telemetry ConfigMap registers sensible-pg without dsn_env"
assert_not_contains "$out1" 'dsn_env: SENSIBLE_PG_DSN' \
  "hybrid: telemetry ConfigMap no longer names SENSIBLE_PG_DSN"
assert_contains "$out1" 'name: OAUTH_BROKER_ADDR'$'\n''          value: "127.0.0.1:9465"' \
  "hybrid: DataAgent enables loopback OAuth broker for egress sidecar"
assert_contains "$out1" 'token_url: "http://127.0.0.1:9465/oauth/token"' \
  "hybrid: egress sidecar token_url is DataAgent loopback broker"
assert_contains "$out1" 'client_secret: "unused"' \
  "hybrid: egress sidecar uses non-secret oauth2client placeholder"
assert_not_contains "$out1" 'client_secret: ${env:ENROLMENT_TOKEN}' \
  "hybrid: egress sidecar must not read ENROLMENT_TOKEN"
assert_contains "$out1" 'http://clickstack-egress-collector.default.svc.cluster.local:4318/v1/logs' \
  "hybrid: apps OTLP endpoint points at local egress"
# Brackets escaped — assert_contains uses grep -E ([::] is a char class).
assert_contains "$out1" 'endpoint: "\[::\]:4317"' \
  "hybrid: egress OTLP gRPC binds dual-stack ([::]) for IPv6-only clusters"
assert_contains "$out1" 'endpoint: "\[::\]:4318"' \
  "hybrid: egress OTLP HTTP binds dual-stack ([::]) for IPv6-only clusters"
assert_contains "$out1" 'endpoint: "\[::\]:13133"' \
  "hybrid: egress health_check binds dual-stack ([::]) for IPv6-only clusters"
assert_not_contains "$out1" 'name: control-plane-app' \
  "hybrid: control-plane-app must not render (hosted control plane)"
assert_not_contains "$out1" 'name: control-plane-api' \
  "hybrid: control-plane-api must not render (hosted control plane)"
assert_not_contains "$out1" 'OTEL_EXPORTER_OTLP_HEADERS:' \
  "hybrid: apps do not carry remote Authorization headers"
assert_not_contains "$out1" 'TENANT_ID:' \
  "hybrid: DataAgent env omits TENANT_ID when identity comes from enrolment JWT"
assert_not_contains "$out1" 'INSTANCE_ID:' \
  "hybrid: DataAgent env never emits unused INSTANCE_ID"

# ClickStack fail-closed without a fully enabled DataAgent (egress is a sidecar)
blue "==> Scenario 1b: hybrid ClickStack without enrolment must fail (fail-closed)"
assert_render_fails "hybrid without enrolment fails render" \
  --set agentgateway.dataagent.enrolment.existingSecret.name= \
  --set trustguard.dataagent.enrolment.existingSecret.name=

blue "==> Scenario 1b2: legacy clickstack/egress opt-out keys must fail"
assert_render_fails "legacy global.clickstack.enabled=false is rejected" \
  --set global.clickstack.enabled=false
assert_render_fails "legacy global.clickstack.egress.enabled=false is rejected" \
  --set global.clickstack.egress.enabled=false

blue "==> Scenario 1c: product selector rejects invalid keys and types"
assert_render_fails "product selector values must be booleans" \
  --set-string global.products.trustgate=false
if suite_full; then
  assert_render_fails "unknown product selector keys are rejected" \
    --set global.products.unknown=true
fi

# --- full-only: dense config-sync / datastore variants (not Helm-version related)
if suite_full; then

# Config-sync fail-closed (hybrid default-on) and writable LKG storage
blue "==> Scenario 1d: config-sync token references and LKG storage"
assert_render_fails "hybrid config-sync without a token source fails render" \
  --set agentgateway.configSync.existingSecret.name= \
  --set trustguard.configSync.existingSecret.name=
out1d="$TMP/scenario-hybrid-config-sync.yaml"
render_default "$out1d"
assert_contains "$out1d" 'name: "?agentgateway-config-sync"?' \
  "config-sync: TrustGate references its operator-owned token Secret"
assert_contains "$out1d" 'name: "?trustguard-config-sync"?' \
  "config-sync: TrustGuard references its operator-owned token Secret"
assert_not_contains "$out1d" 'key: "?CONFIG_SYNC_LKG_KEY"?' \
  "config-sync: the operator token Secret is not asked for the LKG key"
assert_contains "$out1d" 'CONFIG_SYNC_LKG_KEY: "' \
  "config-sync: the chart-managed Secret generates the LKG key instead"
assert_contains "$out1d" 'mountPath: /var/lib/trustgate' \
  "config-sync: TrustGate LKG path is writable"
assert_contains "$out1d" 'mountPath: /var/lib/trustguard' \
  "config-sync: TrustGuard LKG path is writable"
assert_contains "$out1d" 'name: CONFIG_SYNC_DATA_PLANE_ENABLED'$'\n''          value: "true"' \
  "config-sync: hybrid defaults enable data-plane sync"
assert_render_fails "inline config-sync token fails when auto-generation is disabled" \
  --set global.autoGenerateSecrets=false \
  --set agentgateway.configSync.existingSecret.name= \
  --set agentgateway.configSync.token=inline-test-token \
  --set agentgateway.dataagent.existingSecret.name=dataagent-trustgate-secrets \
  --set trustguard.dataagent.existingSecret.name=dataagent-trustguard-secrets
assert_render_fails "inline config-sync token fails when managed Secrets are preserved" \
  --set global.preserveExistingSecrets=true \
  --set agentgateway.configSync.existingSecret.name= \
  --set agentgateway.configSync.token=inline-test-token
out1e="$TMP/scenario-config-sync-inline-upgrade.yaml"
render_default "$out1e" --is-upgrade \
  --set agentgateway.configSync.existingSecret.name= \
  --set agentgateway.configSync.token=inline-test-token
assert_contains "$out1e" 'name: agentgateway-secrets' \
  "config-sync upgrade: inline token forces managed Secret rendering"
assert_contains "$out1e" 'CONFIG_SYNC_TOKEN: "inline-test-token"' \
  "config-sync upgrade: managed Secret carries the inline token"
assert_contains "$out1e" 'CONFIG_SYNC_LKG_KEY:' \
  "config-sync upgrade: managed Secret carries an LKG encryption key"

# The gate is decided by Secret ownership alone. Renaming the key must not
# resurrect the reference on the owned path, or a rename would quietly demand a
# key from a Secret the operator was told not to put one in.
out1d2="$TMP/scenario-config-sync-custom-lkg-key.yaml"
render_default "$out1d2" \
  --set agentgateway.configSync.existingSecret.lkgKey=MY_LKG_KEY
assert_contains "$out1d2" 'key: "?CONFIG_SYNC_TOKEN"?' \
  "config-sync token-only: the UI-issued token still comes from the operator Secret"
assert_not_contains "$out1d2" 'key: "?MY_LKG_KEY"?' \
  "config-sync token-only: a renamed LKG key is not demanded of the operator Secret either"

# The chart owns no Secret under either opt-out, so the pre-2.6 reference is
# retained rather than leaving the runtime with no key at all. Both halves of
# the conjunct are covered: dropping one would strand the other. Counting the
# occurrences catches a partial regression that leaves only some workloads wired.
out1d3="$TMP/scenario-config-sync-no-autogen.yaml"
render_default "$out1d3" \
  --set global.autoGenerateSecrets=false \
  --set agentgateway.dataagent.existingSecret.name=dataagent-trustgate-secrets \
  --set trustguard.dataagent.existingSecret.name=dataagent-trustguard-secrets
assert_occurrences "$out1d3" 'key: "?CONFIG_SYNC_LKG_KEY"?' 3 \
  "config-sync: without chart Secret generation all three data planes take the LKG key from the operator Secret"
out1d4="$TMP/scenario-config-sync-preserve-existing.yaml"
render_default "$out1d4" \
  --set global.preserveExistingSecrets=true \
  --set agentgateway.dataagent.existingSecret.name=dataagent-trustgate-secrets \
  --set trustguard.dataagent.existingSecret.name=dataagent-trustguard-secrets
assert_occurrences "$out1d4" 'key: "?CONFIG_SYNC_LKG_KEY"?' 3 \
  "config-sync: preserveExistingSecrets also leaves the LKG key to the operator Secret"
# The gate must not read the cluster: a lookup-dependent reference renders one
# way under `helm upgrade` and another under `helm template` or ArgoCD. An
# upgrade render must therefore match the install render exactly.
out1d5="$TMP/scenario-config-sync-upgrade-render.yaml"
render_default "$out1d5" --is-upgrade
assert_not_contains "$out1d5" 'key: "?CONFIG_SYNC_LKG_KEY"?' \
  "config-sync: an upgrade render agrees with the install render on the owned path"

blue "==> Scenario 1e: preserved shared PostgreSQL supports DataAgent"
out1f="$TMP/scenario-preserved-shared-postgres.yaml"
render_default "$out1f" \
  --set global.preserveExistingSecrets=true \
  --set global.postgresql.existingSecret.name=external-postgresql
assert_contains "$out1f" 'name: dataagent$' \
  "preserved Secrets: TrustGate DataAgent still renders"
assert_contains "$out1f" 'name: dataagent-trustguard$' \
  "preserved Secrets: TrustGuard DataAgent still renders"
assert_contains "$out1f" 'name: "?external-postgresql"?' \
  "preserved Secrets: DataAgents reference shared PostgreSQL Secret"
assert_not_contains "$out1f" 'name: dataagent-secrets' \
  "preserved Secrets: no unnecessary per-agent Secret reference"

# ---------------------------------------------------------------------------
# 2. Hybrid with external datastores (existing secrets)
# ---------------------------------------------------------------------------
blue "==> Scenario 2: hybrid with external PG/Redis"
out2="$TMP/scenario-hybrid-external-ds.yaml"
render_default "$out2" \
  --set global.postgresql.deploy=false \
  --set global.postgresql.host=pg.internal.example.com \
  --set global.postgresql.password=external-pg-secret \
  --set data-plane-api.dataPlane.components.api.database.postgresql.schema=tenant_schema \
  --set global.redis.deploy=false \
  --set global.redis.host=redis.internal.example.com \
  --set global.redis.password=external-redis-secret

assert_not_contains "$out2" '^  name: control-plane-postgresql$' \
  "external PG: no in-cluster Postgres Deployment"
# Host is base64-encoded inside postgresql-secrets:
#   $ echo -n pg.internal.example.com | base64 → cGcuaW50ZXJuYWwuZXhhbXBsZS5jb20=
assert_contains "$out2" 'cGcuaW50ZXJuYWwuZXhhbXBsZS5jb20=' \
  "external PG: host reaches templates (base64-encoded in Secret)"
assert_contains "$out2" 'name: POSTGRES_SCHEMA'$'\n''          value: "tenant_schema"' \
  "external PG: configured schema reaches the runtime"
assert_not_contains "$out2" 'CREATE SCHEMA IF NOT EXISTS' \
  "external PG: custom schema does not require database CREATE"
assert_contains "$out2" 'SET search_path TO tenant_schema;' \
  "external PG: configured schema reaches the migration"
assert_contains "$out2" 'CREATE TABLE IF NOT EXISTS tests' \
  "external PG: migration uses the configured search path"
assert_not_contains "$out2" 'SET search_path TO public;' \
  "external PG: migration has no stale default schema"
assert_render_fails "invalid data-plane PostgreSQL schema fails render" \
  --set data-plane-api.dataPlane.components.api.database.postgresql.schema=invalid-schema

# ---------------------------------------------------------------------------
# 2b. autoGenerateSecrets=false fallback still emits postgresql-secrets
# ---------------------------------------------------------------------------
blue "==> Scenario 2b: postgresql-secrets via autoGenerateSecrets=false fallback"
out2b="$TMP/scenario-pg-secrets-fallback.yaml"
# DataAgent reuses the fallback shared PostgreSQL Secret; no per-agent DB Secret.
render_default "$out2b" \
  --set global.autoGenerateSecrets=false \
  --set global.preserveExistingSecrets=false \
  --set global.postgresql.password=fallback-pg-secret

assert_contains "$out2b" 'name: postgresql-secrets' \
  "autoGenerate=false: postgresql-secrets fallback renders"
assert_contains "$out2b" 'ZmFsbGJhY2stcGctc2VjcmV0' \
  "autoGenerate=false: explicit password reaches postgresql-secrets"
assert_not_contains "$out2b" 'SENSIBLE_PG_DSN:' \
  "autoGenerate=false: shared fallback no longer composes SENSIBLE_PG_DSN"
assert_contains "$out2b" 'name: dataagent$' \
  "autoGenerate=false: TrustGate DataAgent reuses shared fallback Secret"
assert_contains "$out2b" 'name: dataagent-trustguard$' \
  "autoGenerate=false: TrustGuard DataAgent reuses shared fallback Secret"
assert_not_contains "$out2b" 'name: dataagent-secrets' \
  "autoGenerate=false: no TrustGate per-agent DB Secret"
assert_not_contains "$out2b" 'name: dataagent-trustguard-secrets' \
  "autoGenerate=false: no TrustGuard per-agent DB Secret"

fi # suite_full (1d–2b)

# ---------------------------------------------------------------------------
# 3. External mode — full on-prem
# ---------------------------------------------------------------------------
blue "==> Scenario 3: external (full on-prem) mode"
out3="$TMP/scenario-external.yaml"
render_default "$out3" --set global.deploymentMode=external

assert_contains "$out3" 'name: control-plane-api' \
  "external: control-plane-api Deployment/Service renders"
assert_contains "$out3" 'name: control-plane-app' \
  "external: control-plane-app Deployment/Service renders"
assert_contains "$out3" 'name: AUTH_EMAIL_FORCE_ENV' \
  "external: AUTH_EMAIL_FORCE_ENV is set on control-plane-app"
assert_contains "$out3" 'name: AUTH_EMAIL_FORCE_ENV'$'\n''          value: "true"' \
  "external: AUTH_EMAIL_FORCE_ENV defaults to true"
assert_contains "$out3" 'name: DEPLOYMENT_MODE' \
  "external: DEPLOYMENT_MODE is set on control-plane-app"
assert_contains "$out3" 'name: DEPLOYMENT_MODE'$'\n''          value: "external"' \
  "external: DEPLOYMENT_MODE is always external"
assert_not_contains "$out3" 'name: ONPREM_SUPERADMIN_EMAIL' \
  "external: ONPREM_SUPERADMIN_EMAIL absent when global.superadmin unset"
assert_not_contains "$out3" 'name: ONPREM_SUPERADMIN_PASSWORD' \
  "external: ONPREM_SUPERADMIN_PASSWORD absent when global.superadmin unset"
assert_contains "$out3" 'name: data-plane-api' \
  "external: data-plane-api still renders"
assert_contains "$out3" 'name: agentgateway-admin' \
  "external: agentgateway admin control plane renders"
assert_contains "$out3" 'name: trustguard-control-plane' \
  "external: trustguard control plane renders"
assert_contains "$out3" 'NEURAL_TRUST_FIREWALL_BASE_URL: "http://firewall.default.svc.cluster.local"' \
  "external: TrustGuard wires in-cluster Firewall base URL"
assert_contains "$out3" 'name: NEURAL_TRUST_FIREWALL_SECRET_KEY'$'\n''          valueFrom:'$'\n''            secretKeyRef:'$'\n''              name: "firewall-secrets"' \
  "external: TrustGuard mounts firewall-secrets JWT_SECRET"
assert_contains "$out3" 'OTEL_EXPORTER_OTLP_ENDPOINT: "http://clickstack-collector.default.svc.cluster.local:4318/v1/logs"' \
  "external: product OTLP logs endpoint includes /v1/logs (WithEndpointURL)"
assert_contains "$out3" 'OPENTELEMETRY_TRACES_ENDPOINT: "clickstack-collector.default.svc.cluster.local:4318"' \
  "external: runtime traces stay host:port (WithEndpoint appends /v1/traces)"
assert_not_contains "$out3" 'name: clickstack-egress-collector' \
  "external: hybrid egress collector must not render (in-cluster path)"
assert_not_contains "$out3" 'clickstack-egress-collector.default.svc' \
  "external: product OTLP must not point at hybrid egress"
assert_contains "$out3" 'name: clickstack-collector-secrets' \
  "external: clickstack-collector-secrets Secret renders"
assert_contains "$out3" 'OTEL_EXPORTER_OTLP_HEADERS:' \
  "external: collector Secret carries OTEL_EXPORTER_OTLP_HEADERS"
assert_contains "$out3" 'name: OTEL_EXPORTER_OTLP_HEADERS'$'\n''          valueFrom:'$'\n''            secretKeyRef:'$'\n''              name: "clickstack-collector-secrets"' \
  "external: TrustGuard/AgentGateway mount OTLP headers from collector Secret"
assert_contains "$out3" 'name: datacore-env-vars' \
  "external: datacore-env-vars ConfigMap renders"
assert_contains "$out3" 'POSTGRES_HOST: "control-plane-postgresql"' \
  "external: DataCore POSTGRES_HOST defaults to in-cluster Postgres"
assert_contains "$out3" 'POSTGRES_DATABASE: "datacore"' \
  "external: DataCore POSTGRES_DATABASE defaults to datacore"
assert_contains "$out3" 'POSTGRES_USER: "datacore"' \
  "external: DataCore POSTGRES_USER defaults to datacore"
assert_contains "$out3" 'POSTGRES_PASSWORD:' \
  "external: datacore-secrets carries POSTGRES_PASSWORD"

# Same canonical Postgres family as hybrid, plus the Prisma URL the app needs.
assert_secret_keys "$out3" postgresql-secrets present \
  "external: postgresql-secrets stores canonical" \
  POSTGRES_HOST POSTGRES_PORT POSTGRES_DB POSTGRES_USER \
  POSTGRES_PASSWORD POSTGRES_SSLMODE POSTGRES_LOGIN POSTGRES_AUTH_MODE \
  POSTGRES_CONNECTION_TYPE POSTGRES_PRISMA_URL
# The lib/pq DSN has no external reader: the gateways gate that env entry on
# hybrid and DataAgent is hybrid-only. Storing it anyway meant a credential
# written for nobody, and one more thing to compose at render time.
assert_secret_key "$out3" postgresql-secrets absent SENSIBLE_PG_DSN \
  "external: postgresql-secrets omits the lib/pq DSN it has no reader for"
assert_secret_keys "$out3" postgresql-secrets absent \
  "external: postgresql-secrets no longer stores" \
  DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD DB_SSL_MODE \
  DATABASE_URL DATABASE_AUTH_MODE DATABASE_IAM_AUTH
# The app reads POSTGRES_DATABASE and DATABASE_URL; both are renames of canonical
# keys (POSTGRES_DB, POSTGRES_PRISMA_URL) rather than separately stored duplicates.
# SSLMODE and CONNECTION_LIMIT are the remaining two parts of the URL, so the app
# can rebuild exactly what the chart would have composed when no URL is supplied.
assert_datastore_env "$out3" control-plane-app app \
  'DATABASE_URL POSTGRES_AUTH_MODE POSTGRES_CONNECTION_LIMIT POSTGRES_DATABASE POSTGRES_HOST POSTGRES_PASSWORD POSTGRES_PORT POSTGRES_PRISMA_URL POSTGRES_SSLMODE POSTGRES_USER' \
  "external: control-plane-app renames POSTGRES_DB/POSTGRES_PRISMA_URL at the consumption site"
assert_no_envfrom_secret "$out3" postgresql-secrets \
  "external: no workload injects postgresql-secrets wholesale"

# --- full-only: external env contracts through cloud Ingress (before OpenShift Routes)
if suite_full; then

blue "==> Scenario 3-superadmin: ONPREM_SUPERADMIN_* when global.superadmin set"
out3sa="$TMP/scenario-external-superadmin.yaml"
render_default "$out3sa" \
  --set global.deploymentMode=external \
  --set global.superadmin.email=admin@example.com \
  --set global.superadmin.password=s3cret
if ! grep -A4 -E '^        - name: ONPREM_SUPERADMIN_PASSWORD$' "$out3sa" \
  | grep -qE '^              name: control-plane-secrets$'; then
  red "FAIL: external+superadmin: ONPREM_SUPERADMIN_PASSWORD not sourced from control-plane-secrets"
  exit 1
fi
green "ok  - external+superadmin: ONPREM_SUPERADMIN_PASSWORD from control-plane-secrets"
assert_contains "$out3sa" 'ONPREM_SUPERADMIN_EMAIL: "YWRtaW5AZXhhbXBsZS5jb20="' \
  "external+superadmin: inline email rendered into control-plane-secrets"
assert_contains "$out3sa" 'ONPREM_SUPERADMIN_PASSWORD: "czNjcmV0"' \
  "external+superadmin: inline password rendered into control-plane-secrets"
# The password must never reach the Deployment spec as a literal value.
assert_not_contains "$out3sa" 'value: "s3cret"' \
  "external+superadmin: password never a plain container env value"

# Env var names must match what the apps actually read; a mismatch is silently
# ignored at runtime rather than failing loudly.
blue "==> Scenario 3-envnames: chart env names match the names the apps read"
out3en="$TMP/scenario-external-envnames.yaml"
render_default "$out3en" \
  --set global.deploymentMode=external \
  --set data-plane-api.dataPlane.components.api.k8sJobs.enabled=true \
  --set data-plane-api.dataPlane.components.api.k8sJobs.ttlSecondsAfterFinished=900 \
  --set data-plane-api.dataPlane.components.api.k8sJobs.maxConcurrentJobs=25 \
  --set control-plane-app.controlPlane.secrets.resendAlertSender=alerts@example.com \
  --set control-plane-app.controlPlane.secrets.resendReplyTo=support@example.com
# data-plane-api reads K8S_JOB_TTL_SECONDS / K8S_MAX_CONCURRENT_JOBS.
assert_contains "$out3en" '^          - name: K8S_JOB_TTL_SECONDS$' \
  "envnames: K8S_JOB_TTL_SECONDS set on data-plane-api"
assert_contains "$out3en" '^          - name: K8S_MAX_CONCURRENT_JOBS$' \
  "envnames: K8S_MAX_CONCURRENT_JOBS set on data-plane-api"
assert_not_contains "$out3en" 'K8S_JOB_TTL_SECONDS_AFTER_FINISHED|K8S_JOBS_MAX_CONCURRENT' \
  "envnames: stale K8S job env names gone"
# control-plane-app reads SENDER / REPLY_TO_EMAIL, never RESEND_SENDER. Legacy
# controlPlane.secrets.resend* values must keep feeding them.
assert_contains "$out3en" '^        - name: SENDER$' \
  "envnames: SENDER set on control-plane-app"
assert_contains "$out3en" '^          value: "alerts@example.com"$' \
  "envnames: legacy resendAlertSender still feeds SENDER"
assert_contains "$out3en" '^        - name: REPLY_TO_EMAIL$' \
  "envnames: REPLY_TO_EMAIL set on control-plane-app"
assert_contains "$out3en" 'resend-reply-to:' \
  "envnames: control-plane-secrets carries resend-reply-to"
assert_not_contains "$out3en" 'name: RESEND_SENDER' \
  "envnames: stale RESEND_SENDER gone"
# Neither control-plane service reads DATABASE_AUTH_MODE / DATABASE_IAM_AUTH;
# the app uses POSTGRES_AUTH_MODE and the API uses POSTGRES_CONNECTION_TYPE.
assert_not_contains "$out3en" '^        - name: DATABASE_AUTH_MODE$' \
  "envnames: dead DATABASE_AUTH_MODE env gone"
assert_not_contains "$out3en" '^        - name: DATABASE_IAM_AUTH$' \
  "envnames: dead DATABASE_IAM_AUTH env gone"
assert_contains "$out3en" '^        - name: POSTGRES_AUTH_MODE$' \
  "envnames: POSTGRES_AUTH_MODE still set on control-plane-app"

# The app supports resend | ses | smtp behind AUTH_EMAIL_PROVIDER. Addresses are
# public config (plain env); only credentials may come from a Secret.
blue "==> Scenario 3-email: provider-specific outbound email wiring"
out3em="$TMP/scenario-external-email-smtp.yaml"
render_default "$out3em" \
  --set global.deploymentMode=external \
  --set global.email.provider=smtp \
  --set global.email.from=noreply@example.com \
  --set global.email.replyTo=help@example.com \
  --set global.email.smtp.host=smtp.example.com \
  --set global.email.smtp.port=465 \
  --set global.email.smtp.user=mailer \
  --set global.email.smtp.password=s3cr3t
assert_contains "$out3em" '^          value: "smtp"$' \
  "email smtp: AUTH_EMAIL_PROVIDER is smtp"
assert_contains "$out3em" '^        - name: SMTP_HOST$' "email smtp: SMTP_HOST set"
assert_contains "$out3em" '^          value: "465"$' "email smtp: SMTP_PORT set"
assert_contains "$out3em" '^        - name: SMTP_SECURE$' "email smtp: SMTP_SECURE set"
assert_contains "$out3em" '^        - name: SMTP_USER$' "email smtp: SMTP_USER set"
# App reads SMTP_PASS; the chart Secret key is SMTP_PASSWORD.
assert_contains "$out3em" '^        - name: SMTP_PASS$' "email smtp: SMTP_PASS set"
assert_contains "$out3em" '^  SMTP_PASSWORD: ' "email smtp: password stored in a Secret"
assert_not_contains "$out3em" 'value: "s3cr3t"' \
  "email smtp: password never a plain env value"
# Addresses are public and must not be pushed into a Secret.
assert_contains "$out3em" '^          value: "noreply@example.com"$' \
  "email smtp: from address is plain env"
assert_not_contains "$out3em" '^  EMAIL_FROM: ' \
  "email smtp: from address not stored as a Secret key"
assert_not_contains "$out3em" '^        - name: AWS_SES_REGION$' \
  "email smtp: no SES env when provider is smtp"

out3ses="$TMP/scenario-external-email-ses.yaml"
render_default "$out3ses" \
  --set global.deploymentMode=external \
  --set global.email.provider=ses \
  --set global.email.ses.region=eu-west-1
assert_contains "$out3ses" '^        - name: AWS_SES_REGION$' "email ses: AWS_SES_REGION set"
# No static keys means the pod IAM role (IRSA) is used; injecting static creds
# would hijack the SDK credential chain for Postgres IAM auth too.
assert_not_contains "$out3ses" '^        - name: AWS_ACCESS_KEY_ID$' \
  "email ses: no static credentials when relying on IRSA"
assert_not_contains "$out3ses" '^        - name: SMTP_HOST$' \
  "email ses: no SMTP env when provider is ses"

# Misconfigured providers must fail at render time, not silently drop email.
# extraEnv was the only way to select a provider before global.email existed.
# Emitting the same env name twice makes the API server reject the
# strategic-merge patch, so the chart must yield to extraEnv on upgrade.
out3ex="$TMP/scenario-external-email-extraenv.yaml"
render_default "$out3ex" \
  --set global.deploymentMode=external \
  --set 'control-plane-app.controlPlane.components.app.extraEnv[0].name=AUTH_EMAIL_PROVIDER' \
  --set 'control-plane-app.controlPlane.components.app.extraEnv[0].value=ses' \
  --set 'control-plane-app.controlPlane.components.app.extraEnv[1].name=AWS_SES_REGION' \
  --set 'control-plane-app.controlPlane.components.app.extraEnv[1].value=eu-west-1' \
  --set 'control-plane-app.controlPlane.components.app.extraEnv[2].name=AUTH_EMAIL_FROM' \
  --set 'control-plane-app.controlPlane.components.app.extraEnv[2].value=no-reply@example.com'
assert_occurrences "$out3ex" '^        - name: AUTH_EMAIL_PROVIDER$' 1 \
  "email extraEnv: AUTH_EMAIL_PROVIDER emitted once, not duplicated"
assert_occurrences "$out3ex" '^        - name: AWS_SES_REGION$' 1 \
  "email extraEnv: AWS_SES_REGION emitted once, not duplicated"
assert_occurrences "$out3ex" '^        - name: AUTH_EMAIL_FROM$' 1 \
  "email extraEnv: AUTH_EMAIL_FROM emitted once, not duplicated"
# extraEnv goes through toYaml, so the value renders unquoted.
assert_contains "$out3ex" '^          value: ses$' \
  "email extraEnv: operator override wins over the chart default"
assert_not_contains "$out3ex" '^          value: "resend"$' \
  "email extraEnv: chart default provider not also emitted"

assert_render_fails "email: unknown provider fails render" \
  --set global.deploymentMode=external --set global.email.provider=mailgun
assert_render_fails "email: ses without a region fails render" \
  --set global.deploymentMode=external --set global.email.provider=ses
assert_render_fails "email: smtp without a host fails render" \
  --set global.deploymentMode=external --set global.email.provider=smtp
assert_render_fails "email: smtp user without a password source fails render" \
  --set global.deploymentMode=external --set global.email.provider=smtp \
  --set global.email.smtp.host=smtp.example.com --set global.email.smtp.user=mailer
assert_render_fails "email: existingSecret plus an inline credential fails render" \
  --set global.deploymentMode=external \
  --set global.email.existingSecret.name=my-email \
  --set global.email.resend.apiKey=re_123

# Hybrid is the primary customer topology, and it renders data-plane-api without
# any control plane, so the external-mode assertions above never exercise it.
blue "==> Scenario 3-hybrid-envnames: data-plane-api env names in hybrid mode"
out3hy="$TMP/scenario-hybrid-envnames.yaml"
render_default "$out3hy" \
  --set global.deploymentMode=hybrid \
  --set global.products.trustguard=true \
  --set global.products.dataPlane=true \
  --set data-plane-api.dataPlane.components.api.k8sJobs.enabled=true \
  --set data-plane-api.dataPlane.components.api.k8sJobs.ttlSecondsAfterFinished=900 \
  --set data-plane-api.dataPlane.components.api.k8sJobs.maxConcurrentJobs=25
assert_contains "$out3hy" '^          - name: K8S_JOB_TTL_SECONDS$' \
  "hybrid envnames: K8S_JOB_TTL_SECONDS set on data-plane-api"
assert_contains "$out3hy" '^          - name: K8S_MAX_CONCURRENT_JOBS$' \
  "hybrid envnames: K8S_MAX_CONCURRENT_JOBS set on data-plane-api"
assert_not_contains "$out3hy" 'K8S_JOB_TTL_SECONDS_AFTER_FINISHED' \
  "hybrid envnames: stale K8S_JOB_TTL_SECONDS_AFTER_FINISHED gone"
assert_not_contains "$out3hy" 'K8S_JOBS_MAX_CONCURRENT' \
  "hybrid envnames: stale K8S_JOBS_MAX_CONCURRENT gone"
# Hybrid has no control plane, so control-plane-app must not appear at all.
assert_not_contains "$out3hy" '^  name: control-plane-app$' \
  "hybrid envnames: no control-plane-app in hybrid"
# data-plane-api used to include four undefined kafka helpers. They rendered
# nothing but would fail the chart if reintroduced, and the app talks to
# ClickHouse directly in hybrid.
assert_not_contains "$out3hy" 'name: KAFKA_BROKERS|kafka-client-tls|name: KAFKA_SASL' \
  "hybrid envnames: no kafka client env or TLS volume on data-plane-api"

# PR1 on the hybrid path: the data-plane-api Route is the only Route carrying a
# control-plane-facing TLS Secret here, and it must still avoid key material.
out3hytls="$TMP/scenario-hybrid-openshift-route-tls.yaml"
helm template test "$CHART_DIR" --namespace default \
  -f "$CHART_DIR/values-required.yaml" \
  "${CLICKSTACK_DEFAULT_ARGS[@]}" \
  --api-versions route.openshift.io/v1 \
  --set global.deploymentMode=hybrid \
  --set global.products.trustguard=true \
  --set global.products.dataPlane=true \
  --set global.platform=openshift \
  --set global.domain=apps.example.com \
  --set data-plane-api.dataPlane.components.api.ingress.enabled=false \
  --set data-plane-api.dataPlane.components.api.ingress.tls.secretName=dp-tls \
  > "$out3hytls"
validate_yaml "$out3hytls"
assert_contains "$out3hytls" '^    externalCertificate:$' \
  "hybrid Route TLS: data-plane-api Route references a TLS Secret"
assert_contains "$out3hytls" 'name: "dp-tls"' \
  "hybrid Route TLS: externalCertificate references dp-tls"
if awk '/^kind: Route$/{r=1} /^---$/{r=0} r' "$out3hytls" | grep -qE 'PRIVATE KEY|^ +key:'; then
  red "FAIL: hybrid Route TLS: a Route contains private key material"
  exit 1
fi
green "ok  - hybrid Route TLS: no Route contains private key material"

blue "==> Scenario 3-superadmin-secret: existingSecret wins over inline"
out3sas="$TMP/scenario-external-superadmin-secret.yaml"
render_default "$out3sas" \
  --set global.deploymentMode=external \
  --set global.superadmin.existingSecret.name=onprem-superadmin \
  --set global.superadmin.email=ignored@example.com \
  --set global.superadmin.password=ignored
assert_contains "$out3sas" 'name: ONPREM_SUPERADMIN_EMAIL'$'\n''          valueFrom:'$'\n''            secretKeyRef:'$'\n''              name: "onprem-superadmin"' \
  "external+superadmin secret: EMAIL from existingSecret"
assert_contains "$out3sas" 'key: "ONPREM_SUPERADMIN_EMAIL"' \
  "external+superadmin secret: default email key"
assert_contains "$out3sas" 'name: ONPREM_SUPERADMIN_PASSWORD'$'\n''          valueFrom:'$'\n''            secretKeyRef:'$'\n''              name: "onprem-superadmin"' \
  "external+superadmin secret: PASSWORD from existingSecret"
assert_contains "$out3sas" 'key: "ONPREM_SUPERADMIN_PASSWORD"' \
  "external+superadmin secret: default password key"
assert_not_contains "$out3sas" 'value: "ignored@example.com"' \
  "external+superadmin secret: inline email not used when existingSecret set"
assert_not_contains "$out3sas" 'value: "ignored"' \
  "external+superadmin secret: inline password not used when existingSecret set"

# External config-sync servers and clients must share each component's
# operator-owned credentials.
blue "==> Scenario 3a: external config-sync uses shared operator Secrets"
out3a="$TMP/scenario-external-config-sync.yaml"
render_default "$out3a" \
  --set global.deploymentMode=external \
  --set agentgateway.configSync.enabled=true \
  --set agentgateway.configSync.existingSecret.name=agentgateway-config-sync \
  --set trustguard.configSync.enabled=true \
  --set trustguard.configSync.existingSecret.name=trustguard-config-sync
# One reference per workload: the token only. The LKG key rides along on the
# chart-managed Secret through envFrom.
assert_occurrences "$out3a" 'name: "?agentgateway-config-sync"?' 3 \
  "external config-sync: AgentGateway proxy, MCP, and admin share the operator token"
assert_occurrences "$out3a" 'name: "?trustguard-config-sync"?' 2 \
  "external config-sync: TrustGuard data and control planes share the operator token"

# ---------------------------------------------------------------------------
# 3b. Control-plane RDS IAM env contract (api + app) + DataCore IAM
# ---------------------------------------------------------------------------
blue "==> Scenario 3b: control-plane Postgres IAM env contract"
out3b="$TMP/scenario-external-cp-iam.yaml"
render_default "$out3b" \
  --set global.deploymentMode=external \
  --set global.postgresql.deploy=false \
  --set global.postgresql.host=pg.iam.example.com \
  --set global.postgresql.authMode=iam \
  --set global.postgresql.awsRegion=eu-west-1 \
  --set global.postgresql.user=neuraltrust_iam \
  --set datacore.database.iamAuth=true \
  --set datacore.database.host=pg.iam.example.com \
  --set datacore.database.user=datacore_iam \
  --set datacore.database.sslMode=require \
  --set datacore.database.awsRegion=eu-west-1 \
  --set control-plane-api.controlPlane.components.postgresql.authMode=iam \
  --set control-plane-api.controlPlane.components.postgresql.awsRegion=eu-west-1 \
  --set control-plane-app.controlPlane.components.postgresql.authMode=iam \
  --set control-plane-app.controlPlane.components.postgresql.awsRegion=eu-west-1

# Secret carries app/API-facing keys (base64):
#   POSTGRES_AUTH_MODE=iam          → aWFt
#   POSTGRES_CONNECTION_TYPE=aurora → YXVyb3Jh
assert_contains "$out3b" 'POSTGRES_AUTH_MODE: "aWFt"' \
  "cp IAM: postgresql-secrets emits POSTGRES_AUTH_MODE=iam"
assert_contains "$out3b" 'POSTGRES_CONNECTION_TYPE: "YXVyb3Jh"' \
  "cp IAM: postgresql-secrets emits POSTGRES_CONNECTION_TYPE=aurora"
assert_contains "$out3b" 'name: AWS_REGION' \
  "cp IAM: Deployments emit AWS_REGION"
assert_contains "$out3b" 'value: "eu-west-1"' \
  "cp IAM: AWS_REGION=eu-west-1"
assert_contains "$out3b" 'postgres-iam-url.mjs' \
  "cp IAM: app init-db mints Prisma URL via postgres-iam-url.mjs"
assert_contains "$out3b" 'PRISMA_CLI="/app/node_modules/prisma/build/index.js"' \
  "cp app: init-db uses the image-bundled Prisma CLI"
assert_contains "$out3b" 'node "\$PRISMA_CLI" migrate deploy' \
  "cp app: init-db executes versioned migrations with the bundled CLI"
assert_not_contains "$out3b" 'npx prisma' \
  "cp app: init-db does not require the removed npx binary"
assert_not_contains "$out3b" 'prisma db push' \
  "cp app: init-db applies versioned migrations only"
assert_contains "$out3b" 'POSTGRES_LOGIN: "aws"' \
  "datacore IAM: emits POSTGRES_LOGIN=aws"
assert_contains "$out3b" 'POSTGRES_USER: "datacore_iam"' \
  "datacore IAM: POSTGRES_USER is the _iam role"
assert_contains "$out3b" 'AWS_REGION: "eu-west-1"' \
  "datacore IAM: ConfigMap carries AWS_REGION"
# datacore-secrets keeps AUTH_JWT + CLICKHOUSE_USER only (no POSTGRES_PASSWORD).
assert_contains "$out3b" 'name: datacore-secrets'$'\n''  annotations:'$'\n''    helm.sh/resource-policy: keep' \
  "datacore IAM: datacore-secrets still renders"
assert_contains "$out3b" 'AUTH_JWT_HS256_SECRET:'$'\n''  CLICKHOUSE_USER:' \
  "datacore IAM: omits POSTGRES_PASSWORD between JWT and CLICKHOUSE_USER"

# ---------------------------------------------------------------------------
# 4. New unprefixed value roots are honoured
# ---------------------------------------------------------------------------
blue "==> Scenario 4: unprefixed value roots (control-plane-api / control-plane-app / data-plane-api / firewall / watchdog)"
out4="$TMP/scenario-unprefixed-roots.yaml"
render_default "$out4" \
  --set global.deploymentMode=external \
  --set watchdog.enabled=true

assert_contains "$out4" 'kind: Deployment' \
  "unprefixed roots: chart still renders"
assert_contains "$out4" 'name: firewall' \
  "firewall: Deployment follows enabled TrustGuard"
assert_contains "$out4" 'name: neuraltrust-watchdog' \
  "watchdog root: stable K8s name neuraltrust-watchdog preserved"
assert_resource_count "$out4" Service dataagent 0 \
  "external: TrustGate DataAgent health Service absent"
assert_resource_count "$out4" Service dataagent-trustguard 0 \
  "external: TrustGuard DataAgent health Service absent"
assert_not_contains "$out4" 'dataagent-(trustgate|trustguard)-(readyz|deployment-health)' \
  "external: no orphan DataAgent watchdog checks"

# ---------------------------------------------------------------------------
# 5. ABSENCE of retired v1 components
# ---------------------------------------------------------------------------
blue "==> Scenario 5: retired v1 components MUST be absent"
for scenario_file in "$out1" "$out2" "$out3" "$out4"; do
  assert_not_contains "$scenario_file" '^kind: Deployment$.*trustgate' \
    "no TrustGate Deployment in $(basename "$scenario_file")" || true
  assert_not_contains "$scenario_file" 'app.kubernetes.io/name: trustgate' \
    "no TrustGate labels in $(basename "$scenario_file")"
  assert_not_contains "$scenario_file" 'app.kubernetes.io/name: kafka' \
    "no Kafka labels in $(basename "$scenario_file")"
  assert_not_contains "$scenario_file" 'app.kubernetes.io/name: zookeeper' \
    "no Zookeeper labels in $(basename "$scenario_file")"
  # Zookeeper/Kafka were the only StatefulSets in v1; ClickHouse's StatefulSet is legitimate.
  if grep -qE '^kind: StatefulSet' "$scenario_file"; then
    while IFS= read -r sts_name; do
      case "$sts_name" in
        clickhouse|clickhouse-*|neuraltrust-watchdog|neuraltrust-watchdog-*) ;;
        *)
          red "FAIL: unexpected StatefulSet '$sts_name' in $(basename "$scenario_file")"
          exit 1
          ;;
      esac
    done < <(awk '/^kind: StatefulSet/{sts=1; next} sts && /^metadata:/{next} sts && /^  name:/{sub("^  name: ", ""); print; sts=0}' "$scenario_file")
  fi
  green "ok  - only legit (ClickHouse) StatefulSets in $(basename "$scenario_file")"
  assert_not_contains "$scenario_file" 'name: scheduler' \
    "no scheduler Deployment/Service in $(basename "$scenario_file")"
  assert_not_contains "$scenario_file" 'name: kafka-connect' \
    "no Kafka Connect Deployment/Service in $(basename "$scenario_file")"
  assert_not_contains "$scenario_file" 'name: v2-postgresql-init' \
    "no v2-postgresql-init Job in $(basename "$scenario_file")"
  # The v1 console env block was gated on a helper that always returned true,
  # so it never rendered. Its variables must not come back: the app either
  # ignores them (FORCE_V2_UI) or would follow them to the SaaS host.
  for v1_env in FORCE_V2_UI CONTROL_PLANE_SCHEDULER_URL TRUSTGATE_CONTROL_PLANE_URL \
                TRUSTGATE_DATA_PLANE_URL TRUSTGATE_ACTIONS_URL TRUSTGATE_JWT_SECRET; do
    assert_not_contains "$scenario_file" "name: ${v1_env}$" \
      "no ${v1_env} in $(basename "$scenario_file")"
  done
done

# Keys nothing reads must not be minted either. Both belonged to the retired v1
# console; control-plane-secrets only renders in external mode.
assert_secret_keys "$out3" control-plane-secrets absent \
  "external: control-plane-secrets omits unread" \
  TRUSTGATE_JWT_SECRET resend-invite-sender

# ---------------------------------------------------------------------------
# 6. Stable Kubernetes names after physical chart moves
# ---------------------------------------------------------------------------
blue "==> Scenario 6: stable Kubernetes names preserved after chart rebrand"
# Reuse Scenario 3 external render — same deploymentMode, no extra flags.
for name in \
  control-plane-api \
  control-plane-app \
  control-plane-postgresql \
  postgresql-secrets \
  redis \
  data-plane-api \
  agentgateway-proxy \
  agentgateway-admin \
  trustguard-data-plane \
  trustguard-control-plane
do
  assert_contains "$out3" "name: $name" \
    "stable name preserved: $name"
done
# redis-secrets is a hybrid-only shared Secret.
assert_contains "$out1" 'name: redis-secrets' \
  "stable name preserved (hybrid): redis-secrets"

# watchdog keeps its stable resource name after charts/neuraltrust-watchdog -> charts/watchdog.
out6wd="$TMP/scenario-watchdog-names.yaml"
render_default "$out6wd" --set global.deploymentMode=external --set watchdog.enabled=true
assert_contains "$out6wd" 'name: neuraltrust-watchdog' \
  "stable name preserved after rename: neuraltrust-watchdog"
# AUT-346: external watchdog → in-cluster ClickStack (signal-neutral base + headers).
assert_env_value "$out6wd" neuraltrust-watchdog watchdog OTEL_EXPORTER_OTLP_ENDPOINT \
  'http://clickstack-collector.default.svc.cluster.local:4318' \
  "watchdog external: OTLP is signal-neutral clickstack-collector :4318"
assert_env_value "$out6wd" neuraltrust-watchdog watchdog OTEL_EXPORTER_OTLP_HEADERS \
  'secretKeyRef:clickstack-collector-secrets/OTEL_EXPORTER_OTLP_HEADERS' \
  "watchdog external: mounts OTEL_EXPORTER_OTLP_HEADERS from clickstack-collector-secrets"
assert_env_value "$out6wd" neuraltrust-watchdog watchdog OPENTELEMETRY_AUTH_TOKEN ABSENT \
  "watchdog external: no hosted OPENTELEMETRY_AUTH_TOKEN"
# AUT-519: bundled Prometheus is gone; RED inherits runner.clickstack.
if grep -qE 'name: .*-prometheus|PROMETHEUS_QUERY_URL|prometheusQueryEnv|scrape_staleness|kind: promql' "$out6wd"; then
  red "FAIL: watchdog external render still ships Prometheus / PromQL symbols"
  grep -nE 'name: .*-prometheus|PROMETHEUS_QUERY_URL|prometheusQueryEnv|scrape_staleness|kind: promql' "$out6wd" | head -20
  exit 1
fi
green "ok  - watchdog external: no bundled Prometheus / PROMETHEUS_QUERY_URL / scrape_staleness"
assert_contains "$out6wd" 'clickstack:' \
  "watchdog external: runner.clickstack block present"
assert_contains "$out6wd" 'address: "clickhouse:9000"' \
  "watchdog external: runner.clickstack defaults to in-cluster ClickHouse native port"
assert_contains "$out6wd" 'database: "otel"' \
  "watchdog external: runner.clickstack database is otel"
assert_contains "$out6wd" 'kind: otlp_freshness' \
  "watchdog external: self-freshness is otlp_freshness (not scrape_staleness)"
# hybrid must NOT wire a local ClickStack address (no in-cluster CH).
out6wd_h="$TMP/scenario-watchdog-hybrid-clickstack.yaml"
render_product_slice "$out6wd_h" -f "$CHART_DIR/values-trustgate.yaml.example" --set watchdog.enabled=true
if grep -qE 'name: .*-prometheus|PROMETHEUS_QUERY_URL|prometheusQueryEnv' "$out6wd_h"; then
  red "FAIL: watchdog hybrid render still ships Prometheus symbols"
  exit 1
fi
if awk '/name: neuraltrust-watchdog-config/,/^---/' "$out6wd_h" | grep -q 'clickstack:'; then
  red "FAIL: watchdog hybrid must not default runner.clickstack (no local ClickHouse)"
  awk '/name: neuraltrust-watchdog-config/,/^---/' "$out6wd_h" | head -40
  exit 1
fi
green "ok  - watchdog hybrid: no runner.clickstack default (central SaaS evaluates RED)"

# ---------------------------------------------------------------------------
# 7. Retired helpers / values must not appear in the values contract or rendered output
# ---------------------------------------------------------------------------
blue "==> Scenario 7: retired concepts must not surface in values contract"
if grep -RqE '(platformVersion|confirmV2Migration|hybridRoleLayout|sharedWriter|initJob|neuraltrust-control-plane:|neuraltrust-data-plane:|neuraltrust-firewall:|neuraltrust-watchdog:|^kafka:|gatewayDiscoveryMode|GATEWAY_DISCOVERY_MODE|^trustgate:)' \
    values.yaml values-required.yaml charts/agentgateway/values.yaml; then
  red "FAIL: retired values keys still present in values.yaml / values-required.yaml / agentgateway values"
  exit 1
fi
green "ok  - values.yaml / values-required.yaml free of retired keys"

# ---------------------------------------------------------------------------
# 8. AgentGateway exact + wildcard routing (AWS / Azure / GCP Ingress)
# ---------------------------------------------------------------------------
blue "==> Scenario 8: AgentGateway exact + wildcard Ingress (cloud providers)"
WILDCARD_COMMON=(
  --set global.domain=platform.example.com
  --set agentgateway.config.gatewayBaseDomain=llm.platform.example.com
  --set agentgateway.config.mcpBaseDomain=mcp.platform.example.com
  --set agentgateway.ingress.dataPlane.host=gateway.platform.example.com
  --set agentgateway.ingress.dataPlane.additionalHosts[0]="*.llm.platform.example.com"
  --set agentgateway.ingress.mcp.host=mcp.platform.example.com
  --set agentgateway.ingress.mcp.additionalHosts[0]="*.mcp.platform.example.com"
)

# Cloud providers share the same Ingress template path; one representative is enough.
provider=aws
outw="$TMP/scenario-wildcard-${provider}.yaml"
render_default "$outw" \
  --set global.deploymentMode=external \
  --set "global.platform=${provider}" \
  "${WILDCARD_COMMON[@]}"
assert_contains "$outw" 'name: agentgateway-gateway' \
  "${provider}: proxy Ingress name stable"
assert_contains "$outw" 'host: "gateway.platform.example.com"' \
  "${provider}: proxy exact host"
assert_contains "$outw" 'host: "\*\.llm\.platform\.example\.com"' \
  "${provider}: proxy wildcard host rule"
assert_contains "$outw" 'name: agentgateway-proxy' \
  "${provider}: proxy backend Service"
assert_contains "$outw" 'name: agentgateway-mcp' \
  "${provider}: MCP Ingress/Service present"
assert_contains "$outw" 'host: "mcp.platform.example.com"' \
  "${provider}: MCP exact host"
assert_contains "$outw" 'host: "\*\.mcp\.platform\.example\.com"' \
  "${provider}: MCP wildcard host rule"
assert_not_contains "$outw" 'GATEWAY_DISCOVERY_MODE' \
  "${provider}: discovery mode env retired"
assert_contains "$outw" 'GATEWAY_BASE_DOMAIN: "llm.platform.example.com"' \
  "${provider}: gateway base domain"
assert_contains "$outw" 'MCP_BASE_DOMAIN: "mcp.platform.example.com"' \
  "${provider}: MCP base domain"
# Admin must stay exact-only (no wildcard rule on admin Ingress).
if python3 - "$outw" <<'PY'
import re, sys
for doc in open(sys.argv[1]).read().split("---"):
    if "kind: Ingress" in doc and re.search(r"(?m)^\s+name:\s*agentgateway-admin\s*$", doc):
        if re.search(r'host:\s*"?\*\.', doc):
            sys.exit(1)
sys.exit(0)
PY
then
  green "ok  - ${provider}: admin Ingress has no wildcard hosts"
else
  red "FAIL: ${provider}: admin Ingress must not include wildcard hosts"
  exit 1
fi
assert_not_contains "$outw" 'kind: Route' \
  "${provider}: no OpenShift Routes on cloud platform"

# Dual discovery default: empty additionalHosts → auto wildcards + llm./mcp. bases.
blue "==> Scenario 8b: dual discovery auto-derives base domains and wildcards"
outw_auto="$TMP/scenario-wildcard-autoderive.yaml"
render_default "$outw_auto" \
  --set global.domain=platform.example.com
assert_not_contains "$outw_auto" 'GATEWAY_DISCOVERY_MODE' \
  "auto: discovery mode env retired"
assert_contains "$outw_auto" 'GATEWAY_BASE_DOMAIN: "llm.platform.example.com"' \
  "auto: GATEWAY_BASE_DOMAIN=llm.<global.domain>"
assert_contains "$outw_auto" 'MCP_BASE_DOMAIN: "mcp.platform.example.com"' \
  "auto: MCP_BASE_DOMAIN=mcp.<global.domain>"
assert_contains "$outw_auto" 'host: "\*\.llm\.platform\.example\.com"' \
  "auto: proxy wildcard host from global.domain"
assert_contains "$outw_auto" 'host: "\*\.mcp\.platform\.example\.com"' \
  "auto: MCP wildcard host from global.domain"
assert_contains "$outw_auto" 'host: "gateway.platform.example.com"' \
  "auto: exact gateway primary host retained"
# Opt out of auto wildcards (exact hosts only).
outw_no_auto="$TMP/scenario-wildcard-no-auto.yaml"
render_default "$outw_no_auto" \
  --set global.domain=platform.example.com \
  --set agentgateway.config.autoWildcardHosts=false
assert_contains "$outw_no_auto" 'host: "gateway.platform.example.com"' \
  "no-auto: exact gateway primary host retained"
assert_not_contains "$outw_no_auto" 'host: "\*\.' \
  "no-auto: autoWildcardHosts=false skips wildcards"
assert_contains "$outw_no_auto" 'GATEWAY_BASE_DOMAIN: "llm.platform.example.com"' \
  "no-auto: base domains still derived for dual-mode app"
# Explicit additionalHosts stays authoritative (no auto-merge).
outw_override="$TMP/scenario-wildcard-override.yaml"
render_default "$outw_override" \
  --set global.domain=platform.example.com \
  --set agentgateway.ingress.dataPlane.additionalHosts[0]="custom.platform.example.com"
assert_contains "$outw_override" 'host: "custom.platform.example.com"' \
  "override: explicit additionalHosts rendered"
assert_not_contains "$outw_override" 'host: "\*\.llm\.platform\.example\.com"' \
  "override: non-empty additionalHosts skips auto *.llm wildcard"

fi # suite_full (3-superadmin through 8b)

# ---------------------------------------------------------------------------
# 9. AgentGateway OpenShift Routes (exact + wildcardPolicy Subdomain)
# ---------------------------------------------------------------------------
blue "==> Scenario 9: AgentGateway OpenShift Routes + Ingress override"
out_ocp="$TMP/scenario-wildcard-openshift-routes.yaml"
helm template test "$CHART_DIR" --namespace default \
  -f "$CHART_DIR/values-required.yaml" \
  "${CLICKSTACK_DEFAULT_ARGS[@]}" \
  --api-versions route.openshift.io/v1 \
  --set global.deploymentMode=external \
  --set global.platform=openshift \
  --set global.domain=apps.example.com \
  --set agentgateway.config.gatewayBaseDomain=llm.apps.example.com \
  --set agentgateway.config.mcpBaseDomain=mcp.apps.example.com \
  --set agentgateway.ingress.dataPlane.host=gateway.apps.example.com \
  --set agentgateway.ingress.dataPlane.additionalHosts[0]="*.llm.apps.example.com" \
  --set agentgateway.ingress.mcp.host=mcp.apps.example.com \
  --set agentgateway.ingress.mcp.additionalHosts[0]="*.mcp.apps.example.com" \
  > "$out_ocp"

assert_contains "$out_ocp" 'kind: Route' \
  "openshift auto: Routes render"
assert_contains "$out_ocp" 'host: "gateway.apps.example.com"' \
  "openshift: exact proxy Route host"
assert_contains "$out_ocp" 'host: "llm.apps.example.com"' \
  "openshift: wildcard proxy Route host strips *."
assert_contains "$out_ocp" 'wildcardPolicy: Subdomain' \
  "openshift: wildcard Routes use Subdomain policy"
assert_contains "$out_ocp" 'wildcardPolicy: None' \
  "openshift: exact Routes use None policy"
assert_contains "$out_ocp" 'name: agentgateway-proxy' \
  "openshift: proxy Route backend Service"
assert_not_contains "$out_ocp" 'name: agentgateway-gateway' \
  "openshift auto: proxy Ingress not rendered"

# A Route is readable by anyone holding route/get, so it must never carry key
# material. TLS Secrets are referenced through spec.tls.externalCertificate.
out_ocp_tls="$TMP/scenario-openshift-route-tls.yaml"
helm template test "$CHART_DIR" --namespace default \
  -f "$CHART_DIR/values-required.yaml" \
  "${CLICKSTACK_DEFAULT_ARGS[@]}" \
  --api-versions route.openshift.io/v1 \
  --set global.deploymentMode=external \
  --set global.platform=openshift \
  --set global.domain=apps.example.com \
  --set control-plane-app.controlPlane.components.app.ingress.enabled=false \
  --set control-plane-app.controlPlane.components.app.ingress.tls.secretName=app-tls \
  --set control-plane-api.controlPlane.components.api.ingress.enabled=false \
  --set control-plane-api.controlPlane.components.api.ingress.tls.secretName=api-tls \
  --set data-plane-api.dataPlane.components.api.ingress.enabled=false \
  --set data-plane-api.dataPlane.components.api.ingress.tls.secretName=dp-tls \
  > "$out_ocp_tls"

assert_occurrences "$out_ocp_tls" '^    externalCertificate:$' 3 \
  "openshift Route TLS: all three Routes reference a TLS Secret"
for _s in app-tls api-tls dp-tls; do
  if ! grep -A1 -E '^    externalCertificate:$' "$out_ocp_tls" | grep -qE "name: \"${_s}\""; then
    red "FAIL: openshift Route TLS: externalCertificate does not reference ${_s}"
    exit 1
  fi
  green "ok  - openshift Route TLS: externalCertificate references ${_s}"
done
if awk '/^kind: Route$/{r=1} /^---$/{r=0} r' "$out_ocp_tls" | grep -qE 'PRIVATE KEY|^ +key:'; then
  red "FAIL: openshift Route TLS: a Route contains private key material"
  exit 1
fi
green "ok  - openshift Route TLS: no Route contains private key material"

# Explicit Ingress on OpenShift still works.
out_ocp_ing="$TMP/scenario-wildcard-openshift-ingress.yaml"
helm template test "$CHART_DIR" --namespace default \
  -f "$CHART_DIR/values-required.yaml" \
  "${CLICKSTACK_DEFAULT_ARGS[@]}" \
  --api-versions route.openshift.io/v1 \
  --set global.deploymentMode=hybrid \
  --set global.platform=openshift \
  --set global.domain=apps.example.com \
  --set agentgateway.ingress.resourceType=ingress \
  --set agentgateway.ingress.dataPlane.additionalHosts[0]="*.llm.apps.example.com" \
  > "$out_ocp_ing"
assert_contains "$out_ocp_ing" 'name: agentgateway-gateway' \
  "openshift resourceType=ingress: Ingress renders"
assert_contains "$out_ocp_ing" 'host: "\*\.llm\.apps\.example\.com"' \
  "openshift resourceType=ingress: wildcard Ingress rule"
assert_not_contains "$out_ocp_ing" 'name: agentgateway-proxy-' \
  "openshift resourceType=ingress: AgentGateway proxy Routes absent"
assert_not_contains "$out_ocp_ing" 'name: agentgateway-mcp-' \
  "openshift resourceType=ingress: AgentGateway MCP Routes absent"

if ! suite_full; then
  green "ok  - HELM_SUITE=compat complete"
  exit 0
fi

# ---------------------------------------------------------------------------
# 10. Watchdog defaults + firewall disable sync + hybrid ClickStack channels
# ---------------------------------------------------------------------------
blue "==> Scenario 10: watchdog otel-collector target and topology-neutral checks"
out10="$TMP/scenario-watchdog-defaults.yaml"
render_default "$out10" \
  --set global.observability.enabled=true \
  --set global.observability.hostedExport.enabled=false \
  --set watchdog.enabled=true
assert_contains "$out10" 'url: http://otel-collector:13133/' \
  "watchdog: otel-collector check targets umbrella Service"
assert_contains "$out10" 'labelSelector: app.kubernetes.io/component=otel-collector' \
  "watchdog: otel-collector selector matches umbrella labels"
assert_contains "$out10" 'endpoint: \[::\]:4317' \
  "observability: umbrella otel-collector OTLP gRPC binds dual-stack"
assert_contains "$out10" 'endpoint: \[::\]:13133' \
  "observability: umbrella otel-collector health binds dual-stack"
assert_contains "$out10" 'host: "::"' \
  "observability: umbrella otel-collector telemetry metrics host is ::"
assert_not_contains "$out10" 'url: http://opentelemetry-collector.opentelemetry:13133/' \
  "watchdog: obsolete collector health URL is gone"
# Hybrid render must not enable the clickhouse check by default.
assert_contains "$out10" 'enabled: false'$'\n''        id: clickhouse' \
  "watchdog: clickhouse check stays off in hybrid defaults"
# AUT-346: hybrid ClickStack egress + hostedExport.enabled=false honoured.
assert_env_value "$out10" neuraltrust-watchdog watchdog OTEL_EXPORTER_OTLP_ENDPOINT \
  'http://clickstack-egress-collector.default.svc.cluster.local:4318' \
  "watchdog hybrid: OTLP is signal-neutral ClickStack egress :4318"
assert_env_value "$out10" neuraltrust-watchdog watchdog OPENTELEMETRY_AUTH_TOKEN ABSENT \
  "watchdog hybrid: no hosted OPENTELEMETRY_AUTH_TOKEN"
assert_not_contains "$out10" 'name: neuraltrust-observability-token' \
  "hostedExport false: observability token Secret is omitted"
assert_not_contains "$out10" 'collector\.neuraltrust\.ai' \
  "hostedExport false: no collector.neuraltrust.ai default on watchdog path"

blue "==> Scenario 10e: watchdog telemetry.otlp.endpoint override wins"
out10e="$TMP/scenario-watchdog-otlp-override.yaml"
render_default "$out10e" \
  --set watchdog.enabled=true \
  --set watchdog.telemetry.otlp.endpoint=https://otel.example.com:4318 \
  --set watchdog.telemetry.otlp.headers='authorization=test-token'
assert_env_value "$out10e" neuraltrust-watchdog watchdog OTEL_EXPORTER_OTLP_ENDPOINT \
  'https://otel.example.com:4318' \
  "watchdog override: explicit otlp.endpoint wins over ClickStack default"
assert_env_value "$out10e" neuraltrust-watchdog watchdog OTEL_EXPORTER_OTLP_HEADERS \
  'authorization=test-token' \
  "watchdog override: explicit otlp.headers wins over collector secret mount"
assert_env_value "$out10e" neuraltrust-watchdog watchdog OPENTELEMETRY_AUTH_TOKEN ABSENT \
  "watchdog override: no hosted auth token alongside break-glass headers"

blue "==> Scenario 10b: Firewall follows the TrustGuard product gate"
out10b="$TMP/scenario-firewall-disabled.yaml"
render_default "$out10b" --set global.products.trustguard=false
assert_not_contains "$out10b" 'name: firewall$' \
  "trustguard off: Firewall gateway absent"
assert_not_contains "$out10b" 'name: prompt-moderation-worker' \
  "trustguard off: Firewall workers absent"
assert_not_contains "$out10b" 'name: firewall-secrets' \
  "trustguard off: Firewall Secret absent"
assert_not_contains "$out10b" 'NEURAL_TRUST_FIREWALL_BASE_URL' \
  "trustguard off: no Firewall client wiring"

blue "==> Scenario 10b2: Firewall v2.15 production worker module set"
out10b2="$TMP/scenario-firewall-workers.yaml"
render_default "$out10b2"
assert_contains "$out10b2" 'name: firewall$' \
  "firewall workers: gateway Deployment present"
assert_contains "$out10b2" 'name: toxicity-worker' \
  "firewall workers: toxicity present"
assert_contains "$out10b2" 'name: prompt-jailbreak-worker' \
  "firewall workers: prompt-jailbreak present"
assert_contains "$out10b2" 'name: prompt-moderation-worker' \
  "firewall workers: prompt-moderation present"
assert_contains "$out10b2" 'name: response-jailbreak-worker' \
  "firewall workers: response-jailbreak present"
assert_contains "$out10b2" 'name: indirect-prompt-injections-worker' \
  "firewall workers: IPI present"
assert_contains "$out10b2" 'src.workers.indirect_prompt_injections.app:app' \
  "firewall workers: IPI module arg"
assert_contains "$out10b2" 'INDIRECT_PROMPT_INJECTIONS_WORKER_URL: "http://indirect-prompt-injections-worker:80"' \
  "firewall workers: IPI worker URL in ConfigMap"
assert_not_contains "$out10b2" 'name: toolguard-worker' \
  "firewall workers: retired toolguard worker absent"
assert_not_contains "$out10b2" 'TOOLGUARD_WORKER_URL' \
  "firewall workers: TOOLGUARD_WORKER_URL absent"
assert_not_contains "$out10b2" 'src.workers.toolguard.app:app' \
  "firewall workers: retired toolguard module absent"

blue "==> Scenario 10c: hybrid has no in-cluster ClickStack; egress via sidecar"
out10c="$TMP/scenario-hybrid-clickstack-channels.yaml"
render_default "$out10c"
assert_not_contains "$out10c" 'name: clickstack-collector' \
  "hybrid: in-cluster ClickStack collector must not render"
assert_not_contains "$out10c" 'kind: StatefulSet' \
  "hybrid: ClickHouse StatefulSet must not render"
assert_contains "$out10c" 'name: clickstack-egress-collector' \
  "hybrid: local egress ClusterIP Service renders"
assert_contains "$out10c" 'name: clickstack-egress-collector'$'\n''        image:' \
  "hybrid: egress sidecar co-located on DataAgent"
assert_contains "$out10c" 'token_url: "http://127.0.0.1:9465/oauth/token"' \
  "hybrid: egress sidecar exchanges via DataAgent loopback broker"
assert_contains "$out10c" 'endpoint: "https://telemetry.neuraltrust.ai"' \
  "hybrid: egress sidecar exports to telemetry.neuraltrust.ai"
assert_contains "$out10c" 'http://clickstack-egress-collector.default.svc.cluster.local:4318/v1/logs' \
  "hybrid: apps send OTLP to local egress only"

blue "==> Scenario 10d: GPU Firewall workers (dataplane-gpu example shape)"
out10d="$TMP/scenario-firewall-gpu.yaml"
render_default "$out10d" \
  --set firewall.firewall.workerDefaults.image.repository=europe-west1-docker.pkg.dev/neuraltrust-app-prod/nt-docker/firewall-gpu \
  --set 'firewall.firewall.workerDefaults.resources.requests.nvidia\.com/gpu=1' \
  --set 'firewall.firewall.workerDefaults.resources.limits.nvidia\.com/gpu=1' \
  --set firewall.firewall.workerDefaults.hostIPC=true
assert_contains "$out10d" 'nvidia.com/gpu' \
  "gpu: Firewall workers request GPU resources"
assert_contains "$out10d" 'hostIPC: true' \
  "gpu: Firewall workers share host IPC for CUDA MPS"

blue "==> Scenario 10f: Firewall OTLP endpoint resolution"
# The chart used to default this to a NeuralTrust-internal collector namespace,
# which no customer cluster has. Enabling OTel without an endpoint must leave
# the variable unset rather than ship an address that cannot resolve.
out10f_fw="$TMP/scenario-firewall-otel-unset.yaml"
render_default "$out10f_fw" \
  --set firewall.firewall.config.otelEnabled=true
document_named "$out10f_fw" firewall-config "$TMP/firewall-config-unset.yaml"
assert_contains "$TMP/firewall-config-unset.yaml" 'OTEL_ENABLED: "true"' \
  "firewall otel: SDK gate is on"
assert_not_contains "$TMP/firewall-config-unset.yaml" 'OTEL_EXPORTER_OTLP_ENDPOINT' \
  "firewall otel: no endpoint resolves, so the key is omitted"
assert_not_contains "$out10f_fw" 'opentelemetry-collector.opentelemetry' \
  "firewall otel: retired collector namespace is not a default"

out10f_glob="$TMP/scenario-firewall-otel-umbrella.yaml"
render_default "$out10f_glob" \
  --set firewall.firewall.config.otelEnabled=true \
  --set firewall.firewall.config.otelExporterOtlpEndpoint=http://per-component:4318 \
  --set global.observability.collector.endpoint=http://umbrella:4318
document_named "$out10f_glob" firewall-config "$TMP/firewall-config-umbrella.yaml"
assert_contains "$TMP/firewall-config-umbrella.yaml" 'OTEL_EXPORTER_OTLP_ENDPOINT: "http://umbrella:4318"' \
  "firewall otel: umbrella endpoint overrides the per-component setting"

# ---------------------------------------------------------------------------
# 11. Positive hybrid product selection
# ---------------------------------------------------------------------------
blue "==> Scenario 11: hybrid with no product selected fails fast"
assert_render_fails "hybrid no-selection: requires at least one product" \
  "${HYBRID_NO_PRODUCTS[@]}"

blue "==> Scenario 11a: trustgate-only hybrid"
out11a="$TMP/scenario-trustgate-only.yaml"
render_product_slice "$out11a" -f "$CHART_DIR/values-trustgate.yaml.example" --set watchdog.enabled=true
assert_contains "$out11a" 'name: agentgateway-proxy' \
  "trustgate-only: proxy renders"
assert_contains "$out11a" 'name: dataagent$' \
  "trustgate-only: single DataAgent keeps stable name dataagent"
assert_not_contains "$out11a" 'name: trustguard-data-plane' \
  "trustgate-only: trustguard absent"
assert_not_contains "$out11a" 'TRUSTGUARD_BASE_URL:' \
  "trustgate-only: TRUSTGUARD_BASE_URL omitted"
assert_contains "$out11a" 'name: clickstack-egress-collector' \
  "trustgate-only: egress Service present"
assert_resource_count "$out11a" Service dataagent 1 "trustgate-only: health Service present"
assert_resource_count "$out11a" Service dataagent-trustguard 0 "trustgate-only: TrustGuard health Service absent"
assert_contains "$out11a" 'id: dataagent-trustgate-(readyz|deployment-health)' "trustgate-only: applicable watchdog checks render"
assert_not_contains "$out11a" 'id: dataagent-trustguard-(readyz|deployment-health)' "trustgate-only: TrustGuard watchdog checks omitted"
assert_env_value "$out11a" neuraltrust-watchdog watchdog OTEL_EXPORTER_OTLP_ENDPOINT \
  'http://clickstack-egress-collector.default.svc.cluster.local:4318' \
  "trustgate-only: watchdog OTLP via local egress :4318"
assert_env_value "$out11a" neuraltrust-watchdog watchdog OPENTELEMETRY_AUTH_TOKEN ABSENT \
  "trustgate-only: watchdog has no hosted auth token"

blue "==> Scenario 11b: trustguard-only hybrid"
out11b="$TMP/scenario-trustguard-only.yaml"
render_product_slice "$out11b" -f "$CHART_DIR/values-trustguard.yaml.example" --set watchdog.enabled=true
assert_contains "$out11b" 'name: trustguard-data-plane' \
  "trustguard-only: data-plane renders"
assert_contains "$out11b" 'name: dataagent-trustguard$' \
  "trustguard-only: fixed TrustGuard DataAgent name"
assert_not_contains "$out11b" 'name: agentgateway-proxy' \
  "trustguard-only: trustgate absent"
assert_contains "$out11b" 'name: firewall$' \
  "trustguard-only: Firewall follows TrustGuard"
assert_contains "$out11b" 'name: clickstack-egress-collector' \
  "trustguard-only: egress Service on primary DataAgent"
assert_resource_count "$out11b" Service dataagent 0 "trustguard-only: TrustGate health Service absent"
assert_resource_count "$out11b" Service dataagent-trustguard 1 "trustguard-only: health Service present"
assert_contains "$out11b" 'id: dataagent-trustguard-(readyz|deployment-health)' "trustguard-only: applicable watchdog checks render"
assert_not_contains "$out11b" 'id: dataagent-trustgate-(readyz|deployment-health)' "trustguard-only: TrustGate watchdog checks omitted"
assert_env_value "$out11b" neuraltrust-watchdog watchdog OTEL_EXPORTER_OTLP_ENDPOINT \
  'http://clickstack-egress-collector.default.svc.cluster.local:4318' \
  "trustguard-only: watchdog OTLP via local egress :4318"
assert_env_value "$out11b" neuraltrust-watchdog watchdog OPENTELEMETRY_AUTH_TOKEN ABSENT \
  "trustguard-only: watchdog has no hosted auth token"

blue "==> Scenario 11c: data-plane-only (red-teaming) hybrid — no DataAgent"
out11c="$TMP/scenario-red-teaming-only.yaml"
render_product_slice "$out11c" -f "$CHART_DIR/values-red-teaming.yaml.example" --set watchdog.enabled=true
assert_contains "$out11c" 'name: data-plane-api' \
  "red-teaming: data-plane-api renders"
assert_not_contains "$out11c" 'name: dataagent' \
  "red-teaming: no DataAgent"
assert_not_contains "$out11c" 'name: clickstack-egress-collector' \
  "red-teaming: no ClickStack egress"
assert_not_contains "$out11c" 'name: agentgateway-proxy' \
  "red-teaming: trustgate absent"
assert_not_contains "$out11c" 'name: trustguard-data-plane' \
  "red-teaming: trustguard absent"
assert_resource_count "$out11c" Service dataagent 0 "red-teaming: TrustGate health Service absent"
assert_resource_count "$out11c" Service dataagent-trustguard 0 "red-teaming: TrustGuard health Service absent"
assert_not_contains "$out11c" 'id: dataagent-(trustgate|trustguard)-(readyz|deployment-health)' "red-teaming: no orphan DataAgent watchdog checks"
# AUT-346: no egress → no fabricated OTLP default (override only).
assert_env_value "$out11c" neuraltrust-watchdog watchdog OTEL_EXPORTER_OTLP_ENDPOINT ABSENT \
  "red-teaming: watchdog has no default OTLP endpoint without egress"
assert_env_value "$out11c" neuraltrust-watchdog watchdog OPENTELEMETRY_AUTH_TOKEN ABSENT \
  "red-teaming: watchdog has no hosted auth token"

blue "==> Scenario 11d: positive slices compose pairwise and all together"
out11d1="$TMP/scenario-trustgate-trustguard.yaml"
render_product_slice "$out11d1" \
  -f "$CHART_DIR/values-trustgate.yaml.example" \
  -f "$CHART_DIR/values-trustguard.yaml.example" \
  --set watchdog.enabled=true
assert_contains "$out11d1" 'name: dataagent$' \
  "trustgate+trustguard: stable TrustGate DataAgent"
assert_contains "$out11d1" 'name: dataagent-trustguard$' \
  "trustgate+trustguard: fixed TrustGuard DataAgent"
assert_occurrences "$out11d1" '^  name: clickstack-egress-collector$' 1 \
  "trustgate+trustguard: exactly one egress Service"
assert_resource_count "$out11d1" Service dataagent 1 "trustgate+trustguard: TrustGate health Service renders once"
assert_resource_count "$out11d1" Service dataagent-trustguard 1 "trustgate+trustguard: TrustGuard health Service renders once"
for product in trustgate trustguard; do
  assert_contains "$out11d1" "id: dataagent-${product}-readyz" "trustgate+trustguard: ${product} readyz check renders"
  assert_contains "$out11d1" "id: dataagent-${product}-deployment-health" "trustgate+trustguard: ${product} deployment check renders"
done
assert_occurrences "$out11d1" '^        dryRun: true$' 4 "trustgate+trustguard: all DataAgent checks are explicit dry-run"
assert_occurrences "$out11d1" '^        actions: \[notify\.otlp, notify\.slack\]$' 4 "trustgate+trustguard: all DataAgent checks are notifier-only"

# Pairwise red-teaming combos are covered by 11a–c + all-products (11d4).
out11d4="$TMP/scenario-all-products.yaml"
render_product_slice "$out11d4" \
  -f "$CHART_DIR/values-red-teaming.yaml.example" \
  -f "$CHART_DIR/values-trustguard.yaml.example" \
  -f "$CHART_DIR/values-trustgate.yaml.example"
assert_contains "$out11d4" 'name: agentgateway-proxy' \
  "all products: TrustGate renders"
assert_contains "$out11d4" 'name: trustguard-data-plane' \
  "all products: TrustGuard renders"
assert_contains "$out11d4" 'name: data-plane-api' \
  "all products: data-plane-api renders"
assert_occurrences "$out11d4" '^  name: clickstack-egress-collector$' 1 \
  "all products: exactly one egress Service"

blue "==> Scenario 11e: external overlay without global.products still full stack"
out11e="$TMP/scenario-external-no-products.yaml"
helm template test "$CHART_DIR" --namespace default \
  -f "$CHART_DIR/values-external.yaml.example" > "$out11e"
validate_yaml "$out11e"
assert_contains "$out11e" 'name: agentgateway-admin' \
  "external no-products: AgentGateway admin renders"
assert_contains "$out11e" 'name: trustguard-control-plane' \
  "external no-products: TrustGuard control plane renders"
assert_contains "$out11e" 'name: data-plane-api' \
  "external no-products: data-plane-api renders"
assert_contains "$out11e" 'name: firewall$' \
  "external no-products: Firewall renders"

blue "==> Scenario 11f: global.saasRegion picks the SaaS behind a hybrid install"
# EU is the default, so an install that never sets the knob must render the
# historical hostnames byte-for-byte.
out11f_eu="$TMP/scenario-saas-region-eu.yaml"
render_product_slice "$out11f_eu" \
  -f "$CHART_DIR/values-trustgate.yaml.example" \
  -f "$CHART_DIR/values-trustguard.yaml.example" \
  --set watchdog.enabled=true
assert_contains "$out11f_eu" 'value: "agentgateway-configsync\.neuraltrust\.ai:443"' \
  "saasRegion default: TrustGate config-sync stays EU"
assert_contains "$out11f_eu" 'value: "trustguard-configsync\.neuraltrust\.ai:443"' \
  "saasRegion default: TrustGuard config-sync stays EU"
assert_contains "$out11f_eu" 'DATABRIDGE_ADDR: "databridge\.neuraltrust\.ai:443"' \
  "saasRegion default: DataBridge stays EU"
assert_contains "$out11f_eu" 'endpoint: "https://telemetry\.neuraltrust\.ai"' \
  "saasRegion default: ClickStack egress stays EU"

# One value moves config-sync, DataBridge and telemetry together — the bug was
# that each had to be overridden separately, so US installs silently kept EU.
out11f_us="$TMP/scenario-saas-region-us.yaml"
render_product_slice "$out11f_us" \
  -f "$CHART_DIR/values-trustgate.yaml.example" \
  -f "$CHART_DIR/values-trustguard.yaml.example" \
  --set watchdog.enabled=true \
  --set global.saasRegion=us
assert_contains "$out11f_us" 'value: "agentgateway-configsync\.us\.neuraltrust\.ai:443"' \
  "saasRegion us: TrustGate config-sync targets US"
assert_contains "$out11f_us" 'value: "agentgateway-configsync\.us\.neuraltrust\.ai"' \
  "saasRegion us: TrustGate config-sync SNI targets US"
assert_contains "$out11f_us" 'value: "trustguard-configsync\.us\.neuraltrust\.ai:443"' \
  "saasRegion us: TrustGuard config-sync targets US"
assert_contains "$out11f_us" 'DATABRIDGE_ADDR: "databridge\.us\.neuraltrust\.ai:443"' \
  "saasRegion us: DataBridge targets US"
assert_contains "$out11f_us" 'DATABRIDGE_SERVER_NAME: "databridge\.us\.neuraltrust\.ai"' \
  "saasRegion us: DataBridge SNI follows the address"
assert_contains "$out11f_us" 'endpoint: "https://telemetry\.us\.neuraltrust\.ai"' \
  "saasRegion us: ClickStack egress targets US"
assert_not_contains "$out11f_us" '(configsync|databridge|telemetry)\.neuraltrust\.ai' \
  "saasRegion us: no EU SaaS hostname survives anywhere in the render"
# AUT-346 regression guard: watchdog OTLP is in-cluster and must stay that way.
# The region reaches it through the egress sidecar, not through its own endpoint.
assert_env_value "$out11f_us" neuraltrust-watchdog watchdog OTEL_EXPORTER_OTLP_ENDPOINT \
  'http://clickstack-egress-collector.default.svc.cluster.local:4318' \
  "saasRegion us: watchdog OTLP stays in-cluster"
assert_env_value "$out11f_us" neuraltrust-watchdog watchdog OPENTELEMETRY_AUTH_TOKEN ABSENT \
  "saasRegion us: watchdog still has no hosted auth token"

# Per-endpoint overrides predate the region knob and must keep winning.
out11f_override="$TMP/scenario-saas-region-override.yaml"
render_product_slice "$out11f_override" \
  -f "$CHART_DIR/values-trustgate.yaml.example" \
  --set global.saasRegion=us \
  --set agentgateway.configSync.saasDomain=example.com \
  --set dataagent.databridge.addr=databridge.example.com:9443 \
  --set global.clickstack.egress.endpoint=https://telemetry.example.com
assert_contains "$out11f_override" 'value: "agentgateway-configsync\.example\.com:443"' \
  "saasRegion override: explicit saasDomain beats the region"
assert_contains "$out11f_override" 'DATABRIDGE_ADDR: "databridge\.example\.com:9443"' \
  "saasRegion override: explicit DataBridge address beats the region"
assert_contains "$out11f_override" 'DATABRIDGE_SERVER_NAME: "databridge\.example\.com"' \
  "saasRegion override: SNI derives from the overridden address"
assert_contains "$out11f_override" 'endpoint: "https://telemetry\.example\.com"' \
  "saasRegion override: explicit egress endpoint beats the region"

assert_render_fails_with 'global.saasRegion must be "eu" or "us"' \
  "saasRegion: an unknown region fails the render instead of quietly staying EU" \
  --set global.saasRegion=emea

# ---------------------------------------------------------------------------
# Shared platform Secret (`platform-secrets`)
#
# The chart used to duplicate cross-service credentials by hand, and two
# independent resolveSecret calls cannot agree on a freshly generated value
# (lookup is empty during install). So the invariant under test is that every
# migrated key has exactly ONE source: no workload may still read a migrated
# key from its legacy per-service Secret, and every platform-secrets reference
# must resolve to a key the Secret actually carries.
# ---------------------------------------------------------------------------
assert_shared_secret_wiring() {
  local file="$1" label="$2"
  if ! ruby -ryaml -rbase64 -e '
    docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
    # logical key => [legacy Secret name, legacy key]
    reg = {
      "SERVER_SECRET_KEY" => ["agentgateway-secrets", "SERVER_SECRET_KEY"],
      "ADMIN_JWT_SECRET" => ["trustguard-secrets", "ADMIN_JWT_SECRET"],
      "TRUSTGUARD_TOKEN_SIGNING_SECRET" => ["trustguard-secrets", "TRUSTGUARD_TOKEN_SIGNING_SECRET"],
      "REDIS_EVENTS_SECRET" => ["trustguard-secrets", "REDIS_EVENTS_SECRET"],
      "AUTH_JWT_HS256_SECRET" => ["datacore-secrets", "AUTH_JWT_HS256_SECRET"],
      "AUTH_JWT_SECRET" => ["alertengine-secrets", "AUTH_JWT_SECRET"],
      "APP_ENCRYPTION_KEY" => ["alertengine-secrets", "APP_ENCRYPTION_KEY"],
      "TRUSTLENS_JWT_SECRET" => ["trustlens-secrets", "JWT_SECRET"],
      "ENCRYPTION_KEYSET" => ["trustlens-secrets", "ENCRYPTION_KEYSET"],
      "JWT_SECRET" => ["firewall-secrets", "JWT_SECRET"],
      "DATA_PLANE_JWT_SECRET" => ["data-plane-jwt-secret", "DATA_PLANE_JWT_SECRET"],
      "CONTROL_PLANE_JWT_SECRET" => ["control-plane-secrets", "CONTROL_PLANE_JWT_SECRET"],
      "AUTH_SECRET" => ["control-plane-secrets", "AUTH_SECRET"],
      "MODEL_SCANNER_SECRET" => ["control-plane-secrets", "MODEL_SCANNER_SECRET"],
    }
    shared = docs.find { |d| d["kind"] == "Secret" && d.dig("metadata", "name") == "platform-secrets" }
    abort "platform-secrets not rendered" if shared.nil?
    data = shared["data"] || {}
    errors = []
    refs = 0
    docs.each do |d|
      next unless %w[Deployment StatefulSet DaemonSet].include?(d["kind"])
      name = d.dig("metadata", "name")
      pod = d.dig("spec", "template", "spec") || {}
      ((pod["containers"] || []) + (pod["initContainers"] || [])).each do |c|
        seen = Hash.new(0)
        (c["env"] || []).each do |e|
          seen[e["name"]] += 1
          skr = e.dig("valueFrom", "secretKeyRef")
          next if skr.nil?
          if skr["name"] == "platform-secrets"
            refs += 1
            # An optional ref to an absent key is how an unconfigured
            # integration is expressed, so only required refs must resolve.
            unless data.key?(skr["key"]) || skr["optional"]
              errors << "#{name}/#{c["name"]} #{e["name"]} -> platform-secrets/#{skr["key"]} which is absent"
            end
          else
            reg.each do |logical, (ln, lk)|
              if skr["name"] == ln && skr["key"] == lk
                errors << "#{name}/#{c["name"]} #{e["name"]} still reads migrated #{logical} from #{ln}"
              end
            end
          end
        end
        seen.each { |k, v| errors << "#{name}/#{c["name"]} duplicate env #{k} (x#{v})" if v > 1 }
      end
    end
    # Documented invariants that must survive a fresh install, where each key
    # would otherwise be generated independently.
    # An alias is only present when the install shape needs it, so compare the
    # pair only when both were emitted.
    [["AUTH_SECRET", "NEXTAUTH_SECRET"]].each do |a, b|
      next unless data.key?(a) && data.key?(b)
      errors << "#{a} != #{b}" if data[a] != data[b]
    end
    errors << "no workload references platform-secrets" if refs.zero?
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

# Key presence inside the platform-secrets document specifically. A plain grep
# also matches the legacy Secrets, which keep dual-emitting migrated keys for
# one release, so it cannot tell the two sources apart.
blue "==> Scenario 12: shared platform Secret"
out12ext="$TMP/scenario-shared-secret-external.yaml"
render_default "$out12ext" --set global.deploymentMode=external
assert_contains "$out12ext" '^  name: platform-secrets$' \
  "external: platform-secrets renders"
assert_shared_secret_wiring "$out12ext" \
  "external: every migrated key has a single source in platform-secrets"

out12hyb="$TMP/scenario-shared-secret-hybrid.yaml"
render_default "$out12hyb" --set global.deploymentMode=hybrid
assert_contains "$out12hyb" '^  name: platform-secrets$' \
  "hybrid: platform-secrets renders"
assert_shared_secret_wiring "$out12hyb" \
  "hybrid: every migrated key has a single source in platform-secrets"

# control-plane-app used to reach into seven Secrets to build its env.
# A hybrid install must not carry credentials only the hosted control plane
# reads. Keys already present in a live Secret are preserved by a `lookup` that
# render tests cannot exercise, so only the gating is asserted here.
# AUTH_JWT_SECRET / APP_ENCRYPTION_KEY follow the alertengine shape (AUT-382):
# present in external with alertengine.enabled (default), absent in hybrid.
blue "==> Scenario 12a: keys are gated to the install shape"
assert_platform_keys "$out12hyb" absent \
  "hybrid: platform-secrets omits control-plane-only key" \
  CONTROL_PLANE_JWT_SECRET AUTH_SECRET NEXTAUTH_SECRET \
  AUTH_JWT_HS256_SECRET AUTH_JWT_SECRET APP_ENCRYPTION_KEY
assert_platform_keys "$out12ext" present \
  "external: platform-secrets carries" \
  CONTROL_PLANE_JWT_SECRET AUTH_SECRET NEXTAUTH_SECRET \
  AUTH_JWT_HS256_SECRET AUTH_JWT_SECRET APP_ENCRYPTION_KEY

# AlertEngine off ⇒ its credentials must not be minted (AUT-382).
out12aeoff="$TMP/scenario-shared-secret-alertengine-off.yaml"
render_default "$out12aeoff" --set global.deploymentMode=external --set alertengine.enabled=false
assert_platform_keys "$out12aeoff" absent \
  "alertengine disabled: platform-secrets omits" \
  AUTH_JWT_SECRET APP_ENCRYPTION_KEY

# An opt-in subchart and a retired code path must not mint credentials nobody
# reads, in either mode. External deploys the full stack, so the install shape
# alone cannot gate these.
assert_platform_keys "$out12ext" absent \
  "external: platform-secrets omits unused" \
  TRUSTLENS_JWT_SECRET ENCRYPTION_KEYSET TRUSTGATE_JWT_SECRET
assert_platform_keys "$out12hyb" absent \
  "hybrid: platform-secrets omits unused" \
  TRUSTLENS_JWT_SECRET ENCRYPTION_KEYSET TRUSTGATE_JWT_SECRET

# Enabling TrustLens is what brings its credentials in, not the deployment mode.
out12tl="$TMP/scenario-shared-secret-trustlens-on.yaml"
render_default "$out12tl" --set global.deploymentMode=hybrid \
  --set trustlens.enabled=true --set trustlens.image.tag=v0.1.1
assert_platform_keys "$out12tl" present \
  "trustlens enabled: platform-secrets carries" \
  TRUSTLENS_JWT_SECRET ENCRYPTION_KEYSET
assert_shared_secret_wiring "$out12tl" \
  "trustlens enabled: every migrated key has a single source in platform-secrets"

# MODEL_SCANNER_SECRET is adopt-only: an empty legacy value must stay empty
# rather than becoming a generated credential for a peer that is not deployed.
assert_platform_key "$out12ext" absent MODEL_SCANNER_SECRET \
  "external: platform-secrets does not invent MODEL_SCANNER_SECRET"
out12ms="$TMP/scenario-shared-secret-model-scanner.yaml"
render_default "$out12ms" --set global.deploymentMode=external \
  --set global.platformSecret.values.MODEL_SCANNER_SECRET=ms-pinned
assert_platform_key "$out12ms" present MODEL_SCANNER_SECRET \
  "external: an operator-supplied MODEL_SCANNER_SECRET is still emitted"
assert_contains "$out12ms" 'bXMtcGlubmVk' \
  "external: the pinned MODEL_SCANNER_SECRET value reaches platform-secrets"
# Disabling a product drops the credentials only that product reads.
out12tgoff="$TMP/scenario-shared-secret-trustguard-off.yaml"
render_default "$out12tgoff" --set global.deploymentMode=hybrid --set global.products.trustguard=false
assert_platform_keys "$out12tgoff" absent \
  "hybrid without TrustGuard: platform-secrets omits" \
  ADMIN_JWT_SECRET TRUSTGUARD_TOKEN_SIGNING_SECRET REDIS_EVENTS_SECRET JWT_SECRET
assert_platform_key "$out12tgoff" present SERVER_SECRET_KEY \
  "hybrid without TrustGuard: TrustGate credentials still present"
# Gating a product off must not leave a consumer pointing at a key nobody emits.
assert_shared_secret_wiring "$out12tgoff" \
  "hybrid without TrustGuard: every migrated key has a single source in platform-secrets"

# autoGenerateSecrets=false means the chart mints nothing. Consumers must fall
# back to the legacy Secrets rather than reference a Secret that is never created.
out12nogen="$TMP/scenario-shared-secret-nogen.yaml"
render_default "$out12nogen" --set global.deploymentMode=external --set global.autoGenerateSecrets=false
assert_not_contains "$out12nogen" '^  name: platform-secrets$' \
  "autoGenerateSecrets=false: shared Secret not rendered"
assert_not_contains "$out12nogen" 'name: "platform-secrets"' \
  "autoGenerateSecrets=false: no workload references the shared Secret"
assert_contains "$out12nogen" 'name: "control-plane-secrets"' \
  "autoGenerateSecrets=false: refs fall back to the legacy Secret"

# An operator override through extraEnv must win without producing a duplicate
# env name, which would break the strategic merge patch on the next upgrade.
out12dup="$TMP/scenario-shared-secret-extraenv-override.yaml"
render_default "$out12dup" --set global.deploymentMode=external \
  --set 'trustguard.dataPlane.extraEnv[0].name=ADMIN_JWT_SECRET' \
  --set 'trustguard.dataPlane.extraEnv[0].value=operator-wins' \
  --set 'agentgateway.controlPlane.extraEnv[0].name=SERVER_SECRET_KEY' \
  --set 'agentgateway.controlPlane.extraEnv[0].value=operator-wins'
assert_shared_secret_wiring "$out12dup" \
  "extraEnv override: no duplicate env names and every ref still resolves"
assert_contains "$out12dup" 'value: operator-wins' \
  "extraEnv override: the operator value reaches the container"

# Watchdog usage export authenticates against both APIs, so it must read the
# same signing keys they verify with — including in hybrid, where the shared
# Secret would not otherwise carry the control-plane key.
out12wd="$TMP/scenario-shared-secret-watchdog.yaml"
render_default "$out12wd" --set watchdog.enabled=true --set watchdog.usageExport.enabled=true
assert_shared_secret_wiring "$out12wd" \
  "hybrid + watchdog usage export: every ref resolves to an emitted key"
for key in CONTROL_PLANE_JWT_SECRET DATA_PLANE_JWT_SECRET; do
  assert_platform_key "$out12wd" present "${key}" \
    "hybrid + watchdog usage export: platform-secrets carries ${key}"
done
out12wdoff="$TMP/scenario-shared-secret-watchdog-override.yaml"
render_default "$out12wdoff" --set watchdog.enabled=true --set watchdog.usageExport.enabled=true \
  --set watchdog.usageExport.jwtSecret.existingSecret=my-watchdog-secret
assert_contains "$out12wdoff" 'name: my-watchdog-secret' \
  "watchdog: an operator-supplied Secret still overrides the shared one"

# An alias key exists because two names must hold one value. Pinning the alias
# instead of its target cannot be honoured, so it must fail loudly rather than
# be silently overwritten by the mirror.
assert_render_fails "pinning an alias key is rejected with a pointer to its target" \
  --set global.deploymentMode=external \
  --set global.platformSecret.values.NEXTAUTH_SECRET=pinned-alias

# A credential path that accepts either a string or a {secretName, secretKey}
# map must not reach b64enc as a map, which would abort the whole render.
out12map="$TMP/scenario-shared-secret-map-value.yaml"
render_default "$out12map" --set global.deploymentMode=external \
  --set-json 'global.platformSecret.values.MODEL_SCANNER_SECRET={"secretName":"ms","secretKey":"k"}'
assert_platform_key "$out12map" absent MODEL_SCANNER_SECRET \
  "a map-shaped credential is ignored rather than aborting the render"

# AUTH_SECRET_KEY encrypts SSO client secrets and SMTP credentials at rest. The
# app has a committed default, so an install already running on that default has
# ciphertext bound to it: generating a new key on upgrade would make those rows
# undecryptable. Fresh install gets one, upgrade does not.
blue "==> Scenario 12f: AUTH_SECRET_KEY is generated on install only"
assert_platform_key "$out12ext" present AUTH_SECRET_KEY \
  "external install: platform-secrets carries AUTH_SECRET_KEY"
out12askup="$TMP/scenario-shared-secret-authsecretkey-upgrade.yaml"
render_default "$out12askup" --set global.deploymentMode=external --is-upgrade
assert_platform_key "$out12askup" absent AUTH_SECRET_KEY \
  "external upgrade: AUTH_SECRET_KEY is not generated, so nothing already encrypted breaks"
out12askpin="$TMP/scenario-shared-secret-authsecretkey-pinned.yaml"
render_default "$out12askpin" --set global.deploymentMode=external --is-upgrade \
  --set global.platformSecret.values.AUTH_SECRET_KEY=operator-adopted
assert_platform_key "$out12askpin" present AUTH_SECRET_KEY \
  "external upgrade: an operator can still adopt AUTH_SECRET_KEY deliberately"
# It signs nothing — AUTH_SECRET does. Sharing one value would be key reuse.
ruby -ryaml -e '
  docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
  d = docs.find { |x| x["kind"] == "Secret" && x.dig("metadata", "name") == "platform-secrets" }
  data = d["data"] || {}
  abort "AUTH_SECRET or AUTH_SECRET_KEY missing" unless data["AUTH_SECRET"] && data["AUTH_SECRET_KEY"]
  abort "AUTH_SECRET_KEY reuses the session signing key" if data["AUTH_SECRET"] == data["AUTH_SECRET_KEY"]
' "$out12ext" || { red "FAIL: AUTH_SECRET_KEY must not equal AUTH_SECRET"; exit 1; }
green "ok  - external: AUTH_SECRET_KEY is a distinct key from AUTH_SECRET"

# MCP OAuth is on by default in external. A signing key is always available because
# the chart generates one through a pre-install hook when nothing else provides it —
# Helm's own templating cannot, since it emits PKCS#1 while the app parses PKCS#8,
# and without a stable key each replica signs with its own ephemeral one. The gate
# stays three-state: unset means auto, true means required, false means never.
blue "==> Scenario 12g: MCP OAuth follows the signing key, not intent alone"
# The signing key is opaque to the chart; only the app parses it, so a placeholder
# is enough to prove the gate and the wiring.
mcpkey="pem-placeholder"
# Nothing supplied: the generator covers the key, so the feature is simply on.
assert_platform_key "$out12ext" present MCP_OAUTH_CLIENT_SECRET \
  "external defaults: MCP OAuth is on with no operator action"
# The generated key lives in its own hook-owned Secret, never in platform-secrets.
assert_platform_key "$out12ext" absent MCP_OAUTH_SIGNING_KEY \
  "external defaults: the generated key stays out of platform-secrets"
assert_contains "$out12ext" 'name: "mcp-oauth-signing"' \
  "external defaults: the app reads the generated signing key"
# Default-on: external plus a key, and nobody had to set the flag.
out12mcp="$TMP/scenario-mcp-oauth-on.yaml"
render_default "$out12mcp" --set global.deploymentMode=external \
  --set global.platformSecret.values.MCP_OAUTH_SIGNING_KEY="$mcpkey"
assert_platform_key "$out12mcp" present MCP_OAUTH_CLIENT_SECRET \
  "auto with a signing key: MCP OAuth switches on without global.mcpOAuth.enabled"
assert_platform_key "$out12mcp" present MCP_OAUTH_SIGNING_KEY \
  "auto with a signing key: the operator-supplied key is emitted"
# Adopted verbatim, never regenerated: a chart-invented value would not parse.
ruby -ryaml -rbase64 -e '
  docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
  s = docs.find { |d| d["kind"] == "Secret" && d.dig("metadata", "name") == "platform-secrets" }
  abort "platform-secrets not rendered" if s.nil?
  got = Base64.decode64(s.fetch("data").fetch("MCP_OAUTH_SIGNING_KEY"))
  abort "signing key was not adopted verbatim: #{got.inspect}" unless got == ARGV.fetch(1)
' "$out12mcp" "$mcpkey" || { red "FAIL: the signing key must be adopted, not generated"; exit 1; }
green "ok  - the signing key is adopted verbatim, never generated"
# An operator key makes the generator redundant; running it anyway would leave a
# second key nobody reads.
assert_not_contains "$out12mcp" 'component: mcp-signing-key' \
  "an operator-supplied key stands the generator down"
assert_contains "$out12mcp" 'name: "platform-secrets"' \
  "an operator-supplied key is read from platform-secrets, not the generated one"
# Intent without the material is a misconfiguration, not a silent no-op: half the
# logins would fail JWKS verification across replicas. Only reachable by refusing
# the generator, since otherwise the chart always has a key.
assert_render_fails "mcpOAuth=true with no key and no generator fails loudly" \
  --set global.deploymentMode=external \
  --set global.mcpOAuth.generateSigningKey=false \
  --set global.mcpOAuth.enabled=true
# An explicit false still wins over an available key.
out12mcpoff="$TMP/scenario-mcp-oauth-forced-off.yaml"
render_default "$out12mcpoff" --set global.deploymentMode=external \
  --set global.mcpOAuth.enabled=false \
  --set global.platformSecret.values.MCP_OAUTH_SIGNING_KEY="$mcpkey"
assert_not_contains "$out12mcpoff" 'MCP_DEFAULT_IDP_|name: MCP_OAUTH_CLIENT_ID' \
  "explicit false with a key present: MCP OAuth stays off"
assert_platform_key "$out12mcpoff" absent MCP_OAUTH_CLIENT_SECRET \
  "explicit false with a key present: no client secret is generated"
assert_shared_secret_wiring "$out12mcp" \
  "mcpOAuth on: every ref still resolves to an emitted key"
# One value, two env names, and one issuer both sides resolve identically: a
# mismatch on either would surface only as a failed login at request time.
ruby -ryaml -e '
  docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
  def env_of(docs, name)
    d = docs.find { |x| x["kind"] == "Deployment" && x.dig("metadata", "name") == name }
    abort "#{name} not rendered" if d.nil?
    (d.dig("spec", "template", "spec", "containers") || []).flat_map { |c| c["env"] || [] }
  end
  app = env_of(docs, "control-plane-app")
  mcp = env_of(docs, "agentgateway-mcp")
  app_ref = app.find { |e| e["name"] == "MCP_OAUTH_CLIENT_SECRET" }
  mcp_ref = mcp.find { |e| e["name"] == "MCP_DEFAULT_IDP_CLIENT_SECRET" }
  abort "client secret not wired on both sides" if app_ref.nil? || mcp_ref.nil?
  a = app_ref.dig("valueFrom", "secretKeyRef")
  b = mcp_ref.dig("valueFrom", "secretKeyRef")
  unless a && b && a["name"] == b["name"] && a["key"] == b["key"]
    abort "client secret sources differ: #{a.inspect} vs #{b.inspect}"
  end
  app_iss = app.find { |e| e["name"] == "MCP_OAUTH_ISSUER" }&.fetch("value", nil)
  mcp_iss = mcp.find { |e| e["name"] == "MCP_DEFAULT_IDP_ISSUER" }&.fetch("value", nil)
  abort "issuer missing on one side: #{app_iss.inspect} vs #{mcp_iss.inspect}" if app_iss.nil? || mcp_iss.nil?
  abort "issuers differ: #{app_iss} vs #{mcp_iss}" unless app_iss == mcp_iss
  # Only the MCP plane brokers logins; the others must not advertise an IdP.
  %w[agentgateway-admin agentgateway-proxy].each do |name|
    leaked = env_of(docs, name).map { |e| e["name"] }.grep(/^MCP_DEFAULT_IDP/)
    abort "#{name} carries #{leaked.join(", ")}" unless leaked.empty?
  end
' "$out12mcp" || { red "FAIL: MCP OAuth wiring is not consistent across services"; exit 1; }
green "ok  - mcpOAuth on: app and TrustGate share one client secret and one issuer"
# Empty allowlist means the app accepts a callback on any https origin.
assert_contains "$out12mcp" 'name: MCP_OAUTH_ALLOWED_REDIRECT_HOSTS' \
  "mcpOAuth on: the redirect-host allowlist is always set"
# With no domain there is neither a derivable issuer nor a derivable allowlist. Auto
# resolves to off, which is the point of the three-state gate; an explicit enable
# must still refuse rather than wire a login that cannot complete.
out12nodomain="$TMP/scenario-mcp-oauth-no-domain.yaml"
render_default "$out12nodomain" --set global.deploymentMode=external --set global.domain= \
  --set global.platformSecret.values.MCP_OAUTH_SIGNING_KEY="$mcpkey"
assert_not_contains "$out12nodomain" 'MCP_DEFAULT_IDP_|name: MCP_OAUTH_CLIENT_ID' \
  "no domain: auto leaves MCP OAuth off even with a signing key present"
assert_render_fails "mcpOAuth without a resolvable issuer fails loudly when required" \
  --set global.deploymentMode=external \
  --set global.platformSecret.values.MCP_OAUTH_SIGNING_KEY="$mcpkey" \
  --set global.mcpOAuth.enabled=true \
  --set global.domain=
# Hybrid deploys no control-plane app, so there is no authorization server to
# point at. Refuse rather than hand TrustGate an issuer nobody serves.
assert_render_fails "mcpOAuth is rejected in hybrid, where the app is the hosted platform" \
  --set global.deploymentMode=hybrid \
  --set global.mcpOAuth.enabled=true
assert_platform_key "$out12hyb" absent MCP_OAUTH_CLIENT_SECRET \
  "hybrid: platform-secrets omits the MCP OAuth client secret"
assert_not_contains "$out12hyb" 'MCP_DEFAULT_IDP_' \
  "hybrid: agentgateway carries no MCP default IdP env"
# Auto must not fire in hybrid just because a key happens to be present: the
# authorization server is the hosted platform, which never saw this client secret.
out12hybkey="$TMP/scenario-mcp-oauth-hybrid-key.yaml"
render_default "$out12hybkey" --set global.deploymentMode=hybrid \
  --set global.platformSecret.values.MCP_OAUTH_SIGNING_KEY="$mcpkey"
assert_not_contains "$out12hybkey" 'MCP_DEFAULT_IDP_|name: MCP_OAUTH_CLIENT_ID' \
  "hybrid with a signing key present: auto still leaves MCP OAuth off"
assert_platform_key "$out12hybkey" absent MCP_OAUTH_CLIENT_SECRET \
  "hybrid with a signing key present: no client secret is generated"

# The signing key generator exists so a fresh external install needs no operator
# step. It must reuse an image the install already pulls: some operators mirror
# their own registry or run under a vulnerability allowlist, where an extra image
# is a real cost.
blue "==> Scenario 12h: the signing key generator is self-contained"
ruby -ryaml -e '
  docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
  hook = docs.select { |d| d.dig("metadata", "labels", "app.kubernetes.io/component") == "mcp-signing-key" }
  kinds = hook.map { |d| d["kind"] }.sort
  want = %w[Job Role RoleBinding ServiceAccount]
  abort "hook bundle is #{kinds.inspect}, want #{want.inspect}" unless kinds == want
  hook.each do |d|
    ann = d.dig("metadata", "annotations") || {}
    unless ann["helm.sh/hook"] == "pre-install,pre-upgrade"
      abort "#{d["kind"]} is not a pre-install,pre-upgrade hook: #{ann["helm.sh/hook"].inspect}"
    end
  end
  # RBAC must exist before the Job that uses it.
  weight = ->(k) { hook.find { |d| d["kind"] == k }.dig("metadata", "annotations", "helm.sh/hook-weight").to_i }
  abort "the Job is not ordered after its RBAC" unless weight.call("Role") < weight.call("Job")

  job = hook.find { |d| d["kind"] == "Job" }
  app = docs.find { |d| d["kind"] == "Deployment" && d.dig("metadata", "name") == "control-plane-app" }
  app_image = app.dig("spec", "template", "spec", "containers").find { |c| c["name"] == "app" }.fetch("image")
  job_image = job.dig("spec", "template", "spec", "containers", 0).fetch("image")
  abort "the Job pulls #{job_image}, not the app image #{app_image}" unless job_image == app_image

  # A generator that rewrote an existing key would invalidate live access tokens.
  script = job.dig("spec", "template", "spec", "containers", 0, "command").last
  abort "the generator does not check for an existing key" unless script.include?("already present")
  abort "the generator does not produce PKCS#8" unless script.include?("pkcs8")
  # On IPv6 single-stack, KUBERNETES_SERVICE_HOST is a bare literal: unparsable
  # as a URL host, and unmatchable against the certificate SAN even bracketed.
  # The Job then exhausts its backoffLimit and fails the release.
  abort "the generator dials the apiserver by IP instead of DNS" \
    if script.include?("process.env.KUBERNETES_SERVICE_HOST")
  abort "the generator does not dial kubernetes.default.svc" \
    unless script.include?("https://kubernetes.default.svc:")

  role = hook.find { |d| d["kind"] == "Role" }
  named = role["rules"].select { |r| r["resourceNames"] }
  abort "no rule is scoped to a single Secret" if named.empty?
  named.each do |r|
    abort "a name-scoped rule reaches beyond the generated Secret: #{r["resourceNames"].inspect}" \
      unless r["resourceNames"] == ["mcp-oauth-signing"]
  end
  # `create` cannot be name-scoped in RBAC, but nothing else may be unscoped.
  role["rules"].reject { |r| r["resourceNames"] }.each do |r|
    abort "an unscoped rule grants #{r["verbs"].inspect}, only create is acceptable" unless r["verbs"] == ["create"]
  end
  abort "the Role reaches outside the core API group" unless role["rules"].all? { |r| r["apiGroups"] == [""] }
  abort "the Role touches something other than secrets" unless role["rules"].all? { |r| r["resources"] == ["secrets"] }
' "$out12ext" || { red "FAIL: the signing key generator is not correctly scoped"; exit 1; }
green "ok  - the generator reuses the app image and can write only its own Secret"

# `enabled` is read by this helper family and by validate-values. A raw bool test
# and Go truthiness disagree for a string, and a Flux HelmRelease sourcing values
# from a ConfigMap makes every value a string — so a string-typed flag must mean the
# same thing everywhere, or disabling the feature turns it on.
blue "==> Scenario 12i: the gate reads the same way however enabled is typed"
out12strfalse="$TMP/scenario-mcp-oauth-string-false.yaml"
render_default "$out12strfalse" --set global.deploymentMode=external \
  --set-string global.mcpOAuth.enabled=false
assert_not_contains "$out12strfalse" 'MCP_DEFAULT_IDP_|name: MCP_OAUTH_CLIENT_ID' \
  'enabled="false" as a string disables the feature, as a bool would'
assert_not_contains "$out12strfalse" 'component: mcp-signing-key' \
  'enabled="false" as a string also stands the generator down'
# The same string in hybrid must not be read as intent to enable, which would
# reject the install for turning the feature off.
out12strhyb="$TMP/scenario-mcp-oauth-string-false-hybrid.yaml"
render_default "$out12strhyb" --set global.deploymentMode=hybrid \
  --set-string global.mcpOAuth.enabled=false
assert_contains "$out12strhyb" '^  name: platform-secrets$' \
  'hybrid with enabled="false" as a string still renders'
# An explicit string true must be honoured as intent, so it still fails loudly.
assert_render_fails 'enabled="true" as a string is honoured as required' \
  --set global.deploymentMode=external \
  --set global.mcpOAuth.generateSigningKey=false \
  --set-string global.mcpOAuth.enabled=true
# Anything else is a typo, not a third state to guess at.
assert_render_fails 'a non-boolean enabled is rejected rather than guessed at' \
  --set global.deploymentMode=external \
  --set-string global.mcpOAuth.enabled=maybe

# Both sides read one client secret from whichever Secret secretRef resolves to.
# When the shared Secret is out of play those refs land on legacy Secrets the chart
# never writes this key into, and since they are optional the env is simply absent:
# the login fails at request time with nothing pointing at the cause.
blue "==> Scenario 12j: MCP OAuth needs a Secret that actually carries the client secret"
# Two representative undeliverable shapes (opt-out vs preserve); other flags share the gate.
for flag in global.platformSecret.enabled=false global.preserveExistingSecrets=true; do
  out12nodel="$TMP/scenario-mcp-oauth-undeliverable-${flag%%=*}.yaml"
  render_default "$out12nodel" --set global.deploymentMode=external --set "$flag"
  assert_not_contains "$out12nodel" 'MCP_DEFAULT_IDP_|name: MCP_OAUTH_CLIENT_ID' \
    "${flag}: MCP OAuth stays off rather than half-wired"
  assert_not_contains "$out12nodel" 'component: mcp-signing-key' \
    "${flag}: no signing key is minted for a login that cannot complete"
  assert_render_fails "${flag}: an explicit enable is refused with guidance" \
    --set global.deploymentMode=external --set "$flag" \
    --set global.mcpOAuth.enabled=true
done

# An empty allowlist is not merely unset: the app then accepts an OAuth callback on
# ANY https origin, handing the authorization code to whoever asks. It was possible
# to reach that state with an explicit issuer and no domain.
blue "==> Scenario 12k: MCP OAuth refuses to run without a callback allowlist"
out12noallow="$TMP/scenario-mcp-oauth-no-allowlist.yaml"
render_default "$out12noallow" --set global.deploymentMode=external --set global.domain= \
  --set global.mcpOAuth.issuer=https://console.example.com/api/mcp/oauth
assert_not_contains "$out12noallow" 'MCP_DEFAULT_IDP_|name: MCP_OAUTH_CLIENT_ID' \
  "an issuer without a derivable allowlist leaves MCP OAuth off"
assert_render_fails "an explicit enable without an allowlist is refused" \
  --set global.deploymentMode=external --set global.domain= \
  --set global.mcpOAuth.issuer=https://console.example.com/api/mcp/oauth \
  --set global.mcpOAuth.enabled=true
# Supplying one explicitly is the documented way out, with no domain at all.
out12allow="$TMP/scenario-mcp-oauth-explicit-allowlist.yaml"
render_default "$out12allow" --set global.deploymentMode=external --set global.domain= \
  --set global.mcpOAuth.issuer=https://console.example.com/api/mcp/oauth \
  --set 'global.mcpOAuth.allowedRedirectHosts=https://*.mcp.example.com'
assert_contains "$out12allow" 'name: MCP_OAUTH_ALLOWED_REDIRECT_HOSTS' \
  "an explicit allowlist enables the feature without global.domain"

# The issuer is derived as app.<domain> because a subchart cannot read a sibling's
# values. An install serving the app elsewhere would advertise an issuer nobody
# serves, and default-on means the operator never opts into finding out.
assert_render_fails "a custom app host without an explicit issuer is refused" \
  --set global.deploymentMode=external \
  --set 'control-plane-app.controlPlane.components.app.host=console.acme.test'
out12host="$TMP/scenario-mcp-oauth-custom-host.yaml"
render_default "$out12host" --set global.deploymentMode=external \
  --set 'control-plane-app.controlPlane.components.app.host=console.acme.test' \
  --set global.mcpOAuth.issuer=https://console.acme.test/api/mcp/oauth
assert_contains "$out12host" 'https://console.acme.test/api/mcp/oauth' \
  "a custom app host works once the issuer is explicit"

# The generator's premise is that it costs no new image: if the app can be pulled,
# so can the Job. That must survive a mirrored registry and operator pull secrets,
# where reaching for a different image would fail with ImagePullBackOff mid-upgrade.
out12reg="$TMP/scenario-mcp-generator-mirrored-registry.yaml"
render_default "$out12reg" --set global.deploymentMode=external \
  --set global.imageRegistry=registry.internal.example.com/nt \
  --set 'control-plane-app.imagePullSecrets=mirror-creds' \
  --set 'control-plane-app.controlPlane.components.app.image.pullPolicy=Always'
ruby -ryaml -e '
  docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
  app = docs.find { |d| d["kind"] == "Deployment" && d.dig("metadata", "name") == "control-plane-app" }
  job = docs.find { |d| d["kind"] == "Job" && d.dig("metadata", "labels", "app.kubernetes.io/component") == "mcp-signing-key" }
  abort "the generator Job is not rendered" if job.nil?
  app_c = app.dig("spec", "template", "spec", "containers").find { |c| c["name"] == "app" }
  job_c = job.dig("spec", "template", "spec", "containers", 0)
  abort "the Job pulls #{job_c["image"]}, the app pulls #{app_c["image"]}" unless job_c["image"] == app_c["image"]
  abort "the mirrored registry was not applied: #{job_c["image"]}" unless job_c["image"].start_with?("registry.internal.example.com/nt/")
  pull = ->(d) { (d.dig("spec", "template", "spec", "imagePullSecrets") || []).map { |s| s["name"] } }
  abort "pull secrets differ: #{pull.call(job).inspect} vs #{pull.call(app).inspect}" unless pull.call(job) == pull.call(app)
  abort "the operator pull secret did not reach the Job: #{pull.call(job).inspect}" unless pull.call(job) == ["mirror-creds"]
  unless job_c["imagePullPolicy"] == app_c["imagePullPolicy"]
    abort "pull policies differ: #{job_c["imagePullPolicy"]} vs #{app_c["imagePullPolicy"]}"
  end
' "$out12reg" || { red "FAIL: the generator does not follow the app image into a custom registry"; exit 1; }
green "ok  - the generator follows the app image through a mirrored registry and pull secrets"

# AUT-390: control-plane pull-secret precedence
#   controlPlane.imagePullSecrets → subchart root → global.imagePullSecrets → gcr-secret
#   "none" (or global ["none"]) suppresses. Default path must stay gcr-secret.
blue "==> AUT-390: control-plane imagePullSecrets precedence"
assert_pull_secrets() {
  local file="$1" workload="$2" expected_csv="$3" msg="$4"
  ruby -ryaml -e '
    docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
    want, expected = ARGV.fetch(1), ARGV.fetch(2).split(",").reject(&:empty?)
    d = docs.find { |x|
      next false unless %w[Deployment Job].include?(x["kind"])
      x.dig("metadata", "name") == want ||
        x.dig("metadata", "labels", "app.kubernetes.io/component") == want
    }
    abort "#{want} not rendered" if d.nil?
    actual = (d.dig("spec", "template", "spec", "imagePullSecrets") || []).map { |s| s["name"] }
    abort "expected #{expected.inspect}, got #{actual.inspect}" unless actual == expected
  ' "$file" "$workload" "$expected_csv" || { red "FAIL: $msg"; exit 1; }
  green "ok  - $msg"
}

out390def="$TMP/scenario-aut390-default.yaml"
render_default "$out390def" --set global.deploymentMode=external
assert_pull_secrets "$out390def" control-plane-app "gcr-secret" \
  "AUT-390: default external app still uses gcr-secret"
assert_pull_secrets "$out390def" control-plane-api "gcr-secret" \
  "AUT-390: default external api still uses gcr-secret"
assert_pull_secrets "$out390def" mcp-signing-key "gcr-secret" \
  "AUT-390: default signing-key Job still uses gcr-secret"

out390cp="$TMP/scenario-aut390-controlplane.yaml"
render_default "$out390cp" --set global.deploymentMode=external \
  --set 'control-plane-app.controlPlane.imagePullSecrets=cp-creds' \
  --set 'control-plane-api.controlPlane.imagePullSecrets=cp-api-creds'
assert_pull_secrets "$out390cp" control-plane-app "cp-creds" \
  "AUT-390: controlPlane.imagePullSecrets reaches the app pod"
assert_pull_secrets "$out390cp" control-plane-api "cp-api-creds" \
  "AUT-390: controlPlane.imagePullSecrets reaches the api pod"
assert_pull_secrets "$out390cp" mcp-signing-key "cp-creds" \
  "AUT-390: signing-key Job tracks app controlPlane pull secret"

out390root="$TMP/scenario-aut390-root.yaml"
render_default "$out390root" --set global.deploymentMode=external \
  --set 'control-plane-app.imagePullSecrets=root-creds' \
  --set 'control-plane-api.imagePullSecrets=root-api-creds'
assert_pull_secrets "$out390root" control-plane-app "root-creds" \
  "AUT-390: subchart root imagePullSecrets reaches the app pod"
assert_pull_secrets "$out390root" mcp-signing-key "root-creds" \
  "AUT-390: signing-key Job tracks app root pull secret"

out390glob="$TMP/scenario-aut390-global.yaml"
render_default "$out390glob" --set global.deploymentMode=external \
  --set 'global.imagePullSecrets[0].name=global-creds'
assert_pull_secrets "$out390glob" control-plane-app "global-creds" \
  "AUT-390: global.imagePullSecrets reaches the app pod"
assert_pull_secrets "$out390glob" control-plane-api "global-creds" \
  "AUT-390: global.imagePullSecrets reaches the api pod"
assert_pull_secrets "$out390glob" mcp-signing-key "global-creds" \
  "AUT-390: signing-key Job tracks global pull secret"

out390none="$TMP/scenario-aut390-none-cp.yaml"
render_default "$out390none" --set global.deploymentMode=external \
  --set 'control-plane-app.controlPlane.imagePullSecrets=none' \
  --set 'control-plane-api.controlPlane.imagePullSecrets=none'
assert_pull_secrets "$out390none" control-plane-app "" \
  "AUT-390: controlPlane imagePullSecrets=none suppresses app pull secrets"
assert_pull_secrets "$out390none" control-plane-api "" \
  "AUT-390: controlPlane imagePullSecrets=none suppresses api pull secrets"
assert_pull_secrets "$out390none" mcp-signing-key "" \
  "AUT-390: controlPlane none suppresses signing-key Job pull secrets"

out390noneroot="$TMP/scenario-aut390-none-root.yaml"
render_default "$out390noneroot" --set global.deploymentMode=external \
  --set 'control-plane-app.imagePullSecrets=none' \
  --set 'control-plane-api.imagePullSecrets=none'
assert_pull_secrets "$out390noneroot" control-plane-app "" \
  "AUT-390: root imagePullSecrets=none suppresses app pull secrets"
assert_pull_secrets "$out390noneroot" mcp-signing-key "" \
  "AUT-390: root none suppresses signing-key Job pull secrets"

out390noneglob="$TMP/scenario-aut390-none-global.yaml"
render_default "$out390noneglob" --set global.deploymentMode=external \
  --set 'global.imagePullSecrets[0]=none'
assert_pull_secrets "$out390noneglob" control-plane-app "" \
  "AUT-390: global imagePullSecrets [none] suppresses app pull secrets"
assert_pull_secrets "$out390noneglob" mcp-signing-key "" \
  "AUT-390: global none suppresses signing-key Job pull secrets"

# Most-specific wins when several levels are set.
out390win="$TMP/scenario-aut390-precedence-wins.yaml"
render_default "$out390win" --set global.deploymentMode=external \
  --set 'global.imagePullSecrets[0].name=global-creds' \
  --set 'control-plane-app.imagePullSecrets=root-creds' \
  --set 'control-plane-app.controlPlane.imagePullSecrets=cp-creds'
assert_pull_secrets "$out390win" control-plane-app "cp-creds" \
  "AUT-390: controlPlane wins over root and global"
assert_pull_secrets "$out390win" mcp-signing-key "cp-creds" \
  "AUT-390: signing-key Job follows the winning app level"

# The embedded script ships as a string, so a syntax error would surface as a
# CrashLoopBackOff during an upgrade rather than at render time.
if command -v node >/dev/null 2>&1; then
  ruby -ryaml -e '
    docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
    job = docs.find { |d| d["kind"] == "Job" && d.dig("metadata", "labels", "app.kubernetes.io/component") == "mcp-signing-key" }
    File.write(ARGV.fetch(1), job.dig("spec", "template", "spec", "containers", 0, "command").last)
  ' "$out12ext" "$TMP/mcp-generator.js"
  node --check "$TMP/mcp-generator.js" \
    || { red "FAIL: the generator script is not valid JavaScript"; exit 1; }
  green "ok  - the generator script parses under the Node it runs on"
else
  yellow "skip - node not available to syntax-check the generator script"
fi

# Turning the generator off leaves the operator in charge, and with no key of
# their own the feature must stay off rather than half-work.
out12nogen_mcp="$TMP/scenario-mcp-oauth-no-generator.yaml"
render_default "$out12nogen_mcp" --set global.deploymentMode=external \
  --set global.mcpOAuth.generateSigningKey=false
assert_not_contains "$out12nogen_mcp" 'component: mcp-signing-key' \
  "generateSigningKey=false: no Job, no RBAC"
assert_not_contains "$out12nogen_mcp" 'MCP_DEFAULT_IDP_|name: MCP_OAUTH_CLIENT_ID' \
  "generateSigningKey=false with no key: MCP OAuth stays off"
# An explicit false must not leave a Job minting a key for a disabled feature.
assert_not_contains "$out12mcpoff" 'component: mcp-signing-key' \
  "mcpOAuth.enabled=false: the generator does not run"
# Hybrid has no authorization server, so it must carry none of this.
for f in "$out12hyb" "$out12hybkey"; do
  assert_not_contains "$f" 'component: mcp-signing-key' \
    "hybrid: no signing key generator is rendered"
done

blue "==> Scenario 12b: control-plane-app no longer couples to backend Secrets"
for legacy in agentgateway-secrets trustguard-secrets datacore-secrets alertengine-secrets trustlens-secrets; do
  ruby -ryaml -e '
    docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
    app = docs.find { |d| d["kind"] == "Deployment" && d.dig("metadata", "name") == "control-plane-app" }
    abort "control-plane-app not rendered" if app.nil?
    pod = app.dig("spec", "template", "spec")
    hits = ((pod["containers"] || []) + (pod["initContainers"] || [])).flat_map { |c|
      (c["env"] || []).select { |e| e.dig("valueFrom", "secretKeyRef", "name") == ARGV.fetch(1) }.map { |e| e["name"] }
    }
    abort "control-plane-app still reads #{ARGV.fetch(1)}: #{hits.join(", ")}" unless hits.empty?
  ' "$out12ext" "$legacy" || { red "FAIL: control-plane-app still couples to $legacy"; exit 1; }
done
green "ok  - control-plane-app reads no backend service Secret directly"

# Opt-outs must leave existing installs on the legacy contract untouched.
blue "==> Scenario 12c: shared Secret opt-outs (external, where the coupling lived)"
out12off="$TMP/scenario-shared-secret-disabled.yaml"
render_default "$out12off" --set global.deploymentMode=external --set global.platformSecret.enabled=false
assert_not_contains "$out12off" '^  name: platform-secrets$' \
  "platformSecret.enabled=false: Secret not rendered"
assert_not_contains "$out12off" 'name: "platform-secrets"' \
  "platformSecret.enabled=false: no workload references it"
assert_contains "$out12off" 'name: "control-plane-secrets"' \
  "platformSecret.enabled=false: refs fall back to the legacy Secret"

out12own="$TMP/scenario-shared-secret-operator-owned.yaml"
render_default "$out12own" --set global.deploymentMode=external --set global.platformSecret.existingSecret.name=my-platform-secrets
assert_not_contains "$out12own" '^  name: platform-secrets$' \
  "existingSecret.name: chart does not render its own Secret"
assert_contains "$out12own" 'name: "my-platform-secrets"' \
  "existingSecret.name: refs point at the operator Secret"

out12pres="$TMP/scenario-shared-secret-preserve.yaml"
render_default "$out12pres" --set global.deploymentMode=external --set global.preserveExistingSecrets=true
assert_not_contains "$out12pres" 'name: "platform-secrets"' \
  "preserveExistingSecrets: refs stay on the legacy per-service Secrets"

# A pinned value must reach the Secret verbatim.
blue "==> Scenario 12d: pinned credential"
out12pin="$TMP/scenario-shared-secret-pinned.yaml"
render_default "$out12pin" --set global.deploymentMode=external --set global.platformSecret.values.CONTROL_PLANE_JWT_SECRET=pinned-value-abc
ruby -ryaml -rbase64 -e '
  docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
  s = docs.find { |d| d["kind"] == "Secret" && d.dig("metadata", "name") == "platform-secrets" }
  got = Base64.decode64(s["data"].fetch("CONTROL_PLANE_JWT_SECRET"))
  abort "expected pinned value, got #{got}" unless got == "pinned-value-abc"
' "$out12pin" || { red "FAIL: pinned value not honored"; exit 1; }
green "ok  - global.platformSecret.values pins a credential verbatim"

# The gateway binaries refuse cleartext config-sync once APP_ENV is deployed:
# the control plane will not build its listener without a keypair, and the data
# plane rejects CONFIG_SYNC_TLS_INSECURE=true. Both halves must arrive together.
blue "==> Scenario 13: config-sync gRPC TLS on both gateways"
AGW_TLS_MOUNT="/etc/agentgateway/configsync-tls"
CS_ON=(--set agentgateway.configSync.enabled=true --set agentgateway.configSync.token=tok)

out13="$TMP/scenario-configsync-tls-external.yaml"
render_default "$out13" --set global.deploymentMode=external "${CS_ON[@]}"

for k in tls.crt tls.key ca.crt; do
  assert_secret_key "$out13" agentgateway-configsync-tls present "$k" \
    "external: agentgateway config-sync TLS Secret carries $k"
done
assert_contains "$out13" 'name: agentgateway-configsync-tls' \
  "external: the generated Secret is named after the chart, not TrustGuard's"

assert_env_value "$out13" agentgateway-admin admin CONFIG_SYNC_GRPC_TLS_CERT \
  "$AGW_TLS_MOUNT/tls.crt" "external: the admin plane serves the generated cert"
assert_env_value "$out13" agentgateway-admin admin CONFIG_SYNC_GRPC_TLS_KEY \
  "$AGW_TLS_MOUNT/tls.key" "external: the admin plane serves the generated key"

# Both data planes dial the listener, so both must verify it.
for wl in agentgateway-proxy agentgateway-mcp; do
  c=proxy; [ "$wl" = agentgateway-mcp ] && c=mcp
  assert_env_value "$out13" "$wl" "$c" CONFIG_SYNC_TLS_INSECURE false \
    "external: $wl verifies the config-sync listener instead of dialing cleartext"
  assert_env_value "$out13" "$wl" "$c" CONFIG_SYNC_TLS_CA "$AGW_TLS_MOUNT/ca.crt" \
    "external: $wl trusts the generated CA"
  assert_env_value "$out13" "$wl" "$c" CONFIG_SYNC_TLS_SERVER_NAME \
    "agentgateway-admin.default.svc.cluster.local" \
    "external: $wl verifies the listener's SAN"
done

assert_contains "$out13" 'APP_ENV: "production"' \
  "external: agentgateway declares a deployed APP_ENV"

# A non-deployed APP_ENV keeps the old permissive behaviour, so an operator who
# needs cleartext has a way out that does not involve editing templates.
out13dev="$TMP/scenario-configsync-tls-dev.yaml"
render_default "$out13dev" --set global.deploymentMode=external "${CS_ON[@]}" \
  --set agentgateway.config.appEnv=dev
assert_not_contains "$out13dev" 'agentgateway-configsync-tls' \
  "non-deployed APP_ENV: no keypair is generated"
assert_env_value "$out13dev" agentgateway-proxy proxy CONFIG_SYNC_TLS_INSECURE true \
  "non-deployed APP_ENV: the permissive dial is still available"

# Hybrid has no control plane to secure and dials SaaS over public TLS.
out13hy="$TMP/scenario-configsync-tls-hybrid.yaml"
render_default "$out13hy"
assert_not_contains "$out13hy" 'agentgateway-configsync-tls' \
  "hybrid: no config-sync keypair is generated"
assert_env_value "$out13hy" agentgateway-proxy proxy CONFIG_SYNC_TLS_INSECURE false \
  "hybrid: the SaaS dial stays verified under a deployed APP_ENV"

# Operator-owned keypair: the chart must not mint a competing one.
out13own="$TMP/scenario-configsync-tls-existing.yaml"
render_default "$out13own" --set global.deploymentMode=external "${CS_ON[@]}" \
  --set agentgateway.configSync.grpcTls.existingSecret=my-configsync-tls
assert_not_contains "$out13own" 'name: agentgateway-configsync-tls' \
  "existingSecret: the chart renders no keypair of its own"
assert_contains "$out13own" 'secretName: my-configsync-tls' \
  "existingSecret: the control plane mounts the operator Secret"

# Pre-provisioned installs own every Secret themselves.
out13pre="$TMP/scenario-configsync-tls-preserve.yaml"
render_default "$out13pre" --set global.deploymentMode=external "${CS_ON[@]}" \
  --set global.preserveExistingSecrets=true \
  --set agentgateway.configSync.existingSecret.name=agw-cs \
  --set trustguard.configSync.existingSecret.name=tg-cs
assert_not_contains "$out13pre" 'name: agentgateway-configsync-tls' \
  "preserveExistingSecrets: the chart generates no keypair"

# Turning generation off without supplying a Secret yields a control plane that
# cannot start. sprig reads an explicit false back as true through `default`, so
# this guard only works via hasKey - these cases would silently pass otherwise.
assert_render_fails "autoGenerate=false without existingSecret is rejected" \
  --set global.deploymentMode=external \
  --set agentgateway.configSync.grpcTls.autoGenerate=false
assert_render_fails "the same guard covers trustguard" \
  --set global.deploymentMode=external \
  --set trustguard.configSync.grpcTls.autoGenerate=false

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

# IRSA supplies a role and a token file, not a region, and the SDK fails the
# token request without one.
blue "==> Scenario 16: AWS region for RDS IAM on the Go gateways"
out16="$TMP/scenario-aws-region.yaml"
render_default "$out16" --set global.deploymentMode=external \
  --set global.postgresql.awsRegion=eu-west-1 \
  --set agentgateway.database.iamAuth=true --set trustguard.database.iamAuth=true
assert_contains "$out16" 'AWS_REGION: "eu-west-1"' \
  "external: the IAM gateways are told which region to sign for"
ruby -ryaml -e '
  docs = []
  YAML.load_stream(File.read(ARGV.fetch(0), encoding: "UTF-8")) { |d| docs << d if d.is_a?(Hash) }
  %w[agentgateway-env-vars trustguard-env-vars].each do |name|
    cm = docs.find { |d| d["kind"] == "ConfigMap" && d.dig("metadata", "name") == name }
    abort "#{name} not rendered" if cm.nil?
    got = cm.fetch("data")["AWS_REGION"]
    abort "#{name} has no AWS_REGION (IAM token minting will fail)" if got.nil?
    abort "#{name} AWS_REGION=#{got.inspect}" unless got == "eu-west-1"
  end
' "$out16" || { red "FAIL: an IAM gateway was left without a region"; exit 1; }
green "ok  - both Go gateways carry the region their SigV4 signer needs"

out16sub="$TMP/scenario-aws-region-subchart.yaml"
render_default "$out16sub" --set global.deploymentMode=external \
  --set global.postgresql.awsRegion=eu-west-1 \
  --set agentgateway.database.iamAuth=true \
  --set agentgateway.database.awsRegion=us-east-2
assert_contains "$out16sub" 'AWS_REGION: "us-east-2"' \
  "a per-chart region overrides the global one"

out16off="$TMP/scenario-aws-region-noniam.yaml"
render_default "$out16off" --set global.deploymentMode=external \
  --set global.postgresql.awsRegion=eu-west-1
assert_not_contains "$out16off" 'agentgateway[\s\S]{0,200}AWS_REGION' \
  "no region is emitted for the gateways when IAM is off"

# Managed endpoints used to be declared once per service, because empty
# per-service hosts fell straight through to the in-cluster Service names.
blue "==> Scenario 17: managed datastores declared once on the global blocks"
MANAGED_DATASTORES=(
  --set global.postgresql.deploy=false
  --set global.postgresql.host=aurora.example.com
  --set global.postgresql.port=5433
  --set global.postgresql.sslMode=require
  --set global.redis.deploy=false
  --set global.redis.host=cache.example.com
  --set global.redis.port=6380
  --set global.redis.username=neuraltrust
  --set global.redis.tls=true
)

out17="$TMP/scenario-datastore-inherit.yaml"
render_default "$out17" --set global.deploymentMode=external \
  --set trustlens.enabled=true --set trustlens.image.tag=v0.1.0 \
  "${MANAGED_DATASTORES[@]}"
ruby -ryaml -e '
  docs = []
  YAML.load_stream(File.read(ARGV.fetch(0), encoding: "UTF-8")) { |d| docs << d if d.is_a?(Hash) }
  cm = ->(name) do
    d = docs.find { |x| x["kind"] == "ConfigMap" && x.dig("metadata", "name") == name }
    abort "#{name} not rendered" if d.nil?
    d.fetch("data")
  end
  # Each service names the same endpoint under its own variable convention.
  { "agentgateway-env-vars" => %w[DB_HOST DB_PORT DB_SSL_MODE],
    "trustguard-env-vars"   => %w[DB_HOST DB_PORT DB_SSL_MODE],
    "alertengine-env-vars"  => %w[DB_HOST DB_PORT DB_SSL_MODE],
    "datacore-env-vars"     => %w[POSTGRES_HOST POSTGRES_PORT POSTGRES_SSLMODE],
    "trustlens-env-vars"    => %w[DATABASE_HOST DATABASE_PORT DATABASE_SSLMODE] }.each do |name, (hk, pk, sk)|
    data = cm.call(name)
    abort "#{name} #{hk}=#{data[hk].inspect}" unless data[hk] == "aurora.example.com"
    abort "#{name} #{pk}=#{data[pk].inspect}" unless data[pk].to_s == "5433"
    abort "#{name} #{sk}=#{data[sk].inspect}" unless data[sk] == "require"
  end
  # Redis: TrustGate reads REDIS_TLS_ENABLED, TrustGuard reads REDIS_TLS.
  { "agentgateway-env-vars" => "REDIS_TLS_ENABLED",
    "trustguard-env-vars"   => "REDIS_TLS" }.each do |name, tlsk|
    data = cm.call(name)
    abort "#{name} REDIS_HOST=#{data["REDIS_HOST"].inspect}" unless data["REDIS_HOST"] == "cache.example.com"
    abort "#{name} REDIS_PORT=#{data["REDIS_PORT"].inspect}" unless data["REDIS_PORT"].to_s == "6380"
    abort "#{name} REDIS_USERNAME=#{data["REDIS_USERNAME"].inspect}" unless data["REDIS_USERNAME"] == "neuraltrust"
    abort "#{name} #{tlsk}=#{data[tlsk].inspect}" unless data[tlsk].to_s == "true"
  end
' "$out17" || { red "FAIL: a service ignored the global blocks and dialed an in-cluster Service"; exit 1; }
green "ok  - external: every service inherits the managed endpoints from the global blocks"

# data-plane-api composes its cache DSN in a Secret rather than reading env.
ruby -ryaml -rbase64 -e '
  docs = []
  YAML.load_stream(File.read(ARGV.fetch(0), encoding: "UTF-8")) { |d| docs << d if d.is_a?(Hash) }
  s = docs.find { |d| d["kind"] == "Secret" && d.dig("metadata", "name") == "data-plane-jwt-secret" }
  abort "data-plane-jwt-secret not rendered" if s.nil?
  url = Base64.decode64(s.fetch("data").fetch("REDIS_URL"))
  abort "REDIS_URL=#{url.inspect} does not target the managed cache" unless url.include?("cache.example.com:6380")
  abort "REDIS_URL=#{url.inspect} should use the TLS scheme" unless url.start_with?("rediss://")
' "$out17" || { red "FAIL: the data-plane cache DSN ignored global.redis"; exit 1; }
green "ok  - external: the data-plane cache DSN follows global.redis, TLS scheme included"

# An explicit global host is honoured whatever `deploy` says: the shared
# postgresql-secrets already resolve that way, and disagreeing here would split
# the platform across two databases.
out17deploy="$TMP/scenario-datastore-inherit-deploy.yaml"
render_default "$out17deploy" --set global.deploymentMode=external \
  --set global.postgresql.host=aurora.example.com \
  --set global.postgresql.port=5433
ruby -ryaml -rbase64 -e '
  docs = []
  YAML.load_stream(File.read(ARGV.fetch(0), encoding: "UTF-8")) { |d| docs << d if d.is_a?(Hash) }
  shared = docs.find { |d| d["kind"] == "Secret" && d.dig("metadata", "name") == "postgresql-secrets" }
  abort "postgresql-secrets not rendered" if shared.nil?
  host = Base64.decode64(shared.fetch("data").fetch("POSTGRES_HOST"))
  ag = docs.find { |d| d["kind"] == "ConfigMap" && d.dig("metadata", "name") == "agentgateway-env-vars" }
  abort "agentgateway-env-vars not rendered" if ag.nil?
  runtime = ag.fetch("data").fetch("DB_HOST")
  abort "split brain: postgresql-secrets=#{host.inspect} but runtime=#{runtime.inspect}" unless host == runtime
' "$out17deploy" || { red "FAIL: the control plane and the runtimes disagree on the Postgres host"; exit 1; }
green "ok  - deploy=true: the control plane and the runtimes agree on one host"

out17override="$TMP/scenario-datastore-inherit-override.yaml"
render_default "$out17override" --set global.deploymentMode=external \
  "${MANAGED_DATASTORES[@]}" \
  --set agentgateway.database.host=gateway-pg.example.com \
  --set agentgateway.database.port=6432 \
  --set agentgateway.redis.host=gateway-cache.example.com
ruby -ryaml -e '
  docs = []
  YAML.load_stream(File.read(ARGV.fetch(0), encoding: "UTF-8")) { |d| docs << d if d.is_a?(Hash) }
  ag = docs.find { |d| d["kind"] == "ConfigMap" && d.dig("metadata", "name") == "agentgateway-env-vars" }.fetch("data")
  abort "agentgateway host override lost" unless ag["DB_HOST"] == "gateway-pg.example.com"
  abort "agentgateway port override lost" unless ag["DB_PORT"].to_s == "6432"
  abort "agentgateway redis override lost" unless ag["REDIS_HOST"] == "gateway-cache.example.com"
  tg = docs.find { |d| d["kind"] == "ConfigMap" && d.dig("metadata", "name") == "trustguard-env-vars" }.fetch("data")
  abort "trustguard should still inherit" unless tg["DB_HOST"] == "aurora.example.com"
  abort "trustguard redis should still inherit" unless tg["REDIS_HOST"] == "cache.example.com"
' "$out17override" || { red "FAIL: a per-service endpoint no longer wins over the global one"; exit 1; }
green "ok  - a per-service host/port still overrides the inherited one"

# Hybrid: DataAgent builds its own DSN, so inheritance has to reach the string.
out17dsn="$TMP/scenario-datastore-inherit-dsn.yaml"
render_default "$out17dsn" "${MANAGED_DATASTORES[@]}" \
  --set dataagent.database.password=render-test
assert_contains "$out17dsn" 'aurora.example.com:5433' \
  "hybrid: the DataAgent DSN points at the managed endpoint"
assert_contains "$out17dsn" 'sslmode=require' \
  "hybrid: the DataAgent DSN inherits the global sslMode"
assert_not_contains "$out17dsn" 'DATABASE_URL: "postgresql://[^"]*@control-plane-postgresql' \
  "hybrid: no DataAgent DSN is left on the in-cluster Service"

# The cache credential has three consumers and used to be declared once for each.
out17pw="$TMP/scenario-datastore-inherit-redis-pw.yaml"
render_default "$out17pw" --set global.deploymentMode=external \
  "${MANAGED_DATASTORES[@]}" \
  --set global.redis.password=inherited-cache-pw
ruby -ryaml -rbase64 -e '
  docs = []
  YAML.load_stream(File.read(ARGV.fetch(0), encoding: "UTF-8")) { |d| docs << d if d.is_a?(Hash) }
  # The gateway Secrets ship stringData; only the umbrella ones are base64 data.
  fields = ->(name) do
    d = docs.find { |x| x["kind"] == "Secret" && x.dig("metadata", "name") == name }
    abort "#{name} not rendered" if d.nil?
    d["stringData"] || d["data"] || {}
  end
  %w[agentgateway-secrets trustguard-secrets].each do |name|
    got = fields.call(name)["REDIS_PASSWORD"]
    abort "#{name} carries no REDIS_PASSWORD" if got.nil?
    abort "#{name} REDIS_PASSWORD=#{got.inspect}" unless got == "inherited-cache-pw"
  end
  url = Base64.decode64(fields.call("data-plane-jwt-secret").fetch("REDIS_URL"))
  abort "REDIS_URL=#{url.inspect} carries no inherited credential" unless url.include?(":inherited-cache-pw@")
' "$out17pw" || { red "FAIL: global.redis.password did not reach all three cache consumers"; exit 1; }
green "ok  - one global.redis.password reaches both gateways and the data-plane DSN"

# A per-service cache password still wins, so split credentials stay possible.
out17pwover="$TMP/scenario-datastore-inherit-redis-pw-override.yaml"
render_default "$out17pwover" --set global.deploymentMode=external \
  "${MANAGED_DATASTORES[@]}" \
  --set global.redis.password=inherited-cache-pw \
  --set agentgateway.redis.password=gateway-only-pw
ruby -ryaml -rbase64 -e '
  docs = []
  YAML.load_stream(File.read(ARGV.fetch(0), encoding: "UTF-8")) { |d| docs << d if d.is_a?(Hash) }
  pw = ->(name) do
    d = docs.find { |x| x["kind"] == "Secret" && x.dig("metadata", "name") == name }
    abort "#{name} not rendered" if d.nil?
    (d["stringData"] || {}).fetch("REDIS_PASSWORD")
  end
  abort "agentgateway override lost" unless pw.call("agentgateway-secrets") == "gateway-only-pw"
  abort "trustguard should still inherit" unless pw.call("trustguard-secrets") == "inherited-cache-pw"
' "$out17pwover" || { red "FAIL: a per-service cache password no longer wins"; exit 1; }
green "ok  - a per-service cache password still overrides the inherited one"

# Nothing inherits when the global blocks are left at their defaults.
out17def="$TMP/scenario-datastore-inherit-default.yaml"
render_default "$out17def" --set global.deploymentMode=external
assert_contains "$out17def" 'DB_HOST: "control-plane-postgresql"' \
  "defaults: Postgres still resolves to the in-cluster Service"
assert_contains "$out17def" 'REDIS_HOST: "redis"' \
  "defaults: Redis still resolves to the in-cluster Service"
assert_contains "$out17def" 'DB_SSL_MODE: "prefer"' \
  "defaults: sslMode still resolves to prefer"

blue "==> Scenario 18: operator-supplied datastore credential Secrets (AUT-411)"

# Naming a pre-created Secret must move the credential out of the chart Secret
# entirely, not merely duplicate it: a copy left behind would still land in
# release history, which is the whole point of the hook.
CREDENTIAL_HOOKS=(
  --set global.deploymentMode=external
  --set agentgateway.database.existingSecret.name=ag-db
  --set agentgateway.database.existingSecret.key=password
  --set agentgateway.redis.existingSecret.name=cache
  --set trustguard.database.existingSecret.name=tg-db
  --set trustguard.redis.existingSecret.name=cache
  --set alertengine.database.existingSecret.name=ae-db
  --set datacore.database.existingSecret.name=dc-db
  --set data-plane-api.dataPlane.components.api.redis.existingSecret.name=dp-cache
  --set data-plane-api.dataPlane.components.api.redis.existingSecret.key=url
)
out18="$TMP/scenario-credential-hooks.yaml"
render_default "$out18" "${CREDENTIAL_HOOKS[@]}"
ruby -ryaml -e '
  docs = []
  YAML.load_stream(File.read(ARGV.fetch(0), encoding: "UTF-8")) { |d| docs << d if d.is_a?(Hash) }
  # postgresql-secrets keeps POSTGRES_PASSWORD: the control-plane role also feeds
  # the composed DSNs, which the chart cannot assemble from a Secret it may not read.
  owned = { "postgresql-secrets" => ["POSTGRES_PASSWORD"] }
  docs.select { |d| d["kind"] == "Secret" }.each do |d|
    name = d.dig("metadata", "name")
    fields = (d["data"] || {}).merge(d["stringData"] || {})
    leaked = fields.keys.grep(/\A(DB_PASSWORD|REDIS_PASSWORD|POSTGRES_PASSWORD|REDIS_URL)\z/) - (owned[name] || [])
    abort "#{name} still carries #{leaked.inspect}" unless leaked.empty?
  end
  want = {
    ["agentgateway-admin", "DB_PASSWORD"]            => ["ag-db", "password"],
    ["agentgateway-proxy", "DB_PASSWORD"]            => ["ag-db", "password"],
    ["agentgateway-mcp", "DB_PASSWORD"]              => ["ag-db", "password"],
    ["agentgateway-proxy", "REDIS_PASSWORD"]         => ["cache", "REDIS_PASSWORD"],
    ["trustguard-control-plane", "DB_PASSWORD"]      => ["tg-db", "DB_PASSWORD"],
    ["trustguard-data-plane", "REDIS_PASSWORD"]      => ["cache", "REDIS_PASSWORD"],
    ["alertengine-api", "DB_PASSWORD"]               => ["ae-db", "DB_PASSWORD"],
    ["alertengine-worker", "DB_PASSWORD"]            => ["ae-db", "DB_PASSWORD"],
    ["datacore", "POSTGRES_PASSWORD"]                => ["dc-db", "POSTGRES_PASSWORD"],
    ["data-plane-api", "REDIS_URL"]                  => ["dp-cache", "url"],
  }
  want.each do |(workload, env), (secret, key)|
    d = docs.find { |x| x["kind"] == "Deployment" && x.dig("metadata", "name") == workload }
    abort "#{workload} not rendered" if d.nil?
    entry = d["spec"]["template"]["spec"]["containers"].flat_map { |c| c["env"] || [] }.find { |e| e["name"] == env }
    abort "#{workload} does not read #{env} from a Secret" if entry.nil?
    ref = entry.dig("valueFrom", "secretKeyRef") || {}
    got = [ref["name"], ref["key"]]
    abort "#{workload}/#{env} reads #{got.inspect}, want #{[secret, key].inspect}" unless got == [secret, key]
  end
' "$out18" || { red "FAIL: pre-created credential Secrets are not wired end to end"; exit 1; }
green "ok  - external: pre-created Secrets own the credential and every workload reads it directly"

# Hybrid takes both passwords from the shared postgresql-secrets / redis-secrets,
# so the per-service hooks have nothing to bind to and must stay inert.
out18hy="$TMP/scenario-credential-hooks-hybrid.yaml"
render_default "$out18hy" \
  --set agentgateway.database.existingSecret.name=ag-db \
  --set agentgateway.redis.existingSecret.name=cache \
  --set trustguard.database.existingSecret.name=tg-db
ruby -ryaml -e '
  docs = []
  YAML.load_stream(File.read(ARGV.fetch(0), encoding: "UTF-8")) { |d| docs << d if d.is_a?(Hash) }
  bound = docs.select { |d| d["kind"] == "Deployment" }.flat_map do |d|
    d["spec"]["template"]["spec"]["containers"].flat_map { |c| c["env"] || [] }.select do |e|
      %w[ag-db tg-db cache].include?(e.dig("valueFrom", "secretKeyRef", "name"))
    end.map { |e| "#{d.dig("metadata", "name")}/#{e["name"]}" }
  end
  abort "hybrid bound the external hooks: #{bound.inspect}" unless bound.empty?
' "$out18hy" || { red "FAIL: hybrid should ignore the per-service credential hooks"; exit 1; }
green "ok  - hybrid ignores the hooks and keeps using the shared datastore Secrets"

# An inline password next to a hook is silently unused, so reject the combination
# rather than leave the operator guessing which one the pods received.
assert_render_fails "a hook plus an inline database password is rejected" \
  --set global.deploymentMode=external \
  --set agentgateway.database.existingSecret.name=ag-db \
  --set agentgateway.database.password=ignored
assert_render_fails "a hook plus an inline cache password is rejected" \
  --set global.deploymentMode=external \
  --set trustguard.redis.existingSecret.name=cache \
  --set trustguard.redis.password=ignored

# IAM auth mints a token per connection, so there is no static password to point
# at and the hook must not smuggle one back in.
out18iam="$TMP/scenario-credential-hooks-iam.yaml"
render_default "$out18iam" --set global.deploymentMode=external \
  --set agentgateway.database.iamAuth=true \
  --set agentgateway.database.awsRegion=eu-west-1 \
  --set agentgateway.database.existingSecret.name=ag-db
assert_not_contains "$out18iam" 'name: "ag-db"' \
  "IAM database auth ignores the credential hook"

blue "==> Scenario 19: PostgreSQL bootstrap Job for the in-cluster instance (AUT-412)"

# The Job is the only thing that creates the per-service roles external mode
# expects, so assert on the service list it actually bootstraps, not just on the
# Job being present. Reads the rendered shell rather than guessing: each service
# contributes exactly one bootstrap_service call and one password env entry.
bootstrap_services() {
  ruby -ryaml -e '
    docs = []
    YAML.load_stream(File.read(ARGV.fetch(0), encoding: "UTF-8")) { |d| docs << d if d.is_a?(Hash) }
    job = docs.find { |d| d["kind"] == "Job" && d.dig("metadata", "name") == "control-plane-postgresql-bootstrap" }
    exit 0 if job.nil?
    container = job.dig("spec", "template", "spec", "containers").fetch(0)
    script = container["command"].fetch(2)
    calls = script.scan(/^bootstrap_service "([^"]+)" "([^"]+)" "([^"]+)" "([^"]+)" "([^"]+)" "([^"]+)"$/)
    envs = (container["env"] || []).map { |e| e["name"] }
    calls.each do |key, role, db, env_name, secret, secret_key|
      abort "#{key}: #{env_name} is not wired into the pod" unless envs.include?(env_name)
      puts "#{key}:#{role}:#{db}:#{secret}/#{secret_key}"
    end
  ' "$1"
}

assert_bootstrap() {
  local file="$1" expected="$2" msg="$3" got
  got="$(bootstrap_services "$file" | tr '\n' ' ' | sed 's/ $//')"
  if [[ "$got" != "$expected" ]]; then
    red "FAIL: $msg"
    red "  expected: ${expected:-<no Job>}"
    red "  got:      ${got:-<no Job>}"
    exit 1
  fi
  green "ok  - $msg"
}

out19ext="$TMP/scenario-bootstrap-external.yaml"
render_default "$out19ext" --set global.deploymentMode=external
assert_bootstrap "$out19ext" \
  "agentgateway:agentgateway:agentgateway:agentgateway-secrets/DB_PASSWORD trustguard:trustguard:trustguard:trustguard-secrets/DB_PASSWORD alertengine:alertengine:alertengine:alertengine-secrets/DB_PASSWORD datacore:datacore:datacore:datacore-secrets/POSTGRES_PASSWORD" \
  "external + in-cluster Postgres bootstraps all four per-service roles"
assert_contains "$out19ext" '"helm.sh/hook": post-install,post-upgrade' \
  "the Job runs after the PostgreSQL Deployment exists, not before it"
# Templated target, so no values path can aim this Job at someone's managed instance.
assert_contains "$out19ext" 'value: "control-plane-postgresql"' \
  "the Job dials the in-cluster Service, not the endpoint in postgresql-secrets"

# A managed instance is provisioned by its own tooling; the chart must never try
# to create roles there, whichever way the operator names it.
for managed in \
  "--set global.postgresql.host=pg.example.com" \
  "--set global.postgresql.authMode=iam" \
  "--set global.postgresql.bootstrapJob.enabled=false"; do
  out19off="$TMP/scenario-bootstrap-off.yaml"
  # shellcheck disable=SC2086 # deliberate word splitting of the flag pairs above
  render_default "$out19off" --set global.deploymentMode=external $managed
  assert_bootstrap "$out19off" "" "no bootstrap Job with $managed"
done

# Hybrid shares one role and database, which the PostgreSQL image itself creates,
# so the Job has nothing per-service to do — but it still renders to converge the
# shared database and to turn a stale superuser password into one legible error
# instead of six crash-looping pods.
out19hy="$TMP/scenario-bootstrap-hybrid.yaml"
render_default "$out19hy"
assert_bootstrap "$out19hy" "" "hybrid bootstraps no per-service role"
assert_contains "$out19hy" 'name: control-plane-postgresql-bootstrap' \
  "hybrid still renders the Job for the shared database"

# Only deployed services get a role, and IAM auth has no password to set.
out19off1="$TMP/scenario-bootstrap-alertengine-off.yaml"
render_default "$out19off1" --set global.deploymentMode=external --set alertengine.enabled=false
assert_bootstrap "$out19off1" \
  "agentgateway:agentgateway:agentgateway:agentgateway-secrets/DB_PASSWORD trustguard:trustguard:trustguard:trustguard-secrets/DB_PASSWORD datacore:datacore:datacore:datacore-secrets/POSTGRES_PASSWORD" \
  "a disabled service gets no role"
out19iam="$TMP/scenario-bootstrap-iam.yaml"
render_default "$out19iam" --set global.deploymentMode=external \
  --set agentgateway.database.iamAuth=true --set agentgateway.database.awsRegion=eu-west-1
assert_bootstrap "$out19iam" \
  "trustguard:trustguard:trustguard:trustguard-secrets/DB_PASSWORD alertengine:alertengine:alertengine:alertengine-secrets/DB_PASSWORD datacore:datacore:datacore:datacore-secrets/POSTGRES_PASSWORD" \
  "an IAM-auth service is skipped"

# The credential hooks from Scenario 18 must move where the Job reads the
# password too, or it would set a role to a value the pod never uses.
out19hook="$TMP/scenario-bootstrap-hook.yaml"
render_default "$out19hook" --set global.deploymentMode=external \
  --set agentgateway.database.existingSecret.name=postgres-roles \
  --set agentgateway.database.existingSecret.key=AGENTGATEWAY \
  --set datacore.database.user=dc --set datacore.database.name=dcdb
assert_bootstrap "$out19hook" \
  "agentgateway:agentgateway:agentgateway:postgres-roles/AGENTGATEWAY trustguard:trustguard:trustguard:trustguard-secrets/DB_PASSWORD alertengine:alertengine:alertengine:alertengine-secrets/DB_PASSWORD datacore:dc:dcdb:datacore-secrets/POSTGRES_PASSWORD" \
  "the Job follows the credential hooks and custom role/database names"

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
# too (RUN-1086 / RUN-1093). The password must still follow the operator Secret.
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
# rejected — the same way the per-service credential hooks behave (AUT-411).
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
# AUT-322: port + probe parity against service k8s overlays / health routes.
# A wrong readiness path marks Ready while broken; a missing startupProbe
# CrashLoops migration-bound boots (TrustGate admin, TrustLens API).
# ---------------------------------------------------------------------------
blue "==> AUT-322: port and probe parity"
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
  --set global.deploymentMode=external \
  --set trustlens.enabled=true --set trustlens.image.tag=v0.1.0
assert_workload_parity "$out322ext" agentgateway-admin admin 8080 /readyz /healthz /healthz
assert_workload_parity "$out322ext" agentgateway-proxy proxy 8081 /readyz /healthz /healthz
assert_workload_parity "$out322ext" agentgateway-mcp mcp 8082 /readyz /healthz /healthz
assert_workload_parity "$out322ext" trustguard-control-plane control-plane 8080 /readyz /healthz /healthz
assert_workload_parity "$out322ext" trustguard-data-plane data-plane 8081 /readyz /healthz /healthz
assert_workload_parity "$out322ext" trustlens-api api 8080 /ready /health /health
assert_workload_parity "$out322ext" data-plane-api api 8000 /health/ready /health /health

out322hyb="$TMP/scenario-aut322-hybrid.yaml"
render_default "$out322hyb"
# Primary TrustGate DataAgent is named `dataagent`; TrustGuard's slice is
# `dataagent-trustguard` (see charts/dataagent fullname helpers).
for da in dataagent dataagent-trustguard; do
  assert_workload_parity "$out322hyb" "$da" dataagent 8080 /readyz /healthz /healthz
done
assert_render_fails_with \
  "trustlens.image.tag is required when trustlens.enabled=true" \
  "AUT-322: TrustLens refuses to render without an image tag" \
  --set trustlens.enabled=true

# ---------------------------------------------------------------------------
# AUT-393: create-secrets.sh must track platformSecret.registry and the
# canonical Postgres family. Drift here is silent until an operator runs the
# script under preserveExistingSecrets.
# ---------------------------------------------------------------------------
blue "create-secrets.sh registry + Postgres contract"
SCRIPT_KEYS="$(awk '
  /PLATFORM_SECRET_REGISTRY_KEYS_BEGIN/ { in_list=1; next }
  /PLATFORM_SECRET_REGISTRY_KEYS_END/ { in_list=0 }
  in_list && /^[[:space:]]*[A-Z0-9_]+[[:space:]]*$/ {
    gsub(/[[:space:]]/, "", $0)
    print $0
  }
' create-secrets.sh | sort)"
HELPER_KEYS="$(awk '
  /define "neuraltrust-platform.platformSecret.registry"/ { in_reg=1; next }
  in_reg && /{{- end }}/ { exit }
  in_reg && /^[A-Z0-9_]+:/ {
    sub(/:.*/, "", $0)
    print $0
  }
' templates/_helpers.tpl | sort)"
if [ "$SCRIPT_KEYS" != "$HELPER_KEYS" ]; then
  red "FAIL - create-secrets.sh PLATFORM_SECRET_REGISTRY_KEYS drifts from platformSecret.registry"
  echo "--- script ---"
  echo "$SCRIPT_KEYS"
  echo "--- helpers ---"
  echo "$HELPER_KEYS"
  exit 1
fi
green "ok  - create-secrets.sh registry keys match platformSecret.registry"

for key in $HELPER_KEYS; do
  if ! grep -q "ensure_platform_secret_key \"$key\"" create-secrets.sh; then
    red "FAIL - create-secrets.sh never calls ensure_platform_secret_key for $key"
    exit 1
  fi
done
green "ok  - create-secrets.sh materialises every registry key into platform-secrets"

# The telemetry signing key is the first PEM this script stores. trim_value ends
# in `tr -d '\n\r'`, which would flatten it into one line that no PEM parser
# accepts — a Secret that looks correct in kubectl and 401s every OTLP batch at
# runtime. Drive the real functions with a stubbed kubectl rather than grepping
# for the guard, so the property is tested and not the implementation.
pem_probe="$TMP/create-secrets-pem-probe.sh"
{
  sed -n '/^trim_value()/,/^}/p' create-secrets.sh
  sed -n '/^add_secret_key()/,/^}/p' create-secrets.sh
} > "$TMP/create-secrets-funcs.sh"
cat > "$pem_probe" <<'PROBE'
NAMESPACE=nt
GREEN=''; RED=''; YELLOW=''; NC=''
captured="$1"
kubectl() {
  [ "$1 $2" = "get secret" ] && return 1
  if [ "$1" = "create" ]; then
    for a in "$@"; do
      case "$a" in --from-literal=*) printf '%s' "${a#--from-literal=}" > "$captured" ;; esac
    done
    return 0
  fi
  cat >/dev/null; return 0
}
. "$2"
pem=$(openssl genrsa -traditional 2048 2>/dev/null || openssl genrsa 2048 2>/dev/null)
add_secret_key nt-secrets TELEMETRY_JWT_PRIVATE_KEY_PEM "$pem" raw
PROBE
bash "$pem_probe" "$TMP/pem-captured" "$TMP/create-secrets-funcs.sh" >/dev/null 2>&1
if ! sed 's/^TELEMETRY_JWT_PRIVATE_KEY_PEM=//' "$TMP/pem-captured" \
     | openssl rsa -noout -check >/dev/null 2>&1; then
  red "FAIL - create-secrets.sh stores TELEMETRY_JWT_PRIVATE_KEY_PEM as an unparseable PEM"
  red "  stored $(wc -l < "$TMP/pem-captured" | tr -d ' ') line(s); a PEM needs its line structure intact"
  exit 1
fi
green "ok  - create-secrets.sh stores the telemetry signing key as a parseable PEM"

# The generated key must be shaped like the chart's own, or the two bootstrap
# paths hand DataCore structurally different keys for one registry entry.
if ! grep -q 'openssl genrsa -traditional 4096' create-secrets.sh; then
  red "FAIL - create-secrets.sh should mint PKCS#1 4096 to match genPrivateKey \"rsa\""
  exit 1
fi
green "ok  - create-secrets.sh matches the chart's own RSA key shape"

for needle in POSTGRES_SSLMODE POSTGRES_LOGIN POSTGRES_AUTH_MODE POSTGRES_CONNECTION_TYPE; do
  if ! grep -q -- "--from-literal=${needle}=" create-secrets.sh; then
    red "FAIL - create-secrets.sh postgresql-secrets omits ${needle}"
    exit 1
  fi
done
if grep -q -- '--from-literal=DATABASE_URL=' create-secrets.sh; then
  red "FAIL - create-secrets.sh still writes retired DATABASE_URL into postgresql-secrets"
  exit 1
fi
if grep -q -- '--from-literal=SENSIBLE_PG_DSN=' create-secrets.sh; then
  red "FAIL - create-secrets.sh must not compose SENSIBLE_PG_DSN"
  exit 1
fi
green "ok  - create-secrets.sh writes the canonical Postgres family without DSN composition"

# AUT-393: on the pre-provisioned path the chart owns no service Secret, so it
# references configSync.existingSecret for CONFIG_SYNC_LKG_KEY instead of
# generating one. The script has to write that key or the data planes will not
# start. Guard both the call sites and the 32-byte contract, since a wrong-length
# key fails at runtime rather than at render.
for product in trustgate trustguard; do
  if ! grep -q "shape_enabled $product" create-secrets.sh; then
    red "FAIL - create-secrets.sh never gates the config-sync LKG key on the $product shape"
    exit 1
  fi
done
if ! grep -q 'ensure_config_sync_lkg_key' create-secrets.sh; then
  red "FAIL - create-secrets.sh never creates CONFIG_SYNC_LKG_KEY (AUT-393)"
  exit 1
fi
if ! grep -q 'openssl rand -base64 32' create-secrets.sh; then
  red "FAIL - create-secrets.sh config-sync LKG key must be 32 bytes to match randBytes 32"
  exit 1
fi
LKG_DEFAULT_NAMES="$(grep -c -e 'agentgateway-config-sync' -e 'trustguard-config-sync' create-secrets.sh || true)"
if [ "${LKG_DEFAULT_NAMES:-0}" -lt 2 ]; then
  red "FAIL - create-secrets.sh must default to the documented config-sync Secret names"
  exit 1
fi
green "ok  - create-secrets.sh creates a 32-byte CONFIG_SYNC_LKG_KEY for both data planes"

# ---------------------------------------------------------------------------
# AUT-385 / AUT-386 / AUT-392: AlertEngine ClickHouse DB, firewall REDIS_URL,
# and umbrella IAM inheritance for gateway POSTGRES_LOGIN.
# ---------------------------------------------------------------------------
blue "==> Scenario 21: AlertEngine reads the events database (AUT-385)"
out21="$TMP/scenario-alertengine-ch-default.yaml"
render_default "$out21" --set global.deploymentMode=external
if ! ruby -ryaml -e '
  docs = YAML.load_stream(File.read(ARGV[0])).compact
  cm = docs.find { |d| d["kind"] == "ConfigMap" && d.dig("metadata", "name") == "alertengine-env-vars" }
  abort "alertengine-env-vars not rendered" if cm.nil?
  db = cm.dig("data", "CLICKHOUSE_DATABASE")
  abort "CLICKHOUSE_DATABASE=#{db.inspect}, want default" unless db == "default"
' "$out21"; then
  red "FAIL: AUT-385 AlertEngine CLICKHOUSE_DATABASE=default"
  exit 1
fi
green "ok  - AUT-385: AlertEngine CLICKHOUSE_DATABASE=default"

blue "==> Scenario 22: firewall REDIS_URL from shared Redis (AUT-386)"
out22="$TMP/scenario-firewall-redis-url.yaml"
render_default "$out22" --set global.deploymentMode=external
assert_contains "$out22" 'REDIS_URL: "redis://redis:6379/0"' \
  "AUT-386: firewall-config carries REDIS_URL for in-cluster Redis"
# Password-bearing URL must land in the Secret, not the ConfigMap.
# validate-values rejects a password against the chart's own Redis, so point at
# a managed host the same way operators do.
out22pw="$TMP/scenario-firewall-redis-url-pw.yaml"
render_default "$out22pw" --set global.deploymentMode=external \
  --set global.redis.deploy=false \
  --set global.redis.host=cache.example.com \
  --set global.redis.password=s3cret
if ! ruby -ryaml -e '
  docs = YAML.load_stream(File.read(ARGV[0])).compact
  cm = docs.find { |d| d["kind"] == "ConfigMap" && d.dig("metadata", "name") == "firewall-config" }
  abort "firewall-config missing" if cm.nil?
  abort "password REDIS_URL leaked into ConfigMap" if cm.dig("data", "REDIS_URL")
  sec = docs.find { |d| d["kind"] == "Secret" && d.dig("metadata", "name") == "firewall-secrets" }
  abort "firewall-secrets missing" if sec.nil?
  raw = sec.dig("data", "REDIS_URL")
  abort "firewall-secrets missing REDIS_URL" if raw.nil? || raw.empty?
  url = raw.unpack1("m0")
  abort "unexpected REDIS_URL=#{url.inspect}" unless url.include?("s3cret") && url.include?("cache.example.com") && url.start_with?("redis://")
' "$out22pw"; then
  red "FAIL: AUT-386 password REDIS_URL placement"
  exit 1
fi
green "ok  - AUT-386: password REDIS_URL lives in firewall-secrets"

blue "==> Scenario 23: umbrella IAM drives gateway POSTGRES_LOGIN (AUT-392)"
# global.authMode=iam + unset per-service ⇒ POSTGRES_LOGIN=aws
out23iam="$TMP/scenario-iam-inherit.yaml"
render_default "$out23iam" --set global.deploymentMode=external \
  --set global.postgresql.deploy=false \
  --set global.postgresql.host=pg.example.com \
  --set global.postgresql.authMode=iam \
  --set global.postgresql.awsRegion=eu-west-1
if ! ruby -ryaml -e '
  docs = YAML.load_stream(File.read(ARGV[0])).compact
  %w[agentgateway-env-vars trustguard-env-vars].each do |name|
    cm = docs.find { |d| d["kind"] == "ConfigMap" && d.dig("metadata", "name") == name }
    abort "#{name} not rendered" if cm.nil?
    login = cm.dig("data", "POSTGRES_LOGIN")
    abort "#{name} POSTGRES_LOGIN=#{login.inspect}, want aws" unless login == "aws"
    region = cm.dig("data", "AWS_REGION")
    abort "#{name} AWS_REGION=#{region.inspect}, want eu-west-1" unless region == "eu-west-1"
  end
' "$out23iam"; then
  red "FAIL: AUT-392 global IAM inheritance"
  exit 1
fi
green "ok  - AUT-392: global.postgresql.authMode=iam ⇒ POSTGRES_LOGIN=aws"

# Explicit per-service false still wins against global iam.
out23off="$TMP/scenario-iam-override-off.yaml"
render_default "$out23off" --set global.deploymentMode=external \
  --set global.postgresql.deploy=false \
  --set global.postgresql.host=pg.example.com \
  --set global.postgresql.authMode=iam \
  --set global.postgresql.awsRegion=eu-west-1 \
  --set agentgateway.database.iamAuth=false
if ! ruby -ryaml -e '
  docs = YAML.load_stream(File.read(ARGV[0])).compact
  ag = docs.find { |d| d["kind"] == "ConfigMap" && d.dig("metadata", "name") == "agentgateway-env-vars" }
  abort "agentgateway-env-vars not rendered" if ag.nil?
  login = ag.dig("data", "POSTGRES_LOGIN")
  abort "explicit iamAuth=false should leave POSTGRES_LOGIN unset, got #{login.inspect}" unless login.nil?
  tg = docs.find { |d| d["kind"] == "ConfigMap" && d.dig("metadata", "name") == "trustguard-env-vars" }
  abort "trustguard-env-vars not rendered" if tg.nil?
  tlogin = tg.dig("data", "POSTGRES_LOGIN")
  abort "trustguard should still inherit global IAM, got #{tlogin.inspect}" unless tlogin == "aws"
' "$out23off"; then
  red "FAIL: AUT-392 explicit iamAuth=false override"
  exit 1
fi
green "ok  - AUT-392: explicit iamAuth=false wins; sibling still inherits"

# ---------------------------------------------------------------------------
# AUT-403: ConfigMap/Secret checksum annotations roll envFrom consumers.
# ---------------------------------------------------------------------------
blue "==> Scenario 24: AUT-403 checksum annotations change on config edits and stay stable on no-op"

# Helper: print "deploy|annotation|value" lines for the named Deployments.
aut403_ann() {
  local file=$1
  shift
  ruby -ryaml -e '
    want = ARGV[1..]
    docs = YAML.load_stream(File.read(ARGV[0])).compact
    docs.select { |d| d["kind"] == "Deployment" && want.include?(d.dig("metadata", "name")) }.each do |d|
      name = d.dig("metadata", "name")
      ann = d.dig("spec", "template", "metadata", "annotations") || {}
      ann.keys.sort.each { |k| puts "#{name}|#{k}|#{ann[k]}" if k.start_with?("checksum/") }
    end
  ' "$file" "$@"
}

out24a="$TMP/scenario-aut403-baseline.yaml"
render_default "$out24a"
out24b="$TMP/scenario-aut403-baseline-rerun.yaml"
render_default "$out24b"
out24c="$TMP/scenario-aut403-loglevel.yaml"
render_default "$out24c" --set agentgateway.config.logLevel=debug
out24d="$TMP/scenario-aut403-redis-host.yaml"
render_default "$out24d" --set global.redis.host=cache.example.com
out24e="$TMP/scenario-aut403-external.yaml"
render_default "$out24e" --set global.deploymentMode=external
out24f="$TMP/scenario-aut403-external-fw.yaml"
render_default "$out24f" --set global.deploymentMode=external \
  --set firewall.firewall.config.otelEnvironment=aut403-test

# Every envFrom v2 workload must carry at least the env ConfigMap checksum.
# Secrets checksum is also required where the chart owns the Secret; its value
# is intentionally NOT asserted for byte-stability across bare helm template
# runs, because resolveSecret/randAlphaNum regenerates without cluster lookup.
# Live upgrades stay stable via lookup — that is the helm-diff gate.
if ! ruby -ryaml -e '
  docs = YAML.load_stream(File.read(ARGV[0])).compact
  # Hybrid profile (values-required): no agentgateway-admin / trustguard-control-plane.
  required = {
    "agentgateway-proxy" => %w[checksum/env-configmap checksum/secrets checksum/redis-secrets],
    "agentgateway-mcp" => %w[checksum/env-configmap checksum/secrets checksum/redis-secrets],
    "trustguard-data-plane" => %w[checksum/env-configmap checksum/secrets checksum/redis-secrets],
    "dataagent" => %w[checksum/env-configmap],
    "dataagent-trustguard" => %w[checksum/env-configmap],
    "firewall" => %w[checksum/configmap],
  }
  docs.select { |d| d["kind"] == "Deployment" }.each do |d|
    name = d.dig("metadata", "name")
    next unless required.key?(name)
    ann = d.dig("spec", "template", "metadata", "annotations") || {}
    required[name].each do |key|
      abort "#{name} missing #{key}" unless ann[key].to_s =~ /\A[0-9a-f]{64}\z/
    end
  end
' "$out24a"; then
  red "FAIL: AUT-403 hybrid workloads missing checksum annotations"
  exit 1
fi
green "ok  - AUT-403: hybrid envFrom workloads carry ConfigMap/Secret/redis checksums"

if ! ruby -ryaml -e '
  docs = YAML.load_stream(File.read(ARGV[0])).compact
  required = {
    "agentgateway-admin" => %w[checksum/env-configmap checksum/secrets],
    "agentgateway-proxy" => %w[checksum/env-configmap checksum/secrets],
    "agentgateway-mcp" => %w[checksum/env-configmap checksum/secrets],
    "trustguard-control-plane" => %w[checksum/env-configmap checksum/secrets],
    "trustguard-data-plane" => %w[checksum/env-configmap checksum/secrets],
    "datacore" => %w[checksum/env-configmap checksum/secrets],
    "alertengine-api" => %w[checksum/env-configmap checksum/secrets],
    "alertengine-worker" => %w[checksum/env-configmap checksum/secrets],
    "firewall" => %w[checksum/configmap],
    "clickstack-collector" => %w[checksum/config checksum/secrets],
  }
  # Firewall workers share the gateway ConfigMap checksum.
  docs.select { |d| d["kind"] == "Deployment" }.each do |d|
    name = d.dig("metadata", "name").to_s
    keys = required[name]
    if keys.nil? && name.end_with?("-worker") && name != "alertengine-worker"
      # firewall toxicity-worker etc.
      keys = %w[checksum/configmap] if name.match?(/^(toxicity|indirect-prompt-injections|prompt-jailbreak|prompt-moderation|response-jailbreak)-worker$/)
    end
    next if keys.nil?
    ann = d.dig("spec", "template", "metadata", "annotations") || {}
    keys.each do |key|
      abort "#{name} missing #{key}" unless ann[key].to_s =~ /\A[0-9a-f]{64}\z/
    end
  end
' "$out24e"; then
  red "FAIL: AUT-403 external workloads missing checksum annotations"
  exit 1
fi
green "ok  - AUT-403: external envFrom workloads carry ConfigMap/Secret checksums"

# Deterministic ConfigMap checksums must be byte-identical across two no-op renders.
env_a=$(aut403_ann "$out24a" agentgateway-proxy | awk -F'|' '$2=="checksum/env-configmap"{print $3}')
env_b=$(aut403_ann "$out24b" agentgateway-proxy | awk -F'|' '$2=="checksum/env-configmap"{print $3}')
redis_a=$(aut403_ann "$out24a" agentgateway-proxy | awk -F'|' '$2=="checksum/redis-secrets"{print $3}')
redis_b=$(aut403_ann "$out24b" agentgateway-proxy | awk -F'|' '$2=="checksum/redis-secrets"{print $3}')
if [ -z "$env_a" ] || [ "$env_a" != "$env_b" ]; then
  red "FAIL: AUT-403 env-configmap checksum not stable across identical renders"
  exit 1
fi
if [ -z "$redis_a" ] || [ "$redis_a" != "$redis_b" ]; then
  red "FAIL: AUT-403 redis-secrets checksum not stable across identical renders"
  exit 1
fi
green "ok  - AUT-403: env-configmap and redis-secrets checksums are byte-stable on no-op"

# A ConfigMap value edit must flip only the env checksum.
env_c=$(aut403_ann "$out24c" agentgateway-proxy | awk -F'|' '$2=="checksum/env-configmap"{print $3}')
redis_c=$(aut403_ann "$out24c" agentgateway-proxy | awk -F'|' '$2=="checksum/redis-secrets"{print $3}')
if [ "$env_a" = "$env_c" ]; then
  red "FAIL: AUT-403 logLevel change did not flip checksum/env-configmap"
  exit 1
fi
if [ "$redis_a" != "$redis_c" ]; then
  red "FAIL: AUT-403 logLevel change unexpectedly flipped checksum/redis-secrets"
  exit 1
fi
green "ok  - AUT-403: ConfigMap edit flips env-configmap checksum only"

# A Redis host edit must flip the umbrella redis checksum, not the env ConfigMap.
env_d=$(aut403_ann "$out24d" agentgateway-proxy | awk -F'|' '$2=="checksum/env-configmap"{print $3}')
redis_d=$(aut403_ann "$out24d" agentgateway-proxy | awk -F'|' '$2=="checksum/redis-secrets"{print $3}')
if [ "$redis_a" = "$redis_d" ]; then
  red "FAIL: AUT-403 redis host change did not flip checksum/redis-secrets"
  exit 1
fi
if [ "$env_a" != "$env_d" ]; then
  red "FAIL: AUT-403 redis host change unexpectedly flipped checksum/env-configmap"
  exit 1
fi
green "ok  - AUT-403: umbrella redis-secrets checksum tracks global.redis.host"

fw_e=$(aut403_ann "$out24e" firewall | awk -F'|' '$2=="checksum/configmap"{print $3}')
fw_f=$(aut403_ann "$out24f" firewall | awk -F'|' '$2=="checksum/configmap"{print $3}')
if [ -z "$fw_e" ] || [ "$fw_e" = "$fw_f" ]; then
  red "FAIL: AUT-403 firewall config edit did not flip checksum/configmap"
  exit 1
fi
green "ok  - AUT-403: firewall ConfigMap edit flips checksum/configmap"

# ---------------------------------------------------------------------------
# saas mode: a customer-owned central control plane serving data planes that
# live in other clusters. external, plus DataBridge, the ClickStack ingest
# gateway, DataCore in hybrid residency, and published config-sync listeners.
# ---------------------------------------------------------------------------
blue "==> Scenario 25: saas mode (central control plane for remote data planes)"

# Happy path: deploymentMode + domain only. Chart defaults mint self-signed TLS,
# HA DataBridge, AWS L4 annotations (when platform=aws), and publish config-sync.
SAAS_ARGS=(
  --set global.deploymentMode=saas
  --set global.domain=cp.example.com
)

# BYO-cert path (existingSecret) still supported for production PKI tests below.
SAAS_BYO_ARGS=(
  --set global.deploymentMode=saas
  --set global.domain=cp.example.com
  --set databridge.tls.existingSecret=databridge-southbound-tls
  --set agentgateway.configSync.grpcTls.existingSecret=ag-configsync-tls
  --set trustguard.configSync.grpcTls.existingSecret=tg-configsync-tls
)

out25="$TMP/scenario-saas.yaml"
render_default "$out25" "${SAAS_ARGS[@]}"

# --- saas is external plus three additions -------------------------------
assert_contains "$out25" '^  name: control-plane-api$' \
  "saas: control-plane-api renders (saas is a superset of external)"
assert_contains "$out25" '^          value: "external"$' \
  "saas: DEPLOYMENT_MODE stays external for the apps"
assert_contains "$out25" '^  name: databridge$' \
  "saas: DataBridge Deployment renders"
assert_contains "$out25" '^  name: databridge-northbound$' \
  "saas: DataBridge northbound Service renders"
assert_contains "$out25" '^  name: databridge-southbound$' \
  "saas: DataBridge southbound Service renders"
assert_contains "$out25" '^  name: clickstack-ingest-gateway$' \
  "saas: ClickStack ingest gateway renders"
# Ingress is the product path (hybrid OTLP/HTTP). Default ON; inherits
# global.ingress like app/api. Host is telemetry.<controlPlane.domain>.
assert_contains "$out25" '^  name: clickstack-ingest-gateway$' \
  "saas: ingest gateway resource name present"
# The Ingress shares the Deployment name; select by kind.
gw_ing_host=$(yq -N 'select(.kind == "Ingress" and .metadata.name == "clickstack-ingest-gateway")
  | .spec.rules[0].host' "$out25" | sed '/^$/d' | head -1)
if [[ "$gw_ing_host" != "telemetry.cp.example.com" ]]; then
  red "FAIL: saas: ingest gateway Ingress host want telemetry.cp.example.com got: ${gw_ing_host:-<none>}"
  exit 1
fi
green "ok  - saas: ingest gateway Ingress is enabled by default (telemetry.<domain>)"
gw_ing_backend=$(yq -N 'select(.kind == "Ingress" and .metadata.name == "clickstack-ingest-gateway")
  | .spec.rules[0].http.paths[0].backend.service.port.name' "$out25" | sed '/^$/d' | head -1)
if [[ "$gw_ing_backend" != "otlp-http" ]]; then
  red "FAIL: saas: ingest gateway Ingress must target otlp-http (got: ${gw_ing_backend:-<none>})"
  exit 1
fi
green "ok  - saas: ingest gateway Ingress backends OTLP/HTTP"

# --- every image comes from one registry ----------------------------------
# An air-gapped install mirrors what it is told to mirror. An image with no
# registry host resolves to Docker Hub, which such a cluster cannot reach and
# which no mirroring list mentions, so the pod only fails at pull time. Assert
# the shape rather than a list of names so a component added later is covered.
hub_images=$(grep -oE 'image: *"?[^"]+' "$out25" | sed 's/image: *"*//' | sort -u \
  | awk -F/ '$1 !~ /[.:]/')
if [[ -n "$hub_images" ]]; then
  red "FAIL: saas: image(s) resolve to Docker Hub rather than a mirrorable registry:"
  printf '  %s\n' $hub_images
  exit 1
fi
green "ok  - saas: every image carries an explicit registry host"

# The gateway runs the same upstream collector as the egress sidecars. Pulling
# it from the NeuralTrust mirror keeps one registry, one pull secret, one entry
# in the mirroring list.
assert_contains "$out25" '^          image: "europe-west1-docker\.pkg\.dev/neuraltrust-app-prod/nt-docker/opentelemetry-collector-contrib:' \
  "saas: ingest gateway pulls the collector from the NeuralTrust mirror"
# Select by kind: the Deployment shares its name with the Service and the
# ServiceAccount, and only the Deployment carries the pull secret.
gw_pull=$(yq eval 'select(.kind == "Deployment" and .metadata.name == "clickstack-ingest-gateway")
  | (.spec.template.spec.imagePullSecrets // []) | map(.name) | join(",")' "$out25")
if [[ "$gw_pull" != *gcr-secret* ]]; then
  red "FAIL: saas: ingest gateway has no pull secret for that private registry (got: ${gw_pull:-<none>})"
  exit 1
fi
green "ok  - saas: ingest gateway carries a pull secret for that private registry"

# A mirror has to replace the pinned registry, not be prepended to it: the naive
# form yields <mirror>/europe-west1-docker.pkg.dev/... which exists nowhere.
out25m="$TMP/scenario-saas-mirror.yaml"
render_default "$out25m" "${SAAS_ARGS[@]}" \
  --set global.imageRegistry=registry.internal.example.com/mirror
assert_contains "$out25m" '^          image: "registry\.internal\.example\.com/mirror/opentelemetry-collector-contrib:' \
  "saas: global.imageRegistry retargets the ingest gateway collector"
assert_not_contains "$out25m" 'mirror/europe-west1-docker\.pkg\.dev' \
  "saas: the mirror replaces the pinned registry instead of prefixing it"

# --- DataCore drives the remote planes through DataBridge ----------------
assert_contains "$out25" '^  RESIDENCY_BACKEND: "hybrid"$' \
  "saas: DataCore runs hybrid residency, not direct ClickHouse"
assert_contains "$out25" '^  DATABRIDGE_ADDR: "databridge-northbound\.default\.svc\.cluster\.local:50051"$' \
  "saas: DataCore dials the northbound Service this chart renders"

# The gateway verifies tokens DataCore mints. A mismatch on either the issuer
# or the audience rejects every batch at runtime with a 401, so compare the two
# sides instead of asserting each against a literal.
dc_issuer=$(grep -m1 '^  TELEMETRY_JWT_ISSUER_URL: ' "$out25" | sed 's/.*: //' | tr -d '"')
dc_aud=$(grep -m1 '^  TELEMETRY_JWT_AUDIENCE: ' "$out25" | sed 's/.*: //' | tr -d '"')
gw_issuer=$(grep -m1 'issuer_url: ' "$out25" | sed 's/.*issuer_url: //' | tr -d '"')
gw_aud=$(grep -m1 '^            audience: ' "$out25" | sed 's/.*: //' | tr -d '"')
if [[ -z "$dc_issuer" || "$dc_issuer" != "$gw_issuer" ]]; then
  red "FAIL: saas: ingest gateway OIDC issuer ($gw_issuer) does not match DataCore ($dc_issuer)"
  exit 1
fi
if [[ -z "$dc_aud" || "$dc_aud" != "$gw_aud" ]]; then
  red "FAIL: saas: ingest gateway audience ($gw_aud) does not match DataCore ($dc_aud)"
  exit 1
fi
green "ok  - saas: ingest gateway verifies exactly the tokens DataCore mints"

# OIDC identifies an issuer by its URL, and the gateway rejects any token whose
# iss claim is a different string. DataCore's own default for iss is the bare
# name "datacore", which never matches a URL, so the chart pins both to one
# value — assert they agree rather than assert either against a literal.
dc_iss=$(grep -m1 '^  TELEMETRY_JWT_ISSUER: ' "$out25" | sed 's/.*: //' | tr -d '"')
if [[ -z "$dc_iss" || "$dc_iss" != "$dc_issuer" ]]; then
  red "FAIL: saas: DataCore signs iss=$dc_iss but advertises issuer $dc_issuer; the ingest gateway would reject every batch"
  exit 1
fi
green "ok  - saas: the iss DataCore signs matches the issuer it advertises"

# --- gateway -> collector hop is authenticated -----------------------------
# Verifying the sender's JWT only proves who called the gateway; it does not
# authenticate the gateway to clickstack-collector, which enforces its own
# OTLP_AUTH_TOKEN. Without this the batch is accepted at the edge and dropped
# on the last hop with "Unauthenticated: missing or empty authorization
# header" — every upstream check green while telemetry silently disappears.
gw_auth=$(yq -N 'select(.kind == "ConfigMap" and .metadata.name == "clickstack-ingest-gateway-config")
  | .data["collector.yaml"]' "$out25" 2>/dev/null \
  | yq -N '.exporters["otlphttp/clickstack"].auth.authenticator' 2>/dev/null)
if [[ "$gw_auth" != "bearertokenauth/downstream" ]]; then
  red "FAIL: saas: gateway forwards to clickstack-collector unauthenticated (got: ${gw_auth:-<none>})"
  exit 1
fi
green "ok  - saas: gateway authenticates itself to the downstream collector"

# scheme must stay empty: the collector compares the Authorization header
# against the raw OTLP_AUTH_TOKEN, so a default "Bearer " prefix 401s.
gw_scheme=$(yq -N 'select(.kind == "ConfigMap" and .metadata.name == "clickstack-ingest-gateway-config")
  | .data["collector.yaml"]' "$out25" 2>/dev/null \
  | yq -N '.extensions["bearertokenauth/downstream"].scheme' 2>/dev/null)
if [[ -n "$gw_scheme" && "$gw_scheme" != '""' ]]; then
  red "FAIL: saas: downstream bearer scheme must be empty to match OTLP_AUTH_TOKEN (got: $gw_scheme)"
  exit 1
fi
green "ok  - saas: downstream bearer token is sent raw, no Bearer prefix"

# The token comes from the Secret, never inlined into the ConfigMap.
assert_contains "$out25" '^                  key: OTLP_AUTH_TOKEN$' \
  "saas: gateway reads OTLP_AUTH_TOKEN from the collector Secret"

# OTLP/HTTP, not gRPC: gRPC refuses per-RPC credentials on a cleartext
# connection ("credentials require transport level security") and the
# collector crashloops at startup.
gw_ds=$(yq -N 'select(.kind == "ConfigMap" and .metadata.name == "clickstack-ingest-gateway-config")
  | .data["collector.yaml"]' "$out25" 2>/dev/null \
  | yq -N '.exporters["otlphttp/clickstack"].endpoint' 2>/dev/null)
if [[ "$gw_ds" != http://clickstack-collector.*:4318 ]]; then
  red "FAIL: saas: downstream must be OTLP/HTTP :4318 or the bearer hop crashloops (got: ${gw_ds:-<none>})"
  exit 1
fi
green "ok  - saas: downstream hop uses OTLP/HTTP so bearer auth can attach"

# --- published config-sync listeners --------------------------------------
assert_contains "$out25" '^  name: agentgateway-admin-configsync$' \
  "saas: AgentGateway config-sync Service is published"
assert_contains "$out25" '^  name: trustguard-control-plane-configsync$' \
  "saas: TrustGuard config-sync Service is published"
assert_contains "$out25" 'neuraltrust\.ai/config-sync-host: "agentgateway-configsync\.cp\.example\.com"' \
  "saas: AgentGateway config-sync published under the customer domain"
assert_contains "$out25" 'neuraltrust\.ai/config-sync-host: "trustguard-configsync\.cp\.example\.com"' \
  "saas: TrustGuard config-sync published under the customer domain"

# Port 443 in, gRPC listener out. Getting targetPort wrong sends config-sync
# traffic to the HTTP API, which answers, so this fails quietly in a cluster.
cs_ag="$TMP/scenario-saas-cs-ag.yaml"
document_named "$out25" agentgateway-admin-configsync "$cs_ag"
assert_contains "$cs_ag" '^      port: 443$' \
  "saas: AgentGateway config-sync listens on 443"
assert_contains "$cs_ag" '^      targetPort: 8083$' \
  "saas: AgentGateway config-sync forwards to the gRPC listener"
assert_contains "$cs_ag" '^  type: LoadBalancer$' \
  "saas: AgentGateway config-sync is L4, not an Ingress"

# --- neither existing mode grows any of this ------------------------------
out25ext="$TMP/scenario-saas-external-unchanged.yaml"
render_default "$out25ext" --set global.deploymentMode=external
for absent in '^  name: databridge$' '^  name: clickstack-ingest-gateway$' '\-configsync$'; do
  assert_not_contains "$out25ext" "$absent" \
    "external: no saas-only resource matching $absent"
done
assert_contains "$out25ext" '^  RESIDENCY_BACKEND: "saas"$' \
  "external: DataCore keeps its own residency backend"

# --- a remote data plane retargets onto the customer domain ---------------
# hybrid is what the remote clusters run; they must dial the central cluster
# rendered above rather than NeuralTrust.
out25c="$TMP/scenario-saas-remote.yaml"
render_default "$out25c" \
  --set global.deploymentMode=hybrid \
  --set global.controlPlane.domain=cp.example.com \
  --set agentgateway.configSync.token=cs-trustgate \
  --set trustguard.configSync.token=cs-trustguard
assert_contains "$out25c" '^          value: "agentgateway-configsync\.cp\.example\.com:443"$' \
  "remote: AgentGateway dials the central config-sync listener"
assert_contains "$out25c" '^          value: "trustguard-configsync\.cp\.example\.com:443"$' \
  "remote: TrustGuard dials the central config-sync listener"
assert_contains "$out25c" 'databridge\.cp\.example\.com:443' \
  "remote: DataAgent enrols against the central DataBridge"
assert_contains "$out25c" 'telemetry\.cp\.example\.com' \
  "remote: telemetry egress targets the central ingest gateway"
assert_not_contains "$out25c" 'neuraltrust\.ai:443' \
  "remote: nothing still points at NeuralTrust SaaS"

# The region map must keep working untouched for everyone not setting a domain.
out25r="$TMP/scenario-saas-region-default.yaml"
render_default "$out25r" \
  --set global.deploymentMode=hybrid \
  --set agentgateway.configSync.token=cs-trustgate
assert_contains "$out25r" '^          value: "agentgateway-configsync\.neuraltrust\.ai:443"$' \
  "hybrid: no controlPlane.domain still resolves through saasRegion"

# --- fail-closed guards ---------------------------------------------------
# Both rejected auth modes authenticate every data plane with one shared
# credential, then believe whatever tenant each agent claims.
assert_render_fails_with 'is not allowed with global.deploymentMode=saas' \
  "saas: shared-token DataBridge auth mode rejected" \
  "${SAAS_ARGS[@]}" --set databridge.auth.mode=token
assert_render_fails_with 'is not allowed with global.deploymentMode=saas' \
  "saas: dev DataBridge auth mode rejected" \
  "${SAAS_ARGS[@]}" --set databridge.auth.mode=dev
assert_render_fails_with 'databridge.auth.mode must be one of' \
  "saas: unknown DataBridge auth mode rejected" \
  "${SAAS_ARGS[@]}" --set databridge.auth.mode=mtls

# --- DataBridge peer forwarding (AUT-495) — HA is the default --------------
# replicas >= 2 requires headless (default). Explicit discovery=off fails.
# Singleton escape hatch: replicas=1 forces discovery off.
assert_render_fails_with 'requires peer forwarding' \
  "saas: replicas >= 2 with peer discovery off is refused" \
  "${SAAS_ARGS[@]}" --set databridge.peers.discovery=off
assert_render_fails_with 'databridge.peers.discovery must be' \
  "saas: an unknown peer discovery mode fails the render" \
  "${SAAS_ARGS[@]}" --set databridge.peers.discovery=redis

# Default install: HA (replicas=2 + headless peer Service + POD_IP).
assert_contains "$out25" '^  PEER_DISCOVERY: "headless"$' \
  "saas: DataBridge defaults to headless peer forwarding"
assert_contains "$out25" '^  name: databridge-peers$' \
  "saas: headless peer Service renders by default"
assert_env_value "$out25" databridge databridge POD_IP fieldRef:status.podIP \
  "saas: POD_IP is injected when peer forwarding is on"
db_replicas=$(yq eval 'select(.kind == "Deployment" and .metadata.name == "databridge") | .spec.replicas' "$out25" | sed '/^$/d' | head -1)
if [[ "$db_replicas" != "2" ]]; then
  red "FAIL: saas: DataBridge default replicas want 2 got: ${db_replicas:-<none>}"
  exit 1
fi
green "ok  - saas: DataBridge defaults to 2 replicas"

# A ClusterIP here would load-balance "who holds agent X?" to an arbitrary pod,
# including back to the asker, which is the one answer that is never useful.
peers_clusterip=$(yq eval 'select(.kind == "Service" and .metadata.name == "databridge-peers")
  | .spec.clusterIP' "$out25")
if [[ "$peers_clusterip" != "None" ]]; then
  red "FAIL: peers: the discovery Service must be headless (clusterIP: ${peers_clusterip:-<unset>})"
  exit 1
fi
green "ok  - peers: the discovery Service is headless"
peers_notready=$(yq eval 'select(.kind == "Service" and .metadata.name == "databridge-peers")
  | .spec.publishNotReadyAddresses' "$out25")
if [[ "$peers_notready" != "true" ]]; then
  red "FAIL: peers: the discovery Service hides not-ready pods (got: $peers_notready)"
  exit 1
fi
green "ok  - peers: the discovery Service publishes not-ready addresses"

assert_contains "$out25" '^  PEER_SERVICE_NAME: "databridge-peers\.default\.svc\.cluster\.local"$' \
  "peers: replicas resolve the headless Service this chart renders"
assert_contains "$out25" '^  PEER_PORT: "50051"$' \
  "peers: siblings are dialled on the northbound port"
peers_affinity=$(yq eval 'select(.kind == "Deployment" and .metadata.name == "databridge")
  | .spec.template.spec.affinity.podAntiAffinity
  | (.preferredDuringSchedulingIgnoredDuringExecution[0].podAffinityTerm.topologyKey // "")' "$out25")
if [[ "$peers_affinity" != "kubernetes.io/hostname" ]]; then
  red "FAIL: peers: replicas are not spread across nodes (topologyKey: ${peers_affinity:-<none>})"
  exit 1
fi
green "ok  - peers: replicas prefer separate nodes"

# Singleton opt-down: replicas < 2 forces discovery off.
out25single="$TMP/scenario-saas-databridge-singleton.yaml"
render_default "$out25single" "${SAAS_ARGS[@]}" --set databridge.replicas=1
assert_contains "$out25single" '^  PEER_DISCOVERY: "off"$' \
  "saas: replicas=1 forces peer discovery off"
assert_not_contains "$out25single" '^  name: databridge-peers$' \
  "saas: no headless peer Service in singleton mode"
assert_env_value "$out25single" databridge databridge POD_IP ABSENT \
  "saas: no POD_IP in singleton mode"

assert_pdb_shape() {
  local file="$1" field="$2" want="$3" msg="$4" got
  got=$(yq eval "select(.kind == \"PodDisruptionBudget\" and .metadata.name == \"databridge\") | .spec.$field" "$file")
  if [[ "$got" != "$want" ]]; then
    red "FAIL: $msg"
    red "  expected spec.$field=$want, got $got"
    exit 1
  fi
  green "ok  - $msg"
}
assert_pdb_shape "$out25single" maxUnavailable 1 \
  "saas: a single-replica DataBridge lets a node drain evict its only pod"
assert_pdb_shape "$out25single" minAvailable null \
  "saas: a single-replica DataBridge does not deadlock the drain with minAvailable"
assert_pdb_shape "$out25" minAvailable 1 \
  "peers: several replicas keep one available through a drain"
assert_pdb_shape "$out25" maxUnavailable null \
  "peers: several replicas do not fall back to maxUnavailable"

out25pdb="$TMP/scenario-saas-databridge-pdb-override.yaml"
render_default "$out25pdb" "${SAAS_ARGS[@]}" \
  --set databridge.podDisruptionBudget.maxUnavailable=1
assert_pdb_shape "$out25pdb" maxUnavailable 1 \
  "peers: an explicit maxUnavailable overrides the replica-derived default"

db_strategy=$(yq eval 'select(.kind == "Deployment" and .metadata.name == "databridge")
  | [.spec.strategy.type, (.spec.strategy.rollingUpdate.maxUnavailable | tostring)] | join(",")' "$out25" \
  | sed '/^$/d')
if [[ "$db_strategy" != "RollingUpdate,0" ]]; then
  red "FAIL: saas: DataBridge does not roll without taking its pod down first (got: $db_strategy)"
  exit 1
fi
green "ok  - saas: DataBridge replaces a pod before removing the old one"

# Explicit opt-out of auto TLS without BYO secret still fails.
assert_render_fails_with 'southbound TLS cert for DataBridge' \
  "saas: DataBridge with autoGenerate=false and no secret rejected" \
  --set global.deploymentMode=saas \
  --set global.domain=cp.example.com \
  --set databridge.tls.autoGenerate=false \
  --set agentgateway.configSync.expose.enabled=false \
  --set trustguard.configSync.expose.enabled=false
assert_render_fails_with 'configSync.expose needs a certificate the data planes will accept' \
  "saas: publishing config-sync with selfSignedTls=false and no secret rejected" \
  --set global.deploymentMode=saas \
  --set global.domain=cp.example.com \
  --set agentgateway.configSync.expose.selfSignedTls=false \
  --set trustguard.configSync.expose.enabled=false
assert_render_fails_with 'export-controlplane-ca.sh' \
  "saas: the DataBridge cert guard points at the CA export path" \
  --set global.deploymentMode=saas \
  --set global.domain=cp.example.com \
  --set databridge.tls.autoGenerate=false \
  --set agentgateway.configSync.expose.enabled=false \
  --set trustguard.configSync.expose.enabled=false

# Opting out is how you keep a listener private, not by leaving it uncertified.
out25priv="$TMP/scenario-saas-configsync-private.yaml"
render_default "$out25priv" \
  --set global.deploymentMode=saas \
  --set global.domain=cp.example.com \
  --set agentgateway.configSync.expose.enabled=false \
  --set trustguard.configSync.expose.enabled=false
assert_not_contains "$out25priv" '\-configsync$' \
  "saas: configSync.expose.enabled=false keeps both listeners ClusterIP"

# Default saas render mints DataBridge + config-sync CAs (happy path).
# Telemetry ingress CA still needs ingress.tls.autoGenerate (HTTP edge often uses ACM).
out25gen="$TMP/scenario-saas-selfsigned.yaml"
render_default "$out25gen" \
  --set global.deploymentMode=saas \
  --set global.domain=cp.example.com \
  --set clickstack-ingest-gateway.ingress.tls.autoGenerate=true
assert_contains "$out25gen" '^  name: databridge-southbound-tls$' \
  "saas: default autoGenerate mints the DataBridge southbound keypair"
assert_contains "$out25gen" '^  name: clickstack-ingest-gateway-tls$' \
  "saas: ingress.tls.autoGenerate mints the telemetry keypair"
assert_contains "$out25gen" '^      secretName: "clickstack-ingest-gateway-tls"$' \
  "saas: the telemetry Ingress serves the generated keypair"

for component in southbound-tls configsync-tls telemetry-ingress-tls; do
  count="$(yq -N "select(.kind==\"Secret\" and .metadata.labels.\"app.kubernetes.io/component\"==\"$component\" and (.data | has(\"ca.crt\"))) | .metadata.name" "$out25gen" | grep -c . || true)"
  if [[ "$count" -eq 0 ]]; then
    red "FAIL: saas: no ca.crt-bearing Secret labelled $component, so the CA export script would miss it"
    exit 1
  fi
  green "ok  - saas: $component secrets are labelled for CA export ($count)"
done

cert_sans() {
  yq -N "select(.kind==\"Secret\" and .metadata.name==\"$2\") | .data.\"tls.crt\"" "$1" \
    | base64 -d 2>/dev/null | openssl x509 -noout -ext subjectAltName 2>/dev/null
}
for pair in "databridge-southbound-tls:databridge.cp.example.com" \
            "agentgateway-configsync-tls:agentgateway-configsync.cp.example.com" \
            "trustguard-configsync-tls:trustguard-configsync.cp.example.com" \
            "clickstack-ingest-gateway-tls:telemetry.cp.example.com"; do
  secret="${pair%%:*}"; host="${pair##*:}"
  if ! cert_sans "$out25gen" "$secret" | grep -q "DNS:$host"; then
    red "FAIL: saas: $secret does not cover $host, so remote planes fail the handshake on the name"
    exit 1
  fi
  green "ok  - saas: $secret covers $host"
done

# AWS L4 defaults: empty annotations ⇒ internal NLB on platform=aws.
out25aws="$TMP/scenario-saas-aws-l4.yaml"
render_default "$out25aws" \
  --set global.deploymentMode=saas \
  --set global.domain=cp.example.com \
  --set global.platform=aws
sb_scheme=$(yq -N 'select(.kind == "Service" and .metadata.name == "databridge-southbound")
  | .metadata.annotations["service.beta.kubernetes.io/aws-load-balancer-scheme"]' "$out25aws" | sed '/^$/d' | head -1)
if [[ "$sb_scheme" != "internal" ]]; then
  red "FAIL: saas aws: DataBridge southbound want scheme internal got: ${sb_scheme:-<none>}"
  exit 1
fi
green "ok  - saas aws: DataBridge southbound gets internal NLB by default"
cs_type=$(yq -N 'select(.kind == "Service" and .metadata.name == "agentgateway-admin-configsync")
  | .metadata.annotations["service.beta.kubernetes.io/aws-load-balancer-type"]' "$out25aws" | sed '/^$/d' | head -1)
if [[ "$cs_type" != "nlb" ]]; then
  red "FAIL: saas aws: config-sync want nlb got: ${cs_type:-<none>}"
  exit 1
fi
green "ok  - saas aws: config-sync expose gets NLB annotations by default"
out25aws_pub="$TMP/scenario-saas-aws-l4-public.yaml"
render_default "$out25aws_pub" \
  --set global.deploymentMode=saas \
  --set global.domain=cp.example.com \
  --set global.platform=aws \
  --set global.controlPlane.loadBalancerScheme=internet-facing
sb_pub=$(yq -N 'select(.kind == "Service" and .metadata.name == "databridge-southbound")
  | .metadata.annotations["service.beta.kubernetes.io/aws-load-balancer-scheme"]' "$out25aws_pub" | sed '/^$/d' | head -1)
if [[ "$sb_pub" != "internet-facing" ]]; then
  red "FAIL: saas aws: loadBalancerScheme=internet-facing want internet-facing got: ${sb_pub:-<none>}"
  exit 1
fi
green "ok  - saas aws: one global knob flips L4 scheme to internet-facing"

# --- local annotations must MERGE over the scheme, not replace it ------------
# Regression: l4Annotations used to return local annotations verbatim, so a
# values file that set any annotation at all silently dropped the scheme derived
# from loadBalancerScheme. The Service came up internal, a remote data plane in
# another VPC dialled an RFC1918 address, and the resulting `i/o timeout` read as
# an application fault. Every published L4 Service is checked: they are reached
# from other clusters, so a silent internal is an outage on each one.
out25merge="$TMP/scenario-saas-aws-l4-merge.yaml"
render_default "$out25merge" \
  --set global.deploymentMode=saas \
  --set global.domain=cp.example.com \
  --set global.platform=aws \
  --set global.controlPlane.loadBalancerScheme=internet-facing \
  --set 'databridge.service.southbound.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-nlb-target-type=ip' \
  --set 'agentgateway.configSync.expose.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-type=nlb' \
  --set 'trustguard.configSync.expose.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-type=nlb'
for svc in databridge-southbound agentgateway-admin-configsync trustguard-control-plane-configsync; do
  merged=$(yq -N "select(.kind == \"Service\" and .metadata.name == \"$svc\")
    | .metadata.annotations[\"service.beta.kubernetes.io/aws-load-balancer-scheme\"]" "$out25merge" | sed '/^$/d' | head -1)
  if [[ "$merged" != "internet-facing" ]]; then
    red "FAIL: saas aws: $svc local annotations dropped the global scheme (got: ${merged:-<none>})"
    exit 1
  fi
done
green "ok  - saas aws: local L4 annotations merge over the global scheme instead of replacing it"

# An explicit local scheme is still authoritative — merging must not take away
# the operator's ability to override one Service.
out25override="$TMP/scenario-saas-aws-l4-override.yaml"
render_default "$out25override" \
  --set global.deploymentMode=saas \
  --set global.domain=cp.example.com \
  --set global.platform=aws \
  --set global.controlPlane.loadBalancerScheme=internet-facing \
  --set 'databridge.service.southbound.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-scheme=internal'
sb_override=$(yq -N 'select(.kind == "Service" and .metadata.name == "databridge-southbound")
  | .metadata.annotations["service.beta.kubernetes.io/aws-load-balancer-scheme"]' "$out25override" | sed '/^$/d' | head -1)
if [[ "$sb_override" != "internal" ]]; then
  red "FAIL: saas aws: an explicit local scheme must win over the global knob (got: ${sb_override:-<none>})"
  exit 1
fi
green "ok  - saas aws: an explicit local scheme still overrides the global knob"

# An internet-facing control plane without source ranges is open to the world,
# so the allowlist has to survive templating on every published Service.
out25ranges="$TMP/scenario-saas-aws-l4-ranges.yaml"
render_default "$out25ranges" \
  --set global.deploymentMode=saas \
  --set global.domain=cp.example.com \
  --set global.platform=aws \
  --set global.controlPlane.loadBalancerScheme=internet-facing \
  --set 'databridge.service.southbound.loadBalancerSourceRanges[0]=203.0.113.10/32' \
  --set 'agentgateway.configSync.expose.loadBalancerSourceRanges[0]=203.0.113.10/32' \
  --set 'trustguard.configSync.expose.loadBalancerSourceRanges[0]=203.0.113.10/32'
for svc in databridge-southbound agentgateway-admin-configsync trustguard-control-plane-configsync; do
  cidr=$(yq -N "select(.kind == \"Service\" and .metadata.name == \"$svc\")
    | .spec.loadBalancerSourceRanges[0]" "$out25ranges" | sed '/^$/d' | head -1)
  if [[ "$cidr" != "203.0.113.10/32" ]]; then
    red "FAIL: saas aws: $svc dropped loadBalancerSourceRanges (got: ${cidr:-<none>})"
    exit 1
  fi
done
green "ok  - saas aws: loadBalancerSourceRanges fence every published L4 Service"

# controlPlane.domain still wins over global.domain (split-DNS).
out25split="$TMP/scenario-saas-split-dns.yaml"
render_default "$out25split" \
  --set global.deploymentMode=saas \
  --set global.domain=ui.example.com \
  --set global.controlPlane.domain=dial.example.com
split_host=$(yq -N 'select(.kind == "Ingress" and .metadata.name == "clickstack-ingest-gateway")
  | .spec.rules[0].host' "$out25split" | sed '/^$/d' | head -1)
if [[ "$split_host" != "telemetry.dial.example.com" ]]; then
  red "FAIL: saas split-DNS: telemetry host want telemetry.dial.example.com got: ${split_host:-<none>}"
  exit 1
fi
green "ok  - saas: controlPlane.domain overrides global.domain for dial names"

# External keeps an in-cluster-only certificate: publishing is what adds the
# public name, so a mode that publishes nothing must not carry one.
if cert_sans "$out13" agentgateway-configsync-tls | grep -q 'configsync\.'; then
  red "FAIL: external: config-sync certificate carries a public name it never serves"
  exit 1
fi
green "ok  - external: config-sync certificate stays in-cluster only"

# --- remote side: trusting a private control plane ------------------------
# The three legs a remote data plane dials. Each reads its trust store
# differently, and two of them silently used system roots before this existed:
# the handshake fails at runtime with nothing wrong in the rendered manifest.
out25ca="$TMP/scenario-hybrid-private-ca.yaml"
render_default "$out25ca" \
  --set global.deploymentMode=hybrid \
  --set global.controlPlane.domain=cp.example.com \
  --set agentgateway.configSync.token=cs-trustgate \
  --set trustguard.configSync.token=cs-trustguard \
  --set global.customCaCert.enabled=true \
  --set global.customCaCert.secretName=controlplane-ca \
  --set dataagent.databridge.tlsCa=/etc/ssl/certs/custom-ca.crt \
  --set agentgateway.configSync.tlsCa=/etc/ssl/certs/custom-ca.crt \
  --set trustguard.configSync.tlsCa=/etc/ssl/certs/custom-ca.crt \
  --set global.clickstack.egress.tlsCaSecretName=controlplane-ca
assert_contains "$out25ca" '^  TLS_CA_FILE: "/etc/ssl/certs/custom-ca\.crt"$' \
  "remote: DataAgent verifies DataBridge against the supplied CA"
assert_contains "$out25ca" '^          value: "/etc/ssl/certs/custom-ca\.crt"$' \
  "remote: config-sync clients verify against the supplied CA"
assert_contains "$out25ca" '^          ca_file: /etc/otelcol/ca/ca\.crt$' \
  "remote: telemetry egress verifies the ingest gateway against the supplied CA"
assert_contains "$out25ca" '^      - name: egress-ca-bundle$' \
  "remote: the egress CA bundle is mounted, not just referenced in config"

# One-knob form: domain + raw NLB dial hosts + caSecretName. Mirrors the
# dataplane-bundle CONTROL_PLANE_* model so Docker and Helm hybrid installs
# share the same operator surface. SNI must stay on the cert name (domain),
# not the NLB hostname. DataBridge is genuinely shared; config-sync is per
# product, so two products pin each endpoint rather than a scalar
# controlPlane.configSyncAddr (that combination fails the render — AUT-540).
out25one="$TMP/scenario-hybrid-controlplane-one-knob.yaml"
render_default "$out25one" \
  --set global.deploymentMode=hybrid \
  --set global.controlPlane.domain=neuraltrust.es \
  --set global.controlPlane.databridgeAddr=k8s-databrid.elb.eu-west-1.amazonaws.com:443 \
  --set agentgateway.configSync.endpoint=k8s-agentgat.elb.eu-west-1.amazonaws.com:443 \
  --set trustguard.configSync.endpoint=k8s-trustgua.elb.eu-west-1.amazonaws.com:443 \
  --set global.controlPlane.telemetryUrl=https://k8s-telemetry.elb.eu-west-1.amazonaws.com \
  --set global.controlPlane.caSecretName=controlplane-ca \
  --set agentgateway.configSync.token=cs-trustgate \
  --set trustguard.configSync.token=cs-trustguard
assert_contains "$out25one" '^  DATABRIDGE_ADDR: "k8s-databrid\.elb\.eu-west-1\.amazonaws\.com:443"$' \
  "one-knob: DataAgent dials the raw DataBridge NLB"
assert_contains "$out25one" '^  DATABRIDGE_SERVER_NAME: "databridge\.neuraltrust\.es"$' \
  "one-knob: DataBridge SNI stays on the domain cert name"
assert_contains "$out25one" '^  TLS_CA_FILE: "/etc/ssl/certs/custom-ca\.crt"$' \
  "one-knob: caSecretName expands into DataAgent TLS_CA_FILE"
assert_contains "$out25one" '^          value: "k8s-agentgat\.elb\.eu-west-1\.amazonaws\.com:443"$' \
  "one-knob: AgentGateway config-sync dials its own NLB"
assert_contains "$out25one" '^          value: "k8s-trustgua\.elb\.eu-west-1\.amazonaws\.com:443"$' \
  "one-knob: TrustGuard config-sync dials its own NLB"
assert_contains "$out25one" '^          value: "agentgateway-configsync\.neuraltrust\.es"$' \
  "one-knob: AgentGateway config-sync SNI stays on the domain cert name"
assert_contains "$out25one" '^          value: "trustguard-configsync\.neuraltrust\.es"$' \
  "one-knob: TrustGuard config-sync SNI stays on the domain cert name"
assert_contains "$out25one" '^          value: "/etc/ssl/certs/custom-ca\.crt"$' \
  "one-knob: caSecretName expands into CONFIG_SYNC_TLS_CA"
assert_contains "$out25one" '^        endpoint: "https://k8s-telemetry\.elb\.eu-west-1\.amazonaws\.com"$' \
  "one-knob: egress exporter dials the telemetry URL override"
assert_contains "$out25one" '^          ca_file: /etc/otelcol/ca/ca\.crt$' \
  "one-knob: caSecretName expands into the egress collector CA"
assert_contains "$out25one" '^          include_system_ca_certs_pool: true$' \
  "one-knob: egress CA keeps system roots (public telemetry + chart L4)"
# Go's crypto/x509 treats SSL_CERT_FILE as a REPLACEMENT for the system bundle,
# which would empty SystemCertPool() and silently defeat the flag asserted above.
# The collector must trust its private anchor via exporter tls.ca_file only.
assert_env_value "$out25one" dataagent clickstack-egress-collector SSL_CERT_FILE ABSENT \
  "one-knob: egress collector has no SSL_CERT_FILE (would void the system pool)"
# The DataAgent binary is a different story: it wants an explicit CA file.
assert_env_value "$out25one" dataagent dataagent SSL_CERT_FILE '/etc/ssl/certs/custom-ca.crt' \
  "one-knob: DataAgent still gets the custom CA via SSL_CERT_FILE"
assert_contains "$out25one" '^            secretName: "controlplane-ca"$' \
  "one-knob: custom-ca-cert volume mounts caSecretName"

# Air-gapped operators may close the trust store to private PKI only.
out25nosys="$TMP/scenario-hybrid-egress-no-system-ca.yaml"
render_default "$out25nosys" \
  --set global.deploymentMode=hybrid \
  --set global.controlPlane.domain=platform.example.com \
  --set global.controlPlane.caSecretName=controlplane-ca \
  --set global.clickstack.egress.tlsIncludeSystemCaCerts=false \
  --set agentgateway.configSync.token=cs-trustgate
assert_contains "$out25nosys" '^          ca_file: /etc/otelcol/ca/ca\.crt$' \
  "closed trust store: ca_file still mounts when CA is set"
assert_not_contains "$out25nosys" 'include_system_ca_certs_pool' \
  "closed trust store: tlsIncludeSystemCaCerts=false omits system roots"

# Product-level overrides still beat the umbrella controlPlane dial hosts.
# Do not set controlPlane.configSyncAddr here: values-required enables both
# products, and that scalar with 2+ products fails closed (AUT-540).
out25ovr="$TMP/scenario-hybrid-controlplane-override.yaml"
render_default "$out25ovr" \
  --set global.deploymentMode=hybrid \
  --set global.controlPlane.domain=neuraltrust.es \
  --set global.controlPlane.databridgeAddr=k8s-databrid.elb.amazonaws.com:443 \
  --set dataagent.databridge.addr=custom-bridge.internal:9443 \
  --set dataagent.databridge.serverName=databridge.neuraltrust.es \
  --set agentgateway.configSync.endpoint=custom-sync.internal:8443 \
  --set agentgateway.configSync.serverName=agentgateway-configsync.neuraltrust.es \
  --set agentgateway.configSync.token=cs-trustgate
assert_contains "$out25ovr" '^  DATABRIDGE_ADDR: "custom-bridge\.internal:9443"$' \
  "override: dataagent.databridge.addr beats controlPlane.databridgeAddr"
assert_contains "$out25ovr" '^          value: "custom-sync\.internal:8443"$' \
  "override: configSync.endpoint beats the domain-derived config-sync host"

# Two-product hybrid without dial-host pins: each product derives its own
# <product>-configsync.<domain> listener (AUT-540).
out25two="$TMP/scenario-hybrid-two-product-configsync.yaml"
render_default "$out25two" \
  --set global.deploymentMode=hybrid \
  --set global.controlPlane.domain=neuraltrust.es \
  --set agentgateway.configSync.token=cs-trustgate \
  --set trustguard.configSync.token=cs-trustguard
assert_contains "$out25two" '^          value: "agentgateway-configsync\.neuraltrust\.es:443"$' \
  "two-product: AgentGateway dials agentgateway-configsync.<domain>"
assert_contains "$out25two" '^          value: "trustguard-configsync\.neuraltrust\.es:443"$' \
  "two-product: TrustGuard dials trustguard-configsync.<domain>"

assert_render_fails_with 'configSyncAddr cannot serve more than one product' \
  "scalar configSyncAddr with two products fails closed" \
  --set global.deploymentMode=hybrid \
  --set global.controlPlane.domain=neuraltrust.es \
  --set global.controlPlane.configSyncAddr=k8s-agentgat.elb.amazonaws.com:443 \
  --set agentgateway.configSync.token=cs-trustgate \
  --set trustguard.configSync.token=cs-trustguard

# Defaults must stay on system roots. Emitting an empty TLS_CA_FILE would replace
# the system pool with nothing and break every hybrid install against NeuralTrust.
out25noca="$TMP/scenario-hybrid-system-roots.yaml"
render_default "$out25noca" \
  --set global.deploymentMode=hybrid \
  --set agentgateway.configSync.token=cs-trustgate
assert_not_contains "$out25noca" 'TLS_CA_FILE' \
  "hybrid: no tlsCa leaves DataAgent on the system trust store"
assert_not_contains "$out25noca" 'ca_file' \
  "hybrid: no tlsCaSecretName leaves the egress collector on the system trust store"
assert_not_contains "$out25noca" 'include_system_ca_certs_pool' \
  "hybrid: no CA means no include_system_ca_certs_pool either"
assert_not_contains "$out25noca" 'ALLOW_INSECURE_TRANSPORT' \
  "hybrid: TLS stays on unless insecure is asked for explicitly"

# tlsMode=insecure was unusable before: the binary refuses to start on insecure
# transport without this opt-in, so the value produced a crash loop.
out25insec="$TMP/scenario-hybrid-insecure.yaml"
render_default "$out25insec" \
  --set global.deploymentMode=hybrid \
  --set agentgateway.configSync.token=cs-trustgate \
  --set dataagent.databridge.tlsMode=insecure
assert_contains "$out25insec" '^  ALLOW_INSECURE_TRANSPORT: "true"$' \
  "remote: tlsMode=insecure carries the opt-in the binary demands"

# A bare DNS suffix is the only accepted shape; the others produce endpoints
# that only fail once an agent tries to dial them.
for bad in https://cp.example.com cp.example.com:443 cp.example.com/api localhost; do
  assert_render_fails_with 'control-plane domain must be a' \
    "domain: $bad rejected" \
    --set global.deploymentMode=hybrid \
    --set "global.controlPlane.domain=$bad"
done

# --- saas without a domain of its own -------------------------------------
# Neither global.domain nor controlPlane.domain → refuse (would mint NeuralTrust hosts).
# values-required.yaml ships a domain for other scenarios; clear both knobs here.
assert_render_fails_with 'global.deploymentMode=saas requires a bare domain' \
  "saas: no domain rejected" \
  --set global.deploymentMode=saas \
  --set global.domain= \
  --set global.controlPlane.domain=
# Both existing modes still resolve the regional domain.
out25reg="$TMP/scenario-region-us.yaml"
render_default "$out25reg" \
  --set global.deploymentMode=hybrid --set global.saasRegion=us \
  --set agentgateway.configSync.token=cs-trustgate
assert_contains "$out25reg" 'databridge\.us\.neuraltrust\.ai' \
  "hybrid: saasRegion=us still resolves without a controlPlane.domain"

# --- string-typed booleans ------------------------------------------------
# Flux valuesFrom, Helmfile and --set-string all deliver "false" rather than
# false, and a Go template reads any non-empty string as true. For a flag that
# decides whether a config-sync listener goes on a public load balancer, that
# default is the unsafe one.
out25sf="$TMP/scenario-saas-stringflag.yaml"
render_default "$out25sf" "${SAAS_ARGS[@]}" \
  --set-string agentgateway.configSync.expose.enabled=false \
  --set-string trustguard.configSync.expose.enabled=false
assert_not_contains "$out25sf" '^  name: .*-configsync$' \
  "saas: expose.enabled=\"false\" as a string still keeps both listeners private"

# --- telemetry token drift ------------------------------------------------
# DataCore mints what the gateway verifies, from two independent values blocks.
# They agree on their defaults, so drift needs an override — and it is invisible
# in the manifest, showing up only as a 401 on every batch.
assert_render_fails_with 'telemetry audience mismatch' \
  "saas: audience drift between DataCore and the gateway rejected" \
  "${SAAS_ARGS[@]}" --set datacore.telemetryJwt.audience=other-aud
assert_render_fails_with 'telemetry issuer mismatch' \
  "saas: issuer drift between DataCore and the gateway rejected" \
  "${SAAS_ARGS[@]}" --set datacore.telemetryJwt.issuerUrl=https://datacore.internal
out25aud="$TMP/scenario-saas-aud-agree.yaml"
render_default "$out25aud" "${SAAS_ARGS[@]}" \
  --set datacore.telemetryJwt.audience=other-aud \
  --set clickstack-ingest-gateway.auth.audience=other-aud
assert_contains "$out25aud" '^  TELEMETRY_JWT_AUDIENCE: "other-aud"$' \
  "saas: overriding both sides together is still allowed"

# --- a reissued certificate reaches the listener --------------------------
# These processes read their keypair off disk at startup. Reissue happens when
# the names the certificate covers change, which is what retargeting the domain
# does, so without a checksum the Secret updates and the listener keeps serving
# a certificate the remote clusters no longer accept.
# Only the chart-generated path can reissue, so assert on that scenario. An
# operator-supplied or cert-manager Secret rotates outside the chart's knowledge
# and a template checksum could not see it either way.
for dep in databridge agentgateway-admin trustguard-control-plane; do
  ann=$(yq eval "select(.kind == \"Deployment\" and .metadata.name == \"$dep\")
    | .spec.template.metadata.annotations | keys | join(\",\")" "$out25gen")
  case "$ann" in
    *checksum/southbound-tls*|*checksum/configsync-tls*) ;;
    *)
      red "FAIL: saas: $dep is not rolled when its certificate is reissued (annotations: ${ann:-none})"
      exit 1 ;;
  esac
done
green "ok  - saas: a reissued certificate rolls the pod that serves it"
# Nothing new on the existing modes: they never reissue, and a fresh annotation
# would restart every control plane on upgrade for no reason.
assert_not_contains "$out25ext" 'checksum/configsync-tls' \
  "external: no certificate checksum annotation appears"
# Happy-path saas mints the leaf, so checksum is present on out25. BYO path
# must not annotate — rotation is outside the chart.
out25byo="$TMP/scenario-saas-byo-tls.yaml"
render_default "$out25byo" "${SAAS_BYO_ARGS[@]}"
assert_not_contains "$out25byo" 'checksum/southbound-tls' \
  "saas: an operator-supplied DataBridge cert gets no chart checksum"
assert_contains "$out25" 'checksum/southbound-tls' \
  "saas: chart-minted DataBridge cert rolls the pod on reissue"

# --- the broker's budget must not deadlock a drain -----------------------
# Default HA (replicas=2): minAvailable 1 lets a drain take one pod at a time.
# Singleton (replicas=1): maxUnavailable 1 — already asserted on out25single above.
assert_pdb_shape "$out25" minAvailable 1 \
  "saas: default HA DataBridge PDB keeps one pod through a drain"
assert_pdb_shape "$out25single" maxUnavailable 1 \
  "saas: singleton DataBridge PDB allows a node drain to proceed"

green ""
green "All v2 render scenarios passed."
