# Secrets Management Guide

How secrets are created, stored, and managed across the NeuralTrust Platform chart.

## Quick start

### Auto-generated secrets (default — recommended)

No action required. Deploy and all secrets are created automatically:

```bash
helm upgrade --install neuraltrust-platform . --namespace neuraltrust --create-namespace
```

| Secret | Kubernetes Secret | Key |
|---|---|---|
| TrustGate server key | `trustgate-secrets` | `SERVER_SECRET_KEY` |
| TrustGate DB password | `trustgate-secrets` | `DATABASE_PASSWORD` |
| Control Plane JWT | `control-plane-secrets` | `CONTROL_PLANE_JWT_SECRET` |
| TrustGate JWT (synced) | `control-plane-secrets` | `TRUSTGATE_JWT_SECRET` |
| Data Plane JWT | `data-plane-jwt-secret` | `DATA_PLANE_JWT_SECRET` |
| PostgreSQL password | `postgresql-secrets` | `POSTGRES_PASSWORD` |

> `SERVER_SECRET_KEY` (TrustGate) and `TRUSTGATE_JWT_SECRET` (Control Plane) are always synchronized to the same value.

**How it works:**

1. On first install, random 64-character alphanumeric values are generated
2. On `helm upgrade`, existing values are read from the cluster via `lookup` and reused
3. Explicit (non-empty) values in your values file always take priority

> **Deploy methods without `lookup`.** `lookup` returns nothing during `helm template`,
> `--dry-run`, ArgoCD/Flux renders, or when the deploy identity lacks RBAC to read Secrets.
> In those flows step 2 cannot preserve a generated value, so a fresh random value would
> overwrite the live Secret each upgrade. Generated secrets carry `helm.sh/resource-policy: keep`
> and the ClickHouse secret skips emission on upgrade when no value is resolvable, which avoids
> clobbering existing Secrets; for a guaranteed-stable result, install once and then set
> `global.preserveExistingSecrets: true` (or supply explicit values / `existingSecret`).

**Override a specific secret:**

```yaml
trustgate:
  global:
    env:
      SERVER_SECRET_KEY: "my-explicit-key"
```

### Pre-create secrets with the script

For environments that require secrets before deployment:

```bash
# Interactive
./create-secrets.sh --namespace neuraltrust

# With environment variables
export DATA_PLANE_JWT_SECRET="your-secret"
export CONTROL_PLANE_JWT_SECRET="your-secret"
./create-secrets.sh --namespace neuraltrust

# Script options
./create-secrets.sh --replace-existing      # replace without asking
./create-secrets.sh --no-replace-existing   # skip existing without asking
```

### Pre-existing secrets (external management)

For Vault, Sealed Secrets, or External Secrets Operator:

```yaml
global:
  autoGenerateSecrets: false
  preserveExistingSecrets: true   # Helm will NOT create or update secrets
```

All required secrets must exist in the namespace before deployment.

## Secret reference

### Data Plane

| Kubernetes Secret | Key | Required | Description |
|---|---|---|---|
| `data-plane-jwt-secret` | `DATA_PLANE_JWT_SECRET` | Auto-generated | JWT for Data Plane API auth |
| `data-plane-jwt-secret` | `REDIS_URL` | Auto-generated (v2 only) | Evaluation-progress cache. v1 uses Kafka instead (no key). v2 defaults to the in-cluster shared Redis; regenerated from `neuraltrust-data-plane.dataPlane.components.api.redis.*` on every render, so pre-provisioned/`preserveExistingSecrets` setups must set this key themselves when pointing at external/ACL/IAM Redis. |
| `openai-secrets` | `OPENAI_API_KEY` | No | OpenAI API key |
| `google-secrets` | `GOOGLE_API_KEY` | No | Google API key |
| `resend-secrets` | `RESEND_API_KEY` | No | Resend email API key |
| `huggingface-secrets` | `HUGGINGFACE_TOKEN` | No | Not needed to run the data-plane (image bundles fastText). Only forwarded to evaluation Jobs that use HF-gated models. |

### Control Plane

| Kubernetes Secret | Key | Required | Description |
|---|---|---|---|
| `control-plane-secrets` | `CONTROL_PLANE_JWT_SECRET` | Auto-generated | JWT for Control Plane API auth |
| `control-plane-secrets` | `TRUSTGATE_JWT_SECRET` | Auto-generated | Synced with `SERVER_SECRET_KEY` |
| `control-plane-secrets` | `FIREWALL_JWT_SECRET` | No | JWT for firewall service |
| `control-plane-secrets` | `FIREWALL_API_URL` | Auto-populated | Firewall base URL (FQDN when firewall enabled, data-plane fallback otherwise) |
| `control-plane-secrets` | `MODEL_SCANNER_SECRET` | No | Model scanner service secret |
| `control-plane-secrets` | `OPENAI_API_KEY` | No | OpenAI API key |
| `control-plane-secrets` | `resend-api-key` | No | Resend API key |
| `control-plane-secrets` | `resend-alert-sender` | No | Alert notification email |
| `control-plane-secrets` | `resend-invite-sender` | No | Invitation email |

### PostgreSQL

| Kubernetes Secret | Key | Required | Description |
|---|---|---|---|
| `postgresql-secrets` | `POSTGRES_HOST` | Yes (if pre-generating) | Database hostname |
| `postgresql-secrets` | `POSTGRES_PORT` | Yes (if pre-generating) | Database port |
| `postgresql-secrets` | `POSTGRES_USER` | Yes (if pre-generating) | Database username |
| `postgresql-secrets` | `POSTGRES_PASSWORD` | Auto-generated (password mode) | Database password. Empty when `controlPlane.components.postgresql.authMode: iam`. |
| `postgresql-secrets` | `POSTGRES_DB` | Yes (if pre-generating) | Database name |
| `postgresql-secrets` | `DATABASE_AUTH_MODE` | No | `password` (default) or `iam`. IAM is only honored for external Postgres (`global.postgresql.deploy: false`). |
| `postgresql-secrets` | `DATABASE_IAM_AUTH` | No | `"true"`/`"false"` mirror of the auth mode, read by api/app/scheduler. |
| `postgresql-secrets` | `DATABASE_URL` | Yes (if pre-generating) | Connection URL (URL-encoded). Password-less when `authMode: iam`. |
| `postgresql-secrets` | `POSTGRES_PRISMA_URL` | Yes (if pre-generating) | Prisma-compatible URL. Password-less when `authMode: iam`. |

> **IAM auth for Control-Plane Postgres (chart plumbing).** Setting
> `neuraltrust-control-plane.controlPlane.components.postgresql.authMode: iam`
> makes the chart emit a password-less `DATABASE_URL`/`POSTGRES_PRISMA_URL` and
> the `DATABASE_AUTH_MODE`/`DATABASE_IAM_AUTH` flags, and stops generating
> `POSTGRES_PASSWORD`. The api/app/scheduler must run an **IAM-capable image**
> that mints an RDS SigV4 token at connect time, with `global.irsa` providing the
> role. Until the images support it, leave `authMode: password` (default). IAM is
> ignored for the bundled in-cluster PostgreSQL — it always uses a password.

### Infrastructure

| Kubernetes Secret | Key | Required | Description |
|---|---|---|---|
| `clickhouse` | `admin-password` | Auto-generated | ClickHouse admin password |
| `kafka-credentials` | `username`, `password` | External Kafka + SASL only | Pre-created; referenced by `global.kafka.auth.existingSecret` (default key names). Chart never renders this Secret. |
| `kafka-broker-ca` | `ca.crt` | External Kafka + TLS only | Broker CA bundle; referenced by `global.kafka.tls.existingSecret`. Chart never renders this Secret. |
| ~~`kafka-connect-monitor-secrets`~~ | ~~`SLACK_WEBHOOK_URL`~~ | Removed in chart v1.13.0 | Use the `neuraltrust-watchdog` subchart instead — set `neuraltrust-watchdog.actions.slack.existingSecret` (and `secretKey`) to a pre-created Secret you control, OR set `actions.slack.webhookUrl` inline and the chart will render a managed Secret. The standalone `kafka-connect-monitor-secrets` Secret is no longer rendered. |

> **External Kafka credentials.** When `infrastructure.kafka.deploy: false` and `global.kafka.auth.enabled: true`, create `kafka-credentials` (or your chosen name matching `global.kafka.auth.existingSecret`) before `helm install`. For TLS, create `kafka-broker-ca` with key `ca.crt` (or match `global.kafka.tls.{existingSecret,caKey}`). Use `./create-secrets.sh` with `KAFKA_USERNAME`, `KAFKA_PASSWORD`, and optional `KAFKA_BROKER_CA_FILE`, or the `kubectl` commands in [`values-external-services.yaml.example`](./values-external-services.yaml.example).
>
> **`global.customCaCert` is not Kafka TLS.** It mounts a corporate CA bundle for HTTP/TLS egress (LLM APIs, etc.). In-cluster Kafka stays PLAINTEXT on `kafka:9092` unless you explicitly set `global.kafka.tls.enabled: true`.

### Observability (chart v1.13.0+)

Created only when explicitly enabled. None are auto-generated — operators bring their own values.

| Kubernetes Secret | Key | Required | Description |
|---|---|---|---|
| `neuraltrust-observability-token` | `token` | When `neuraltrust-watchdog.enabled: true` or `global.observability.enabled: true` with hosted export | Bearer token for `collector.neuraltrust.ai`. **Never auto-generated randomly.** Supply via `global.observability.hostedExport.auth.tokenValue`, pre-create with `./create-secrets.sh` (`OBSERVABILITY_TOKEN` env), or let Helm preserve an existing Secret via `lookup` on upgrade. Without it, hosted OTLP export is omitted and `watchdog_otlp_connectivity{*}==0`. |
| `<your-name>` (caller-controlled) | `webhook` | Only when `neuraltrust-watchdog.actions.slack.existingSecret` is set | Slack webhook URL for watchdog notifications. The chart never logs the URL. Set `neuraltrust-watchdog.actions.slack.existingSecret` to this Secret's name and `secretKey` to the data key (default `webhook`). Alternatively, set `actions.slack.webhookUrl` inline and the chart renders a managed Secret for you. |
| `<your-name>` (caller-controlled) | `token` | Only when `neuraltrust-watchdog.server.authToken.existingSecret` is set | Bearer token guarding the watchdog `POST /checks/{id}/run` force-run endpoint. Optional — the read-only endpoints (`/healthz`, `/readyz`, `/metrics`, `/checks`) stay unauthenticated. The chart can render a Secret from `server.authToken.value` instead. |

### TrustGate

| Kubernetes Secret | Key | Required | Description |
|---|---|---|---|
| `trustgate-secrets` | `SERVER_SECRET_KEY` | Auto-generated | Server secret key |
| `trustgate-secrets` | `DATABASE_HOST` | No | PostgreSQL host (external DB) |
| `trustgate-secrets` | `DATABASE_PORT` | No | PostgreSQL port (external DB) |
| `trustgate-secrets` | `DATABASE_USER` | No | PostgreSQL user (external DB) |
| `trustgate-secrets` | `DATABASE_PASSWORD` | Auto-generated (password mode) | PostgreSQL password. Empty when `DATABASE_AUTH_MODE: iam`. |
| `trustgate-secrets` | `DATABASE_NAME` | No | PostgreSQL database (external DB) |
| `trustgate-secrets` | `DATABASE_URL` | No | Connection URL (external DB). Password-less when `DATABASE_AUTH_MODE: iam`. |
| `trustgate-secrets` | `DATABASE_AUTH_MODE` | No | `password` (default) or `iam` (AWS RDS IAM auth). |
| `trustgate-secrets` | `DATABASE_IAM_AUTH` | No | `"true"`/`"false"` mirror of the auth mode, for the app. |
| `trustgate-secrets` | `redis-password` | No | External Redis password. Sourced from `trustgate.global.env.REDIS_PASSWORD` / `redis.external.password`. **Lives only in this Secret — no longer in the `trustgate-env-vars` ConfigMap.** |
| `trustgate-secrets` | `NEURAL_TRUST_FIREWALL_URL` | No | Firewall base URL |
| `trustgate-secrets` | `NEURAL_TRUST_FIREWALL_SECRET_KEY` | No | Firewall API key |

To use a pre-created Secret **only for TrustGate PostgreSQL** while the chart
generates the rest, keep `global.autoGenerateSecrets: true` and
`global.preserveExistingSecrets: false`, then point TrustGate at that Secret:

```yaml
trustgate:
  postgresql:
    existingSecret: "trustgate-postgres"
    existingSecretKeys:
      host: DATABASE_HOST
      port: DATABASE_PORT
      user: DATABASE_USER
      password: DATABASE_PASSWORD
      database: DATABASE_NAME
      sslMode: DATABASE_SSL_MODE
      authMode: DATABASE_AUTH_MODE
```

The parent chart reads those keys and renders the canonical `trustgate-secrets`
used by TrustGate pods. `SERVER_SECRET_KEY`, `NEURAL_TRUST_FIREWALL_URL`,
`NEURAL_TRUST_FIREWALL_SECRET_KEY`, and optional `redis-password` continue to be
resolved/generated by the chart. When a configured key exists in the referenced
PostgreSQL Secret, it wins over the `trustgate.global.env.DATABASE_*` defaults,
so database credentials do not need to be stored inline in values files. Do **not** set
`global.preserveExistingSecrets: true` for this mixed mode; that skips all
parent-chart Secret rendering.

> **Upgrade note (Redis password moved ConfigMap → Secret).** The TrustGate
> Redis password is no longer emitted into the `trustgate-env-vars` ConfigMap; it
> is read only from `trustgate-secrets` key `redis-password` (env `REDIS_PASSWORD`,
> `optional: true`). With `global.autoGenerateSecrets: true` the chart writes the
> key for you on upgrade. With `global.preserveExistingSecrets: true` you manage
> `trustgate-secrets` yourself — **add a `redis-password` key** before upgrading,
> otherwise `REDIS_PASSWORD` resolves empty and Redis auth fails at runtime.

### Firewall

Created when `neuraltrust-firewall.firewall.enabled: true`:

| Kubernetes Secret | Key | Required | Description |
|---|---|---|---|
| `firewall-secrets` | `JWT_SECRET` | Yes | Shared with services calling the firewall |
| `firewall-secrets` | `HUGGINGFACE_TOKEN` | No | Not needed for official images (models are baked in at build time). Only for custom runtime-download builds. |

Align `controlPlane.secrets.firewallJwtSecret` (`FIREWALL_JWT_SECRET`) with `firewall-secrets` `JWT_SECRET` when the Control Plane validates firewall tokens.

### Docker registry

| Kubernetes Secret | Type | Required | Description |
|---|---|---|---|
| `gcr-secret` | `docker-registry` | Yes | Credentials for NeuralTrust container images |

## TrustGate firewall integration

TrustGate calls the NeuralTrust Firewall using two keys stored in `trustgate-secrets`. With `global.autoGenerateSecrets: true` and `neuraltrust-firewall.firewall.enabled: true` (default), both are auto-populated to the in-cluster firewall Service:

```
NEURAL_TRUST_FIREWALL_URL        = http://firewall.<release-namespace>.svc.cluster.local
NEURAL_TRUST_FIREWALL_SECRET_KEY = <auto-generated, shared with firewall-secrets/JWT_SECRET>
```

To point TrustGate at a cross-namespace or external firewall, override explicitly:

```yaml
trustgate:
  global:
    env:
      NEURAL_TRUST_FIREWALL_URL: "http://firewall.shared-ns.svc.cluster.local"
      NEURAL_TRUST_FIREWALL_SECRET_KEY: "your-secret-key"
```

| Kubernetes Secret | Key | Required |
|---|---|---|
| `trustgate-secrets` | `NEURAL_TRUST_FIREWALL_URL` | No — auto-populated when firewall enabled; omit to disable firewall calls |
| `trustgate-secrets` | `NEURAL_TRUST_FIREWALL_SECRET_KEY` | No — auto-populated when firewall enabled; omit if not using secret-key auth |

With `global.autoGenerateSecrets: true`, these are merged into `trustgate-secrets` from `trustgate.global.env`. With `global.preserveExistingSecrets: true`, add them to a pre-created `trustgate-secrets`.

The Control Plane app's `FIREWALL_API_URL` follows the same auto-derivation rules from `control-plane-secrets/FIREWALL_API_URL`.

After changing firewall secrets, **restart TrustGate** so pods pick up the new values:

```bash
kubectl rollout restart deployment/trustgate-control-plane -n neuraltrust
kubectl rollout restart deployment/trustgate-data-plane -n neuraltrust
kubectl rollout restart deployment/trustgate-actions -n neuraltrust
```

## Secret reference in values

### Direct value (less secure)

```yaml
neuraltrust-data-plane:
  dataPlane:
    secrets:
      dataPlaneJWTSecret: "your-secret-value"
```

### Secret reference (recommended)

```yaml
neuraltrust-data-plane:
  dataPlane:
    secrets:
      dataPlaneJWTSecret:
        secretName: "data-plane-jwt-secret"
        secretKey: "DATA_PLANE_JWT_SECRET"
```

## Environment variables for the script

All secrets can be provided via environment variables:

```bash
# Data Plane
export DATA_PLANE_JWT_SECRET="your-secret"
export DATA_PLANE_REDIS_URL="redis://user:pass@host:6379/0"  # optional; platform-v2 only, requires global.preserveExistingSecrets=true
export OPENAI_API_KEY="sk-..."
export GOOGLE_API_KEY="your-key"
export RESEND_API_KEY="your-key"
export HUGGINGFACE_TOKEN="your-token"

# Control Plane
export CONTROL_PLANE_JWT_SECRET="your-secret"
export TRUSTGATE_JWT_SECRET="your-secret"
export FIREWALL_JWT_SECRET="your-secret"
export MODEL_SCANNER_SECRET="your-secret"

# Infrastructure
export CLICKHOUSE_PASSWORD="your-password"
export POSTGRES_HOST="postgres.example.com"
export POSTGRES_PORT="5432"
export POSTGRES_USER="postgres"
export POSTGRES_PASSWORD="your-password"
export POSTGRES_DB="neuraltrust"

# External Kafka (when infrastructure.kafka.deploy=false and global.kafka.auth/tls enabled)
export KAFKA_USERNAME="neuraltrust"
export KAFKA_PASSWORD="your-kafka-password"
export KAFKA_BROKER_CA_FILE="/path/to/broker-ca-bundle.pem"  # optional; creates kafka-broker-ca
export KAFKA_CREDENTIALS_SECRET_NAME="kafka-credentials"     # optional override
export KAFKA_BROKER_CA_SECRET_NAME="kafka-broker-ca"          # optional override

# TrustGate
export SERVER_SECRET_KEY="your-secret"

# Hosted observability (collector-less watchdog / hosted OTLP export)
export OBSERVABILITY_TOKEN="your-customer-token"

./create-secrets.sh --namespace neuraltrust
```

## Platform v2 secrets (`global.platformVersion=v2`)

The v2 services follow the same auto-generate + `lookup`-preserve model. Under
`global.autoGenerateSecrets: true` the keys below are created on first install
and reused on upgrade. Env var names are what each binary reads (verified in
source); the `envFrom` mounts map secret keys directly to env vars.

| Secret | Kubernetes Secret | Key | Notes |
|---|---|---|---|
| AgentGateway server key | `agentgateway-secrets` | `SERVER_SECRET_KEY` | auto-generated |
| AgentGateway MCP STS signing | `agentgateway-secrets` | `STS_SIGNING_KEY` | auto-generated RSA PKCS#1 private key (RS256), lookup-preserved so MCP tokens survive upgrades; use `create-secrets.sh` to validate and pre-provision an explicit PEM/base64-PEM key |
| AgentGateway DB password | `agentgateway-secrets` | `DB_PASSWORD` | auto-generated (app reads `DB_PASSWORD`, not `DATABASE_PASSWORD`); **omitted when `agentgateway.database.iamAuth=true`** |
| AgentGateway raw-telemetry DSN | `agentgateway-secrets` | `SENSIBLE_PG_DSN` | **hybrid only** — assembled DSN into the shared `trustdata` DB (own `agentgateway` schema); consumed by the postgres raw exporter so DataAgent has data. Omitted in external / when `iamAuth=true` |
| TrustGuard admin JWT | `trustguard-secrets` | `ADMIN_JWT_SECRET` | auto-generated |
| TrustGuard token signing | `trustguard-secrets` | `TRUSTGUARD_TOKEN_SIGNING_SECRET` | auto-generated |
| TrustGuard Redis events | `trustguard-secrets` | `REDIS_EVENTS_SECRET` | auto-generated; authenticates cache pub/sub events |
| TrustGuard DB password | `trustguard-secrets` | `DB_PASSWORD` | auto-generated; **omitted when `trustguard.database.iamAuth=true`** |
| TrustGuard raw-telemetry DSN | `trustguard-secrets` | `SENSIBLE_PG_DSN` | **hybrid only** — assembled DSN into the shared `trustdata` DB (own `trustguard` schema); consumed by the postgres raw exporter so DataAgent has data. Omitted in external / when `iamAuth=true` |
| Shared TrustGuard client creds | `trustguard-client-credentials` | `CLIENT_ID` / `CLIENT_SECRET` | id defaults to `agentgateway-platform`; secret auto-generated (or `global.v2.trustguardClientSecret`). Injected into both AgentGateway (`TRUSTGUARD_CLIENT_ID`/`_SECRET`) and TrustGuard (`TRUSTGUARD_PLATFORM_CLIENT_ID`/`_SECRET`) so the pair matches. The prerelease `v2-trustguard-client-secret` values are copied during upgrade. |
| TrustLens JWT | `trustlens-secrets` | `JWT_SECRET` | auto-generated (only when `trustlens.enabled=true`) |
| TrustLens encryption keyset | `trustlens-secrets` | `ENCRYPTION_KEYSET` | auto-generated |
| TrustLens DB password | `trustlens-secrets` | `DATABASE_PASSWORD` | auto-generated |
| DataAgent DB password | `dataagent-secrets` | `DB_PASSWORD` | auto-generated (read-only `dataagent` role in `trustdata`; search_path spans both writer schemas) |
| DataAgent DB DSN | `dataagent-secrets` | `DATABASE_URL` | assembled from the `database` components (or `databaseUrl` override) |
| DataAgent enrolment token | `dataagent-secrets` or operator Secret | `ENROLMENT_TOKEN` (configurable key) | **never** auto-generated — SaaS-issued, from `enrolmentToken` or `enrolmentTokenExistingSecret` |
| AlertEngine DB password | `alertengine-secrets` | `DB_PASSWORD` | auto-generated (own `alertengine` DB; external only); **omitted when `alertengine.database.iamAuth=true`** |
| AlertEngine auth JWT | `alertengine-secrets` | `AUTH_JWT_SECRET` | auto-generated — must match the app BFF token signer for UI auth |
| AlertEngine encryption key | `alertengine-secrets` | `APP_ENCRYPTION_KEY` | auto-generated (AES-256-GCM for integration secrets) |
| DataCore / AlertEngine / clickstack / data-plane-api ClickHouse password | `clickhouse` | `admin-password` | **shared** — all read `CLICKHOUSE_PASSWORD` from the in-cluster `clickhouse` secret via `clickhouse.existingSecret` (`dataPlane.components.clickhouse.existingSecret` for the shim; no per-service key). External ClickHouse: point `existingSecret.name`/`key` at your secret. |
| Control-plane app auth | `control-plane-secrets` | `AUTH_SECRET` / `NEXTAUTH_SECRET` | one generated or reused value exposed under both aliases |

AlertEngine and TrustLens URLs are non-secret values wired directly into the
control-plane app Deployment, alongside the other backend service URLs. A live
v1-to-v2 migration must keep `global.confirmV2Migration: true` for its first v2
reconciliation so missing v2 Secrets/keys can be created; later upgrades reuse
them with `lookup`.

- **Postgres (`v2-postgres-init`)**: `control-plane-postgresql` deploys by default
  in all v2 modes; the Job's provisioning is **mode-derived**:
  - **hybrid** — ONE shared database `trustdata`. AgentGateway and TrustGuard each get
    their OWN schema (named after their role) with `search_path` defaulted there, from
    their `DB_PASSWORD` above, so their identically-named migration trackers
    (`migration_versions`) never collide. A read-only `dataagent` role (from
    `dataagent-secrets/DB_PASSWORD`) is granted SELECT on both schemas and its
    `search_path` spans them, so DataAgent's unqualified reads resolve.
  - **external** — each service gets its OWN database (`agentgateway`, `trustguard`)
    on `public`, since the control planes run on-prem and own their migrations;
    DataCore reads raw data from ClickHouse, so there is no shared Postgres reader.
    `trustlens` and `alertengine` keep their own databases when deployed (the init Job
    also provisions the `alertengine` role + DB in external mode).
- **In-cluster Redis** (`redis`) is passwordless by default; set
  `agentgateway.redis.password` / `trustguard.redis.password` (stored as
  `REDIS_PASSWORD`) for an authenticated external Redis. `REDIS_PASSWORD` is
  omitted when `redis.iamAuth=true`.
- **Shared ClickHouse credential**: DataCore, AlertEngine, `clickstack-otel-collector`
  and the `data-plane-api` shim read the ClickHouse password from the single
  `clickhouse` secret (key `admin-password`) — none store their own
  `CLICKHOUSE_PASSWORD`. Override per service with
  `datacore.clickhouse.existingSecret` / `alertengine.clickhouse.existingSecret` /
  `clickstack-otel-collector.clickhouse.existingSecret` /
  `neuraltrust-data-plane.dataPlane.components.clickhouse.existingSecret`. For
  external ClickHouse (`infrastructure.clickhouse.deploy=false`), point these at the
  secret matching `infrastructure.clickhouse.external.secretName`/`secretKey`, and set
  the ClickHouse host to your endpoint (a dotted/FQDN host is used verbatim; a bare
  name expands to `<name>.<namespace>.svc.cluster.local`).
- **`data-plane-api` PostgreSQL backend (v2 hybrid default)**: in hybrid the shim
  reads its evaluation store from PostgreSQL (`SQL_DATABASE=postgres`), so it needs
  no ClickHouse. It resolves its five `POSTGRES_*` connection vars from the
  umbrella-managed `postgresql-secrets` (keys `POSTGRES_HOST`/`POSTGRES_PORT`/
  `POSTGRES_USER`/`POSTGRES_PASSWORD`/`POSTGRES_DB`) by default — the password is
  ALWAYS a `secretKeyRef` (never inlined). For an EXTERNAL PostgreSQL, set the
  non-secret scalars under
  `neuraltrust-data-plane.dataPlane.components.api.database.postgresql.{host,port,user,database}`
  (they override the matching Secret key) and/or point `…database.postgresql.existingSecret.name`
  (with an optional `keys` map) at a pre-created Secret holding the password. A
  `postgres-migrations` initContainer applies the idempotent schema, so the
  configured role needs `CREATE SCHEMA`/`CREATE TABLE` on the target database.
  The ClickHouse credential below applies only when the shim is on ClickHouse
  (v2 external, or hybrid pinned to an external ClickHouse).
- **Optional IAM DB/Redis auth (AWS)**: the v2 Go services accept
  `database.iamAuth` / `redis.iamAuth` (default false). When on they emit
  `DB_IAM_AUTH`/`DB_AUTH_MODE`/`REDIS_IAM_AUTH` and ship no static password.
  AgentGateway and TrustGuard mint RDS tokens at connect time; Redis IAM and
  AlertEngine database IAM remain chart-prepared and require an IAM-capable
  service image. RDS IAM is also live for the Python control-plane
  (`controlPlane.components.postgresql.authMode: iam`). Use
  `values-v2-managed-datastores.yaml.example` as the tracked starting point.
- **DataAgent** requires operator-supplied `enrolmentToken` (SaaS-issued, never
  generated). Its `DATABASE_URL` and `DB_PASSWORD` auto-derive for in-cluster
  Postgres; overlay `dataagent.database.host` + `database.password` for external.
  Prefer `dataagent.enrolmentTokenExistingSecret` so the token never enters Helm
  values or release history. When chart secret generation is disabled, also set
  `dataagent.existingSecret.name` to a Secret containing `DATABASE_URL` and
  `DB_PASSWORD`.

## Using external secret management

Example with External Secrets Operator:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: data-plane-jwt-secret
  namespace: neuraltrust
spec:
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: data-plane-jwt-secret
  data:
    - secretKey: DATA_PLANE_JWT_SECRET
      remoteRef:
        key: neuraltrust/data-plane/jwt-secret
```

## Comparison: auto-generated vs pre-generated

| Feature | Auto-generated | Pre-generated |
|---|---|---|
| Setup effort | None — just deploy | Must create all secrets first |
| Secret creation | Helm creates automatically | User/CI creates before deploy |
| Upgrade behavior | Existing values preserved via `lookup` | Helm never touches secrets |
| Secret sync | `SERVER_SECRET_KEY` = `TRUSTGATE_JWT_SECRET` automatic | Manual — user must ensure consistency |
| Best for | Dev, staging, quick starts | Production with Vault/compliance |

## Security best practices

1. **Use auto-generated secrets for simplicity** — the default is the safest starting point
2. **Use external secret management for production** — Vault, Sealed Secrets, or External Secrets Operator
3. **Never commit secrets to git** — don't store real values in values files that are version-controlled
4. **Rotate secrets regularly** — especially JWT secrets
5. **Restrict access with RBAC** — limit who can read Kubernetes secrets

## Troubleshooting

### TrustGate firewall env vars not updating

TrustGate reads `NEURAL_TRUST_FIREWALL_URL` and `NEURAL_TRUST_FIREWALL_SECRET_KEY` from `trustgate-secrets`. After `helm upgrade`, restart TrustGate deployments to reload.

### Secret not found

```bash
kubectl get secret <secret-name> -n neuraltrust
kubectl get secrets -n neuraltrust
kubectl get secret <secret-name> -n neuraltrust -o yaml
```

### Wrong secret key

```bash
kubectl patch secret <secret-name> -n neuraltrust \
  --type='json' \
  -p='[{"op": "replace", "path": "/data/<key>", "value": "<base64-encoded-value>"}]'
```

### Secret format issues

When creating secrets manually:

- URL-encode passwords in `DATABASE_URL`
- Base64-encode all values in Kubernetes secrets
- Avoid trailing newlines or whitespace
