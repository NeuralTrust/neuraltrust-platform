#!/usr/bin/env bash
# scripts/test-sizing-doc.sh
#
# Fail when the "What the chart requests" table in docs/sizing.md drifts from
# the default render. Each row is re-derived from helm template output: requests
# of every Deployment, StatefulSet and DaemonSet container times its replicas,
# split into the GPU pool (containers requesting nvidia.com/gpu) and the CPU
# pool, rounded up to whole vCPU / GiB. On drift it prints the rows to paste.
#
# Node counts depend on measured allocatable capacity and stay manual; only the
# request totals are checked. Runs in CI via .github/workflows/helm-render-tests.yml
# and locally:
#
#   ./scripts/test-sizing-doc.sh

set -euo pipefail

cd "$(dirname "$0")/.."

CHART_DIR="."
SIZING_DOC="$CHART_DIR/docs/sizing.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
blue()  { printf '\033[34m%s\033[0m\n' "$*"; }

helm dependency build "$CHART_DIR" >/dev/null 2>&1 \
  || helm dependency update "$CHART_DIR" >/dev/null

# Same render setup as scripts/test-helm-render.sh: hybrid needs the per-product
# DataAgent enrolment Secret refs, and product slices start with every product off.
ENROLMENT_ARGS=(
  --set agentgateway.dataagent.enrolment.existingSecret.name=dataagent-enrolment-trustgate
  --set trustguard.dataagent.enrolment.existingSecret.name=dataagent-enrolment-trustguard
)
PRODUCTS_OFF_FILE="$TMP/products-off.yaml"
cat > "$PRODUCTS_OFF_FILE" <<'YAML'
global:
  products:
    trustgate: false
    trustguard: false
    dataPlane: false
YAML

render_default() {
  local out="$1"
  shift
  helm template test "$CHART_DIR" --namespace default \
    -f "$CHART_DIR/values-required.yaml" "${ENROLMENT_ARGS[@]}" "$@" > "$out"
}

render_product_slice() {
  local out="$1"
  shift
  helm template test "$CHART_DIR" --namespace default \
    -f "$CHART_DIR/values-required.yaml" -f "$PRODUCTS_OFF_FILE" \
    "${ENROLMENT_ARGS[@]}" "$@" > "$out"
}

# Prints the CPU-pool cell and the GPU-pool cell of a render, tab-separated;
# the GPU cell is an em dash when nothing lands on the GPU pool.
sizing_cells() {
  ruby -ryaml -e '
    UNITS = { "Ki" => 2**10, "Mi" => 2**20, "Gi" => 2**30, "Ti" => 2**40,
              "k" => 10**3, "M" => 10**6, "G" => 10**9, "T" => 10**12 }.freeze
    def cpu(v)
      s = v.to_s
      s.end_with?("m") ? Rational(s.chomp("m")) / 1000 : Rational(s)
    end
    def mem(v)
      s = v.to_s
      unit = UNITS.keys.find { |u| s.end_with?(u) }
      unit ? Rational(s.delete_suffix(unit)) * UNITS[unit] : Rational(s)
    end
    pools = Hash.new { |h, k| h[k] = [0r, 0r, 0] }
    pools[:cpu]
    YAML.load_stream(File.read(ARGV.fetch(0))).compact.each do |d|
      next unless %w[Deployment StatefulSet DaemonSet].include?(d["kind"])
      replicas = d["kind"] == "DaemonSet" ? 1 : (d.dig("spec", "replicas") || 1)
      (d.dig("spec", "template", "spec", "containers") || []).each do |c|
        req = c.dig("resources", "requests") || {}
        pool = pools[req.key?("nvidia.com/gpu") ? :gpu : :cpu]
        pool[0] += replicas * cpu(req.fetch("cpu", 0))
        pool[1] += replicas * mem(req.fetch("memory", 0))
        pool[2] += replicas * req.fetch("nvidia.com/gpu", 0).to_i
      end
    end
    cell = ->(p) { "#{p[0].ceil} vCPU / #{(p[1] / 2**30).ceil} GiB" }
    gpu = pools.key?(:gpu) ? "#{cell.(pools[:gpu])}, #{pools[:gpu][2]} GPU shares" : "—"
    puts [cell.(pools[:cpu]), gpu].join("\t")' "$1"
}

# The three request cells of the row whose first cell starts with $1, from the
# "What the chart requests" table, tab-separated.
sizing_doc_row() {
  awk -F'|' -v label="$1" '
    /^## / { in_section = ($0 == "## What the chart requests") }
    in_section && index($2, " " label) == 1 {
      for (i = 3; i <= 5; i++) gsub(/^ +| +$/, "", $i)
      print $3 "\t" $4 "\t" $5
      exit
    }' "$SIZING_DOC"
}

DRIFT=()
# label, gpu|nogpu, render function, render args...
check_row() {
  local label="$1" gpu="$2" renderer="$3"
  shift 3
  local slug="${label//[^A-Za-z]/}"
  local out="$TMP/sizing-$slug.yaml" out_gpu="$TMP/sizing-$slug-gpu.yaml"
  local cpu_cells gpu_cells want got doc_row
  "$renderer" "$out" "$@"
  cpu_cells="$(sizing_cells "$out")"
  if [[ "$gpu" == gpu ]]; then
    "$renderer" "$out_gpu" "$@" -f "$CHART_DIR/values-dataplane-gpu.yaml.example"
    gpu_cells="$(sizing_cells "$out_gpu")"
  else
    gpu_cells=$'—\t—'
  fi
  want="${cpu_cells%%$'\t'*}"$'\t'"$gpu_cells"
  got="$(sizing_doc_row "$label")"
  if [[ "$want" == "$got" ]]; then
    green "ok  - sizing: $label matches docs/sizing.md"
    return
  fi
  doc_row="no such row"
  if [[ -n "$got" ]]; then doc_row="| $label | ${got//$'\t'/ | } |"; fi
  DRIFT+=("| $label | ${want//$'\t'/ | } |"$'\n'"      was: $doc_row")
}

blue "==> docs/sizing.md request totals match the render"

check_row "Hybrid, all products" gpu render_default
check_row "Hybrid, TrustGuard only" gpu render_product_slice \
  -f "$CHART_DIR/values-trustguard.yaml.example"
check_row "Hybrid, TrustGate only" nogpu render_product_slice \
  -f "$CHART_DIR/values-trustgate.yaml.example"
check_row "External" gpu render_default \
  -f "$CHART_DIR/values-external.yaml.example"
check_row "SaaS" gpu render_default \
  --set global.deploymentMode=saas --set global.domain=cp.example.com

if (( ${#DRIFT[@]} )); then
  red "FAIL: docs/sizing.md \"What the chart requests\" no longer matches the render."
  red "      Update these rows (and the docs site copy) from the rendered requests:"
  for row in "${DRIFT[@]}"; do red "      $row"; done
  exit 1
fi
green "docs/sizing.md request totals match the render."
