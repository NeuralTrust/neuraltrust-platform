#!/usr/bin/env bash
# Markdown table of default container images for GitHub Release notes.
# Called from .github/workflows/publish-chart.yml after auto-release creates the tag.
# Reads umbrella values.yaml plus subchart defaults.
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

emit_row "agentgateway (v2)" "$(yq_get "$AGW" '.image.repository')" "$(yq_get "$V" '.agentgateway.image.tag')"
emit_row "trustguard (v2)" "$(yq_get "$TGUARD" '.image.repository')" "$(yq_get "$V" '.trustguard.image.tag')"
emit_row "dataagent (v2)" "$(yq_get "$DAGENT" '.image.repository')" "$(yq_get "$V" '.dataagent.image.tag')"
emit_row "datacore (v2)" "$(yq_get "$DCORE" '.image.repository')" "$(yq_get "$V" '.datacore.image.tag')"
emit_row "clickstack-otel-collector (v2)" "$(yq_get "$CSCOL" '.image.repository')" "$(yq_get "$V" '.["clickstack-otel-collector"].image.tag')"
emit_row "alertengine (v2)" "$(yq_get "$AENG" '.image.repository')" "$(yq_get "$V" '.alertengine.image.tag')"
emit_row "trustlens (v2, optional)" "$(yq_get "$TLENS" '.image.repository')" "$(yq_get "$V" '.trustlens.image.tag')"
emit_row "control-plane-api (v2 external / v1)" "$(yq_get "$V" '.["neuraltrust-control-plane"].controlPlane.components.api.image.repository')" "$(yq_get "$V" '.["neuraltrust-control-plane"].controlPlane.components.api.image.tag')"
emit_row "control-plane-app (v2 external / v1)" "$(yq_get "$V" '.["neuraltrust-control-plane"].controlPlane.components.app.image.repository')" "$(yq_get "$V" '.["neuraltrust-control-plane"].controlPlane.components.app.image.tag')"
emit_row "data-plane-api (v2 shim / v1)" "$(yq_get "$V" '.["neuraltrust-data-plane"].dataPlane.components.api.image.repository')" "$(yq_get "$V" '.["neuraltrust-data-plane"].dataPlane.components.api.image.tag')"
emit_row "curl (v1 ClickHouse backup)" "$(yq_get "$V" '.["neuraltrust-data-plane"].dataPlane.components.clickhouse.backup.image.repository')" "$(yq_get "$V" '.["neuraltrust-data-plane"].dataPlane.components.clickhouse.backup.image.tag')"
emit_row "clickhouse-server" "$CH_REPO" "$CH_TAG"
emit_row "redis (v2 in-cluster)" "$(yq_get "$V" '.infrastructure.redis.image.repository')" "$(yq_get "$V" '.infrastructure.redis.image.tag')"
emit_row "postgres (v2 + v1 control-plane)" "$(yq_get "$V" '.trustgate.global.postgresql.image.repository')" "$(yq_get "$V" '.trustgate.global.postgresql.image.tag')"
emit_row "firewall-gateway (cpu)" "$(yq_get "$V" '.["neuraltrust-firewall"].firewall.gateway.image.repository')" "$(yq_get "$V" '.["neuraltrust-firewall"].firewall.gateway.image.tag')"
emit_row "firewall-worker (cpu default)" "$(yq_get "$V" '.["neuraltrust-firewall"].firewall.workerDefaults.image.repository')" "$(yq_get "$V" '.["neuraltrust-firewall"].firewall.workerDefaults.image.tag')"
emit_row "opentelemetry-collector-contrib" "$(yq_get "$V" '.global.observability.collector.image.repository')" "$(yq_get "$V" '.global.observability.collector.image.tag')"
emit_row "neuraltrust-watchdog" "$(yq_get "$WD" '.image.repository')" "$(yq_get "$WD" '.image.tag')"
emit_row "watchdog-prometheus" "$(yq_get "$WD" '.prometheus.image.repository')" "$(yq_get "$WD" '.prometheus.image.tag')"
emit_row "trustgate-ee (v1 legacy)" "$(yq_get "$V" '.trustgate.global.image.image')" "$(yq_get "$V" '.trustgate.global.image.tag')"
emit_row "redis-stack-server (v1 legacy)" "$(yq_get "$V" '.trustgate.redis.image.repository')" "$(yq_get "$V" '.trustgate.redis.image.tag')"
emit_row "kafka (v1 legacy)" "$(yq_get "$V" '.kafka.image.repository')" "$(yq_get "$V" '.kafka.image.tag')"
emit_row "control-plane-scheduler (v1 legacy)" "$(yq_get "$V" '.["neuraltrust-control-plane"].controlPlane.components.scheduler.image.repository')" "$(yq_get "$V" '.["neuraltrust-control-plane"].controlPlane.components.scheduler.image.tag')"
emit_row "data-plane-workers (v1 legacy)" "$(yq_get "$V" '.["neuraltrust-data-plane"].dataPlane.components.worker.image.repository')" "$(yq_get "$V" '.["neuraltrust-data-plane"].dataPlane.components.worker.image.tag')"
emit_row "kafka-connect (v1 legacy)" "$(yq_get "$V" '.["neuraltrust-data-plane"].dataPlane.components.kafka.connect.image.repository')" "$(yq_get "$V" '.["neuraltrust-data-plane"].dataPlane.components.kafka.connect.image.tag')"
