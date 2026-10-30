#!/usr/bin/env bash
# Render scenarios 22. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

blue "==> Scenario 22: firewall Redis cache from shared Redis"
# Wired to the shared Redis by default. A firewall pod with REDIS_HOST set exits
# when Redis is unreachable at startup, so it must only be set when Redis exists.
fw_redis_keys() {
  ruby -ryaml -e '
    docs = YAML.load_stream(File.read(ARGV[0])).compact
    cm = docs.find { |d| d["kind"] == "ConfigMap" && d.dig("metadata", "name") == "firewall-config" }
    abort "firewall-config missing" if cm.nil?
    puts cm["data"].select { |k, _| k =~ /REDIS/ }.sort.map { |k, v| "#{k}=#{v}" }.join(" ")
  ' "$1"
}
assert_fw_redis() {
  local file="$1" want="$2" msg="$3" got
  got="$(fw_redis_keys "$file")" || { red "FAIL: $msg"; exit 1; }
  if [[ "$got" != "$want" ]]; then
    red "FAIL: $msg"
    echo "  want: $want"
    echo "  got:  $got"
    exit 1
  fi
  green "ok  - $msg"
}
out22="$TMP/scenario-firewall-redis.yaml"
render_default "$out22" --set global.deploymentMode=external
assert_fw_redis "$out22" "FIREWALL_CACHE_REDIS=true REDIS_DB=0 REDIS_HOST=redis REDIS_PORT=6379" \
  "firewall-config points the cache at the in-cluster Redis"
# firewall-config's exact key set above already excludes REDIS_URL.
assert_env_value "$out22" firewall gateway REDIS_URL ABSENT \
  "firewall no longer ships the retired REDIS_URL"
out22off="$TMP/scenario-firewall-redis-off.yaml"
render_default "$out22off" --set global.deploymentMode=external --set firewall.firewall.redis.enabled=false
assert_fw_redis "$out22off" "" "firewall.redis.enabled=false opts out of the cache"
out22none="$TMP/scenario-firewall-redis-none.yaml"
render_default "$out22none" --set global.deploymentMode=external --set global.redis.deploy=false
assert_fw_redis "$out22none" "" "no Redis deployed and no host: firewall runs without the cache"
# A password must land in the Secret, not the ConfigMap. validate-values rejects
# a password against the chart's own Redis, so point at a managed host the same
# way operators do.
out22pw="$TMP/scenario-firewall-redis-pw.yaml"
render_default "$out22pw" --set global.deploymentMode=external \
  --set global.redis.deploy=false \
  --set global.redis.host=cache.example.com \
  --set global.redis.username=fw \
  --set-string global.redis.tls=true \
  --set global.redis.password=s3cret
assert_fw_redis "$out22pw" \
  "FIREWALL_CACHE_REDIS=true REDIS_DB=0 REDIS_HOST=cache.example.com REDIS_PORT=6379 REDIS_TLS=true REDIS_USERNAME=fw" \
  "firewall-config follows a managed global.redis"
if ! ruby -ryaml -e '
  docs = YAML.load_stream(File.read(ARGV[0])).compact
  sec = docs.find { |d| d["kind"] == "Secret" && d.dig("metadata", "name") == "firewall-secrets" }
  abort "firewall-secrets missing" if sec.nil?
  pw = sec.dig("data", "REDIS_PASSWORD").to_s.unpack1("m0")
  abort "firewall-secrets REDIS_PASSWORD=#{pw.inspect}" unless pw == "s3cret"
' "$out22pw"; then
  red "FAIL: firewall REDIS_PASSWORD placement"
  exit 1
fi
green "ok  - firewall REDIS_PASSWORD lives in firewall-secrets"
for w in "firewall:gateway" "toxicity-worker:worker" "topic-guard-worker:worker"; do
  IFS=: read -r workload container <<< "$w"
  assert_env_value "$out22pw" "$workload" "$container" REDIS_PASSWORD secretKeyRef:firewall-secrets/REDIS_PASSWORD \
    "firewall redis: $workload reads REDIS_PASSWORD from firewall-secrets"
done
assert_env_value "$out22" firewall gateway REDIS_PASSWORD ABSENT \
  "firewall redis: no REDIS_PASSWORD for the passwordless in-cluster Redis"
out22gcp="$TMP/scenario-firewall-redis-gcp.yaml"
render_default "$out22gcp" "${gcp_args[@]}" --set global.redis.deploy=false \
  --set global.redis.host=10.0.0.6 --set global.redis.tls=true --set global.redis.authMode=iam
assert_fw_redis "$out22gcp" \
  "FIREWALL_CACHE_REDIS=true REDIS_DB=0 REDIS_HOST=10.0.0.6 REDIS_LOGIN=gcp REDIS_PORT=6379 REDIS_TLS=true REDIS_TLS_INSECURE_SKIP_VERIFY=true" \
  "firewall redis: Memorystore IAM logs in with a GCP token"
out22cluster="$TMP/scenario-firewall-redis-cluster.yaml"
render_default "$out22cluster" "${gcp_args[@]}" "${redis_args[@]}"
assert_fw_redis "$out22cluster" "" "firewall redis: a Redis Cluster is skipped (client is not cluster-aware)"
fw_managed_redis=(
  --set global.deploymentMode=external
  --set global.redis.deploy=false
  --set global.redis.host=cache.example.com
  --set-string global.redis.tls=true
)
out22aws="$TMP/scenario-firewall-redis-aws.yaml"
render_default "$out22aws" "${fw_managed_redis[@]}" --set global.redis.password=unused \
  --set firewall.firewall.redis.login=aws \
  --set firewall.firewall.redis.iamUser=fw-user \
  --set firewall.firewall.redis.iamCacheName=my-cache \
  --set firewall.firewall.redis.iamRegion=eu-west-1
assert_fw_redis "$out22aws" \
  "FIREWALL_CACHE_REDIS=true REDIS_CACHE_NAME=my-cache REDIS_DB=0 REDIS_HOST=cache.example.com REDIS_LOGIN=aws REDIS_PORT=6379 REDIS_TLS=true REDIS_USERNAME=fw-user" \
  "firewall redis: ElastiCache IAM login"
assert_contains "$out22aws" '^  AWS_REGION: "eu-west-1"$' \
  "firewall redis: ElastiCache IAM region in firewall-config"
assert_env_value "$out22aws" firewall gateway REDIS_PASSWORD ABSENT \
  "firewall redis: no password with the ElastiCache IAM login"
out22az="$TMP/scenario-firewall-redis-azure.yaml"
render_default "$out22az" "${fw_managed_redis[@]}" \
  --set firewall.firewall.redis.login=azure \
  --set global.azureIdentity.method=service-principal \
  --set global.azureIdentity.clientId=cid \
  --set global.azureIdentity.tenantId=tid \
  --set global.azureIdentity.clientSecret.name=sp
assert_fw_redis "$out22az" \
  "FIREWALL_CACHE_REDIS=true REDIS_DB=0 REDIS_HOST=cache.example.com REDIS_LOGIN=azure REDIS_PORT=6379 REDIS_TLS=true" \
  "firewall redis: Entra ID login"
for w in "firewall:gateway" "topic-guard-worker:worker"; do
  IFS=: read -r workload container <<< "$w"
  assert_env_value "$out22az" "$workload" "$container" AZURE_CLIENT_SECRET secretKeyRef:sp/AZURE_CLIENT_SECRET \
    "firewall redis: $workload gets the service principal for Entra ID"
done
assert_render_fails_with 'redis.login=aws needs firewall.firewall.redis.iamUser' \
  "firewall redis guard: aws login needs the IAM user and cache name" \
  "${fw_managed_redis[@]}" --set firewall.firewall.redis.login=aws
assert_render_fails_with 'redis.login=azure needs global.azureIdentity.method' \
  "firewall redis guard: azure login needs an Azure identity" \
  "${fw_managed_redis[@]}" --set firewall.firewall.redis.login=azure
assert_render_fails_with 'redis.login=aws describes a managed Redis' \
  "firewall redis guard: a token login against the chart's own Redis is refused" \
  --set global.deploymentMode=external --set firewall.firewall.redis.login=aws
