#!/usr/bin/env bash
# Render scenarios 1d, 1e. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

# Config-sync fail-closed (hybrid default-on) and writable LKG storage
blue "==> Scenario 1d: config-sync token references and LKG storage"
assert_render_fails "hybrid config-sync without a token source fails render" \
  --set agentgateway.configSync.existingSecret.name= \
  --set trustguard.configSync.existingSecret.name=
out1d="$TMP/scenario-hybrid-config-sync.yaml"
render_default "$out1d"
assert_contains "$out1d" 'name: "?agentgateway-config-sync"?' \
  "config-sync: TrustGate references its operator-owned token Secret"
assert_contains "$out1d" 'name: "?trustguard-config-sync"?' \
  "config-sync: TrustGuard references its operator-owned token Secret"
assert_not_contains "$out1d" 'key: "?CONFIG_SYNC_LKG_KEY"?' \
  "config-sync: the operator token Secret is not asked for the LKG key"
assert_contains "$out1d" 'CONFIG_SYNC_LKG_KEY: "' \
  "config-sync: the chart-managed Secret generates the LKG key instead"
assert_contains "$out1d" 'mountPath: /var/lib/trustgate' \
  "config-sync: TrustGate LKG path is writable"
assert_contains "$out1d" 'mountPath: /var/lib/trustguard' \
  "config-sync: TrustGuard LKG path is writable"
assert_contains "$out1d" 'name: CONFIG_SYNC_DATA_PLANE_ENABLED'$'\n''          value: "true"' \
  "config-sync: hybrid defaults enable data-plane sync"
assert_render_fails "inline config-sync token fails when auto-generation is disabled" \
  --set global.autoGenerateSecrets=false \
  --set agentgateway.configSync.existingSecret.name= \
  --set agentgateway.configSync.token=inline-test-token \
  --set agentgateway.dataagent.existingSecret.name=dataagent-trustgate-secrets \
  --set trustguard.dataagent.existingSecret.name=dataagent-trustguard-secrets
assert_render_fails "inline config-sync token fails when managed Secrets are preserved" \
  --set global.preserveExistingSecrets=true \
  --set agentgateway.configSync.existingSecret.name= \
  --set agentgateway.configSync.token=inline-test-token
out1e="$TMP/scenario-config-sync-inline-upgrade.yaml"
render_default "$out1e" --is-upgrade \
  --set agentgateway.configSync.existingSecret.name= \
  --set agentgateway.configSync.token=inline-test-token
assert_contains "$out1e" 'name: agentgateway-secrets' \
  "config-sync upgrade: inline token forces managed Secret rendering"
assert_contains "$out1e" 'CONFIG_SYNC_TOKEN: "inline-test-token"' \
  "config-sync upgrade: managed Secret carries the inline token"
assert_contains "$out1e" 'CONFIG_SYNC_LKG_KEY:' \
  "config-sync upgrade: managed Secret carries an LKG encryption key"

# The gate is decided by Secret ownership alone. Renaming the key must not
# resurrect the reference on the owned path, or a rename would quietly demand a
# key from a Secret the operator was told not to put one in.
out1d2="$TMP/scenario-config-sync-custom-lkg-key.yaml"
render_default "$out1d2" \
  --set agentgateway.configSync.existingSecret.lkgKey=MY_LKG_KEY
assert_contains "$out1d2" 'key: "?CONFIG_SYNC_TOKEN"?' \
  "config-sync token-only: the UI-issued token still comes from the operator Secret"
assert_not_contains "$out1d2" 'key: "?MY_LKG_KEY"?' \
  "config-sync token-only: a renamed LKG key is not demanded of the operator Secret either"

# The chart owns no Secret under either opt-out, so the pre-2.6 reference is
# retained rather than leaving the runtime with no key at all. Both halves of
# the conjunct are covered: dropping one would strand the other. Counting the
# occurrences catches a partial regression that leaves only some workloads wired.
out1d3="$TMP/scenario-config-sync-no-autogen.yaml"
render_default "$out1d3" \
  --set global.autoGenerateSecrets=false \
  --set agentgateway.dataagent.existingSecret.name=dataagent-trustgate-secrets \
  --set trustguard.dataagent.existingSecret.name=dataagent-trustguard-secrets
assert_occurrences "$out1d3" 'key: "?CONFIG_SYNC_LKG_KEY"?' 3 \
  "config-sync: without chart Secret generation all three data planes take the LKG key from the operator Secret"
out1d4="$TMP/scenario-config-sync-preserve-existing.yaml"
render_default "$out1d4" \
  --set global.preserveExistingSecrets=true \
  --set agentgateway.dataagent.existingSecret.name=dataagent-trustgate-secrets \
  --set trustguard.dataagent.existingSecret.name=dataagent-trustguard-secrets
assert_occurrences "$out1d4" 'key: "?CONFIG_SYNC_LKG_KEY"?' 3 \
  "config-sync: preserveExistingSecrets also leaves the LKG key to the operator Secret"
# The gate must not read the cluster: a lookup-dependent reference renders one
# way under `helm upgrade` and another under `helm template` or ArgoCD. An
# upgrade render must therefore match the install render exactly.
out1d5="$TMP/scenario-config-sync-upgrade-render.yaml"
render_default "$out1d5" --is-upgrade
assert_not_contains "$out1d5" 'key: "?CONFIG_SYNC_LKG_KEY"?' \
  "config-sync: an upgrade render agrees with the install render on the owned path"
# Same principle, the other direction: the managed Secret document itself
# must survive an upgrade render. Gated on "config-sync needs the chart to mint a
# token" it did not, so an operator supplying their own token saw the whole Secret —
# and CONFIG_SYNC_LKG_KEY with it — disappear from `helm diff upgrade`. The live
# upgrade was unaffected; the review diff lied.
assert_contains "$out1d5" 'name: agentgateway-secrets' \
  "config-sync: an upgrade render still emits the managed agentgateway Secret"
assert_contains "$out1d5" 'name: trustguard-secrets' \
  "config-sync: an upgrade render still emits the managed trustguard Secret"
out1d6="$TMP/scenario-config-sync-upgrade-operator-token.yaml"
render_default "$out1d6" --is-upgrade \
  --set agentgateway.configSync.existingSecret.name=my-token \
  --set trustguard.configSync.existingSecret.name=my-token
assert_contains "$out1d6" 'name: agentgateway-secrets' \
  "config-sync: operator-supplied token still leaves the managed Secret in an upgrade render"
assert_contains "$out1d6" 'name: trustguard-secrets' \
  "config-sync: same for trustguard"

blue "==> Scenario 1e: preserved shared PostgreSQL supports DataAgent"
out1f="$TMP/scenario-preserved-shared-postgres.yaml"
render_default "$out1f" \
  --set global.preserveExistingSecrets=true \
  --set global.postgresql.existingSecret.name=external-postgresql
assert_contains "$out1f" 'name: dataagent$' \
  "preserved Secrets: TrustGate DataAgent still renders"
assert_contains "$out1f" 'name: dataagent-trustguard$' \
  "preserved Secrets: TrustGuard DataAgent still renders"
assert_contains "$out1f" 'name: "?external-postgresql"?' \
  "preserved Secrets: DataAgents reference shared PostgreSQL Secret"
assert_not_contains "$out1f" 'name: dataagent-secrets' \
  "preserved Secrets: no unnecessary per-agent Secret reference"
