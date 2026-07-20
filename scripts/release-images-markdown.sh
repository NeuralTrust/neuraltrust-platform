#!/usr/bin/env bash
# Markdown table of default container images for GitHub Release notes.
# Called from .github/workflows/publish-chart.yml after auto-release creates the tag.
# Reads umbrella values.yaml plus subchart defaults.
#
# v2-only: v1 (TrustGate/Kafka) is maintained on the v1.14.x release line and is
# not part of this chart. Do not add v1 rows here.
#
# Usage: ./scripts/release-images-markdown.sh

set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v yq >/dev/null 2>&1; then
  echo "yq is required" >&2
  exit 1
fi

yq_get() {
  local file="$1"
  local path="$2"
  yq eval "$path" "$file" 2>/dev/null | sed '/^null$/d' | head -1
}

emit_row() {
  local component="$1"
  local repo="$2"
  local tag="$3"
  if [[ -z "$repo" || -z "$tag" || "$repo" == "null" || "$tag" == "null" ]]; then
    return
  fi
  printf '| %s | `%s:%s` |\n' "$component" "$repo" "$tag"
}

V=values.yaml
WD=charts/watchdog/values.yaml
AGW=charts/agentgateway/values.yaml
TGUARD=charts/trustguard/values.yaml
TLENS=charts/trustlens/values.yaml
DAGENT=charts/dataagent/values.yaml
DCORE=charts/datacore/values.yaml
CSCOL=charts/clickstack-otel-collector/values.yaml
AENG=charts/alertengine/values.yaml

CH_REPO=$(yq_get "$V" '.clickhouse.image.repository')
CH_TAG=$(yq_get "$V" '.clickhouse.image.tag')

echo '| Component | Image |'
echo '|-----------|-------|'

# In-cluster runtime (hybrid + external).
emit_row "agentgateway" "$(yq_get "$AGW" '.image.repository')" "$(yq_get "$V" '.agentgateway.image.tag')"
emit_row "trustguard" "$(yq_get "$TGUARD" '.image.repository')" "$(yq_get "$V" '.trustguard.image.tag')"
emit_row "dataagent (hybrid, enrolled)" "$(yq_get "$DAGENT" '.image.repository')" "$(yq_get "$V" '.dataagent.image.tag')"
emit_row "data-plane-api (shim)" "$(yq_get "$V" '.["data-plane-api"].dataPlane.components.api.image.repository')" "$(yq_get "$V" '.["data-plane-api"].dataPlane.components.api.image.tag')"

# External-only stack.
emit_row "control-plane-api (external)" "$(yq_get "$V" '.["control-plane-api"].controlPlane.components.api.image.repository')" "$(yq_get "$V" '.["control-plane-api"].controlPlane.components.api.image.tag')"
emit_row "control-plane-app (external)" "$(yq_get "$V" '.["control-plane-app"].controlPlane.components.app.image.repository')" "$(yq_get "$V" '.["control-plane-app"].controlPlane.components.app.image.tag')"
emit_row "datacore (external)" "$(yq_get "$DCORE" '.image.repository')" "$(yq_get "$V" '.datacore.image.tag')"
emit_row "clickstack-otel-collector (external)" "$(yq_get "$CSCOL" '.image.repository')" "$(yq_get "$V" '.["clickstack-otel-collector"].image.tag')"
emit_row "alertengine (external)" "$(yq_get "$AENG" '.image.repository')" "$(yq_get "$V" '.alertengine.image.tag')"
emit_row "trustlens (optional, WIP)" "$(yq_get "$TLENS" '.image.repository')" "$(yq_get "$V" '.trustlens.image.tag')"

# Datastores.
emit_row "clickhouse-server (external analytics)" "$CH_REPO" "$CH_TAG"
emit_row "redis (in-cluster)" "$(yq_get "$V" '.infrastructure.redis.image.repository')" "$(yq_get "$V" '.infrastructure.redis.image.tag')"
emit_row "postgres (in-cluster)" "$(yq_get "$V" '.global.postgresql.image.repository')" "$(yq_get "$V" '.global.postgresql.image.tag')"

# Optional add-ons.
emit_row "firewall-gateway (cpu)" "$(yq_get "$V" '.firewall.firewall.gateway.image.repository')" "$(yq_get "$V" '.firewall.firewall.gateway.image.tag')"
emit_row "firewall-worker (cpu default)" "$(yq_get "$V" '.firewall.firewall.workerDefaults.image.repository')" "$(yq_get "$V" '.firewall.firewall.workerDefaults.image.tag')"
emit_row "opentelemetry-collector-contrib (umbrella)" "$(yq_get "$V" '.global.observability.collector.image.repository')" "$(yq_get "$V" '.global.observability.collector.image.tag')"
emit_row "opentelemetry-collector-contrib (clickstack egress)" "$(yq_get "$V" '.global.clickstack.egress.image.repository')" "$(yq_get "$V" '.global.clickstack.egress.image.tag')"
emit_row "neuraltrust-watchdog" "$(yq_get "$WD" '.image.repository')" "$(yq_get "$WD" '.image.tag')"
emit_row "watchdog-prometheus" "$(yq_get "$WD" '.prometheus.image.repository')" "$(yq_get "$WD" '.prometheus.image.tag')"
