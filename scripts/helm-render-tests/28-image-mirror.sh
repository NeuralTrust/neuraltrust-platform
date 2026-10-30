#!/usr/bin/env bash
# Render scenarios 41. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

blue "==> Scenario 41: one key moves every image onto a mirror"
# Each shape renders with the mirror set; the collector image moves only with
# imageRegistryScope=all, and a repository the operator chose is never rewritten.
images_outside_mirror() { grep -E '^ +image:' "$1" | grep -v 'registry.example.com/' || true; }
out41h="$TMP/mirror-hybrid.yaml"
out41e="$TMP/mirror-external.yaml"
render_default "$out41h" --set global.imageRegistry=registry.example.com
assert_contains "$out41h" 'image: "europe-west1-docker.pkg.dev/neuraltrust-app-prod/nt-docker/opentelemetry-collector-contrib:' \
  "mirror: without imageRegistryScope the collector keeps the default registry"
render_default "$out41h" --set global.imageRegistry=registry.example.com --set global.imageRegistryScope=all
helm template test "$CHART_DIR" --namespace default -f "$CHART_DIR/values-external.yaml.example" \
  -f "$CHART_DIR/values-observability-self-hosted.yaml.example" \
  --set global.imageRegistry=registry.example.com --set global.imageRegistryScope=all > "$out41e"
for f in "$out41h" "$out41e"; do
  if [[ -n "$(images_outside_mirror "$f")" ]]; then
    red "FAIL: imageRegistryScope=all left images outside the mirror in $(basename "$f")"
    images_outside_mirror "$f"
    exit 1
  fi
  green "ok  - mirror: imageRegistryScope=all moves every image ($(basename "$f"))"
done
render_default "$out41h" --set global.imageRegistry=registry.example.com --set global.imageRegistryScope=all \
  --set global.clickstack.egress.image.repository=mirror.internal/otel
assert_contains "$out41h" 'image: "mirror.internal/otel:' \
  "mirror: an operator-chosen collector repository is kept"
