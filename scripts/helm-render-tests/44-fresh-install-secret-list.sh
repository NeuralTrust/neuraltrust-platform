#!/usr/bin/env bash
# Render scenario 44. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

# The exact Secrets a fresh install of each documented shape ends up with: the
# ones Helm renders, plus the ones the in-cluster secrets generator creates
# (platform-secrets and the TLS keypairs its spec ConfigMaps name). 32-secret-shape
# blocks empty and config-only Secrets; this pins the list itself, so a Secret
# cannot quietly come back. Renders with the chart's own defaults (generator
# included), unlike render_default. Changing a list here is a deliberate,
# documented change: update SECRETS.md ("Secrets per install shape") with it.
blue "==> Scenario 44: fresh-install Secret list per documented shape"

SHAPES=(
  "hybrid|values-required.yaml|agentgateway-secrets data-plane-jwt-secret neuraltrust-ingress-tls platform-secrets postgresql-secrets redis-secrets trustguard-client-credentials trustguard-secrets"
  "hybrid-managed|values-hybrid.yaml.example|agentgateway-secrets data-plane-jwt-secret neuraltrust-ingress-tls platform-secrets postgresql-secrets trustguard-client-credentials trustguard-secrets"
  "hybrid-trustgate|values-trustgate.yaml.example|agentgateway-secrets neuraltrust-ingress-tls platform-secrets postgresql-secrets redis-secrets"
  "hybrid-trustguard|values-trustguard.yaml.example|neuraltrust-ingress-tls platform-secrets postgresql-secrets redis-secrets trustguard-secrets"
  "hybrid-red-teaming|values-red-teaming.yaml.example|data-plane-jwt-secret neuraltrust-ingress-tls platform-secrets postgresql-secrets redis-secrets"
  "hybrid-gpu|values-required.yaml,values-dataplane-gpu.yaml.example|agentgateway-secrets data-plane-jwt-secret firewall-secrets neuraltrust-ingress-tls platform-secrets postgresql-secrets redis-secrets trustguard-client-credentials trustguard-secrets"
  "external|values-external.yaml.example|agentgateway-configsync-tls neuraltrust-ingress-tls platform-secrets postgresql-secrets trustguard-configsync-tls"
  "external-managed|values-managed-datastores.yaml.example|"
  "external-trustguard-only|values-external.yaml.example,values-external-trustguard-only.yaml.example|neuraltrust-ingress-tls platform-secrets postgresql-secrets trustguard-configsync-tls"
  "external-observability|values-external.yaml.example,values-observability-self-hosted.yaml.example|agentgateway-configsync-tls neuraltrust-ingress-tls platform-secrets postgresql-secrets trustguard-configsync-tls"
  "dedicated-trustgate|values-dedicated.yaml.example|agentgateway-secrets redis-secrets"
  "saas|values-required.yaml|agentgateway-configsync-tls databridge-southbound-tls neuraltrust-ingress-tls platform-secrets postgresql-secrets trustguard-configsync-tls"
)

secret_list() {
  ruby -ryaml -rjson -e '
    names = []
    gen = nil
    YAML.load_stream(File.read(ARGV.fetch(0), encoding: "UTF-8")) do |d|
      next unless d.is_a?(Hash)
      names << d.dig("metadata", "name") if d["kind"] == "Secret"
      if d["kind"] == "Job" && d.dig("metadata", "name").to_s.end_with?("secrets-generator")
        (d.dig("spec", "template", "spec", "containers") || []).each do |c|
          (c["env"] || []).each { |e| gen = e["value"] if e["name"] == "GENERATED_SECRET" }
        end
      end
      if d["kind"] == "ConfigMap" && (d.dig("metadata", "labels") || {}).key?("neuraltrust.ai/generator-spec")
        JSON.parse(d.dig("data", "spec.json") || "[]").each { |e| names << e["secret"] if e["secret"] }
      end
    end
    names << gen if gen
    puts names.compact.uniq.sort.join(" ")
  ' "$1"
}

for row in "${SHAPES[@]}"; do
  IFS='|' read -r shape files expected <<<"$row"
  args=()
  IFS=',' read -r -a value_files <<<"$files"
  for f in "${value_files[@]}"; do args+=(-f "$CHART_DIR/$f"); done
  if [[ "$shape" == saas ]]; then
    args+=(--set global.deploymentMode=saas --set global.domain=cp.example.com)
  fi
  out="$TMP/fresh-secrets-$shape.yaml"
  helm template neuraltrust-platform "$CHART_DIR" --namespace neuraltrust "${args[@]}" > "$out"
  actual="$(secret_list "$out")"
  if [[ "$actual" == "$expected" ]]; then
    green "ok  - $shape: fresh install ends with exactly its documented Secrets"
  else
    red "FAIL: $shape: the fresh-install Secret list changed"
    red "  expected: $expected"
    red "  actual:   $actual"
    exit 1
  fi
done
