#!/usr/bin/env bash
# Render scenarios 2c. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

# ---------------------------------------------------------------------------
# 2c. Hybrid Postgres cloud identity: AWS IRSA and Azure Entra ID.
#
# POSTGRES_LOGIN in the shared Secret is the only token-auth switch that reaches
# a hybrid pod, and the ServiceAccount annotation helper is shared by twelve
# templates — so a regression in either is silent and wide. The AWS half is
# backfilled here because the suite carried no IRSA assertion at all.
# ---------------------------------------------------------------------------
blue "==> Scenario 2c: hybrid Postgres cloud identity (IRSA + Entra ID)"

out2c_aws="$TMP/scenario-hybrid-irsa.yaml"
render_default "$out2c_aws" \
  --set global.postgresql.deploy=false \
  --set global.postgresql.host=pg.iam.example.com \
  --set global.postgresql.authMode=iam \
  --set global.postgresql.sslMode=require \
  --set global.postgresql.awsRegion=eu-west-1 \
  --set global.irsa.roleArn=arn:aws:iam::123456789012:role/neuraltrust \
  --set global.irsa.applyGlobally=true

# echo -n aws | base64 -> YXdz
assert_contains "$out2c_aws" 'POSTGRES_LOGIN: "YXdz"' \
  "hybrid IRSA: POSTGRES_LOGIN stays aws when no Azure identity is configured"
assert_occurrences "$out2c_aws" 'eks\.amazonaws\.com/role-arn' 6 \
  "hybrid IRSA: every hybrid ServiceAccount carries the role ARN"
assert_contains "$out2c_aws" 'name: AWS_REGION' \
  "hybrid IRSA: the region the SDK needs reaches the pods"
assert_not_contains "$out2c_aws" 'azure\.workload\.identity' \
  "hybrid IRSA: no Azure identity leaks into an AWS install"
# Without POSTGRES_LOGIN the agent stayed on password auth with the empty
# password an IAM install carries, while the gateways authenticated fine. Both
# instances render from one template, so both are checked.
for agent in dataagent dataagent-trustguard; do
  assert_datastore_env "$out2c_aws" "$agent" dataagent \
    'POSTGRES_DB,POSTGRES_HOST,POSTGRES_LOGIN,POSTGRES_PASSWORD,POSTGRES_PORT,POSTGRES_SSLMODE,POSTGRES_USER' \
    "hybrid IRSA: $agent receives the login switch"
  assert_env_value "$out2c_aws" "$agent" dataagent AWS_REGION "eu-west-1" \
    "hybrid IRSA: $agent receives the region the SDK signs the token for"
done
assert_not_contains "$out2c_aws" 'name: POSTGRES_AZURE_SCOPE' \
  "hybrid IRSA: no Azure scope on an AWS install"

out2c_az="$TMP/scenario-hybrid-entra.yaml"
render_default "$out2c_az" \
  --set global.platform=azure \
  --set global.postgresql.deploy=false \
  --set global.postgresql.host=pg.postgres.database.azure.com \
  --set global.postgresql.authMode=iam \
  --set global.postgresql.sslMode=require \
  --set global.postgresql.user=nt-umi \
  --set global.azureIdentity.method=workload-identity \
  --set global.azureIdentity.clientId=00000000-0000-0000-0000-000000000000 \
  --set global.azureIdentity.tenantId=11111111-1111-1111-1111-111111111111 \
  --set global.azureIdentity.applyGlobally=true \
  --set global.postgresql.azureScope=https://ossrdbms-aad.database.usgovcloudapi.net/.default

# echo -n azure | base64 -> YXp1cmU=
assert_contains "$out2c_az" 'POSTGRES_LOGIN: "YXp1cmU="' \
  "hybrid Entra: the shared Secret selects the Azure token provider"
assert_occurrences "$out2c_az" 'azure\.workload\.identity/client-id' 6 \
  "hybrid Entra: every hybrid ServiceAccount carries the client ID"
assert_occurrences "$out2c_az" 'azure\.workload\.identity/tenant-id' 6 \
  "hybrid Entra: every hybrid ServiceAccount carries the tenant ID"
# proxy, mcp, trustguard data-plane, both DataAgents, data-plane-api. Without the
# pod label the AKS webhook never fires and nothing is injected, silently.
assert_occurrences "$out2c_az" 'azure\.workload\.identity/use' 6 \
  "hybrid Entra: every Postgres client pod carries the webhook label"
# The webhook injects these itself, and only for names the container has not
# already declared — a chart-set value would win over the annotation.
assert_not_contains "$out2c_az" 'name: AZURE_CLIENT_ID' \
  "hybrid Entra: workload identity ships no credential env"
assert_not_contains "$out2c_az" 'name: AZURE_CLIENT_SECRET' \
  "hybrid Entra: no client secret on the federated path"
assert_not_contains "$out2c_az" 'name: AWS_REGION' \
  "hybrid Entra: no AWS region on an Azure install"
# DataAgent spells its whole env family POSTGRES_*, so the scope variable is
# POSTGRES_AZURE_SCOPE here and DB_AZURE_SCOPE on the gateways.
assert_datastore_env "$out2c_az" dataagent dataagent \
  'POSTGRES_AZURE_SCOPE,POSTGRES_DB,POSTGRES_HOST,POSTGRES_LOGIN,POSTGRES_PASSWORD,POSTGRES_PORT,POSTGRES_SSLMODE,POSTGRES_USER' \
  "hybrid Entra: DataAgent receives the login switch and its own scope name"
assert_contains "$out2c_az" 'name: DB_AZURE_SCOPE' \
  "hybrid Entra: the gateways receive the scope under the name they read"
# data-plane-api's enum is azure_ad|password, NOT the iam|password the shared
# postgresql-secrets key of the same name carries for the Next.js app. It raises
# at boot on anything else, so this must be a literal and never that Secret key.
assert_env_value "$out2c_az" data-plane-api api POSTGRES_AUTH_MODE azure_ad \
  "hybrid Entra: data-plane-api gets its own auth-mode vocabulary"
assert_not_contains "$out2c_aws" 'name: POSTGRES_AUTH_MODE' \
  "hybrid IRSA: data-plane-api is not handed an auth mode it rejects"
# The schema runner is the API image with the API's environment, so it takes
# the same Entra token path — the migration renders under Entra, no opt-out.
assert_pg_migration_runner "$out2c_az" \
  "hybrid Entra: the schema migration runs under Entra through the API image"
for c in api postgres-migrations; do
  assert_env_value "$out2c_az" data-plane-api "$c" POSTGRES_AUTH_MODE azure_ad \
    "hybrid Entra: data-plane-api/$c authenticates with an Entra token"
  assert_env_value "$out2c_az" data-plane-api "$c" POSTGRES_AZURE_SCOPE \
    https://ossrdbms-aad.database.usgovcloudapi.net/.default \
    "hybrid Entra: data-plane-api/$c receives the sovereign-cloud scope"
done
# Pod-only. A label that reaches matchLabels is an immutable-field change and
# every upgrade of an existing release would be rejected by the API server.
assert_not_contains "$out2c_az" 'matchLabels:\n.*azure\.workload\.identity' \
  "hybrid Entra: the webhook label never reaches an immutable selector"
diff <(awk '/^  selector:/{f=4} f&&f--' "$out2c_aws") \
     <(awk '/^  selector:/{f=4} f&&f--' "$out2c_az") >/dev/null \
  && green "ok  - hybrid Entra: selectors identical to the AWS render" \
  || { red "FAIL: hybrid Entra: selector blocks changed"; exit 1; }

out2c_sp="$TMP/scenario-hybrid-entra-sp.yaml"
render_default "$out2c_sp" \
  --set global.postgresql.deploy=false \
  --set global.postgresql.host=pg.postgres.database.azure.com \
  --set global.postgresql.authMode=iam \
  --set global.postgresql.sslMode=require \
  --set global.azureIdentity.method=service-principal \
  --set global.azureIdentity.clientId=cid \
  --set global.azureIdentity.tenantId=tid \
  --set global.azureIdentity.clientSecret.name=azure-sp \
  --set global.postgresql.azureScope=https://ossrdbms-aad.database.usgovcloudapi.net/.default

assert_contains "$out2c_sp" 'name: AZURE_CLIENT_SECRET' \
  "hybrid Entra SP: the client secret is injected by reference"
# Deliberately not optional: a wrong key must stop the pod rather than let the
# credential chain fall through to another link.
assert_not_contains "$out2c_sp" 'key: "AZURE_CLIENT_SECRET"\n              optional: true' \
  "hybrid Entra SP: the client secret reference is required"
assert_contains "$out2c_sp" 'value: "https://ossrdbms-aad.database.usgovcloudapi.net/.default"' \
  "hybrid Entra SP: the sovereign-cloud scope override reaches the pods"
assert_not_contains "$out2c_sp" 'azure\.workload\.identity' \
  "hybrid Entra SP: no federation annotation or label off the workload-identity path"
# Service principal resolves through env, never through the webhook, so both
# data-plane-api containers need it; before this they only worked under
# workload identity.
for c in api postgres-migrations; do
  assert_env_value "$out2c_sp" data-plane-api "$c" AZURE_TENANT_ID tid \
    "hybrid Entra SP: data-plane-api/$c receives the tenant"
  assert_env_value "$out2c_sp" data-plane-api "$c" AZURE_CLIENT_ID cid \
    "hybrid Entra SP: data-plane-api/$c receives the client ID"
  assert_env_value "$out2c_sp" data-plane-api "$c" AZURE_CLIENT_SECRET \
    secretKeyRef:azure-sp/AZURE_CLIENT_SECRET \
    "hybrid Entra SP: data-plane-api/$c receives the secret by reference"
done

out2c_mi="$TMP/scenario-hybrid-entra-mi.yaml"
render_default "$out2c_mi" \
  --set global.postgresql.deploy=false \
  --set global.postgresql.host=pg.postgres.database.azure.com \
  --set global.postgresql.authMode=iam \
  --set global.postgresql.sslMode=require \
  --set global.azureIdentity.method=managed-identity \
  --set global.azureIdentity.clientId=umi-cid
for c in api postgres-migrations; do
  assert_env_value "$out2c_mi" data-plane-api "$c" AZURE_CLIENT_ID umi-cid \
    "hybrid Entra MI: data-plane-api/$c selects the user-assigned identity"
  assert_env_value "$out2c_mi" data-plane-api "$c" AZURE_CLIENT_SECRET ABSENT \
    "hybrid Entra MI: data-plane-api/$c carries no client secret"
done

# An operator override must win once, not twice: a duplicate env name is the
# $setElementOrder patch failure that breaks the next helm upgrade.
out2c_override="$TMP/scenario-hybrid-entra-mi-override.yaml"
render_default "$out2c_override" \
  --set global.postgresql.deploy=false \
  --set global.postgresql.host=pg.postgres.database.azure.com \
  --set global.postgresql.authMode=iam \
  --set global.postgresql.sslMode=require \
  --set global.azureIdentity.method=managed-identity \
  --set global.azureIdentity.clientId=umi-cid \
  --set 'data-plane-api.dataPlane.components.api.extraEnv[0].name=AZURE_CLIENT_ID' \
  --set 'data-plane-api.dataPlane.components.api.extraEnv[0].value=operator-cid'
ruby -ryaml -e '
  docs = []
  YAML.load_stream(File.read(ARGV[0])) { |d| docs << d if d.is_a?(Hash) }
  spec = docs.find { |x| x["kind"] == "Deployment" && x.dig("metadata", "name") == "data-plane-api" }.dig("spec", "template", "spec")
  (spec["containers"] + spec["initContainers"]).select { |c| %w[api postgres-migrations].include?(c["name"]) }.each do |c|
    hits = c["env"].select { |e| e["name"] == "AZURE_CLIENT_ID" }
    abort "#{c["name"]}: #{hits.size} AZURE_CLIENT_ID entries" unless hits.size == 1 && hits[0]["value"] == "operator-cid"
  end
' "$out2c_override" \
  && green "ok  - hybrid Entra MI: an extraEnv override appears once on both containers" \
  || { red "FAIL: hybrid Entra MI: extraEnv override duplicated or lost"; exit 1; }

# Guards. Each is conjoined with authMode=iam so global.azureIdentity alone can
# never stop a password install rendering.
assert_render_fails_with "sslMode" "Entra guard: default sslMode=prefer is rejected" \
  --set global.postgresql.deploy=false \
  --set global.postgresql.host=pg.postgres.database.azure.com \
  --set global.postgresql.authMode=iam \
  --set global.azureIdentity.method=workload-identity \
  --set global.azureIdentity.clientId=cid \
  --set global.azureIdentity.applyGlobally=true
for mode in external saas; do
  assert_render_fails_with "hybrid only" "Entra guard: $mode mode is rejected" \
    --set global.deploymentMode=$mode \
    --set global.postgresql.deploy=false \
    --set global.postgresql.host=pg.postgres.database.azure.com \
    --set global.postgresql.authMode=iam \
    --set global.postgresql.sslMode=require \
    --set global.azureIdentity.method=workload-identity \
    --set global.azureIdentity.clientId=cid \
    --set global.azureIdentity.applyGlobally=true
done
assert_render_fails_with "clientSecret.name" "Entra guard: service-principal needs a Secret name" \
  --set global.postgresql.deploy=false \
  --set global.postgresql.host=pg.postgres.database.azure.com \
  --set global.postgresql.authMode=iam \
  --set global.postgresql.sslMode=require \
  --set global.azureIdentity.method=service-principal \
  --set global.azureIdentity.clientId=cid \
  --set global.azureIdentity.tenantId=tid
assert_render_fails_with "workload-identity, managed-identity, service-principal" \
  "Entra guard: an unknown method lists the supported ones" \
  --set global.azureIdentity.method=entra
assert_render_fails_with "clientId" "Entra guard: applyGlobally needs a client ID" \
  --set global.azureIdentity.method=workload-identity \
  --set global.azureIdentity.applyGlobally=true

# The AWS half. values.yaml ships sslMode: prefer, so an operator who sets only
# authMode: iam must be stopped at render rather than by three crash-looping
# workloads. Every case outside the ones that break must keep rendering.
aws_iam_args=(
  --set global.postgresql.deploy=false
  --set global.postgresql.host=pg.iam.example.com
  --set global.postgresql.authMode=iam
  --set global.postgresql.awsRegion=eu-west-1
)
assert_render_fails_with "sslMode must be require, verify-ca or verify-full for AWS RDS IAM" \
  "AWS IAM guard: default sslMode=prefer is rejected in hybrid" \
  "${aws_iam_args[@]}"
assert_render_fails_with "sslMode must be require, verify-ca or verify-full for AWS RDS IAM" \
  "AWS IAM guard: disable is rejected in hybrid" \
  "${aws_iam_args[@]}" --set global.postgresql.sslMode=disable
aws_guard_passes() {
  local msg="$1"
  shift
  if ! helm template test "$CHART_DIR" --namespace default -f "$CHART_DIR/values-required.yaml" \
      "${CLICKSTACK_DEFAULT_ARGS[@]}" "${aws_iam_args[@]}" "$@" >/dev/null 2>&1; then
    red "FAIL: $msg"
    exit 1
  fi
  green "ok  - $msg"
}
aws_guard_passes "AWS IAM guard: an empty sslMode takes the chart's require default" \
  --set global.postgresql.sslMode=
aws_guard_passes "AWS IAM guard: verify-full passes, case-insensitively" \
  --set global.postgresql.sslMode=VERIFY-FULL
aws_guard_passes "AWS IAM guard: an operator-owned Secret carries its own sslmode" \
  --set global.postgresql.existingSecret.name=operator-pg
aws_guard_passes "AWS IAM guard: a data-plane-only hybrid runs no token-login client" \
  --set global.products.trustgate=false --set global.products.trustguard=false
for mode in external saas; do
  aws_guard_passes "AWS IAM guard: $mode keeps its per-service sslMode" \
    --set global.deploymentMode=$mode
done
if ! helm template test "$CHART_DIR" --namespace default -f "$CHART_DIR/values-required.yaml" \
    "${CLICKSTACK_DEFAULT_ARGS[@]}" >/dev/null 2>&1; then
  red "FAIL: AWS IAM guard: a password install with sslMode=prefer must render"
  exit 1
fi
green "ok  - AWS IAM guard: a password install with sslMode=prefer renders"

# External and saas are not failed (that would break values files that render
# today); the same trap is reported as a NOTES.txt warning, per gateway, and
# only for a gateway that actually logs in with a token.
for mode in external saas; do
  notes_iam="$TMP/notes-$mode-aws-iam.txt"
  render_notes "$notes_iam" "${aws_iam_args[@]}" --set global.deploymentMode=$mode
  assert_contains "$notes_iam" 'TrustGate uses PostgreSQL IAM token auth with sslMode "prefer"' \
    "AWS IAM warning: $mode TrustGate on default sslMode=prefer is warned about"
  assert_contains "$notes_iam" 'TrustGuard uses PostgreSQL IAM token auth with sslMode "prefer"' \
    "AWS IAM warning: $mode TrustGuard on default sslMode=prefer is warned about"
done
notes_iam="$TMP/notes-external-aws-iam-require.txt"
render_notes "$notes_iam" "${aws_iam_args[@]}" --set global.deploymentMode=external \
  --set global.postgresql.sslMode=require
assert_not_contains "$notes_iam" '^Warnings' \
  "AWS IAM warning: external with sslMode=require has nothing to warn about"
notes_iam="$TMP/notes-external-aws-iam-mixed.txt"
render_notes "$notes_iam" "${aws_iam_args[@]}" --set global.deploymentMode=external \
  --set trustguard.database.iamAuth=false --set agentgateway.database.sslMode=verify-full
assert_not_contains "$notes_iam" '^Warnings' \
  "AWS IAM warning: a password gateway and a per-service verify-full gateway are not warned about"
notes_iam="$TMP/notes-hybrid-default.txt"
render_notes "$notes_iam"
assert_contains "$notes_iam" 'NeuralTrust Platform has been deployed' \
  "NOTES: renders for the default hybrid install"
assert_not_contains "$notes_iam" '^Warnings' \
  "NOTES: the default hybrid install has no warnings"

# Both emitters of postgresql-secrets must agree on IAM: platform-secrets.yaml
# (autoGenerateSecrets=true) and postgresql/secrets.yaml (false) used to decide
# it differently, so deploy=true + authMode=iam produced a token login against
# the chart's own Postgres from one and a password login from the other.
pg_secret_data() {  # file -> the decoded postgresql-secrets data, sorted
  ruby -ryaml -rbase64 -e '
    d = []
    YAML.load_stream(File.read(ARGV.fetch(0))) { |x| d << x if x.is_a?(Hash) }
    s = d.find { |x| x["kind"] == "Secret" && x.dig("metadata", "name") == "postgresql-secrets" }
    abort "postgresql-secrets not rendered" if s.nil?
    (s["data"] || {}).sort.each { |k, v| puts "#{k}=#{Base64.decode64(v)}" }
  ' "$1"
}
for shape in "in-cluster:--set global.postgresql.authMode=iam --set global.postgresql.password=pw-test" \
             "managed:--set global.postgresql.deploy=false --set global.postgresql.host=pg.iam.example.com --set global.postgresql.authMode=iam --set global.postgresql.sslMode=require"; do
  label="${shape%%:*}"
  read -r -a args <<< "${shape#*:}"
  for mode in hybrid external; do
    out_auto="$TMP/pg-emitter-$label-$mode-auto.yaml"
    out_fallback="$TMP/pg-emitter-$label-$mode-fallback.yaml"
    render_default "$out_auto" --set global.deploymentMode=$mode "${args[@]}"
    render_default "$out_fallback" --set global.deploymentMode=$mode "${args[@]}" \
      --set global.autoGenerateSecrets=false
    if ! diff <(pg_secret_data "$out_auto") <(pg_secret_data "$out_fallback") >/dev/null; then
      red "FAIL: postgresql-secrets emitters disagree ($label, $mode)"
      diff <(pg_secret_data "$out_auto") <(pg_secret_data "$out_fallback") | sed 's/PASSWORD=.*/PASSWORD=<redacted>/' | head -10
      exit 1
    fi
    green "ok  - postgresql-secrets emitters agree ($label Postgres + authMode=iam, $mode)"
  done
done
out_pg_incluster="$TMP/pg-emitter-in-cluster-hybrid-auto.yaml"
assert_contains "$out_pg_incluster" 'POSTGRES_LOGIN: "ZGVmYXVsdA=="' \
  "authMode=iam is ignored for the chart's own Postgres: POSTGRES_LOGIN stays default"
assert_contains "$out_pg_incluster" 'POSTGRES_AUTH_MODE: "cGFzc3dvcmQ="' \
  "authMode=iam is ignored for the chart's own Postgres: POSTGRES_AUTH_MODE stays password"
assert_secret_key "$out_pg_incluster" postgresql-secrets present POSTGRES_PASSWORD \
  "authMode=iam is ignored for the chart's own Postgres: it keeps its password"
notes_iam="$TMP/notes-hybrid-iam-in-cluster.txt"
render_notes "$notes_iam" --set global.postgresql.authMode=iam
assert_contains "$notes_iam" 'authMode is iam, but the chart is deploying its own PostgreSQL' \
  "authMode=iam with the chart's own Postgres is warned about"

# global.irsa reaches every workload ServiceAccount. The ClickHouse backup,
# DataBridge and ingest-gateway ones used to emit only their own annotations, so
# the backup CronJob got no role and could not reach its bucket.
sa_role() {  # file, serviceaccount -> its eks.amazonaws.com/role-arn, or empty
  ruby -ryaml -e '
    YAML.load_stream(File.read(ARGV.fetch(0))) do |d|
      next unless d.is_a?(Hash) && d["kind"] == "ServiceAccount" && d.dig("metadata", "name") == ARGV.fetch(1)
      puts (d.dig("metadata", "annotations") || {})["eks.amazonaws.com/role-arn"].to_s
    end
  ' "$1" "$2"
}
irsa_args=(
  --set global.irsa.roleArn=arn:aws:iam::111111111111:role/nt-global
  --set global.irsa.applyGlobally=true
)
out_sa_backup="$TMP/scenario-external-clickhouse-backup-irsa.yaml"
render_default "$out_sa_backup" --set global.deploymentMode=external \
  --set infrastructure.clickhouse.deploy=true \
  --set clickhouse.backup.enabled=true --set clickhouse.backup.serviceAccount.create=true \
  "${irsa_args[@]}"
out_sa_saas="$TMP/scenario-saas-irsa.yaml"
render_default "$out_sa_saas" --set global.deploymentMode=saas "${irsa_args[@]}" \
  --set databridge.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=arn:aws:iam::111111111111:role/nt-databridge
for pair in "$out_sa_backup:clickhouse-backup:nt-global" \
            "$out_sa_saas:clickstack-ingest-gateway:nt-global" \
            "$out_sa_saas:databridge:nt-databridge"; do
  IFS=: read -r file sa want <<< "$pair"
  got="$(sa_role "$file" "$sa")"
  if [[ "$got" != "arn:aws:iam::111111111111:role/$want" ]]; then
    red "FAIL: IRSA: ServiceAccount $sa should carry role $want, got '${got}'"
    exit 1
  fi
  green "ok  - IRSA: ServiceAccount $sa carries role $want"
done

# Regression fence: an install that never configures an Azure identity must be
# untouched by any of the above.
out2c_none="$TMP/scenario-hybrid-no-cloud-identity.yaml"
render_default "$out2c_none"
assert_not_contains "$out2c_none" 'azure\.workload\.identity' \
  "no cloud identity: nothing Azure renders by default"
assert_not_contains "$out2c_none" 'name: AZURE_' \
  "no cloud identity: no Azure env renders by default"
