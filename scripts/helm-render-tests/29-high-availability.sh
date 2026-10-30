#!/usr/bin/env bash
# Render scenarios 40, 40b, 40c, 40d, 40e. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

blue "==> Scenario 40: high availability — spread by default, budgets opt-in"

# Zone/node spread is a chart default: ScheduleAnyway, so it is a preference and
# cannot wedge scheduling on a single-zone cluster. Before this existed,
# agentgateway and trustguard had no spread support at all.
out40="$TMP/ha-default.yaml"
render_default "$out40"

for wl in agentgateway-proxy trustguard-data-plane; do
  doc="$TMP/ha-$wl.yaml"
  # Deployment, not the same-named Service that helm emits ahead of it.
  document_named_kind "$out40" Deployment "$wl" "$doc"
  assert_contains "$doc" 'topologyKey: topology\.kubernetes\.io/zone' \
    "ha: $wl spreads across zones by default"
  assert_contains "$doc" 'topologyKey: kubernetes\.io/hostname' \
    "ha: $wl spreads across nodes by default"
  assert_contains "$doc" 'whenUnsatisfiable: ScheduleAnyway' \
    "ha: $wl spread is a preference, not a scheduling requirement"
done

# Names the PodDisruptionBudgets in a render, space separated.
pdb_names() {
  yq eval 'select(.kind == "PodDisruptionBudget") | .metadata.name' "$1" \
    | sed '/^$/d;/^null$/d' | sort | tr '\n' ' '
}

assert_pdb_present() {
  local file="$1" name="$2" msg="$3"
  if [[ " $(pdb_names "$file") " != *" $name "* ]]; then
    red "FAIL: $msg"
    red "  no PodDisruptionBudget named $name; got: $(pdb_names "$file")"
    exit 1
  fi
  green "ok  - $msg"
}

assert_pdb_absent() {
  local file="$1" name="$2" msg="$3"
  if [[ " $(pdb_names "$file") " == *" $name "* ]]; then
    red "FAIL: $msg"
    red "  unexpected PodDisruptionBudget named $name"
    exit 1
  fi
  green "ok  - $msg"
}

# Budgets stay opt-in, so an upgrade creates no new objects on its own.
assert_pdb_absent "$out40" agentgateway-proxy \
  "ha: no gateway PDB until the operator asks for one"
assert_pdb_absent "$out40" trustguard-data-plane \
  "ha: no trustguard PDB until the operator asks for one"

# DataBridge sets podDisruptionBudget.enabled itself, so it must keep its PDB
# regardless of the global default — this is the regression that would silently
# remove a budget from an existing cluster. DataBridge is a SaaS-side relay and
# renders in saas mode only, so the default (hybrid) render above cannot carry
# the evidence.
out40_saas="$TMP/ha-default-saas.yaml"
render_default "$out40_saas" --set global.deploymentMode=saas
assert_pdb_present "$out40_saas" databridge \
  "ha: databridge keeps its own PDB when the global switch is off"

blue "==> Scenario 40b: one global switch raises every component"
out40b="$TMP/ha-global-on.yaml"
render_default "$out40b" --set global.highAvailability.podDisruptionBudget.enabled=true
for name in agentgateway-proxy trustguard-data-plane; do
  assert_pdb_present "$out40b" "$name" \
    "ha: global switch renders the $name PDB"
done

blue "==> Scenario 40c: a component can still opt out of the global switch"
out40c="$TMP/ha-optout.yaml"
render_default "$out40c" \
  --set global.highAvailability.podDisruptionBudget.enabled=true \
  --set agentgateway.dataPlane.podDisruptionBudget.enabled=false
assert_pdb_absent "$out40c" agentgateway-proxy \
  "ha: an explicit per-component false overrides a global true"
assert_pdb_present "$out40c" trustguard-data-plane \
  "ha: the opt-out is scoped to that one component"

blue "==> Scenario 40d: a budget never renders on a single replica"
# A PDB over one replica pins disruptionsAllowed at 0 and deadlocks every node
# drain, with no operator in a customer cluster to diagnose it.
out40d="$TMP/ha-singleton.yaml"
render_default "$out40d" \
  --set global.highAvailability.podDisruptionBudget.enabled=true \
  --set agentgateway.dataPlane.replicas=1
assert_pdb_absent "$out40d" agentgateway-proxy \
  "ha: no PDB at one replica, even with the global switch on"

blue "==> Scenario 40e: spread can be turned off"
out40e="$TMP/ha-nospread.yaml"
render_default "$out40e" --set global.highAvailability.topologySpread.enabled=false
doc40e="$TMP/ha-nospread-proxy.yaml"
document_named_kind "$out40e" Deployment agentgateway-proxy "$doc40e"
assert_not_contains "$doc40e" 'topologySpreadConstraints' \
  "ha: topologySpread.enabled=false removes the constraints"
