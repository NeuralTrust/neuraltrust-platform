#!/usr/bin/env bash
# Render scenarios 38, 38b, 38c. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

# A hybrid install with the secrets generator is the GitOps path: Argo CD and
# Flux render with `helm template`, which cannot `lookup`. Whatever the render
# reads from the live cluster comes back empty there, so a field built from a
# lookup differs from the live object, the Application never settles, and a
# sync writes the empty value over the live one. These scenarios pin that the
# hybrid render depends on values alone.

blue "==> Scenario 38: hybrid with the generator renders the same twice (no lookup in redis-secrets or its checksum)"
out38a="$TMP/hybrid-gen-a.yaml"
out38b="$TMP/hybrid-gen-b.yaml"
render_default "$out38a" --set global.secrets.generator.enabled=true
render_default "$out38b" --set global.secrets.generator.enabled=true
if ! diff -q "$out38a" "$out38b" >/dev/null; then
  red "FAIL: hybrid + generator: two renders are byte-identical"
  diff "$out38a" "$out38b" | head -20 | while IFS= read -r line; do red "  > $line"; done
  exit 1
fi
green "ok  - hybrid + generator: two renders are byte-identical"
redis38="$TMP/hybrid-gen-redis.yaml"
document_named_kind "$out38a" Secret redis-secrets "$redis38"
assert_contains "$redis38" '^  REDIS_PASSWORD: *("")?$' "hybrid + generator: redis-secrets takes REDIS_PASSWORD from values only (none set: empty)"

blue "==> Scenario 38b: the generator Job guards a password only the live redis-secrets holds"
gen38="$TMP/hybrid-gen-job.yaml"
document_named_kind "$out38a" Job neuraltrust-platform-secrets-generator "$gen38"
assert_contains "$gen38" 'name: PASSWORD_GUARD' "guard: the generator Job checks redis-secrets when values carry no Redis password"
assert_contains "$out38a" '"redis-secrets"' "guard: the generator Role may read redis-secrets"
# A managed Redis whose password is in values, or in the operator's Secret.
managed38=(--set global.redis.deploy=false --set global.redis.host=cache.example.com)
for case in "global.redis.password=from-values" "global.redis.existingSecret.name=my-redis"; do
  out="$TMP/hybrid-gen-${case%%=*}.yaml"
  render_default "$out" --set global.secrets.generator.enabled=true "${managed38[@]}" --set "$case"
  assert_not_contains "$out" 'name: PASSWORD_GUARD' "guard: off with $case (values own the password)"
done
out38off="$TMP/hybrid-nogen.yaml"
render_default "$out38off"
assert_not_contains "$out38off" 'name: PASSWORD_GUARD' "guard: off without the generator (the Helm path adopts the live password)"

blue "==> Scenario 38c: the DataAgent gate reads values, not the cluster"
# With the chart creating no Secrets, the operator supplies them (create-secrets.sh
# renders them from these values). An enrolment token in values is then enough;
# before, the gate looked the live Secret up, so `helm template` dropped DataAgent.
out38c="$TMP/hybrid-preserve.yaml"
render_default "$out38c" --set global.preserveExistingSecrets=true \
  --set agentgateway.dataagent.enrolment.existingSecret.name= --set agentgateway.dataagent.enrolment.token=example-token \
  --set trustguard.dataagent.enrolment.existingSecret.name= --set trustguard.dataagent.enrolment.token=example-token
# Captured first: grep -q closing the pipe early fails yq under pipefail.
agents38c="$(yq eval 'select(.kind == "Deployment") | .metadata.name' "$out38c")"
if ! grep -Eq '^dataagent' <<<"$agents38c"; then
  red "FAIL: gate: preserveExistingSecrets with an enrolment token in values renders DataAgent"
  red "  Deployments: $(echo "$agents38c" | sed '/^---$/d' | tr '\n' ' ')"
  exit 1
fi
green "ok  - gate: preserveExistingSecrets with an enrolment token in values renders DataAgent"

blue "==> Scenario 38d: the guard stops the Job on a password only the live redis-secrets holds"
# The rendered program runs against an in-memory API (fake-kube-api.js): a live
# redis-secrets with a password must stop it before it writes anything; an empty
# one, the passwordless in-cluster default, must not.
if command -v node >/dev/null 2>&1; then
  ruby -ryaml -e '
    docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
    job = docs.find { |d| d["kind"] == "Job" && d.dig("metadata", "name").to_s.end_with?("secrets-generator") }
    File.write(ARGV.fetch(1), job.dig("spec", "template", "spec", "containers", 0, "command").last)
  ' "$out38a" "$TMP/guard-generator.js"
  run_guarded() {
    FAKE_STATE="$1" GENERATED_SECRET=platform-secrets SPEC_COMPONENTS="" \
      SPEC_LABEL=neuraltrust.ai/generator-spec SPEC_FORMAT=2 PREVIOUS_SECRET=neuraltrust-generated \
      MARKER=neuraltrust.ai/secrets-generator PASSWORD_GUARD=redis-secrets \
      node --require "$(cd "$(dirname "$0")" && pwd)/fake-kube-api.js" "$TMP/guard-generator.js"
  }
  printf '{"secrets": {"redis-secrets": {"metadata": {}, "data": {"REDIS_PASSWORD": "%s"}}}}' "$(printf 'live-only' | base64)" > "$TMP/guard-held.json"
  if run_guarded "$TMP/guard-held.json" > "$TMP/guard-held.log" 2>&1; then
    red "FAIL: guard: a password only the live redis-secrets holds stops the generator Job"
    exit 1
  fi
  assert_contains "$TMP/guard-held.log" 'global.redis.existingSecret.name' "guard: a password only the live redis-secrets holds stops the Job, naming the fix"
  if ruby -rjson -e 'exit((JSON.parse(File.read(ARGV[0]))["log"] || []).empty?)' "$TMP/guard-held.json"; then
    green "ok  - guard: the stopped Job wrote nothing"
  else
    red "FAIL: guard: the stopped Job wrote nothing"
    exit 1
  fi
  printf '{"secrets": {"redis-secrets": {"metadata": {}, "data": {"REDIS_PASSWORD": ""}}}}' > "$TMP/guard-empty.json"
  run_guarded "$TMP/guard-empty.json" > "$TMP/guard-empty.log" 2>&1 \
    || { red "FAIL: guard: an empty live password (passwordless default) lets the Job run"; sed 's/^/  /' "$TMP/guard-empty.log"; exit 1; }
  green "ok  - guard: an empty live password (passwordless default) lets the Job run"
else
  yellow "skip - node not available to run the generator guard"
fi
