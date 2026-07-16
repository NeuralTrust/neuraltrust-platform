#!/usr/bin/env bash
# scripts/test-helm-render.sh
#
# Render the umbrella chart in several representative scenarios and
# assert structural invariants. Designed to fail loudly if a future
# change accidentally:
#
#   - breaks the "no-egress install" guarantee (chart must render with
#     observability ON but no token configured),
#   - leaks the otlphttp/neuraltrust exporter into pipelines when no
#     token is resolvable,
#   - drops the always-on `nop` fallback exporter,
#   - regresses the privacy-redaction processors.
#
# Used by .github/workflows/helm-render-tests.yml and locally:
#
#   ./scripts/test-helm-render.sh
#
# Exits non-zero on the first assertion failure.

set -euo pipefail

cd "$(dirname "$0")/.."

CHART_DIR="."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
blue()  { printf '\033[34m%s\033[0m\n' "$*"; }

helm dependency update "$CHART_DIR" >/dev/null

render() {
  local out="$1"
  shift
  helm template test "$CHART_DIR" --namespace default -f "$CHART_DIR/values-required.yaml" \
    --set global.platformVersion=v1 "$@" > "$out"
}

render_default() {
  local out="$1"
  shift
  helm template test "$CHART_DIR" --namespace default -f "$CHART_DIR/values-required.yaml" "$@" > "$out"
}

assert_render_fails() {
  local msg="$1"
  shift
  if helm template test "$CHART_DIR" --namespace default -f "$CHART_DIR/values-required.yaml" "$@" >/dev/null 2>&1; then
    red "FAIL: $msg"
    exit 1
  fi
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

assert_env_value() {
  local file="$1" name="$2" expected="$3" msg="$4"
  if ! grep -A1 -- "name: $name\$" "$file" | grep -qE -- "value: \"?${expected}\"?\$"; then
    red "FAIL: $msg"
    red "  expected env $name to equal: $expected"
    red "  in: $file"
    exit 1
  fi
  green "ok  - $msg"
}

assert_watchdog_check_state() {
  local file="$1" check_id="$2" expected="$3" msg="$4"
  local actual
  actual=$(CHECK_ID="$check_id" yq e 'select(.kind == "ConfigMap" and (.metadata.name | test("watchdog.*-config$"))) | .data."config.yaml" | from_yaml | .checks[] | select(.id == strenv(CHECK_ID)) | .enabled' "$file")
  if [[ "$actual" != "$expected" ]]; then
    red "FAIL: $msg"
    red "  check $check_id expected enabled=$expected, got ${actual:-missing}"
    exit 1
  fi
  green "ok  - $msg"
}

assert_resource_state() {
  local file="$1" kind="$2" name="$3" expected="$4" msg="$5"
  local actual
  actual=$(RESOURCE_KIND="$kind" RESOURCE_NAME="$name" yq e 'select(.kind == strenv(RESOURCE_KIND) and .metadata.name == strenv(RESOURCE_NAME)) | .metadata.name' "$file")
  if [[ "$expected" == "present" && "$actual" != "$name" ]]; then
    red "FAIL: $msg"
    red "  expected $kind/$name to be present"
    exit 1
  fi
  if [[ "$expected" == "absent" && -n "$actual" ]]; then
    red "FAIL: $msg"
    red "  expected $kind/$name to be absent"
    exit 1
  fi
  green "ok  - $msg"
}

# Scenario 1: defaults. Observability is OFF by default — no in-chart
# collector. Components still render; hosted export is irrelevant until
# the collector is enabled (via global.observability.enabled or watchdog).
blue "scenario 1: chart 2.0 defaults to v2 hybrid"
render_default "$TMP/default-v2.yaml"
assert_contains     "$TMP/default-v2.yaml" "name: agentgateway-proxy" "default render includes AgentGateway"
assert_contains     "$TMP/default-v2.yaml" "name: trustguard-data-plane" "default render includes TrustGuard"
assert_not_contains "$TMP/default-v2.yaml" "name: dataagent$" "default render omits DataAgent without enrolment"
assert_not_contains "$TMP/default-v2.yaml" "name: clickstack-collector" "default hybrid omits external-only ClickStack"
assert_not_contains "$TMP/default-v2.yaml" "name: kafka-controller" "default v2 render omits Kafka"
assert_not_contains "$TMP/default-v2.yaml" "name: otel-collector-config" "otel collector ConfigMap omitted by default"

# Keep an explicit v1 baseline for the legacy contract assertions below.
render "$TMP/default.yaml"

# Scenario 1b: collector on explicitly but no token — graceful degradation.
blue "scenario 1b: observability on, no token (graceful degradation)"
render "$TMP/default-obs-on.yaml" --set global.observability.enabled=true
assert_contains     "$TMP/default-obs-on.yaml" "name: otel-collector-config" "otel collector ConfigMap is rendered when enabled"
assert_not_contains "$TMP/default-obs-on.yaml" "test-neuraltrust-platform-otel-collector" "otel collector resource name carries no release-name prefix (fullnameOverride)"
assert_not_contains "$TMP/default-obs-on.yaml" "otlphttp/neuraltrust:"                            "hosted exporter is omitted when no token"
assert_contains     "$TMP/default-obs-on.yaml" "nop: \\{\\}"                                       "nop fallback exporter is present"
assert_contains     "$TMP/default-obs-on.yaml" "attributes/redact"                                 "privacy-redact processor is present"
assert_not_contains "$TMP/default-obs-on.yaml" "address: 0.0.0.0:8888"                              "otel internal metrics use readers (not deprecated address)"
assert_contains     "$TMP/default-obs-on.yaml" "readers:"                                           "otel internal metrics readers block present"
assert_contains     "$TMP/default-obs-on.yaml" "- key: prompt_text"                                "prompt_text redaction rule is present"

# Scenario 2: explicit token. Hosted exporter should appear, secret
# should be created, env var should be wired into the Deployment.
blue "scenario 2: explicit token configured"
render "$TMP/withtoken.yaml" \
  --set global.observability.enabled=true \
  --set global.observability.hostedExport.auth.tokenValue=secrettoken123
assert_contains     "$TMP/withtoken.yaml" "otlphttp/neuraltrust:"                                  "hosted exporter is rendered when token set"
assert_contains     "$TMP/withtoken.yaml" "Bearer \\\$\\{env:NT_OBSERVABILITY_TOKEN\\}"           "exporter uses NT_OBSERVABILITY_TOKEN env"
assert_contains     "$TMP/withtoken.yaml" "name: neuraltrust-observability-token"                  "token Secret is created"
assert_contains     "$TMP/withtoken.yaml" "name: NT_OBSERVABILITY_TOKEN"                           "Deployment env wires NT_OBSERVABILITY_TOKEN"
assert_contains     "$TMP/withtoken.yaml" "attributes/redact"                                      "privacy-redact processor still present with token"

# Scenario 3: master switch off. No otel-collector resources at all
# (watchdog also off in this render).
blue "scenario 3: observability disabled"
render "$TMP/off.yaml" \
  --set global.observability.enabled=false \
  --set neuraltrust-watchdog.enabled=false
assert_not_contains "$TMP/off.yaml" "otel-collector"                                          "no otel-collector resources when disabled"

# Scenario 4: watchdog subchart enabled (collector-less default). Deployment +
# ConfigMap render; in-chart collector stays OFF unless explicitly enabled.
blue "scenario 4: watchdog enabled (collector-less)"
render "$TMP/watchdog.yaml" --set neuraltrust-watchdog.enabled=true
assert_contains     "$TMP/watchdog.yaml" "name: neuraltrust-watchdog$" "watchdog resource (named neuraltrust-watchdog, no release prefix) is rendered"
assert_contains     "$TMP/watchdog.yaml" "neuraltrust-watchdog-config" "watchdog ConfigMap is rendered"
assert_not_contains "$TMP/watchdog.yaml" "name: test-neuraltrust-watchdog$" "watchdog resource name carries no release-name prefix (fullnameOverride)"
assert_not_contains "$TMP/watchdog.yaml" "name: otel-collector-config" "otel collector omitted in collector-less watchdog profile"
assert_contains     "$TMP/watchdog.yaml" "control-plane-api-service/health" "synthetic checks use umbrella Service DNS names"
assert_contains     "$TMP/watchdog.yaml" "name: CLICKHOUSE_USER" "watchdog wires ClickHouse user from clickhouse-secrets"
assert_contains     "$TMP/watchdog.yaml" "name: gcr-secret" "watchdog defaults to gcr-secret imagePullSecret"

# Scenario 4b: collector-less watchdog + explicit hosted token => Secret +
# required OPENTELEMETRY_AUTH_TOKEN env (no optional: true).
blue "scenario 4b: watchdog + hosted token"
render "$TMP/watchdog-token.yaml" \
  --set neuraltrust-watchdog.enabled=true \
  --set global.observability.hostedExport.auth.tokenValue=secrettoken123
assert_contains     "$TMP/watchdog-token.yaml" "name: neuraltrust-observability-token" "hosted token Secret rendered for watchdog"
assert_contains     "$TMP/watchdog-token.yaml" "name: OPENTELEMETRY_AUTH_TOKEN" "watchdog Deployment wires OPENTELEMETRY_AUTH_TOKEN"
if awk '
  /- name: OPENTELEMETRY_AUTH_TOKEN/ { capture=1; lines=0; next }
  capture {
    lines++
    if (/optional: true/) { fail=1 }
    if (lines > 8 || /^            - name:/) { capture=0 }
  }
  END { exit fail ? 0 : 1 }
' "$TMP/watchdog-token.yaml"; then
  red "FAIL: hosted token SecretRef is required when wired"
  red "  OPENTELEMETRY_AUTH_TOKEN must not use optional: true"
  exit 1
fi
green "ok  - hosted token SecretRef is required when wired"

# Scenario 4c: platform-scoped check namespaces follow --namespace (not hardcoded).
blue "scenario 4c: watchdog platform check namespaces follow release namespace"
render "$TMP/watchdog-ns.yaml" \
  --namespace alt-ns \
  --set neuraltrust-watchdog.enabled=true
if ! awk '
  /id: deployment-health/ { in_check=1; next }
  in_check && /namespace: alt-ns/ { found=1; exit }
  in_check && /^      - id:/ { exit }
  END { exit found ? 0 : 1 }
' "$TMP/watchdog-ns.yaml"; then
  red "FAIL: deployment-health check namespace not resolved to release namespace (alt-ns)"
  exit 1
fi
green "ok  - deployment-health namespace resolves to release namespace"
if ! awk '
  /id: pod-health/ { in_check=1; next }
  in_check && /- alt-ns/ { found=1; exit }
  in_check && /^      - id:/ { exit }
  END { exit found ? 0 : 1 }
' "$TMP/watchdog-ns.yaml"; then
  red "FAIL: pod-health namespaces not resolved to release namespace (alt-ns)"
  exit 1
fi
green "ok  - pod-health namespaces resolve to release namespace"
assert_contains "$TMP/watchdog-ns.yaml" "namespace: deploy-api" "cross-namespace deploy-api check keeps explicit namespace"
assert_watchdog_check_state "$TMP/watchdog-ns.yaml" "data-plane-synthetic" "true" "v1 enables the legacy data-plane deep check"
assert_watchdog_check_state "$TMP/watchdog-ns.yaml" "v2-data-plane-synthetic" "false" "v1 leaves the Kafka-free v2 check disabled"
assert_watchdog_check_state "$TMP/watchdog-ns.yaml" "deployment-health" "true" "v1 enables legacy deployment-health"
assert_watchdog_check_state "$TMP/watchdog-ns.yaml" "v2-deployment-health" "false" "v1 leaves v2 deployment-health disabled"

render_default "$TMP/watchdog-v2-state.yaml" \
  --set neuraltrust-watchdog.enabled=true
assert_watchdog_check_state "$TMP/watchdog-v2-state.yaml" "data-plane-synthetic" "false" "v2 disables the Kafka-dependent deep check"
assert_watchdog_check_state "$TMP/watchdog-v2-state.yaml" "v2-data-plane-synthetic" "true" "v2 enables the Kafka-free data-plane check"
assert_watchdog_check_state "$TMP/watchdog-v2-state.yaml" "deployment-health" "false" "v2 disables legacy deployment-health"
assert_watchdog_check_state "$TMP/watchdog-v2-state.yaml" "v2-deployment-health" "true" "v2 enables v2 deployment-health"

# Scenario 5: hosted explicitly disabled (local-only collector). Hosted
# exporter omitted; collector still runs.
blue "scenario 5: hosted export explicitly disabled"
render "$TMP/local.yaml" \
  --set global.observability.enabled=true \
  --set global.observability.hostedExport.enabled=false
assert_contains     "$TMP/local.yaml" "name: otel-collector-config" "collector still runs locally"
assert_not_contains "$TMP/local.yaml" "otlphttp/neuraltrust:"                            "hosted exporter omitted when hostedExport.enabled=false"
assert_contains     "$TMP/local.yaml" "nop: \\{\\}"                                       "nop fallback present in local-only mode"

# Scenario 6: components flip to in-chart collector when global override set.
# This guarantees the umbrella-wide endpoint takes precedence and that
# legacy default DNS in the subchart values doesn't leak through.
blue "scenario 6: global.observability.collector.endpoint flips component endpoints"
render "$TMP/inchart.yaml" \
  --set firewall.enabled=true \
  --set trustgate.enabled=true \
  --set global.observability.collector.endpoint=http://test-otel-collector.default.svc.cluster.local:4318
assert_contains     "$TMP/inchart.yaml" "OTEL_EXPORTER_OTLP_ENDPOINT: \"http://test-otel-collector" "firewall picks up global collector endpoint"
assert_contains     "$TMP/inchart.yaml" "OPENTELEMETRY_TRACES_ENDPOINT: \"http://test-otel-collector"  "trustgate writes OPENTELEMETRY_TRACES_ENDPOINT (read by TrustGate-EE)"
assert_contains     "$TMP/inchart.yaml" "OPENTELEMETRY_METRICS_ENDPOINT: \"http://test-otel-collector" "trustgate writes OPENTELEMETRY_METRICS_ENDPOINT (read by TrustGate-EE)"
assert_contains     "$TMP/inchart.yaml" "OPENTELEMETRY_ENABLED: \"true\""                            "trustgate auto-enables OTLP when global endpoint set"
assert_not_contains "$TMP/inchart.yaml" "OPENTELEMETRY_ENDPOINT:"                                    "legacy OPENTELEMETRY_ENDPOINT key fully removed"
assert_not_contains "$TMP/inchart.yaml" "OPENTELEMETRY_OTLP_ENDPOINT:"                               "legacy OPENTELEMETRY_OTLP_ENDPOINT key fully removed"
assert_not_contains "$TMP/inchart.yaml" "OTEL_EXPORTER_OTLP_ENDPOINT: \"http://opentelemetry-collector.opentelemetry" "firewall no longer points at legacy default"

render "$TMP/v2-trustguard-otel.yaml" \
  --set global.platformVersion=v2 \
  --set global.observability.collector.endpoint=http://test-otel-collector.default.svc.cluster.local:4318
assert_contains "$TMP/v2-trustguard-otel.yaml" 'OTEL_EXPORTER_OTLP_ENDPOINT: "http://test-otel-collector' "TrustGuard picks up global collector endpoint"
assert_contains "$TMP/v2-trustguard-otel.yaml" 'OPENTELEMETRY_SERVICE_NAME: "trustguard"' "TrustGuard has stable OTel service identity"

# Scenario 6b: control-plane + data-plane OTel wiring. The chart was not
# injecting OTel env into these subcharts before; this catches regressions
# where the configmap or envFrom is silently dropped.
blue "scenario 6b: control/data plane subcharts pick up the global collector endpoint"
render "$TMP/cpdp-otel.yaml" \
  --set neuraltrust-control-plane.controlPlane.enabled=true \
  --set neuraltrust-data-plane.dataPlane.enabled=true \
  --set global.observability.collector.endpoint=http://test-otel-collector.default.svc.cluster.local:4318
assert_contains "$TMP/cpdp-otel.yaml" "name: control-plane-api-otel"  "control-plane-api OTel ConfigMap rendered"
assert_contains "$TMP/cpdp-otel.yaml" "name: control-plane-app-otel"  "control-plane-app OTel ConfigMap rendered"
assert_contains "$TMP/cpdp-otel.yaml" "name: data-plane-api-otel"     "data-plane-api OTel ConfigMap rendered"
assert_contains "$TMP/cpdp-otel.yaml" "name: data-plane-worker-otel"  "data-plane-worker OTel ConfigMap rendered"
# Each Deployment must envFrom its OTel ConfigMap. We assert "name:
# <cm>-otel" appears at least twice in the render (once in the
# ConfigMap metadata, once under a configMapRef in the Deployment).
# Using grep -c which is portable on BSD/GNU.
for cm in control-plane-api-otel control-plane-app-otel data-plane-api-otel data-plane-worker-otel; do
  occurrences=$(grep -c "name: $cm" "$TMP/cpdp-otel.yaml" || true)
  if [ "$occurrences" -lt 2 ]; then
    red "FAIL: $cm referenced fewer than 2 times (ConfigMap + envFrom expected) — got $occurrences"
    exit 1
  fi
  green "ok  - $cm referenced by a Deployment envFrom"
done

# Scenario 6c: backward-compat — without the global endpoint, the new
# OTel ConfigMaps (and their envFrom refs) must NOT render.
blue "scenario 6c: CP/DP OTel ConfigMaps omitted when global endpoint unset"
render "$TMP/cpdp-noendpoint.yaml" \
  --set neuraltrust-control-plane.controlPlane.enabled=true \
  --set neuraltrust-data-plane.dataPlane.enabled=true
assert_not_contains "$TMP/cpdp-noendpoint.yaml" "name: control-plane-api-otel"  "no control-plane-api OTel ConfigMap without global endpoint"
assert_not_contains "$TMP/cpdp-noendpoint.yaml" "name: data-plane-worker-otel"  "no data-plane-worker OTel ConfigMap without global endpoint"

# Scenario 6d: scheduler probes must hit /v1/health (routes mounted under /v1).
blue "scenario 6d: control-plane-scheduler probes use /v1/health"
render "$TMP/cp-scheduler.yaml" \
  --set neuraltrust-control-plane.controlPlane.enabled=true
scheduler_probe_paths=$(awk '/kind: Deployment/{d=0} /name: control-plane-scheduler/{d=1} d && /path:/{print}' "$TMP/cp-scheduler.yaml" | sort -u)
if [ "$scheduler_probe_paths" != "            path: \"/v1/health\"" ] && [ "$scheduler_probe_paths" != '            path: "/v1/health"' ]; then
  red "FAIL: scheduler probe paths expected only /v1/health, got:${scheduler_probe_paths}"
  exit 1
fi
green "ok  - scheduler liveness/readiness probe path is /v1/health"

# Scenario 6e: bind addresses default to working values across cluster topologies.
# ClickHouse `<listen_host>` and control-plane-app `HOSTNAME` default to `::` —
# a single socket bound to `::` accepts both IPv4 and IPv6 on Linux when
# `net.ipv6.bindv6only=0` (the kernel default).
# Trustgate Redis defaults to `0.0.0.0 -::` (Redis 7.0+ multi-bind syntax: the
# `-` prefix marks the address optional, so Redis skips IPv6 silently when the
# socket can't be created). This is Redis-specific because the kubelet
# `tcpSocket` liveness probe connects to the pod's IPv4 address — on certain
# IPv4-only nodes (e.g. AWS EKS), a Redis instance bound only to `::` answers
# IPv6 fine but rejects the IPv4 probe, triggering a SIGTERM crash loop.
# Operators must still be able to pin each setting to a specific address.
blue "scenario 6e: bind addresses default to working cross-topology values"
render "$TMP/bind-default.yaml" \
  --set neuraltrust-control-plane.controlPlane.enabled=true
assert_contains "$TMP/bind-default.yaml" "<listen_host>::</listen_host>" "ClickHouse listen_host defaults to ::"
assert_contains "$TMP/bind-default.yaml" '^    bind 0\.0\.0\.0 -::$'    "Trustgate Redis bind defaults to 0.0.0.0 -:: (IPv4 required, IPv6 optional)"
app_hostname=$(grep -A 1 "name: HOSTNAME$" "$TMP/bind-default.yaml" | grep "value:" | head -1 | tr -d '[:space:]')
if [ "$app_hostname" != 'value:"::"' ]; then
  red "FAIL: control-plane-app HOSTNAME expected value \"::\", got: ${app_hostname}"
  exit 1
fi
green "ok  - control-plane-app HOSTNAME defaults to ::"

blue "scenario 6e (cont): bind addresses overridable (IPv4-only and IPv6-only)"
render "$TMP/bind-ipv4.yaml" \
  --set clickhouse.listenHost=0.0.0.0 \
  --set trustgate.redis.bind=0.0.0.0 \
  --set neuraltrust-control-plane.controlPlane.enabled=true \
  --set neuraltrust-control-plane.controlPlane.components.app.hostname=0.0.0.0
assert_contains "$TMP/bind-ipv4.yaml" "<listen_host>0.0.0.0</listen_host>" "ClickHouse listen_host overridable to 0.0.0.0"
assert_contains "$TMP/bind-ipv4.yaml" "^    bind 0.0.0.0$"                 "Trustgate Redis bind overridable to 0.0.0.0"
app_hostname_v4=$(grep -A 1 "name: HOSTNAME$" "$TMP/bind-ipv4.yaml" | grep "value:" | head -1 | tr -d '[:space:]')
if [ "$app_hostname_v4" != 'value:"0.0.0.0"' ]; then
  red "FAIL: control-plane-app HOSTNAME expected value \"0.0.0.0\", got: ${app_hostname_v4}"
  exit 1
fi
green "ok  - control-plane-app HOSTNAME overridable to 0.0.0.0"

# IPv6-only clusters: operator must be able to pin Redis to `::` (no IPv4 wildcard).
render "$TMP/bind-ipv6.yaml" --set trustgate.redis.bind=::
assert_contains "$TMP/bind-ipv6.yaml" "^    bind ::$" "Trustgate Redis bind overridable to :: (IPv6-only)"

# Scenario 7: backward compat — without the global override, every
# component keeps its prior default. This test exists to catch a future
# regression where someone changes the default to point at the in-chart
# collector unconditionally and breaks customers who still rely on
# their own collector at the legacy DNS name.
blue "scenario 7: defaults preserved when global collector endpoint unset"
render "$TMP/legacy.yaml" \
  --set firewall.enabled=true \
  --set trustgate.enabled=true
assert_contains "$TMP/legacy.yaml" "OTEL_EXPORTER_OTLP_ENDPOINT: \"http://opentelemetry-collector.opentelemetry" "firewall keeps its legacy default endpoint"
assert_contains "$TMP/legacy.yaml" "OPENTELEMETRY_ENABLED: \"false\"" "trustgate stays OFF by default"

# Scenario 8: monitoring CRDs are gated on cluster capability.
# When global.monitoring.enabled=true but the monitoring.coreos.com/v1
# CRDs are NOT in the cluster, NO PrometheusRule/ServiceMonitor/PodMonitor
# resources may render. This protects clusters without the Prometheus
# Operator from `helm upgrade` failures.
blue "scenario 8: monitoring CRDs absent => no operator resources"
render "$TMP/mon-nocrd.yaml" \
  --set global.monitoring.enabled=true \
  --set trustgate.enabled=true \
  --set firewall.enabled=true \
  --set neuraltrust-watchdog.enabled=true \
  --set controlPlane.enabled=true
assert_not_contains "$TMP/mon-nocrd.yaml" "kind: PrometheusRule"  "no PrometheusRule when CRDs missing"
assert_not_contains "$TMP/mon-nocrd.yaml" "kind: ServiceMonitor"  "no ServiceMonitor when CRDs missing"
assert_not_contains "$TMP/mon-nocrd.yaml" "kind: PodMonitor"      "no PodMonitor when CRDs missing"

# Scenario 9: monitoring CRDs present + flag on => every component renders.
# Catches accidental regressions where a subchart's monitoring.yaml gets
# silently disabled (e.g. wrong gate variable, unmerged global block).
blue "scenario 9: monitoring CRDs available => every component renders"
render "$TMP/mon-on.yaml" \
  --set global.monitoring.enabled=true \
  --set trustgate.enabled=true \
  --set firewall.enabled=true \
  --set kafka.enabled=true \
  --set neuraltrust-watchdog.enabled=true \
  --set controlPlane.enabled=true \
  --api-versions monitoring.coreos.com/v1
assert_contains "$TMP/mon-on.yaml" "name: clickhouse"                              "clickhouse PrometheusRule rendered"
assert_contains "$TMP/mon-on.yaml" "name: control-plane"                           "control-plane PrometheusRule rendered"
assert_contains "$TMP/mon-on.yaml" "name: data-plane"                              "data-plane PrometheusRule rendered"
assert_contains "$TMP/mon-on.yaml" "name: firewall"                                "firewall PrometheusRule rendered"
assert_contains "$TMP/mon-on.yaml" "name: kafka"                                   "kafka PrometheusRule rendered"
assert_contains "$TMP/mon-on.yaml" "name: trustgate"                               "trustgate PrometheusRule rendered"
assert_contains "$TMP/mon-on.yaml" "name: trustgate-data-plane"                    "trustgate-data-plane PodMonitor rendered"
assert_contains "$TMP/mon-on.yaml" "name: neuraltrust-watchdog-rules"              "watchdog PrometheusRule rendered"
assert_not_contains "$TMP/mon-on.yaml" "name: otel-collector-config" "otel collector omitted unless global.observability.enabled"

blue "scenario 9b: v2 monitoring renders runtime ServiceMonitors"
render_default "$TMP/mon-v2.yaml" \
  --set global.monitoring.enabled=true \
  --api-versions monitoring.coreos.com/v1
yq e 'select(.kind == "ServiceMonitor") | .metadata.name' "$TMP/mon-v2.yaml" > "$TMP/mon-v2-names.txt"
assert_contains "$TMP/mon-v2-names.txt" "agentgateway" "AgentGateway ServiceMonitor rendered under v2"
assert_contains "$TMP/mon-v2-names.txt" "trustguard" "TrustGuard ServiceMonitor rendered under v2"
assert_not_contains "$TMP/mon-v2-names.txt" "trustgate" "legacy TrustGate monitoring omitted under v2"

# Scenario 10: watchdog pod scrape annotations are baseline.
# Universal scrape contract that works in every monitoring stack
# (Prometheus Operator, GMP, AMP, Azure Monitor, in-chart OTel
# collector, air-gapped). Default ON.
blue "scenario 10: watchdog scrape annotations baked into Deployment"
render "$TMP/wd-annot.yaml" --set neuraltrust-watchdog.enabled=true
assert_contains     "$TMP/wd-annot.yaml" 'prometheus.io/scrape: "true"' "scrapeAnnotations.enabled=true bakes prometheus.io/scrape"
assert_contains     "$TMP/wd-annot.yaml" 'prometheus.io/port: "8080"'   "scrapeAnnotations bakes prometheus.io/port"
assert_contains     "$TMP/wd-annot.yaml" 'prometheus.io/path: "/metrics"' "scrapeAnnotations bakes prometheus.io/path"

# Scenario 11: watchdog scrape annotations opt-out.
blue "scenario 11: watchdog scrapeAnnotations.enabled=false omits annotations"
render "$TMP/wd-noannot.yaml" \
  --set neuraltrust-watchdog.enabled=true \
  --set neuraltrust-watchdog.monitoring.scrapeAnnotations.enabled=false
assert_not_contains "$TMP/wd-noannot.yaml" 'prometheus.io/scrape: "true"' "annotations omitted when scrapeAnnotations.enabled=false"

# Scenario 12: GMP-native rendering. Customers running Google Managed
# Prometheus (GKE built-in or GMP-on-other-cloud) flip
# monitoring.podMonitoring.enabled + monitoring.gmpRules.enabled. Both
# resources gate on the matching CRD via APIVersions.Has.
blue "scenario 12: GMP-native PodMonitoring + Rules render with the right CRDs"
render "$TMP/wd-gmp.yaml" \
  --set neuraltrust-watchdog.enabled=true \
  --set neuraltrust-watchdog.monitoring.podMonitoring.enabled=true \
  --set neuraltrust-watchdog.monitoring.gmpRules.enabled=true \
  --api-versions monitoring.googleapis.com/v1/PodMonitoring \
  --api-versions monitoring.googleapis.com/v1/Rules
assert_contains     "$TMP/wd-gmp.yaml" "kind: PodMonitoring" "PodMonitoring (GMP) renders with monitoring.googleapis.com/v1 CRDs"
assert_contains     "$TMP/wd-gmp.yaml" "kind: Rules"        "Rules (GMP) renders with monitoring.googleapis.com/v1 CRDs"

# Scenario 13: GMP toggles ON but CRDs absent => silent no-op (no kind:
# PodMonitoring, no kind: Rules in render output). This protects
# clusters without GMP from spurious resources.
blue "scenario 13: GMP toggles + no CRDs => silent no-op"
render "$TMP/wd-gmp-nocrd.yaml" \
  --set neuraltrust-watchdog.enabled=true \
  --set neuraltrust-watchdog.monitoring.podMonitoring.enabled=true \
  --set neuraltrust-watchdog.monitoring.gmpRules.enabled=true
assert_not_contains "$TMP/wd-gmp-nocrd.yaml" "kind: PodMonitoring" "PodMonitoring omitted when GMP CRDs absent"
assert_not_contains "$TMP/wd-gmp-nocrd.yaml" "^kind: Rules$"       "Rules omitted when GMP CRDs absent"

# Scenario 14: self-monitoring overlay. With values-self-monitoring.yaml.example
# layered on, the watchdog Deployment is up AND the curated checks flip to
# enabled=true via the new enabledCheckIds overlay (without losing their
# target / thresholds / actions definitions).
blue "scenario 14: values-self-monitoring overlay enables curated checks"
helm template test "$CHART_DIR" \
  -f "$CHART_DIR/values-required.yaml" \
  -f "$CHART_DIR/values-self-monitoring.yaml.example" \
  --set neuraltrust-control-plane.controlPlane.enabled=true \
  --set neuraltrust-data-plane.dataPlane.enabled=true > "$TMP/self-mon.yaml"
assert_contains "$TMP/self-mon.yaml" "name: neuraltrust-watchdog\$"   "watchdog Deployment rendered by overlay"
# Curated check ids are flipped on (regex tolerates surrounding YAML indent).
assert_contains "$TMP/self-mon.yaml" "id: control-plane-synthetic"         "control-plane-synthetic check present in overlay"
assert_contains "$TMP/self-mon.yaml" "id: v2-data-plane-synthetic"         "Kafka-free v2 data-plane check present in overlay"
assert_contains "$TMP/self-mon.yaml" "id: firewall-health"                   "firewall-health check present in overlay"
# The kafka-broker check must keep its target.bootstrapServers (overlay
# flips enabled only — must NOT replace the check definition).
assert_contains "$TMP/self-mon.yaml" "bootstrapServers:"                   "kafka-broker target preserved through overlay"
# scheduler URL: control-plane-synthetic hits /v1/health on the chart Service.
assert_contains "$TMP/self-mon.yaml" "control-plane-scheduler-service/v1/health" "scheduler URL fixed to /v1/health on chart Service"

# Scenario 15: overlay backward-compat. Without the overlay (or without
# `enabledCheckIds`), the curated synthetic checks are not flipped on by the
# overlay. Other checks may be enabled by default (for example the bundled RED
# PromQL checks), so assert the overlay-controlled check IDs specifically.
blue "scenario 15: no overlay => no curated-check flip"
render "$TMP/no-overlay.yaml" --set neuraltrust-watchdog.enabled=true
for check_id in control-plane-synthetic data-plane-synthetic firewall-health; do
  enabled=$(awk -v id="$check_id" '
    $0 ~ "id: " id { print last_enabled; found=1; exit }
    $0 ~ /^[[:space:]]*enabled:/ { last_enabled=$2 }
    END { if (!found) print "missing" }
  ' "$TMP/no-overlay.yaml")
  if [ "$enabled" != "false" ]; then
    red "FAIL: watchdog check $check_id without overlay: expected enabled=false, got $enabled"
    exit 1
  fi
done
green "ok  - curated checks stay disabled without overlay (backward-compat preserved)"

# Scenario 16: data-plane-api k8sJobs is OFF by default — matches
# data-plane-api K8S_JOBS_ENABLED=false when unset. No job-creator RBAC,
# no K8S_* env vars on the API pod. The API still runs under the shared
# `data-plane` SA (same as worker / kafka-connect), never a bespoke one.
blue "scenario 16: data-plane-api k8sJobs disabled by default"
render "$TMP/dp-jobs-default.yaml" \
  --set neuraltrust-data-plane.dataPlane.enabled=true
assert_not_contains "$TMP/dp-jobs-default.yaml" "name: data-plane-job-creator"        "no Role/RoleBinding when k8sJobs disabled by default"
assert_not_contains "$TMP/dp-jobs-default.yaml" "serviceAccountName: data-plane-api"  "API never pins a bespoke data-plane-api SA"
assert_contains     "$TMP/dp-jobs-default.yaml" "serviceAccountName: data-plane$"     "API Deployment runs under the shared data-plane SA"
assert_not_contains "$TMP/dp-jobs-default.yaml" 'name: K8S_JOBS_ENABLED'              "no K8S_JOBS_ENABLED env when k8sJobs disabled by default"
assert_not_contains "$TMP/dp-jobs-default.yaml" 'name: K8S_JOB_IMAGE'                 "no K8S_JOB_IMAGE env when k8sJobs disabled by default"

# Scenario 16b: trustTestConfig.enabled defaults to false — ConfigMap and volume
# mount render only when explicitly opted in.
blue "scenario 16b: data-plane-api trustTestConfig mount disabled by default"
render "$TMP/dp-trusttest-default.yaml" \
  --set neuraltrust-data-plane.dataPlane.enabled=true
assert_not_contains "$TMP/dp-trusttest-default.yaml" "name: data-plane-trusttest-config"      "trusttest ConfigMap omitted by default"
assert_not_contains "$TMP/dp-trusttest-default.yaml" "mountPath: /app/.trusttest_config.json"  "trusttest config not mounted by default"
render "$TMP/dp-trusttest-on.yaml" \
  --set neuraltrust-data-plane.dataPlane.enabled=true \
  --set neuraltrust-data-plane.dataPlane.components.api.trustTestConfig.enabled=true
assert_contains "$TMP/dp-trusttest-on.yaml" "name: data-plane-trusttest-config"       "trusttest ConfigMap rendered when trustTestConfig.enabled=true"
assert_contains "$TMP/dp-trusttest-on.yaml" "mountPath: /app/.trusttest_config.json"  "trusttest config mounted when opted in"
# Legacy trustTestConfig: {} does not opt in (requires explicit enabled: true).
cat > "$TMP/dp-trusttest-legacy-values.yaml" <<'YAML'
neuraltrust-data-plane:
  dataPlane:
    enabled: true
    components:
      api:
        trustTestConfig: {}
YAML
render "$TMP/dp-trusttest-legacy.yaml" -f "$TMP/dp-trusttest-legacy-values.yaml"
assert_not_contains "$TMP/dp-trusttest-legacy.yaml" "mountPath: /app/.trusttest_config.json" "legacy trustTestConfig: {} does not mount without enabled: true"
# trustTestConfig: null must disable.
cat > "$TMP/dp-trusttest-null-values.yaml" <<'YAML'
neuraltrust-data-plane:
  dataPlane:
    enabled: true
    components:
      api:
        trustTestConfig: null
YAML
render "$TMP/dp-trusttest-null.yaml" -f "$TMP/dp-trusttest-null-values.yaml"
assert_not_contains "$TMP/dp-trusttest-null.yaml" "mountPath: /app/.trusttest_config.json" "trusttest config not mounted when trustTestConfig: null"

# Scenario 17: opt-in path. Setting k8sJobs.enabled=true renders the
# job-creator RBAC bound to the shared `data-plane` SA (NOT a new SA),
# wires K8S_* env vars, and forwards the pull secret for spawned Job pods.
blue "scenario 17: data-plane-api k8sJobs explicit opt-in"
render "$TMP/dp-jobs-on.yaml" \
  --set neuraltrust-data-plane.dataPlane.enabled=true \
  --set neuraltrust-data-plane.dataPlane.components.api.k8sJobs.enabled=true
assert_not_contains "$TMP/dp-jobs-on.yaml" "name: data-plane-api$"          "no separate data-plane-api ServiceAccount — the data-plane SA is reused"
assert_contains "$TMP/dp-jobs-on.yaml" "name: data-plane-job-creator$"  "data-plane-job-creator Role + RoleBinding rendered when k8sJobs enabled"
assert_contains "$TMP/dp-jobs-on.yaml" "serviceAccountName: data-plane$" "API Deployment uses the shared data-plane SA when k8sJobs enabled"
assert_contains "$TMP/dp-jobs-on.yaml" 'name: K8S_JOBS_ENABLED'              "K8S_JOBS_ENABLED wired on API pod when k8sJobs enabled"
assert_contains "$TMP/dp-jobs-on.yaml" 'name: K8S_JOB_IMAGE'                 "K8S_JOB_IMAGE wired on API pod when k8sJobs enabled"
assert_contains "$TMP/dp-jobs-on.yaml" 'name: K8S_JOB_SERVICE_ACCOUNT'       "K8S_JOB_SERVICE_ACCOUNT wired on API pod when k8sJobs enabled"
assert_not_contains "$TMP/dp-jobs-on.yaml" 'name: K8S_JOB_SECRETS_MODE'      "no K8S_JOB_SECRETS_MODE env (mode toggle removed)"
assert_contains "$TMP/dp-jobs-on.yaml" 'name: K8S_JOB_IMAGE_PULL_SECRET'    "K8S_JOB_IMAGE_PULL_SECRET wired when k8sJobs enabled (Job pods inherit pull secret)"

# Scenario 17b: pull-secret opt-out for IAM / Workload Identity clusters.
# With k8sJobs enabled, setting imagePullSecrets to "none" drops the
# Deployment's imagePullSecrets AND the K8S_JOB_IMAGE_PULL_SECRET env.
blue "scenario 17b: data-plane k8sJobs pull-secret opt-out (IAM / WIF)"
render "$TMP/dp-jobs-noatch.yaml" \
  --set neuraltrust-data-plane.dataPlane.enabled=true \
  --set neuraltrust-data-plane.dataPlane.components.api.k8sJobs.enabled=true \
  --set neuraltrust-data-plane.imagePullSecrets=none
assert_not_contains "$TMP/dp-jobs-noatch.yaml" 'name: K8S_JOB_IMAGE_PULL_SECRET' "no K8S_JOB_IMAGE_PULL_SECRET env when pull secret opted out"

# Scenario 18: TrustGate IAM DB auth. With DATABASE_AUTH_MODE=iam the chart
# must skip the postgresql-init Job (the chart can no longer password-auth as
# admin) and emit DATABASE_IAM_AUTH=true. Default (password) keeps the Job.
blue "scenario 18: TrustGate IAM Postgres auth skips the init Job"
render "$TMP/tg-iam.yaml" \
  --set trustgate.enabled=true \
  --set trustgate.global.env.DATABASE_AUTH_MODE=iam
assert_not_contains "$TMP/tg-iam.yaml" "app.kubernetes.io/component: postgresql-init" "postgresql-init Job skipped in IAM mode"
# DATABASE_IAM_AUTH=true (base64 "dHJ1ZQ==") written into trustgate-secrets.
assert_contains     "$TMP/tg-iam.yaml" "DATABASE_IAM_AUTH: \"dHJ1ZQ==\""               "DATABASE_IAM_AUTH=true in trustgate-secrets (IAM mode)"

blue "scenario 18b: TrustGate password auth (default) keeps the init Job"
assert_contains     "$TMP/default.yaml" "app.kubernetes.io/component: postgresql-init" "postgresql-init Job present in password mode"

# Scenario 18c: TrustGate postgresql.passwordSecretRef. The DB password lives
# ONLY in the user's Secret (external-secrets / CSI): containers reference it via
# secretKeyRef. TrustGate reads the individual DATABASE_* vars (not DATABASE_URL),
# so the chart-managed trustgate-secrets never carries the password, and
# DATABASE_URL is omitted entirely in this mode.
blue "scenario 18c: TrustGate passwordSecretRef keeps the password out of trustgate-secrets"
render "$TMP/tg-pw-secret.yaml" \
  --set trustgate.enabled=true \
  --set trustgate.postgresql.passwordSecretRef.name=tg-ext-pg \
  --set trustgate.postgresql.passwordSecretRef.key=azure-pg-password \
  --set trustgate.global.env.DATABASE_HOST=db.example.com
assert_contains "$TMP/tg-pw-secret.yaml" "name: \"tg-ext-pg\"" "DATABASE_PASSWORD sourced via secretKeyRef from the user Secret"
assert_contains "$TMP/tg-pw-secret.yaml" "key: \"azure-pg-password\"" "DATABASE_PASSWORD uses the configured key from the user Secret"
# Scope the negative assertions to the trustgate-secrets object (other secrets
# legitimately carry a DATABASE_URL, e.g. the in-cluster postgresql-secrets).
awk 'BEGIN{RS="---\n"} /kind: Secret/ && /name: trustgate-secrets/ {print}' "$TMP/tg-pw-secret.yaml" > "$TMP/tg-pw-secret-only.yaml"
assert_not_contains "$TMP/tg-pw-secret-only.yaml" "DATABASE_PASSWORD:" "trustgate-secrets omits DATABASE_PASSWORD in passwordSecretRef mode"
assert_not_contains "$TMP/tg-pw-secret-only.yaml" "DATABASE_URL:"      "trustgate-secrets omits DATABASE_URL in passwordSecretRef mode"

# Scenario 19: IRSA. applyGlobally annotates every component ServiceAccount with
# the role; default (off) emits no role annotation. Guards the new
# serviceAccount.annotationsBlock helper.
blue "scenario 19: global IRSA annotates ServiceAccounts when applyGlobally=true"
render "$TMP/irsa-on.yaml" \
  --set trustgate.enabled=true \
  --set global.irsa.roleArn=arn:aws:iam::111122223333:role/nt-platform \
  --set global.irsa.applyGlobally=true
assert_contains     "$TMP/irsa-on.yaml" "eks.amazonaws.com/role-arn: .?arn:aws:iam::111122223333:role/nt-platform" "IRSA role annotation applied to SAs"
assert_not_contains "$TMP/default.yaml" "eks.amazonaws.com/role-arn"                                                  "no IRSA annotation by default (backward-compat)"

# Scenario 20: TrustGate external Redis IAM auth. The ConfigMap exposes
# REDIS_AUTH_MODE / REDIS_IAM_AUTH (plaintext, app-readable).
blue "scenario 20: TrustGate Redis IAM auth flags in env ConfigMap"
render "$TMP/tg-redis-iam.yaml" \
  --set trustgate.enabled=true \
  --set trustgate.redis.enabled=false \
  --set trustgate.redis.external.host=cache.example.com \
  --set trustgate.redis.external.authMode=iam
assert_contains "$TMP/tg-redis-iam.yaml" "REDIS_AUTH_MODE: \"iam\""  "REDIS_AUTH_MODE emitted for external Redis IAM"
assert_contains "$TMP/tg-redis-iam.yaml" "REDIS_IAM_AUTH: \"true\""  "REDIS_IAM_AUTH=true emitted for external Redis IAM"

# Scenario 21: the OTel Collector Prometheus exporter (:8889) is gated on BOTH
# the collector AND the watchdog subchart (local RED path). Collector-less
# watchdog installs omit :8889 entirely.
blue "scenario 21: collector Prometheus exporter gated on collector+watchdog"
assert_not_contains "$TMP/watchdog.yaml"       "0.0.0.0:8889" "collector-less watchdog omits :8889 exporter"
render "$TMP/watchdog-collector.yaml" \
  --set neuraltrust-watchdog.enabled=true \
  --set global.observability.enabled=true
assert_contains     "$TMP/watchdog-collector.yaml" "0.0.0.0:8889" "collector exposes :8889 when collector+watchdog both enabled"
assert_not_contains "$TMP/default-obs-on.yaml" "0.0.0.0:8889" "collector omits :8889 when watchdog disabled"

# Scenario 22: Control-Plane IAM Postgres auth. IAM is only honored for external
# PostgreSQL — the chart emits DATABASE_IAM_AUTH=true (base64 "dHJ1ZQ==") in
# postgresql-secrets. With in-cluster PG it must stay password (false). TrustGate
# is disabled here so the only DATABASE_IAM_AUTH key comes from control-plane.
blue "scenario 22: Control-Plane IAM Postgres auth (external only)"
render "$TMP/cp-iam.yaml" \
  --set trustgate.enabled=false \
  --set neuraltrust-control-plane.infrastructure.postgresql.deploy=false \
  --set neuraltrust-control-plane.controlPlane.components.postgresql.secrets.host=db.example.com \
  --set neuraltrust-control-plane.controlPlane.components.postgresql.authMode=iam
assert_contains     "$TMP/cp-iam.yaml" "DATABASE_IAM_AUTH: \"dHJ1ZQ==\"" "control-plane DATABASE_IAM_AUTH=true for external IAM Postgres"
assert_not_contains "$TMP/cp-iam.yaml" "DATABASE_IAM_AUTH: \"ZmFsc2U=\"" "no password-mode flag when control-plane IAM is active"

blue "scenario 22b: Control-Plane IAM ignored for the in-cluster bundled PG"
render "$TMP/cp-iam-incluster.yaml" \
  --set trustgate.enabled=false \
  --set neuraltrust-control-plane.controlPlane.components.postgresql.authMode=iam
assert_contains     "$TMP/cp-iam-incluster.yaml" "DATABASE_IAM_AUTH: \"ZmFsc2U=\"" "in-cluster PG stays password even with authMode=iam"
assert_not_contains "$TMP/cp-iam-incluster.yaml" "DATABASE_IAM_AUTH: \"dHJ1ZQ==\"" "IAM not activated for in-cluster PG"

# Scenario 25: global.nodeSelector / global.tolerations pin EVERY workload to a
# dedicated (optionally tainted) node pool with a single setting. Default OFF —
# default render must inject no nodeSelector. Per-component nodeSelector still
# merges on top (per-component keys win on conflicts).
blue "scenario 25: global.nodeSelector + global.tolerations pin all workloads"
render "$TMP/global-nodeselector.yaml" \
  --set trustgate.enabled=true \
  --set firewall.enabled=true \
  --set neuraltrust-watchdog.enabled=true \
  --set neuraltrust-control-plane.controlPlane.enabled=true \
  --set neuraltrust-data-plane.dataPlane.enabled=true \
  --set global.nodeSelector.dedicated=neuraltrust \
  --set 'global.tolerations[0].key=dedicated' \
  --set 'global.tolerations[0].operator=Equal' \
  --set 'global.tolerations[0].value=neuraltrust' \
  --set 'global.tolerations[0].effect=NoSchedule'
assert_contains "$TMP/global-nodeselector.yaml" "dedicated: neuraltrust"  "global.nodeSelector key rendered on workloads"
# Applied broadly, not just one pod.
ns_count=$(grep -c "dedicated: neuraltrust" "$TMP/global-nodeselector.yaml" || true)
if [ "$ns_count" -lt 6 ]; then
  red "FAIL: global.nodeSelector applied to only $ns_count pod specs (expected >= 6)"
  exit 1
fi
green "ok  - global.nodeSelector applied to $ns_count workload pod specs"
assert_contains "$TMP/global-nodeselector.yaml" "key: dedicated"          "global.tolerations rendered on workloads"
assert_contains "$TMP/global-nodeselector.yaml" "effect: NoSchedule"      "global.tolerations effect rendered"

# Scenario 25b: backward-compat — without global.nodeSelector/tolerations and no
# per-component overrides, the default render injects no nodeSelector at all.
blue "scenario 25b: no nodeSelector injected by default (backward-compat)"
assert_not_contains "$TMP/default.yaml" "nodeSelector:" "default render carries no nodeSelector"

# Scenario 25c: per-component nodeSelector still wins on key conflicts. With a
# global key AND the same key set on clickhouse, the clickhouse StatefulSet must
# carry the per-component value.
blue "scenario 25c: per-component nodeSelector overrides global on conflict"
render "$TMP/nodeselector-override.yaml" \
  --set global.nodeSelector.dedicated=platform-pool \
  --set clickhouse.nodeSelector.dedicated=clickhouse-pool
# Scope to the clickhouse StatefulSet (a Service is also named clickhouse, so
# match on kind + name together) and read its nodeSelector value.
chouse_sel=$(awk '
  /^kind:/{k=$2}
  /^  name:/{n=$2}
  /dedicated:/ && k=="StatefulSet" && n=="clickhouse" {print $2; exit}
' "$TMP/nodeselector-override.yaml")
if [ "$chouse_sel" != "clickhouse-pool" ]; then
  red "FAIL: clickhouse nodeSelector expected clickhouse-pool (per-component wins), got: ${chouse_sel:-<none>}"
  exit 1
fi
green "ok  - per-component nodeSelector wins over global on key conflict"

# Scenario 25d: firewall GPU workers pin to a different node pool than the global
# default using the SAME label key. global.nodeSelector keys the CPU pool and the
# per-worker nodeSelector keys the GPU pool on `nodepool`. The worker must end up
# with a single nodeAffinity selecting the GPU pool (per-worker wins) and NO plain
# nodeSelector forcing the CPU pool — otherwise the two collide and the worker can
# never schedule on GPU.
blue "scenario 25d: firewall worker per-pool selector overrides global on same key"
render "$TMP/firewall-gpu-pool.yaml" \
  --set neuraltrust-firewall.firewall.enabled=true \
  --set global.nodeSelector.nodepool=cpu-pool \
  --set 'neuraltrust-firewall.firewall.workers.toxicity.enabled=true' \
  --set 'neuraltrust-firewall.firewall.workerDefaults.nodeSelector.nodepool[0]=gpu-pool'
# Scope to the toxicity-worker Deployment document (split on the YAML `---`
# separator so the assertions never bleed into an adjacent resource) and assert
# it requires the GPU pool via nodeAffinity and never the CPU pool via a plain
# nodeSelector.
worker_block=$(awk '
  /^---[[:space:]]*$/ { if (isdep && isname) print buf; buf=""; isdep=0; isname=0; next }
  { buf = buf $0 "\n" }
  /^kind: Deployment[[:space:]]*$/ { isdep=1 }
  /^  name: toxicity-worker[[:space:]]*$/ { isname=1 }
  END { if (isdep && isname) print buf }
' "$TMP/firewall-gpu-pool.yaml")
if ! printf '%s\n' "$worker_block" | grep -qE -- "- gpu-pool"; then
  red "FAIL: firewall worker nodeAffinity does not select the GPU pool (gpu-pool)"
  printf '%s\n' "$worker_block" | grep -nE "affinity|nodeSelector|nodepool|pool" | head -20
  exit 1
fi
green "ok  - firewall worker nodeAffinity selects the GPU pool"
if printf '%s\n' "$worker_block" | grep -qE -- "nodepool: cpu-pool"; then
  red "FAIL: firewall worker still carries a plain nodeSelector pinning the CPU pool (conflict)"
  printf '%s\n' "$worker_block" | grep -nE "nodeSelector|cpu-pool" | head -20
  exit 1
fi
green "ok  - firewall worker carries no conflicting CPU-pool nodeSelector"

# Scenario 26: external PostgreSQL via global.postgresql.deploy=false. The chart
# must skip every postgres-image consumer so the heavy image is never pulled:
#   - in-cluster control-plane-postgresql Deployment,
#   - control-plane API/scheduler wait-for-postgresql initContainers,
#   - TrustGate postgresql-init Job.
# The control-plane app init-db (Prisma migrations, app image) MUST stay.
blue "scenario 26: global.postgresql.deploy=false skips all postgres-image consumers"
render "$TMP/pg-external.yaml" \
  --set trustgate.enabled=true \
  --set neuraltrust-control-plane.controlPlane.enabled=true \
  --set neuraltrust-data-plane.dataPlane.enabled=true \
  --set global.postgresql.deploy=false
assert_not_contains "$TMP/pg-external.yaml" "name: control-plane-postgresql"                "in-cluster PostgreSQL Deployment skipped (external)"
assert_not_contains "$TMP/pg-external.yaml" "name: wait-for-postgresql"                      "wait-for-postgresql initContainers skipped (external)"
assert_not_contains "$TMP/pg-external.yaml" "app.kubernetes.io/component: postgresql-init"   "TrustGate postgresql-init Job skipped (external)"
assert_contains     "$TMP/pg-external.yaml" "name: init-db"                                  "control-plane app init-db (Prisma) still present (external)"

assert_render_fails "deprecated root PostgreSQL alias fails with migration guidance" \
  --set global.platformVersion=v1 \
  --set infrastructure.postgresql.deploy=false

render "$TMP/pg-legacy-component-disabled.yaml" \
  --set neuraltrust-control-plane.controlPlane.enabled=true \
  --set neuraltrust-control-plane.controlPlane.components.postgresql.installInCluster=false
assert_not_contains "$TMP/pg-legacy-component-disabled.yaml" "name: control-plane-postgresql" "legacy installInCluster=false remains authoritative"

# Scenario 26b: default (deploy=true) keeps every consumer (backward-compat).
blue "scenario 26b: global.postgresql.deploy=true (default) keeps postgres-image consumers"
render "$TMP/pg-incluster.yaml" \
  --set trustgate.enabled=true \
  --set neuraltrust-control-plane.controlPlane.enabled=true
assert_contains "$TMP/pg-incluster.yaml" "name: control-plane-postgresql"              "in-cluster PostgreSQL Deployment present by default"
assert_contains "$TMP/pg-incluster.yaml" "name: wait-for-postgresql"                   "wait-for-postgresql initContainers present by default"
assert_contains "$TMP/pg-incluster.yaml" "app.kubernetes.io/component: postgresql-init" "TrustGate postgresql-init Job present by default"

# Scenario 27: HPA and PDB are opt-in (default OFF). A plain install must not
# render any HorizontalPodAutoscaler or PodDisruptionBudget. Opting in per
# component must render the matching resources.
blue "scenario 27: HPA and PDB default off; opt-in renders resources"
assert_not_contains "$TMP/default.yaml" "kind: HorizontalPodAutoscaler" "no HPA by default"
assert_not_contains "$TMP/default.yaml" "kind: PodDisruptionBudget"   "no PDB by default"
render "$TMP/hpa-pdb-on.yaml" \
  --set neuraltrust-control-plane.controlPlane.enabled=true \
  --set neuraltrust-control-plane.controlPlane.components.api.autoscaling.enabled=true \
  --set neuraltrust-control-plane.controlPlane.components.api.podDisruptionBudget.enabled=true \
  --set neuraltrust-data-plane.dataPlane.components.api.autoscaling.enabled=true \
  --set neuraltrust-data-plane.dataPlane.components.api.podDisruptionBudget.enabled=true \
  --set trustgate.controlPlane.autoscaling.enabled=true \
  --set trustgate.controlPlane.podDisruptionBudget.enabled=true
assert_contains "$TMP/hpa-pdb-on.yaml" "name: control-plane-api" "control-plane-api HPA rendered when opted in"
assert_contains "$TMP/hpa-pdb-on.yaml" "name: data-plane-api"    "data-plane-api HPA rendered when opted in"
assert_contains "$TMP/hpa-pdb-on.yaml" "name: trustgate-control-plane" "trustgate-control-plane HPA rendered when opted in"
assert_contains "$TMP/hpa-pdb-on.yaml" "kind: PodDisruptionBudget" "PDB rendered when opted in"

# Scenario 28: external Kafka with SASL/TLS credentials from an existing Secret.
blue "scenario 28: external Kafka auth/TLS wiring"
render "$TMP/kafka-external.yaml" \
  -f values-required.yaml \
  --set infrastructure.kafka.deploy=false \
  --set global.kafka.bootstrapServers=kafka.example.svc:9093 \
  --set global.kafka.auth.enabled=true \
  --set global.kafka.auth.existingSecret=kafka-credentials \
  --set global.kafka.tls.enabled=true \
  --set global.kafka.tls.existingSecret=kafka-broker-ca \
  --set neuraltrust-data-plane.dataPlane.enabled=true \
  --set neuraltrust-control-plane.controlPlane.enabled=true \
  --set trustgate.enabled=true
assert_contains     "$TMP/kafka-external.yaml" "name: kafka-connection"              "kafka-connection ConfigMap rendered for external Kafka"
assert_contains     "$TMP/kafka-external.yaml" "KAFKA_SECURITY_PROTOCOL"            "KAFKA_SECURITY_PROTOCOL emitted"
assert_contains     "$TMP/kafka-external.yaml" "KAFKA_SASL_USERNAME"                "KAFKA_SASL_USERNAME sourced from existing Secret"
assert_contains     "$TMP/kafka-external.yaml" "CONNECT_SECURITY_PROTOCOL"          "Kafka Connect worker security protocol set"
assert_contains     "$TMP/kafka-external.yaml" "CONNECT_SSL_TRUSTSTORE_LOCATION"  "Kafka Connect TLS truststore configured"
assert_contains     "$TMP/kafka-external.yaml" "kafka-credentials"                  "Kafka credential Secret referenced by name"
assert_not_contains "$TMP/kafka-external.yaml" "password: your-"                    "no inline Kafka passwords in rendered manifests"
awk '/^kind: Deployment/{d=0} /name: trustgate-data-plane$/{d=1} d' "$TMP/kafka-external.yaml" > "$TMP/tg-dp-kafka.yaml"
assert_contains "$TMP/tg-dp-kafka.yaml" "name: KAFKA_HOST"              "TrustGate data-plane receives KAFKA_HOST from global.kafka"
assert_contains "$TMP/tg-dp-kafka.yaml" "name: KAFKA_SECURITY_PROTOCOL" "TrustGate data-plane receives SASL/TLS env vars"
assert_contains "$TMP/tg-dp-kafka.yaml" "name: kafka-broker-ca"         "TrustGate data-plane mounts Kafka broker CA for TLS"
# The kafka-connect init container creates the internal topics with explicit
# partition counts (idempotent create-if-not-exists), guards against a
# multi-partition connect-configs (which crashes Connect's herder on start), and
# keeps a writable logs dir under readOnlyRootFilesystem.
assert_contains     "$TMP/kafka-external.yaml" "connect-configs) echo 1 ;;"        "init container pins connect-configs to a single partition"
assert_contains     "$TMP/kafka-external.yaml" "--create --if-not-exists"          "init container provisions missing internal topics idempotently"
assert_contains     "$TMP/kafka-external.yaml" "Kafka Connect requires exactly 1"  "init container guards against a multi-partition connect-configs"
assert_contains     "$TMP/kafka-external.yaml" "mountPath: /opt/kafka/logs"        "kafka-connect mounts a writable logs dir for readOnlyRootFilesystem"

# Scenario 29: customCaCert for HTTP egress must not enable Kafka TLS on in-cluster broker.
blue "scenario 29: customCaCert does not enable Kafka TLS"
render "$TMP/kafka-customca-incluster.yaml" \
  -f values-required.yaml \
  --set global.customCaCert.enabled=true \
  --set global.customCaCert.secretName=corp-ca \
  --set neuraltrust-data-plane.dataPlane.enabled=true \
  --set neuraltrust-control-plane.controlPlane.enabled=true \
  --set trustgate.enabled=true
assert_not_contains "$TMP/kafka-customca-incluster.yaml" "name: KAFKA_SECURITY_PROTOCOL" "no Kafka SSL protocol when only customCaCert is enabled"
assert_not_contains "$TMP/kafka-customca-incluster.yaml" "name: KAFKA_SSL_CA_LOCATION"   "no Kafka SSL CA env when only customCaCert is enabled"
assert_not_contains "$TMP/kafka-customca-incluster.yaml" "name: kafka-broker-ca"         "no dedicated Kafka broker CA volume when only customCaCert is enabled"

# Scenario 30: TrustGate can source DB fields from a separate Secret while parent auto-generates the rest.
blue "scenario 30: TrustGate Postgres existing Secret with generated platform secrets"
render "$TMP/trustgate-postgres-existing-secret.yaml" \
  -f values-required.yaml \
  --set global.autoGenerateSecrets=true \
  --set global.preserveExistingSecrets=false \
  --set trustgate.enabled=true \
  --set trustgate.postgresql.existingSecret=trustgate-postgres \
  --set trustgate.postgresql.existingSecretKeys.host=DATABASE_HOST \
  --set trustgate.postgresql.existingSecretKeys.password=DATABASE_PASSWORD
assert_contains "$TMP/trustgate-postgres-existing-secret.yaml" "name: trustgate-secrets" "trustgate-secrets still rendered by parent chart"
assert_contains "$TMP/trustgate-postgres-existing-secret.yaml" "SERVER_SECRET_KEY:"      "TrustGate server key remains generated/resolved"
assert_contains "$TMP/trustgate-postgres-existing-secret.yaml" "DATABASE_URL:"           "TrustGate database URL still rendered for pods"
assert_not_contains "$TMP/trustgate-postgres-existing-secret.yaml" "preserveExistingSecrets: true" "mixed mode does not require preserving all secrets"

# Scenario 31: ClickHouse admin-password secret is prune-safe and re-renders
# deterministically. Rendered in v2 EXTERNAL because ClickHouse no longer deploys
# in the default hybrid mode (the secret template is version/mode-agnostic).
blue "scenario 31: ClickHouse admin-password secret carries resource-policy keep"
helm template test "$CHART_DIR" -f "$CHART_DIR/values-required.yaml" \
  --set global.deploymentMode=external \
  --show-only charts/clickhouse/templates/secret.yaml > "$TMP/ch-secret.yaml"
assert_contains "$TMP/ch-secret.yaml" "name: clickhouse"                "clickhouse admin-password secret rendered"
assert_contains "$TMP/ch-secret.yaml" "helm.sh/resource-policy: keep"   "clickhouse secret carries resource-policy keep"
assert_contains "$TMP/ch-secret.yaml" "admin-password:"                 "clickhouse secret emits admin-password"

# Scenario 32: preserveExistingSecrets=true skips chart-managed secrets, including ClickHouse
# (previously the ClickHouse subchart ignored this flag and kept rotating).
blue "scenario 32: preserveExistingSecrets=true skips chart-managed secrets (incl. ClickHouse)"
render "$TMP/preserve.yaml" \
  -f values-required.yaml \
  --set global.preserveExistingSecrets=true
assert_not_contains "$TMP/preserve.yaml" "admin-password: [A-Za-z0-9]" "ClickHouse secret skipped under preserveExistingSecrets"
# Anchor to the metadata line (2-space indent) so secretKeyRef references to the
# secret in pods/jobs don't count as the Secret resource itself.
assert_not_contains "$TMP/preserve.yaml" "^  name: postgresql-secrets$" "parent generated Secret resource skipped under preserveExistingSecrets"

# Scenario 33: parent-generated (non-hook) secrets are prune-safe so preserveExistingSecrets
# can be flipped after install without Helm pruning the live secrets.
blue "scenario 33: parent generated secrets carry resource-policy keep"
helm template test "$CHART_DIR" -f "$CHART_DIR/values-required.yaml" \
  --show-only templates/platform-secrets.yaml > "$TMP/platform-secrets.yaml"
assert_contains "$TMP/platform-secrets.yaml" "name: postgresql-secrets"      "postgresql-secrets rendered"
assert_contains "$TMP/platform-secrets.yaml" "helm.sh/resource-policy: keep" "parent generated secret carries resource-policy keep"

# Scenario 34: SERVER_SECRET_KEY is mandatory (not optional) on every TrustGate
# deployment, and the firewall API key is auto-populated when firewall is enabled.
blue "scenario 34: TrustGate SERVER_SECRET_KEY required + firewall key present when firewall enabled"
render "$TMP/trustgate-required-keys.yaml" \
  -f values-required.yaml \
  --set trustgate.enabled=true \
  --set neuraltrust-firewall.firewall.enabled=true
# The SERVER_SECRET_KEY env ref must not carry `optional: true` on the line that
# immediately follows the `key: SERVER_SECRET_KEY` reference.
if grep -A1 'key: SERVER_SECRET_KEY' "$TMP/trustgate-required-keys.yaml" | grep -qE 'optional: true'; then
  red "FAIL: SERVER_SECRET_KEY must be required (no optional: true) on TrustGate deployments"
  exit 1
fi
green "ok  - SERVER_SECRET_KEY is required (not optional) on TrustGate deployments"
assert_contains "$TMP/trustgate-required-keys.yaml" "NEURAL_TRUST_FIREWALL_SECRET_KEY:" "firewall API key auto-populated in trustgate-secrets when firewall enabled"

# Scenario 35: explicit v1 escape hatch renders no v2 workloads.
blue "scenario 35: explicit platformVersion=v1 keeps the legacy topology"
assert_not_contains "$TMP/default.yaml" "name: agentgateway-proxy"        "agentgateway not rendered under explicit v1"
assert_not_contains "$TMP/default.yaml" "name: trustguard-data-plane"     "trustguard not rendered under explicit v1"
assert_not_contains "$TMP/default.yaml" "name: trustlens-worker"          "trustlens not rendered under explicit v1"
assert_not_contains "$TMP/default.yaml" "name: dataagent"                 "dataagent not rendered under explicit v1"
assert_not_contains "$TMP/default.yaml" "name: datacore"                  "datacore not rendered under explicit v1"
assert_not_contains "$TMP/default.yaml" "name: clickstack-collector"      "clickstack omitted under explicit v1"
assert_not_contains "$TMP/default.yaml" "name: alertengine-api"           "alertengine not rendered under explicit v1"

# Scenario 36: v2 hybrid. The v2 data-plane workloads render on-prem
# (agentgateway proxy + mcp, trustguard data-plane). TrustLens is off by default.
# The control-planes (admin / control-plane) stay in SaaS => absent. In-cluster
# Postgres + Redis deploy by default; ClickHouse does NOT (analytics are SaaS-side)
# and the data-plane-api read shim is therefore off unless pointed at an external
# ClickHouse (see 36-ext). Kafka never renders, so kafka-workers/kafka-connect stay off.
blue "scenario 36: platformVersion=v2 hybrid renders data-plane workloads (no ClickHouse / no shim)"
render "$TMP/v2-hybrid.yaml" --set global.platformVersion=v2
assert_contains     "$TMP/v2-hybrid.yaml" "name: agentgateway-proxy"       "agentgateway proxy (data) rendered under v2 hybrid"
assert_contains     "$TMP/v2-hybrid.yaml" "name: agentgateway-mcp"         "agentgateway mcp (data) rendered under v2 hybrid"
assert_contains     "$TMP/v2-hybrid.yaml" "name: trustguard-data-plane"    "trustguard data-plane rendered under v2 hybrid"
assert_not_contains "$TMP/v2-hybrid.yaml" "name: trustlens-worker"         "trustlens off by default (disabled)"
assert_not_contains "$TMP/v2-hybrid.yaml" "name: agentgateway-admin"       "agentgateway admin (control) omitted in hybrid"
assert_not_contains "$TMP/v2-hybrid.yaml" "name: trustguard-control-plane" "trustguard control-plane omitted in hybrid"
assert_not_contains "$TMP/v2-hybrid.yaml" "name: trustlens-api"            "trustlens api (control) omitted in hybrid"
# DataAgent is credential-gated and therefore absent from the default hybrid render.
assert_not_contains "$TMP/v2-hybrid.yaml" "name: dataagent$"               "dataagent omitted without tenant/enrolment configuration"
assert_not_contains "$TMP/v2-hybrid.yaml" "name: datacore"                 "datacore omitted in hybrid (external-only)"
assert_not_contains "$TMP/v2-hybrid.yaml" "name: clickstack-collector"     "clickstack-otel-collector omitted in hybrid (external-only)"
assert_not_contains "$TMP/v2-hybrid.yaml" "name: alertengine-api"          "alertengine omitted in hybrid (external-only)"
assert_not_contains "$TMP/v2-hybrid.yaml" "name: alertengine-worker"       "alertengine worker omitted in hybrid (external-only)"
# Hybrid runs NO in-cluster ClickHouse. The data-plane-api read shim DOES render
# by default now, backed by PostgreSQL (SQL_DATABASE=postgres) reusing the umbrella
# PostgreSQL — so NO ClickHouse connection metadata/migrations render. An external
# ClickHouse backend stays opt-in (36-ext).
assert_contains     "$TMP/v2-hybrid.yaml" 'name: "data-plane-api"'         "data-plane-api shim renders in hybrid default (PostgreSQL-backed)"
assert_env_value    "$TMP/v2-hybrid.yaml" "SQL_DATABASE" "postgres"        "data-plane-api selects the PostgreSQL backend in hybrid default"
assert_contains     "$TMP/v2-hybrid.yaml" "name: postgres-migrations"      "data-plane-api PostgreSQL migration initContainer rendered in hybrid default"
assert_contains     "$TMP/v2-hybrid.yaml" "name: data-plane-postgres-init" "data-plane-api PostgreSQL schema ConfigMap rendered in hybrid default"
assert_contains     "$TMP/v2-hybrid.yaml" "SELECT pg_advisory_xact_lock"   "PostgreSQL migration serializes replicas with an advisory lock"
assert_not_contains "$TMP/v2-hybrid.yaml" "name: clickhouse-secrets"       "clickhouse-secrets omitted in hybrid PostgreSQL default"
assert_not_contains "$TMP/v2-hybrid.yaml" "name: clickhouse-init-job"      "clickhouse-init-job omitted in hybrid PostgreSQL default"
assert_not_contains "$TMP/v2-hybrid.yaml" "name: clickhouse-migrations"    "data-plane-api ClickHouse migration initContainer omitted in hybrid PostgreSQL default"
assert_not_contains "$TMP/v2-hybrid.yaml" "name: CLICKHOUSE_HOST"          "data-plane-api emits no CLICKHOUSE_* env in hybrid PostgreSQL default"
assert_not_contains "$TMP/v2-hybrid.yaml" "name: data-plane-worker"        "kafka-workers (data-plane-worker) omitted under v2 hybrid"
assert_not_contains "$TMP/v2-hybrid.yaml" "name: kafka-connect"            "kafka-connect omitted under v2 hybrid"
# In-cluster datastores: Postgres + Redis default ON in v2; ClickHouse does NOT
# deploy in hybrid (external-only / v1).
assert_contains     "$TMP/v2-hybrid.yaml" "name: control-plane-postgresql" "in-cluster Postgres deployed by default under v2 hybrid"
assert_contains     "$TMP/v2-hybrid.yaml" "name: v2-postgresql-init"       "v2 postgres-init Job rendered under v2 hybrid"
assert_contains     "$TMP/v2-hybrid.yaml" "name: redis"                    "in-cluster Redis deployed by default under v2 hybrid"
# Passwordless in-cluster Redis must disable protected-mode, otherwise it drops
# non-loopback clients (cross-pod services crash with "write: broken pipe").
assert_contains     "$TMP/v2-hybrid.yaml" "\-\-protected-mode"              "in-cluster Redis disables protected-mode for cross-pod clients"
assert_not_contains "$TMP/v2-hybrid.yaml" "name: clickhouse$"              "in-cluster ClickHouse NOT deployed under v2 hybrid (external-only)"
assert_not_contains "$TMP/v2-hybrid.yaml" "name: kafka-controller"         "Kafka omitted under v2 hybrid"
# Dynamic wiring: shared client credentials, derived URLs, shared trustdata DB.
assert_contains     "$TMP/v2-hybrid.yaml" "name: trustguard-client-credentials" "shared TrustGuard client-credentials Secret rendered under v2"
assert_contains     "$TMP/v2-hybrid.yaml" "CLIENT_ID: \"agentgateway-platform\"" "shared client id defaults to agentgateway-platform"
assert_contains     "$TMP/v2-hybrid.yaml" "name: TRUSTGUARD_CLIENT_SECRET"       "AgentGateway wires shared client secret via secretKeyRef"
assert_contains     "$TMP/v2-hybrid.yaml" "name: TRUSTGUARD_PLATFORM_CLIENT_SECRET" "TrustGuard wires shared client secret via secretKeyRef"
assert_contains     "$TMP/v2-hybrid.yaml" "TRUSTGUARD_BASE_URL: \"http://trustguard-data-plane\\." "AgentGateway TRUSTGUARD_BASE_URL auto-derives to in-cluster Service"
assert_contains     "$TMP/v2-hybrid.yaml" "DB_NAME: \"trustdata\""               "AgentGateway/TrustGuard default to shared trustdata DB in hybrid"
# Hybrid defaults to the shared-writer layout: AgentGateway and TrustGuard share ONE
# writer role + schema in trustdata, DataAgent is a separate read-only role.
assert_contains     "$TMP/v2-hybrid.yaml" "DB_USER: \"trustdata\""               "hybrid default: AG+TG connect as the shared writer role"
assert_contains     "$TMP/v2-hybrid.yaml" "name: trustdata-secrets"             "hybrid default: shared writer credential Secret rendered"
assert_contains     "$TMP/v2-hybrid.yaml" "ensure_role \"trustdata\""            "v2 postgres-init provisions the shared writer role (hybrid)"
assert_contains     "$TMP/v2-hybrid.yaml" "ensure_writer_schema \"trustdata\" \"trustdata\" \"trustdata\"" "v2 postgres-init gives the shared writer its schema in trustdata (hybrid)"
assert_contains     "$TMP/v2-hybrid.yaml" "CREATE SCHEMA IF NOT EXISTS"          "hybrid shared writer gets a writer-owned schema"
assert_contains     "$TMP/v2-hybrid.yaml" "grant_readonly \"trustdata\" \"dataagent\"" "v2 postgres-init grants the read-only dataagent role SELECT on the writer schema"
assert_contains     "$TMP/v2-hybrid.yaml" "search_path = .*trustdata.*, public"  "dataagent reader search_path targets the shared writer schema"
# Raw-telemetry wiring so DataAgent actually has data to read in hybrid.
assert_contains     "$TMP/v2-hybrid.yaml" "SENSIBLE_PG_DSN:"                     "hybrid data planes get a raw-telemetry Postgres DSN"
assert_contains     "$TMP/v2-hybrid.yaml" "name: agentgateway-telemetry"        "agentgateway raw-telemetry exporters ConfigMap rendered (hybrid)"
assert_contains     "$TMP/v2-hybrid.yaml" "name: trustguard-telemetry"          "trustguard raw-telemetry exporters ConfigMap rendered (hybrid)"
assert_contains     "$TMP/v2-hybrid.yaml" "TELEMETRY_EXPORTERS_FILE: \"/etc/telemetry/telemetry.yaml\"" "hybrid data planes point TELEMETRY_EXPORTERS_FILE at the mounted profile"
assert_contains     "$TMP/v2-hybrid.yaml" "TELEMETRY_ENABLED: \"true\""         "AgentGateway enables the configured hybrid telemetry pipeline"

# Scenario 36-ext: hybrid + EXTERNAL ClickHouse. Pointing the data-plane-api shim
# at a dotted (external) ClickHouse host resolves the backend to ClickHouse
# (backward-compat) WITHOUT deploying an in-cluster ClickHouse. The default bare
# host now resolves to PostgreSQL (36 above).
blue "scenario 36-ext: hybrid data-plane-api read shim resolves to ClickHouse via an external host"
render_default "$TMP/v2-hybrid-extch.yaml" \
  --set neuraltrust-data-plane.dataPlane.components.clickhouse.host=my-ch.example.com
assert_contains     "$TMP/v2-hybrid-extch.yaml" 'name: "data-plane-api"'    "data-plane-api shim renders in hybrid when pointed at an external ClickHouse"
assert_not_contains "$TMP/v2-hybrid-extch.yaml" "name: clickhouse$"         "external ClickHouse does not deploy the in-cluster ClickHouse in hybrid"
assert_contains     "$TMP/v2-hybrid-extch.yaml" "CLICKHOUSE_HOST: $(printf '%s' 'my-ch.example.com' | base64)" "hybrid shim uses the external ClickHouse host verbatim"
assert_contains     "$TMP/v2-hybrid-extch.yaml" "name: clickhouse-migrations" "external-ClickHouse hybrid keeps the ClickHouse migration initContainer"
assert_not_contains "$TMP/v2-hybrid-extch.yaml" "name: postgres-migrations"   "external-ClickHouse hybrid does not run the PostgreSQL migration"
assert_not_contains "$TMP/v2-hybrid-extch.yaml" "SQL_DATABASE"                "external-ClickHouse hybrid does not force SQL_DATABASE=postgres"

# Scenario 36-pg: hybrid data-plane-api PostgreSQL backend — explicit override,
# external connection, and migration toggle. Also verify credential precedence
# never inlines a plaintext password and that validation guards misconfiguration.
blue "scenario 36-pg: hybrid data-plane-api PostgreSQL backend, external connection, and validation"
# Explicit backend=postgres wins even when a dotted external ClickHouse host is set.
render_default "$TMP/v2-pg-explicit.yaml" \
  --set neuraltrust-data-plane.dataPlane.components.clickhouse.host=my-ch.example.com \
  --set neuraltrust-data-plane.dataPlane.components.api.database.backend=postgres
assert_env_value    "$TMP/v2-pg-explicit.yaml" "SQL_DATABASE" "postgres"    "explicit backend=postgres overrides a dotted ClickHouse host"
assert_contains     "$TMP/v2-pg-explicit.yaml" "name: postgres-migrations"  "explicit backend=postgres runs the PostgreSQL migration"
assert_not_contains "$TMP/v2-pg-explicit.yaml" "name: clickhouse-migrations" "explicit backend=postgres omits the ClickHouse migration"
# In-cluster default reuses postgresql-secrets; password only via secretKeyRef.
assert_contains     "$TMP/v2-hybrid.yaml" "name: \"postgresql-secrets\""    "data-plane-api sources POSTGRES_* from postgresql-secrets by default"
pg_pw_block="$(yq e 'select(.kind == "Deployment" and .metadata.name == "data-plane-api") | .spec.template.spec.containers[0].env[] | select(.name == "POSTGRES_PASSWORD")' "$TMP/v2-hybrid.yaml")"
if printf '%s' "$pg_pw_block" | grep -qE '^\s*value:'; then
  red "FAIL: data-plane-api POSTGRES_PASSWORD is inlined as a plaintext value"; exit 1
fi
if ! printf '%s' "$pg_pw_block" | grep -q 'secretKeyRef'; then
  red "FAIL: data-plane-api POSTGRES_PASSWORD is not a secretKeyRef"; exit 1
fi
green "ok  - data-plane-api POSTGRES_PASSWORD is always a secretKeyRef (never inlined)"
# External PostgreSQL: scalar host/port/user/database override; custom Secret for the password.
render_default "$TMP/v2-pg-external.yaml" \
  --set neuraltrust-data-plane.dataPlane.components.api.database.postgresql.host=pg.db.example.com \
  --set neuraltrust-data-plane.dataPlane.components.api.database.postgresql.port=6432 \
  --set neuraltrust-data-plane.dataPlane.components.api.database.postgresql.user=dpapi \
  --set neuraltrust-data-plane.dataPlane.components.api.database.postgresql.database=trustdata \
  --set neuraltrust-data-plane.dataPlane.components.api.database.postgresql.existingSecret.name=my-ext-pg
assert_env_value    "$TMP/v2-pg-external.yaml" "POSTGRES_HOST" "pg.db.example.com" "external PostgreSQL host wired from values"
assert_env_value    "$TMP/v2-pg-external.yaml" "POSTGRES_PORT" "6432"              "external PostgreSQL port wired from values"
assert_contains     "$TMP/v2-pg-external.yaml" "name: \"my-ext-pg\""               "external PostgreSQL password sourced from the configured Secret"
# Migration can be disabled without disabling the shim.
render_default "$TMP/v2-pg-nomig.yaml" \
  --set neuraltrust-data-plane.dataPlane.components.api.database.postgresql.migration.enabled=false
assert_contains     "$TMP/v2-pg-nomig.yaml" 'name: "data-plane-api"'        "data-plane-api still renders with migration disabled"
assert_not_contains "$TMP/v2-pg-nomig.yaml" "name: postgres-migrations"     "migration initContainer omitted when migration.enabled=false"
assert_not_contains "$TMP/v2-pg-nomig.yaml" "name: data-plane-postgres-init" "PostgreSQL schema ConfigMap omitted when migration.enabled=false"
# Validation: unknown backend and hybrid ClickHouse without an external host both fail.
assert_render_fails "unknown data-plane-api backend fails render" \
  --set neuraltrust-data-plane.dataPlane.components.api.database.backend=mysql
assert_render_fails "hybrid backend=clickhouse without an external host fails render" \
  --set neuraltrust-data-plane.dataPlane.components.api.database.backend=clickhouse
# The bundled PostgreSQL schema stays byte-identical to the data-plane-api source
# (canonical copy checked in under files/postgres). Assert its shape rendered into
# the ConfigMap.
assert_contains     "$TMP/v2-hybrid.yaml" "CREATE SCHEMA IF NOT EXISTS neuraltrust" "PostgreSQL init ConfigMap creates the neuraltrust schema"

render_default "$TMP/v2-upgrade-lookupless.yaml" --is-upgrade
assert_resource_state "$TMP/v2-upgrade-lookupless.yaml" "Secret" "agentgateway-secrets" "absent" "lookup-less upgrade does not rotate AgentGateway secrets"
assert_resource_state "$TMP/v2-upgrade-lookupless.yaml" "Secret" "trustguard-secrets" "absent" "lookup-less upgrade does not rotate TrustGuard secrets"
assert_resource_state "$TMP/v2-upgrade-lookupless.yaml" "Secret" "trustguard-client-credentials" "absent" "lookup-less upgrade does not rotate shared client credentials"

render_default "$TMP/v2-upgrade-preserved-secrets.yaml" \
  --is-upgrade \
  --set global.preserveExistingSecrets=true
assert_contains "$TMP/v2-upgrade-preserved-secrets.yaml" "name: v2-trustguard-client-secret" "lookup-less preserved upgrade keeps the prerelease client Secret reference"
assert_resource_state "$TMP/v2-upgrade-preserved-secrets.yaml" "Secret" "trustguard-client-credentials" "absent" "preserved upgrade does not duplicate externally managed client credentials"

render_default "$TMP/v2-install-preserved-secrets.yaml" \
  --set global.preserveExistingSecrets=true
assert_contains "$TMP/v2-install-preserved-secrets.yaml" "name: trustguard-client-credentials" "fresh externally managed install uses the canonical client Secret name"

render_default "$TMP/v2-managed-client-secret.yaml" \
  --set global.preserveExistingSecrets=true \
  --set global.v2.trustguardClientSecretName=trustguard-client-credentials
assert_contains "$TMP/v2-managed-client-secret.yaml" "name: trustguard-client-credentials" "externally managed client Secret name can use the canonical name"

render_default "$TMP/v2-upgrade-confirmed.yaml" \
  --is-upgrade \
  --set global.confirmV2Migration=true
assert_resource_state "$TMP/v2-upgrade-confirmed.yaml" "Secret" "agentgateway-secrets" "absent" "confirmation alone cannot rotate AgentGateway secrets without lookup"
assert_resource_state "$TMP/v2-upgrade-confirmed.yaml" "Secret" "trustguard-secrets" "absent" "confirmation alone cannot rotate TrustGuard secrets without lookup"
assert_resource_state "$TMP/v2-upgrade-confirmed.yaml" "Secret" "trustguard-client-credentials" "absent" "confirmation alone cannot rotate shared credentials without lookup"

blue "scenario 36b: DataAgent renders only with tenant + enrolment Secret reference"
render "$TMP/v2-hybrid-dataagent.yaml" \
  --set global.platformVersion=v2 \
  --set dataagent.tenantId=tenant-example \
  --set dataagent.enrolmentTokenExistingSecret.name=dataagent-enrolment \
  --set dataagent.enrolmentTokenExistingSecret.key=token
assert_contains "$TMP/v2-hybrid-dataagent.yaml" "name: dataagent$" "DataAgent resources render with complete enrolment configuration"
assert_contains "$TMP/v2-hybrid-dataagent.yaml" 'name: "dataagent-enrolment"' "DataAgent references the configured existing Secret"
assert_contains "$TMP/v2-hybrid-dataagent.yaml" "key: \"token\"" "DataAgent references the configured token key"
assert_contains "$TMP/v2-hybrid-dataagent.yaml" "/trustdata\\?sslmode=" "DataAgent DSN targets the shared trustdata DB"

render "$TMP/v2-hybrid-dataagent-partial.yaml" \
  --set global.platformVersion=v2 \
  --set dataagent.tenantId=tenant-example
assert_not_contains "$TMP/v2-hybrid-dataagent-partial.yaml" "name: dataagent$" "partial DataAgent configuration renders no resources"

assert_render_fails "DataAgent inline token fails closed when chart secret generation is disabled" \
  --set global.platformVersion=v2 \
  --set global.autoGenerateSecrets=false \
  --set dataagent.tenantId=tenant-example \
  --set dataagent.enrolmentToken=token-placeholder

assert_render_fails "DataAgent fails closed without its managed database Secret" \
  --set global.platformVersion=v2 \
  --set global.autoGenerateSecrets=false \
  --set dataagent.tenantId=tenant-example \
  --set dataagent.enrolmentTokenExistingSecret.name=dataagent-enrolment

render_default "$TMP/v2-hybrid-dataagent-managed-secrets.yaml" \
  --set global.autoGenerateSecrets=false \
  --set dataagent.tenantId=tenant-example \
  --set dataagent.enrolmentTokenExistingSecret.name=dataagent-enrolment \
  --set dataagent.existingSecret.name=dataagent-runtime
assert_contains "$TMP/v2-hybrid-dataagent-managed-secrets.yaml" 'name: "dataagent-runtime"' "DataAgent uses the configured managed database Secret"
assert_resource_state "$TMP/v2-hybrid-dataagent-managed-secrets.yaml" "Secret" "dataagent-secrets" "absent" "chart does not duplicate externally managed DataAgent credentials"

# Scenario 37: v2 full (DEPRECATED alias of external). Must render identically to
# external: control + data planes + self-hosted analytics + in-cluster datastores.
blue "scenario 37: platformVersion=v2 full renders identically to external"
render "$TMP/v2-full.yaml" \
  --set global.platformVersion=v2 \
  --set global.deploymentMode=full
assert_contains "$TMP/v2-full.yaml" "name: agentgateway-admin"       "agentgateway admin (control) rendered under v2 full"
assert_contains "$TMP/v2-full.yaml" "name: agentgateway-proxy"       "agentgateway proxy (data) still rendered under v2 full"
assert_contains "$TMP/v2-full.yaml" "name: trustguard-control-plane" "trustguard control-plane rendered under v2 full"
assert_contains "$TMP/v2-full.yaml" "name: trustguard-data-plane"    "trustguard data-plane still rendered under v2 full"
# Stable, release-independent resource names (no <release>- prefix).
assert_not_contains "$TMP/v2-full.yaml" "name: test-agentgateway"    "v2 resource names carry no release-name prefix (fullnameOverride)"
# gcr-secret default pull secret is wired on v2 workloads.
assert_contains "$TMP/v2-full.yaml" "name: gcr-secret"               "v2 workloads default to gcr-secret imagePullSecret"
# full == external: analytics present, DataAgent absent, TrustLens off by default.
assert_not_contains "$TMP/v2-full.yaml" "name: dataagent$"           "dataagent omitted in full (no SaaS bridge)"
assert_contains     "$TMP/v2-full.yaml" "name: datacore"             "datacore rendered in full (== external)"
assert_contains     "$TMP/v2-full.yaml" "name: clickstack-collector" "clickstack rendered in full (== external)"
assert_contains     "$TMP/v2-full.yaml" "name: alertengine-api"      "alertengine api rendered in full (== external)"
assert_contains     "$TMP/v2-full.yaml" "name: alertengine-worker"   "alertengine worker rendered in full (== external)"
assert_not_contains "$TMP/v2-full.yaml" "name: trustlens-api"        "trustlens off by default in full"

# Scenario 37b: v2 external. Control + data planes render (isExternal) PLUS the
# self-hosted analytics stack (clickstack-otel-collector + DataCore over local
# ClickHouse) + in-cluster Postgres/Redis/ClickHouse. DataAgent is not deployed.
blue "scenario 37b: platformVersion=v2 external renders control + data planes + self-hosted analytics"
render "$TMP/v2-external.yaml" \
  --set global.platformVersion=v2 \
  --set global.deploymentMode=external \
  --set global.domain=v2.example.com
assert_contains     "$TMP/v2-external.yaml" "name: agentgateway-admin"   "agentgateway admin (control) rendered under v2 external"
assert_contains     "$TMP/v2-external.yaml" "name: agentgateway-proxy"   "agentgateway proxy (data) rendered under v2 external"
assert_contains     "$TMP/v2-external.yaml" "name: trustguard-control-plane" "trustguard control-plane rendered under v2 external"
assert_contains     "$TMP/v2-external.yaml" "name: datacore"             "datacore rendered under v2 external"
assert_contains     "$TMP/v2-external.yaml" "name: clickstack-collector" "clickstack-otel-collector rendered under v2 external"
assert_contains     "$TMP/v2-external.yaml" "name: alertengine-api"      "alertengine api rendered under v2 external"
assert_contains     "$TMP/v2-external.yaml" "name: alertengine-worker"   "alertengine worker rendered under v2 external"
assert_not_contains "$TMP/v2-external.yaml" "name: dataagent$"           "dataagent omitted in external (no SaaS bridge)"
# data-plane-api shim renders in all v2 modes; kafka-workers stay off.
assert_contains     "$TMP/v2-external.yaml" 'name: "data-plane-api"'     "data-plane-api shim rendered under v2 external"
assert_not_contains "$TMP/v2-external.yaml" "name: data-plane-worker"    "kafka-workers (data-plane-worker) omitted under v2 external"
assert_not_contains "$TMP/v2-external.yaml" "name: kafka-connect"        "kafka-connect omitted under v2 external"
# In-cluster datastores: Postgres + Redis + ClickHouse all default ON in external.
assert_contains     "$TMP/v2-external.yaml" "name: control-plane-postgresql" "in-cluster Postgres deployed by default under v2 external"
assert_contains     "$TMP/v2-external.yaml" "name: v2-postgresql-init"       "v2 postgres-init Job rendered under v2 external"
assert_contains     "$TMP/v2-external.yaml" "name: redis"                    "in-cluster Redis deployed by default under v2 external"
assert_contains     "$TMP/v2-external.yaml" "name: clickhouse"               "in-cluster ClickHouse deployed by default under v2 external"
# Shared client credentials + external audience URL from global.domain.
assert_contains     "$TMP/v2-external.yaml" "name: trustguard-client-credentials" "shared TrustGuard client-credentials Secret rendered under v2 external"
assert_contains     "$TMP/v2-external.yaml" "TRUSTGUARD_BASE_URL: \"https://trustguard\\." "TrustGuard audience URL auto-derives from global.domain"
# External: each service owns its OWN database (control planes run on-prem and own
# their migrations); no shared trustdata DB and no DataAgent reader.
assert_contains     "$TMP/v2-external.yaml" "DB_NAME: \"agentgateway\""            "AgentGateway uses its own database in external"
assert_contains     "$TMP/v2-external.yaml" "DB_NAME: \"trustguard\""              "TrustGuard uses its own database in external"
assert_contains     "$TMP/v2-external.yaml" "ensure_owned_db \"agentgateway\" \"agentgateway\"" "v2 postgres-init provisions the private agentgateway DB under external"
assert_contains     "$TMP/v2-external.yaml" "ensure_owned_db \"trustguard\" \"trustguard\""     "v2 postgres-init provisions the private trustguard DB under external"
assert_not_contains "$TMP/v2-external.yaml" "ensure_writer_schema \"trustdata\""   "no shared trustdata schemas in external"
assert_not_contains "$TMP/v2-external.yaml" "grant_readonly \"trustdata\""         "no read-only dataagent reader in external"
# Raw telemetry stays out of Postgres in external. AgentGateway and TrustGuard
# instead mount mode-specific metadata/raw OTLP profiles targeting ClickStack.
assert_not_contains "$TMP/v2-external.yaml" "SENSIBLE_PG_DSN:"                    "no raw-telemetry Postgres DSN in external"
assert_contains     "$TMP/v2-external.yaml" "name: agentgateway-telemetry"       "AgentGateway external OTLP profile is rendered"
assert_contains     "$TMP/v2-external.yaml" "name: trustguard-telemetry"         "TrustGuard external OTLP profile is rendered"
assert_contains     "$TMP/v2-external.yaml" "name: metadata-otlp"                "external profiles export metadata over OTLP"
assert_contains     "$TMP/v2-external.yaml" "name: raw-otlp"                     "external profiles export raw events over OTLP"
assert_contains     "$TMP/v2-external.yaml" "OTEL_EXPORTER_OTLP_ENDPOINT: \"http://clickstack-collector\\." "v2 runtimes target the in-cluster ClickStack OTLP/HTTP endpoint"
assert_contains     "$TMP/v2-external.yaml" "TELEMETRY_EXPORTERS_FILE: \"/etc/telemetry/telemetry.yaml\"" "external runtimes load the mounted telemetry profiles"
assert_contains     "$TMP/v2-external.yaml" "OPENTELEMETRY_ENABLED: \"true\""     "TrustGuard runtime tracing targets ClickStack in external mode"
# TrustGuard control-plane config-sync gRPC listener needs TLS in a deployed APP_ENV
# (production default): the chart auto-generates + mounts a cert/key.
assert_contains     "$TMP/v2-external.yaml" "name: trustguard-configsync-tls"      "trustguard config-sync gRPC TLS secret auto-generated under v2 external"
assert_contains     "$TMP/v2-external.yaml" "CONFIG_SYNC_GRPC_TLS_CERT"            "trustguard control-plane gets config-sync gRPC TLS cert path"
assert_contains     "$TMP/v2-external.yaml" "CONFIG_SYNC_GRPC_TLS_KEY"             "trustguard control-plane gets config-sync gRPC TLS key path"

# Scenario 37e: TLS-only managed Redis. TrustGate (agentgateway) reads
# REDIS_TLS_ENABLED; TrustGuard reads REDIS_TLS — assert each emits the var its
# own binary honors so a TLS-only endpoint is not dialed in plaintext.
blue "scenario 37e: v2 external TLS-only Redis emits the per-binary TLS env var"
render "$TMP/v2-redis-tls.yaml" \
  --set global.platformVersion=v2 \
  --set global.deploymentMode=external \
  --set agentgateway.redis.host=cache.example.com \
  --set agentgateway.redis.tls=true \
  --set trustguard.redis.host=cache.example.com \
  --set trustguard.redis.tls=true
assert_contains     "$TMP/v2-redis-tls.yaml" "REDIS_TLS_ENABLED: \"true\""         "agentgateway (TrustGate) emits REDIS_TLS_ENABLED for TLS-only Redis"
assert_contains     "$TMP/v2-redis-tls.yaml" "REDIS_TLS: \"true\""                 "trustguard emits REDIS_TLS for TLS-only Redis"

# Scenario 37c: full is a deprecated alias of external → same rendered resources.
# Compare the set of kind/name pairs (auto-generated secret VALUES differ between
# any two renders, so a byte diff is not meaningful — the invariant is that the
# same resources render).
blue "scenario 37c: v2 full == external (deprecated alias equivalence)"
kind_names() { yq e '(.kind // "-") + "/" + (.metadata.name // "-")' "$1" 2>/dev/null | sort; }
if diff <(kind_names "$TMP/v2-full.yaml") <(kind_names "$TMP/v2-external.yaml") >/dev/null 2>&1; then
  green "ok  - v2 full renders the same resource set as v2 external"
else
  red "FAIL: v2 full renders a different resource set than v2 external"
  diff <(kind_names "$TMP/v2-full.yaml") <(kind_names "$TMP/v2-external.yaml") | head -20 | while IFS= read -r line; do red "  > $line"; done
  exit 1
fi

# Scenario 37d: TrustLens opt-in renders api + worker.
blue "scenario 37d: trustlens.enabled=true renders TrustLens"
assert_render_fails "TrustLens requires a manually pinned release image" \
  --set global.platformVersion=v2 \
  --set trustlens.enabled=true
render "$TMP/v2-trustlens.yaml" \
  --set global.platformVersion=v2 \
  --set global.deploymentMode=external \
  --set trustlens.enabled=true \
  --set trustlens.image.tag=v0.1.0
assert_contains "$TMP/v2-trustlens.yaml" "name: trustlens-api"    "trustlens api rendered when enabled=true"
assert_contains "$TMP/v2-trustlens.yaml" "name: trustlens-worker" "trustlens worker rendered when enabled=true"
assert_contains "$TMP/v2-trustlens.yaml" 'value: "http://trustlens-api"' "app receives TrustLens URL when enabled"
assert_contains "$TMP/v2-trustlens.yaml" "name: TRUSTLENS_JWT_SECRET" "app receives TrustLens JWT reference when enabled"

# Scenario 38: v2 disables the legacy stack (single global switch). Under v2 the
# Python control-plane API, trustgate, and kafka must not render; firewall stays
# available. The data-plane-api analytics shim is intentionally kept (temporary
# until TrustLens), but its kafka-workers (data-plane-worker) and kafka-connect
# stay disabled. In hybrid the shim needs an external ClickHouse to render, so one
# is set here (in-cluster ClickHouse does not deploy in hybrid).
blue "scenario 38: platformVersion=v2 disables the legacy stack (keeps data-plane-api shim)"
render "$TMP/v2-legacy-off.yaml" \
  --set global.platformVersion=v2 \
  --set trustgate.enabled=true \
  --set neuraltrust-control-plane.controlPlane.enabled=true \
  --set neuraltrust-data-plane.dataPlane.enabled=true \
  --set neuraltrust-data-plane.dataPlane.components.clickhouse.host=my-ch.example.com \
  --set infrastructure.kafka.deploy=true
assert_not_contains "$TMP/v2-legacy-off.yaml" "name: trustgate-data-plane"  "legacy trustgate disabled under v2"
assert_not_contains "$TMP/v2-legacy-off.yaml" "name: control-plane-api"     "legacy Python control-plane-api disabled under v2"
assert_not_contains "$TMP/v2-legacy-off.yaml" "name: control-plane-scheduler" "legacy control-plane scheduler disabled under v2"
assert_contains     "$TMP/v2-legacy-off.yaml" 'name: "data-plane-api"'      "data-plane-api shim kept under v2"
assert_not_contains "$TMP/v2-legacy-off.yaml" "name: data-plane-worker"     "kafka-workers (data-plane-worker) disabled under v2"
assert_not_contains "$TMP/v2-legacy-off.yaml" "name: kafka-connect"         "kafka-connect disabled under v2"
assert_not_contains "$TMP/v2-legacy-off.yaml" "name: kafka-controller"      "legacy kafka disabled under v2"

# Scenario 38b: legacy stack intact under v1 (backward-compat).
blue "scenario 38b: legacy stack intact under v1"
render "$TMP/v1-legacy-on.yaml" \
  --set global.platformVersion=v1 \
  --set trustgate.enabled=true \
  --set neuraltrust-control-plane.controlPlane.enabled=true \
  --set neuraltrust-data-plane.dataPlane.enabled=true
assert_contains "$TMP/v1-legacy-on.yaml" "name: trustgate-data-plane" "legacy trustgate present under v1"
assert_contains "$TMP/v1-legacy-on.yaml" "name: control-plane-api"    "legacy control-plane-api present under v1"
assert_contains "$TMP/v1-legacy-on.yaml" 'name: "data-plane-api"'     "legacy data-plane present under v1"

# Scenario 38c: the product control-plane (API + App UI) auto-enables on-prem in v2
# EXTERNAL (zero-SaaS) from the platform flags alone (NO controlPlane.enabled), but
# stays SaaS-side in v2 HYBRID even when controlPlane.enabled=true (v2 ignores it).
# The scheduler is a legacy component and stays OFF in all v2 modes.
blue "scenario 38c: control-plane API + App auto-enable in v2 external, not in v2 hybrid"
render "$TMP/v2-ext-cp.yaml" \
  --set global.platformVersion=v2 \
  --set global.deploymentMode=external
assert_contains     "$TMP/v2-ext-cp.yaml" "name: control-plane-api"       "control-plane-api auto-renders in v2 external (no controlPlane.enabled)"
assert_contains     "$TMP/v2-ext-cp.yaml" "name: control-plane-app"       "control-plane-app auto-renders in v2 external (no controlPlane.enabled)"
assert_not_contains "$TMP/v2-ext-cp.yaml" "name: control-plane-scheduler" "scheduler stays off in v2 external"

# Even with controlPlane.enabled=true, v2 hybrid keeps the console SaaS-side.
render "$TMP/v2-hyb-cp.yaml" \
  --set global.platformVersion=v2 \
  --set global.deploymentMode=hybrid \
  --set neuraltrust-control-plane.controlPlane.enabled=true
assert_not_contains "$TMP/v2-hyb-cp.yaml" "name: control-plane-api"       "control-plane-api stays SaaS-side in v2 hybrid (enabled ignored)"
assert_not_contains "$TMP/v2-hyb-cp.yaml" "name: control-plane-app"       "control-plane-app stays SaaS-side in v2 hybrid (enabled ignored)"

# Scenario 38c-url: APP_URL / NEXTAUTH_URL follow the real app Ingress host
# (app.<domain>), not the in-cluster control-plane-app name, so emailed magic
# links / NextAuth callbacks are correct. The v2 UI also receives its backend
# service env (agentgateway/trustguard/datacore/alertengine).
blue "scenario 38c-url: control-plane-app public URL + v2 backend env"
render "$TMP/v2-ext-cp-url.yaml" \
  --set global.platformVersion=v2 \
  --set global.deploymentMode=external \
  --set global.domain=example.com
assert_contains     "$TMP/v2-ext-cp-url.yaml" "value: \"https://app.example.com\"" "APP_URL/NEXTAUTH_URL use the app Ingress host (app.<domain>)"
assert_not_contains "$TMP/v2-ext-cp-url.yaml" "control-plane-app.example.com"      "app URLs never use the control-plane-app.<domain> host (non-OpenShift)"
assert_contains     "$TMP/v2-ext-cp-url.yaml" "name: AGENTGATEWAY_URL"             "AGENTGATEWAY_URL wired into the app under v2"
assert_contains     "$TMP/v2-ext-cp-url.yaml" "name: TRUSTGUARD_URL"               "TRUSTGUARD_URL wired into the app under v2"
assert_contains     "$TMP/v2-ext-cp-url.yaml" "name: DATACORE_URL"                 "DATACORE_URL wired into the app under v2"
assert_contains     "$TMP/v2-ext-cp-url.yaml" "name: ALERT_ENGINE_API_URL"        "ALERT_ENGINE_API_URL wired directly into the app under v2"
yq e 'select(.kind == "Deployment" and .metadata.name == "control-plane-app")' "$TMP/v2-ext-cp-url.yaml" > "$TMP/v2-app.yaml"
assert_contains     "$TMP/v2-app.yaml" 'value: "http://alertengine-api"'         "v2 app receives the in-cluster AlertEngine URL"
assert_contains     "$TMP/v2-app.yaml" "name: TRUSTLENS_API_URL"                "v2 app receives TrustLens URL through the standard env pattern"
assert_not_contains "$TMP/v2-ext-cp-url.yaml" "name: v2-app-backends"            "v2 app does not create a one-off backend URL ConfigMap"
assert_contains     "$TMP/v2-app.yaml" "name: AUTH_SECRET"                       "v2 app receives AUTH_SECRET"
assert_contains     "$TMP/v2-app.yaml" "name: NEXTAUTH_SECRET"                   "v2 app receives NEXTAUTH_SECRET alias"
assert_env_value    "$TMP/v2-app.yaml" "FORCE_V2_UI" "true"                      "v2 app forces the v2 UI by default (no v1 UI to preserve on self-hosted v2)"
assert_not_contains "$TMP/v2-app.yaml" "name: KAFKA_"                            "v2 app receives no Kafka env"
assert_not_contains "$TMP/v2-app.yaml" "name: TRUSTGATE_"                        "v2 app receives no legacy TrustGate env"
assert_not_contains "$TMP/v2-app.yaml" "name: POSTURE_"                          "v2 app receives no removed Posture env"

render_default "$TMP/v2-alertengine-disabled.yaml" \
  --set global.deploymentMode=external \
  --set alertengine.enabled=false
assert_resource_state "$TMP/v2-alertengine-disabled.yaml" "Deployment" "alertengine-api" "absent" "disabled AlertEngine omits its workload"
assert_contains "$TMP/v2-alertengine-disabled.yaml" "name: ALERT_ENGINE_API_URL" "app backend URLs keep the standard direct env contract"

render_default "$TMP/v2-alertengine-external-url.yaml" \
  --set global.deploymentMode=external \
  --set alertengine.enabled=false \
  --set neuraltrust-control-plane.controlPlane.components.app.config.alertEngineApiUrl=http://alerts.example.com
assert_contains "$TMP/v2-alertengine-external-url.yaml" 'value: "http://alerts.example.com"' "explicit external AlertEngine URL works without bundled subchart"
auth_secret="$(yq e 'select(.kind == "Secret" and .metadata.name == "control-plane-secrets") | .data.AUTH_SECRET' "$TMP/v2-ext-cp-url.yaml")"
nextauth_secret="$(yq e 'select(.kind == "Secret" and .metadata.name == "control-plane-secrets") | .data.NEXTAUTH_SECRET' "$TMP/v2-ext-cp-url.yaml")"
if [ -z "$auth_secret" ] || [ "$auth_secret" != "$nextauth_secret" ]; then
  red "FAIL: AUTH_SECRET and NEXTAUTH_SECRET must be identical"
  exit 1
fi
green "ok  - AUTH_SECRET and NEXTAUTH_SECRET share one resolved value"

# v1 keeps the corrected app URL but must NOT receive the v2 backend env.
render "$TMP/v1-cp-url.yaml" \
  --set global.platformVersion=v1 \
  --set neuraltrust-control-plane.controlPlane.enabled=true \
  --set global.domain=example.com
assert_contains     "$TMP/v1-cp-url.yaml" "value: \"https://app.example.com\"" "v1 APP_URL/NEXTAUTH_URL use the app Ingress host too"
assert_not_contains "$TMP/v1-cp-url.yaml" "name: AGENTGATEWAY_URL"             "v2 backend env absent under v1 (backward-compat)"
assert_not_contains "$TMP/v1-cp-url.yaml" "name: TRUSTGUARD_URL"               "v2 trustguard env absent under v1 (backward-compat)"
assert_not_contains "$TMP/v1-cp-url.yaml" "name: AUTH_SECRET"                  "v2 app auth env absent under v1 (backward-compat)"
assert_not_contains "$TMP/v1-cp-url.yaml" "name: FORCE_V2_UI"                  "FORCE_V2_UI absent under v1 (shared SaaS app keeps its default UI)"
assert_contains     "$TMP/v1-cp-url.yaml" "name: KAFKA_HOST"                   "explicit v1 app keeps Kafka env"
assert_contains     "$TMP/v1-cp-url.yaml" "name: TRUSTGATE_CONTROL_PLANE_URL"  "explicit v1 app keeps TrustGate env"

# Scenario 38d: shared ClickHouse secret. DataCore + AlertEngine read the password
# from the in-cluster `clickhouse` secret (key admin-password), not their own.
blue "scenario 38d: DataCore + AlertEngine source CLICKHOUSE_PASSWORD from the shared clickhouse secret"
assert_contains     "$TMP/v2-external.yaml" "name: clickhouse"           "in-cluster clickhouse secret present (shared source)"
assert_contains     "$TMP/v2-external.yaml" "key: admin-password"        "CLICKHOUSE_PASSWORD references the shared clickhouse secret key"
# datacore-secrets / alertengine-secrets must NOT carry their own CLICKHOUSE_PASSWORD.
dc_ae_secret_clickhouse="$(yq e 'select(.kind == "Secret" and (.metadata.name == "datacore-secrets" or .metadata.name == "alertengine-secrets")) | .stringData.CLICKHOUSE_PASSWORD // ""' "$TMP/v2-external.yaml" 2>/dev/null | tr -d '[:space:]')"
if [ -z "$dc_ae_secret_clickhouse" ]; then
  green "ok  - datacore/alertengine own secrets no longer carry CLICKHOUSE_PASSWORD"
else
  red "FAIL: datacore/alertengine secret still carries CLICKHOUSE_PASSWORD"
  exit 1
fi

# Scenario 38e: optional IAM DB/Redis auth for the v2 Go services (default OFF).
# When database.iamAuth=true the chart selects the binaries' POSTGRES_LOGIN=aws
# mode and ships no static DB_PASSWORD.
blue "scenario 38e: v2 service IAM DB/Redis auth emits IAM env and drops static passwords"
render "$TMP/v2-iam.yaml" \
  --set global.platformVersion=v2 \
  --set global.deploymentMode=external \
  --set global.domain=v2.example.com \
  --set agentgateway.database.iamAuth=true \
  --set agentgateway.redis.iamAuth=true \
  --set trustguard.database.iamAuth=true
assert_contains     "$TMP/v2-iam.yaml" "DB_IAM_AUTH: \"true\""   "agentgateway emits DB_IAM_AUTH when iamAuth=true"
assert_contains     "$TMP/v2-iam.yaml" "DB_AUTH_MODE: \"iam\""   "agentgateway emits DB_AUTH_MODE=iam when iamAuth=true"
assert_contains     "$TMP/v2-iam.yaml" "POSTGRES_LOGIN: \"aws\"" "AgentGateway and TrustGuard select their AWS IAM login mode"
assert_contains     "$TMP/v2-iam.yaml" "REDIS_IAM_AUTH: \"true\"" "agentgateway emits REDIS_IAM_AUTH when redis.iamAuth=true"
# Default (password) path still ships DB_PASSWORD.
assert_contains     "$TMP/v2-external.yaml" "DB_PASSWORD:"        "password mode still ships DB_PASSWORD (default)"
assert_contains     "$TMP/v2-external.yaml" "STS_SIGNING_KEY:"    "AgentGateway MCP receives a lookup-preserved STS signing key"
if yq eval 'select(.kind == "Secret" and .metadata.name == "agentgateway-secrets") | .stringData.STS_SIGNING_KEY' \
    "$TMP/v2-external.yaml" | openssl rsa -noout -check >/dev/null 2>&1; then
  green "ok  - AgentGateway MCP STS signing key is a valid RSA private key"
else
  red "FAIL: AgentGateway MCP STS signing key is not a valid private key"
  exit 1
fi
assert_render_fails "invalid explicit AgentGateway MCP STS signing key is rejected" \
  --set global.platformVersion=v2 \
  --set-string agentgateway.stsSigningKey=not-a-private-key
EC_STS_SIGNING_KEY=$(openssl ecparam -name prime256v1 -genkey 2>/dev/null | base64 | tr -d '\n\r')
assert_render_fails "EC key is rejected for AgentGateway's RS256 signer" \
  --set global.platformVersion=v2 \
  --set-string agentgateway.stsSigningKey="$EC_STS_SIGNING_KEY"
unset EC_STS_SIGNING_KEY
assert_contains     "$TMP/v2-external.yaml" "REDIS_EVENTS_SECRET:" "TrustGuard receives a stable Redis events secret"
assert_contains     "$TMP/v2-external.yaml" 'ENABLE_CACHE_PUBSUB: "true"' "TrustGuard cache pub/sub is enabled by default"

# Scenario 38f: Postgres sslMode defaults to "prefer" across the v2 Go services
# (works against both the non-TLS in-cluster PG and TLS hosted DBs). Operators set
# "require" per-deployment to force TLS.
blue "scenario 38f: v2 services default DB_SSL_MODE to \"prefer\""
assert_contains     "$TMP/v2-external.yaml" 'DB_SSL_MODE: "prefer"'   "agentgateway/trustguard/alertengine default DB_SSL_MODE=prefer"
assert_not_contains "$TMP/v2-external.yaml" 'DB_SSL_MODE: "require"'  "no service hardcodes DB_SSL_MODE=require by default"

# Scenario 38g: registry-auth opt-out. Nested controlPlane/dataPlane imagePullSecrets
# set to "none" must suppress the imagePullSecrets block (previously kept gcr-secret).
blue "scenario 38g: nested imagePullSecrets: none opts out of the pull-secret block"
render "$TMP/v2-nopull.yaml" \
  --set global.platformVersion=v2 \
  --set global.deploymentMode=external \
  --set global.domain=v2.example.com \
  --set neuraltrust-control-plane.controlPlane.imagePullSecrets=none \
  --set neuraltrust-data-plane.dataPlane.imagePullSecrets=none
cp_api_pull="$(yq e 'select(.kind == "Deployment" and .metadata.name == "control-plane-api") | .spec.template.spec.imagePullSecrets' "$TMP/v2-nopull.yaml" 2>/dev/null | tr -d '[:space:]')"
dp_api_pull="$(yq e 'select(.kind == "Deployment" and .metadata.name == "data-plane-api") | .spec.template.spec.imagePullSecrets' "$TMP/v2-nopull.yaml" 2>/dev/null | tr -d '[:space:]')"
if [ "$cp_api_pull" = "null" ] || [ -z "$cp_api_pull" ]; then
  green "ok  - control-plane-api drops imagePullSecrets when controlPlane.imagePullSecrets=none"
else
  red "FAIL: control-plane-api still sets imagePullSecrets ($cp_api_pull) with controlPlane.imagePullSecrets=none"
  exit 1
fi
if [ "$dp_api_pull" = "null" ] || [ -z "$dp_api_pull" ]; then
  green "ok  - data-plane-api drops imagePullSecrets when dataPlane.imagePullSecrets=none"
else
  red "FAIL: data-plane-api still sets imagePullSecrets ($dp_api_pull) with dataPlane.imagePullSecrets=none"
  exit 1
fi

# Scenario 38h: external ClickHouse. A dotted host is used verbatim (no
# .<ns>.svc.cluster.local suffix) and the data-plane-api ClickHouse password secret
# name is taken from dataPlane.components.clickhouse.existingSecret.
blue "scenario 38h: external ClickHouse host is verbatim and password secret name is honored"
render "$TMP/v2-extch.yaml" \
  --set global.platformVersion=v2 \
  --set global.deploymentMode=external \
  --set global.domain=v2.example.com \
  --set infrastructure.clickhouse.deploy=false \
  --set neuraltrust-data-plane.dataPlane.components.clickhouse.host=my-ch.example.com \
  --set neuraltrust-data-plane.dataPlane.components.clickhouse.existingSecret.name=my-ch-secret \
  --set neuraltrust-data-plane.dataPlane.components.clickhouse.existingSecret.key=password
expected_ch_host="$(printf '%s' 'my-ch.example.com' | base64)"
assert_contains     "$TMP/v2-extch.yaml" "CLICKHOUSE_HOST: $expected_ch_host" "external ClickHouse host rendered verbatim (no svc.cluster.local suffix)"
assert_contains     "$TMP/v2-extch.yaml" "name: \"my-ch-secret\""             "data-plane-api CLICKHOUSE_PASSWORD uses external existingSecret name"
assert_contains     "$TMP/v2-extch.yaml" "key: \"password\""                  "data-plane-api CLICKHOUSE_PASSWORD uses external existingSecret key"

# Scenario 38i: clickstack image mirror strips the AR prefix so an air-gapped
# registry gets <mirror>/clickstack-otel-collector, not <mirror>/europe-west1-docker.pkg.dev/...
blue "scenario 38i: clickstack-otel-collector image mirror strips the AR prefix"
render "$TMP/v2-mirror.yaml" \
  --set global.platformVersion=v2 \
  --set global.deploymentMode=external \
  --set global.domain=v2.example.com \
  --set global.imageRegistry=mirror.example.com/nt
assert_contains     "$TMP/v2-mirror.yaml" "image: \"mirror.example.com/nt/clickstack-otel-collector:" "clickstack image prepends mirror after stripping the AR registry"
assert_not_contains "$TMP/v2-mirror.yaml" "mirror.example.com/nt/europe-west1-docker.pkg.dev" "clickstack image does not double up the AR registry under a mirror"
assert_contains     "$TMP/v2-mirror.yaml" "image: \"mirror.example.com/nt/redis-stack-server:7.2.0-v20\"" "v2 Redis honors the global image mirror"
assert_contains     "$TMP/v2-mirror.yaml" "image: \"mirror.example.com/nt/postgres:17-alpine\"" "v2 PostgreSQL init honors the global image mirror"

# Scenario 38j: control-plane-secrets follows the control-plane workloads. In v2 it
# renders in external mode EVEN without controlPlane.enabled (the API + App
# auto-enable there), and stays absent in hybrid (console is SaaS-side). Override the
# values-required.yaml controlPlane.enabled=true to prove the v2 gating is mode-driven.
blue "scenario 38j: control-plane-secrets renders in v2 external without controlPlane.enabled, not in hybrid"
render "$TMP/v2-ext-cpsec.yaml" \
  --set global.platformVersion=v2 \
  --set global.deploymentMode=external \
  --set global.domain=v2.example.com \
  --set neuraltrust-control-plane.controlPlane.enabled=false
assert_contains     "$TMP/v2-ext-cpsec.yaml" "name: control-plane-secrets" "control-plane-secrets renders in v2 external without controlPlane.enabled"
render "$TMP/v2-hyb-cpsec.yaml" \
  --set global.platformVersion=v2 \
  --set global.deploymentMode=hybrid \
  --set neuraltrust-control-plane.controlPlane.enabled=false
assert_not_contains "$TMP/v2-hyb-cpsec.yaml" "name: control-plane-secrets" "control-plane-secrets absent in v2 hybrid (console SaaS-side)"

# Scenario 38k: TLS-only managed Redis. agentgateway/trustguard emit REDIS_USERNAME
# and REDIS_TLS only when set; the default render emits neither (backward-compat).
blue "scenario 38k: agentgateway/trustguard emit REDIS_USERNAME/REDIS_TLS only when set"
render "$TMP/v2-redis-tls.yaml" \
  --set global.platformVersion=v2 \
  --set global.deploymentMode=external \
  --set global.domain=v2.example.com \
  --set agentgateway.redis.username=cacheuser \
  --set agentgateway.redis.tls=true \
  --set trustguard.redis.username=cacheuser \
  --set trustguard.redis.tls=true
assert_contains     "$TMP/v2-redis-tls.yaml" "REDIS_USERNAME: \"cacheuser\"" "agentgateway/trustguard emit REDIS_USERNAME when set"
assert_contains     "$TMP/v2-redis-tls.yaml" "REDIS_TLS: \"true\""           "agentgateway/trustguard emit REDIS_TLS when set"
assert_not_contains "$TMP/v2-external.yaml"  "REDIS_USERNAME"                "no REDIS_USERNAME by default (backward-compat)"
assert_not_contains "$TMP/v2-external.yaml"  "REDIS_TLS"                     "no REDIS_TLS by default (backward-compat)"

# Scenario 38l: DataCore writes its tables into the built-in `default` ClickHouse DB
# (matches DataCore's SaaS/prod overlays), not a non-existent `datacore` DB.
blue "scenario 38l: DataCore CLICKHOUSE_DATABASE defaults to the built-in \"default\" DB"
assert_contains     "$TMP/v2-external.yaml" "CLICKHOUSE_DATABASE: \"default\""  "datacore CLICKHOUSE_DATABASE defaults to default (matches SaaS)"
assert_contains     "$TMP/v2-external.yaml" "CLICKHOUSE_OTEL_DATABASE: \"otel\"" "datacore reads the canonical OTel database"
assert_not_contains "$TMP/v2-external.yaml" "CLICKHOUSE_DATABASE: \"datacore\"" "datacore no longer points at a non-existent datacore DB"

# Scenario 38m: the ClickStack collector's metrics/promql pipeline is neutralized
# with an inert nop receiver/exporter (so it boots without a Prometheus backend),
# and HYPERDX_LOG_LEVEL is set from values.
blue "scenario 38m: clickstack metrics/promql pipeline is inert (nop) + HYPERDX_LOG_LEVEL set"
assert_contains     "$TMP/v2-external.yaml" 'receivers: \[nop\]' "clickstack metrics/promql pipeline uses the inert nop receiver"
assert_contains     "$TMP/v2-external.yaml" "HYPERDX_LOG_LEVEL"  "clickstack collector sets HYPERDX_LOG_LEVEL"

# Scenario 38n: the optional legacy backup path has complete image and storage
# defaults, so enabling it does not require defining a storage map just to render.
blue "scenario 38n: ClickHouse backup renders with safe image/storage defaults"
render "$TMP/v1-backup.yaml" \
  --set global.platformVersion=v1 \
  --set neuraltrust-data-plane.dataPlane.components.clickhouse.backup.enabled=true
assert_contains "$TMP/v1-backup.yaml" "name: clickhouse-backup" "ClickHouse backup CronJob renders when enabled"
assert_contains "$TMP/v1-backup.yaml" "image: \"europe-west1-docker.pkg.dev/neuraltrust-app-prod/nt-docker/curl:8.20.0\"" "ClickHouse backup uses the tracked curl image"

# Scenario 38o: data-plane-api's evaluation-progress cache backend is mode-derived
# (v1 keeps the existing Kafka backend; v2 uses the shared Redis) unless a
# consumer explicitly overrides it, and the REDIS_URL (with any ACL/IAM auth)
# only ever lives in the Secret, never the plaintext env ConfigMap.
blue "scenario 38o: data-plane-api evaluation-progress cache defaults to Kafka (v1) / Redis (v2)"
render "$TMP/v1-dp-redis.yaml" \
  --set global.platformVersion=v1 \
  --set global.kafka.tls.enabled=true \
  --set global.kafka.tls.existingSecret=kafka-broker-ca
yq e 'select(.kind == "Deployment" and .metadata.name == "data-plane-api")' "$TMP/v1-dp-redis.yaml" > "$TMP/v1-dp-api.yaml"
assert_env_value "$TMP/v1-dp-api.yaml" "EVALUATION_PROGRESS_BACKEND" "kafka" "data-plane-api defaults to the Kafka backend under v1"
assert_env_value "$TMP/v1-dp-api.yaml" "KAFKA_BOOTSTRAP_SERVERS" "kafka:9092" "data-plane-api keeps its Kafka client configuration under v1"
v1_api_kafka_mount="$(yq e '.spec.template.spec.containers[] | select(.name == "api") | .volumeMounts[] | select(.name == "kafka-broker-ca") | .name' "$TMP/v1-dp-api.yaml")"
v1_init_kafka_mount="$(yq e '.spec.template.spec.initContainers[] | select(.name == "clickhouse-migrations") | .volumeMounts[] | select(.name == "kafka-broker-ca") | .name' "$TMP/v1-dp-api.yaml")"
v1_kafka_volume="$(yq e '.spec.template.spec.volumes[] | select(.name == "kafka-broker-ca") | .name' "$TMP/v1-dp-api.yaml")"
if [[ "$v1_api_kafka_mount" == "kafka-broker-ca" && "$v1_init_kafka_mount" == "kafka-broker-ca" && "$v1_kafka_volume" == "kafka-broker-ca" ]]; then
  green "ok  - Kafka-backed v1 data-plane-api keeps Kafka TLS mounts and volume"
else
  red "FAIL: Kafka-backed v1 data-plane-api is missing a Kafka TLS mount or volume"
  exit 1
fi
assert_not_contains "$TMP/v1-dp-redis.yaml" "REDIS_URL" "data-plane-api does not reference REDIS_URL under v1 (no new Redis dependency)"
# The Redis evaluation-progress cache is independent of the SQL backend; pin a
# dotted external ClickHouse host so this case exercises the ClickHouse-backed shim.
render_default "$TMP/v2-dp-redis.yaml" \
  --set neuraltrust-data-plane.dataPlane.components.clickhouse.host=my-ch.example.com
yq e 'select(.kind == "Deployment" and .metadata.name == "data-plane-api")' "$TMP/v2-dp-redis.yaml" > "$TMP/v2-dp-api.yaml"
assert_env_value "$TMP/v2-dp-api.yaml" "EVALUATION_PROGRESS_BACKEND" "redis" "data-plane-api defaults to the Redis backend under v2"
assert_not_contains "$TMP/v2-dp-api.yaml" "name: KAFKA_BOOTSTRAP_SERVERS" "v2 data-plane-api omits Kafka client configuration when Redis owns evaluation progress"
assert_contains "$TMP/v2-dp-redis.yaml" "key: REDIS_URL" "data-plane-api reads REDIS_URL from the data-plane Secret under v2"
assert_contains "$TMP/v2-dp-redis.yaml" "REDIS_URL: cmVkaXM6Ly9yZWRpczo2Mzc5LzA=" "v2 REDIS_URL defaults to the in-cluster shared Redis (redis://redis:6379/0)"
assert_env_value "$TMP/v2-dp-api.yaml" "REDIS_MAX_CONNECTIONS" "100" "v2 data-plane-api defaults the Redis connection pool to 100"
assert_env_value "$TMP/v2-dp-api.yaml" "REDIS_MGET_CHUNK_SIZE" "200" "v2 data-plane-api defaults Redis MGET batches to 200 keys"
assert_not_contains "$TMP/v2-dp-api.yaml" "name: REDIS_CONNECT_TIMEOUT_SECONDS" "Redis connect timeout stays on the application default when unset"
assert_not_contains "$TMP/v2-dp-api.yaml" "name: REDIS_SOCKET_TIMEOUT_SECONDS" "Redis socket timeout stays on the application default when unset"
assert_not_contains "$TMP/v2-dp-api.yaml" "name: REDIS_HEALTH_CHECK_INTERVAL_SECONDS" "Redis health-check interval stays on the application default when unset"
redis_url_optional="$(yq e '.spec.template.spec.containers[] | select(.name == "api") | .env[] | select(.name == "REDIS_URL") | .valueFrom.secretKeyRef.optional' "$TMP/v2-dp-api.yaml")"
if [[ "$redis_url_optional" == "null" ]]; then
  green "ok  - REDIS_URL is required when data-plane-api selects the Redis backend"
else
  red "FAIL: REDIS_URL secretKeyRef remains optional in Redis mode"
  exit 1
fi
assert_render_fails "unknown data-plane-api evaluation-progress backend fails render" \
  --set neuraltrust-data-plane.dataPlane.components.api.redis.backend=memory
render_default "$TMP/v2-dp-redis-kafka-tls.yaml" \
  --set neuraltrust-data-plane.dataPlane.components.clickhouse.host=my-ch.example.com \
  --set global.kafka.tls.enabled=true \
  --set global.kafka.tls.existingSecret=kafka-broker-ca
yq e 'select(.kind == "Deployment" and .metadata.name == "data-plane-api")' "$TMP/v2-dp-redis-kafka-tls.yaml" > "$TMP/v2-dp-api-kafka-tls.yaml"
assert_not_contains "$TMP/v2-dp-api-kafka-tls.yaml" "kafka-broker-ca" "Redis-backed v2 data-plane-api omits Kafka TLS mounts and volumes"
render_default "$TMP/v2-dp-redis-tuning.yaml" \
  --set neuraltrust-data-plane.dataPlane.components.clickhouse.host=my-ch.example.com \
  --set neuraltrust-data-plane.dataPlane.components.api.redis.maxConnections=150 \
  --set neuraltrust-data-plane.dataPlane.components.api.redis.mgetChunkSize=250 \
  --set neuraltrust-data-plane.dataPlane.components.api.redis.connectTimeoutSeconds=6 \
  --set neuraltrust-data-plane.dataPlane.components.api.redis.socketTimeoutSeconds=7 \
  --set neuraltrust-data-plane.dataPlane.components.api.redis.healthCheckIntervalSeconds=45
assert_env_value "$TMP/v2-dp-redis-tuning.yaml" "REDIS_MAX_CONNECTIONS" "150" "Redis connection-pool override is wired"
assert_env_value "$TMP/v2-dp-redis-tuning.yaml" "REDIS_MGET_CHUNK_SIZE" "250" "Redis MGET chunk-size override is wired"
assert_env_value "$TMP/v2-dp-redis-tuning.yaml" "REDIS_CONNECT_TIMEOUT_SECONDS" "6" "Redis connect-timeout override is wired"
assert_env_value "$TMP/v2-dp-redis-tuning.yaml" "REDIS_SOCKET_TIMEOUT_SECONDS" "7" "Redis socket-timeout override is wired"
assert_env_value "$TMP/v2-dp-redis-tuning.yaml" "REDIS_HEALTH_CHECK_INTERVAL_SECONDS" "45" "Redis health-check interval override is wired"
render_default "$TMP/v2-dp-redis-acl.yaml" \
  --set neuraltrust-data-plane.dataPlane.components.clickhouse.host=my-ch.example.com \
  --set neuraltrust-data-plane.dataPlane.components.api.redis.host=my-redis.example.com \
  --set neuraltrust-data-plane.dataPlane.components.api.redis.username=nt-acl \
  --set neuraltrust-data-plane.dataPlane.components.api.redis.password=s3cr3t
assert_contains "$TMP/v2-dp-redis-acl.yaml" "REDIS_URL: cmVkaXM6Ly9udC1hY2w6czNjcjN0QG15LXJlZGlzLmV4YW1wbGUuY29tOjYzNzkvMA==" "data-plane-api ACL username/password are embedded in REDIS_URL (redis-py honors it)"
render_default "$TMP/v2-dp-redis-iam.yaml" \
  --set neuraltrust-data-plane.dataPlane.components.clickhouse.host=my-ch.example.com \
  --set neuraltrust-data-plane.dataPlane.components.api.redis.host=my-cache.abc.cache.amazonaws.com \
  --set neuraltrust-data-plane.dataPlane.components.api.redis.iamAuth=true \
  --set neuraltrust-data-plane.dataPlane.components.api.redis.iamUser=nt-user \
  --set neuraltrust-data-plane.dataPlane.components.api.redis.iamCacheName=nt-cache
assert_contains "$TMP/v2-dp-redis-iam.yaml" "REDIS_URL: cmVkaXNzOi8vbXktY2FjaGUuYWJjLmNhY2hlLmFtYXpvbmF3cy5jb206NjM3OS8w" "IAM-mode REDIS_URL uses rediss:// and carries no inline credentials"
assert_env_value "$TMP/v2-dp-redis-iam.yaml" "REDIS_AUTH_MODE" "aws_iam" "data-plane-api IAM mode emits REDIS_AUTH_MODE=aws_iam"
assert_env_value "$TMP/v2-dp-redis-iam.yaml" "REDIS_IAM_USER" "nt-user" "data-plane-api IAM mode emits REDIS_IAM_USER"

# Scenario 38p: hybrid ClickStack OTLP export is opt-in (global.clickstack) and
# DUAL-writes — the Postgres raw path (for DataAgent) stays, and the OTLP
# meta/raw exporters + endpoint are added for AgentGateway and TrustGuard. The
# bearer token only ever lives in the data-plane Secret, never the env ConfigMap.
blue "scenario 38p: hybrid ClickStack OTLP export is opt-in and dual-writes"
render_default "$TMP/v2-hybrid-noclickstack.yaml"
assert_not_contains "$TMP/v2-hybrid-noclickstack.yaml" "name: raw-otlp" "hybrid default keeps product data on the Postgres raw path (no OTLP raw exporter)"
assert_not_contains "$TMP/v2-hybrid-noclickstack.yaml" "name: metadata-otlp" "hybrid default emits no OTLP metadata exporter"
assert_not_contains "$TMP/v2-hybrid-noclickstack.yaml" "OTEL_EXPORTER_OTLP_HEADERS" "hybrid default ships no ClickStack OTLP auth header"
render_default "$TMP/v2-hybrid-clickstack.yaml" \
  --set global.clickstack.enabled=true \
  --set global.clickstack.endpoint=https://clickstack-collector.example.com/v1/logs \
  --set global.clickstack.authToken=cs-token-123
assert_contains "$TMP/v2-hybrid-clickstack.yaml" "name: sensible-pg" "ClickStack export keeps the Postgres raw path (dual-write)"
assert_contains "$TMP/v2-hybrid-clickstack.yaml" "name: metadata-otlp" "ClickStack export adds the OTLP metadata exporter"
assert_contains "$TMP/v2-hybrid-clickstack.yaml" "name: raw-otlp" "ClickStack export adds the OTLP raw exporter"
assert_contains "$TMP/v2-hybrid-clickstack.yaml" "OTEL_EXPORTER_OTLP_ENDPOINT: .https://clickstack-collector.example.com/v1/logs." "ClickStack export sets the OTLP endpoint on the data planes"
assert_contains "$TMP/v2-hybrid-clickstack.yaml" "OTEL_EXPORTER_OTLP_HEADERS: .authorization=cs-token-123." "ClickStack export ships the bearer token via the data-plane Secret"
assert_render_fails "ClickStack export requires an endpoint when enabled" \
  --set global.clickstack.enabled=true

# Scenario 40a: hybrid PostgreSQL init defaults to the SHARED-WRITER layout (mode-
# derived, no configuration). AgentGateway and TrustGuard collapse onto ONE writer
# role + schema (trustdata), the credential is generated once in trustdata-secrets,
# and DataAgent stays a separate read-only role.
blue "scenario 40a: default hybrid layout is shared-writer (one writer, one reader)"
render_default "$TMP/v2-pg-shared-local.yaml"
assert_contains     "$TMP/v2-pg-shared-local.yaml" 'DB_USER: "trustdata"'                "shared-writer default: AgentGateway and TrustGuard both connect as the shared writer role"
assert_not_contains "$TMP/v2-pg-shared-local.yaml" 'DB_USER: "agentgateway"'             "shared-writer default: AgentGateway drops its per-service role"
assert_not_contains "$TMP/v2-pg-shared-local.yaml" 'DB_USER: "trustguard"'               "shared-writer default: TrustGuard drops its per-service role"
assert_contains     "$TMP/v2-pg-shared-local.yaml" "name: trustdata-secrets"             "shared-writer default: the shared writer Secret is generated"
assert_contains     "$TMP/v2-pg-shared-local.yaml" 'ensure_role "trustdata"'             "shared-writer default: the shared writer role is provisioned locally"
assert_contains     "$TMP/v2-pg-shared-local.yaml" 'ensure_writer_schema "trustdata" "trustdata" "trustdata"' "shared-writer default: one writer-owned schema"
assert_contains     "$TMP/v2-pg-shared-local.yaml" 'ensure_role "dataagent"'             "shared-writer default: DataAgent stays a separate role"
assert_contains     "$TMP/v2-pg-shared-local.yaml" 'grant_readonly "trustdata" "dataagent" "trustdata" "trustdata"' "shared-writer default: DataAgent gets read-only SELECT on the writer schema"
assert_contains     "$TMP/v2-pg-shared-local.yaml" 'MANAGED=""'                          "shared-writer local: init Job runs in local (provisioning) mode"

# Scenario 40b: the escape hatch. hybridRoleLayout=separate forces the legacy
# per-service layout in hybrid — AgentGateway and TrustGuard each own a role +
# schema, DataAgent reads both, and no shared writer identity exists.
blue "scenario 40b: hybridRoleLayout=separate forces the legacy per-service layout"
render_default "$TMP/v2-pg-separate.yaml" \
  --set global.postgresql.hybridRoleLayout=separate
assert_contains     "$TMP/v2-pg-separate.yaml" 'DB_USER: "agentgateway"'                 "separate: AgentGateway keeps its own DB role"
assert_contains     "$TMP/v2-pg-separate.yaml" 'DB_USER: "trustguard"'                   "separate: TrustGuard keeps its own DB role"
assert_contains     "$TMP/v2-pg-separate.yaml" 'ensure_writer_schema "trustdata" "agentgateway" "agentgateway"' "separate: AgentGateway gets its own schema"
assert_contains     "$TMP/v2-pg-separate.yaml" 'ensure_writer_schema "trustdata" "trustguard" "trustguard"'     "separate: TrustGuard gets its own schema"
assert_not_contains "$TMP/v2-pg-separate.yaml" "name: trustdata-secrets"                 "separate: no shared writer Secret is generated"
assert_not_contains "$TMP/v2-pg-separate.yaml" 'ensure_role "trustdata"'                 "separate: no shared writer role is provisioned"

# Scenario 40c: managed configure-only. With external PostgreSQL (deploy=false) and
# initJob.mode=enabled the Job still renders but runs configure-only (MANAGED=1):
# it validates DBA-created roles/db and only sets schemas/search_path/grants.
blue "scenario 40c: managed initJob.mode=enabled renders configure-only Job"
render_default "$TMP/v2-pg-managed.yaml" \
  --set global.postgresql.deploy=false \
  --set global.postgresql.initJob.mode=enabled
assert_contains "$TMP/v2-pg-managed.yaml" "name: v2-postgresql-init"  "managed enabled: the init Job renders against external PostgreSQL"
assert_contains "$TMP/v2-pg-managed.yaml" 'MANAGED="1"'               "managed enabled: the Job runs in configure-only mode"

# Scenario 40d: DBA-controlled managed PostgreSQL. initJob.mode=disabled omits the
# Job entirely so the DBA owns schema/search_path/grants.
blue "scenario 40d: initJob.mode=disabled omits the init Job"
render_default "$TMP/v2-pg-nojob.yaml" \
  --set global.postgresql.deploy=false \
  --set global.postgresql.initJob.mode=disabled
assert_not_contains "$TMP/v2-pg-nojob.yaml" "name: v2-postgresql-init" "disabled: the init Job is not rendered"

# Scenario 40e: shared-writer is hybrid-only. It must be rejected in external/full
# where control planes own per-service databases + migrations.
blue "scenario 40e: shared-writer is rejected outside hybrid"
assert_render_fails "shared-writer layout is rejected in external mode" \
  --set global.platformVersion=v2 \
  --set global.deploymentMode=external \
  --set global.postgresql.hybridRoleLayout=shared-writer

# Scenario 40f: single source of truth for the shared credential. The generated
# trustdata-secrets is consumed by the AgentGateway + TrustGuard Deployments AND the
# init Job (3 references) so all three agree on the shared writer password/DSN.
blue "scenario 40f: shared writer credential is consumed identically by AG, TG, and the Job"
count=$(grep -c 'name: trustdata-secrets' "$TMP/v2-pg-shared-local.yaml")
if [[ "$count" -lt 3 ]]; then
  red "FAIL: expected trustdata-secrets referenced by AG + TG deployments and the init Job (>=3), got $count"
  exit 1
fi
green "ok  - shared writer credential is referenced by AG, TG, and the init Job ($count references)"

blue "scenario 39: invalid topology and retired components fail rendering"
assert_render_fails "unknown platform generation is rejected" \
  --set global.platformVersion=v3
assert_render_fails "unknown v2 deployment mode is rejected" \
  --set global.platformVersion=v2 \
  --set global.deploymentMode=isolated
render "$TMP/v1-ignored-mode.yaml" \
  --set global.platformVersion=v1 \
  --set global.deploymentMode=isolated
assert_contains "$TMP/v1-ignored-mode.yaml" "name: trustgate-control-plane" "deploymentMode remains ignored under explicit v1"
assert_render_fails "explicitly enabling retired AISPM is rejected" \
  --set neuraltrust-aispm.aispm.enabled=true
assert_render_fails "explicitly enabling retired SIEM Connectors is rejected" \
  --set neuraltrust-siem-connectors.siemConnectors.enabled=true

green ""
green "All helm-render assertions passed."
