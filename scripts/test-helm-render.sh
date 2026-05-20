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
  helm template test "$CHART_DIR" -f "$CHART_DIR/values-required.yaml" "$@" > "$out"
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

# Scenario 1: defaults. Observability is ON by default but no token is
# set, so the otlphttp/neuraltrust exporter MUST be omitted and the
# chart MUST still install.
blue "scenario 1: defaults (observability on, no token)"
render "$TMP/default.yaml"
assert_contains     "$TMP/default.yaml" "test-neuraltrust-platform-otel-collector-config" "otel collector ConfigMap is rendered"
assert_not_contains "$TMP/default.yaml" "otlphttp/neuraltrust:"                            "hosted exporter is omitted when no token"
assert_contains     "$TMP/default.yaml" "nop: \\{\\}"                                       "nop fallback exporter is present"
assert_contains     "$TMP/default.yaml" "attributes/redact"                                 "privacy-redact processor is present"
assert_contains     "$TMP/default.yaml" "- key: prompt_text"                                "prompt_text redaction rule is present"

# Scenario 2: explicit token. Hosted exporter should appear, secret
# should be created, env var should be wired into the Deployment.
blue "scenario 2: explicit token configured"
render "$TMP/withtoken.yaml" --set global.observability.hostedExport.auth.tokenValue=secrettoken123
assert_contains     "$TMP/withtoken.yaml" "otlphttp/neuraltrust:"                                  "hosted exporter is rendered when token set"
assert_contains     "$TMP/withtoken.yaml" "Bearer \\\$\\{env:NT_OBSERVABILITY_TOKEN\\}"           "exporter uses NT_OBSERVABILITY_TOKEN env"
assert_contains     "$TMP/withtoken.yaml" "name: neuraltrust-observability-token"                  "token Secret is created"
assert_contains     "$TMP/withtoken.yaml" "name: NT_OBSERVABILITY_TOKEN"                           "Deployment env wires NT_OBSERVABILITY_TOKEN"
assert_contains     "$TMP/withtoken.yaml" "attributes/redact"                                      "privacy-redact processor still present with token"

# Scenario 3: master switch off. No otel-collector resources at all.
blue "scenario 3: observability disabled"
render "$TMP/off.yaml" --set global.observability.enabled=false
assert_not_contains "$TMP/off.yaml" "otel-collector"                                          "no otel-collector resources when disabled"

# Scenario 4: watchdog subchart enabled. Deployment + ConfigMap render.
blue "scenario 4: watchdog enabled"
render "$TMP/watchdog.yaml" --set neuraltrust-watchdog.enabled=true
# Multi-line check: confirm the watchdog Deployment exists by searching
# for both its kind line and its full name. (BSD grep has no portable
# multi-line, so we just look for both markers.)
assert_contains     "$TMP/watchdog.yaml" "name: test-neuraltrust-watchdog$" "watchdog resource (named test-neuraltrust-watchdog) is rendered"
assert_contains     "$TMP/watchdog.yaml" "test-neuraltrust-watchdog-config" "watchdog ConfigMap is rendered"

# Scenario 5: hosted explicitly disabled (local-only collector). Hosted
# exporter omitted; collector still runs.
blue "scenario 5: hosted export explicitly disabled"
render "$TMP/local.yaml" --set global.observability.hostedExport.enabled=false
assert_contains     "$TMP/local.yaml" "test-neuraltrust-platform-otel-collector-config" "collector still runs locally"
assert_not_contains "$TMP/local.yaml" "otlphttp/neuraltrust:"                            "hosted exporter omitted when hostedExport.enabled=false"
assert_contains     "$TMP/local.yaml" "nop: \\{\\}"                                       "nop fallback present in local-only mode"

# Scenario 6: components flip to in-chart collector when global override set.
# This guarantees the umbrella-wide endpoint takes precedence and that
# legacy default DNS in the subchart values doesn't leak through.
blue "scenario 6: global.observability.collector.endpoint flips component endpoints"
render "$TMP/inchart.yaml" \
  --set firewall.enabled=true \
  --set trustgate.enabled=true \
  --set neuraltrust-aispm.aispm.enabled=true \
  --set global.observability.collector.endpoint=http://test-otel-collector.default.svc.cluster.local:4318
assert_contains     "$TMP/inchart.yaml" "OTEL_EXPORTER_OTLP_ENDPOINT: \"http://test-otel-collector" "firewall picks up global collector endpoint"
assert_contains     "$TMP/inchart.yaml" "OTEL_EXPORTER_ENDPOINT: \"http://test-otel-collector"      "aispm picks up global collector endpoint"
assert_contains     "$TMP/inchart.yaml" "OPENTELEMETRY_TRACES_ENDPOINT: \"http://test-otel-collector"  "trustgate writes OPENTELEMETRY_TRACES_ENDPOINT (read by TrustGate-EE)"
assert_contains     "$TMP/inchart.yaml" "OPENTELEMETRY_METRICS_ENDPOINT: \"http://test-otel-collector" "trustgate writes OPENTELEMETRY_METRICS_ENDPOINT (read by TrustGate-EE)"
assert_contains     "$TMP/inchart.yaml" "OPENTELEMETRY_ENABLED: \"true\""                            "trustgate auto-enables OTLP when global endpoint set"
assert_not_contains "$TMP/inchart.yaml" "OPENTELEMETRY_ENDPOINT:"                                    "legacy OPENTELEMETRY_ENDPOINT key fully removed"
assert_not_contains "$TMP/inchart.yaml" "OPENTELEMETRY_OTLP_ENDPOINT:"                               "legacy OPENTELEMETRY_OTLP_ENDPOINT key fully removed"
assert_not_contains "$TMP/inchart.yaml" "OTEL_EXPORTER_OTLP_ENDPOINT: \"http://opentelemetry-collector.opentelemetry" "firewall no longer points at legacy default"

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
assert_contains "$TMP/mon-on.yaml" "name: test-neuraltrust-watchdog-rules"         "watchdog PrometheusRule rendered"
assert_contains "$TMP/mon-on.yaml" "name: test-neuraltrust-platform-otel-collector" "otel-collector ServiceMonitor + PrometheusRule rendered"

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
assert_contains "$TMP/self-mon.yaml" "name: test-neuraltrust-watchdog\$"   "watchdog Deployment rendered by overlay"
# Curated check ids are flipped on (regex tolerates surrounding YAML indent).
assert_contains "$TMP/self-mon.yaml" "id: control-plane-synthetic"         "control-plane-synthetic check present in overlay"
assert_contains "$TMP/self-mon.yaml" "id: data-plane-synthetic"            "data-plane-synthetic check present in overlay"
assert_contains "$TMP/self-mon.yaml" "id: firewall-synthetic"              "firewall-synthetic check present in overlay"
# The kafka-broker check must keep its target.bootstrapServers (overlay
# flips enabled only — must NOT replace the check definition).
assert_contains "$TMP/self-mon.yaml" "bootstrapServers:"                   "kafka-broker target preserved through overlay"
# scheduler URL fix: control-plane-synthetic now hits /v1/health, not /health.
assert_contains "$TMP/self-mon.yaml" "control-plane-scheduler:3000/v1/health" "scheduler URL fixed to /v1/health"

# Scenario 15: overlay backward-compat. Without the overlay (or without
# `enabledCheckIds`), no check is flipped on by the chart — operators have
# to opt in explicitly, exactly as before.
blue "scenario 15: no overlay => no curated-check flip"
render "$TMP/no-overlay.yaml" --set neuraltrust-watchdog.enabled=true
flipped=$(awk '/Source.*neuraltrust-watchdog\/templates\/configmap\.yaml/,/Source.*neuraltrust-watchdog\/templates\/[^c]/' "$TMP/no-overlay.yaml" | grep -c "enabled: true" || true)
if [ "$flipped" != "0" ]; then
  red "FAIL: watchdog enabled checks without overlay: expected 0, got $flipped"
  exit 1
fi
green "ok  - no checks flipped without overlay (backward-compat preserved)"

# Scenario 16: data-plane-api k8sJobs is ON by default. SA + RBAC render,
# the API Deployment uses the new SA, and the chart wires K8S_* env vars
# with secretsMode=inherit (no Secret/CSI dependency).
blue "scenario 16: data-plane-api k8sJobs enabled by default (inherit mode)"
render "$TMP/dp-jobs-default.yaml" \
  --set neuraltrust-data-plane.dataPlane.enabled=true
assert_contains "$TMP/dp-jobs-default.yaml" "name: data-plane-api$"          "data-plane-api ServiceAccount rendered"
assert_contains "$TMP/dp-jobs-default.yaml" "name: data-plane-job-creator$"  "data-plane-job-creator Role + RoleBinding rendered"
assert_contains "$TMP/dp-jobs-default.yaml" "serviceAccountName: data-plane-api" "API Deployment uses the data-plane-api SA"
assert_contains "$TMP/dp-jobs-default.yaml" 'name: K8S_JOBS_ENABLED'              "K8S_JOBS_ENABLED wired on API pod"
assert_contains "$TMP/dp-jobs-default.yaml" 'name: K8S_JOB_SECRETS_MODE'          "K8S_JOB_SECRETS_MODE wired on API pod"
assert_contains "$TMP/dp-jobs-default.yaml" 'value: "inherit"'                    "secretsMode defaults to inherit"
assert_contains "$TMP/dp-jobs-default.yaml" 'name: K8S_JOB_IMAGE'                 "K8S_JOB_IMAGE wired on API pod"
assert_contains "$TMP/dp-jobs-default.yaml" 'name: K8S_JOB_SERVICE_ACCOUNT'       "K8S_JOB_SERVICE_ACCOUNT wired on API pod"

# Scenario 17: opt-out path. Setting k8sJobs.enabled=false must drop the
# SA, the Role/RoleBinding, the serviceAccountName line on the Deployment,
# and every K8S_* env var. This protects older API images that don't yet
# support inherit mode.
blue "scenario 17: data-plane-api k8sJobs explicit opt-out"
render "$TMP/dp-jobs-off.yaml" \
  --set neuraltrust-data-plane.dataPlane.enabled=true \
  --set neuraltrust-data-plane.dataPlane.components.api.k8sJobs.enabled=false
assert_not_contains "$TMP/dp-jobs-off.yaml" "name: data-plane-job-creator"        "no Role/RoleBinding when k8sJobs disabled"
assert_not_contains "$TMP/dp-jobs-off.yaml" "serviceAccountName: data-plane-api"  "no serviceAccountName override when disabled"
assert_not_contains "$TMP/dp-jobs-off.yaml" 'name: K8S_JOBS_ENABLED'              "no K8S_JOBS_ENABLED env when disabled"
assert_not_contains "$TMP/dp-jobs-off.yaml" 'name: K8S_JOB_SECRETS_MODE'          "no K8S_JOB_SECRETS_MODE env when disabled"

green ""
green "All helm-render assertions passed."
