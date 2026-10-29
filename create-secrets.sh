#!/usr/bin/env bash
# create-secrets.sh — every Secret the chart reads when it does not create its own.
#
# Set global.autoGenerateSecrets: false and global.preserveExistingSecrets: true,
# and the chart renders no Secret: every one its workloads read must already exist.
# That is the stable way to install with ArgoCD or Flux, which render with
# `helm template` and so cannot reuse a generated value, and the way to keep
# credentials in a vault.
#
# This script renders the chart with your values to find exactly which Secrets and
# keys your install reads, generates each value the chart would have generated
# (passwords, signing keys, TLS material, connection strings), and then either
# prints them or creates them in the namespace.
#
#   ./create-secrets.sh print -f my-values.yaml > secrets.yaml   # review, or load into a vault
#   ./create-secrets.sh print -f my-values.yaml -o json          # {"secret": {"KEY": "value"}}
#   ./create-secrets.sh apply -f my-values.yaml                  # create them in the cluster
#
# Commands:
#   print   Write every Secret with its keys and values to stdout; change nothing.
#   apply   Create missing Secrets and add missing keys. An existing value is never
#           changed, so running it again is safe.
#
# Options:
#   -f, --values FILE        Values file, as passed to helm. Repeatable.
#   --set K=V                Passed to helm. Repeatable. Also --set-string, --set-file.
#   -n, --namespace NS       Install namespace (default: neuraltrust). TLS
#                            certificates are issued for services in it.
#   --release NAME           Helm release name (default: neuraltrust-platform).
#   --chart REF              Chart directory or OCI reference. Default: the chart next
#                            to this script, else the published chart (needs --version).
#   --version VERSION        Chart version, for an OCI --chart.
#   --secret NAME/KEY=VALUE  Supply a value: one only you know, or one you want instead
#                            of a generated one. VALUE @path reads a file (a PEM, or to
#                            keep it out of shell history). Repeatable.
#   -o, --output FORMAT      print: yaml (Secret manifests, default) or json.
#   --context NAME           apply: kubectl context.
#   -h, --help               Show this help.
#
# Values only you can supply (the console administrator, the NeuralTrust firewall
# key, console-issued tokens, Cloud SQL passwords) are printed as REPLACE_ME, and
# apply leaves them out. Pass them with --secret, or create them yourself.
#
# Needs: bash 3.2+, helm 3.8+, yq v4 (github.com/mikefarah/yq), openssl;
# kubectl for apply. Runs on macOS, Linux, and Windows (Git Bash or WSL).

# shellcheck disable=SC2016  # the $names inside single quotes are yq variables
set -euo pipefail

DEFAULT_OCI_CHART="oci://europe-west1-docker.pkg.dev/neuraltrust-app-prod/helm-charts/neuraltrust-platform"
PLACEHOLDER="REPLACE_ME"
# Optional integrations: referenced by the workloads, needed only when you use them.
OPTIONAL_SECRETS="openai-secrets google-secrets resend-secrets"
OPTIONAL_KEYS="firewall-secrets/HUGGINGFACE_TOKEN"

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*" >&2; }

# Windows binaries (helm.exe, yq.exe) need native paths, including inside yq
# expressions where Git Bash does not translate them.
native_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

COMMAND=""
NAMESPACE="neuraltrust"
RELEASE="neuraltrust-platform"
CHART=""
VERSION=""
OUTPUT="yaml"
KUBE_CONTEXT=""
HELM_ARGS=()
SECRET_ARGS=()

[ $# -gt 0 ] || usage 1
case "$1" in
  print|apply) COMMAND="$1"; shift ;;
  -h|--help) usage 0 ;;
  *) printf 'Unknown command: %s (expected print or apply)\n\n' "$1" >&2; usage 1 ;;
esac

need_arg() { [ $# -ge 2 ] && [ -n "$2" ] || die "$1 needs a value"; }
while [ $# -gt 0 ]; do
  case "$1" in
    -f|--values) need_arg "$@"; [ -f "$2" ] || die "values file not found: $2"
      HELM_ARGS+=(-f "$(native_path "$2")"); shift 2 ;;
    --set|--set-string|--set-file) need_arg "$@"; HELM_ARGS+=("$1" "$2"); shift 2 ;;
    -n|--namespace) need_arg "$@"; NAMESPACE="$2"; shift 2 ;;
    --release) need_arg "$@"; RELEASE="$2"; shift 2 ;;
    --chart) need_arg "$@"; CHART="$2"; shift 2 ;;
    --version) need_arg "$@"; VERSION="$2"; shift 2 ;;
    --secret) need_arg "$@"; SECRET_ARGS+=("$2"); shift 2 ;;
    -o|--output) need_arg "$@"; OUTPUT="$2"; shift 2 ;;
    --context) need_arg "$@"; KUBE_CONTEXT="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

case "$OUTPUT" in yaml|json) ;; *) die "--output must be yaml or json" ;; esac

command -v helm >/dev/null 2>&1 || die "helm is required: https://helm.sh/docs/intro/install/"
command -v yq >/dev/null 2>&1 || die "yq v4 is required: https://github.com/mikefarah/yq#install"
yq --version 2>/dev/null | grep -q 'mikefarah.* v4\.' \
  || die "yq v4 from github.com/mikefarah/yq is required; found: $(yq --version 2>&1 | head -1)"
command -v openssl >/dev/null 2>&1 || die "openssl is required"
if [ "$COMMAND" = apply ]; then
  command -v kubectl >/dev/null 2>&1 || die "kubectl is required for apply"
fi

WORK="$(mktemp -d 2>/dev/null || mktemp -d -t nt-secrets)"
trap 'rm -rf "$WORK"' EXIT

# --- the chart, as a local directory -----------------------------------------
# A local directory is needed to read the shared-credential registry below.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -z "$CHART" ]; then
  if [ -f "$SCRIPT_DIR/Chart.yaml" ] && [ -d "$SCRIPT_DIR/templates" ]; then
    CHART="$SCRIPT_DIR"
  else
    CHART="$DEFAULT_OCI_CHART"
  fi
fi
case "$CHART" in
  oci://*)
    [ -n "$VERSION" ] || die "--version is required with an OCI chart"
    helm pull "$CHART" --version "$VERSION" --untar --untardir "$(native_path "$WORK/chart")" >/dev/null \
      || die "could not pull $CHART $VERSION"
    CHART_DIR="$(find "$WORK/chart" -mindepth 1 -maxdepth 1 -type d | head -1)" ;;
  *)
    [ -f "$CHART/Chart.yaml" ] || die "not a chart directory: $CHART"
    CHART_DIR="$CHART" ;;
esac

# --- three renders -----------------------------------------------------------
render() {
  local out="$1"; shift
  if ! helm template "$RELEASE" "$(native_path "$CHART_DIR")" --namespace "$NAMESPACE" \
      ${HELM_ARGS[@]+"${HELM_ARGS[@]}"} "$@" > "$out" 2> "$out.err"; then
    cat "$out.err" >&2
    return 1
  fi
}

# What the install reads: the workloads exactly as they will run.
render "$WORK/needed.yaml" \
  --set global.autoGenerateSecrets=false --set global.preserveExistingSecrets=true \
  || die "the chart does not render with these values and preserveExistingSecrets=true (above)"
# What the chart would generate, into the per-service Secrets those workloads read.
render "$WORK/generated.yaml" \
  --set global.autoGenerateSecrets=true --set global.preserveExistingSecrets=false \
  --set global.platformSecret.enabled=false \
  || die "the chart does not render with these values and autoGenerateSecrets=true (above)"
# Credentials two services share, generated once so both copies match.
render "$WORK/shared.yaml" \
  --set global.autoGenerateSecrets=true --set global.preserveExistingSecrets=false \
  || die "the chart does not render with these values and autoGenerateSecrets=true (above)"

# --- what the workloads reference -------------------------------------------
# One line per reference: "<secret> <key>", with __all__ for a whole-Secret mount
# (not "*": yq string equality treats it as a wildcard).
NEEDED="$(native_path "$WORK/needed.yaml")"
{
  yq -N '.. | select(has("secretKeyRef")) | .secretKeyRef | .name + " " + .key' "$NEEDED"
  yq -N '.. | select(has("secretRef")) | .secretRef.name + " __all__"' "$NEEDED"
  yq -N '.. | select(has("secretName")) | .secretName + " __all__"' "$NEEDED"
  yq -N '.. | select(has("certificateRefs")) | .certificateRefs[] | .name + " __all__"' "$NEEDED"
} 2>/dev/null | tr -d '\r' | { grep -v '^ ' || true; } | sort -u > "$WORK/refs.txt"

# Secrets the chart still owns in this mode, or that its hook Jobs mint in the
# cluster (the m2m and MCP signing keys): not ours to create.
{
  yq -N 'select(.kind == "Secret") | .metadata.name' "$NEEDED"
  yq -N 'select(.metadata.annotations."helm.sh/hook" != null) | .. | select(has("env")) | .env[] | .value // ""' "$NEEDED"
} 2>/dev/null | tr -d '\r' | { grep -v '^$' || true; } | sort -u > "$WORK/owned.txt"

PULL_SECRETS="$(yq -N '.. | select(has("imagePullSecrets")) | .imagePullSecrets[] | .name // .' "$NEEDED" 2>/dev/null | tr -d '\r' | sort -u | tr '\n' ' ')"

: > "$WORK/refs.yaml"
while read -r name key; do
  [ -n "$name" ] || continue
  grep -Fqx "$name" "$WORK/owned.txt" && continue
  printf -- '- {name: "%s", key: "%s"}\n' "$name" "$key" >> "$WORK/refs.yaml"
done < "$WORK/refs.txt"
[ -s "$WORK/refs.yaml" ] || die "the rendered workloads reference no Secret; check the values"

# --- generated values --------------------------------------------------------
yq ea -o=json '[select(.kind == "Secret")]
  | map({"key": .metadata.name, "value": {"type": (.type // "Opaque"),
      "values": (((.data // {}) | map_values(@base64d)) * (.stringData // {}))}})
  | from_entries' "$(native_path "$WORK/generated.yaml")" > "$WORK/generated.json"
yq ea -o=json '[select(.kind == "Secret" and .metadata.name == "platform-secrets")] | .[0] // {}
  | ((.data // {}) | map_values(@base64d)) * (.stringData // {})' \
  "$(native_path "$WORK/shared.yaml")" > "$WORK/shared.json"

# Each shared credential's per-service home, from the chart's registry rows:
# "KEY: {legacyName: secret, legacyKey: key, generate: random, length: 64, ...}".
: > "$WORK/registry.yaml"
: > "$WORK/registry.txt"
grep -E '^[A-Z0-9_]+: \{legacyName: ' "$CHART_DIR/templates/_helpers.tpl" | tr -d '\r' | while IFS= read -r row; do
  shared="${row%%:*}"
  name="$(printf '%s' "$row" | sed -n 's/.*legacyName: \([a-z0-9.-]*\).*/\1/p')"
  key="$(printf '%s' "$row" | sed -n 's/.*legacyKey: \([A-Za-z0-9_.-]*\).*/\1/p')"
  generate="$(printf '%s' "$row" | sed -n 's/.*generate: \([a-z]*\).*/\1/p')"
  length="$(printf '%s' "$row" | sed -n 's/.*length: \([0-9]*\).*/\1/p')"
  printf -- '- {name: "%s", key: "%s", shared: "%s"}\n' "$name" "$key" "$shared" >> "$WORK/registry.yaml"
  printf '%s/%s %s %s\n' "$name" "$key" "${generate:-none}" "${length:-64}" >> "$WORK/registry.txt"
done

# Values given with --secret.
echo '{}' > "$WORK/supplied.json"
for arg in ${SECRET_ARGS[@]+"${SECRET_ARGS[@]}"}; do
  case "$arg" in */*=*) ;; *) die "--secret expects NAME/KEY=VALUE, got: $arg" ;; esac
  ref="${arg%%=*}"; value="${arg#*=}"
  sname="${ref%%/*}"; skey="${ref#*/}"
  case "$value" in
    @*) [ -f "${value#@}" ] || die "--secret $ref: file not found: ${value#@}"
        value="$(cat "${value#@}")" ;;
  esac
  SNAME="$sname" SKEY="$skey" SVAL="$value" yq -i -o=json \
    '.[strenv(SNAME)][strenv(SKEY)] = strenv(SVAL)' "$(native_path "$WORK/supplied.json")"
done

# --- compose -----------------------------------------------------------------
# Per key, the first that exists: --secret, the shared credential, the per-service
# value, else null (only you can supply it).
G="$(native_path "$WORK/generated.json")" S="$(native_path "$WORK/shared.json")" \
R="$(native_path "$WORK/registry.yaml")" U="$(native_path "$WORK/supplied.json")" \
yq -o=json '
  . as $refs
  | load(strenv(G)) as $gen | load(strenv(S)) as $shared
  | load(strenv(R)) as $reg | load(strenv(U)) as $sup
  | ($reg | map({"key": .name + "/" + .key, "value": $shared[.shared]}) | from_entries) as $byref
  | [$refs[] | .name] | unique | map(
      . as $n
      | ((($gen[$n].values // {}) | keys)
         + [$refs[] | select(.name == $n and .key != "__all__") | .key]
         + (($sup[$n] // {}) | keys)) | unique as $keys
      | {"name": $n, "type": ($gen[$n].type // "Opaque"),
         "values": ($keys | map(. as $k
           | {"key": $k, "value": ($sup[$n][$k] // $byref[$n + "/" + $k] // $gen[$n].values[$k] // null)})
           | from_entries)})
' "$(native_path "$WORK/refs.yaml")" > "$WORK/result.json"

random_alnum() { openssl rand -base64 $(( $1 * 2 )) | tr -dc 'A-Za-z0-9' | cut -c "1-$1"; }

# Generated here when no render produced them. The config-sync cache key lives in
# an operator-named Secret on this path (32 random bytes, base64: an AES-256 key);
# a shared credential the chart registers as random but did not render for these
# values follows its registry row.
for ref in $(yq -r '.[] | .name as $n | .values | to_entries[] | select(.value == null) | $n + "/" + .key' "$(native_path "$WORK/result.json")" | tr -d '\r'); do
  row="$(grep -F "$ref " "$WORK/registry.txt" | head -1 || true)"
  case "${ref#*/}" in
    CONFIG_SYNC_LKG_KEY) value="$(openssl rand -base64 32 | tr -d '\r\n')" ;;
    *)
      case "$row" in
        *" random "*|*" install "*) value="$(random_alnum "${row##* }")" ;;
        *) continue ;;
      esac ;;
  esac
  SNAME="${ref%%/*}" SKEY="${ref#*/}" SVAL="$value" yq -i -o=json \
    '(.[] | select(.name == strenv(SNAME)) | .values[strenv(SKEY)]) = strenv(SVAL)' "$(native_path "$WORK/result.json")"
done

# Optional integrations are reported, not emitted.
OPTIONAL_FOUND=""
for ref in $(yq -r '.[] | .name as $n | .values | to_entries[] | select(.value == null) | $n + "/" + .key' "$(native_path "$WORK/result.json")" | tr -d '\r'); do
  sname="${ref%%/*}"
  case " $OPTIONAL_SECRETS $OPTIONAL_KEYS " in
    *" $sname "*|*" $ref "*)
      OPTIONAL_FOUND="$OPTIONAL_FOUND $ref"
      SNAME="$sname" SKEY="${ref#*/}" yq -i -o=json \
        '(.[] | select(.name == strenv(SNAME)) | .values) |= del(.[strenv(SKEY)])' "$(native_path "$WORK/result.json")" ;;
  esac
done
yq -i -o=json 'map(select((.values | length) > 0))' "$(native_path "$WORK/result.json")"
RESULT="$(native_path "$WORK/result.json")"
MISSING="$(yq -r '.[] | .name as $n | .values | to_entries[] | select(.value == null) | $n + "/" + .key' "$RESULT" | tr -d '\r')"

report() {
  local count
  count="$(yq '[.[] | .values | keys | .[]] | length' "$RESULT")"
  info ""
  info "$(yq 'length' "$RESULT") Secrets, $count keys, for namespace $NAMESPACE."
  if [ -n "$MISSING" ]; then
    info ""
    info "Only you can supply these. Pass each with --secret NAME/KEY=VALUE, or create it yourself:"
    for ref in $MISSING; do info "  $ref"; done
  fi
  if [ -n "$OPTIONAL_FOUND" ]; then
    info ""
    info "Optional, only if you use the integration (not included):"
    for ref in $OPTIONAL_FOUND; do info "  $ref"; done
  fi
  if [ -n "$PULL_SECRETS" ]; then
    info ""
    info "Image pull Secrets, not included: $PULL_SECRETS"
  fi
  info ""
  info "Install with global.autoGenerateSecrets: false and global.preserveExistingSecrets: true."
}

# --- print -------------------------------------------------------------------
if [ "$COMMAND" = print ]; then
  if [ "$OUTPUT" = json ]; then
    P="$PLACEHOLDER" yq -o=json 'map({"key": .name, "value": (.values | map_values(. // strenv(P)))}) | from_entries' "$RESULT"
  else
    P="$PLACEHOLDER" NS="$NAMESPACE" yq -o=yaml -P '.[]
      | {"apiVersion": "v1", "kind": "Secret",
         "metadata": {"name": .name, "namespace": strenv(NS)},
         "type": .type, "stringData": (.values | map_values(. // strenv(P)))}
      | split_doc' "$RESULT"
  fi
  report
  info "The output holds live credentials: store it as you would the Secrets themselves."
  exit 0
fi

# --- apply -------------------------------------------------------------------
KUBECTL=(kubectl)
[ -z "$KUBE_CONTEXT" ] || KUBECTL+=(--context "$KUBE_CONTEXT")

if ! "${KUBECTL[@]}" get namespace "$NAMESPACE" >/dev/null 2>&1; then
  info "Creating namespace $NAMESPACE"
  "${KUBECTL[@]}" create namespace "$NAMESPACE" >/dev/null
fi

for name in $(yq -r '.[].name' "$RESULT" | tr -d '\r'); do
  if "${KUBECTL[@]}" get secret "$name" -n "$NAMESPACE" >/dev/null 2>&1; then
    existing="$("${KUBECTL[@]}" get secret "$name" -n "$NAMESPACE" -o json | yq -r '(.data // {}) | keys | .[]' | tr -d '\r')"
    add=""
    for key in $(N="$name" yq -r '.[] | select(.name == strenv(N)) | .values | to_entries[] | select(.value != null) | .key' "$RESULT" | tr -d '\r'); do
      printf '%s\n' "$existing" | grep -Fqx "$key" || add="$add$key"$'\n'
    done
    if [ -z "$add" ]; then
      info "  unchanged  $name"
      continue
    fi
    patch="$(N="$name" A="$add" yq -o=json -I=0 '(strenv(A) | split("\n")) as $add
      | .[] | select(.name == strenv(N))
      | {"stringData": (.values | with_entries(select(.key as $k | $add | any_c(. == $k))))}' "$RESULT")"
    "${KUBECTL[@]}" patch secret "$name" -n "$NAMESPACE" --type merge -p "$patch" >/dev/null
    info "  added      $name: $(printf '%s' "$add" | tr '\n' ' ')"
  else
    # Holding only values you have not supplied yet: an empty Secret would look done.
    if [ "$(N="$name" yq '.[] | select(.name == strenv(N)) | [.values[] | select(. != null)] | length' "$RESULT")" = "0" ]; then
      info "  skipped    $name: no value yet"
      continue
    fi
    N="$name" NS="$NAMESPACE" yq -o=json '.[] | select(.name == strenv(N))
      | {"apiVersion": "v1", "kind": "Secret",
         "metadata": {"name": .name, "namespace": strenv(NS)},
         "type": .type, "stringData": (.values | with_entries(select(.value != null)))}' "$RESULT" \
      | "${KUBECTL[@]}" create -f - >/dev/null
    info "  created    $name"
  fi
done

# A key only you can supply counts as done once the cluster has it.
LEFT=""
for ref in $MISSING; do
  sname="${ref%%/*}"; skey="${ref#*/}"
  "${KUBECTL[@]}" get secret "$sname" -n "$NAMESPACE" -o json 2>/dev/null \
    | K="$skey" yq -e '.data | has(strenv(K))' >/dev/null 2>&1 || LEFT="$LEFT $ref"
done
MISSING="$LEFT"
report
[ -z "$MISSING" ] || exit 2
