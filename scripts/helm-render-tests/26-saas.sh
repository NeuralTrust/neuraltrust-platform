#!/usr/bin/env bash
# Render scenarios 25. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

# ---------------------------------------------------------------------------
# saas mode: a customer-owned central control plane serving data planes that
# live in other clusters. external, plus DataBridge, the ClickStack ingest
# gateway, DataCore in hybrid residency, and published config-sync listeners.
# ---------------------------------------------------------------------------
blue "==> Scenario 25: saas mode (central control plane for remote data planes)"

# Happy path: deploymentMode + domain only. Chart defaults mint self-signed TLS,
# HA DataBridge, AWS L4 annotations (when platform=aws), and publish config-sync.
SAAS_ARGS=(
  --set global.deploymentMode=saas
  --set global.domain=cp.example.com
)

# BYO-cert path (existingSecret) still supported for production PKI tests below.
SAAS_BYO_ARGS=(
  --set global.deploymentMode=saas
  --set global.domain=cp.example.com
  --set databridge.tls.existingSecret=databridge-southbound-tls
  --set agentgateway.configSync.grpcTls.existingSecret=ag-configsync-tls
  --set trustguard.configSync.grpcTls.existingSecret=tg-configsync-tls
)

out25="$TMP/scenario-saas.yaml"
render_default "$out25" "${SAAS_ARGS[@]}"

# --- saas is external plus three additions -------------------------------
assert_contains "$out25" '^  name: control-plane-api$' \
  "saas: control-plane-api renders (saas is a superset of external)"
assert_contains "$out25" '^          value: "external"$' \
  "saas: DEPLOYMENT_MODE stays external for the apps"
assert_contains "$out25" '^  name: databridge$' \
  "saas: DataBridge Deployment renders"
assert_contains "$out25" '^  name: databridge-northbound$' \
  "saas: DataBridge northbound Service renders"
assert_contains "$out25" '^  name: databridge-southbound$' \
  "saas: DataBridge southbound Service renders"
assert_contains "$out25" '^  name: clickstack-ingest-gateway$' \
  "saas: ClickStack ingest gateway renders"
assert_contains "$out25" 'TELEMETRY_EXPORTERS_METADATA: .*name.*metadata-otlp.*type.*otlp' \
  "saas: metadata exporter is a named otlp list"
assert_contains "$out25" 'TELEMETRY_EXPORTERS_RAW: .*name.*raw-otlp.*type.*otlp' \
  "saas: central CP raw exporter is a named otlp list"
assert_not_contains "$out25" 'TELEMETRY_EXPORTERS_RAW: .*postgres' \
  "saas: central CP does not default raw to postgres"
assert_not_contains "$out25" 'name: trustguard-telemetry' \
  "saas: no TrustGuard telemetry ConfigMap"
assert_not_contains "$out25" 'name: agentgateway-telemetry' \
  "saas: no AgentGateway telemetry ConfigMap"
# Ingress is the product path (hybrid OTLP/HTTP). Default ON; inherits
# global.ingress like app/api. Host is telemetry.<controlPlane.domain>.
assert_contains "$out25" '^  name: clickstack-ingest-gateway$' \
  "saas: ingest gateway resource name present"
# The Ingress shares the Deployment name; select by kind.
gw_ing_host=$(yq -N 'select(.kind == "Ingress" and .metadata.name == "clickstack-ingest-gateway")
  | .spec.rules[0].host' "$out25" | sed '/^$/d' | head -1)
if [[ "$gw_ing_host" != "telemetry.cp.example.com" ]]; then
  red "FAIL: saas: ingest gateway Ingress host want telemetry.cp.example.com got: ${gw_ing_host:-<none>}"
  exit 1
fi
green "ok  - saas: ingest gateway Ingress is enabled by default (telemetry.<domain>)"
gw_ing_backend=$(yq -N 'select(.kind == "Ingress" and .metadata.name == "clickstack-ingest-gateway")
  | .spec.rules[0].http.paths[0].backend.service.port.name' "$out25" | sed '/^$/d' | head -1)
if [[ "$gw_ing_backend" != "otlp-http" ]]; then
  red "FAIL: saas: ingest gateway Ingress must target otlp-http (got: ${gw_ing_backend:-<none>})"
  exit 1
fi
green "ok  - saas: ingest gateway Ingress backends OTLP/HTTP"

# The ingest views read the tenant from log-record attributes, so the edge must
# rewrite each of them from the verified claim. Only as `update`: `upsert`
# would add a key to records that lack it and move them into another table.
gw_cfg="$TMP/scenario-saas-ingest-gateway-collector.yaml"
yq -N 'select(.kind == "ConfigMap" and .metadata.name == "clickstack-ingest-gateway-config")
  | .data["collector.yaml"]' "$out25" > "$gw_cfg"
for key in usage.tenant_id trustgate.tenant_id trustguard.tenant_id \
           trustgate.topic.tenant_id trustgate.label.tenant_id \
           trustguard.shadow.tenant_id team.id; do
  got=$(yq -N ".processors[\"attributes/tenant_from_claims\"].actions[]
    | select(.key == \"$key\") | .action + \" \" + .from_context" "$gw_cfg")
  if [[ "$got" != "update auth.claims.tenant_id" ]]; then
    red "FAIL: saas: ingest gateway must update $key from auth.claims.tenant_id (got: ${got:-<none>})"
    exit 1
  fi
done
green "ok  - saas: ingest gateway rewrites every log-record tenant key from the token"
gw_logs=$(yq -N '.service.pipelines.logs.processors | join(",")' "$gw_cfg")
if [[ "$gw_logs" != *"resource/tenant_from_claims,transform/dedupe_log_attributes,attributes/tenant_from_claims,"*batch ]]; then
  red "FAIL: saas: ingest gateway logs pipeline must collapse duplicate keys, then apply attributes/tenant_from_claims, before batch (got: $gw_logs)"
  exit 1
fi
gw_traces=$(yq -N '.service.pipelines.traces.processors | join(",")' "$gw_cfg")
if [[ "$gw_traces" == *attributes/tenant_from_claims* ]]; then
  red "FAIL: saas: log-record tenant processor belongs to the logs pipeline only (traces: $gw_traces)"
  exit 1
fi
green "ok  - saas: ingest gateway collapses duplicate keys, then applies it in the logs pipeline, before batch"

# --- saas NOTES name the mode and the four remote-plane endpoints
notes25="$TMP/scenario-saas-notes.txt"
render_notes "$notes25" "${SAAS_ARGS[@]}"
assert_contains "$notes25" 'Deployment profile: Platform v2 — saas \(customer-owned central control plane' \
  "saas NOTES: profile names saas mode"
assert_contains "$notes25" 'databridge.cp.example.com:443' \
  "saas NOTES: DataBridge derived endpoint"
assert_contains "$notes25" 'https://telemetry.cp.example.com' \
  "saas NOTES: telemetry derived endpoint"
assert_contains "$notes25" 'agentgateway-configsync.cp.example.com:443' \
  "saas NOTES: AgentGateway config-sync endpoint"
assert_contains "$notes25" 'trustguard-configsync.cp.example.com:443' \
  "saas NOTES: TrustGuard config-sync endpoint"
assert_contains "$notes25" 'kubectl get svc -n default databridge-southbound agentgateway-admin-configsync trustguard-control-plane-configsync' \
  "saas NOTES: L4 Service lookup"
assert_contains "$notes25" 'serving chart-minted certificates' \
  "saas NOTES: self-signed warning on default minting path"
assert_contains "$notes25" 'DataBridge \(southbound L4' \
  "saas NOTES: DataBridge in component list"

notes25byo="$TMP/scenario-saas-notes-byo.txt"
render_notes "$notes25byo" "${SAAS_BYO_ARGS[@]}" \
  --set databridge.tls.autoGenerate=false \
  --set agentgateway.configSync.expose.selfSignedTls=false \
  --set trustguard.configSync.expose.selfSignedTls=false
assert_not_contains "$notes25byo" 'serving chart-minted certificates' \
  "saas NOTES: no self-signed warning on BYO certs"

notes_ext="$TMP/scenario-external-notes.txt"
render_notes "$notes_ext" --set global.deploymentMode=external
assert_contains "$notes_ext" 'Deployment profile: Platform v2 — external \(control \+ data plane' \
  "external NOTES: profile unchanged"
assert_not_contains "$notes_ext" 'Remote data-plane endpoints' \
  "external NOTES: no saas L4 block"
assert_not_contains "$notes_ext" 'DataBridge \(southbound L4' \
  "external NOTES: no DataBridge saas component line"

notes_hyb="$TMP/scenario-hybrid-notes.txt"
render_notes "$notes_hyb" \
  --set global.products.trustgate=true \
  --set agentgateway.configSync.token=cs-trustgate
assert_contains "$notes_hyb" 'Deployment profile: Platform v2 — hybrid \(data plane in-cluster' \
  "hybrid NOTES: profile unchanged"
assert_not_contains "$notes_hyb" 'Remote data-plane endpoints' \
  "hybrid NOTES: no saas L4 block"

# --- every image comes from one registry ----------------------------------
# An air-gapped install mirrors what it is told to mirror. An image with no
# registry host resolves to Docker Hub, which such a cluster cannot reach and
# which no mirroring list mentions, so the pod only fails at pull time. Assert
# the shape rather than a list of names so a component added later is covered.
hub_images=$(grep -oE 'image: *"?[^"]+' "$out25" | sed 's/image: *"*//' | sort -u \
  | awk -F/ '$1 !~ /[.:]/')
if [[ -n "$hub_images" ]]; then
  red "FAIL: saas: image(s) resolve to Docker Hub rather than a mirrorable registry:"
  printf '  %s\n' $hub_images
  exit 1
fi
green "ok  - saas: every image carries an explicit registry host"

# The gateway runs the same upstream collector as the egress sidecars. Pulling
# it from the NeuralTrust mirror keeps one registry, one pull secret, one entry
# in the mirroring list.
assert_contains "$out25" '^          image: "europe-west1-docker\.pkg\.dev/neuraltrust-app-prod/nt-docker/opentelemetry-collector-contrib:' \
  "saas: ingest gateway pulls the collector from the NeuralTrust mirror"
# Select by kind: the Deployment shares its name with the Service and the
# ServiceAccount, and only the Deployment carries the pull secret.
gw_pull=$(yq eval 'select(.kind == "Deployment" and .metadata.name == "clickstack-ingest-gateway")
  | (.spec.template.spec.imagePullSecrets // []) | map(.name) | join(",")' "$out25")
if [[ "$gw_pull" != *gcr-secret* ]]; then
  red "FAIL: saas: ingest gateway has no pull secret for that private registry (got: ${gw_pull:-<none>})"
  exit 1
fi
green "ok  - saas: ingest gateway carries a pull secret for that private registry"

# A mirror has to replace the pinned registry, not be prepended to it: the naive
# form yields <mirror>/europe-west1-docker.pkg.dev/... which exists nowhere.
out25m="$TMP/scenario-saas-mirror.yaml"
render_default "$out25m" "${SAAS_ARGS[@]}" \
  --set global.imageRegistry=registry.internal.example.com/mirror
assert_contains "$out25m" '^          image: "registry\.internal\.example\.com/mirror/opentelemetry-collector-contrib:' \
  "saas: global.imageRegistry retargets the ingest gateway collector"
assert_not_contains "$out25m" 'mirror/europe-west1-docker\.pkg\.dev' \
  "saas: the mirror replaces the pinned registry instead of prefixing it"

# --- DataCore drives the remote planes through DataBridge ----------------
assert_contains "$out25" '^  RESIDENCY_BACKEND: "hybrid"$' \
  "saas: DataCore runs hybrid residency, not direct ClickHouse"
assert_contains "$out25" '^  DATABRIDGE_ADDR: "databridge-northbound\.default\.svc\.cluster\.local:50051"$' \
  "saas: DataCore dials the northbound Service this chart renders"

# The gateway verifies tokens DataCore mints. A mismatch on either the issuer
# or the audience rejects every batch at runtime with a 401, so compare the two
# sides instead of asserting each against a literal.
dc_issuer=$(grep -m1 '^  TELEMETRY_JWT_ISSUER_URL: ' "$out25" | sed 's/.*: //' | tr -d '"')
dc_aud=$(grep -m1 '^  TELEMETRY_JWT_AUDIENCE: ' "$out25" | sed 's/.*: //' | tr -d '"')
gw_issuer=$(grep -m1 'issuer_url: ' "$out25" | sed 's/.*issuer_url: //' | tr -d '"')
gw_aud=$(grep -m1 '^            audience: ' "$out25" | sed 's/.*: //' | tr -d '"')
if [[ -z "$dc_issuer" || "$dc_issuer" != "$gw_issuer" ]]; then
  red "FAIL: saas: ingest gateway OIDC issuer ($gw_issuer) does not match DataCore ($dc_issuer)"
  exit 1
fi
if [[ -z "$dc_aud" || "$dc_aud" != "$gw_aud" ]]; then
  red "FAIL: saas: ingest gateway audience ($gw_aud) does not match DataCore ($dc_aud)"
  exit 1
fi
green "ok  - saas: ingest gateway verifies exactly the tokens DataCore mints"

# OIDC identifies an issuer by its URL, and the gateway rejects any token whose
# iss claim is a different string. DataCore's own default for iss is the bare
# name "datacore", which never matches a URL, so the chart pins both to one
# value — assert they agree rather than assert either against a literal.
dc_iss=$(grep -m1 '^  TELEMETRY_JWT_ISSUER: ' "$out25" | sed 's/.*: //' | tr -d '"')
if [[ -z "$dc_iss" || "$dc_iss" != "$dc_issuer" ]]; then
  red "FAIL: saas: DataCore signs iss=$dc_iss but advertises issuer $dc_issuer; the ingest gateway would reject every batch"
  exit 1
fi
green "ok  - saas: the iss DataCore signs matches the issuer it advertises"

# --- gateway -> collector hop is authenticated -----------------------------
# Verifying the sender's JWT only proves who called the gateway; it does not
# authenticate the gateway to clickstack-collector, which enforces its own
# OTLP_AUTH_TOKEN. Without this the batch is accepted at the edge and dropped
# on the last hop with "Unauthenticated: missing or empty authorization
# header" — every upstream check green while telemetry silently disappears.
gw_auth=$(yq -N 'select(.kind == "ConfigMap" and .metadata.name == "clickstack-ingest-gateway-config")
  | .data["collector.yaml"]' "$out25" 2>/dev/null \
  | yq -N '.exporters["otlphttp/clickstack"].auth.authenticator' 2>/dev/null)
if [[ "$gw_auth" != "bearertokenauth/downstream" ]]; then
  red "FAIL: saas: gateway forwards to clickstack-collector unauthenticated (got: ${gw_auth:-<none>})"
  exit 1
fi
green "ok  - saas: gateway authenticates itself to the downstream collector"

# scheme must stay empty: the collector compares the Authorization header
# against the raw OTLP_AUTH_TOKEN, so a default "Bearer " prefix 401s.
gw_scheme=$(yq -N 'select(.kind == "ConfigMap" and .metadata.name == "clickstack-ingest-gateway-config")
  | .data["collector.yaml"]' "$out25" 2>/dev/null \
  | yq -N '.extensions["bearertokenauth/downstream"].scheme' 2>/dev/null)
if [[ -n "$gw_scheme" && "$gw_scheme" != '""' ]]; then
  red "FAIL: saas: downstream bearer scheme must be empty to match OTLP_AUTH_TOKEN (got: $gw_scheme)"
  exit 1
fi
green "ok  - saas: downstream bearer token is sent raw, no Bearer prefix"

# The token comes from the Secret, never inlined into the ConfigMap.
assert_contains "$out25" '^                  key: OTLP_AUTH_TOKEN$' \
  "saas: gateway reads OTLP_AUTH_TOKEN from the collector Secret"

# OTLP/HTTP, not gRPC: gRPC refuses per-RPC credentials on a cleartext
# connection ("credentials require transport level security") and the
# collector crashloops at startup.
gw_ds=$(yq -N 'select(.kind == "ConfigMap" and .metadata.name == "clickstack-ingest-gateway-config")
  | .data["collector.yaml"]' "$out25" 2>/dev/null \
  | yq -N '.exporters["otlphttp/clickstack"].endpoint' 2>/dev/null)
if [[ "$gw_ds" != http://clickstack-collector.*:4318 ]]; then
  red "FAIL: saas: downstream must be OTLP/HTTP :4318 or the bearer hop crashloops (got: ${gw_ds:-<none>})"
  exit 1
fi
green "ok  - saas: downstream hop uses OTLP/HTTP so bearer auth can attach"

# --- published config-sync listeners --------------------------------------
assert_contains "$out25" '^  name: agentgateway-admin-configsync$' \
  "saas: AgentGateway config-sync Service is published"
assert_contains "$out25" '^  name: trustguard-control-plane-configsync$' \
  "saas: TrustGuard config-sync Service is published"
assert_contains "$out25" 'neuraltrust\.ai/config-sync-host: "agentgateway-configsync\.cp\.example\.com"' \
  "saas: AgentGateway config-sync published under the customer domain"
assert_contains "$out25" 'neuraltrust\.ai/config-sync-host: "trustguard-configsync\.cp\.example\.com"' \
  "saas: TrustGuard config-sync published under the customer domain"

# Port 443 in, gRPC listener out. Getting targetPort wrong sends config-sync
# traffic to the HTTP API, which answers, so this fails quietly in a cluster.
cs_ag="$TMP/scenario-saas-cs-ag.yaml"
document_named "$out25" agentgateway-admin-configsync "$cs_ag"
assert_contains "$cs_ag" '^      port: 443$' \
  "saas: AgentGateway config-sync listens on 443"
assert_contains "$cs_ag" '^      targetPort: 8083$' \
  "saas: AgentGateway config-sync forwards to the gRPC listener"
assert_contains "$cs_ag" '^  type: LoadBalancer$' \
  "saas: AgentGateway config-sync is L4, not an Ingress"

# --- neither existing mode grows any of this ------------------------------
out25ext="$TMP/scenario-saas-external-unchanged.yaml"
render_default "$out25ext" --set global.deploymentMode=external
for absent in '^  name: databridge$' '^  name: clickstack-ingest-gateway$' '\-configsync$'; do
  assert_not_contains "$out25ext" "$absent" \
    "external: no saas-only resource matching $absent"
done
assert_contains "$out25ext" '^  RESIDENCY_BACKEND: "saas"$' \
  "external: DataCore keeps its own residency backend"

# --- a remote data plane retargets onto the customer domain ---------------
# hybrid is what the remote clusters run; they must dial the central cluster
# rendered above rather than NeuralTrust.
out25c="$TMP/scenario-saas-remote.yaml"
render_default "$out25c" \
  --set global.deploymentMode=hybrid \
  --set global.controlPlane.domain=cp.example.com \
  --set agentgateway.configSync.token=cs-trustgate \
  --set trustguard.configSync.token=cs-trustguard
assert_contains "$out25c" '^          value: "agentgateway-configsync\.cp\.example\.com:443"$' \
  "remote: AgentGateway dials the central config-sync listener"
assert_contains "$out25c" '^          value: "trustguard-configsync\.cp\.example\.com:443"$' \
  "remote: TrustGuard dials the central config-sync listener"
assert_contains "$out25c" 'databridge\.cp\.example\.com:443' \
  "remote: DataAgent enrols against the central DataBridge"
assert_contains "$out25c" 'telemetry\.cp\.example\.com' \
  "remote: telemetry egress targets the central ingest gateway"
assert_not_contains "$out25c" 'neuraltrust\.ai:443' \
  "remote: nothing still points at NeuralTrust SaaS"

# The region map must keep working untouched for everyone not setting a domain.
out25r="$TMP/scenario-saas-region-default.yaml"
render_default "$out25r" \
  --set global.deploymentMode=hybrid \
  --set agentgateway.configSync.token=cs-trustgate
assert_contains "$out25r" '^          value: "agentgateway-configsync\.neuraltrust\.ai:443"$' \
  "hybrid: no controlPlane.domain still resolves through saasRegion"

# --- fail-closed guards ---------------------------------------------------
# Both rejected auth modes authenticate every data plane with one shared
# credential, then believe whatever tenant each agent claims.
assert_render_fails_with 'is not allowed with global.deploymentMode=saas' \
  "saas: shared-token DataBridge auth mode rejected" \
  "${SAAS_ARGS[@]}" --set databridge.auth.mode=token
assert_render_fails_with 'is not allowed with global.deploymentMode=saas' \
  "saas: dev DataBridge auth mode rejected" \
  "${SAAS_ARGS[@]}" --set databridge.auth.mode=dev
assert_render_fails_with 'databridge.auth.mode must be one of' \
  "saas: unknown DataBridge auth mode rejected" \
  "${SAAS_ARGS[@]}" --set databridge.auth.mode=mtls

# --- DataBridge peer forwarding — HA is the default --------------
# replicas >= 2 requires headless (default). Explicit discovery=off fails.
# Singleton escape hatch: replicas=1 forces discovery off.
assert_render_fails_with 'requires peer forwarding' \
  "saas: replicas >= 2 with peer discovery off is refused" \
  "${SAAS_ARGS[@]}" --set databridge.peers.discovery=off
assert_render_fails_with 'databridge.peers.discovery must be' \
  "saas: an unknown peer discovery mode fails the render" \
  "${SAAS_ARGS[@]}" --set databridge.peers.discovery=redis

# Default install: HA (replicas=2 + headless peer Service + POD_IP).
assert_contains "$out25" '^  PEER_DISCOVERY: "headless"$' \
  "saas: DataBridge defaults to headless peer forwarding"
assert_contains "$out25" '^  name: databridge-peers$' \
  "saas: headless peer Service renders by default"
assert_env_value "$out25" databridge databridge POD_IP fieldRef:status.podIP \
  "saas: POD_IP is injected when peer forwarding is on"
db_replicas=$(yq eval 'select(.kind == "Deployment" and .metadata.name == "databridge") | .spec.replicas' "$out25" | sed '/^$/d' | head -1)
if [[ "$db_replicas" != "2" ]]; then
  red "FAIL: saas: DataBridge default replicas want 2 got: ${db_replicas:-<none>}"
  exit 1
fi
green "ok  - saas: DataBridge defaults to 2 replicas"

# A ClusterIP here would load-balance "who holds agent X?" to an arbitrary pod,
# including back to the asker, which is the one answer that is never useful.
peers_clusterip=$(yq eval 'select(.kind == "Service" and .metadata.name == "databridge-peers")
  | .spec.clusterIP' "$out25")
if [[ "$peers_clusterip" != "None" ]]; then
  red "FAIL: peers: the discovery Service must be headless (clusterIP: ${peers_clusterip:-<unset>})"
  exit 1
fi
green "ok  - peers: the discovery Service is headless"
peers_notready=$(yq eval 'select(.kind == "Service" and .metadata.name == "databridge-peers")
  | .spec.publishNotReadyAddresses' "$out25")
if [[ "$peers_notready" != "true" ]]; then
  red "FAIL: peers: the discovery Service hides not-ready pods (got: $peers_notready)"
  exit 1
fi
green "ok  - peers: the discovery Service publishes not-ready addresses"

assert_contains "$out25" '^  PEER_SERVICE_NAME: "databridge-peers\.default\.svc\.cluster\.local"$' \
  "peers: replicas resolve the headless Service this chart renders"
assert_contains "$out25" '^  PEER_PORT: "50051"$' \
  "peers: siblings are dialled on the northbound port"
peers_affinity=$(yq eval 'select(.kind == "Deployment" and .metadata.name == "databridge")
  | .spec.template.spec.affinity.podAntiAffinity
  | (.preferredDuringSchedulingIgnoredDuringExecution[0].podAffinityTerm.topologyKey // "")' "$out25")
if [[ "$peers_affinity" != "kubernetes.io/hostname" ]]; then
  red "FAIL: peers: replicas are not spread across nodes (topologyKey: ${peers_affinity:-<none>})"
  exit 1
fi
green "ok  - peers: replicas prefer separate nodes"

# Singleton opt-down: replicas < 2 forces discovery off.
out25single="$TMP/scenario-saas-databridge-singleton.yaml"
render_default "$out25single" "${SAAS_ARGS[@]}" --set databridge.replicas=1
assert_contains "$out25single" '^  PEER_DISCOVERY: "off"$' \
  "saas: replicas=1 forces peer discovery off"
assert_not_contains "$out25single" '^  name: databridge-peers$' \
  "saas: no headless peer Service in singleton mode"
assert_env_value "$out25single" databridge databridge POD_IP ABSENT \
  "saas: no POD_IP in singleton mode"

assert_pdb_shape() {
  local file="$1" field="$2" want="$3" msg="$4" got
  got=$(yq eval "select(.kind == \"PodDisruptionBudget\" and .metadata.name == \"databridge\") | .spec.$field" "$file")
  if [[ "$got" != "$want" ]]; then
    red "FAIL: $msg"
    red "  expected spec.$field=$want, got $got"
    exit 1
  fi
  green "ok  - $msg"
}
assert_pdb_shape "$out25single" maxUnavailable 1 \
  "saas: a single-replica DataBridge lets a node drain evict its only pod"
assert_pdb_shape "$out25single" minAvailable null \
  "saas: a single-replica DataBridge does not deadlock the drain with minAvailable"
assert_pdb_shape "$out25" minAvailable 1 \
  "peers: several replicas keep one available through a drain"
assert_pdb_shape "$out25" maxUnavailable null \
  "peers: several replicas do not fall back to maxUnavailable"

out25pdb="$TMP/scenario-saas-databridge-pdb-override.yaml"
render_default "$out25pdb" "${SAAS_ARGS[@]}" \
  --set databridge.podDisruptionBudget.maxUnavailable=1
assert_pdb_shape "$out25pdb" maxUnavailable 1 \
  "peers: an explicit maxUnavailable overrides the replica-derived default"

db_strategy=$(yq eval 'select(.kind == "Deployment" and .metadata.name == "databridge")
  | [.spec.strategy.type, (.spec.strategy.rollingUpdate.maxUnavailable | tostring)] | join(",")' "$out25" \
  | sed '/^$/d')
if [[ "$db_strategy" != "RollingUpdate,0" ]]; then
  red "FAIL: saas: DataBridge does not roll without taking its pod down first (got: $db_strategy)"
  exit 1
fi
green "ok  - saas: DataBridge replaces a pod before removing the old one"

# Explicit opt-out of auto TLS without BYO secret still fails.
assert_render_fails_with 'southbound TLS cert for DataBridge' \
  "saas: DataBridge with autoGenerate=false and no secret rejected" \
  --set global.deploymentMode=saas \
  --set global.domain=cp.example.com \
  --set databridge.tls.autoGenerate=false \
  --set agentgateway.configSync.expose.enabled=false \
  --set trustguard.configSync.expose.enabled=false
assert_render_fails_with 'configSync.expose needs a certificate the data planes will accept' \
  "saas: publishing config-sync with selfSignedTls=false and no secret rejected" \
  --set global.deploymentMode=saas \
  --set global.domain=cp.example.com \
  --set agentgateway.configSync.expose.selfSignedTls=false \
  --set trustguard.configSync.expose.enabled=false
assert_render_fails_with 'export-controlplane-ca.sh' \
  "saas: the DataBridge cert guard points at the CA export path" \
  --set global.deploymentMode=saas \
  --set global.domain=cp.example.com \
  --set databridge.tls.autoGenerate=false \
  --set agentgateway.configSync.expose.enabled=false \
  --set trustguard.configSync.expose.enabled=false

# Opting out is how you keep a listener private, not by leaving it uncertified.
out25priv="$TMP/scenario-saas-configsync-private.yaml"
render_default "$out25priv" \
  --set global.deploymentMode=saas \
  --set global.domain=cp.example.com \
  --set agentgateway.configSync.expose.enabled=false \
  --set trustguard.configSync.expose.enabled=false
assert_not_contains "$out25priv" '\-configsync$' \
  "saas: configSync.expose.enabled=false keeps both listeners ClusterIP"

# Default saas render mints DataBridge + config-sync CAs (happy path).
# Telemetry ingress CA still needs ingress.tls.autoGenerate (HTTP edge often uses ACM).
out25gen="$TMP/scenario-saas-selfsigned.yaml"
render_default "$out25gen" \
  --set global.deploymentMode=saas \
  --set global.domain=cp.example.com \
  --set clickstack-ingest-gateway.ingress.tls.autoGenerate=true
assert_contains "$out25gen" '^  name: databridge-southbound-tls$' \
  "saas: default autoGenerate mints the DataBridge southbound keypair"
assert_contains "$out25gen" '^  name: clickstack-ingest-gateway-tls$' \
  "saas: ingress.tls.autoGenerate mints the telemetry keypair"
assert_contains "$out25gen" '^      secretName: "clickstack-ingest-gateway-tls"$' \
  "saas: the telemetry Ingress serves the generated keypair"

for component in southbound-tls configsync-tls telemetry-ingress-tls; do
  count="$(yq -N "select(.kind==\"Secret\" and .metadata.labels.\"app.kubernetes.io/component\"==\"$component\" and (.data | has(\"ca.crt\"))) | .metadata.name" "$out25gen" | grep -c . || true)"
  if [[ "$count" -eq 0 ]]; then
    red "FAIL: saas: no ca.crt-bearing Secret labelled $component, so the CA export script would miss it"
    exit 1
  fi
  green "ok  - saas: $component secrets are labelled for CA export ($count)"
done

for pair in "databridge-southbound-tls:databridge.cp.example.com" \
            "agentgateway-configsync-tls:agentgateway-configsync.cp.example.com" \
            "trustguard-configsync-tls:trustguard-configsync.cp.example.com" \
            "clickstack-ingest-gateway-tls:telemetry.cp.example.com"; do
  secret="${pair%%:*}"; host="${pair##*:}"
  if ! cert_sans "$out25gen" "$secret" | grep -q "DNS:$host"; then
    red "FAIL: saas: $secret does not cover $host, so remote planes fail the handshake on the name"
    exit 1
  fi
  green "ok  - saas: $secret covers $host"
done

# AWS L4 defaults: empty annotations ⇒ internal NLB on platform=aws.
out25aws="$TMP/scenario-saas-aws-l4.yaml"
render_default "$out25aws" \
  --set global.deploymentMode=saas \
  --set global.domain=cp.example.com \
  --set global.platform=aws
sb_scheme=$(yq -N 'select(.kind == "Service" and .metadata.name == "databridge-southbound")
  | .metadata.annotations["service.beta.kubernetes.io/aws-load-balancer-scheme"]' "$out25aws" | sed '/^$/d' | head -1)
if [[ "$sb_scheme" != "internal" ]]; then
  red "FAIL: saas aws: DataBridge southbound want scheme internal got: ${sb_scheme:-<none>}"
  exit 1
fi
green "ok  - saas aws: DataBridge southbound gets internal NLB by default"
cs_type=$(yq -N 'select(.kind == "Service" and .metadata.name == "agentgateway-admin-configsync")
  | .metadata.annotations["service.beta.kubernetes.io/aws-load-balancer-type"]' "$out25aws" | sed '/^$/d' | head -1)
if [[ "$cs_type" != "nlb" ]]; then
  red "FAIL: saas aws: config-sync want nlb got: ${cs_type:-<none>}"
  exit 1
fi
green "ok  - saas aws: config-sync expose gets NLB annotations by default"
out25aws_pub="$TMP/scenario-saas-aws-l4-public.yaml"
render_default "$out25aws_pub" \
  --set global.deploymentMode=saas \
  --set global.domain=cp.example.com \
  --set global.platform=aws \
  --set global.controlPlane.loadBalancerScheme=internet-facing
sb_pub=$(yq -N 'select(.kind == "Service" and .metadata.name == "databridge-southbound")
  | .metadata.annotations["service.beta.kubernetes.io/aws-load-balancer-scheme"]' "$out25aws_pub" | sed '/^$/d' | head -1)
if [[ "$sb_pub" != "internet-facing" ]]; then
  red "FAIL: saas aws: loadBalancerScheme=internet-facing want internet-facing got: ${sb_pub:-<none>}"
  exit 1
fi
green "ok  - saas aws: one global knob flips L4 scheme to internet-facing"

# The scheme keeps a central control plane private on every cloud, not only
# AWS: on AKS and GKE a LoadBalancer without the cloud's internal annotation
# gets a public address.
lb_anno() { # file service annotation
  yq -N "select(.kind == \"Service\" and .metadata.name == \"$2\") | .metadata.annotations[\"$3\"] // \"\"" "$1" | sed '/^$/d' | head -1
}
for cloud in azure gcp; do
  case "$cloud" in
    azure) key="service.beta.kubernetes.io/azure-load-balancer-internal"; want_int="true"; want_pub="false" ;;
    gcp)   key="networking.gke.io/load-balancer-type";                    want_int="Internal"; want_pub="" ;;
  esac
  out_int="$TMP/scenario-saas-$cloud-l4.yaml"
  render_default "$out_int" \
    --set global.deploymentMode=saas \
    --set global.domain=cp.example.com \
    --set global.platform=$cloud
  for svc in databridge-southbound agentgateway-admin-configsync trustguard-control-plane-configsync; do
    got=$(lb_anno "$out_int" "$svc" "$key")
    if [[ "$got" != "$want_int" ]]; then
      red "FAIL: saas $cloud: $svc want $key=$want_int by default got: ${got:-<none>}"
      exit 1
    fi
  done
  green "ok  - saas $cloud: every published L4 Service is internal by default"
  out_pub="$TMP/scenario-saas-$cloud-l4-public.yaml"
  render_default "$out_pub" \
    --set global.deploymentMode=saas \
    --set global.domain=cp.example.com \
    --set global.platform=$cloud \
    --set global.controlPlane.loadBalancerScheme=internet-facing
  got=$(lb_anno "$out_pub" databridge-southbound "$key")
  if [[ "$got" != "$want_pub" ]]; then
    red "FAIL: saas $cloud: internet-facing want ${want_pub:-<none>} got: ${got:-<none>}"
    exit 1
  fi
  green "ok  - saas $cloud: one global knob flips L4 scheme to internet-facing"
done
out_az_override="$TMP/scenario-saas-azure-l4-override.yaml"
render_default "$out_az_override" \
  --set global.deploymentMode=saas \
  --set global.domain=cp.example.com \
  --set global.platform=azure \
  --set 'databridge.service.southbound.annotations.service\.beta\.kubernetes\.io/azure-load-balancer-internal=false'
got=$(lb_anno "$out_az_override" databridge-southbound service.beta.kubernetes.io/azure-load-balancer-internal)
if [[ "$got" != "false" ]]; then
  red "FAIL: saas azure: an explicit local annotation must win over the global knob (got: ${got:-<none>})"
  exit 1
fi
green "ok  - saas azure: an explicit local annotation still overrides the global knob"
out_k8s="$TMP/scenario-saas-kubernetes-l4.yaml"
render_default "$out_k8s" \
  --set global.deploymentMode=saas \
  --set global.domain=cp.example.com \
  --set global.platform=kubernetes
if [[ -n "$(yq -N 'select(.kind == "Service" and .metadata.name == "databridge-southbound") | .metadata.annotations // ""' "$out_k8s" | sed '/^$/d')" ]]; then
  red "FAIL: saas kubernetes: a plain cluster has no portable scheme annotation; none should render"
  exit 1
fi
green "ok  - saas kubernetes: no cloud annotation on a plain cluster"

# --- local annotations must MERGE over the scheme, not replace it ------------
# Regression: l4Annotations used to return local annotations verbatim, so a
# values file that set any annotation at all silently dropped the scheme derived
# from loadBalancerScheme. The Service came up internal, a remote data plane in
# another VPC dialled an RFC1918 address, and the resulting `i/o timeout` read as
# an application fault. Every published L4 Service is checked: they are reached
# from other clusters, so a silent internal is an outage on each one.
out25merge="$TMP/scenario-saas-aws-l4-merge.yaml"
render_default "$out25merge" \
  --set global.deploymentMode=saas \
  --set global.domain=cp.example.com \
  --set global.platform=aws \
  --set global.controlPlane.loadBalancerScheme=internet-facing \
  --set 'databridge.service.southbound.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-nlb-target-type=ip' \
  --set 'agentgateway.configSync.expose.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-type=nlb' \
  --set 'trustguard.configSync.expose.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-type=nlb'
for svc in databridge-southbound agentgateway-admin-configsync trustguard-control-plane-configsync; do
  merged=$(yq -N "select(.kind == \"Service\" and .metadata.name == \"$svc\")
    | .metadata.annotations[\"service.beta.kubernetes.io/aws-load-balancer-scheme\"]" "$out25merge" | sed '/^$/d' | head -1)
  if [[ "$merged" != "internet-facing" ]]; then
    red "FAIL: saas aws: $svc local annotations dropped the global scheme (got: ${merged:-<none>})"
    exit 1
  fi
done
green "ok  - saas aws: local L4 annotations merge over the global scheme instead of replacing it"

# An explicit local scheme is still authoritative — merging must not take away
# the operator's ability to override one Service.
out25override="$TMP/scenario-saas-aws-l4-override.yaml"
render_default "$out25override" \
  --set global.deploymentMode=saas \
  --set global.domain=cp.example.com \
  --set global.platform=aws \
  --set global.controlPlane.loadBalancerScheme=internet-facing \
  --set 'databridge.service.southbound.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-scheme=internal'
sb_override=$(yq -N 'select(.kind == "Service" and .metadata.name == "databridge-southbound")
  | .metadata.annotations["service.beta.kubernetes.io/aws-load-balancer-scheme"]' "$out25override" | sed '/^$/d' | head -1)
if [[ "$sb_override" != "internal" ]]; then
  red "FAIL: saas aws: an explicit local scheme must win over the global knob (got: ${sb_override:-<none>})"
  exit 1
fi
green "ok  - saas aws: an explicit local scheme still overrides the global knob"

# An internet-facing control plane without source ranges is open to the world,
# so the allowlist has to survive templating on every published Service.
out25ranges="$TMP/scenario-saas-aws-l4-ranges.yaml"
render_default "$out25ranges" \
  --set global.deploymentMode=saas \
  --set global.domain=cp.example.com \
  --set global.platform=aws \
  --set global.controlPlane.loadBalancerScheme=internet-facing \
  --set 'databridge.service.southbound.loadBalancerSourceRanges[0]=203.0.113.10/32' \
  --set 'agentgateway.configSync.expose.loadBalancerSourceRanges[0]=203.0.113.10/32' \
  --set 'trustguard.configSync.expose.loadBalancerSourceRanges[0]=203.0.113.10/32'
for svc in databridge-southbound agentgateway-admin-configsync trustguard-control-plane-configsync; do
  cidr=$(yq -N "select(.kind == \"Service\" and .metadata.name == \"$svc\")
    | .spec.loadBalancerSourceRanges[0]" "$out25ranges" | sed '/^$/d' | head -1)
  if [[ "$cidr" != "203.0.113.10/32" ]]; then
    red "FAIL: saas aws: $svc dropped loadBalancerSourceRanges (got: ${cidr:-<none>})"
    exit 1
  fi
done
green "ok  - saas aws: loadBalancerSourceRanges fence every published L4 Service"

# controlPlane.domain still wins over global.domain (split-DNS).
out25split="$TMP/scenario-saas-split-dns.yaml"
render_default "$out25split" \
  --set global.deploymentMode=saas \
  --set global.domain=ui.example.com \
  --set global.controlPlane.domain=dial.example.com
split_host=$(yq -N 'select(.kind == "Ingress" and .metadata.name == "clickstack-ingest-gateway")
  | .spec.rules[0].host' "$out25split" | sed '/^$/d' | head -1)
if [[ "$split_host" != "telemetry.dial.example.com" ]]; then
  red "FAIL: saas split-DNS: telemetry host want telemetry.dial.example.com got: ${split_host:-<none>}"
  exit 1
fi
green "ok  - saas: controlPlane.domain overrides global.domain for dial names"

# --- remote side: trusting a private control plane ------------------------
# The three legs a remote data plane dials. Each reads its trust store
# differently, and two of them silently used system roots before this existed:
# the handshake fails at runtime with nothing wrong in the rendered manifest.
out25ca="$TMP/scenario-hybrid-private-ca.yaml"
render_default "$out25ca" \
  --set global.deploymentMode=hybrid \
  --set global.controlPlane.domain=cp.example.com \
  --set agentgateway.configSync.token=cs-trustgate \
  --set trustguard.configSync.token=cs-trustguard \
  --set global.customCaCert.enabled=true \
  --set global.customCaCert.secretName=controlplane-ca \
  --set dataagent.databridge.tlsCa=/etc/ssl/certs/custom-ca.crt \
  --set agentgateway.configSync.tlsCa=/etc/ssl/certs/custom-ca.crt \
  --set trustguard.configSync.tlsCa=/etc/ssl/certs/custom-ca.crt \
  --set global.clickstack.egress.tlsCaSecretName=controlplane-ca
assert_contains "$out25ca" '^  TLS_CA_FILE: "/etc/ssl/certs/custom-ca\.crt"$' \
  "remote: DataAgent verifies DataBridge against the supplied CA"
assert_contains "$out25ca" '^          value: "/etc/ssl/certs/custom-ca\.crt"$' \
  "remote: config-sync clients verify against the supplied CA"
assert_contains "$out25ca" '^          ca_file: /etc/otelcol/ca/ca\.crt$' \
  "remote: telemetry egress verifies the ingest gateway against the supplied CA"
assert_contains "$out25ca" '^      - name: egress-ca-bundle$' \
  "remote: the egress CA bundle is mounted, not just referenced in config"

# One-knob form: domain + raw NLB dial hosts + caSecretName. Mirrors the
# dataplane-bundle CONTROL_PLANE_* model so Docker and Helm hybrid installs
# share the same operator surface. SNI must stay on the cert name (domain),
# not the NLB hostname. DataBridge is genuinely shared; config-sync is per
# product, so two products pin each endpoint rather than a scalar
# controlPlane.configSyncAddr (that combination fails the render).
out25one="$TMP/scenario-hybrid-controlplane-one-knob.yaml"
render_default "$out25one" \
  --set global.deploymentMode=hybrid \
  --set global.controlPlane.domain=neuraltrust.es \
  --set global.controlPlane.databridgeAddr=k8s-databrid.elb.eu-west-1.amazonaws.com:443 \
  --set agentgateway.configSync.endpoint=k8s-agentgat.elb.eu-west-1.amazonaws.com:443 \
  --set trustguard.configSync.endpoint=k8s-trustgua.elb.eu-west-1.amazonaws.com:443 \
  --set global.controlPlane.telemetryUrl=https://k8s-telemetry.elb.eu-west-1.amazonaws.com \
  --set global.controlPlane.caSecretName=controlplane-ca \
  --set agentgateway.configSync.token=cs-trustgate \
  --set trustguard.configSync.token=cs-trustguard
assert_contains "$out25one" '^  DATABRIDGE_ADDR: "k8s-databrid\.elb\.eu-west-1\.amazonaws\.com:443"$' \
  "one-knob: DataAgent dials the raw DataBridge NLB"
assert_contains "$out25one" '^  DATABRIDGE_SERVER_NAME: "databridge\.neuraltrust\.es"$' \
  "one-knob: DataBridge SNI stays on the domain cert name"
assert_contains "$out25one" '^  TLS_CA_FILE: "/etc/ssl/certs/custom-ca\.crt"$' \
  "one-knob: caSecretName expands into DataAgent TLS_CA_FILE"
assert_contains "$out25one" '^          value: "k8s-agentgat\.elb\.eu-west-1\.amazonaws\.com:443"$' \
  "one-knob: AgentGateway config-sync dials its own NLB"
assert_contains "$out25one" '^          value: "k8s-trustgua\.elb\.eu-west-1\.amazonaws\.com:443"$' \
  "one-knob: TrustGuard config-sync dials its own NLB"
assert_contains "$out25one" '^          value: "agentgateway-configsync\.neuraltrust\.es"$' \
  "one-knob: AgentGateway config-sync SNI stays on the domain cert name"
assert_contains "$out25one" '^          value: "trustguard-configsync\.neuraltrust\.es"$' \
  "one-knob: TrustGuard config-sync SNI stays on the domain cert name"
assert_contains "$out25one" '^          value: "/etc/ssl/certs/custom-ca\.crt"$' \
  "one-knob: caSecretName expands into CONFIG_SYNC_TLS_CA"
assert_contains "$out25one" '^        endpoint: "https://k8s-telemetry\.elb\.eu-west-1\.amazonaws\.com"$' \
  "one-knob: egress exporter dials the telemetry URL override"
assert_contains "$out25one" '^          ca_file: /etc/otelcol/ca/ca\.crt$' \
  "one-knob: caSecretName expands into the egress collector CA"
assert_contains "$out25one" '^          include_system_ca_certs_pool: true$' \
  "one-knob: egress CA keeps system roots (public telemetry + chart L4)"
# Go's crypto/x509 treats SSL_CERT_FILE as a REPLACEMENT for the system bundle,
# which would empty SystemCertPool() and silently defeat the flag asserted above.
# The collector must trust its private anchor via exporter tls.ca_file only.
assert_env_value "$out25one" dataagent clickstack-egress-collector SSL_CERT_FILE ABSENT \
  "one-knob: egress collector has no SSL_CERT_FILE (would void the system pool)"
# The DataAgent binary is a different story: it wants an explicit CA file.
assert_env_value "$out25one" dataagent dataagent SSL_CERT_FILE '/etc/ssl/certs/custom-ca.crt' \
  "one-knob: DataAgent still gets the custom CA via SSL_CERT_FILE"
assert_contains "$out25one" '^            secretName: "controlplane-ca"$' \
  "one-knob: custom-ca-cert volume mounts caSecretName"

# Air-gapped operators may close the trust store to private PKI only.
out25nosys="$TMP/scenario-hybrid-egress-no-system-ca.yaml"
render_default "$out25nosys" \
  --set global.deploymentMode=hybrid \
  --set global.controlPlane.domain=platform.example.com \
  --set global.controlPlane.caSecretName=controlplane-ca \
  --set global.clickstack.egress.tlsIncludeSystemCaCerts=false \
  --set agentgateway.configSync.token=cs-trustgate
assert_contains "$out25nosys" '^          ca_file: /etc/otelcol/ca/ca\.crt$' \
  "closed trust store: ca_file still mounts when CA is set"
assert_not_contains "$out25nosys" 'include_system_ca_certs_pool' \
  "closed trust store: tlsIncludeSystemCaCerts=false omits system roots"

# Product-level overrides still beat the umbrella controlPlane dial hosts.
# Do not set controlPlane.configSyncAddr here: values-required enables both
# products, and that scalar with 2+ products fails closed.
out25ovr="$TMP/scenario-hybrid-controlplane-override.yaml"
render_default "$out25ovr" \
  --set global.deploymentMode=hybrid \
  --set global.controlPlane.domain=neuraltrust.es \
  --set global.controlPlane.databridgeAddr=k8s-databrid.elb.amazonaws.com:443 \
  --set dataagent.databridge.addr=custom-bridge.internal:9443 \
  --set dataagent.databridge.serverName=databridge.neuraltrust.es \
  --set agentgateway.configSync.endpoint=custom-sync.internal:8443 \
  --set agentgateway.configSync.serverName=agentgateway-configsync.neuraltrust.es \
  --set agentgateway.configSync.token=cs-trustgate
assert_contains "$out25ovr" '^  DATABRIDGE_ADDR: "custom-bridge\.internal:9443"$' \
  "override: dataagent.databridge.addr beats controlPlane.databridgeAddr"
assert_contains "$out25ovr" '^          value: "custom-sync\.internal:8443"$' \
  "override: configSync.endpoint beats the domain-derived config-sync host"

# Two-product hybrid without dial-host pins: each product derives its own
# <product>-configsync.<domain> listener.
out25two="$TMP/scenario-hybrid-two-product-configsync.yaml"
render_default "$out25two" \
  --set global.deploymentMode=hybrid \
  --set global.controlPlane.domain=neuraltrust.es \
  --set agentgateway.configSync.token=cs-trustgate \
  --set trustguard.configSync.token=cs-trustguard
assert_contains "$out25two" '^          value: "agentgateway-configsync\.neuraltrust\.es:443"$' \
  "two-product: AgentGateway dials agentgateway-configsync.<domain>"
assert_contains "$out25two" '^          value: "trustguard-configsync\.neuraltrust\.es:443"$' \
  "two-product: TrustGuard dials trustguard-configsync.<domain>"

assert_render_fails_with 'configSyncAddr cannot serve more than one product' \
  "scalar configSyncAddr with two products fails closed" \
  --set global.deploymentMode=hybrid \
  --set global.controlPlane.domain=neuraltrust.es \
  --set global.controlPlane.configSyncAddr=k8s-agentgat.elb.amazonaws.com:443 \
  --set agentgateway.configSync.token=cs-trustgate \
  --set trustguard.configSync.token=cs-trustguard

# Defaults must stay on system roots. Emitting an empty TLS_CA_FILE would replace
# the system pool with nothing and break every hybrid install against NeuralTrust.
out25noca="$TMP/scenario-hybrid-system-roots.yaml"
render_default "$out25noca" \
  --set global.deploymentMode=hybrid \
  --set agentgateway.configSync.token=cs-trustgate
assert_not_contains "$out25noca" 'TLS_CA_FILE' \
  "hybrid: no tlsCa leaves DataAgent on the system trust store"
assert_not_contains "$out25noca" 'ca_file' \
  "hybrid: no tlsCaSecretName leaves the egress collector on the system trust store"
assert_not_contains "$out25noca" 'include_system_ca_certs_pool' \
  "hybrid: no CA means no include_system_ca_certs_pool either"
assert_not_contains "$out25noca" 'ALLOW_INSECURE_TRANSPORT' \
  "hybrid: TLS stays on unless insecure is asked for explicitly"

# tlsMode=insecure was unusable before: the binary refuses to start on insecure
# transport without this opt-in, so the value produced a crash loop.
out25insec="$TMP/scenario-hybrid-insecure.yaml"
render_default "$out25insec" \
  --set global.deploymentMode=hybrid \
  --set agentgateway.configSync.token=cs-trustgate \
  --set dataagent.databridge.tlsMode=insecure
assert_contains "$out25insec" '^  ALLOW_INSECURE_TRANSPORT: "true"$' \
  "remote: tlsMode=insecure carries the opt-in the binary demands"

# A bare DNS suffix is the only accepted shape; the others produce endpoints
# that only fail once an agent tries to dial them.
for bad in https://cp.example.com cp.example.com:443 cp.example.com/api localhost; do
  assert_render_fails_with 'control-plane domain must be a' \
    "domain: $bad rejected" \
    --set global.deploymentMode=hybrid \
    --set "global.controlPlane.domain=$bad"
done

# --- saas without a domain of its own -------------------------------------
# Neither global.domain nor controlPlane.domain → refuse (would mint NeuralTrust hosts).
# values-required.yaml ships a domain for other scenarios; clear both knobs here.
assert_render_fails_with 'global.deploymentMode=saas requires a bare domain' \
  "saas: no domain rejected" \
  --set global.deploymentMode=saas \
  --set global.domain= \
  --set global.controlPlane.domain=
# Both existing modes still resolve the regional domain.
out25reg="$TMP/scenario-region-us.yaml"
render_default "$out25reg" \
  --set global.deploymentMode=hybrid --set global.saasRegion=us \
  --set agentgateway.configSync.token=cs-trustgate
assert_contains "$out25reg" 'databridge\.us\.neuraltrust\.ai' \
  "hybrid: saasRegion=us still resolves without a controlPlane.domain"

# --- string-typed booleans ------------------------------------------------
# Flux valuesFrom, Helmfile and --set-string all deliver "false" rather than
# false, and a Go template reads any non-empty string as true. For a flag that
# decides whether a config-sync listener goes on a public load balancer, that
# default is the unsafe one.
out25sf="$TMP/scenario-saas-stringflag.yaml"
render_default "$out25sf" "${SAAS_ARGS[@]}" \
  --set-string agentgateway.configSync.expose.enabled=false \
  --set-string trustguard.configSync.expose.enabled=false
assert_not_contains "$out25sf" '^  name: .*-configsync$' \
  "saas: expose.enabled=\"false\" as a string still keeps both listeners private"

# --- telemetry token drift ------------------------------------------------
# DataCore mints what the gateway verifies, from two independent values blocks.
# They agree on their defaults, so drift needs an override — and it is invisible
# in the manifest, showing up only as a 401 on every batch.
assert_render_fails_with 'telemetry audience mismatch' \
  "saas: audience drift between DataCore and the gateway rejected" \
  "${SAAS_ARGS[@]}" --set datacore.telemetryJwt.audience=other-aud
assert_render_fails_with 'telemetry issuer mismatch' \
  "saas: issuer drift between DataCore and the gateway rejected" \
  "${SAAS_ARGS[@]}" --set datacore.telemetryJwt.issuerUrl=https://datacore.internal
out25aud="$TMP/scenario-saas-aud-agree.yaml"
render_default "$out25aud" "${SAAS_ARGS[@]}" \
  --set datacore.telemetryJwt.audience=other-aud \
  --set clickstack-ingest-gateway.auth.audience=other-aud
assert_contains "$out25aud" '^  TELEMETRY_JWT_AUDIENCE: "other-aud"$' \
  "saas: overriding both sides together is still allowed"

# --- a reissued certificate reaches the listener --------------------------
# These processes read their keypair off disk at startup. Reissue happens when
# the names the certificate covers change, which is what retargeting the domain
# does, so without a checksum the Secret updates and the listener keeps serving
# a certificate the remote clusters no longer accept.
# Only the chart-generated path can reissue, so assert on that scenario. An
# operator-supplied or cert-manager Secret rotates outside the chart's knowledge
# and a template checksum could not see it either way.
for dep in databridge agentgateway-admin trustguard-control-plane; do
  ann=$(yq eval "select(.kind == \"Deployment\" and .metadata.name == \"$dep\")
    | .spec.template.metadata.annotations | keys | join(\",\")" "$out25gen")
  case "$ann" in
    *checksum/southbound-tls*|*checksum/configsync-tls*) ;;
    *)
      red "FAIL: saas: $dep is not rolled when its certificate is reissued (annotations: ${ann:-none})"
      exit 1 ;;
  esac
done
green "ok  - saas: a reissued certificate rolls the pod that serves it"
# Nothing new on the existing modes: they never reissue, and a fresh annotation
# would restart every control plane on upgrade for no reason.
assert_not_contains "$out25ext" 'checksum/configsync-tls' \
  "external: no certificate checksum annotation appears"
# Happy-path saas mints the leaf, so checksum is present on out25. BYO path
# must not annotate — rotation is outside the chart.
out25byo="$TMP/scenario-saas-byo-tls.yaml"
render_default "$out25byo" "${SAAS_BYO_ARGS[@]}"
assert_not_contains "$out25byo" 'checksum/southbound-tls' \
  "saas: an operator-supplied DataBridge cert gets no chart checksum"
assert_contains "$out25" 'checksum/southbound-tls' \
  "saas: chart-minted DataBridge cert rolls the pod on reissue"

# --- the broker's budget must not deadlock a drain -----------------------
# Default HA (replicas=2): minAvailable 1 lets a drain take one pod at a time.
# Singleton (replicas=1): maxUnavailable 1 — already asserted on out25single above.
assert_pdb_shape "$out25" minAvailable 1 \
  "saas: default HA DataBridge PDB keeps one pod through a drain"
assert_pdb_shape "$out25single" maxUnavailable 1 \
  "saas: singleton DataBridge PDB allows a node drain to proceed"

# =========================================================================
# Scenario 10c2 — imagePullSecrets: "none" actually suppresses
# =========================================================================
# Nine subcharts carried byte-identical resolvers and every one of them dropped
# the "none" check in the list branch, so global.imagePullSecrets: ["none"]
# rendered `- name: none` — a reference to a Secret that does not exist, i.e. an
# ImagePullBackOff on exactly the IAM / Workload Identity clusters that set it to
# opt out. charts/clickhouse, charts/firewall and charts/watchdog had their own
# inline variants with the same or worse gaps.
#
# These assertions are the regression fence. The whole point of the fix is that
# the string "name: none" can never reach a rendered podspec.

# Helper: resolve one workload's pull secrets to a comma-joined string.
pull_secrets_of() {
  local file="$1" kind="$2" name="$3"
  yq eval "select(.kind == \"$kind\" and .metadata.name == \"$name\")
    | (.spec.template.spec.imagePullSecrets // []) | map(.name) | join(\",\")" "$file"
}

# --- 1. the default install is byte-identical to before the refactor -------
# The delegating wrappers must not change what a default render emits; every
# product workload still pulls with gcr-secret, now from the resolver's default.
out10c2="$TMP/scenario-pullsecret-default.yaml"
render_default "$out10c2" --set global.deploymentMode=external \
  --set watchdog.enabled=true --set clickhouse.backup.enabled=true
for _w in "Deployment:datacore" "Deployment:firewall" "Deployment:toxicity-worker" \
          "Deployment:alertengine-api" "Deployment:clickstack-collector" \
          "Deployment:agentgateway-proxy" "Deployment:trustguard-data-plane" \
          "Deployment:redis" "StatefulSet:clickhouse" "StatefulSet:neuraltrust-watchdog"; do
  _got=$(pull_secrets_of "$out10c2" "${_w%%:*}" "${_w##*:}")
  if [[ "$_got" != "gcr-secret" ]]; then
    red "FAIL: default install: ${_w##*:} pull secret changed (got: ${_got:-<none>}, want gcr-secret)"
    exit 1
  fi
done
green "ok  - default install still pulls with gcr-secret across every chart family"

# --- 2. a "none" pin suppresses, and leaves no phantom Secret name ---------
out10c2n="$TMP/scenario-pullsecret-none-pin.yaml"
render_default "$out10c2n" --set global.deploymentMode=external \
  --set watchdog.enabled=true --set clickhouse.backup.enabled=true \
  --set datacore.imagePullSecrets=none \
  --set firewall.firewall.imagePullSecrets=none \
  --set clickhouse.imagePullSecrets=none \
  --set watchdog.imagePullSecrets=none
for _w in "Deployment:datacore" "Deployment:firewall" "Deployment:toxicity-worker" \
          "StatefulSet:clickhouse" "StatefulSet:neuraltrust-watchdog"; do
  _got=$(pull_secrets_of "$out10c2n" "${_w%%:*}" "${_w##*:}")
  if [[ -n "$_got" ]]; then
    red "FAIL: imagePullSecrets=none: ${_w##*:} still carries a pull secret (got: $_got)"
    exit 1
  fi
done
green "ok  - a \"none\" pin suppresses pull secrets on subchart, firewall, clickhouse and watchdog workloads"

# The fence that matters most: "none" must never render as a Secret name. It is
# valid YAML and a valid object reference, so nothing else catches it.
assert_not_contains "$out10c2n" '^        - name: none$' \
  "no workload references a Secret literally named \"none\""

# The backup CronJob had drifted furthest — no "none" guard at all — so a chart
# pinned to "none" gave the Job a pull secret the StatefulSet correctly omitted.
cj_pull=$(yq eval 'select(.kind == "CronJob" and .metadata.name == "clickhouse-backup")
  | (.spec.jobTemplate.spec.template.spec.imagePullSecrets // []) | map(.name) | join(",")' "$out10c2n")
if [[ -n "$cj_pull" ]]; then
  red "FAIL: clickhouse backup CronJob ignores imagePullSecrets=none (got: $cj_pull)"
  exit 1
fi
green "ok  - the clickhouse backup CronJob honours \"none\" like its StatefulSet sibling"

# --- 3. global ["none"] suppresses where the chart has no values pin -------
# redis, the OTel collector and control-plane default in the template, so an
# unset key falls through to the global list. Both previously rendered
# `- name: none` from a global opt-out.
out10c2g="$TMP/scenario-pullsecret-none-global.yaml"
render_default "$out10c2g" --set global.deploymentMode=external \
  --set 'global.imagePullSecrets={none}'
for _n in redis control-plane-api control-plane-app control-plane-postgresql; do
  _got=$(pull_secrets_of "$out10c2g" Deployment "$_n")
  if [[ -n "$_got" ]]; then
    red "FAIL: global.imagePullSecrets=[none]: $_n still carries a pull secret (got: $_got)"
    exit 1
  fi
done
green "ok  - global [\"none\"] suppresses redis, control-plane api/app and postgresql"
assert_not_contains "$out10c2g" '^        - name: none$' \
  "global [\"none\"] leaves no phantom Secret name anywhere"

# --- 4. a list-of-{name:} global is valid YAML everywhere ------------------
# charts/clickhouse concatenated the global list into `- name: {{ . }}`, so a
# list-of-maps global — an accepted shape in every other chart — rendered a map
# into a scalar position. `helm template` parses, but the object is malformed.
# Rendering through yq is itself the assertion: a broken document fails to parse.
out10c2m="$TMP/scenario-pullsecret-global-maps.yaml"
render_default "$out10c2m" --set global.deploymentMode=external \
  --set watchdog.enabled=true \
  --set clickhouse.imagePullSecrets=null \
  --set datacore.imagePullSecrets=null \
  --set watchdog.imagePullSecrets=null \
  --set 'global.imagePullSecrets[0].name=mirror-registry'
for _w in "StatefulSet:clickhouse" "Deployment:datacore" "StatefulSet:neuraltrust-watchdog"; do
  _got=$(pull_secrets_of "$out10c2m" "${_w%%:*}" "${_w##*:}")
  if [[ "$_got" != "mirror-registry" ]]; then
    red "FAIL: list-of-maps global: ${_w##*:} did not resolve (got: ${_got:-<none>}, want mirror-registry)"
    exit 1
  fi
done
green "ok  - a list-of-{name:} global.imagePullSecrets resolves to a valid Secret reference"

# --- 5. firewall and watchdog gained a global fallback they never had ------
# Both read only their local key before, so an operator setting only the global
# list got the pinned default silently.
out10c2f="$TMP/scenario-pullsecret-global-fallback.yaml"
render_default "$out10c2f" --set global.deploymentMode=external \
  --set watchdog.enabled=true \
  --set firewall.firewall.imagePullSecrets="" \
  --set watchdog.imagePullSecrets=null \
  --set 'global.imagePullSecrets={my-registry}'
for _w in "Deployment:firewall" "Deployment:toxicity-worker" "StatefulSet:neuraltrust-watchdog"; do
  _got=$(pull_secrets_of "$out10c2f" "${_w%%:*}" "${_w##*:}")
  if [[ "$_got" != "my-registry" ]]; then
    red "FAIL: cleared pin + global: ${_w##*:} did not fall through (got: ${_got:-<none>}, want my-registry)"
    exit 1
  fi
done
green "ok  - clearing a firewall/watchdog pin lets global.imagePullSecrets win"

# --- 6. the scalar accessor data-plane-api needs still works --------------
# api/deployment.yaml forwards the resolved NAME into K8S_JOB_IMAGE_PULL_SECRET so
# Jobs the API spawns pull with the same credential. A block-only refactor would
# silently drop it, and nothing else in the suite covers that env var.
# The env var only renders when k8sJobs is enabled, which is off by default.
out10c2j="$TMP/scenario-pullsecret-job-name.yaml"
render_default "$out10c2j" --set global.deploymentMode=external \
  --set data-plane-api.dataPlane.components.api.k8sJobs.enabled=true
jobsecret=$(yq eval 'select(.kind == "Deployment" and .metadata.name == "data-plane-api")
  | .spec.template.spec.containers[0].env[] | select(.name == "K8S_JOB_IMAGE_PULL_SECRET") | .value' "$out10c2j")
podsecret=$(pull_secrets_of "$out10c2j" Deployment data-plane-api)
if [[ -z "$jobsecret" || "$jobsecret" != "$podsecret" ]]; then
  red "FAIL: K8S_JOB_IMAGE_PULL_SECRET ($jobsecret) does not match the podspec pull secret ($podsecret)"
  exit 1
fi
green "ok  - K8S_JOB_IMAGE_PULL_SECRET resolves to the same name the podspec pulls with"

# And it must vanish, not render "none", when the operator opts out.
out10c2jn="$TMP/scenario-pullsecret-job-none.yaml"
render_default "$out10c2jn" --set global.deploymentMode=external \
  --set data-plane-api.dataPlane.components.api.k8sJobs.enabled=true \
  --set data-plane-api.dataPlane.imagePullSecrets=none
assert_not_contains "$out10c2jn" 'K8S_JOB_IMAGE_PULL_SECRET' \
  "data-plane-api omits the Job pull-secret env entirely when set to \"none\""

# --- 7. global.imagePullSecrets alone reaches every workload --------------
# The product charts used to pin gcr-secret in their own values, so a mirrored
# install had to clear every pin by hand before the global list counted. The
# pins are gone; the gcr-secret default lives in the shared resolver instead.
_PULL_WORKLOADS=("Deployment:datacore" "Deployment:firewall" "Deployment:toxicity-worker"
  "Deployment:alertengine-api" "Deployment:clickstack-collector"
  "Deployment:agentgateway-proxy" "Deployment:trustguard-data-plane"
  "Deployment:data-plane-api" "Deployment:control-plane-app" "Deployment:redis"
  "StatefulSet:clickhouse" "StatefulSet:neuraltrust-watchdog")
out10c2go="$TMP/scenario-pullsecret-global-only.yaml"
render_default "$out10c2go" --set global.deploymentMode=external \
  --set watchdog.enabled=true \
  --set data-plane-api.dataPlane.components.api.k8sJobs.enabled=true \
  --set 'global.imagePullSecrets={mirror-registry}'
for _w in "${_PULL_WORKLOADS[@]}"; do
  _got=$(pull_secrets_of "$out10c2go" "${_w%%:*}" "${_w##*:}")
  if [[ "$_got" != "mirror-registry" ]]; then
    red "FAIL: global-only: ${_w##*:} ignored global.imagePullSecrets (got: ${_got:-<none>}, want mirror-registry)"
    exit 1
  fi
done
green "ok  - global.imagePullSecrets alone reaches every chart family, with no per-chart key"
jobsecret=$(yq eval 'select(.kind == "Deployment" and .metadata.name == "data-plane-api")
  | .spec.template.spec.containers[0].env[] | select(.name == "K8S_JOB_IMAGE_PULL_SECRET") | .value' "$out10c2go")
if [[ "$jobsecret" != "mirror-registry" ]]; then
  red "FAIL: K8S_JOB_IMAGE_PULL_SECRET did not follow the global list (got: ${jobsecret:-<none>})"
  exit 1
fi
green "ok  - data-plane-api forwards the global pull secret to the Jobs it spawns"

# --- 8. global ["none"] now suppresses the product charts too -------------
# Before, their gcr-secret pin outranked the global opt-out, so an IAM cluster
# still referenced a Secret it never created.
out10c2gn="$TMP/scenario-pullsecret-global-none-products.yaml"
render_default "$out10c2gn" --set global.deploymentMode=external \
  --set watchdog.enabled=true --set 'global.imagePullSecrets={none}'
for _w in "${_PULL_WORKLOADS[@]}"; do
  _got=$(pull_secrets_of "$out10c2gn" "${_w%%:*}" "${_w##*:}")
  if [[ -n "$_got" ]]; then
    red "FAIL: global [none]: ${_w##*:} still carries a pull secret (got: $_got)"
    exit 1
  fi
done
green "ok  - global [\"none\"] suppresses pull secrets on every chart family"

# --- 9. an explicit empty key keeps its old meaning -----------------------
# "" / [] were the documented IAM opt-out before the pins went away. Unset now
# falls back to gcr-secret, so an empty value must NOT: it takes the global list
# when there is one and otherwise renders nothing. At data-plane-api's component
# tier "" always meant none outright, and still does even with a global list.
out10c2e="$TMP/scenario-pullsecret-empty-key.yaml"
render_default "$out10c2e" --set global.deploymentMode=external \
  --set watchdog.enabled=true \
  --set datacore.imagePullSecrets="" \
  --set firewall.firewall.imagePullSecrets="" \
  --set 'watchdog.imagePullSecrets={}' \
  --set data-plane-api.dataPlane.imagePullSecrets=""
for _w in "Deployment:datacore" "Deployment:firewall" "StatefulSet:neuraltrust-watchdog" \
          "Deployment:data-plane-api"; do
  _got=$(pull_secrets_of "$out10c2e" "${_w%%:*}" "${_w##*:}")
  if [[ -n "$_got" ]]; then
    red "FAIL: empty key, no global: ${_w##*:} gained a pull secret (got: $_got)"
    exit 1
  fi
done
_got=$(pull_secrets_of "$out10c2e" Deployment alertengine-api)
if [[ "$_got" != "gcr-secret" ]]; then
  red "FAIL: unset key, no global: alertengine-api lost the gcr-secret default (got: ${_got:-<none>})"
  exit 1
fi
green "ok  - an empty key renders no pull secret while an unset key keeps gcr-secret"
out10c2eg="$TMP/scenario-pullsecret-empty-key-global.yaml"
render_default "$out10c2eg" --set global.deploymentMode=external \
  --set datacore.imagePullSecrets="" \
  --set data-plane-api.dataPlane.imagePullSecrets="" \
  --set 'global.imagePullSecrets={mirror-registry}'
_got=$(pull_secrets_of "$out10c2eg" Deployment datacore)
_dpa=$(pull_secrets_of "$out10c2eg" Deployment data-plane-api)
if [[ "$_got" != "mirror-registry" || -n "$_dpa" ]]; then
  red "FAIL: empty key + global: datacore=${_got:-<none>} (want mirror-registry), data-plane-api=${_dpa:-<none>} (want none)"
  exit 1
fi
green "ok  - an empty product key takes the global list; data-plane-api's \"\" still means none"

# =========================================================================
# Scenario 10c2r — one replica key: `replicas`, with `replicaCount` as alias
# =========================================================================
# control-plane-api, control-plane-app, clickhouse and watchdog were the only
# charts keyed on `replicaCount`. They now read `replicas` like every other
# chart, and keep honouring `replicaCount` because live overlays still set it.

replicas_of() {
  yq eval "select(.kind == \"$2\" and .metadata.name == \"$3\") | .spec.replicas" "$1"
}
_REPLICA_WORKLOADS=("Deployment:control-plane-api:3" "Deployment:control-plane-app:4"
  "StatefulSet:clickhouse:2" "StatefulSet:neuraltrust-watchdog:2")
for _key in replicas replicaCount; do
  outrep="$TMP/scenario-replicas-$_key.yaml"
  render_default "$outrep" --set global.deploymentMode=external --set watchdog.enabled=true \
    --set "control-plane-api.controlPlane.components.api.$_key=3" \
    --set "control-plane-app.controlPlane.components.app.$_key=4" \
    --set "clickhouse.$_key=2" --set "watchdog.$_key=2"
  for _w in "${_REPLICA_WORKLOADS[@]}"; do
    IFS=: read -r _k _n _want <<<"$_w"
    _got=$(replicas_of "$outrep" "$_k" "$_n")
    if [[ "$_got" != "$_want" ]]; then
      red "FAIL: $_key: $_n replicas=$_got, want $_want"
      exit 1
    fi
  done
  green "ok  - \`$_key\` sets replicas on control-plane api/app, clickhouse and watchdog"
done

# The alias wins over the new key: no chart default sets it, so it is always
# the operator's own override.
outrepb="$TMP/scenario-replicas-both.yaml"
render_default "$outrepb" --set global.deploymentMode=external \
  --set control-plane-api.controlPlane.components.api.replicas=3 \
  --set control-plane-api.controlPlane.components.api.replicaCount=5
if [[ "$(replicas_of "$outrepb" Deployment control-plane-api)" != "5" ]]; then
  red "FAIL: replicaCount did not win over replicas on control-plane-api"
  exit 1
fi
green "ok  - an operator's replicaCount still wins over the chart's replicas default"

# =========================================================================
# Scenario 10c3 — an external ClickHouse reaches every consumer
# =========================================================================
# infrastructure.clickhouse.external was read by exactly ONE of the five
# consumers, because .Values.infrastructure is invisible to a subchart. So
# `deploy: false` plus an external host left datacore, alertengine and the
# ClickStack collector dialling a Service that is never rendered. There was no
# scenario asserting the external path reached anything, which is why it shipped.
#
# The contract is now global.clickhouse. These assertions are the fence: every
# consumer must follow it, and the in-cluster default must not move.
