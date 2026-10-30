#!/usr/bin/env bash
# Render scenarios 3b, 3c, 3d. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

# ---------------------------------------------------------------------------
# 3b. Control-plane RDS IAM env contract (api + app) + DataCore IAM
# ---------------------------------------------------------------------------
blue "==> Scenario 3b: control-plane Postgres IAM env contract"
out3b="$TMP/scenario-external-cp-iam.yaml"
render_default "$out3b" \
  --set global.deploymentMode=external \
  --set global.postgresql.deploy=false \
  --set global.postgresql.host=pg.iam.example.com \
  --set global.postgresql.authMode=iam \
  --set global.postgresql.awsRegion=eu-west-1 \
  --set global.postgresql.user=neuraltrust_iam \
  --set datacore.database.iamAuth=true \
  --set datacore.database.host=pg.iam.example.com \
  --set datacore.database.user=datacore_iam \
  --set datacore.database.sslMode=require \
  --set datacore.database.awsRegion=eu-west-1 \
  --set control-plane-api.controlPlane.components.postgresql.authMode=iam \
  --set control-plane-api.controlPlane.components.postgresql.awsRegion=eu-west-1 \
  --set control-plane-app.controlPlane.components.postgresql.authMode=iam \
  --set control-plane-app.controlPlane.components.postgresql.awsRegion=eu-west-1

# Secret carries app/API-facing keys (base64):
#   POSTGRES_AUTH_MODE=iam          → aWFt
#   POSTGRES_CONNECTION_TYPE=aurora → YXVyb3Jh
assert_contains "$out3b" 'POSTGRES_AUTH_MODE: "aWFt"' \
  "cp IAM: postgresql-secrets emits POSTGRES_AUTH_MODE=iam"
assert_contains "$out3b" 'POSTGRES_CONNECTION_TYPE: "YXVyb3Jh"' \
  "cp IAM: postgresql-secrets emits POSTGRES_CONNECTION_TYPE=aurora"
assert_contains "$out3b" 'name: AWS_REGION' \
  "cp IAM: Deployments emit AWS_REGION"
assert_contains "$out3b" 'value: "eu-west-1"' \
  "cp IAM: AWS_REGION=eu-west-1"
assert_contains "$out3b" 'postgres-iam-url.mjs' \
  "cp IAM: app init-db mints Prisma URL via postgres-iam-url.mjs"
assert_contains "$out3b" 'PRISMA_CLI="/app/node_modules/prisma/build/index.js"' \
  "cp app: init-db uses the image-bundled Prisma CLI"
assert_contains "$out3b" 'node "\$PRISMA_CLI" migrate deploy' \
  "cp app: init-db executes versioned migrations with the bundled CLI"
assert_not_contains "$out3b" 'npx prisma' \
  "cp app: init-db does not require the removed npx binary"
assert_not_contains "$out3b" 'prisma db push' \
  "cp app: init-db applies versioned migrations only"
assert_contains "$out3b" 'POSTGRES_LOGIN: "aws"' \
  "datacore IAM: emits POSTGRES_LOGIN=aws"
assert_contains "$out3b" 'POSTGRES_USER: "datacore_iam"' \
  "datacore IAM: POSTGRES_USER is the _iam role"
assert_contains "$out3b" 'AWS_REGION: "eu-west-1"' \
  "datacore IAM: ConfigMap carries AWS_REGION"
# datacore-secrets keeps AUTH_JWT + CLICKHOUSE_USER only (no POSTGRES_PASSWORD).
assert_contains "$out3b" 'name: datacore-secrets'$'\n''  annotations:'$'\n''    helm.sh/resource-policy: keep' \
  "datacore IAM: datacore-secrets still renders"
assert_contains "$out3b" 'AUTH_JWT_HS256_SECRET:'$'\n''  CLICKHOUSE_USER:' \
  "datacore IAM: omits POSTGRES_PASSWORD between JWT and CLICKHOUSE_USER"

# ---------------------------------------------------------------------------
# 3c. GCP IAM (Cloud SQL / AlloyDB) with GKE Workload Identity, external mode.
# Global authMode alone must reach every Postgres client, including the control
# plane, whose own overlays still default to "password".
# ---------------------------------------------------------------------------
blue "==> Scenario 3c: GCP IAM Postgres env contract (external, Workload Identity)"
out3c="$TMP/scenario-external-gcp-iam.yaml"
render_default "$out3c" "${gcp_args[@]}" \
  --set trustguard.serviceAccount.annotations.iam\\.gke\\.io/gcp-service-account=trustguard-db@example-project.iam.gserviceaccount.com \
  --set control-plane-api.controlPlane.serviceAccount.annotations.iam\\.gke\\.io/gcp-service-account=cp-db@example-project.iam.gserviceaccount.com
for w in "control-plane-api:control-plane-api" "control-plane-app:app" "control-plane-app:init-db"; do
  IFS=: read -r workload container <<< "$w"
  assert_env_value "$out3c" "$workload" "$container" POSTGRES_LOGIN gcp \
    "gcp IAM: $workload/$container gets POSTGRES_LOGIN=gcp"
  assert_env_value "$out3c" "$workload" "$container" AWS_REGION ABSENT \
    "gcp IAM: $workload/$container gets no AWS_REGION"
done
assert_contains "$out3c" 'if \[ "\$\{POSTGRES_LOGIN:-\}" = "gcp" \]; then' \
  "gcp IAM: app init-db mints the Prisma URL for the gcp login"
# agentgateway, trustguard, datacore and alertengine env ConfigMaps.
assert_occurrences "$out3c" '^  POSTGRES_LOGIN: "gcp"$' 4 \
  "gcp IAM: TrustGate, TrustGuard, DataCore and AlertEngine ConfigMaps carry POSTGRES_LOGIN=gcp"
assert_not_contains "$out3c" '^  AWS_REGION:' \
  "gcp IAM: no ConfigMap carries AWS_REGION"
assert_not_contains "$out3c" '^  (DB_AUTH_MODE|DB_IAM_AUTH):' \
  "gcp IAM: AlertEngine gets no AWS-only DB_AUTH_MODE"
# postgresql-secrets: POSTGRES_LOGIN, POSTGRES_AUTH_MODE and
# POSTGRES_CONNECTION_TYPE all "gcp" (Z2Nw), so an image without GCP support
# fails closed instead of attempting a password login.
assert_occurrences "$out3c" '^  POSTGRES_(LOGIN|AUTH_MODE|CONNECTION_TYPE): "Z2Nw"$' 3 \
  "gcp IAM: postgresql-secrets stores gcp under all three switch names"
assert_datastore_env "$out3c" trustguard-control-plane control-plane \
  "DB_HOST DB_NAME DB_PORT DB_SSL_MODE DB_USER POSTGRES_LOGIN" \
  "gcp IAM: TrustGuard receives no DB_PASSWORD"
assert_contains "$out3c" 'DB_USER: "trustguard-db@example-project.iam"' \
  "gcp IAM: TrustGuard logs in as its IAM user"
assert_contains "$out3c" 'iam.gke.io/gcp-service-account: trustguard-db@example-project.iam.gserviceaccount.com' \
  "gcp IAM: a per-service Google service account reaches its ServiceAccount"
assert_occurrences "$out3c" 'iam\.gke\.io/gcp-service-account' 2 \
  "gcp IAM: without applyGlobally only the annotated ServiceAccounts change"

out3c_global="$TMP/scenario-external-gcp-iam-global.yaml"
render_default "$out3c_global" "${gcp_args[@]}" \
  --set global.gcpIdentity.applyGlobally=true \
  --set global.gcpIdentity.serviceAccount=nt-db@example-project.iam.gserviceaccount.com
# Workload ServiceAccounts only: the key-generation hook ones talk to the
# Kubernetes API alone and deliberately carry no cloud identity.
sa_count="$(ruby -ryaml -e '
  n = 0
  YAML.load_stream(File.read(ARGV.fetch(0))) do |d|
    next unless d.is_a?(Hash) && d["kind"] == "ServiceAccount"
    n += 1 unless (d.dig("metadata", "annotations") || {}).key?("helm.sh/hook")
  end
  puts n
' "$out3c_global")"
assert_occurrences "$out3c_global" 'iam\.gke\.io/gcp-service-account: nt-db@example-project\.iam\.gserviceaccount\.com' "$sa_count" \
  "gcp IAM: applyGlobally annotates every ServiceAccount"

# Hybrid: the gateways, TrustGuard, both DataAgents and data-plane-api all take
# the login from the shared Secret or a literal.
out3c_hybrid="$TMP/scenario-hybrid-gcp-iam.yaml"
render_default "$out3c_hybrid" \
  --set global.postgresql.deploy=false --set global.postgresql.host=10.0.0.5 \
  --set global.postgresql.authMode=iam --set global.postgresql.sslMode=require \
  --set global.postgresql.user=nt-db@example-project.iam \
  --set global.gcpIdentity.method=workload-identity
assert_contains "$out3c_hybrid" '^  POSTGRES_LOGIN: "Z2Nw"$' \
  "gcp IAM hybrid: postgresql-secrets carries POSTGRES_LOGIN=gcp"
assert_env_value "$out3c_hybrid" data-plane-api api POSTGRES_LOGIN gcp \
  "gcp IAM hybrid: data-plane-api gets POSTGRES_LOGIN=gcp"
assert_env_value "$out3c_hybrid" dataagent dataagent POSTGRES_LOGIN "secretKeyRef:postgresql-secrets/POSTGRES_LOGIN" \
  "gcp IAM hybrid: DataAgent reads the login from postgresql-secrets"
assert_not_contains "$out3c_hybrid" 'name: AWS_REGION' \
  "gcp IAM hybrid: no AWS_REGION reaches any pod"
assert_render_fails_with 'sslMode must be require, verify-ca or verify-full for GCP IAM' \
  "gcp IAM guard: the shipped sslMode=prefer is refused" \
  "${gcp_args[@]}" --set global.postgresql.sslMode=prefer
assert_render_fails_with 'are both set' \
  "gcp IAM guard: a GCP and an Azure identity at once are refused" \
  "${gcp_args[@]}" --set global.azureIdentity.method=workload-identity
assert_render_fails_with 'global.gcpIdentity.method must be workload-identity' \
  "gcp IAM guard: an unknown method is refused" \
  "${gcp_args[@]}" --set global.gcpIdentity.method=federation
assert_render_fails_with 'global.gcpIdentity.serviceAccount is required' \
  "gcp IAM guard: applyGlobally needs the Google service account" \
  "${gcp_args[@]}" --set global.gcpIdentity.applyGlobally=true
assert_render_fails_with 'without ".gserviceaccount.com" (datacore-db@example-project.iam)' \
  "gcp IAM guard: a database user with the .gserviceaccount.com suffix is refused" \
  "${gcp_args[@]}" --set datacore.database.user=datacore-db@example-project.iam.gserviceaccount.com
# ---------------------------------------------------------------------------
# 3d. Memorystore for Redis Cluster with IAM auth and its per-instance CA.
# ---------------------------------------------------------------------------
blue "==> Scenario 3d: Redis Cluster, GCP IAM and a custom CA"
out3d="$TMP/scenario-external-redis-cluster-iam.yaml"
render_default "$out3d" "${gcp_args[@]}" "${redis_args[@]}"
for w in "trustguard-control-plane:control-plane" "trustguard-data-plane:data-plane" \
         "agentgateway-admin:admin" "agentgateway-proxy:proxy" "agentgateway-mcp:mcp" "data-plane-api:api"; do
  IFS=: read -r workload container <<< "$w"
  assert_env_value "$out3d" "$workload" "$container" REDIS_LOGIN gcp \
    "redis gcp: $workload/$container gets REDIS_LOGIN=gcp"
  assert_env_value "$out3d" "$workload" "$container" REDIS_CLUSTER true \
    "redis cluster: $workload/$container gets REDIS_CLUSTER=true"
  assert_env_value "$out3d" "$workload" "$container" REDIS_TLS_CA_FILE /etc/neuraltrust/redis-ca/ca.pem \
    "redis CA: $workload/$container reads the mounted CA bundle"
done
assert_env_value "$out3d" data-plane-api api K8S_JOB_REDIS_CA_SECRET_NAME redis-ca \
  "redis CA: data-plane-api hands the CA Secret to its evaluation Jobs"
assert_contains "$out3d" "REDIS_URL: $(printf 'rediss://10.0.0.6:6379/0' | base64)" \
  "redis gcp: data-plane-api's REDIS_URL carries no credential and uses TLS"
out3d_hybrid="$TMP/scenario-hybrid-redis-cluster-iam.yaml"
render_default "$out3d_hybrid" "${redis_args[@]}" --set global.gcpIdentity.method=workload-identity
assert_env_value "$out3d_hybrid" agentgateway-proxy proxy REDIS_LOGIN gcp \
  "redis gcp hybrid: the gateway data plane gets REDIS_LOGIN=gcp"
assert_env_value "$out3d_hybrid" trustguard-data-plane data-plane REDIS_CLUSTER true \
  "redis cluster hybrid: TrustGuard's data plane gets REDIS_CLUSTER=true"
assert_render_fails_with 'set global.gcpIdentity.method' \
  "redis gcp guard: authMode=iam without a GCP identity is refused" \
  --set global.redis.deploy=false --set global.redis.host=10.0.0.6 --set global.redis.tls=true \
  --set global.redis.authMode=iam
assert_render_fails_with 'needs global.redis.tls' \
  "redis gcp guard: a token login without TLS is refused" \
  "${gcp_args[@]}" --set global.redis.deploy=false --set global.redis.host=10.0.0.6 \
  --set global.redis.authMode=iam
assert_render_fails_with 'database 0 only' \
  "redis cluster guard: a non-zero database is refused" \
  "${gcp_args[@]}" "${redis_args[@]}" --set agentgateway.redis.db=3
assert_render_fails_with 'describe a Redis you run' \
  "redis guard: cluster against the chart's own Redis is refused" \
  --set global.redis.cluster=true
out3d_none="$TMP/scenario-external-no-redis-cloud.yaml"
render_default "$out3d_none" --set global.deploymentMode=external
assert_not_contains "$out3d_none" 'REDIS_CLUSTER|REDIS_TLS_CA_FILE|name: redis-ca' \
  "no cloud Redis: nothing renders by default"

out3c_none="$TMP/scenario-external-no-gcp.yaml"
render_default "$out3c_none" --set global.deploymentMode=external
assert_not_contains "$out3c_none" 'iam\.gke\.io|"gcp"' \
  "no GCP identity: nothing GCP renders by default"
