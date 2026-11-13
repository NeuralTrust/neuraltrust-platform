#!/usr/bin/env bash
# Run through scripts/test-helm-render.sh.
source "$(dirname "$0")/lib.sh"
suite_full || exit 0

blue "==> Scenario 40: gateway decision backends and detector double checks"
FW_ARGS=(--set global.firewall.deploy=true)
DECISION_ARGS=("${FW_ARGS[@]}" --set firewall.firewall.gateway.decision.enabled=true)
KEY_ARGS=(--set firewall.firewall.gateway.decision.apiKeyExistingSecret.name=decision-key)

out="$TMP/default.yaml"
render_default "$out" "${FW_ARGS[@]}"
assert_not_contains "$out" DECISION_SERVICE_ "decision backend adds no env by default"

out="$TMP/decision.yaml"
render_default "$out" "${DECISION_ARGS[@]}" "${KEY_ARGS[@]}" \
  --set firewall.firewall.gateway.decision.provider=liquid \
  --set firewall.firewall.gateway.decision.model=d1-ultra \
  --set firewall.firewall.gateway.decision.doubleCheck=true \
  --set firewall.firewall.gateway.decision.url=https://decision.example.test/systemone \
  --set firewall.firewall.gateway.decision.apiKeyExistingSecret.key=token \
  --set firewall.firewall.gateway.decision.timeoutSeconds=20 \
  --set firewall.firewall.gateway.decision.maxRetries=0 \
  --set firewall.firewall.gateway.decision.retryBackoffSeconds=0 \
  --set firewall.firewall.gateway.decision.healthCacheSeconds=0
for pair in PROVIDER=liquid MODEL=d1-ultra DOUBLE_CHECK=true AUTH=api_key \
    URL=https://decision.example.test/systemone TIMEOUT_S=20 MAX_RETRIES=0 \
    RETRY_BACKOFF_S=0 HEALTH_CACHE_S=0 API_KEY=secretKeyRef:decision-key/token; do
  assert_env_value "$out" firewall gateway "DECISION_SERVICE_${pair%%=*}" "${pair#*=}" \
    "gateway decision setting $pair"
done
ruby -ryaml -e '
  docs = YAML.load_stream(File.read(ARGV[0])).compact
  docs.each do |d|
    if %w[Secret ConfigMap].include?(d["kind"])
      abort "decision env leaked into #{d["kind"]}" if ((d["data"] || {}).keys + (d["stringData"] || {}).keys).any? { |k| k.start_with?("DECISION_SERVICE_") }
    end
    next unless d["kind"] == "Deployment"
    d.dig("spec", "template", "spec", "containers").each do |c|
      env = c.fetch("env", []).map { |e| e["name"] }
      abort "duplicate env" unless env.uniq == env
      next if d.dig("metadata", "name") == "firewall"
      abort "decision env leaked to #{d.dig("metadata", "name")}" if env.any? { |k| k.start_with?("DECISION_SERVICE_") }
    end
  end
' "$out"
green "ok  - decision credentials and settings reach only the gateway, with no duplicate env"

# General LLMs require a model. Both provider families accept Secret references.
for provider in typesafe cloudflare openai google gemini openai_chat anthropic; do
  out="$TMP/$provider.yaml"
  args=("${DECISION_ARGS[@]}" "${KEY_ARGS[@]}" --set "firewall.firewall.gateway.decision.provider=$provider")
  case "$provider" in
    cloudflare) args+=(--set firewall.firewall.gateway.decision.cloudflareAccountId=account-123) ;;
    gemini|openai_chat|anthropic) args+=(--set firewall.firewall.gateway.decision.model=test-model) ;;
  esac
  render_default "$out" "${args[@]}"
  assert_env_value "$out" firewall gateway DECISION_SERVICE_PROVIDER "$provider" "$provider provider renders"
  assert_env_value "$out" firewall gateway DECISION_SERVICE_DOUBLE_CHECK false "$provider can serve decision routes without double checking"
  assert_env_value "$out" firewall gateway DECISION_SERVICE_API_KEY secretKeyRef:decision-key/DECISION_SERVICE_API_KEY \
    "$provider uses the default Secret key"
done
assert_env_value "$TMP/cloudflare.yaml" firewall gateway DECISION_SERVICE_CLOUDFLARE_ACCOUNT_ID account-123 \
  "Cloudflare receives the account ID"

# Entra identity must work even when Redis uses password authentication.
out="$TMP/entra.yaml"
render_default "$out" "${DECISION_ARGS[@]}" \
  --set firewall.firewall.gateway.decision.provider=azure_foundry \
  --set firewall.firewall.gateway.decision.auth=entra \
  --set firewall.firewall.gateway.decision.model=deployment \
  --set firewall.firewall.gateway.decision.url=https://foundry.example.test \
  --set firewall.firewall.gateway.decision.entraScope=https://scope.example.test/.default \
  --set global.azureIdentity.method=service-principal \
  --set global.azureIdentity.clientId=client --set global.azureIdentity.tenantId=tenant \
  --set global.azureIdentity.clientSecret.name=azure-credential
assert_env_value "$out" firewall gateway AZURE_CLIENT_ID client "decision Entra auth receives the client ID"
assert_env_value "$out" firewall gateway AZURE_CLIENT_SECRET secretKeyRef:azure-credential/AZURE_CLIENT_SECRET \
  "decision Entra auth receives the client Secret reference"
assert_env_value "$out" firewall gateway DECISION_SERVICE_ENTRA_SCOPE https://scope.example.test/.default \
  "Foundry receives the custom Entra scope"
assert_env_value "$out" firewall gateway DECISION_SERVICE_API_KEY ABSENT "Entra auth has no API-key reference"

out="$TMP/aks.yaml"
render_default "$out" "${DECISION_ARGS[@]}" \
  --set firewall.firewall.gateway.decision.provider=microsoft \
  --set firewall.firewall.gateway.decision.auth=entra \
  --set global.azureIdentity.method=workload-identity \
  --set global.azureIdentity.clientId=client --set global.azureIdentity.applyGlobally=true
document_named_kind "$out" Deployment firewall "$TMP/gateway.yaml"
assert_contains "$TMP/gateway.yaml" 'azure.workload.identity/use: "true"' "decision Entra auth activates the AKS webhook"
document_named_kind "$out" ServiceAccount firewall "$TMP/sa.yaml"
assert_contains "$TMP/sa.yaml" 'azure.workload.identity/client-id: client' "Firewall ServiceAccount receives the Azure identity"

out="$TMP/vertex.yaml"
render_default "$out" "${DECISION_ARGS[@]}" \
  --set firewall.firewall.gateway.decision.provider=vertex \
  --set firewall.firewall.gateway.decision.model=test-model \
  --set firewall.firewall.gateway.decision.project=test-project \
  --set firewall.firewall.gateway.decision.location=europe-west1 \
  --set firewall.firewall.serviceAccount.create=false \
  --set firewall.firewall.serviceAccount.name=existing-firewall
assert_env_value "$out" firewall gateway DECISION_SERVICE_PROJECT test-project "Vertex receives the project"
assert_env_value "$out" firewall gateway DECISION_SERVICE_LOCATION europe-west1 "Vertex receives the location"
assert_env_value "$out" firewall gateway DECISION_SERVICE_API_KEY ABSENT "Vertex uses Google credentials without a Secret"
document_named_kind "$out" Deployment firewall "$TMP/gateway.yaml"
assert_contains "$TMP/gateway.yaml" 'serviceAccountName: existing-firewall' "gateway selects the pre-created identity ServiceAccount"

blue "==> Scenario 40b: invalid decision configuration fails at render time"
assert_render_fails_with 'doubleCheck=true requires decision.enabled=true' "double check needs an enabled backend" \
  "${FW_ARGS[@]}" --set firewall.firewall.gateway.decision.doubleCheck=true
assert_render_fails_with 'apiKeyExistingSecret.name is required' "API-key auth needs a Secret" "${DECISION_ARGS[@]}"
assert_render_fails_with 'provider must be one of' "unknown providers fail" "${DECISION_ARGS[@]}" \
  --set firewall.firewall.gateway.decision.provider=unknown
assert_render_fails_with 'auth must be api_key or entra' "unknown auth fails" "${DECISION_ARGS[@]}" \
  --set firewall.firewall.gateway.decision.auth=unknown
assert_render_fails_with 'auth=entra requires provider=microsoft or azure_foundry' "Entra needs an Azure backend" \
  "${DECISION_ARGS[@]}" --set firewall.firewall.gateway.decision.auth=entra
assert_render_fails_with 'model is required' "general LLM needs a model" "${DECISION_ARGS[@]}" "${KEY_ARGS[@]}" \
  --set firewall.firewall.gateway.decision.provider=gemini
assert_render_fails_with 'url is required' "Foundry needs a resource endpoint" "${DECISION_ARGS[@]}" "${KEY_ARGS[@]}" \
  --set firewall.firewall.gateway.decision.provider=azure_foundry --set firewall.firewall.gateway.decision.model=test-model
assert_render_fails_with 'project is required' "Vertex needs a project" "${DECISION_ARGS[@]}" \
  --set firewall.firewall.gateway.decision.provider=vertex --set firewall.firewall.gateway.decision.model=test-model
assert_render_fails_with 'cloudflareAccountId is required' "Cloudflare needs an account or URL" \
  "${DECISION_ARGS[@]}" "${KEY_ARGS[@]}" --set firewall.firewall.gateway.decision.provider=cloudflare
assert_render_fails_with 'apiKeyExistingSecret.name is unused' "identity auth rejects an unused API key" \
  "${DECISION_ARGS[@]}" "${KEY_ARGS[@]}" --set firewall.firewall.gateway.decision.provider=microsoft \
  --set firewall.firewall.gateway.decision.auth=entra
assert_render_fails_with 'remove DECISION_SERVICE_MODEL from gateway.extraEnv' "duplicate explicit decision env fails" \
  "${DECISION_ARGS[@]}" "${KEY_ARGS[@]}" \
  --set 'firewall.firewall.gateway.extraEnv[0].name=DECISION_SERVICE_MODEL' \
  --set 'firewall.firewall.gateway.extraEnv[0].value=custom-model'

# Legacy env remains usable with the first-class block off.
out="$TMP/legacy.yaml"
render_default "$out" "${FW_ARGS[@]}" \
  --set 'firewall.firewall.gateway.extraEnv[0].name=DECISION_SERVICE_MODEL' \
  --set 'firewall.firewall.gateway.extraEnv[0].value=legacy-model'
assert_env_value "$out" firewall gateway DECISION_SERVICE_MODEL legacy-model "legacy decision env still works"

# An unconfigured, undeployed Firewall cannot block a hosted-Firewall install.
render_default "$TMP/hosted.yaml" --set firewall.firewall.gateway.decision.enabled=true
assert_not_contains "$TMP/hosted.yaml" DECISION_SERVICE_ "hosted Firewall ignores local decision settings"
