#!/usr/bin/env bash
# Render scenarios 10, 10e, 10b, 10b2, 10b3, 10b4b, 10b5, 10b6, 10c1, 10b7, 10b9, 10c0, 10c, 10d, 10f, 10g. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

# ---------------------------------------------------------------------------
# 10. Watchdog defaults + firewall disable sync + hybrid ClickStack channels
# ---------------------------------------------------------------------------
blue "==> Scenario 10: watchdog otel-collector target and topology-neutral checks"
out10="$TMP/scenario-watchdog-defaults.yaml"
render_default "$out10" \
  --set global.observability.enabled=true \
  --set global.observability.hostedExport.enabled=false \
  --set watchdog.enabled=true
assert_contains "$out10" 'url: http://otel-collector:13133/' \
  "watchdog: otel-collector check targets umbrella Service"
assert_contains "$out10" 'labelSelector: app.kubernetes.io/component=otel-collector' \
  "watchdog: otel-collector selector matches umbrella labels"
assert_contains "$out10" 'endpoint: \[::\]:4317' \
  "observability: umbrella otel-collector OTLP gRPC binds dual-stack"
assert_contains "$out10" 'endpoint: \[::\]:13133' \
  "observability: umbrella otel-collector health binds dual-stack"
assert_contains "$out10" 'host: "::"' \
  "observability: umbrella otel-collector telemetry metrics host is ::"
# Hybrid render must not enable the clickhouse check by default.
assert_contains "$out10" 'enabled: false'$'\n''        id: clickhouse' \
  "watchdog: clickhouse check stays off in hybrid defaults"
# hybrid ClickStack egress + hostedExport.enabled=false honoured.
assert_env_value "$out10" neuraltrust-watchdog watchdog OTEL_EXPORTER_OTLP_ENDPOINT \
  'http://clickstack-egress-collector.default.svc.cluster.local:4318' \
  "watchdog hybrid: OTLP is signal-neutral ClickStack egress :4318"
assert_env_value "$out10" neuraltrust-watchdog watchdog OPENTELEMETRY_AUTH_TOKEN ABSENT \
  "watchdog hybrid: no hosted OPENTELEMETRY_AUTH_TOKEN"
assert_not_contains "$out10" 'name: neuraltrust-observability-token' \
  "hostedExport false: observability token Secret is omitted"
assert_not_contains "$out10" 'collector\.neuraltrust\.ai' \
  "hostedExport false: no collector.neuraltrust.ai default on watchdog path"

blue "==> Scenario 10e: watchdog telemetry.otlp.endpoint override wins"
out10e="$TMP/scenario-watchdog-otlp-override.yaml"
render_default "$out10e" \
  --set watchdog.enabled=true \
  --set watchdog.telemetry.otlp.endpoint=https://otel.example.com:4318 \
  --set watchdog.telemetry.otlp.headers='authorization=test-token'
assert_env_value "$out10e" neuraltrust-watchdog watchdog OTEL_EXPORTER_OTLP_ENDPOINT \
  'https://otel.example.com:4318' \
  "watchdog override: explicit otlp.endpoint wins over ClickStack default"
assert_env_value "$out10e" neuraltrust-watchdog watchdog OTEL_EXPORTER_OTLP_HEADERS \
  'authorization=test-token' \
  "watchdog override: explicit otlp.headers wins over collector secret mount"
assert_env_value "$out10e" neuraltrust-watchdog watchdog OPENTELEMETRY_AUTH_TOKEN ABSENT \
  "watchdog override: no hosted auth token alongside break-glass headers"

blue "==> Scenario 10b: Firewall follows the TrustGuard product gate"
out10b="$TMP/scenario-firewall-disabled.yaml"
render_default "$out10b" --set global.products.trustguard=false
assert_not_contains "$out10b" 'name: firewall$' \
  "trustguard off: Firewall gateway absent"
assert_not_contains "$out10b" 'name: toxicity-worker' \
  "trustguard off: Firewall workers absent"
assert_not_contains "$out10b" 'name: firewall-secrets' \
  "trustguard off: Firewall Secret absent"
assert_not_contains "$out10b" 'NEURAL_TRUST_FIREWALL_BASE_URL' \
  "trustguard off: no Firewall client wiring"

blue "==> Scenario 10b2: Firewall v2.15 production worker module set"
out10b2="$TMP/scenario-firewall-workers.yaml"
render_default "$out10b2"
assert_contains "$out10b2" 'name: firewall$' \
  "firewall workers: gateway Deployment present"
assert_contains "$out10b2" 'name: toxicity-worker' \
  "firewall workers: toxicity present"
assert_contains "$out10b2" 'name: prompt-jailbreak-worker' \
  "firewall workers: prompt-jailbreak present"
# Retired in the firewall image: no worker module left to serve them.
assert_not_contains "$out10b2" 'name: prompt-moderation-worker' \
  "firewall workers: prompt-moderation retired"
assert_not_contains "$out10b2" 'name: response-jailbreak-worker' \
  "firewall workers: response-jailbreak retired"
assert_not_contains "$out10b2" 'PROMPT_MODERATION_WORKER_URL|RESPONSE_JAILBREAK_WORKER_URL' \
  "firewall workers: no URLs for the retired workers"
if ! ruby -ryaml -e '
  docs = YAML.load_stream(File.read(ARGV[0])).compact
  { "topic-guard-worker" => 2, "prompt-jailbreak-worker" => 2, "toxicity-worker" => 1 }.each do |name, want|
    d = docs.find { |x| x["kind"] == "Deployment" && x.dig("metadata", "name") == name }
    abort "#{name} missing" if d.nil?
    got = d.dig("spec", "replicas")
    abort "#{name} replicas=#{got.inspect}, want #{want}" unless got == want
  end
' "$out10b2"; then
  red "FAIL: firewall worker replica defaults"
  exit 1
fi
green "ok  - topic-guard and prompt-jailbreak default to 2 replicas"
assert_contains "$out10b2" 'name: indirect-prompt-injections-worker' \
  "firewall workers: IPI present"
assert_contains "$out10b2" 'src.workers.indirect_prompt_injections.app:app' \
  "firewall workers: IPI module arg"
assert_contains "$out10b2" 'INDIRECT_PROMPT_INJECTIONS_WORKER_URL: "http://indirect-prompt-injections-worker:80"' \
  "firewall workers: IPI worker URL in ConfigMap"
# topic-guard and complexity complete the image's worker set. Without a worker the
# gateway never gets its <WORKER>_WORKER_URL and falls back to an in-process
# localhost default, which fails every call for that detector.
assert_contains "$out10b2" 'name: topic-guard-worker' \
  "firewall workers: topic-guard present"
assert_contains "$out10b2" 'src.workers.topic_guard.app:app' \
  "firewall workers: topic-guard module arg"
assert_contains "$out10b2" 'TOPIC_GUARD_WORKER_URL: "http://topic-guard-worker:80"' \
  "firewall workers: topic-guard worker URL in ConfigMap"
assert_contains "$out10b2" 'name: complexity-worker' \
  "firewall workers: complexity present"
assert_contains "$out10b2" 'src.workers.complexity.app:app' \
  "firewall workers: complexity module arg"
assert_contains "$out10b2" 'COMPLEXITY_WORKER_URL: "http://complexity-worker:80"' \
  "firewall workers: complexity worker URL in ConfigMap"

blue "==> Scenario 10b3: TrustGate complexity scoring wiring"
out10b3="$TMP/scenario-firewall-complexity-wiring.yaml"
render_default "$out10b3"
# The binary reads FIREWALL_BASE_URL / FIREWALL_SECRET_KEY, and appends
# /v1/complexity — a route on the firewall GATEWAY, so this must be the `firewall`
# Service and not the complexity worker.
# Anchored: TrustGuard's own NEURAL_TRUST_FIREWALL_BASE_URL would match unanchored.
assert_contains "$out10b3" '^  FIREWALL_BASE_URL: "http://firewall\.default\.svc\.cluster\.local"$' \
  "complexity: agentgateway points at the firewall gateway Service"
assert_contains "$out10b3" 'name: FIREWALL_SECRET_KEY' \
  "complexity: agentgateway data plane mounts the firewall signing secret"
# Opting out must remove the variable entirely rather than emit an empty one, or
# the binary would treat "" as configured-but-broken.
out10b4="$TMP/scenario-firewall-complexity-optout.yaml"
render_default "$out10b4" --set agentgateway.config.firewallBaseURL=""
assert_not_contains "$out10b4" '^  FIREWALL_BASE_URL' \
  "complexity: firewallBaseURL=\"\" opts out of scoring"

blue "==> Scenario 10b4b: external Firewall (global.firewall.deploy=false)"
FW_EXTERNAL_ARGS=(
  --set global.firewall.deploy=false
  --set global.firewall.baseURL=http://firewall.firewall.svc.cluster.local/
  --set global.firewall.existingSecret.name=firewall-jwt
)
for fw_mode in hybrid external; do
  out10b4b="$TMP/scenario-firewall-external-$fw_mode.yaml"
  render_default "$out10b4b" --set global.deploymentMode="$fw_mode" "${FW_EXTERNAL_ARGS[@]}"
  assert_not_contains "$out10b4b" 'name: firewall$' \
    "external firewall ($fw_mode): no in-release Firewall gateway"
  assert_not_contains "$out10b4b" 'name: toxicity-worker' \
    "external firewall ($fw_mode): no in-release Firewall workers"
  assert_not_contains "$out10b4b" 'name: firewall-secrets$' \
    "external firewall ($fw_mode): no firewall-secrets (nothing here verifies the JWT)"
  assert_not_contains "$out10b4b" 'name: firewall-config$' \
    "external firewall ($fw_mode): no firewall ConfigMap"
  # Trailing slash trimmed: TrustGate appends /v1/complexity to this base.
  assert_contains "$out10b4b" 'NEURAL_TRUST_FIREWALL_BASE_URL: "http://firewall\.firewall\.svc\.cluster\.local"$' \
    "external firewall ($fw_mode): TrustGuard calls the external URL"
  assert_contains "$out10b4b" '^  FIREWALL_BASE_URL: "http://firewall\.firewall\.svc\.cluster\.local"$' \
    "external firewall ($fw_mode): TrustGate complexity scoring calls the external URL"
  # Both signers must use the external firewall's key, or every call is a 401.
  fw_refs="$TMP/scenario-firewall-external-$fw_mode-refs.txt"
  grep -A4 -E 'name: (NEURAL_TRUST_FIREWALL_SECRET_KEY|FIREWALL_SECRET_KEY)$' "$out10b4b" \
    | grep -E '^ +name: "' > "$fw_refs" || true
  assert_contains "$fw_refs" 'name: "firewall-jwt"' \
    "external firewall ($fw_mode): signing keys come from global.firewall.existingSecret"
  assert_not_contains "$fw_refs" 'name: "(platform-secrets|firewall-secrets)"' \
    "external firewall ($fw_mode): no signer left on a chart-generated key"
done
out10b4b="$TMP/scenario-firewall-external-trustguard-off.yaml"
render_default "$out10b4b" "${HYBRID_NO_PRODUCTS[@]}" --set global.products.trustgate=true \
  --set global.firewall.deploy=false
assert_not_contains "$out10b4b" 'FIREWALL_BASE_URL|FIREWALL_SECRET_KEY' \
  "external firewall: inert while TrustGuard is off"
assert_render_fails_with "requires global.firewall.baseURL" \
  "external firewall: missing baseURL fails the render" \
  --set global.firewall.deploy=false --set global.firewall.existingSecret.name=firewall-jwt
assert_render_fails_with "requires global.firewall.baseURL" \
  "external firewall: baseURL without a scheme fails the render" \
  --set global.firewall.deploy=false --set global.firewall.baseURL=firewall \
  --set global.firewall.existingSecret.name=firewall-jwt
assert_render_fails_with "requires the external firewall's JWT_SECRET" \
  "external firewall: no key source fails the render" \
  --set global.firewall.deploy=false --set global.firewall.baseURL=http://firewall.firewall.svc.cluster.local
assert_render_fails_with "only apply with global.firewall.deploy=false" \
  "external firewall keys are rejected while the firewall is deployed" \
  --set global.firewall.baseURL=http://firewall.firewall.svc.cluster.local
# trustguard.firewall.existingSecret is allowed once it names the same Secret as
# the external firewall's: both signers then agree.
out10b4b="$TMP/scenario-firewall-external-aligned.yaml"
render_default "$out10b4b" "${FW_EXTERNAL_ARGS[@]}" \
  --set trustguard.firewall.existingSecret.name=firewall-jwt
assert_contains "$out10b4b" 'NEURAL_TRUST_FIREWALL_BASE_URL: "http://firewall\.firewall\.svc\.cluster\.local"$' \
  "external firewall: trustguard.firewall.existingSecret aligned with global renders"
# NeuralTrust-hosted firewall: the same https URL serves internet and Private
# Service Connect callers, and must reach both signers untouched in every mode.
# Leaving baseURL empty must still fail (covered above): prompts are never sent
# to a hosted firewall by default.
for fw_mode in hybrid external saas; do
  out10b4b="$TMP/scenario-firewall-hosted-$fw_mode.yaml"
  render_default "$out10b4b" --set global.deploymentMode="$fw_mode" --set global.domain=cp.example.com \
    --set global.firewall.deploy=false \
    --set global.firewall.baseURL=https://firewall.us.neuraltrust.ai \
    --set global.firewall.existingSecret.name=neuraltrust-firewall
  assert_not_contains "$out10b4b" 'name: firewall$' \
    "hosted firewall ($fw_mode): no in-release Firewall gateway"
  assert_contains "$out10b4b" 'NEURAL_TRUST_FIREWALL_BASE_URL: "https://firewall\.us\.neuraltrust\.ai"$' \
    "hosted firewall ($fw_mode): TrustGuard calls the hosted URL"
  assert_contains "$out10b4b" '^  FIREWALL_BASE_URL: "https://firewall\.us\.neuraltrust\.ai"$' \
    "hosted firewall ($fw_mode): TrustGate complexity scoring calls the hosted URL"
  fw_refs="$TMP/scenario-firewall-hosted-$fw_mode-refs.txt"
  grep -A4 -E 'name: (NEURAL_TRUST_FIREWALL_SECRET_KEY|FIREWALL_SECRET_KEY)$' "$out10b4b" \
    | grep -E '^ +name: "' > "$fw_refs" || true
  assert_contains "$fw_refs" 'name: "neuraltrust-firewall"' \
    "hosted firewall ($fw_mode): signing keys come from the issued key's Secret"
  assert_not_contains "$fw_refs" 'name: "(platform-secrets|firewall-secrets)"' \
    "hosted firewall ($fw_mode): no signer left on a chart-generated key"
done

blue "==> Scenario 10b5: data-plane-api PrometheusRule"
# The v1-era rule was gated on a helper that always returned true, so it never
# rendered in v2 and was deleted. These assertions stop the coverage silently
# disappearing a second time.
out10b5="$TMP/scenario-dpapi-monitoring.yaml"
render_default "$out10b5" --set global.monitoring.enabled=true --api-versions monitoring.coreos.com/v1
assert_contains "$out10b5" 'alert: DataPlaneApiDown' \
  "monitoring: data-plane-api rule renders with monitoring on and the CRD present"
assert_contains "$out10b5" '^  name: data-plane-api$' \
  "monitoring: data-plane-api PrometheusRule keeps its stable name"
# Retired with the Kafka stack; there is no workload left to alert on.
assert_not_contains "$out10b5" 'DataPlaneKafkaWorkersDown' \
  "monitoring: retired Kafka worker alert stays absent"
# Absent CRD must not produce an unappliable object.
out10b5b="$TMP/scenario-dpapi-monitoring-nocrd.yaml"
render_default "$out10b5b" --set global.monitoring.enabled=true
assert_not_contains "$out10b5b" 'alert: DataPlaneApiDown' \
  "monitoring: no data-plane-api rule when the Prometheus CRD is absent"
# Default install leaves monitoring off.
out10b5c="$TMP/scenario-dpapi-monitoring-off.yaml"
render_default "$out10b5c" --api-versions monitoring.coreos.com/v1
assert_not_contains "$out10b5c" 'alert: DataPlaneApiDown' \
  "monitoring: no data-plane-api rule when monitoring is disabled"

blue "==> Scenario 10b6: DataAgent POSTGRES_* yields to an extraEnv override"
# Emitting a name the operator also sets in extraEnv leaves two env entries with
# that name, which fails the next helm upgrade on $setElementOrder.
out10b6="$TMP/scenario-dataagent-pg-override.yaml"
render_default "$out10b6" \
  --set dataagent.store.backend=postgres \
  --set 'dataagent.extraEnv[0].name=POSTGRES_HOST' \
  --set 'dataagent.extraEnv[0].value=operator-pg-tg' \
  --set 'trustguard.dataagent.extraEnv[0].name=POSTGRES_HOST' \
  --set 'trustguard.dataagent.extraEnv[0].value=operator-pg-tgd'
# Count the chart-emitted form — `- name: POSTGRES_HOST` immediately followed by
# `valueFrom:` — across the render. Four workloads emit it by default; the two
# DataAgent instances must drop theirs when the operator overrides the name, leaving
# the two unrelated ones. Counting the secretKeyRef form rather than the bare name is
# what distinguishes "chart yielded" from "chart duplicated".
dpa_ref_count() {
  grep -A1 -E '^\s+- name: POSTGRES_HOST$' "$1" | grep -c "valueFrom:" || true
}
ovr_refs="$(dpa_ref_count "$out10b6")"
if [ "$ovr_refs" != "2" ]; then
  red "FAIL: dataagent: expected 2 chart-emitted POSTGRES_HOST refs after both overrides, found $ovr_refs"
  red "  4 means a DataAgent still emits its own alongside the override — two env entries"
  red "  of one name is the \$setElementOrder patch failure that breaks the next helm upgrade"
  exit 1
fi
green "ok  - dataagent: both instances yield POSTGRES_HOST to an extraEnv override"
assert_contains "$out10b6" 'value: operator-pg-tg' \
  "dataagent (TrustGate): the operator's POSTGRES_HOST value is the one present"
assert_contains "$out10b6" 'value: operator-pg-tgd' \
  "dataagent (TrustGuard): the operator's POSTGRES_HOST value is the one present"
# Without an override the chart must still supply it from the Secret.
out10b6b="$TMP/scenario-dataagent-pg-default.yaml"
render_default "$out10b6b" --set dataagent.store.backend=postgres
base_refs="$(dpa_ref_count "$out10b6b")"
if [ "$base_refs" != "4" ]; then
  red "FAIL: dataagent: expected 4 chart-emitted POSTGRES_HOST refs with no override, found $base_refs"
  exit 1
fi
green "ok  - dataagent: chart still supplies POSTGRES_HOST from the Secret with no override"
# Which refs are required is a decision, so pin it. The four
# credentials DataAgent cannot work without stay required so a missing key stops the
# pod; SSLMODE is optional because SECRETS.md documents it as not required for a
# pre-generated Secret, and a required ref there meant following the docs produced
# CreateContainerConfigError.
da_opt() {  # env name -> "true" when the ref is optional
  yq -N "select(.kind == \"Deployment\" and .metadata.name == \"dataagent\")
    | .spec.template.spec.containers[].env[] | select(.name == \"$1\")
    | .valueFrom.secretKeyRef.optional" "$out10b6b" 2>/dev/null | head -1
}
for req in POSTGRES_HOST POSTGRES_PORT POSTGRES_USER POSTGRES_DB; do
  got="$(da_opt "$req")"
  if [ "$got" != "null" ]; then
    red "FAIL: dataagent: $req must stay a required ref (optional=$got)"
    exit 1
  fi
done
green "ok  - dataagent: the four indispensable Postgres keys stay required"
sslmode_opt="$(da_opt POSTGRES_SSLMODE)"
if [ "$sslmode_opt" != "true" ]; then
  red "FAIL: dataagent: POSTGRES_SSLMODE must be optional, SECRETS.md documents it as not required (optional=$sslmode_opt)"
  exit 1
fi
green "ok  - dataagent: POSTGRES_SSLMODE is an optional ref, matching the documented contract"

blue "==> Scenario 10c1: CH-dependent workloads wait for ClickHouse"
# On a clean install these four raced clickhouse-0 and CrashLoopBackOff'd two or
# three times before it accepted connections.
out10c1="$TMP/scenario-ch-wait.yaml"
render_default "$out10c1" --set global.deploymentMode=external
for dep in datacore alertengine-api alertengine-worker clickstack-collector; do
  # Select the Deployment first, then list initContainer names. A `[]?` guard would
  # emit a 0 for every non-matching document and the first of those wins a `head -1`.
  names="$(yq -N "select(.kind == \"Deployment\" and .metadata.name == \"$dep\") | .spec.template.spec.initContainers[].name" "$out10c1" 2>/dev/null || true)"
  count="$(printf '%s\n' "$names" | grep -c '^wait-for-clickhouse$' || true)"
  if [ "${count:-0}" != "1" ]; then
    red "FAIL: $dep must have exactly one wait-for-clickhouse initContainer (got ${count:-0})"
    exit 1
  fi
done
green "ok  - all four CH-dependent workloads gain a wait-for-clickhouse initContainer"
# The invariant that keeps this from breaking a working install: the wait must target
# exactly what the app is configured to reach, never a guess. If they ever diverge the
# initContainer would fail a deployment that would otherwise have worked.
ch_wait_cmd="$(yq -N 'select(.kind == "Deployment" and .metadata.name == "datacore") | .spec.template.spec.initContainers[] | select(.name == "wait-for-clickhouse") | .command[-1]' "$out10c1" 2>/dev/null)"
ch_wait_host="$(printf '%s' "$ch_wait_cmd" | sed -n 's/^ *HOST="\(.*\)"$/\1/p' | head -1)"
ch_wait_port="$(printf '%s' "$ch_wait_cmd" | sed -n 's/^ *PORT="\(.*\)"$/\1/p' | head -1)"
ch_app_addr="$(yq -N 'select(.kind == "ConfigMap" and .metadata.name == "datacore-env-vars") | .data.CLICKHOUSE_ADDR' "$out10c1" 2>/dev/null | head -1)"
if [ "${ch_wait_host}:${ch_wait_port}" != "$ch_app_addr" ]; then
  red "FAIL: datacore wait target ${ch_wait_host}:${ch_wait_port} != CLICKHOUSE_ADDR ${ch_app_addr}"
  red "  a wait that targets anything other than the app's own endpoint can fail an install that would have worked"
  exit 1
fi
green "ok  - the wait targets exactly the endpoint the app is configured to reach"
# A private-registry mirror copies the tags the install pulls. A wait or migration
# image pinned to a different tag than the server it serves is a second tag that
# nobody mirrors, so the pod sits in ImagePullBackOff on an otherwise working install.
out10c1m="$TMP/scenario-ch-wait-mirror.yaml"
render_default "$out10c1m" --set global.deploymentMode=external \
  --set global.imageRegistry=registry.internal.example.com/nt \
  --set global.postgresql.image.tag=17.99-alpine
for img in clickhouse-server postgres; do
  tags="$(yq -N '.. | select(has("image")) | .image' "$out10c1m" | grep "/${img}:" | sort -u)"
  if [ "$(printf '%s\n' "$tags" | grep -c .)" != "1" ]; then
    red "FAIL: every ${img} image must resolve to one ref, got:"
    red "$tags"
    exit 1
  fi
done
green "ok  - wait/migration initContainers pull the same clickhouse-server and postgres refs as the servers"
# Hybrid deploys no ClickHouse and none of these workloads, so nothing should appear.
# Render its own file: $out10b9 belongs to a later scenario and set -u would abort.
out10c1h="$TMP/scenario-ch-wait-hybrid.yaml"
render_default "$out10c1h"
assert_not_contains "$out10c1h" 'wait-for-clickhouse' \
  "hybrid: no ClickHouse wait, since neither ClickHouse nor these workloads render"

blue "==> Scenario 10b7: shared-credential integrity"
# A knob that redirects only one half of a signer/verifier pair leaves the two
# holding different values, so every token one side mints is rejected by the other
# — silently, with both pods healthy. The consumers are sibling subcharts and
# cannot read each other's values, so this is rejected rather than reconciled.
assert_render_fails "one-sided firewall Secret override is rejected" \
  --set global.deploymentMode=external \
  --set trustguard.firewall.existingSecret.name=my-fw
assert_render_fails "one-sided data-plane JWT Secret override is rejected" \
  --set global.deploymentMode=external \
  --set 'data-plane-api.dataPlane.secrets.dataPlaneJWTSecretName=my-dp'
# The supported way to own the credential moves every consumer at once, so naming
# that same Secret on both sides must still render.
out10b7="$TMP/scenario-shared-secret-aligned.yaml"
render_default "$out10b7" --set global.deploymentMode=external \
  --set global.platformSecret.existingSecret.name=mine \
  --set trustguard.firewall.existingSecret.name=mine
assert_contains "$out10b7" 'name: "?mine"?' \
  "shared credential: pointing both sides at one operator Secret still renders"
# A map-shaped openaiApiKey is documented and handled by both Deployments, but was
# piped straight into b64enc here and aborted the whole render.
out10b8="$TMP/scenario-openai-map-shape.yaml"
render_default "$out10b8" --set global.deploymentMode=external \
  --set 'control-plane-api.controlPlane.secrets.openaiApiKey.secretName=my-openai' \
  --set 'control-plane-api.controlPlane.secrets.openaiApiKey.secretKey=API_KEY'
assert_contains "$out10b8" 'name: "?my-openai"?' \
  "openaiApiKey map form: Deployments reference the operator Secret"
out10b8cps="$TMP/scenario-openai-map-cp-secret.yaml"
document_named "$out10b8" control-plane-secrets "$out10b8cps"
assert_not_contains "$out10b8cps" 'OPENAI_API_KEY' \
  "openaiApiKey map form: the key is omitted from the chart Secret, not encoded"

blue "==> Scenario 10b9: egress collector telemetry durability"
# Without a sending_queue the exporter retried in memory and dropped the batch at
# max_elapsed_time, so a DataBridge outage spanning a token refresh lost telemetry
# silently. The queue needs a writable volume because the sidecar runs
# readOnlyRootFilesystem: true.
out10b9="$TMP/scenario-egress-queue.yaml"
render_default "$out10b9"
assert_contains "$out10b9" 'file_storage/queue:' \
  "egress: file_storage extension declared"
assert_contains "$out10b9" 'extensions: \[health_check, oauth2client, file_storage/queue\]' \
  "egress: the storage extension is registered on the service, or it is inert"
assert_contains "$out10b9" 'storage: file_storage/queue' \
  "egress: the exporter queue is backed by that extension"
assert_contains "$out10b9" 'name: egress-queue' \
  "egress: queue volume and mount render"
# 300s is the value that produced the reported data loss; fence it out.
assert_not_contains "$out10b9" 'max_elapsed_time: 300s' \
  "egress: the 5-minute give-up window is gone"
# The zero-ingest check must ship disabled — an untuned freshness alert cannot tell
# an idle data plane from a broken one, and would page at night on a quiet tenant.
out10b9b="$TMP/scenario-ingest-freshness.yaml"
render_default "$out10b9b" --set watchdog.enabled=true
ingest_enabled="$(yq -N '.checks[] | select(.id == "dataplane-ingest-freshness") | .enabled' \
  <(yq -N 'select(.kind == "ConfigMap" and (.metadata.name | test("watchdog"))) | .data.["config.yaml"]' "$out10b9b") 2>/dev/null | head -1)"
if [ "$ingest_enabled" != "false" ]; then
  red "FAIL: dataplane-ingest-freshness must ship disabled (got enabled=${ingest_enabled:-missing})"
  exit 1
fi
green "ok  - watchdog: dataplane-ingest-freshness ships disabled pending a soak"

blue "==> Scenario 10c0: egress collector survives an unready DataAgent"
# The egress Service selects the DataAgent pod, and a pod is Ready only when every
# container is — so a control-plane blip stripped the endpoints of a healthy
# collector and took local telemetry down with it.
egress_pnr="$(yq -N 'select(.kind == "Service" and .metadata.name == "clickstack-egress-collector") | .spec.publishNotReadyAddresses' "$out10b9" 2>/dev/null | head -1)"
if [ "$egress_pnr" != "true" ]; then
  red "FAIL: clickstack-egress-collector must publish not-ready addresses (got ${egress_pnr:-missing})"
  exit 1
fi
green "ok  - egress Service keeps endpoints when the dataagent container is unready"
# Deliberately scoped to the egress Service: the agent's own health Service should
# still drop out when the agent is unready.
da_pnr="$(yq -N 'select(.kind == "Service" and .metadata.name == "dataagent") | .spec.publishNotReadyAddresses' "$out10b9" 2>/dev/null | head -1)"
if [ "$da_pnr" = "true" ]; then
  red "FAIL: the dataagent health Service must not publish not-ready addresses"
  exit 1
fi
green "ok  - dataagent health Service still drops out when unready"

blue "==> Scenario 10c: hybrid has no in-cluster ClickStack; egress via sidecar"
out10c="$TMP/scenario-hybrid-clickstack-channels.yaml"
render_default "$out10c"
assert_not_contains "$out10c" 'name: clickstack-collector' \
  "hybrid: in-cluster ClickStack collector must not render"
assert_not_contains "$out10c" 'kind: StatefulSet' \
  "hybrid: ClickHouse StatefulSet must not render"
assert_contains "$out10c" 'name: clickstack-egress-collector' \
  "hybrid: local egress ClusterIP Service renders"
assert_contains "$out10c" 'name: clickstack-egress-collector'$'\n''        image:' \
  "hybrid: egress sidecar co-located on DataAgent"
assert_contains "$out10c" 'token_url: "http://127.0.0.1:9465/oauth/token"' \
  "hybrid: egress sidecar exchanges via DataAgent loopback broker"
assert_contains "$out10c" 'endpoint: "https://telemetry.neuraltrust.ai"' \
  "hybrid: egress sidecar exports to telemetry.neuraltrust.ai"
assert_contains "$out10c" 'http://clickstack-egress-collector.default.svc.cluster.local:4318/v1/logs' \
  "hybrid: apps send OTLP to local egress only"

blue "==> Scenario 10d: GPU Firewall workers (dataplane-gpu example shape)"
out10d="$TMP/scenario-firewall-gpu.yaml"
render_default "$out10d" \
  --set firewall.firewall.workerDefaults.image.repository=europe-west1-docker.pkg.dev/neuraltrust-app-prod/nt-docker/firewall-gpu \
  --set 'firewall.firewall.workerDefaults.resources.requests.nvidia\.com/gpu=1' \
  --set 'firewall.firewall.workerDefaults.resources.limits.nvidia\.com/gpu=1' \
  --set firewall.firewall.workerDefaults.hostIPC=true
assert_contains "$out10d" 'nvidia.com/gpu' \
  "gpu: Firewall workers request GPU resources"
assert_contains "$out10d" 'hostIPC: true' \
  "gpu: Firewall workers share host IPC for CUDA MPS"

# Every Firewall worker must inherit a GPU set in workerDefaults, including the
# two with their own `resources` in the chart defaults: a worker's block merges
# over the defaults instead of replacing them. Checked on the --set shape above
# and on the shipped example, worker by worker.
gpu_less_workers() {  # rendered file -> worker Deployments without a GPU request
  ruby -ryaml -e '
    puts YAML.load_stream(File.read(ARGV.fetch(0))).compact
      .select { |d| d["kind"] == "Deployment" && d.dig("metadata", "name").to_s.end_with?("-worker") }
      .reject { |d| d.dig("spec", "template", "spec", "containers", 0, "resources", "requests", "nvidia.com/gpu") }
      .map { |d| d.dig("metadata", "name") }' "$1"
}
gpu_less="$(gpu_less_workers "$out10d")"
if [[ -n "$gpu_less" ]]; then
  red "FAIL: gpu: a GPU in workerDefaults reaches every Firewall worker"
  red "  without a GPU request: $(echo $gpu_less)"
  exit 1
fi
green "ok  - gpu: a GPU in workerDefaults reaches every Firewall worker, own resources or not"
# A worker's own key still wins: topic-guard keeps its 5Gi memory ceiling.
tg_mem="$(ruby -ryaml -e '
  d = YAML.load_stream(File.read(ARGV.fetch(0))).compact
    .find { |x| x["kind"] == "Deployment" && x.dig("metadata", "name") == "topic-guard-worker" }
  puts d.dig("spec", "template", "spec", "containers", 0, "resources", "limits", "memory")' "$out10d")"
if [[ "$tg_mem" != "5Gi" ]]; then
  red "FAIL: gpu: topic-guard keeps its own memory limit over workerDefaults (got $tg_mem, want 5Gi)"
  exit 1
fi
green "ok  - gpu: a worker's own resources key still wins over workerDefaults"
out10d_ex="$TMP/scenario-firewall-gpu-example.yaml"
render_default "$out10d_ex" -f "$CHART_DIR/values-dataplane-gpu.yaml.example"
gpu_less="$(gpu_less_workers "$out10d_ex")"
if [[ -n "$gpu_less" ]]; then
  red "FAIL: gpu example: every Firewall worker requests a GPU"
  red "  without a GPU request: $(echo $gpu_less)"
  exit 1
fi
green "ok  - gpu example: every Firewall worker requests a GPU"

blue "==> Scenario 10f: Firewall OTLP endpoint resolution"
# The chart used to default this to a NeuralTrust-internal collector namespace,
# which no customer cluster has. Enabling OTel without an endpoint must leave
# the variable unset rather than ship an address that cannot resolve.
out10f_fw="$TMP/scenario-firewall-otel-unset.yaml"
render_default "$out10f_fw" \
  --set firewall.firewall.config.otelEnabled=true
document_named "$out10f_fw" firewall-config "$TMP/firewall-config-unset.yaml"
assert_contains "$TMP/firewall-config-unset.yaml" 'OTEL_ENABLED: "true"' \
  "firewall otel: SDK gate is on"
assert_not_contains "$TMP/firewall-config-unset.yaml" 'OTEL_EXPORTER_OTLP_ENDPOINT' \
  "firewall otel: no endpoint resolves, so the key is omitted"
assert_not_contains "$out10f_fw" 'opentelemetry-collector.opentelemetry' \
  "firewall otel: retired collector namespace is not a default"

out10f_glob="$TMP/scenario-firewall-otel-umbrella.yaml"
render_default "$out10f_glob" \
  --set firewall.firewall.config.otelEnabled=true \
  --set firewall.firewall.config.otelExporterOtlpEndpoint=http://per-component:4318 \
  --set global.observability.collector.endpoint=http://umbrella:4318
document_named "$out10f_glob" firewall-config "$TMP/firewall-config-umbrella.yaml"
assert_contains "$TMP/firewall-config-umbrella.yaml" 'OTEL_EXPORTER_OTLP_ENDPOINT: "http://umbrella:4318"' \
  "firewall otel: umbrella endpoint overrides the per-component setting"

# ---------------------------------------------------------------------------
# 10g. Platform self-observability endpoint derivation
# ---------------------------------------------------------------------------
# control-plane-app, control-plane-api, data-plane-api and firewall each gate
# their whole OTel path on a resolvable endpoint. control-plane-app is also the
# only emitter of the audit records behind Telemetry -> Logs, so an unresolved
# endpoint costs a product feature, not just troubleshooting signal.
blue "==> Scenario 10g: platform OTLP endpoint derivation"

CLICKSTACK_IN_RELEASE='http://clickstack-collector.default.svc.cluster.local:4318'

out10g="$TMP/scenario-otel-derived.yaml"
render_default "$out10g" --set global.deploymentMode=external

for cm in control-plane-app-otel control-plane-api-otel data-plane-api-otel; do
  document_named "$out10g" "$cm" "$TMP/$cm.yaml"
  assert_contains "$TMP/$cm.yaml" "OTEL_EXPORTER_OTLP_ENDPOINT: \"$CLICKSTACK_IN_RELEASE\"" \
    "otel derivation: $cm points at the in-release collector"
done

document_named "$out10g" firewall-config "$TMP/firewall-config-derived.yaml"
assert_contains "$TMP/firewall-config-derived.yaml" "OTEL_EXPORTER_OTLP_ENDPOINT: \"$CLICKSTACK_IN_RELEASE\"" \
  "otel derivation: firewall points at the in-release collector"
assert_contains "$TMP/firewall-config-derived.yaml" 'OTEL_ENABLED: "true"' \
  "otel derivation: firewall SDK gate follows the resolved endpoint"

# The collector answers 401 on :4318 without the shared bearer token, so an
# endpoint with no header exports into a rejection that is invisible from both
# ends. These four assertions are the difference between wired and working.
assert_env_value "$out10g" control-plane-app app OTEL_EXPORTER_OTLP_HEADERS \
  'secretKeyRef:clickstack-collector-secrets/OTEL_EXPORTER_OTLP_HEADERS' \
  "otel derivation: control-plane-app presents the collector token"
assert_env_value "$out10g" control-plane-api control-plane-api OTEL_EXPORTER_OTLP_HEADERS \
  'secretKeyRef:clickstack-collector-secrets/OTEL_EXPORTER_OTLP_HEADERS' \
  "otel derivation: control-plane-api presents the collector token"
assert_env_value "$out10g" data-plane-api api OTEL_EXPORTER_OTLP_HEADERS \
  'secretKeyRef:clickstack-collector-secrets/OTEL_EXPORTER_OTLP_HEADERS' \
  "otel derivation: data-plane-api presents the collector token"
assert_env_value "$out10g" firewall gateway OTEL_EXPORTER_OTLP_HEADERS \
  'secretKeyRef:clickstack-collector-secrets/OTEL_EXPORTER_OTLP_HEADERS' \
  "otel derivation: firewall gateway presents the collector token"

# An explicit endpoint still wins, and our collector's token goes nowhere near
# a destination the operator chose.
out10g_ov="$TMP/scenario-otel-override.yaml"
render_default "$out10g_ov" --set global.deploymentMode=external \
  --set global.observability.collector.endpoint=https://otel.operator.example:4318
document_named "$out10g_ov" control-plane-app-otel "$TMP/cp-app-otel-override.yaml"
assert_contains "$TMP/cp-app-otel-override.yaml" 'OTEL_EXPORTER_OTLP_ENDPOINT: "https://otel.operator.example:4318"' \
  "otel derivation: an explicit endpoint overrides the derived one"
assert_env_value "$out10g_ov" control-plane-app app OTEL_EXPORTER_OTLP_HEADERS ABSENT \
  "otel derivation: the collector token is withheld from an operator endpoint"

# autoDiscover=false is the opt-out. An empty endpoint cannot carry that
# meaning, because empty is the shipped default.
out10g_off="$TMP/scenario-otel-optout.yaml"
render_default "$out10g_off" --set global.deploymentMode=external \
  --set global.observability.collector.autoDiscover=false
assert_not_contains "$out10g_off" 'name: control-plane-app-otel' \
  "otel opt-out: autoDiscover=false suppresses the OTel ConfigMap"
document_named "$out10g_off" firewall-config "$TMP/firewall-config-optout.yaml"
assert_contains "$TMP/firewall-config-optout.yaml" 'OTEL_ENABLED: "false"' \
  "otel opt-out: firewall SDK gate follows the absent endpoint"
assert_env_value "$out10g_off" control-plane-app app OTEL_EXPORTER_OTLP_HEADERS ABSENT \
  "otel opt-out: no collector token is mounted"

# Hybrid is untouched: these components either do not render there, and the
# egress collector carries enrolment-scoped product telemetry to SaaS rather
# than a customer's own service logs.
out10g_hy="$TMP/scenario-otel-hybrid.yaml"
render_default "$out10g_hy"
assert_not_contains "$out10g_hy" 'name: control-plane-app-otel' \
  "otel derivation: hybrid renders no platform OTel ConfigMap"
document_named "$out10g_hy" firewall-config "$TMP/firewall-config-hybrid.yaml"
assert_contains "$TMP/firewall-config-hybrid.yaml" 'OTEL_ENABLED: "false"' \
  "otel derivation: hybrid firewall stays off"
