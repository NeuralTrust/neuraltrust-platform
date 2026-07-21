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
- DataAgent (enrolment required for hybrid OTLP egress and DataBridge)

Hybrid does **not** deploy an in-cluster ClickHouse: analytics live in NeuralTrust
SaaS. AgentGateway and TrustGuard **always dual-write** product data over OTLP
via a local `clickstack-egress-collector` (enrolment-backed; see
[hybrid ClickStack OTLP](#hybrid-clickstack-otlp-mandatory)) while ALSO
persisting raw payloads to the local PostgreSQL for DataAgent. The temporary
`data-plane-api` read shim renders **by default** in hybrid and reads from the
umbrella-managed **PostgreSQL** (`SQL_DATABASE=postgres`), so no ClickHouse is
required. Its schema is applied by a `postgres-migrations` initContainer
(idempotent, advisory-locked). If you instead want it to read from an
**external/managed ClickHouse**, either set a dotted
`data-plane-api.dataPlane.components.clickhouse.host` (auto-resolves to
ClickHouse) or force it with
`data-plane-api.dataPlane.components.api.database.backend: clickhouse`.
The backend can also be pinned to `postgres` explicitly. In-cluster ClickHouse
deploys only in external mode.

### Hybrid control and data channels

SaaS-managed hybrid uses two config-sync channels, mandatory ClickStack OTLP
(via the DataAgent egress sidecar), and DataAgent DataBridge. Every connection
is initiated by the customer cluster over TLS:

1. AgentGateway proxy/MCP opens config-sync gRPC to
   `agentgateway-configsync.neuraltrust.ai:443`.
2. TrustGuard data plane opens config-sync gRPC to
   `trustguard-configsync.neuraltrust.ai:443`.
3. Enrolled DataAgent opens gRPC to `databridge.neuraltrust.ai:443`.
4. AgentGateway and TrustGuard send product events as plain OTLP to the local
   `clickstack-egress-collector`, which forwards to
   `https://telemetry.neuraltrust.ai` after exchanging the DataAgent
   enrolment JWT for a short-lived OTLP access token.

There is no in-cluster `clickstack-otel-collector` product collector in hybrid
(that subchart is external-mode only). The hybrid egress sidecar is co-located
with DataAgent and is not an operator-facing collector.

Hybrid config-sync is **on by default** (mode-derived; subchart
`configSync.enabled: null`). Pre-create the two named Secrets below with
independently issued SaaS bearer tokens under `CONFIG_SYNC_TOKEN` and separate
base64-encoded 32-byte cache encryption keys under `CONFIG_SYNC_LKG_KEY`.
Overlays set `existingSecret` only — do not restate `enabled: true`:

```yaml
agentgateway:
  configSync:
    existingSecret:
      name: "agentgateway-config-sync"

trustguard:
  configSync:
    existingSecret:
      name: "trustguard-config-sync"
```

In external mode, each reference is also injected into that component's local
control plane so the gRPC server and data-plane clients authenticate with the
same token.

Each data plane initiates a long-lived bidirectional gRPC stream, fetches a
compiled snapshot, stores it in memory, and acknowledges applied versions. The
encrypted last-known-good snapshot lets it serve during a temporary SaaS
outage. Config-sync replaces PostgreSQL as the runtime **configuration source**;
the shared hybrid PostgreSQL remains the raw product-data store used by the
Postgres telemetry exporters and DataAgent. AgentGateway calls TrustGuard over
the in-cluster `trustguard-data-plane` Service; that hop does not leave the
cluster.

Set `configSync.enabled: false` only when runtime configuration is populated
and managed in PostgreSQL out of band. The hybrid chart does not deploy local
AgentGateway or TrustGuard control planes to do that.

DataAgent enrolment is required for hybrid OTLP egress (and for DataBridge).
Prefer `enrolment.existingSecret` so the token never enters Helm values
(same ritual as `configSync.existingSecret`):

```yaml
dataagent:
  tenantId: "<tenant-id>"
  enrolment:
    existingSecret:
      name: "dataagent-enrolment"
```

DataAgent renders only when both values are present. It opens an outbound-only
gRPC connection to `databridge.neuraltrust.ai:443`; SaaS sends typed,
entitlement-scoped query requests over that channel and DataAgent reads the
shared local PostgreSQL and streams back only the permitted rows. It has no
Ingress or public Service. The co-located egress collector uses the same
enrolment for ClickStack OTLP — DataAgent is not itself the ClickStack
transport, but enrolment is shared.

### Hybrid ClickStack OTLP (mandatory)

The v2 hybrid ClickStack export is **always on**. Apps send plain OTLP to a
local ClusterIP Service (`clickstack-egress-collector`) on the DataAgent pod.
The sidecar exchanges the DataAgent enrolment JWT at DataCore for a short-lived
OTLP access token and forwards to SaaS. There is **no** direct SaaS bearer on
AgentGateway/TrustGuard and **no** hybrid opt-out:

- `global.clickstack.enabled: false` — rejected
- `global.clickstack.egress.enabled` — rejected

Air-gapped or local-only product telemetry requires
`global.deploymentMode: external` (in-cluster ClickStack collector + ClickHouse).

Optional `global.clickstack.endpoint` / `protocol` / `insecure` and
`global.clickstack.egress.*` knobs override only the egress sidecar's SaaS
export target; leave empty for the fixed defaults. External mode always exports
to its in-cluster ClickStack collector and ignores the hybrid egress path.

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
profiles that target
`http://clickstack-collector.<ns>.svc.cluster.local:4318/v1/logs` (product
events are OTLP logs; apps use `WithEndpointURL`, which requires the `/v1/logs`
path) and authenticate with `OTEL_EXPORTER_OTLP_HEADERS` from
`clickstack-collector-secrets` (same token as `OTLP_AUTH_TOKEN`). TrustGuard
runtime traces/metrics use separate `OPENTELEMETRY_*_ENDPOINT` host:port values.
The collector writes signals to the `otel` ClickHouse database.
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
| DataAgent | required (enrolment) | no | Outbound entitled-query bridge; enrolment also powers ClickStack egress |
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
`redis.host` (and `password`/`iamAuth`, etc.) there to match the shared Redis
when `global.redis.deploy=false` (and any per-service `*.redis` overlays).
Pooling and batching default to 100 connections and 200 keys per MGET;
`maxConnections`, `mgetChunkSize`, and the optional connect/socket/health-check
timeout values under `api.redis` override them.

To use managed datastores, disable each in-cluster component and configure
service-specific endpoints:

```yaml
global:
  postgresql:
    deploy: false
  redis:
    deploy: false

infrastructure:
  clickhouse:
    deploy: false
```

See `values-v2-managed-datastores.yaml.example`. External PostgreSQL roles and
databases must be pre-created.

## Observability collectors

Do not confuse the collectors:

- The umbrella OTel Collector (`global.observability.enabled`) is portable
  cluster observability and can optionally export to NeuralTrust.
- Hybrid product OTLP uses the DataAgent-co-located `clickstack-egress-collector`
  (mandatory; enrolment-backed). There is no hybrid opt-out.
- The ClickStack OTel Collector is an external-mode application component that
  lands self-hosted product telemetry in ClickHouse.

Disabling hosted export does not disable the external-mode ClickStack pipeline.

## AgentGateway public routing (exact + optional wildcards)

AgentGateway exposes three public surfaces: **admin** (external mode only),
**proxy**, and **MCP**. With `config.gatewayDiscoveryMode: subdomain` and empty
base domains, the chart sets `GATEWAY_BASE_DOMAIN=llm.<global.domain>` and
`MCP_BASE_DOMAIN=mcp.<global.domain>`. When `additionalHosts` is also empty,
Ingress/Routes auto-add `*.llm.<domain>` / `*.mcp.<domain>`. Explicit
`additionalHosts` (and explicit `gatewayBaseDomain` / `mcpBaseDomain`) remain
authoritative when set:

```yaml
agentgateway:
  config:
    gatewayDiscoveryMode: "subdomain"
  ingress:
    resourceType: "auto" # Ingress on AWS/Azure/GCP; OpenShift Routes by default
```

Helm only renders routing objects. DNS, certificates, and cloud controller
settings remain operator prerequisites:

| Provider | Routing resource | Operator prerequisites |
|---|---|---|
| AWS (ALB) | `networking.k8s.io/v1` Ingress | ALB accepts `*.llm.<domain>` / `*.mcp.<domain>`; ACM certificate SANs and wildcard DNS records must cover them |
| Azure (AGIC) | Ingress | AGIC **1.5.1+** / Application Gateway **v2** with a wildcard-capable certificate and DNS |
| GCP (GCE Ingress) | Ingress | Wildcard Ingress rules are supported; **Google-managed certificates do not support wildcard names** — provide a self-managed wildcard TLS Secret |
| OpenShift | native `Route` (`resourceType: auto\|route`) | IngressController `routeAdmission.wildcardPolicy: WildcardsAllowed`; router/Route certificate covering the wildcard domains. Set `ingress.resourceType: ingress` to keep Kubernetes Ingress instead |

Admin stays exact-host only (no wildcards). Pair public wildcards with
`config.gatewayDiscoveryMode: subdomain` so the application resolves dynamic
slugs; ingress rules alone do not enable discovery.

See `values-agentgateway-wildcard.yaml.example`.

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
- `values-agentgateway-wildcard.yaml.example`: proxy/MCP exact + wildcard hosts
