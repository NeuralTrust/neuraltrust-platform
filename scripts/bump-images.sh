#!/usr/bin/env bash
#
# Bump NeuralTrust image tags in this chart, locally.
#
# Local twin of .github/workflows/bump-images.yml: same registry, same tag
# filters, same value paths, same template fallbacks, same chart-version rules —
# so running this and running the workflow produce the same diff.
#
# Differences, all deliberate:
#   * Never touches git. No branch, no commit, no PR. Review and commit yourself.
#   * Works with BSD sed (macOS), which the workflow's GNU sed idioms do not.
#   * Root Chart.yaml version is left alone, exactly as in CI — auto-release.yml
#     owns it on merge to main.
#
# v2 only. v1 (TrustGate/Kafka) lives on the v1.14.x line and is not bumped here.
#
# Usage:
#   scripts/bump-images.sh --dry-run                 # what would change
#   scripts/bump-images.sh                           # apply
#   scripts/bump-images.sh --only watchdog,firewall  # a subset
#   scripts/bump-images.sh --set app=v1.148.4        # pin instead of detecting
#   scripts/bump-images.sh --no-fetch --set app=v1.148.4
#   scripts/bump-images.sh --verify                  # apply, then render-test
#   scripts/bump-images.sh --deps                    # apply, then refresh Chart.lock
#                                                    #   and the committed charts/*.tgz
#
# Requires: gcloud (authenticated, read access to the registry), yq v4.
# --verify additionally requires helm.

set -euo pipefail

AR_REGISTRY="europe-west1-docker.pkg.dev"
AR_PROJECT="neuraltrust-app-prod"
AR_REPO="nt-docker"
AR_BASE="${AR_REGISTRY}/${AR_PROJECT}/${AR_REPO}"

SEMVER='^v[0-9]+\.[0-9]+\.[0-9]+$'
BARE='^[0-9]+\.[0-9]+\.[0-9]+$'

DRY_RUN=false
FETCH=true
VERIFY=false
DEPS=false
ONLY=""
declare -a PINS=()

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; BLUE=$'\033[0;34m'; DIM=$'\033[2m'; OFF=$'\033[0m'
info() { printf '%s\n' "$*"; }
ok()   { printf '%s%s%s\n' "$GREEN" "$*" "$OFF"; }
warn() { printf '%s%s%s\n' "$YELLOW" "$*" "$OFF"; }
die()  { printf '%s%s%s\n' "$RED" "$*" "$OFF" >&2; exit 1; }
step() { printf '\n%s==> %s%s\n' "$BLUE" "$*" "$OFF"; }

usage() { sed -n '3,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  DRY_RUN=true; shift ;;
    --no-fetch) FETCH=false; shift ;;
    --verify)   VERIFY=true; shift ;;
    --deps)     DEPS=true; shift ;;
    --only)     ONLY="${2:?--only needs a comma-separated list}"; shift 2 ;;
    --set)      PINS+=("${2:?--set needs key=tag}"); shift 2 ;;
    -h|--help)  usage ;;
    *)          die "unknown argument: $1 (try --help)" ;;
  esac
done

cd "$(dirname "$0")/.."
[[ -f Chart.yaml ]] || die "run this from the chart repo — Chart.yaml not found"
command -v yq >/dev/null || die "yq v4 is required (brew install yq)"
if [[ "$FETCH" == true ]]; then
  command -v gcloud >/dev/null || die "gcloud is required for tag detection (or pass --no-fetch --set ...)"
fi

# ---------------------------------------------------------------------------
# Tag resolution
# ---------------------------------------------------------------------------

wanted() {
  local key="$1"
  [[ -z "$ONLY" ]] && return 0
  [[ ",${ONLY}," == *",${key},"* ]]
}

pinned() {
  local key="$1" p
  for p in "${PINS[@]:-}"; do
    [[ "$p" == "${key}="* ]] && { printf '%s' "${p#*=}"; return 0; }
  done
  return 1
}

# resolve <key> <ar-image> [tag-regex]
# Pin wins; otherwise newest registry tag matching the pattern; empty = skip.
resolve() {
  local key="$1" image="$2" pattern="${3:-$SEMVER}" tag

  wanted "$key" || { printf ''; return 0; }

  if tag=$(pinned "$key"); then
    printf '%s' "$tag"; return 0
  fi
  [[ "$FETCH" == true ]] || { printf ''; return 0; }

  tag=$(gcloud artifacts docker tags list "${AR_BASE}/${image}" --format='value(tag)' 2>/dev/null \
        | grep -E "$pattern" | sort -V | tail -1) || true
  [[ -n "$tag" ]] || warn "  could not resolve a tag for ${image} — skipping" >&2
  printf '%s' "$tag"
}

# ---------------------------------------------------------------------------
# Edit helpers
# ---------------------------------------------------------------------------

declare -a CHANGES=()
# Space-delimited list of subchart dirs that changed. A plain string rather than
# an associative array so this runs on the bash 3.2 that ships with macOS.
TOUCHED=""
touch_dir() {
  case " ${TOUCHED} " in *" $1 "*) return 0 ;; esac
  TOUCHED="${TOUCHED} $1"
}

# set_tag <yq-path> <tag> <label> [file]
# Returns 0 only when the file actually changed, so callers can gate on it.
set_tag() {
  local path="$1" tag="$2" label="$3" file="${4:-values.yaml}" current
  [[ -n "$tag" ]] || return 1
  [[ -f "$file" ]] || { warn "  missing ${file}"; return 1; }

  current=$(yq eval "$path" "$file")
  [[ "$current" == "null" ]] && current=""
  if [[ "$current" == "$tag" ]]; then
    info "  ${DIM}${label}: already ${tag}${OFF}"
    return 1
  fi

  info "  ${label}: ${current:-<unset>} → ${GREEN}${tag}${OFF}  ${DIM}(${file})${OFF}"
  CHANGES+=("${label}: ${current:-<unset>} → ${tag}")
  [[ "$DRY_RUN" == true ]] || yq eval -i "${path} = \"${tag}\"" "$file"
  return 0
}

# set_fallback <file> <var> <tag>
# Rewrites a hardcoded Go-template default: {{- $var := "TAG" }} and the
# {{- $var := .Values.x | default "TAG" }} form. Portable across sed flavours by
# writing through a temp file instead of relying on -i semantics.
set_fallback() {
  local file="$1" var="$2" tag="$3" tmp
  [[ -n "$tag" && -f "$file" ]] || return 1
  grep -q "\$${var} :=" "$file" 2>/dev/null || return 1

  tmp=$(mktemp)
  sed -E \
    -e "s/(\\\$${var} := )\"[^\"]*\"/\1\"${tag}\"/" \
    -e "s/(\\\$${var} := .*\| default )\"[^\"]*\"/\1\"${tag}\"/" \
    "$file" > "$tmp"

  if cmp -s "$file" "$tmp"; then rm -f "$tmp"; return 1; fi
  info "  fallback \$${var} → ${GREEN}${tag}${OFF}  ${DIM}(${file})${OFF}"
  CHANGES+=("${file} \$${var} → ${tag}")
  if [[ "$DRY_RUN" == true ]]; then rm -f "$tmp"; else mv "$tmp" "$file"; fi
  return 0
}

# bump_subchart <dir> <dep-name>
# Patch-bumps the subchart and syncs the root Chart.yaml dependency pin.
bump_subchart() {
  local dir="$1" dep="$2" cur new major minor patch
  cur=$(yq eval '.version' "charts/${dir}/Chart.yaml")
  IFS='.' read -r major minor patch <<< "$cur"
  new="${major}.${minor}.$((patch + 1))"
  info "  chart ${dir}: ${cur} → ${GREEN}${new}${OFF}"
  CHANGES+=("chart ${dir}: ${cur} → ${new}")
  if [[ "$DRY_RUN" == false ]]; then
    yq eval -i ".version = \"${new}\"" "charts/${dir}/Chart.yaml"
    yq eval -i "(.dependencies[] | select(.name == \"${dep}\")).version = \"${new}\"" Chart.yaml
  fi
}

set_app_version() {
  local dir="$1" tag="$2"
  [[ -n "$tag" ]] || return 0
  [[ "$(yq eval '.appVersion' "charts/${dir}/Chart.yaml")" == "$tag" ]] && return 0
  info "  chart ${dir} appVersion → ${GREEN}${tag}${OFF}"
  [[ "$DRY_RUN" == true ]] || yq eval -i ".appVersion = \"${tag}\"" "charts/${dir}/Chart.yaml"
}

# ---------------------------------------------------------------------------
# Resolve every tag up front, then report
# ---------------------------------------------------------------------------

step "Resolving tags${DRY_RUN:+ }$([[ "$DRY_RUN" == true ]] && echo '(dry run)')"

CONTROL_PLANE_API=$(resolve control-plane-api control-plane-api)
APP=$(resolve app app)
DATA_PLANE_API=$(resolve data-plane-api data-plane-api)
FIREWALL=$(resolve firewall firewall-cpu)          # firewall-gpu shares the tag
WATCHDOG=$(resolve watchdog watchdog)
AGENTGATEWAY=$(resolve agentgateway agentgateway)
TRUSTGUARD=$(resolve trustguard trustguard)
TRUSTLENS=$(pinned trustlens || true)              # no registry repo yet: pin only
DATAAGENT=$(resolve dataagent dataagent)
DATACORE=$(resolve datacore datacore)
DATABRIDGE=$(resolve databridge databridge)
ALERTENGINE=$(resolve alertengine alertengine)
CLICKSTACK_COLLECTOR=$(resolve clickstack-otel-collector clickstack-otel-collector "$BARE")
OTEL_CONTRIB=$(resolve opentelemetry-collector-contrib opentelemetry-collector-contrib "$BARE")
CLICKHOUSE=$(resolve clickhouse clickhouse-server '^[0-9]+\.[0-9]+(\.[0-9]+){0,2}$')
REDIS=$(resolve redis redis-stack-server '^[0-9]+\.[0-9]+\.[0-9]+-v[0-9]+$')
POSTGRES=$(resolve postgres postgres '^[0-9]+-alpine$')

printf '\n%-34s %s\n' "IMAGE" "RESOLVED"
for row in \
  "control-plane-api:$CONTROL_PLANE_API" "app:$APP" "data-plane-api:$DATA_PLANE_API" \
  "firewall:$FIREWALL" "watchdog:$WATCHDOG" "agentgateway:$AGENTGATEWAY" \
  "trustguard:$TRUSTGUARD" "trustlens:$TRUSTLENS" "dataagent:$DATAAGENT" \
  "datacore:$DATACORE" "databridge:$DATABRIDGE" "alertengine:$ALERTENGINE" \
  "clickstack-otel-collector:$CLICKSTACK_COLLECTOR" "otel-collector-contrib:$OTEL_CONTRIB" \
  "clickhouse:$CLICKHOUSE" "redis:$REDIS" "postgres:$POSTGRES"; do
  printf '%-34s %s\n' "${row%%:*}" "${row#*:}"
done

# ---------------------------------------------------------------------------
# Apply, service by service. Order and paths mirror the workflow.
# ---------------------------------------------------------------------------

step "Control-plane API"
if set_tag '.["control-plane-api"].controlPlane.components.api.image.tag' "$CONTROL_PLANE_API" "control-plane-api"; then
  touch_dir control-plane-api
fi
set_fallback charts/control-plane-api/templates/api/deployment.yaml apiImageTag "$CONTROL_PLANE_API" && touch_dir control-plane-api

step "Control-plane App (UI)"
if set_tag '.["control-plane-app"].controlPlane.components.app.image.tag' "$APP" "control-plane-app"; then
  touch_dir control-plane-app
  # initContainer and main container share the image; the key-generation hooks
  # run it too, and their fallback lives in its own file because set_fallback
  # rewrites every matching var in a file.
  set_fallback charts/control-plane-app/templates/app/deployment.yaml initImageTag "$APP" || true
  set_fallback charts/control-plane-app/templates/app/deployment.yaml appImageTag "$APP" || true
  set_fallback templates/_keygen.tpl appTag "$APP" || true
fi

step "Data-plane API"
if set_tag '.["data-plane-api"].dataPlane.components.api.image.tag' "$DATA_PLANE_API" "data-plane-api"; then
  touch_dir data-plane-api
fi
for pair in "api/deployment.yaml:apiTag" "api/deployment.yaml:fallbackApiTag" "_helpers.tpl:apiTag"; do
  set_fallback "charts/data-plane-api/templates/${pair%%:*}" "${pair#*:}" "$DATA_PLANE_API" && touch_dir data-plane-api
done

step "Firewall (gateway + workers, one tag)"
fw_changed=false
set_tag '.firewall.firewall.gateway.image.tag'       "$FIREWALL" "firewall gateway"      && fw_changed=true
set_tag '.firewall.firewall.workerDefaults.image.tag' "$FIREWALL" "firewall workers"     && fw_changed=true
set_tag '.firewall.gateway.image.tag'        "$FIREWALL" "firewall gateway (subchart)"  charts/firewall/values.yaml && fw_changed=true
set_tag '.firewall.workerDefaults.image.tag' "$FIREWALL" "firewall workers (subchart)"  charts/firewall/values.yaml && fw_changed=true
set_fallback charts/firewall/templates/gateway-deployment.yaml gwTag "$FIREWALL" && fw_changed=true
set_fallback charts/firewall/templates/worker-deployment.yaml  wTag  "$FIREWALL" && fw_changed=true
if [[ "$fw_changed" == true ]]; then touch_dir firewall; set_app_version firewall "$FIREWALL"; fi

# Single-image subcharts: umbrella key, subchart values, appVersion.
step "Single-image subcharts"
# bump_simple <key> <umbrella-path|-> <subchart-dir> <tag>
# Pass "-" for the umbrella path when the chart deliberately has no top-level
# key: watchdog resolves its tag from the subchart default and Chart.appVersion,
# so adding an umbrella key here would both diverge from CI and grow values.yaml
# against the slim-values rule.
bump_simple() {
  local key="$1" umbrella_path="$2" dir="$3" tag="$4" changed=false
  if [[ "$umbrella_path" != "-" ]]; then
    set_tag "$umbrella_path" "$tag" "$key" && changed=true
  fi
  set_tag '.image.tag' "$tag" "${key} (subchart)" "charts/${dir}/values.yaml" && changed=true
  if [[ "$changed" == true ]]; then touch_dir "$dir"; set_app_version "$dir" "$tag"; fi
}
bump_simple watchdog                  -                                        watchdog                  "$WATCHDOG"
bump_simple agentgateway              '.agentgateway.image.tag'                agentgateway              "$AGENTGATEWAY"
bump_simple trustguard                '.trustguard.image.tag'                  trustguard                "$TRUSTGUARD"
bump_simple trustlens                 '.trustlens.image.tag'                   trustlens                 "$TRUSTLENS"
bump_simple dataagent                 '.dataagent.image.tag'                   dataagent                 "$DATAAGENT"
bump_simple datacore                  '.datacore.image.tag'                    datacore                  "$DATACORE"
bump_simple databridge                '.databridge.image.tag'                  databridge                "$DATABRIDGE"
bump_simple alertengine               '.alertengine.image.tag'                 alertengine               "$ALERTENGINE"
bump_simple clickstack-otel-collector '.["clickstack-otel-collector"].image.tag' clickstack-otel-collector "$CLICKSTACK_COLLECTOR"

step "Infrastructure"
set_tag '.clickhouse.image.tag' "$CLICKHOUSE" "clickhouse" && touch_dir clickhouse
set_tag '.infrastructure.redis.image.tag' "$REDIS" "redis (in-cluster)" || true
set_fallback templates/redis/_helpers.tpl tag "$REDIS" || true
set_tag '.global.postgresql.image.tag' "$POSTGRES" "postgres (in-cluster)" || true
set_fallback templates/postgresql/deployment.yaml tag "$POSTGRES" || true
set_fallback charts/control-plane-api/templates/api/deployment.yaml pgWaitImageTag "$POSTGRES" && touch_dir control-plane-api
set_fallback charts/data-plane-api/templates/api/deployment.yaml    pgMigTag       "$POSTGRES" && touch_dir data-plane-api
set_fallback charts/data-plane-api/templates/api/deployment.yaml    chMigrationTag "$CLICKHOUSE" && touch_dir data-plane-api

# otel-collector-contrib fallback is an inline `default "X.Y.Z"`, not a $var.
if [[ -n "$OTEL_CONTRIB" ]] && grep -q 'opentelemetry-collector-contrib' templates/otel-collector/deployment.yaml 2>/dev/null; then
  tmp=$(mktemp)
  sed -E "s/(default \")[0-9]+\.[0-9]+\.[0-9]+(\" \(default dict \\\$coll\.image\)\.tag)/\1${OTEL_CONTRIB}\2/" \
    templates/otel-collector/deployment.yaml > "$tmp"
  if cmp -s templates/otel-collector/deployment.yaml "$tmp"; then
    rm -f "$tmp"
  else
    info "  otel-collector-contrib fallback → ${GREEN}${OTEL_CONTRIB}${OFF}"
    CHANGES+=("otel-collector-contrib fallback → ${OTEL_CONTRIB}")
    [[ "$DRY_RUN" == true ]] && rm -f "$tmp" || mv "$tmp" templates/otel-collector/deployment.yaml
  fi
fi
set_fallback templates/_helpers.tpl tag "$OTEL_CONTRIB" || true

# ---------------------------------------------------------------------------
# Chart versions + summary
# ---------------------------------------------------------------------------

step "Chart versions"
if [[ -z "${TOUCHED// /}" ]]; then
  info "  ${DIM}no subchart changed${OFF}"
else
  for dir in $TOUCHED; do bump_subchart "$dir" "$dir"; done
fi
info "  ${DIM}root Chart.yaml version left alone — auto-release.yml owns it on merge${OFF}"

step "Summary"
if [[ ${#CHANGES[@]} -eq 0 ]]; then
  ok "Everything already current. Nothing to do."
  exit 0
fi
for c in "${CHANGES[@]}"; do info "  - ${c}"; done

if [[ "$DRY_RUN" == true ]]; then
  printf '\n'; warn "Dry run — nothing written. Re-run without --dry-run to apply."
  exit 0
fi

printf '\n'
ok "Applied ${#CHANGES[@]} change(s). Nothing was committed — review with: git diff"

# Chart.lock pins the subchart versions this file just bumped, and the committed
# charts/*.tgz are what `helm install .` from a checkout actually uses. CI does
# neither — publish-chart.yml regenerates them at publish time with
# --dependency-update — so this stays opt-in to keep the default diff matched to
# the workflow's.
if [[ "$DEPS" == true ]]; then
  step "Refreshing dependencies (Chart.lock + charts/*.tgz)"
  command -v helm >/dev/null || die "helm is required for --deps"
  helm dependency update . >/dev/null
  ok "  Chart.lock and packaged subcharts refreshed"
fi

if [[ "$VERIFY" == true ]]; then
  step "Verifying (scripts/test-helm-render.sh)"
  bash scripts/test-helm-render.sh
fi
