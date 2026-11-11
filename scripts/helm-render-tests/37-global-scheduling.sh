#!/usr/bin/env bash
# Render scenarios 37, 37b, 37c, 37d. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

# global.nodeSelector, global.tolerations and global.affinity reach every pod the
# chart renders — Deployments, StatefulSets, hook Jobs and CronJobs alike. A
# workload that misses one breaks the "every pod on pool X" placement an operator
# asks for, and a hook Job that misses one can block helm upgrade or an Argo sync
# on a cluster where every other pool is tainted.
SCHED_FILE="$TMP/global-scheduling.yaml"
cat > "$SCHED_FILE" <<'EOF'
global:
  nodeSelector:
    pool: cpu
  tolerations:
    - key: dedicated
      operator: Equal
      value: platform
      effect: NoSchedule
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: pool
                operator: In
                values: [cpu]
              - key: topology.kubernetes.io/zone
                operator: In
                values: [zone-a]
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 50
          podAffinityTerm:
            topologyKey: kubernetes.io/hostname
            labelSelector:
              matchLabels:
                tenant: other
  firewall:
    deploy: true
clickhouse:
  backup:
    enabled: true
firewall:
  firewall:
    workerDefaults:
      nodeSelector:
        pool: gpu
EOF

# Lists kind/name of every pod-bearing object missing a global scheduling key.
# Firewall workers carry their selector as a required nodeAffinity instead of a
# nodeSelector (37c pins what it contains), so either one counts.
unscheduled() {
  yq eval '
    select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet" or .kind == "Job" or .kind == "CronJob")
    | (.spec.template.spec // .spec.jobTemplate.spec.template.spec) as $p
    | select(
        ($p.tolerations // [] | length) == 0
        or ($p.affinity.podAntiAffinity // {} | length) == 0
        or (($p.nodeSelector // {} | length) == 0 and ($p.affinity.nodeAffinity // {} | length) == 0))
    | .kind + "/" + .metadata.name' "$1" | sed '/^$/d;/^---$/d'
}

workload_count() {
  yq eval 'select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet" or .kind == "Job" or .kind == "CronJob") | .metadata.name' "$1" \
    | sed '/^$/d;/^---$/d' | wc -l | tr -d ' '
}

assert_all_scheduled() {
  local file="$1" label="$2" missing
  missing="$(unscheduled "$file")"
  if [[ -n "$missing" ]]; then
    red "FAIL: $label: every workload carries the global scheduling keys"
    red "  missing on: $(echo "$missing" | tr '\n' ' ')"
    exit 1
  fi
  green "ok  - $label: all $(workload_count "$file") workloads carry the global scheduling keys"
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

blue "==> Scenario 37: external with the secrets generator — workloads, generator and bootstrap Jobs, backup CronJob"
out37="$TMP/sched-external.yaml"
render_default "$out37" -f "$CHART_DIR/values-external.yaml.example" -f "$SCHED_FILE" \
  --set global.secrets.generator.enabled=true
assert_has_workload "$out37" Job 'secrets-generator$' "sched: the secrets-generator hook Job renders"
assert_has_workload "$out37" Job '^control-plane-postgresql-bootstrap' "sched: the PostgreSQL bootstrap Job renders"
assert_has_workload "$out37" CronJob '^clickhouse-backup$' "sched: the ClickHouse backup CronJob renders"
assert_all_scheduled "$out37" "external"

blue "==> Scenario 37b: external without the generator — keygen hook Jobs; hybrid — DataAgent"
out37b="$TMP/sched-external-keygen.yaml"
render_default "$out37b" -f "$CHART_DIR/values-external.yaml.example" -f "$SCHED_FILE"
assert_has_workload "$out37b" Job 'agentgateway-m2m-keys$' "sched: the m2m keygen hook Job renders"
assert_has_workload "$out37b" Job 'mcp-signing-key$' "sched: the MCP signing-key hook Job renders"
assert_all_scheduled "$out37b" "external, generator off"

out37b_hy="$TMP/sched-hybrid.yaml"
render_default "$out37b_hy" -f "$SCHED_FILE"
assert_has_workload "$out37b_hy" Deployment '^dataagent' "sched: hybrid renders DataAgent"
assert_all_scheduled "$out37b_hy" "hybrid"

blue "==> Scenario 37c: a Firewall worker's own selector wins over global.affinity on the same key"
worker="$TMP/sched-worker.yaml"
document_named_kind "$out37" Deployment toxicity-worker "$worker"
terms="$(yq eval '.spec.template.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms' "$worker")"
pool_values="$(yq eval '[.spec.template.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[].matchExpressions[] | select(.key == "pool") | .values[]] | join(",")' "$worker")"
if [[ "$pool_values" != "gpu" ]]; then
  red "FAIL: sched: worker requires pool=gpu only (global pool=cpu dropped on the worker's key)"
  red "  got pool values: $pool_values"
  red "$terms"
  exit 1
fi
green "ok  - sched: worker requires pool=gpu only (global pool=cpu dropped on the worker's key)"
zone_values="$(yq eval '[.spec.template.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[].matchExpressions[] | select(.key == "topology.kubernetes.io/zone") | .values[]] | join(",")' "$worker")"
if [[ "$zone_values" != "zone-a" ]]; then
  red "FAIL: sched: worker keeps the global zone requirement on other keys"
  red "$terms"
  exit 1
fi
green "ok  - sched: worker keeps the global zone requirement on other keys"

blue "==> Scenario 37d: the bootstrap Job name tracks global.affinity only when it is set"
# Job pod templates are immutable, so the name hashes the pod inputs. An unset
# global.affinity must not enter the hash (no rename on upgrade for installs
# that never set it); setting one must rename the Job so Helm replaces it.
bootstrap_name() {
  yq eval 'select(.kind == "Job") | .metadata.name' "$1" | grep '^control-plane-postgresql-bootstrap'
}
out37d_off="$TMP/sched-bootstrap-off.yaml"
out37d_empty="$TMP/sched-bootstrap-empty.yaml"
out37d_on="$TMP/sched-bootstrap-on.yaml"
render_default "$out37d_off" -f "$CHART_DIR/values-external.yaml.example" --set global.secrets.generator.enabled=true
render_default "$out37d_empty" -f "$CHART_DIR/values-external.yaml.example" --set global.secrets.generator.enabled=true \
  --set-json 'global.affinity={}'
render_default "$out37d_on" -f "$CHART_DIR/values-external.yaml.example" --set global.secrets.generator.enabled=true \
  --set-json 'global.affinity={"podAntiAffinity":{"preferredDuringSchedulingIgnoredDuringExecution":[{"weight":1,"podAffinityTerm":{"topologyKey":"kubernetes.io/hostname"}}]}}'
if [[ "$(bootstrap_name "$out37d_off")" != "$(bootstrap_name "$out37d_empty")" ]]; then
  red "FAIL: sched: an empty global.affinity keeps the bootstrap Job name"
  exit 1
fi
green "ok  - sched: an empty global.affinity keeps the bootstrap Job name"
if [[ "$(bootstrap_name "$out37d_off")" == "$(bootstrap_name "$out37d_on")" ]]; then
  red "FAIL: sched: setting global.affinity renames the bootstrap Job"
  exit 1
fi
green "ok  - sched: setting global.affinity renames the bootstrap Job"
