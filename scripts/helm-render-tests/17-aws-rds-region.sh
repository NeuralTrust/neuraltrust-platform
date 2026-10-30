#!/usr/bin/env bash
# Render scenarios 16. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

# IRSA supplies a role and a token file, not a region, and the SDK fails the
# token request without one.
blue "==> Scenario 16: AWS region for RDS IAM on the Go gateways"
out16="$TMP/scenario-aws-region.yaml"
render_default "$out16" --set global.deploymentMode=external \
  --set global.postgresql.awsRegion=eu-west-1 \
  --set agentgateway.database.iamAuth=true --set trustguard.database.iamAuth=true
assert_contains "$out16" 'AWS_REGION: "eu-west-1"' \
  "external: the IAM gateways are told which region to sign for"
ruby -ryaml -e '
  docs = []
  YAML.load_stream(File.read(ARGV.fetch(0), encoding: "UTF-8")) { |d| docs << d if d.is_a?(Hash) }
  %w[agentgateway-env-vars trustguard-env-vars].each do |name|
    cm = docs.find { |d| d["kind"] == "ConfigMap" && d.dig("metadata", "name") == name }
    abort "#{name} not rendered" if cm.nil?
    got = cm.fetch("data")["AWS_REGION"]
    abort "#{name} has no AWS_REGION (IAM token minting will fail)" if got.nil?
    abort "#{name} AWS_REGION=#{got.inspect}" unless got == "eu-west-1"
  end
' "$out16" || { red "FAIL: an IAM gateway was left without a region"; exit 1; }
green "ok  - both Go gateways carry the region their SigV4 signer needs"

out16sub="$TMP/scenario-aws-region-subchart.yaml"
render_default "$out16sub" --set global.deploymentMode=external \
  --set global.postgresql.awsRegion=eu-west-1 \
  --set agentgateway.database.iamAuth=true \
  --set agentgateway.database.awsRegion=us-east-2
assert_contains "$out16sub" 'AWS_REGION: "us-east-2"' \
  "a per-chart region overrides the global one"

out16off="$TMP/scenario-aws-region-noniam.yaml"
render_default "$out16off" --set global.deploymentMode=external \
  --set global.postgresql.awsRegion=eu-west-1
assert_not_contains "$out16off" 'agentgateway[\s\S]{0,200}AWS_REGION' \
  "no region is emitted for the gateways when IAM is off"
