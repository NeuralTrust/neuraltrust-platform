#!/usr/bin/env bash
# Render scenarios 39, 39b, 39c, 39d. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

# data-plane-api under AWS RDS IAM (global.postgresql.authMode=iam, no Azure or
# GCP identity). Before, it was handed the empty password an IAM install's
# shared Secret carries, PGSSLMODE=prefer and no login switch, so it could not
# connect while every other hybrid service logged in with IAM.
blue "==> Scenario 39: data-plane-api logs in to RDS with IAM"

AWS_IAM_ARGS=(
  --set global.products.dataPlane=true
  --set global.postgresql.deploy=false
  --set global.postgresql.host=pg.abc123.eu-west-1.rds.amazonaws.com
  --set global.postgresql.authMode=iam
  --set global.postgresql.awsRegion=eu-west-1
)

out39="$TMP/scenario-dp-rds-iam.yaml"
render_default "$out39" "${AWS_IAM_ARGS[@]}" \
  --set global.postgresql.sslMode=require \
  --set global.irsa.roleArn=arn:aws:iam::123456789012:role/neuraltrust \
  --set global.irsa.applyGlobally=true
# The schema initContainer goes through the API's connection code, so both
# containers need the same login.
for c in api postgres-migrations; do
  assert_env_value "$out39" data-plane-api "$c" POSTGRES_LOGIN aws \
    "RDS IAM: data-plane-api/$c logs in with an IAM token"
  assert_env_value "$out39" data-plane-api "$c" AWS_REGION eu-west-1 \
    "RDS IAM: data-plane-api/$c receives the region it signs the token for"
  assert_env_value "$out39" data-plane-api "$c" POSTGRES_PASSWORD ABSENT \
    "RDS IAM: data-plane-api/$c references no password"
  assert_env_value "$out39" data-plane-api "$c" PGSSLMODE require \
    "RDS IAM: data-plane-api/$c inherits global.postgresql.sslMode"
  assert_env_value "$out39" data-plane-api "$c" POSTGRES_SSL require \
    "RDS IAM: data-plane-api/$c passes the TLS mode to the token login"
  assert_env_value "$out39" data-plane-api "$c" POSTGRES_AUTH_MODE ABSENT \
    "RDS IAM: data-plane-api/$c gets no Entra auth mode"
done
# The evaluation Jobs run under this ServiceAccount and inherit the login, so
# the IRSA role has to be on it.
ruby -ryaml -e '
  sa = nil
  YAML.load_stream(File.read(ARGV.fetch(0), encoding: "UTF-8")) do |d|
    sa = d if d.is_a?(Hash) && d["kind"] == "ServiceAccount" && d.dig("metadata", "name") == "data-plane"
  end
  abort "data-plane ServiceAccount not rendered" if sa.nil?
  got = (sa.dig("metadata", "annotations") || {})["eks.amazonaws.com/role-arn"]
  abort "role-arn=#{got.inspect}" unless got == "arn:aws:iam::123456789012:role/neuraltrust"
' "$out39" || { red "FAIL: the data-plane ServiceAccount has no IRSA role"; exit 1; }
green "ok  - RDS IAM: the data-plane ServiceAccount carries the global IRSA role"

# 39b. An unset sslMode takes the require default the shared Secret uses under
# IAM; verify-full reaches the token login instead of being lowered to require.
blue "==> Scenario 39b: data-plane-api RDS IAM TLS mode"
out39b="$TMP/scenario-dp-rds-iam-verify.yaml"
render_default "$out39b" "${AWS_IAM_ARGS[@]}" --set global.postgresql.sslMode=verify-full
for c in api postgres-migrations; do
  assert_env_value "$out39b" data-plane-api "$c" POSTGRES_SSL verify-full \
    "RDS IAM: data-plane-api/$c keeps verify-full"
done
out39b2="$TMP/scenario-dp-rds-iam-ssl-unset.yaml"
render_default "$out39b2" "${AWS_IAM_ARGS[@]}" --set global.postgresql.sslMode=
assert_env_value "$out39b2" data-plane-api api PGSSLMODE require \
  "RDS IAM: an unset sslMode resolves to require, as in the shared Secret"

# 39c. A Secret of the operator's own gives data-plane-api a separate password
# login (the interim setup before RDS IAM was wired). It must keep working on
# upgrade, untouched by the global IAM switch.
blue "==> Scenario 39c: data-plane-api with its own password Secret under global IAM"
out39c="$TMP/scenario-dp-rds-iam-own-secret.yaml"
render_default "$out39c" "${AWS_IAM_ARGS[@]}" \
  --set global.postgresql.sslMode=require \
  --set data-plane-api.dataPlane.components.api.database.postgresql.host=pg.abc123.eu-west-1.rds.amazonaws.com \
  --set data-plane-api.dataPlane.components.api.database.postgresql.existingSecret.name=data-plane-api-postgres \
  --set data-plane-api.dataPlane.components.api.database.postgresql.existingSecret.keys.password=password
for c in api postgres-migrations; do
  assert_env_value "$out39c" data-plane-api "$c" POSTGRES_LOGIN ABSENT \
    "own Secret: data-plane-api/$c stays on password auth"
  assert_env_value "$out39c" data-plane-api "$c" POSTGRES_PASSWORD \
    secretKeyRef:data-plane-api-postgres/password \
    "own Secret: data-plane-api/$c reads the operator's password"
  assert_env_value "$out39c" data-plane-api "$c" AWS_REGION ABSENT \
    "own Secret: data-plane-api/$c gets no IAM region"
  assert_env_value "$out39c" data-plane-api "$c" PGSSLMODE prefer \
    "own Secret: data-plane-api/$c does not inherit the global sslMode"
done

# 39d. An operator AWS_REGION in extraEnv wins and is not duplicated: two
# entries under one name break the next helm upgrade.
blue "==> Scenario 39d: data-plane-api RDS IAM region override"
out39d="$TMP/scenario-dp-rds-iam-region-override.yaml"
render_default "$out39d" "${AWS_IAM_ARGS[@]}" \
  --set global.postgresql.sslMode=require \
  --set 'data-plane-api.dataPlane.components.api.extraEnv[0].name=AWS_REGION' \
  --set 'data-plane-api.dataPlane.components.api.extraEnv[0].value=us-east-2'
ruby -ryaml -e '
  YAML.load_stream(File.read(ARGV.fetch(0), encoding: "UTF-8")) do |d|
    next unless d.is_a?(Hash) && d["kind"] == "Deployment" && d.dig("metadata", "name") == "data-plane-api"
    spec = d.dig("spec", "template", "spec")
    ((spec["containers"] || []) + (spec["initContainers"] || [])).each do |c|
      regions = (c["env"] || []).select { |e| e["name"] == "AWS_REGION" }
      next if c["name"] != "api" && c["name"] != "postgres-migrations"
      abort "#{c["name"]}: #{regions.size} AWS_REGION entries" unless regions.size == 1
      abort "#{c["name"]}: AWS_REGION=#{regions[0]["value"]}" unless regions[0]["value"] == "us-east-2"
    end
  end
' "$out39d" || { red "FAIL: extraEnv AWS_REGION duplicated or overridden"; exit 1; }
green "ok  - RDS IAM: an extraEnv AWS_REGION wins with no duplicate entry"

# Password installs are unchanged: shared password, prefer.
out39e="$TMP/scenario-dp-password.yaml"
render_default "$out39e" --set global.products.dataPlane=true
assert_env_value "$out39e" data-plane-api api POSTGRES_LOGIN ABSENT \
  "password install: data-plane-api gets no login switch"
assert_env_value "$out39e" data-plane-api api POSTGRES_PASSWORD \
  secretKeyRef:postgresql-secrets/POSTGRES_PASSWORD \
  "password install: data-plane-api reads the shared password"
assert_env_value "$out39e" data-plane-api api PGSSLMODE prefer \
  "password install: data-plane-api keeps sslMode prefer"
