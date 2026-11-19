#!/usr/bin/env bash
# Render scenarios 41, 41b, 41c, 41d, 41e. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

# global.podLabels and global.podAnnotations reach every pod the chart renders —
# Deployments, StatefulSets, hook Jobs and CronJobs alike. A workload that misses
# one is the workload a label-based NetworkPolicy isolates, or the one a mesh
# never injects. They land on the pod template only: a selector is immutable,
# and a label added to it would fail the upgrade.
PM_FILE="$TMP/pod-metadata.yaml"
cat > "$PM_FILE" <<'EOF'
global:
  podLabels:
    example.com/flow: platform
  podAnnotations:
    example.com/owner: platform-team
  jobs:
    podAnnotations:
      sidecar.istio.io/inject: "false"
  firewall:
    deploy: true
clickhouse:
  backup:
    enabled: true
EOF

# Lists kind/name of every pod-bearing object missing the global label or
# annotation.
unlabelled() {
  yq eval '
    select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet" or .kind == "Job" or .kind == "CronJob")
    | (.spec.template.metadata // .spec.jobTemplate.spec.template.metadata) as $m
    | select(($m.labels["example.com/flow"] // "") != "platform" or ($m.annotations["example.com/owner"] // "") != "platform-team")
    | .kind + "/" + .metadata.name' "$1" | sed '/^$/d;/^---$/d'
}

workload_count() {
  yq eval 'select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet" or .kind == "Job" or .kind == "CronJob") | .metadata.name' "$1" \
    | sed '/^$/d;/^---$/d' | wc -l | tr -d ' '
}

assert_all_labelled() {
  local file="$1" label="$2" missing
  missing="$(unlabelled "$file")"
  if [[ -n "$missing" ]]; then
    red "FAIL: $label: every workload carries the global pod label and annotation"
    red "  missing on: $(echo "$missing" | tr '\n' ' ')"
    exit 1
  fi
  green "ok  - $label: all $(workload_count "$file") workloads carry the global pod label and annotation"
}

# The Jobs layer lands on Job and CronJob pods, and nowhere else.
assert_jobs_layer() {
  local file="$1" label="$2" wrong
  wrong="$(yq eval '
    select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet" or .kind == "Job" or .kind == "CronJob")
    | (.spec.template.metadata // .spec.jobTemplate.spec.template.metadata) as $m
    | (.kind == "Job" or .kind == "CronJob") as $isJob
    | ($m.annotations["sidecar.istio.io/inject"] // "") as $v
    | select(($isJob and $v != "false") or (($isJob | not) and $v != ""))
    | .kind + "/" + .metadata.name' "$file" | sed '/^$/d;/^---$/d')"
  if [[ -n "$wrong" ]]; then
    red "FAIL: $label: global.jobs annotations reach Job pods only"
    red "  wrong on: $(echo "$wrong" | tr '\n' ' ')"
    exit 1
  fi
  green "ok  - $label: global.jobs annotations reach Job pods only"
}

assert_has_workload() {
  local file="$1" kind="$2" pattern="$3" msg="$4" names
  # Captured first: grep -q closing the pipe early fails yq under pipefail.
  names="$(yq eval "select(.kind == \"$kind\") | .metadata.name" "$file")"
  if ! grep -Eq "$pattern" <<<"$names"; then
    red "FAIL: $msg"
    red "  no $kind matching $pattern in the render"
    exit 1
  fi
  green "ok  - $msg"
}

blue "==> Scenario 41: global pod labels and annotations reach every workload"
out41="$TMP/pm-external.yaml"
render_default "$out41" -f "$CHART_DIR/values-external.yaml.example" -f "$PM_FILE" \
  --set global.secrets.generator.enabled=true
assert_has_workload "$out41" Job 'secrets-generator$' "pod metadata: the secrets-generator hook Job renders"
assert_has_workload "$out41" Job '^control-plane-postgresql-bootstrap' "pod metadata: the PostgreSQL bootstrap Job renders"
assert_has_workload "$out41" CronJob '^clickhouse-backup$' "pod metadata: the ClickHouse backup CronJob renders"
assert_all_labelled "$out41" "external"
assert_jobs_layer "$out41" "external"

out41k="$TMP/pm-external-keygen.yaml"
render_default "$out41k" -f "$CHART_DIR/values-external.yaml.example" -f "$PM_FILE"
assert_has_workload "$out41k" Job 'agentgateway-m2m-keys$' "pod metadata: the m2m keygen hook Job renders"
assert_all_labelled "$out41k" "external, generator off"
assert_jobs_layer "$out41k" "external, generator off"

out41h="$TMP/pm-hybrid.yaml"
render_default "$out41h" -f "$PM_FILE"
assert_has_workload "$out41h" Deployment '^dataagent' "pod metadata: hybrid renders DataAgent"
assert_all_labelled "$out41h" "hybrid"

out41s="$TMP/pm-saas.yaml"
render_default "$out41s" -f "$PM_FILE" --set global.deploymentMode=saas --set global.domain=cp.example.com \
  --set watchdog.enabled=true --set global.observability.enabled=true
assert_has_workload "$out41s" Deployment '^databridge$' "pod metadata: saas renders DataBridge"
assert_has_workload "$out41s" Deployment '^otel-collector$' "pod metadata: the umbrella OTel collector renders"
assert_has_workload "$out41s" StatefulSet '^neuraltrust-watchdog$' "pod metadata: watchdog renders"
assert_all_labelled "$out41s" "saas with watchdog and the collector"

blue "==> Scenario 41b: selectors do not move"
selectors() {
  yq eval 'select(.kind == "Deployment" or .kind == "StatefulSet") | .kind + "/" + .metadata.name + " " + (.spec.selector | tojson)' "$1" \
    | sed '/^$/d;/^---$/d' | sort
}
out41b="$TMP/pm-external-plain.yaml"
render_default "$out41b" -f "$CHART_DIR/values-external.yaml.example" --set global.firewall.deploy=true \
  --set clickhouse.backup.enabled=true --set global.secrets.generator.enabled=true
if [[ "$(selectors "$out41b")" != "$(selectors "$out41")" ]]; then
  red "FAIL: pod metadata: spec.selector is identical with and without the global maps"
  diff <(selectors "$out41b") <(selectors "$out41") | head -10
  exit 1
fi
green "ok  - pod metadata: spec.selector is identical with and without the global maps"

blue "==> Scenario 41c: a component map wins over global; chart keys win over both"
out41c="$TMP/pm-precedence.yaml"
render_default "$out41c" -f "$CHART_DIR/values-external.yaml.example" -f "$PM_FILE" \
  --set trustguard.podLabels.example\\.com/flow=guard \
  --set watchdog.enabled=true \
  --set watchdog.podAnnotations.prometheus\\.io/scrape=false \
  --set global.azureIdentity.method=workload-identity
tg="$TMP/pm-tg-data.yaml"
document_named_kind "$out41c" Deployment trustguard-data-plane "$tg"
assert_contains "$tg" '"example.com/flow": "guard"' "pod metadata: trustguard.podLabels overrides global.podLabels"
assert_contains "$tg" 'azure.workload.identity/use: "true"' "pod metadata: the Azure marker still renders beside operator labels"
ag="$TMP/pm-ag-proxy.yaml"
document_named_kind "$out41c" Deployment agentgateway-proxy "$ag"
assert_contains "$ag" '"example.com/flow": "platform"' "pod metadata: other components keep the global value"
wd="$TMP/pm-watchdog.yaml"
document_named_kind "$out41c" StatefulSet neuraltrust-watchdog "$wd"
assert_contains "$wd" 'prometheus.io/scrape: "true"' "pod metadata: watchdog's scrape annotation wins over the operator map"
assert_occurrences "$wd" 'prometheus.io/scrape' 1 "pod metadata: watchdog renders the scrape key once"

blue "==> Scenario 41d: keys a selector or the chart owns fail the render"
assert_render_fails_with 'global.podLabels: "app.kubernetes.io/name" is set by the chart' \
  "pod metadata: global.podLabels refuses app.kubernetes.io/*" \
  --set global.podLabels.app\\.kubernetes\\.io/name=x
assert_render_fails_with 'control-plane-api.podLabels: "app" is set by the chart' \
  "pod metadata: a component map refuses the app selector key" \
  --set control-plane-api.podLabels.app=x
assert_render_fails_with 'global.jobs.podAnnotations: "checksum/x" is reserved' \
  "pod metadata: global.jobs.podAnnotations refuses checksum/*" \
  --set global.jobs.podAnnotations.checksum/x=y

blue "==> Scenario 41e: the bootstrap Job name tracks pod metadata only when it is set"
# Job pod templates are immutable, so the name hashes the pod inputs. Unset maps
# must not enter the hash (no rename on upgrade for installs that never set
# them); setting one must rename the Job so Helm replaces it.
bootstrap_name() {
  yq eval 'select(.kind == "Job") | .metadata.name' "$1" | grep '^control-plane-postgresql-bootstrap'
}
out41e_off="$TMP/pm-bootstrap-off.yaml"
out41e_empty="$TMP/pm-bootstrap-empty.yaml"
out41e_on="$TMP/pm-bootstrap-on.yaml"
render_default "$out41e_off" -f "$CHART_DIR/values-external.yaml.example" --set global.secrets.generator.enabled=true
render_default "$out41e_empty" -f "$CHART_DIR/values-external.yaml.example" --set global.secrets.generator.enabled=true \
  --set-json 'global.podLabels={}' --set-json 'global.jobs={"podAnnotations":{}}'
render_default "$out41e_on" -f "$CHART_DIR/values-external.yaml.example" --set global.secrets.generator.enabled=true \
  --set global.podLabels.example\\.com/flow=platform
if [[ "$(bootstrap_name "$out41e_off")" != "$(bootstrap_name "$out41e_empty")" ]]; then
  red "FAIL: pod metadata: empty maps keep the bootstrap Job name"
  exit 1
fi
green "ok  - pod metadata: empty maps keep the bootstrap Job name"
if [[ "$(bootstrap_name "$out41e_off")" == "$(bootstrap_name "$out41e_on")" ]]; then
  red "FAIL: pod metadata: setting global.podLabels renames the bootstrap Job"
  exit 1
fi
green "ok  - pod metadata: setting global.podLabels renames the bootstrap Job"
