#!/usr/bin/env bash
# Run through scripts/test-helm-render.sh.
source "$(dirname "$0")/lib.sh"
suite_full || exit 0

# ---------------------------------------------------------------------------
# 49. OpenShift restricted-v2 assigns runAsUser, runAsGroup and fsGroup from
#     the namespace range and rejects any fixed value. An OpenShift render must
#     carry none, for every workload the chart can run there: DataBridge,
#     watchdog, the umbrella OTel collector, ClickHouse and its backup Job, on
#     top of the hook Jobs and PostgreSQL that scenario 47 already covers.
#     The in-cluster Firewall (global.firewall.deploy) is out of scope: it runs
#     as root by default and README-OPENSHIFT.md documents the SCC decision.
# ---------------------------------------------------------------------------
blue "==> Scenario 49: OpenShift renders pin no runAsUser, runAsGroup or fsGroup"

FIXED_ID='^ +(runAsUser|runAsGroup|fsGroup): [0-9]+$'

assert_workload() {
  local file="$1" kind="$2" name="$3" msg="$4" names
  names="$(yq eval "select(.kind == \"$kind\") | .metadata.name" "$file")"
  if ! grep -qx -- "$name" <<<"$names"; then
    red "FAIL: $msg"
    red "  no $kind named $name in the render"
    exit 1
  fi
  green "ok  - $msg"
}

# Every optional workload with a fixed ID on other platforms, in one render:
# saas brings DataBridge and ClickHouse, plus watchdog and the collector.
ALL_ARGS=(
  --set global.deploymentMode=saas
  --set global.domain=cp.example.com
  --set watchdog.enabled=true
  --set global.observability.enabled=true
  --set clickhouse.backup.enabled=true
)

out="$TMP/scenario-49-openshift.yaml"
render_default "$out" "${ALL_ARGS[@]}" \
  --api-versions route.openshift.io/v1 \
  --set global.platform=openshift
for w in Deployment:databridge StatefulSet:neuraltrust-watchdog \
         Deployment:otel-collector StatefulSet:clickhouse CronJob:clickhouse-backup; do
  assert_workload "$out" "${w%%:*}" "${w##*:}" "openshift: ${w##*:} renders"
done
assert_not_contains "$out" "$FIXED_ID" \
  "openshift: no workload pins runAsUser, runAsGroup or fsGroup"
assert_contains "$out" 'runAsNonRoot: true' \
  "openshift: workloads still require a non-root UID"

# The legacy flag selects OpenShift the same way, ClickHouse included.
out_legacy="$TMP/scenario-49-openshift-legacy.yaml"
render_default "$out_legacy" "${ALL_ARGS[@]}" \
  --api-versions route.openshift.io/v1 \
  --set global.openshift=true
assert_not_contains "$out_legacy" "$FIXED_ID" \
  "openshift (legacy global.openshift flag): no workload pins a fixed ID"

# An ID the operator chose for their own SCC is kept.
out_override="$TMP/scenario-49-openshift-override.yaml"
render_default "$out_override" "${ALL_ARGS[@]}" \
  --api-versions route.openshift.io/v1 \
  --set global.platform=openshift \
  --set watchdog.podSecurityContext.runAsUser=1000690000
wd="$TMP/scenario-49-watchdog.yaml"
document_named_kind "$out_override" StatefulSet neuraltrust-watchdog "$wd"
assert_contains "$wd" '^        runAsUser: 1000690000$' \
  "openshift: an operator-set watchdog runAsUser is kept"
assert_not_contains "$wd" '^        fsGroup: 65532$' \
  "openshift: the chart-default watchdog fsGroup is still dropped"

# Other platforms keep the images' fixed IDs.
out_k8s="$TMP/scenario-49-kubernetes.yaml"
render_default "$out_k8s" "${ALL_ARGS[@]}"
doc="$TMP/scenario-49-databridge-k8s.yaml"
document_named_kind "$out_k8s" Deployment databridge "$doc"
assert_contains "$doc" '^        fsGroup: 65532$' "kubernetes: DataBridge keeps fsGroup 65532"
assert_contains "$doc" '^            runAsUser: 65532$' "kubernetes: DataBridge keeps runAsUser 65532"
doc="$TMP/scenario-49-watchdog-k8s.yaml"
document_named_kind "$out_k8s" StatefulSet neuraltrust-watchdog "$doc"
assert_contains "$doc" '^        runAsUser: 65532$' "kubernetes: watchdog keeps runAsUser 65532"
assert_contains "$doc" '^        fsGroup: 65532$' "kubernetes: watchdog keeps fsGroup 65532"
doc="$TMP/scenario-49-collector-k8s.yaml"
document_named_kind "$out_k8s" Deployment otel-collector "$doc"
assert_contains "$doc" '^        runAsUser: 10001$' "kubernetes: OTel collector keeps runAsUser 10001"
doc="$TMP/scenario-49-clickhouse-k8s.yaml"
document_named_kind "$out_k8s" StatefulSet clickhouse "$doc"
assert_contains "$doc" '^        runAsUser: 101$' "kubernetes: ClickHouse keeps runAsUser 101"
doc="$TMP/scenario-49-clickhouse-backup-k8s.yaml"
document_named_kind "$out_k8s" CronJob clickhouse-backup "$doc"
assert_contains "$doc" '^            runAsUser: 101$' "kubernetes: ClickHouse backup keeps runAsUser 101"
