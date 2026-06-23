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

# Scenario 1: defaults. Observability is OFF by default — no in-chart
# collector. Components still render; hosted export is irrelevant until
# the collector is enabled (via global.observability.enabled or watchdog).
blue "scenario 1: defaults (observability off, no token)"
render "$TMP/default.yaml"
assert_not_contains "$TMP/default.yaml" "name: otel-collector-config" "otel collector ConfigMap omitted by default"

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
render "$TMP/bind-default.yaml"
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
assert_contains "$TMP/self-mon.yaml" "id: data-plane-synthetic"            "data-plane-synthetic check present in overlay"
assert_contains "$TMP/self-mon.yaml" "id: firewall-synthetic"              "firewall-synthetic check present in overlay"
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
for check_id in control-plane-synthetic data-plane-synthetic firewall-synthetic; do
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

# Scenario 23: AISPM IAM Postgres auth. IAM skips the aispm-postgresql-init Job
# (no static password to create the user/db) and empties DATABASE_PASSWORD in
# aispm-secrets. Default (password) keeps the Job and a generated password.
# TrustGate disabled so DATABASE_PASSWORD:"" can only come from aispm.
blue "scenario 23: AISPM IAM Postgres auth skips the init Job"
render "$TMP/aispm-iam.yaml" \
  --set trustgate.enabled=false \
  --set neuraltrust-aispm.aispm.enabled=true \
  --set neuraltrust-aispm.aispm.database.authMode=iam
assert_not_contains "$TMP/aispm-iam.yaml" "aispm-postgresql-init"   "aispm init Job skipped in IAM mode"
assert_contains     "$TMP/aispm-iam.yaml" "DATABASE_PASSWORD: \"\"" "aispm DB password empty in IAM mode"

blue "scenario 23b: AISPM password auth (default) keeps the init Job + password"
render "$TMP/aispm-default.yaml" \
  --set trustgate.enabled=false \
  --set neuraltrust-aispm.aispm.enabled=true
assert_contains     "$TMP/aispm-default.yaml" "aispm-postgresql-init"   "aispm init Job present in password mode"
assert_not_contains "$TMP/aispm-default.yaml" "DATABASE_PASSWORD: \"\"" "aispm DB password generated in password mode"

# Scenario 24: AISPM Redis auth plumbing. Each env renders only when its value is
# set; the default (shared in-cluster TrustGate Redis) emits none. TrustGate is
# disabled so these markers can only originate from the aispm workloads.
blue "scenario 24: AISPM Redis auth env wired only when configured"
render "$TMP/aispm-redis.yaml" \
  --set trustgate.enabled=false \
  --set neuraltrust-aispm.aispm.enabled=true \
  --set neuraltrust-aispm.aispm.redis.password=s3cr3t \
  --set neuraltrust-aispm.aispm.redis.username=aispm \
  --set neuraltrust-aispm.aispm.redis.tls=true
assert_contains     "$TMP/aispm-redis.yaml"   "key: redis-password" "aispm REDIS_PASSWORD wired from aispm-secrets when set"
assert_contains     "$TMP/aispm-redis.yaml"   "REDIS_USERNAME"      "aispm REDIS_USERNAME emitted when set"
assert_contains     "$TMP/aispm-redis.yaml"   "REDIS_TLS"           "aispm REDIS_TLS emitted when set"
assert_not_contains "$TMP/aispm-default.yaml" "key: redis-password" "no aispm Redis password by default (backward-compat)"
assert_not_contains "$TMP/aispm-default.yaml" "REDIS_USERNAME"      "no aispm REDIS_USERNAME by default (backward-compat)"

# Scenario 25: global.nodeSelector / global.tolerations pin EVERY workload to a
# dedicated (optionally tainted) node pool with a single setting. Default OFF —
# default render must inject no nodeSelector. Per-component nodeSelector still
# merges on top (per-component keys win on conflicts).
blue "scenario 25: global.nodeSelector + global.tolerations pin all workloads"
render "$TMP/global-nodeselector.yaml" \
  --set trustgate.enabled=true \
  --set firewall.enabled=true \
  --set neuraltrust-aispm.aispm.enabled=true \
  --set neuraltrust-watchdog.enabled=true \
  --set neuraltrust-control-plane.controlPlane.enabled=true \
  --set neuraltrust-data-plane.dataPlane.enabled=true \
  --set global.nodeSelector.dedicated=neuraltrust \
  --set 'global.tolerations[0].key=dedicated' \
  --set 'global.tolerations[0].operator=Equal' \
  --set 'global.tolerations[0].value=neuraltrust' \
  --set 'global.tolerations[0].effect=NoSchedule'
assert_contains "$TMP/global-nodeselector.yaml" "dedicated: neuraltrust"  "global.nodeSelector key rendered on workloads"
# Applied broadly, not just one pod (control-plane, data-plane, trustgate,
# firewall, aispm, watchdog all consume the helper).
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
#   - TrustGate + AISPM postgresql-init Jobs.
# The control-plane app init-db (Prisma migrations, app image) MUST stay.
blue "scenario 26: global.postgresql.deploy=false skips all postgres-image consumers"
render "$TMP/pg-external.yaml" \
  --set trustgate.enabled=true \
  --set neuraltrust-aispm.aispm.enabled=true \
  --set neuraltrust-control-plane.controlPlane.enabled=true \
  --set neuraltrust-data-plane.dataPlane.enabled=true \
  --set global.postgresql.deploy=false
assert_not_contains "$TMP/pg-external.yaml" "name: control-plane-postgresql"                "in-cluster PostgreSQL Deployment skipped (external)"
assert_not_contains "$TMP/pg-external.yaml" "name: wait-for-postgresql"                      "wait-for-postgresql initContainers skipped (external)"
assert_not_contains "$TMP/pg-external.yaml" "app.kubernetes.io/component: postgresql-init"   "TrustGate postgresql-init Job skipped (external)"
assert_not_contains "$TMP/pg-external.yaml" "aispm-postgresql-init"                          "AISPM postgresql-init Job skipped (external)"
assert_contains     "$TMP/pg-external.yaml" "name: init-db"                                  "control-plane app init-db (Prisma) still present (external)"

# Scenario 26b: default (deploy=true) keeps every consumer (backward-compat).
blue "scenario 26b: global.postgresql.deploy=true (default) keeps postgres-image consumers"
render "$TMP/pg-incluster.yaml" \
  --set trustgate.enabled=true \
  --set neuraltrust-aispm.aispm.enabled=true \
  --set neuraltrust-control-plane.controlPlane.enabled=true
assert_contains "$TMP/pg-incluster.yaml" "name: control-plane-postgresql"              "in-cluster PostgreSQL Deployment present by default"
assert_contains "$TMP/pg-incluster.yaml" "name: wait-for-postgresql"                   "wait-for-postgresql initContainers present by default"
assert_contains "$TMP/pg-incluster.yaml" "app.kubernetes.io/component: postgresql-init" "TrustGate postgresql-init Job present by default"
assert_contains "$TMP/pg-incluster.yaml" "aispm-postgresql-init"                       "AISPM postgresql-init Job present by default"

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
# The kafka-connect init container must guard against a multi-partition
# connect-configs (which crashes Connect's herder on start) and keep a writable
# logs dir under readOnlyRootFilesystem. Topic creation is opt-in (default off).
assert_contains     "$TMP/kafka-external.yaml" "connect-configs) echo 1 ;;"        "init container pins connect-configs to a single partition"
assert_contains     "$TMP/kafka-external.yaml" "Kafka Connect requires exactly 1"  "init container guards against a multi-partition connect-configs"
assert_contains     "$TMP/kafka-external.yaml" "mountPath: /opt/kafka/logs"        "kafka-connect mounts a writable logs dir for readOnlyRootFilesystem"
assert_contains     "$TMP/kafka-external.yaml" "CREATE_TOPICS=\"false\""           "internal-topic creation is off by default (backward compatible)"
# Opt-in: operators can let the chart create the internal topics.
render "$TMP/kafka-connect-create.yaml" \
  -f values-required.yaml \
  --set infrastructure.kafka.deploy=false \
  --set global.kafka.bootstrapServers=kafka.example.svc:9093 \
  --set neuraltrust-data-plane.dataPlane.enabled=true \
  --set neuraltrust-data-plane.dataPlane.components.kafka.connect.createInternalTopics=true
assert_contains     "$TMP/kafka-connect-create.yaml" "CREATE_TOPICS=\"true\""       "createInternalTopics=true enables chart-side topic creation"
assert_contains     "$TMP/kafka-connect-create.yaml" "--create --if-not-exists"     "init container creates internal topics when opted in"

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

green ""
green "All helm-render assertions passed."
