#!/usr/bin/env bash
# scripts/test-helm-render.sh
#
# Render the umbrella chart in the representative v2 scenarios and assert
# structural invariants. Runs in CI via
# .github/workflows/helm-render-tests.yml and locally:
#
#   ./scripts/test-helm-render.sh                 # HELM_SUITE=full (default)
#   HELM_SUITE=compat ./scripts/test-helm-render.sh
#   ./scripts/test-helm-render.sh 26-saas.sh      # only the named scenario files
#
# Suites:
#   full   — all chart-contract scenarios (CI: Helm v4)
#   compat — smoke + OpenShift Routes + fail-closed guards (CI: Helm v3)
#
# The scenarios live in scripts/helm-render-tests/, one file per scenario group
# with the shared helpers in lib.sh; a file outside compat starts with
# `suite_full || exit 0`. The files share no state, so they run in parallel —
# most of a render is the chart generating RSA keys, which makes the suite
# CPU-bound. HELM_RENDER_JOBS caps the parallelism (default: one per CPU).
# Each file stops at its first failed assertion; the run fails if any file does.

source "$(dirname "$0")/helm-render-tests/lib.sh"
export HELM_SUITE

SCENARIO_DIR="scripts/helm-render-tests"
JOBS="${HELM_RENDER_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}"

if (($#)); then
  files=()
  for f in "$@"; do files+=("$SCENARIO_DIR/$(basename "$f")"); done
else
  files=("$SCENARIO_DIR"/[0-9]*.sh)
fi
for f in "${files[@]}"; do
  [[ -f "$f" ]] || { red "FAIL: no scenario file $f"; exit 1; }
done

blue "==> HELM_SUITE=${HELM_SUITE} (${#files[@]} scenario files, ${JOBS} at a time)"

# Once, before the parallel renders: concurrent dependency builds would race.
helm dependency build "$CHART_DIR" >/dev/null 2>&1 \
  || helm dependency update "$CHART_DIR" >/dev/null

helm lint "$CHART_DIR" -f "$CHART_DIR/values-required.yaml" \
  "${CLICKSTACK_DEFAULT_ARGS[@]}" >/dev/null
green "ok  - helm lint passes"

# Largest file first, so the slowest group never starts last: a file's size
# tracks how many renders it makes closely enough for that.
# shellcheck disable=SC2011,SC2016 # file names are NN-slug.sh; $1/$2 belong to the inner bash
ls -S "${files[@]}" | xargs -n 1 -P "$JOBS" bash -c '
  name="$(basename "$2" .sh)"
  start=$SECONDS
  # Bash 3.2 (macOS) exits 0 when an unbound variable aborts a scenario inside
  # an `if` condition, so the message itself counts as a failure.
  if bash "$2" >"$1/$name.log" 2>&1 && ! grep -q ": unbound variable" "$1/$name.log"; then
    printf "  done %-40s %4ss\n" "$name" "$((SECONDS - start))"
  else
    touch "$1/$name.failed"
    printf "  FAIL %-40s %4ss\n" "$name" "$((SECONDS - start))"
  fi
' _ "$TMP" || true

# Logs in file order, so the output reads like one sequential run.
failed=()
for f in "${files[@]}"; do
  name="$(basename "$f" .sh)"
  cat "$TMP/$name.log"
  if [[ -e "$TMP/$name.failed" ]]; then failed+=("$name"); fi
done
checks="$(cat "$TMP"/*.log | grep -c 'ok  - ' || true)"

if ((${#failed[@]})); then
  red ""
  red "FAIL: ${#failed[@]} scenario file(s) failed: ${failed[*]}"
  red "  rerun one with: ./scripts/test-helm-render.sh ${failed[0]}.sh"
  exit 1
fi

green ""
if suite_full; then
  green "All v2 render scenarios passed."
else
  green "ok  - HELM_SUITE=compat complete"
fi
green "${checks} checks passed across ${#files[@]} scenario files."
