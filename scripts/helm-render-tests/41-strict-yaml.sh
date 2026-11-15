#!/usr/bin/env bash
# Render scenario 41. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

# Every documented shape renders YAML a strict parser accepts. A template whose
# trailing `-}}` eats the newline before a comment glues the comment onto the
# previous value (`KEY: "true"# comment`). Helm and Ruby accept that; yq 4.5x,
# kubeconform and other strict YAML 1.2 parsers reject the whole stream, which
# breaks any pipeline that post-processes `helm template` output.
blue "==> Scenario 41: rendered YAML is strict-parser clean"

out41_hybrid="$TMP/strict-hybrid.yaml"
out41_external="$TMP/strict-external.yaml"
out41_saas="$TMP/strict-saas.yaml"
out41_dedicated="$TMP/strict-dedicated.yaml"
out41_dedicated_guard="$TMP/strict-dedicated-guard.yaml"
render_default "$out41_hybrid"
render_default "$out41_external" --set global.deploymentMode=external
render_default "$out41_saas" --set global.deploymentMode=saas --set global.domain=cp.example.com
helm template x "$CHART_DIR" --namespace dp-x -f "$CHART_DIR/values-dedicated.yaml.example" > "$out41_dedicated"
# The dedicated plane's own TrustGuard URL renders through a separate branch of
# the env ConfigMap, so it needs its own shape.
helm template x "$CHART_DIR" --namespace dp-x -f "$CHART_DIR/values-dedicated.yaml.example" \
  --set agentgateway.trustguard.baseURL=http://trustguard-data.trustguard.svc.cluster.local:8081 \
  > "$out41_dedicated_guard"

for shape in hybrid external saas dedicated dedicated-guard; do
  file="$TMP/strict-$shape.yaml"
  # Toolchain-independent: a quoted scalar immediately followed by a comment.
  assert_not_contains "$file" '"#' \
    "$shape: no comment glued onto a quoted value"
  if command -v yq >/dev/null 2>&1; then
    if yq '.' "$file" >/dev/null 2>"$TMP/strict-$shape.err"; then
      green "ok  - $shape: yq parses the whole render"
    else
      red "FAIL: $shape: yq rejects the render"
      red "  $(head -1 "$TMP/strict-$shape.err")"
      exit 1
    fi
  else
    yellow "skip - $shape: yq not installed"
  fi
done
