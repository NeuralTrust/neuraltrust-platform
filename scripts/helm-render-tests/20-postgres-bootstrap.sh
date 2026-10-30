#!/usr/bin/env bash
# Render scenarios 19, 19b. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

blue "==> Scenario 19: PostgreSQL bootstrap Job for the in-cluster instance"

# The Job is the only thing that creates the per-service roles external mode
# expects, so assert on the service list it actually bootstraps, not just on the
# Job being present. Reads the rendered shell rather than guessing: each service
# contributes exactly one bootstrap_service call and one password env entry.
bootstrap_services() {
  ruby -ryaml -e '
    docs = []
    YAML.load_stream(File.read(ARGV.fetch(0), encoding: "UTF-8")) { |d| docs << d if d.is_a?(Hash) }
    # By its app label: the name ends in a hash of what the Job sets up.
    job = docs.find { |d| d["kind"] == "Job" && d.dig("metadata", "labels", "app") == ARGV.fetch(1) }
    exit 0 if job.nil?
    container = job.dig("spec", "template", "spec", "containers").fetch(0)
    script = container["command"].fetch(2)
    calls = script.scan(/^bootstrap_service "([^"]+)" "([^"]+)" "([^"]+)" "([^"]+)" "([^"]+)" "([^"]+)"$/)
    envs = (container["env"] || []).map { |e| e["name"] }
    calls.each do |key, role, db, env_name, secret, secret_key|
      abort "#{key}: #{env_name} is not wired into the pod" unless envs.include?(env_name)
      puts "#{key}:#{role}:#{db}:#{secret}/#{secret_key}"
    end
  ' "$1" "${2:-control-plane-postgresql-bootstrap}"
}

assert_bootstrap() {
  local file="$1" expected="$2" msg="$3" job="${4:-control-plane-postgresql-bootstrap}" got
  got="$(bootstrap_services "$file" "$job" | tr '\n' ' ' | sed 's/ $//')"
  if [[ "$got" != "$expected" ]]; then
    red "FAIL: $msg"
    red "  expected: ${expected:-<no Job>}"
    red "  got:      ${got:-<no Job>}"
    exit 1
  fi
  green "ok  - $msg"
}

out19ext="$TMP/scenario-bootstrap-external.yaml"
render_default "$out19ext" --set global.deploymentMode=external
assert_bootstrap "$out19ext" \
  "agentgateway:agentgateway:agentgateway:agentgateway-secrets/DB_PASSWORD trustguard:trustguard:trustguard:trustguard-secrets/DB_PASSWORD alertengine:alertengine:alertengine:alertengine-secrets/DB_PASSWORD datacore:datacore:datacore:datacore-secrets/POSTGRES_PASSWORD" \
  "external + in-cluster Postgres bootstraps all four per-service roles"
# Not a hook: Helm runs post-install hooks only once the release is ready, and
# the services that need these roles cannot be ready without them, so a hook
# deadlocked every install that waits (helm --wait, ntctl, Flux).
assert_not_contains "$out19ext" 'helm.sh/hook": post-install' \
  "the bootstrap Job is part of the release, not a post-install hook"
bootstrap_job_name() {
  ruby -ryaml -e '
    YAML.load_stream(File.read(ARGV.fetch(0), encoding: "UTF-8")) do |d|
      next unless d.is_a?(Hash) && d["kind"] == "Job" && d.dig("metadata", "labels", "app") == ARGV.fetch(1)
      puts d.dig("metadata", "name")
    end
  ' "$1" "${2:-control-plane-postgresql-bootstrap}"
}
name19="$(bootstrap_job_name "$out19ext")"
if [[ ! "$name19" =~ ^control-plane-postgresql-bootstrap-[0-9a-f]{10}$ ]]; then
  red "FAIL: the bootstrap Job name should end in a 10-character hash, got '$name19'"; exit 1
fi
green "ok  - the bootstrap Job name ends in a hash of its inputs"
# The pod template of a Job cannot change in place: the name must change with
# anything that shapes it, and must not change otherwise.
out19same="$TMP/scenario-bootstrap-same.yaml"
render_default "$out19same" --set global.deploymentMode=external
[[ "$(bootstrap_job_name "$out19same")" == "$name19" ]] || { red "FAIL: the same inputs gave another Job name"; exit 1; }
green "ok  - the same inputs keep the same Job name, so an upgrade leaves it alone"
for change in \
  "--set agentgateway.database.password=rotated" \
  "--set global.nodeSelector.pool=db" \
  "--set global.postgresql.bootstrapJob.resources.requests.cpu=200m"; do
  out19chg="$TMP/scenario-bootstrap-changed.yaml"
  # shellcheck disable=SC2086 # deliberate word splitting of the flag pair above
  render_default "$out19chg" --set global.deploymentMode=external $change
  [[ "$(bootstrap_job_name "$out19chg")" != "$name19" ]] || { red "FAIL: $change kept the Job name, so the Job would not run again (or the upgrade would fail on its immutable pod template)"; exit 1; }
  green "ok  - $change gives the Job a new name"
done
# Templated target, so no values path can aim this Job at someone's managed instance.
assert_contains "$out19ext" 'value: "control-plane-postgresql"' \
  "the Job dials the in-cluster Service, not the endpoint in postgresql-secrets"

# A managed instance is provisioned by its own tooling; the chart must never try
# to create roles there, whichever way the operator names it.
for managed in \
  "--set global.postgresql.host=pg.example.com" \
  "--set global.postgresql.authMode=iam" \
  "--set global.postgresql.bootstrapJob.enabled=false"; do
  out19off="$TMP/scenario-bootstrap-off.yaml"
  # shellcheck disable=SC2086 # deliberate word splitting of the flag pairs above
  render_default "$out19off" --set global.deploymentMode=external $managed
  assert_bootstrap "$out19off" "" "no bootstrap Job with $managed"
done

# Hybrid shares one role and database, which the PostgreSQL image itself creates,
# so the Job has nothing per-service to do — but it still renders to converge the
# shared database and to turn a stale superuser password into one legible error
# instead of six crash-looping pods.
out19hy="$TMP/scenario-bootstrap-hybrid.yaml"
render_default "$out19hy"
assert_bootstrap "$out19hy" "" "hybrid bootstraps no per-service role"
assert_contains "$out19hy" 'name: control-plane-postgresql-bootstrap' \
  "hybrid still renders the Job for the shared database"

# Only deployed services get a role, and IAM auth has no password to set.
out19off1="$TMP/scenario-bootstrap-alertengine-off.yaml"
render_default "$out19off1" --set global.deploymentMode=external --set alertengine.enabled=false
assert_bootstrap "$out19off1" \
  "agentgateway:agentgateway:agentgateway:agentgateway-secrets/DB_PASSWORD trustguard:trustguard:trustguard:trustguard-secrets/DB_PASSWORD datacore:datacore:datacore:datacore-secrets/POSTGRES_PASSWORD" \
  "a disabled service gets no role"
out19iam="$TMP/scenario-bootstrap-iam.yaml"
render_default "$out19iam" --set global.deploymentMode=external \
  --set agentgateway.database.iamAuth=true --set agentgateway.database.awsRegion=eu-west-1
assert_bootstrap "$out19iam" \
  "trustguard:trustguard:trustguard:trustguard-secrets/DB_PASSWORD alertengine:alertengine:alertengine:alertengine-secrets/DB_PASSWORD datacore:datacore:datacore:datacore-secrets/POSTGRES_PASSWORD" \
  "an IAM-auth service is skipped"

# The credential hooks from Scenario 18 must move where the Job reads the
# password too, or it would set a role to a value the pod never uses.
out19hook="$TMP/scenario-bootstrap-hook.yaml"
render_default "$out19hook" --set global.deploymentMode=external \
  --set agentgateway.database.existingSecret.name=postgres-roles \
  --set agentgateway.database.existingSecret.key=AGENTGATEWAY \
  --set datacore.database.user=dc --set datacore.database.name=dcdb
assert_bootstrap "$out19hook" \
  "agentgateway:agentgateway:agentgateway:postgres-roles/AGENTGATEWAY trustguard:trustguard:trustguard:trustguard-secrets/DB_PASSWORD alertengine:alertengine:alertengine:alertengine-secrets/DB_PASSWORD datacore:dc:dcdb:datacore-secrets/POSTGRES_PASSWORD" \
  "the Job follows the credential hooks and custom role/database names"

blue "==> Scenario 19b: opt-in bootstrap of a PostgreSQL the chart does not run"
# Off by default: a managed instance's roles stay the DBA's unless the operator
# asks, and then only through managedBootstrap with an admin login they provide.
MANAGED_PG=(--set global.postgresql.deploy=false --set global.postgresql.host=pg.example.com)
MB_ON=(--set global.postgresql.managedBootstrap.enabled=true --set global.postgresql.managedBootstrap.adminSecret.name=pg-admin)
out19bOff="$TMP/scenario-managed-bootstrap-off.yaml"
render_default "$out19bOff" --set global.deploymentMode=external "${MANAGED_PG[@]}"
assert_not_contains "$out19bOff" 'postgresql-managed-bootstrap' \
  "managed PostgreSQL: no bootstrap Job unless managedBootstrap is enabled"

# Hybrid on a managed instance: nothing created the control-plane pair, so the
# Job creates it with the password the services read.
out19bHy="$TMP/scenario-managed-bootstrap-hybrid.yaml"
render_default "$out19bHy" "${MANAGED_PG[@]}" "${MB_ON[@]}"
assert_bootstrap "$out19bHy" \
  "control-plane:neuraltrust:neuraltrust:postgresql-secrets/POSTGRES_PASSWORD" \
  "managed hybrid: the Job creates the shared control-plane role and database" \
  postgresql-managed-bootstrap
assert_contains "$out19bHy" 'value: "pg.example.com"' \
  "managed: the Job dials global.postgresql.host"
assert_contains "$out19bHy" 'name: "pg-admin"' \
  "managed: the admin login comes from managedBootstrap.adminSecret"
assert_contains "$out19bHy" 'EXTENSIONS="pgcrypto"' \
  "managed: pgcrypto, which TrustGuard migrations need, is created by default"
assert_not_contains "$out19bHy" 'control-plane-postgresql-bootstrap' \
  "managed: the in-cluster Job does not render alongside"

# External on a managed instance: one role and database per service, plus the
# control plane, with each password from the Secret that service reads.
out19bExt="$TMP/scenario-managed-bootstrap-external.yaml"
render_default "$out19bExt" --set global.deploymentMode=external "${MANAGED_PG[@]}" "${MB_ON[@]}" \
  --set global.postgresql.passwordSecret.name=managed-postgres-roles --set global.postgresql.passwordSecret.key=CONTROL_PLANE
assert_bootstrap "$out19bExt" \
  "control-plane:neuraltrust:neuraltrust:managed-postgres-roles/CONTROL_PLANE agentgateway:agentgateway:agentgateway:agentgateway-secrets/DB_PASSWORD trustguard:trustguard:trustguard:trustguard-secrets/DB_PASSWORD alertengine:alertengine:alertengine:alertengine-secrets/DB_PASSWORD datacore:datacore:datacore:datacore-secrets/POSTGRES_PASSWORD" \
  "managed external: every service role, the control plane's from passwordSecret" \
  postgresql-managed-bootstrap

# A DBA may have provisioned some of it: managed mode only adds what is
# missing, and never resets a password or takes over a database.
assert_not_contains "$out19bExt" 'ALTER ROLE' \
  "managed: an existing role keeps the password it has"
assert_not_contains "$out19bExt" 'ALTER DATABASE' \
  "managed: an existing database keeps its owner"
assert_contains "$out19bExt" 'GRANT :"r" TO CURRENT_USER;' \
  "managed: the admin still holds a role to create a database it owns"
assert_contains "$out19bExt" 'elif q -v r=' \
  "managed: holding a DBA-created role may be refused without failing the Job"
assert_contains "$out19bExt" 'role to the admin login WITH ADMIN OPTION' \
  "managed: a database it cannot create is reported, not fatal"

# Asked for, it must be able to run.
assert_render_fails_with "adminSecret.name is required" \
  "managed bootstrap without an admin Secret fails the render" \
  "${MANAGED_PG[@]}" --set global.postgresql.managedBootstrap.enabled=true
assert_render_fails_with "needs password auth" \
  "managed bootstrap with IAM auth fails the render" \
  "${MANAGED_PG[@]}" "${MB_ON[@]}" --set global.postgresql.authMode=iam
assert_render_fails_with "is for a PostgreSQL the chart does not run" \
  "managed bootstrap against the in-cluster instance fails the render" \
  "${MB_ON[@]}"
