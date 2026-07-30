# Architecture

This is the topology contract: what each mode deploys, how the pieces talk to
each other, and which values govern them. It assumes you have already installed
the chart — for a first install, start with the
[hybrid quick start](../README.md#quick-start-hybrid) or
[README-EXTERNAL.md](../README-EXTERNAL.md).

One global value selects the topology:

```yaml
global:
  deploymentMode: "hybrid" # hybrid | external
```

## Hybrid: default split-plane

Hybrid keeps control-plane services hosted and deploys the data path in the
customer cluster:

- TrustGate proxy and MCP (K8s resources remain `agentgateway-*`)
- TrustGuard data plane
- PostgreSQL and Redis by default
- Firewall whenever TrustGuard is selected
- DataAgent (enrolment required for hybrid OTLP egress and DataBridge)

Hybrid does **not** deploy an in-cluster ClickHouse: analytics use the hosted
path. AgentGateway and TrustGuard **always dual-write** product data over OTLP
via a local `clickstack-egress-collector` (enrolment-backed; see
[hybrid ClickStack OTLP](#hybrid-clickstack-otlp-mandatory-when-trustgatetrustguard-on))
while ALSO
persisting raw payloads to the local PostgreSQL for DataAgent. `data-plane-api`
renders **by default** in hybrid and reads from the umbrella-managed
**PostgreSQL** (`SQL_DATABASE=postgres`), so no ClickHouse is required. Its
schema is applied by a `postgres-migrations` initContainer (idempotent,
advisory-locked). If you instead want it to read from an **external/managed
ClickHouse**, either set a dotted
`data-plane-api.dataPlane.components.clickhouse.host` (auto-resolves to
ClickHouse) or force it with
`data-plane-api.dataPlane.components.api.database.backend: clickhouse`.
The backend can also be pinned to `postgres` explicitly. In-cluster ClickHouse
deploys only in external mode.

### Hybrid control and data channels

Hybrid uses two config-sync channels, mandatory ClickStack OTLP (via the
DataAgent egress sidecar), and DataAgent DataBridge. Every connection is
initiated by the customer cluster over TLS:

1. AgentGateway proxy/MCP opens config-sync gRPC to
   `agentgateway-configsync.neuraltrust.ai:443`.
2. TrustGuard data plane opens config-sync gRPC to
   `trustguard-configsync.neuraltrust.ai:443`.
3. Enrolled DataAgent opens gRPC to `databridge.neuraltrust.ai:443`.
4. AgentGateway and TrustGuard send product events as plain OTLP to the local
   `clickstack-egress-collector`, which forwards to
   `https://telemetry.neuraltrust.ai` after exchanging the DataAgent
   enrolment JWT for a short-lived OTLP access token.

Firewall / security-group allowlist (hostnames, IPs, and the NeuralTrust
inbound source IP): [hybrid-network.md](./hybrid-network.md).

There is no in-cluster `clickstack-collector` product collector in hybrid — the
`clickstack-otel-collector` subchart is external-mode only. The hybrid egress
sidecar is co-located with DataAgent and is not an operator-facing collector.

Hybrid config-sync is **on by default** (mode-derived; subchart
`configSync.enabled: null`). Pre-create the two named Secrets below with
independently issued bearer tokens under `CONFIG_SYNC_TOKEN` and separate
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
encrypted last-known-good snapshot lets it serve during a temporary control-plane
outage. Config-sync replaces PostgreSQL as the runtime **configuration source**;
the shared hybrid PostgreSQL remains the raw product-data store used by the
Postgres telemetry exporters and DataAgent. TrustGate calls TrustGuard over
the in-cluster `trustguard-data-plane` Service when Guard is co-deployed; that
hop does not leave the cluster. TrustGate can run without Guard by selecting
only `global.products.trustgate`.

Set `configSync.enabled: false` only when runtime configuration is populated
and managed in PostgreSQL out of band. The hybrid chart does not deploy local
TrustGate or TrustGuard control planes to do that.

### Positive product selection (hybrid only)

Hybrid installs choose products with positive `global.products` flags.
Chart defaults are all `false`; validation fails if none are selected.
External mode ignores these flags and always deploys the full product stack.

| Slice | Flags | DataAgent |
|---|---|---|
| TrustGate | `global.products.trustgate: true` | `agentgateway.dataagent` (enrolment) |
| TrustGuard + Firewall | `global.products.trustguard: true` | `trustguard.dataagent` |
| Red teaming | `global.products.dataPlane: true` | none |

Overlay only the products you want — no all-off baseline file. Product
examples are positive-only deltas and combine in any `-f` order. Shared
Postgres/Redis stay under `global.postgresql` / `global.redis`. Tracked
examples: `values-trustgate.yaml.example`, `values-trustguard.yaml.example`,
`values-red-teaming.yaml.example`. `values-required.yaml` selects all three
for the full-hybrid preset.

### DataAgent (one per enabled product)

When TrustGate and/or TrustGuard are enabled, each needs its own DataAgent
enrolment (distinct tokens in production). The JWT carries `tenant_id` and
`instance_id` (gateway or guard id); do not duplicate them in values. Prefer
nested `enrolment.existingSecret` so the token never enters Helm values:

```yaml
agentgateway:
  dataagent:
    enrolment:
      existingSecret:
        name: "dataagent-enrolment-trustgate"

trustguard:
  dataagent:
    enrolment:
      existingSecret:
        name: "dataagent-enrolment-trustguard"
```

Top-level `dataagent` contains shared runtime defaults only. Product enrolment
lives under each product. data-plane-only hybrid skips DataAgent.

Each agent opens an outbound-only gRPC connection to
`databridge.neuraltrust.ai:443`. TrustGate preserves the existing `dataagent`
resource name; TrustGuard uses `dataagent-trustguard`. The selected primary
(TrustGate when enabled, otherwise TrustGuard) co-locates the
`clickstack-egress-collector` sidecar and owns that ClusterIP Service name.

### Hybrid ClickStack OTLP (mandatory when TrustGate/TrustGuard on)

When TrustGate or TrustGuard is enabled, hybrid ClickStack export is **always
on**. Apps send plain OTLP to a local ClusterIP Service
(`clickstack-egress-collector`) on the primary DataAgent pod.
The sidecar exchanges the DataAgent enrolment JWT for a short-lived OTLP access
token and exports to the hosted telemetry endpoint. There is **no** direct
bearer on TrustGate/TrustGuard and **no** hybrid opt-out:

- `global.clickstack.enabled: false` — rejected
- `global.clickstack.egress.enabled` — rejected

Air-gapped or local-only product telemetry requires
`global.deploymentMode: external` (in-cluster ClickStack collector + ClickHouse).

Optional `global.clickstack.endpoint` / `protocol` / `insecure` and
`global.clickstack.egress.*` knobs override only the egress sidecar's export
target; leave empty for the fixed defaults. External mode always exports to its
in-cluster ClickStack collector and ignores the hybrid egress path.

## External: self-hosted

External moves the control planes and product console into the cluster and adds
the self-hosted analytics stack:

- AgentGateway admin, proxy, and MCP
- TrustGuard control and data planes
- product control-plane API and web app
- ClickStack OTel Collector
- DataCore
- AlertEngine API and worker
- data-plane API

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
hosted telemetry egress.

## Components

In hybrid, "opt-in" means the product flag is `false` by default and you must set
it. External ignores the flags and deploys everything.

| Component | Hybrid | External | Purpose |
|---|:---:|:---:|---|
| TrustGate proxy/MCP (`agentgateway:`; product `global.products.trustgate`; K8s `agentgateway-*`) | opt-in | yes | AI gateway data path |
| TrustGate admin | hosted | yes | Gateway administration |
| TrustGuard data plane | opt-in | yes | Runtime safety evaluation |
| TrustGuard control plane | hosted | yes | Policy administration |
| data-plane API | opt-in (PostgreSQL) | yes (ClickHouse) | Analytics / evaluation API — PostgreSQL by default in hybrid, ClickHouse in external |
| DataAgent | one per enabled TrustGate/TrustGuard | no | Outbound entitled-query bridge; primary also powers ClickStack egress |
| ClickStack OTel Collector | no | yes | OTLP to ClickHouse |
| DataCore | no | yes | Residency query API (ClickHouse + Postgres metadata) |
| AlertEngine | no | yes | Alert evaluation and SIEM/integration forwarding |
| Firewall | with TrustGuard | with TrustGuard | Prompt and response safety |

## Cluster sizing

Chart defaults are a comfortable starting point. Hybrid (all products) typically
fits **3–4** workers at **8 vCPU / 16–32 GiB**; External typically wants
**4–5** of the same class. Right-size and fine-tune for your traffic — see
[sizing.md](./sizing.md).

## Datastores

PostgreSQL and Redis deploy in-cluster by default in both modes. ClickHouse
deploys in-cluster only in **external** — hybrid uses hosted analytics, so no
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

The chart renders two shared Kubernetes Secrets. Each stores **one canonical name
per fact** — no aliases:

- `postgresql-secrets` — `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_USER`,
  `POSTGRES_PASSWORD`, `POSTGRES_DB`, `POSTGRES_SSLMODE`, `POSTGRES_LOGIN`,
  `POSTGRES_AUTH_MODE`, `POSTGRES_CONNECTION_TYPE`, and `SENSIBLE_PG_DSN`.
  External mode adds `POSTGRES_PRISMA_URL`.
- `redis-secrets` — `REDIS_HOST`, `REDIS_PORT`, `REDIS_PASSWORD`, `REDIS_USERNAME`,
  `REDIS_TLS`.

Stored key names and the environment variables a container sees are deliberately
different. Workloads take `redis-secrets` wholesale with `envFrom`, but read
PostgreSQL through explicit `env` entries so each pod receives only the variables
it uses under the names its binary expects: the Go services get `DB_*`, and
DataAgent gets `DATABASE_URL` from `SENSIBLE_PG_DSN`. Effective values are
identical either way — all hybrid workloads connect as the single `neuraltrust`
role to the shared `neuraltrust` database. Do not expect `DB_*` or `DATABASE_URL`
to exist as keys inside the chart-managed Secret.

> **Supplying your own PostgreSQL Secret changes the contract.** Renaming is only
> safe for a Secret the chart writes. Set `global.postgresql.existingSecret.name`
> or `global.preserveExistingSecrets: true` and workloads fall back to `envFrom`
> on your Secret, injecting its keys verbatim as environment variables. Your keys
> must then be the names the applications read — `DB_HOST`, `DB_PORT`, `DB_USER`,
> `DB_PASSWORD`, `DB_NAME`, `DB_SSL_MODE`, and `SENSIBLE_PG_DSN` — not the
> `POSTGRES_*` family. This is the one case where `DB_*` keys are correct.

There is **no** chart-managed schema/role
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
`alertengine.database` overlays remain the source of truth for external mode —
`global.postgresql.*` is ignored there.

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

See `values-managed-datastores.yaml.example`. External PostgreSQL roles and
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

## AgentGateway public routing (exact + wildcards)

AgentGateway exposes three public surfaces: **admin** (external mode only),
**proxy**, and **MCP**. Discovery is always dual-mode in the app:

| Call path | Host | Gateway header |
|---|---|---|
| Exact primary | `gateway.<domain>` / `mcp.<domain>` | Required |
| Wildcard slug | `<slug>.llm.<domain>` / `<slug>.mcp.<domain>` | Not needed |

With empty base domains the chart sets `GATEWAY_BASE_DOMAIN=llm.<global.domain>`
and `MCP_BASE_DOMAIN=mcp.<global.domain>`. When `additionalHosts` is also empty
and `config.autoWildcardHosts` is true (default), Ingress/Routes auto-add
`*.llm.<domain>` / `*.mcp.<domain>`. Set `autoWildcardHosts: false` for exact
hosts only (no wildcard DNS/cert). Explicit `additionalHosts` (and explicit
`gatewayBaseDomain` / `mcpBaseDomain`) remain authoritative when set.
`config.gatewayDiscoveryMode` / `GATEWAY_DISCOVERY_MODE` are retired — do not
set them.

```yaml
agentgateway:
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

Admin stays exact-host only (no wildcards).

---

## Operator examples

| File | Purpose |
|---|---|
| [`values-required.yaml`](../values-required.yaml) | Full-hybrid preset used by the README quick start |
| [`values-hybrid-reference.yaml.example`](../values-hybrid-reference.yaml.example) | Annotated reference for every hybrid knob |
| [`values-hybrid.yaml.example`](../values-hybrid.yaml.example) | Hybrid overlay with managed datastores |
| [`values-external.yaml.example`](../values-external.yaml.example) | Minimal self-hosted external |
| [`values-managed-datastores.yaml.example`](../values-managed-datastores.yaml.example) | External with managed PostgreSQL, Redis, and ClickHouse |

Scenario walkthroughs: [VALUES_SCENARIOS.md](../VALUES_SCENARIOS.md).

---

<sup>**Looking for v1?** The legacy TrustGate/Kafka line ended at [v1.14.16](https://github.com/NeuralTrust/neuraltrust-platform/releases?page=3#release-v1.14.16) — install it with `--version ~1.14.0`.</sup>
