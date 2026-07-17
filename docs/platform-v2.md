# Platform v2

This chart (2.x) is v2-only. One global value selects the topology:

```yaml
global:
  deploymentMode: "hybrid" # hybrid | external
```

## Hybrid: default split-plane

Hybrid keeps control-plane services in NeuralTrust SaaS and deploys the data
path in the customer cluster:

- AgentGateway proxy and MCP
- TrustGuard data plane
- PostgreSQL and Redis by default
- optional Firewall
- optional, enrolment-gated DataAgent

Hybrid does **not** deploy an in-cluster ClickHouse: analytics live in NeuralTrust
SaaS. AgentGateway and TrustGuard **always dual-write** product data over OTLP to
the NeuralTrust SaaS ClickStack collector (fixed endpoint, protocol, and TLS)
while ALSO persisting raw payloads to the local PostgreSQL for DataAgent — see
[the token setup below](#operator-input-clickstack-otlp-token). The temporary `data-plane-api` read shim renders **by default** in hybrid
and reads from the umbrella-managed **PostgreSQL** (`SQL_DATABASE=postgres`), so no
ClickHouse is required. Its schema is applied by a `postgres-migrations`
initContainer (idempotent, advisory-locked). If you instead want it to read from
an **external/managed ClickHouse**, either set a dotted
`data-plane-api.dataPlane.components.clickhouse.host` (auto-resolves to
ClickHouse) or force it with
`data-plane-api.dataPlane.components.api.database.backend: clickhouse`.
The backend can also be pinned to `postgres` explicitly. In-cluster ClickHouse
deploys only in external mode.

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

### Operator input: ClickStack OTLP token

The v2 hybrid ClickStack export is **always on** and targets the NeuralTrust
SaaS collector:

- **endpoint** `https://clickstack-collector.neuraltrust.ai/v1/logs`
- **protocol** `http/protobuf`
- **TLS** enforced (system-root verification; no `OTEL_EXPORTER_OTLP_INSECURE`)

The operator supplies **only** the bearer token — either inline via
`authToken`, or by pre-creating a Secret and pointing `existingSecret.name` at
it. Rendering fails when neither is set.

```yaml
global:
  clickstack:
    authToken: "<CLICKSTACK_OTLP_TOKEN>"
```

Or reference a pre-created Secret carrying the full OTLP header value:

```yaml
global:
  clickstack:
    existingSecret:
      name: "clickstack-otlp-token"
      key: "OTEL_EXPORTER_OTLP_HEADERS"   # optional (default shown)
```

Create the Secret out-of-band, e.g.:

```bash
kubectl create secret generic clickstack-otlp-token \
  --from-literal=OTEL_EXPORTER_OTLP_HEADERS='authorization=<CLICKSTACK_OTLP_TOKEN>'
```

The inline `authToken` flow stores the header in the chart-managed
`agentgateway-secrets` / `trustguard-secrets` (`envFrom` picks it up). The
`existingSecret` flow mounts `OTEL_EXPORTER_OTLP_HEADERS` directly from the
referenced Secret via `secretKeyRef`, so the chart never sees the value —
recommended for `preserveExistingSecrets=true` and GitOps flows where `lookup`
is not available.

**Air-gap escape hatch.** Set `global.clickstack.enabled: false` to skip the
OTLP dual-write entirely; raw payloads still land in PostgreSQL for DataAgent.

The legacy `endpoint` / `protocol` / `insecure` knobs remain honored as
deprecated overrides (leave empty for the fixed SaaS defaults). External mode
always exports to its in-cluster ClickStack collector and ignores this block.

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
profiles that target `http://clickstack-collector.<ns>.svc.cluster.local:4318`
(OTLP base URL — no `/v1/logs` suffix) and authenticate with
`OTEL_EXPORTER_OTLP_HEADERS` from `clickstack-collector-secrets` (same token as
`OTLP_AUTH_TOKEN`). The collector writes signals to the `otel` ClickHouse
database.
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
| data-plane API shim | yes (PostgreSQL) | yes (ClickHouse) | Temporary read API — PostgreSQL by default in hybrid, ClickHouse in external |
| DataAgent | enrolled only | no | Outbound entitled-query bridge |
| ClickStack OTel Collector | no | yes | OTLP to ClickHouse |
| DataCore | no | yes | Residency query API (ClickHouse + Postgres metadata) |
| AlertEngine | no | yes | Alert evaluation and SIEM/integration forwarding |
| TrustLens | opt-in | opt-in | WIP analytics/inventory replacement |
| Firewall | optional | optional | Prompt and response safety |

## Datastores

PostgreSQL and Redis deploy in-cluster by default in both modes. ClickHouse
deploys in-cluster only in **external** — hybrid keeps analytics in SaaS, so no
in-cluster ClickHouse renders there.

Hybrid PostgreSQL and Redis use ONE shared connection contract driven by two
top-level blocks in `values.yaml`:

```yaml
global:
  postgresql:
    deploy: true
    host: ""           # empty + deploy=true -> in-cluster "control-plane-postgresql"
    port: 5432
    user: neuraltrust
    database: neuraltrust
    password: ""       # auto-generated into postgresql-secrets when empty
    sslMode: prefer
    existingSecret:
      name: ""         # optional; provide a pre-created Secret instead
  redis:
    deploy: true
    host: ""           # empty + deploy=true -> in-cluster "redis"
    port: 6379
    password: ""       # in-cluster default is passwordless
    existingSecret:
      name: ""
```

The chart renders two shared Kubernetes Secrets:

- `postgresql-secrets` — POSTGRES_* keys **plus** `DB_HOST`, `DB_PORT`, `DB_USER`,
  `DB_PASSWORD`, `DB_NAME`, `DB_SSL_MODE`, `DATABASE_URL`, `SENSIBLE_PG_DSN`.
- `redis-secrets` — `REDIS_HOST`, `REDIS_PORT`, `REDIS_PASSWORD`, `REDIS_USERNAME`,
  `REDIS_TLS`.

Every hybrid workload (AgentGateway, TrustGuard, DataAgent, `data-plane-api`)
`envFrom`'s these Secrets, so all four connect as the single `neuraltrust` role
to the shared `neuraltrust` database. There is **no** chart-managed schema/role
init Job in hybrid — application migrations (already namespaced:
`trustgate_migration_versions`, `trustguard_migration_versions`) own their tables
directly. For an external / managed PostgreSQL, the DBA (or Terraform)
pre-creates the database and role before install; point the chart at it via
`global.postgresql.deploy: false` + host/user/password (or set
`global.postgresql.existingSecret.name`). The `data-plane-api` read shim runs on
PostgreSQL by default in hybrid, sharing the same `postgresql-secrets` — a
`postgres-migrations` initContainer applies its own schema
(`neuraltrust` schema + `tests`/`test_runs` tables). Point it at an
external/managed ClickHouse instead by setting a dotted
`data-plane-api.dataPlane.components.clickhouse.host` (and its
`existingSecret`), or force the backend with
`data-plane-api.dataPlane.components.api.database.backend`.

External gives control-plane services separate per-service databases. AlertEngine
also owns its own PostgreSQL database. In external mode the data-plane API shim
stays on ClickHouse; ClickStack, DataCore, AlertEngine, and the data-plane API
shim share the selected ClickHouse credentials through existing Kubernetes
Secrets. The per-service `agentgateway.database` / `trustguard.database` /
`trustlens.database` / `alertengine.database` overlays remain the source of truth
for external mode — `global.postgresql.*` is ignored there.

The data-plane API shim also uses Redis for its evaluation-progress cache
(`EVALUATION_PROGRESS_BACKEND`), pointed at the same Redis AgentGateway and
TrustGuard use via `data-plane-api.dataPlane.components.api.redis`
(host/port/password/username/tls, plus AWS ElastiCache IAM auth). Set
`redis.host` (and `password`/`iamAuth`, etc.) there to match
`infrastructure.redis.external` when `infrastructure.redis.deploy=false`.
Pooling and batching default to 100 connections and 200 keys per MGET;
`maxConnections`, `mgetChunkSize`, and the optional connect/socket/health-check
timeout values under `api.redis` override them.

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

## Legacy v1

v1 (legacy TrustGate/Kafka) is maintained only on the `v1.14.x` release line;
pin `--version ~1.14.0` to install it. This chart (2.x) is v2-only.

## Operator examples

- `values-required.yaml`: minimal hybrid
- `values-v2.yaml.example`: documented hybrid
- `values-v2-hybrid.yaml.example`: hybrid topology overlay
- `values-v2-external.yaml.example`: minimal external
- `values-all-deployed.yaml.example`: external plus supported optional components
- `values-v2-managed-datastores.yaml.example`: external managed datastores
