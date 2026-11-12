#!/usr/bin/env bash
# Render scenarios 42, 42b, 42c. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

# global.platform empty (the default) detects the platform. A default of gcp
# made a plain `helm install` fail on every other cluster: the BackendConfig
# CRD does not exist there, and the gce Ingress class leaves Ingresses unserved.
# On GKE the cluster serves cloud.google.com/v1/BackendConfig, which a live
# install, Argo CD and Flux all pass to the render, so GKE keeps every gcp
# object. values-required.yaml pins kubernetes, so each render clears it.
blue "==> Scenario 42: global.platform auto-detection"

PLATFORM_ARGS=(--set global.products.dataPlane=true --set global.platform=)

count_gke() {
  local file="$1"
  printf '%s %s' "$(grep -c 'kind: BackendConfig' "$file" || true)" \
    "$(grep -c 'cloud.google.com/neg' "$file" || true)"
}

out42="$TMP/platform-auto-offline.yaml"
render_default "$out42" "${PLATFORM_ARGS[@]}"
assert_not_contains "$out42" 'kind: BackendConfig' \
  "auto off GKE: no BackendConfig, so the install does not need GKE's CRD"
assert_not_contains "$out42" 'cloud\.google\.com/neg' \
  "auto off GKE: no NEG annotations"
assert_not_contains "$out42" 'kubernetes\.io/ingress\.class: "?gce' \
  "auto off GKE: no gce Ingress class"

# 42b. On GKE the detected platform renders exactly what an explicit gcp does.
blue "==> Scenario 42b: auto on GKE matches explicit gcp"
out42b="$TMP/platform-auto-gke.yaml"
out42b_explicit="$TMP/platform-explicit-gcp.yaml"
render_default "$out42b" "${PLATFORM_ARGS[@]}" --api-versions cloud.google.com/v1/BackendConfig
render_default "$out42b_explicit" --set global.products.dataPlane=true --set global.platform=gcp
assert_contains "$out42b" 'kind: BackendConfig' \
  "auto on GKE: the BackendConfig health check renders"
assert_contains "$out42b" 'cloud\.google\.com/neg' \
  "auto on GKE: NEG annotations render"
if [[ "$(count_gke "$out42b")" == "$(count_gke "$out42b_explicit")" ]]; then
  green "ok  - auto on GKE renders the same GKE objects as an explicit gcp"
else
  red "FAIL: auto on GKE ($(count_gke "$out42b")) differs from explicit gcp ($(count_gke "$out42b_explicit"))"
  exit 1
fi

# 42c. An explicit platform always wins over detection.
blue "==> Scenario 42c: an explicit platform wins"
out42c="$TMP/platform-explicit-k8s-on-gke.yaml"
render_default "$out42c" --set global.products.dataPlane=true --set global.platform=kubernetes \
  --api-versions cloud.google.com/v1/BackendConfig
assert_not_contains "$out42c" 'kind: BackendConfig' \
  "explicit kubernetes on GKE: no BackendConfig"
