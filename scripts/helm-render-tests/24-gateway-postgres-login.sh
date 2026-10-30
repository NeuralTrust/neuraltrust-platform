#!/usr/bin/env bash
# Render scenarios 23. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

blue "==> Scenario 23: umbrella IAM drives gateway POSTGRES_LOGIN"
# global.authMode=iam + unset per-service ⇒ POSTGRES_LOGIN=aws
out23iam="$TMP/scenario-iam-inherit.yaml"
render_default "$out23iam" --set global.deploymentMode=external \
  --set global.postgresql.deploy=false \
  --set global.postgresql.host=pg.example.com \
  --set global.postgresql.authMode=iam \
  --set global.postgresql.awsRegion=eu-west-1
if ! ruby -ryaml -e '
  docs = YAML.load_stream(File.read(ARGV[0])).compact
  %w[agentgateway-env-vars trustguard-env-vars].each do |name|
    cm = docs.find { |d| d["kind"] == "ConfigMap" && d.dig("metadata", "name") == name }
    abort "#{name} not rendered" if cm.nil?
    login = cm.dig("data", "POSTGRES_LOGIN")
    abort "#{name} POSTGRES_LOGIN=#{login.inspect}, want aws" unless login == "aws"
    region = cm.dig("data", "AWS_REGION")
    abort "#{name} AWS_REGION=#{region.inspect}, want eu-west-1" unless region == "eu-west-1"
  end
' "$out23iam"; then
  red "FAIL: global IAM inheritance"
  exit 1
fi
green "ok  - global.postgresql.authMode=iam ⇒ POSTGRES_LOGIN=aws"

# Explicit per-service false still wins against global iam.
out23off="$TMP/scenario-iam-override-off.yaml"
render_default "$out23off" --set global.deploymentMode=external \
  --set global.postgresql.deploy=false \
  --set global.postgresql.host=pg.example.com \
  --set global.postgresql.authMode=iam \
  --set global.postgresql.awsRegion=eu-west-1 \
  --set agentgateway.database.iamAuth=false
if ! ruby -ryaml -e '
  docs = YAML.load_stream(File.read(ARGV[0])).compact
  ag = docs.find { |d| d["kind"] == "ConfigMap" && d.dig("metadata", "name") == "agentgateway-env-vars" }
  abort "agentgateway-env-vars not rendered" if ag.nil?
  login = ag.dig("data", "POSTGRES_LOGIN")
  abort "explicit iamAuth=false should leave POSTGRES_LOGIN unset, got #{login.inspect}" unless login.nil?
  tg = docs.find { |d| d["kind"] == "ConfigMap" && d.dig("metadata", "name") == "trustguard-env-vars" }
  abort "trustguard-env-vars not rendered" if tg.nil?
  tlogin = tg.dig("data", "POSTGRES_LOGIN")
  abort "trustguard should still inherit global IAM, got #{tlogin.inspect}" unless tlogin == "aws"
' "$out23off"; then
  red "FAIL: explicit iamAuth=false override"
  exit 1
fi
green "ok  - explicit iamAuth=false wins; sibling still inherits"
