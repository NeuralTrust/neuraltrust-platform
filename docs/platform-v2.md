# Platform v2

Platform v2 is the default NeuralTrust architecture. Two global values select
the topology:

```yaml
global:
  platformVersion: "v2"
  deploymentMode: "hybrid" # hybrid | external
```

`full` is a deprecated alias for `external`.

## Hybrid: default split-plane

Hybrid keeps control-plane services in NeuralTrust SaaS and deploys the data
path in the customer cluster:

- AgentGateway proxy and MCP
- TrustGuard data plane
- PostgreSQL and Redis by default
- optional Firewall
- optional, enrolment-gated DataAgent

Hybrid does **not** deploy an in-cluster ClickHouse: analytics live in NeuralTrust
SaaS (the data planes write raw telemetry to PostgreSQL, DataAgent bridges it out,
and you can optionally also stream product data to a ClickStack collector — see
below). The temporary `data-plane-api` read shim therefore renders only when you
point it at an **external** ClickHouse (a dotted
`neuraltrust-data-plane.dataPlane.components.clickhouse.host`); with the default
bare host the shim stays off. In-cluster ClickHouse deploys only in v2 external
(and v1).

Leave DataAgent enrolment empty until a tenant identifier and token are issued:

```yaml
dataagent:
  tenantId: ""
  enrolmentTokenExistingSecret:
    name: ""
    key: "ENROLMENT_TOKEN"
```

DataAgent renders only when both values are present. It reads only the entitled
local PostgreSQL data and opens an outbound TLS stream to SaaS DataBridge. It
has no Ingress or public Service.

### Optional: also stream product data to a ClickStack collector

By default hybrid persists raw AgentGateway/TrustGuard payloads to the local
PostgreSQL for DataAgent. To ALSO dual-write product data (`meta`/`raw`) over
OTLP to a ClickStack collector — without dropping the Postgres/DataAgent path —
enable `global.clickstack`:

```yaml
global:
  clickstack:
    enabled: true
    endpoint: "https://clickstack-collector.example.com/v1/logs"
    protocol: "http/protobuf"
    insecure: false            # public TLS route; true only for a plaintext in-cluster Service
    authToken: "<OTLP_AUTH_TOKEN>"  # collector's bearer token
```

The endpoint is required when enabled (the public route exposes OTLP/HTTP only,
port `:4318`). The token is stored solely in the `agentgateway-secrets` /
`trustguard-secrets` Secret as `OTEL_EXPORTER_OTLP_HEADERS`; with
`global.preserveExistingSecrets=true`, add that key to the pre-created Secrets
yourself. External mode always exports to its in-cluster ClickStack collector
and ignores this block.

## External: self-hosted

External moves the control planes and product console into the cluster and adds
the self-hosted analytics stack:

- AgentGateway admin, proxy, and MCP
- TrustGuard control and data planes
- product control-plane API and web app
- ClickStack OTel Collector
- DataCore
- AlertEngine API and worker
- temporary data-plane API read shim

DataAgent never renders in external mode. The ClickStack collector is also
external-only: AgentGateway and TrustGuard load metadata/raw OTLP exporter
profiles that target it, and it writes the resulting signals to the `otel`
ClickHouse database.
DataCore serves residency queries and AlertEngine evaluates rules and forwards
findings to configured SIEM/integration destinations.

Set `global.observability.hostedExport.enabled: false` for a deployment with no
NeuralTrust SaaS telemetry egress.

## Components

| Component | Hybrid | External | Purpose |
|---|:---:|:---:|---|
| AgentGateway proxy/MCP | yes | yes | AI gateway data path |
| AgentGateway admin | SaaS | yes | Gateway administration |
| TrustGuard data plane | yes | yes | Runtime safety evaluation |
| TrustGuard control plane | SaaS | yes | Policy administration |
| data-plane API shim | external ClickHouse only | yes | Temporary ClickHouse read API |
| DataAgent | enrolled only | no | Outbound entitled-query bridge |
| ClickStack OTel Collector | no | yes | OTLP to ClickHouse |
| DataCore | no | yes | Residency query API |
| AlertEngine | no | yes | Alert evaluation and SIEM/integration forwarding |
| TrustLens | opt-in | opt-in | WIP analytics/inventory replacement |
| Firewall | optional | optional | Prompt and response safety |

## Datastores

PostgreSQL and Redis deploy in-cluster by default in both modes. ClickHouse
deploys in-cluster only in **external** (and v1) — hybrid keeps analytics in SaaS,
so no in-cluster ClickHouse renders there. Kafka is not part of Platform v2 and
never renders.

Hybrid PostgreSQL uses a shared `trustdata` database with isolated
AgentGateway and TrustGuard schemas. When DataAgent is enabled, its read-only
role is granted access to both schemas. If you want the temporary `data-plane-api`
read shim in hybrid, point it at an external/managed ClickHouse by setting a
dotted `neuraltrust-data-plane.dataPlane.components.clickhouse.host` (and its
`existingSecret`); otherwise the shim stays off.

External gives control-plane services separate databases. AlertEngine also owns
its own PostgreSQL database. ClickStack, DataCore, AlertEngine, and the
data-plane API shim share the selected ClickHouse credentials through existing
Kubernetes Secrets.

The data-plane API shim also uses Redis for its evaluation-progress cache
(`EVALUATION_PROGRESS_BACKEND`): v1 keeps the existing Kafka-backed behavior,
while v2 points it at the same Redis AgentGateway/TrustGuard use, via
`neuraltrust-data-plane.dataPlane.components.api.redis` (host/port/password/
username/tls, plus AWS ElastiCache IAM auth). Set `redis.host` (and
`password`/`iamAuth`, etc.) there to match `infrastructure.redis.external`
when `infrastructure.redis.deploy=false`.

To use managed datastores, disable each in-cluster component and configure
service-specific endpoints:

```yaml
global:
  postgresql:
    deploy: false

infrastructure:
  redis:
    deploy: false
  clickhouse:
    deploy: false
  kafka:
    deploy: false
```

See `values-v2-managed-datastores.yaml.example`. External PostgreSQL roles and
databases must be pre-created.

## Observability collectors

Do not confuse the two collectors:

- The umbrella OTel Collector (`global.observability.enabled`) is portable
  cluster observability and can optionally export to NeuralTrust.
- The ClickStack OTel Collector is an external-mode application component that
  lands self-hosted product telemetry in ClickHouse.

Disabling hosted export does not disable the external-mode ClickStack pipeline.

## Retired legacy components

Under v2:

- legacy TrustGate is replaced by AgentGateway
- Kafka, Kafka Connect, and Kafka workers are disabled
- the legacy scheduler is disabled
- AISPM is retired
- the SIEM Connector subchart is retired
- AlertEngine owns supported SIEM and integration forwarding

The legacy data-plane subchart remains only for the temporary API read shim;
its worker and Kafka Connect workloads remain off.

## Legacy v1 appendix

Existing v1 deployments must pin:

```yaml
global:
  platformVersion: "v1"
```

v1 remains available for compatibility and is the only generation that can
render legacy TrustGate and Kafka workloads. New deployments should use v2.

For a live v1 release, chart 2.0 detects legacy workloads and refuses to replace
them silently. First remove any retired AISPM/SIEM add-ons on the current 1.x
chart and back up stateful services. Then choose one upgrade path:

```yaml
# Keep the existing stack.
global:
  platformVersion: "v1"
```

```yaml
# Explicitly authorize the reviewed v1-to-v2 workload replacement.
global:
  platformVersion: "v2"
  confirmV2Migration: true
```

Keep `confirmV2Migration: true` for the first v2 reconciliation so newly
introduced v2 Secrets can be created safely. Remove it after the v2 release is
healthy; subsequent upgrades reuse the live Secrets through `lookup`. Renderers
without cluster `lookup` access must pre-create the v2 Secrets and set
`global.preserveExistingSecrets: true`; confirmation alone never authorizes
random Secret regeneration.

## Operator examples

- `values-required.yaml`: minimal v2 hybrid
- `values-v2.yaml.example`: documented v2 hybrid
- `values-v2-external.yaml.example`: minimal external
- `values-all-deployed.yaml.example`: external plus supported optional components
- `values-v2-managed-datastores.yaml.example`: external managed datastores
- `values-v1-legacy.yaml.example`: explicit v1
