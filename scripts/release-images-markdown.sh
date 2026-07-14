#!/usr/bin/env bash
# Markdown table of default container images for GitHub Release notes.
# Called from .github/workflows/publish-chart.yml after auto-release creates the tag.
# Reads umbrella values.yaml plus subchart defaults (watchdog, aispm, siem).
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
WD=charts/neuraltrust-watchdog/values.yaml
AISPM=charts/neuraltrust-aispm/values.yaml
SIEM=charts/neuraltrust-siem-connectors/values.yaml
# Platform v2 subcharts (only deployed when global.platformVersion=v2)
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

emit_row "clickhouse-server" "$CH_REPO" "$CH_TAG"
emit_row "kafka" "$(yq_get "$V" '.kafka.image.repository')" "$(yq_get "$V" '.kafka.image.tag')"
emit_row "redis-stack-server" "$(yq_get "$V" '.trustgate.redis.image.repository')" "$(yq_get "$V" '.trustgate.redis.image.tag')"
emit_row "redis (v2 in-cluster)" "$(yq_get "$V" '.infrastructure.redis.image.repository')" "$(yq_get "$V" '.infrastructure.redis.image.tag')"
emit_row "postgres (trustgate init + control-plane)" "$(yq_get "$V" '.trustgate.global.postgresql.image.repository')" "$(yq_get "$V" '.trustgate.global.postgresql.image.tag')"
emit_row "trustgate-ee" "$(yq_get "$V" '.trustgate.global.image.image')" "$(yq_get "$V" '.trustgate.global.image.tag')"
emit_row "control-plane-api" "$(yq_get "$V" '.["neuraltrust-control-plane"].controlPlane.components.api.image.repository')" "$(yq_get "$V" '.["neuraltrust-control-plane"].controlPlane.components.api.image.tag')"
emit_row "control-plane-scheduler" "$(yq_get "$V" '.["neuraltrust-control-plane"].controlPlane.components.scheduler.image.repository')" "$(yq_get "$V" '.["neuraltrust-control-plane"].controlPlane.components.scheduler.image.tag')"
emit_row "control-plane-app" "$(yq_get "$V" '.["neuraltrust-control-plane"].controlPlane.components.app.image.repository')" "$(yq_get "$V" '.["neuraltrust-control-plane"].controlPlane.components.app.image.tag')"
emit_row "data-plane-api" "$(yq_get "$V" '.["neuraltrust-data-plane"].dataPlane.components.api.image.repository')" "$(yq_get "$V" '.["neuraltrust-data-plane"].dataPlane.components.api.image.tag')"
emit_row "data-plane-workers" "$(yq_get "$V" '.["neuraltrust-data-plane"].dataPlane.components.worker.image.repository')" "$(yq_get "$V" '.["neuraltrust-data-plane"].dataPlane.components.worker.image.tag')"
emit_row "kafka-connect" "$(yq_get "$V" '.["neuraltrust-data-plane"].dataPlane.components.kafka.connect.image.repository')" "$(yq_get "$V" '.["neuraltrust-data-plane"].dataPlane.components.kafka.connect.image.tag')"
emit_row "firewall-gateway (cpu)" "$(yq_get "$V" '.["neuraltrust-firewall"].firewall.gateway.image.repository')" "$(yq_get "$V" '.["neuraltrust-firewall"].firewall.gateway.image.tag')"
emit_row "firewall-worker (cpu default)" "$(yq_get "$V" '.["neuraltrust-firewall"].firewall.workerDefaults.image.repository')" "$(yq_get "$V" '.["neuraltrust-firewall"].firewall.workerDefaults.image.tag')"
emit_row "opentelemetry-collector-contrib" "$(yq_get "$V" '.global.observability.collector.image.repository')" "$(yq_get "$V" '.global.observability.collector.image.tag')"
emit_row "neuraltrust-watchdog" "$(yq_get "$WD" '.image.repository')" "$(yq_get "$WD" '.image.tag')"
emit_row "watchdog-prometheus" "$(yq_get "$WD" '.prometheus.image.repository')" "$(yq_get "$WD" '.prometheus.image.tag')"
emit_row "aispm-api" "$(yq_get "$AISPM" '.aispm.api.image.repository')" "$(yq_get "$AISPM" '.aispm.api.image.tag')"
emit_row "aispm-worker" "$(yq_get "$AISPM" '.aispm.worker.image.repository')" "$(yq_get "$AISPM" '.aispm.worker.image.tag')"
emit_row "aispm-beat" "$(yq_get "$AISPM" '.aispm.beat.image.repository')" "$(yq_get "$AISPM" '.aispm.beat.image.tag')"
emit_row "siem-connectors" "$(yq_get "$SIEM" '.siemConnectors.image.repository')" "$(yq_get "$SIEM" '.siemConnectors.image.tag')"
emit_row "agentgateway (v2)" "$(yq_get "$AGW" '.image.repository')" "$(yq_get "$AGW" '.image.tag')"
emit_row "trustguard (v2)" "$(yq_get "$TGUARD" '.image.repository')" "$(yq_get "$TGUARD" '.image.tag')"
emit_row "trustlens (v2)" "$(yq_get "$TLENS" '.image.repository')" "$(yq_get "$TLENS" '.image.tag')"
emit_row "dataagent (v2)" "$(yq_get "$DAGENT" '.image.repository')" "$(yq_get "$DAGENT" '.image.tag')"
emit_row "datacore (v2)" "$(yq_get "$DCORE" '.image.repository')" "$(yq_get "$DCORE" '.image.tag')"
emit_row "clickstack-otel-collector (v2)" "$(yq_get "$CSCOL" '.image.repository')" "$(yq_get "$CSCOL" '.image.tag')"
emit_row "alertengine (v2)" "$(yq_get "$AENG" '.image.repository')" "$(yq_get "$AENG" '.image.tag')"
