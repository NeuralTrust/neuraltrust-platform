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
| AgentGateway server key | `agentgateway-secrets` | `SERVER_SECRET_KEY` |
| Data Plane JWT | `data-plane-jwt-secret` | `DATA_PLANE_JWT_SECRET` |
| PostgreSQL password | `postgresql-secrets` | `POSTGRES_PASSWORD` |

**External mode only** (control-plane API/app — not rendered in hybrid):

| Secret | Kubernetes Secret | Key |
|---|---|---|
| Control Plane JWT | `control-plane-secrets` | `CONTROL_PLANE_JWT_SECRET` |
| Gateway integration JWT | `control-plane-secrets` | `TRUSTGATE_JWT_SECRET` |

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
agentgateway:
  secrets:
    serverSecretKey: "my-explicit-key"
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
| `data-plane-jwt-secret` | `REDIS_URL` | Auto-generated | Evaluation-progress cache. Defaults to the in-cluster shared Redis; regenerated from `data-plane-api.dataPlane.components.api.redis.*` on every render, so pre-provisioned/`preserveExistingSecrets` setups must set this key themselves when pointing at external/ACL/IAM Redis. |
| `openai-secrets` | `OPENAI_API_KEY` | No | OpenAI API key |
| `google-secrets` | `GOOGLE_API_KEY` | No | Google API key |
| `resend-secrets` | `RESEND_API_KEY` | No | Resend email API key |
| `huggingface-secrets` | `HUGGINGFACE_TOKEN` | No | Not needed to run the data-plane (image bundles fastText). Only forwarded to evaluation Jobs that use HF-gated models. |

### Control Plane (external mode only)

These Secrets apply when `global.deploymentMode: external` renders
control-plane-api/app. Hybrid keeps the console in NeuralTrust SaaS.

| Kubernetes Secret | Key | Required | Description |
|---|---|---|---|
| `control-plane-secrets` | `CONTROL_PLANE_JWT_SECRET` | Auto-generated | JWT for Control Plane API auth |
| `control-plane-secrets` | `TRUSTGATE_JWT_SECRET` | Auto-generated | Control-plane ↔ AgentGateway integration key |
| `control-plane-secrets` | `FIREWALL_JWT_SECRET` | No | JWT for firewall service |
| `control-plane-secrets` | `FIREWALL_API_URL` | Auto-populated | Firewall base URL (FQDN when firewall enabled, data-plane fallback otherwise) |
| `control-plane-secrets` | `MODEL_SCANNER_SECRET` | No | Model scanner service secret |
| `control-plane-secrets` | `OPENAI_API_KEY` | No | OpenAI API key |
| `control-plane-secrets` | `resend-api-key` | No | Resend API key |
| `control-plane-secrets` | `resend-alert-sender` | No | Alert notification email |
| `control-plane-secrets` | `resend-invite-sender` | No | Invitation email |

### PostgreSQL

> **Ownership.** Both the `control-plane-postgresql` Deployment/PVC/Service and the `postgresql-secrets` Secret are owned by the umbrella chart (`templates/postgresql/` — mirroring `templates/redis/`). The Kubernetes names, PVC identity, and the gating switch `global.postgresql.deploy` are stable so live clusters upgrade in place. `postgresql-secrets` is generated by `templates/platform-secrets.yaml` on the default auto-generate path and by `templates/postgresql/secrets.yaml` on the `autoGenerateSecrets: false` fallback path; the two are mutually exclusive by construction so the Secret is never rendered twice.

| Kubernetes Secret | Key | Required | Description |
|---|---|---|---|
| `postgresql-secrets` | `POSTGRES_HOST` | Yes (if pre-generating) | Database hostname |
| `postgresql-secrets` | `POSTGRES_PORT` | Yes (if pre-generating) | Database port |
| `postgresql-secrets` | `POSTGRES_USER` | Yes (if pre-generating) | Database username |
| `postgresql-secrets` | `POSTGRES_PASSWORD` | Auto-generated (password mode) | Database password. Empty when `controlPlane.components.postgresql.authMode: iam`. |
| `postgresql-secrets` | `POSTGRES_DB` | Yes (if pre-generating) | Database name |
| `postgresql-secrets` | `DATABASE_AUTH_MODE` | No | `password` (default) or `iam`. Chart-level flag; IAM is only honored for external Postgres (`global.postgresql.deploy: false`). |
| `postgresql-secrets` | `DATABASE_IAM_AUTH` | No | `"true"`/`"false"` mirror of the auth mode. |
| `postgresql-secrets` | `POSTGRES_AUTH_MODE` | No | Same as `DATABASE_AUTH_MODE`. Read by the Next.js app (`lib/db/postgresConfig.ts`). |
| `postgresql-secrets` | `POSTGRES_CONNECTION_TYPE` | No | `postgres` (password) or `aurora` (IAM). Read by the Python API (`src/database.py`). |
| `postgresql-secrets` | `DATABASE_URL` | Yes (if pre-generating) | Connection URL (URL-encoded). Password-less when `authMode: iam`. |
| `postgresql-secrets` | `POSTGRES_PRISMA_URL` | Yes (if pre-generating) | Prisma-compatible URL. Password-less when `authMode: iam` (init-db mints a token at migrate time). |

> **IAM auth for Control-Plane Postgres.** Setting
> `control-plane-api.controlPlane.components.postgresql.authMode: iam`
> (and/or `global.postgresql.authMode: iam`) makes the chart emit a password-less
> `DATABASE_URL`/`POSTGRES_PRISMA_URL`, the `DATABASE_*` / `POSTGRES_AUTH_MODE` /
> `POSTGRES_CONNECTION_TYPE` flags, and stops generating `POSTGRES_PASSWORD`.
> Set `awsRegion` (or `global.postgresql.awsRegion`) so Deployments get
> `AWS_REGION` for token minting. Requirements:
> - IRSA on the shared `control-plane` ServiceAccount (`rds-db:connect` for the
>   IAM DB user).
> - **control-plane-api** image with Aurora IAM support (`POSTGRES_CONNECTION_TYPE=aurora`).
> - **control-plane-app** image **v1.93.0+** (`POSTGRES_AUTH_MODE=iam` +
>   `scripts/postgres-iam-url.mjs` for Prisma migrate in the init container).
> Until those images are in use, leave `authMode: password` (default). IAM is
> ignored for the bundled in-cluster PostgreSQL — it always uses a password.

### Infrastructure

| Kubernetes Secret | Key | Required | Description |
|---|---|---|---|
| `clickhouse` | `admin-password` | Auto-generated | ClickHouse admin password (external mode) |

> **`global.customCaCert`.** Mounts a corporate CA bundle for HTTP/TLS egress (LLM APIs, etc.).

### Observability

Created only when explicitly enabled. None are auto-generated — operators bring their own values.

| Kubernetes Secret | Key | Required | Description |
|---|---|---|---|
| `neuraltrust-observability-token` | `token` | When `watchdog.enabled: true` or `global.observability.enabled: true` with hosted export | Bearer token for `collector.neuraltrust.ai`. **Never auto-generated randomly.** Supply via `global.observability.hostedExport.auth.tokenValue`, pre-create with `./create-secrets.sh` (`OBSERVABILITY_TOKEN` env), or let Helm preserve an existing Secret via `lookup` on upgrade. Without it, hosted OTLP export is omitted and `watchdog_otlp_connectivity{*}==0`. |
| `<your-name>` (caller-controlled) | `webhook` | Only when `watchdog.actions.slack.existingSecret` is set | Slack webhook URL for watchdog notifications. The chart never logs the URL. Set `watchdog.actions.slack.existingSecret` to this Secret's name and `secretKey` to the data key (default `webhook`). Alternatively, set `actions.slack.webhookUrl` inline and the chart renders a managed Secret for you. |
| `<your-name>` (caller-controlled) | `token` | Only when `watchdog.server.authToken.existingSecret` is set | Bearer token guarding the watchdog `POST /checks/{id}/run` force-run endpoint. Optional — the read-only endpoints (`/healthz`, `/readyz`, `/metrics`, `/checks`) stay unauthenticated. The chart can render a Secret from `server.authToken.value` instead. |

### Firewall

Created when `firewall.firewall.enabled: true`:

| Kubernetes Secret | Key | Required | Description |
|---|---|---|---|
| `firewall-secrets` | `JWT_SECRET` | Yes | Shared with services calling the firewall |
| `firewall-secrets` | `HUGGINGFACE_TOKEN` | No | Not needed for official images (models are baked in at build time). Only for custom runtime-download builds. |

Align `controlPlane.secrets.firewallJwtSecret` (`FIREWALL_JWT_SECRET`) with `firewall-secrets` `JWT_SECRET` when the Control Plane validates firewall tokens.

### Docker registry

| Kubernetes Secret | Type | Required | Description |
|---|---|---|---|
| `gcr-secret` | `docker-registry` | Yes | Credentials for NeuralTrust container images |

## Firewall integration

The Control Plane app's `FIREWALL_API_URL` auto-derives from
`control-plane-secrets/FIREWALL_API_URL` to the in-cluster firewall Service when
`firewall.firewall.enabled: true`, falling back to the data-plane otherwise. Align
`control-plane-api.controlPlane.secrets.firewallJwtSecret` (`FIREWALL_JWT_SECRET`)
with `firewall-secrets` `JWT_SECRET` when the Control Plane validates firewall tokens.

## Secret reference in values

### Direct value (less secure)

```yaml
data-plane-api:
  dataPlane:
    secrets:
      dataPlaneJWTSecret: "your-secret-value"
```

### Secret reference (recommended)

```yaml
data-plane-api:
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
export TRUSTGATE_JWT_SECRET="your-secret"   # control-plane ↔ gateway integration key
export FIREWALL_JWT_SECRET="your-secret"
export MODEL_SCANNER_SECRET="your-secret"

# Infrastructure
export CLICKHOUSE_PASSWORD="your-password"
export POSTGRES_HOST="postgres.example.com"
export POSTGRES_PORT="5432"
export POSTGRES_USER="postgres"
export POSTGRES_PASSWORD="your-password"
export POSTGRES_DB="neuraltrust"

# Hosted observability (collector-less watchdog / hosted OTLP export)
export OBSERVABILITY_TOKEN="your-customer-token"

./create-secrets.sh --namespace neuraltrust
```

## Platform v2 secrets

The v2 services follow the same auto-generate + `lookup`-preserve model. Under
`global.autoGenerateSecrets: true` the keys below are created on first install
and reused on upgrade. Env var names are what each binary reads (verified in
source); the `envFrom` mounts map secret keys directly to env vars.

| Secret | Kubernetes Secret | Key | Notes |
|---|---|---|---|
| AgentGateway server key | `agentgateway-secrets` | `SERVER_SECRET_KEY` | auto-generated |
| AgentGateway MCP STS signing | `agentgateway-secrets` | `STS_SIGNING_KEY` | auto-generated RSA PKCS#1 private key (RS256), lookup-preserved so MCP tokens survive upgrades; use `create-secrets.sh` to validate and pre-provision an explicit PEM/base64-PEM key |
| AgentGateway DB password | `agentgateway-secrets` | `DB_PASSWORD` | **v2 external only** — auto-generated (app reads `DB_PASSWORD`, not `DATABASE_PASSWORD`); **omitted when `agentgateway.database.iamAuth=true`**. In v2 **hybrid** the password comes from the shared `postgresql-secrets` (see below). |
| AgentGateway raw-telemetry DSN | `agentgateway-secrets` | `SENSIBLE_PG_DSN` | **v2 external only** (assembled DSN when the raw exporter is enabled). In v2 **hybrid** it lives in `postgresql-secrets`. |
| TrustGuard admin JWT | `trustguard-secrets` | `ADMIN_JWT_SECRET` | auto-generated |
| TrustGuard token signing | `trustguard-secrets` | `TRUSTGUARD_TOKEN_SIGNING_SECRET` | auto-generated |
| TrustGuard Redis events | `trustguard-secrets` | `REDIS_EVENTS_SECRET` | auto-generated; authenticates cache pub/sub events |
| TrustGuard Firewall client | `firewall-secrets` (mounted as env) | `JWT_SECRET` → `NEURAL_TRUST_FIREWALL_SECRET_KEY` | When `trustguard.firewall.enabled` (default true). Base URL is ConfigMap `NEURAL_TRUST_FIREWALL_BASE_URL` → in-cluster `http://firewall.<ns>.svc.cluster.local`. Keep in sync with `firewall.enabled`. |
| TrustGuard DB password | `trustguard-secrets` | `DB_PASSWORD` | **v2 external only** — auto-generated; **omitted when `trustguard.database.iamAuth=true`**. In v2 **hybrid** the password comes from the shared `postgresql-secrets`. |
| TrustGuard raw-telemetry DSN | `trustguard-secrets` | `SENSIBLE_PG_DSN` | **v2 external only**. In v2 **hybrid** it lives in `postgresql-secrets`. |
| Shared v2 hybrid Postgres credential | `postgresql-secrets` | `DB_HOST` / `DB_PORT` / `DB_USER` / `DB_PASSWORD` / `DB_NAME` / `DB_SSL_MODE` / `SENSIBLE_PG_DSN` (aliased alongside the `POSTGRES_*` + `DATABASE_URL` keys) | **v2 hybrid only** — the umbrella renders one shared Secret from `global.postgresql.*` (default `user`/`database` = `neuraltrust`). Every hybrid workload (AgentGateway, TrustGuard, DataAgent, `data-plane-api`) `envFrom`'s this Secret, so all four connect as the same role. Set `global.postgresql.existingSecret.name` to point at a pre-created Secret instead. |
| Shared v2 hybrid Redis credential | `redis-secrets` | `REDIS_HOST` / `REDIS_PORT` / `REDIS_PASSWORD` / `REDIS_USERNAME` / `REDIS_TLS` | **v2 hybrid only** — rendered from `global.redis.*`. Empty `REDIS_PASSWORD` for the passwordless in-cluster default. Set `global.redis.existingSecret.name` to reuse a pre-created Secret. |
| Shared TrustGuard client creds | `trustguard-client-credentials` | `CLIENT_ID` / `CLIENT_SECRET` | id defaults to `agentgateway-platform`; secret auto-generated (or `global.v2.trustguardClientSecret`). Injected into both AgentGateway (`TRUSTGUARD_CLIENT_ID`/`_SECRET`) and TrustGuard (`TRUSTGUARD_PLATFORM_CLIENT_ID`/`_SECRET`) so the pair matches. The prerelease `v2-trustguard-client-secret` values are copied during upgrade. |
| TrustLens JWT | `trustlens-secrets` | `JWT_SECRET` | auto-generated (only when `trustlens.enabled=true`) |
| TrustLens encryption keyset | `trustlens-secrets` | `ENCRYPTION_KEYSET` | auto-generated |
| TrustLens DB password | `trustlens-secrets` | `DATABASE_PASSWORD` | auto-generated |
| DataAgent DB password | `postgresql-secrets` (shared) | `DB_PASSWORD` | **v2 hybrid** — DataAgent envFrom's the shared `postgresql-secrets`. Set `dataagent.database.password` / `dataagent.databaseUrl` explicitly to keep a per-service credential in `dataagent-secrets` instead. |
| DataAgent DB DSN | `postgresql-secrets` (shared) | `DATABASE_URL` | **v2 hybrid** — DataAgent connects as `global.postgresql.user` (default `neuraltrust`). Override with `dataagent.databaseUrl` to opt out of the shared credential. |
| DataAgent enrolment token | `dataagent-secrets` or operator Secret | `ENROLMENT_TOKEN` (configurable key) | **never** auto-generated — SaaS-issued, from `enrolmentToken` or `enrolmentTokenExistingSecret` |
| AlertEngine DB password | `alertengine-secrets` | `DB_PASSWORD` | auto-generated (own `alertengine` DB; external only); **omitted when `alertengine.database.iamAuth=true`** |
| AlertEngine auth JWT | `alertengine-secrets` | `AUTH_JWT_SECRET` | auto-generated — must match the app BFF token signer for UI auth |
| AlertEngine encryption key | `alertengine-secrets` | `APP_ENCRYPTION_KEY` | auto-generated (AES-256-GCM for integration secrets) |
| DataCore JWT | `datacore-secrets` | `AUTH_JWT_HS256_SECRET` | auto-generated |
| DataCore DB password | `datacore-secrets` | `POSTGRES_PASSWORD` | auto-generated (own `datacore` DB; external only); **omitted when `datacore.database.iamAuth=true`** (`POSTGRES_LOGIN=aws`) |
| DataCore / AlertEngine / clickstack / data-plane-api ClickHouse password | `clickhouse` | `admin-password` | **shared** — all read `CLICKHOUSE_PASSWORD` from the in-cluster `clickhouse` secret via `clickhouse.existingSecret` (`dataPlane.components.clickhouse.existingSecret` for the shim; no per-service key). External ClickHouse: point `existingSecret.name`/`key` at your secret. |
| v2 hybrid ClickStack OTLP | `dataagent-secrets` (or operator enrolment Secret) + in-memory access JWT | `ENROLMENT_TOKEN` (egress exchanges at DataCore) | **v2 hybrid only** — no direct SaaS bearer on apps. Local `clickstack-egress-collector` exchanges enrolment for a short-lived OTLP JWT. Requires `dataagent.enrolmentToken` / `enrolmentTokenExistingSecret`. Set `global.clickstack.enabled: false` for air-gap. |
| v2 hybrid config-sync (AgentGateway / TrustGuard) | operator Secrets (e.g. `agentgateway-config-sync`, `trustguard-config-sync`) | `CONFIG_SYNC_TOKEN`, `CONFIG_SYNC_LKG_KEY` | **Optional but expected for SaaS-managed hybrid.** Enable `agentgateway.configSync` / `trustguard.configSync` separately (defaults `enabled: false`). Prefer `existingSecret.name` pointing at Secrets that hold **both** keys. Never auto-generated. |
| v2 external ClickStack OTLP token | `clickstack-collector-secrets` | `OTLP_AUTH_TOKEN`, `OTEL_EXPORTER_OTLP_HEADERS` | **v2 external only** — auto-generated (or `clickstack-otel-collector.otlpAuthToken`). `OTLP_AUTH_TOKEN` is what the collector enforces; `OTEL_EXPORTER_OTLP_HEADERS` is `authorization=<same token>` and is mounted on TrustGuard / AgentGateway via `secretKeyRef`. |
| Control-plane app auth | `control-plane-secrets` | `AUTH_SECRET` / `NEXTAUTH_SECRET` | one generated or reused value exposed under both aliases |

AlertEngine and TrustLens URLs are non-secret values wired directly into the
control-plane app Deployment, alongside the other backend service URLs. On first
install, missing Secrets/keys are created; later upgrades reuse them with `lookup`.

- **Postgres (v2 hybrid)**: the chart no longer runs a schema/role init Job.
  Application migrations own their tables in the shared `neuraltrust` database
  (`trustgate_migration_versions` / `trustguard_migration_versions` are already
  namespaced). For **in-cluster PostgreSQL** the umbrella renders
  `control-plane-postgresql` with `POSTGRES_USER=neuraltrust` /
  `POSTGRES_DB=neuraltrust`. For an **external / managed** PostgreSQL the DBA (or
  Terraform) pre-creates the database and login role; point the chart at it via
  `global.postgresql.deploy: false` + host/user/password (or
  `global.postgresql.existingSecret.name`). External deployments keep the classic
  per-service databases (each control plane owns its own migrations) and are not
  affected by this simplification.
- **In-cluster Redis** (`redis`) is passwordless by default. Set
  `global.redis.password` / `global.redis.existingSecret.name` for a hosted /
  authenticated Redis; the chart stores it in the shared `redis-secrets` Secret
  every hybrid workload envFrom's.
- **Shared ClickHouse credential**: DataCore, AlertEngine, `clickstack-otel-collector`
  and the `data-plane-api` shim read the ClickHouse password from the single
  `clickhouse` secret (key `admin-password`) — none store their own
  `CLICKHOUSE_PASSWORD`. Override per service with
  `datacore.clickhouse.existingSecret` / `alertengine.clickhouse.existingSecret` /
  `clickstack-otel-collector.clickhouse.existingSecret` /
  `data-plane-api.dataPlane.components.clickhouse.existingSecret`. For
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
  `data-plane-api.dataPlane.components.api.database.postgresql.{host,port,user,database}`
  (they override the matching Secret key) and/or point `…database.postgresql.existingSecret.name`
  (with an optional `keys` map) at a pre-created Secret holding the password. A
  `postgres-migrations` initContainer applies the idempotent schema, so the
  configured role needs `CREATE SCHEMA`/`CREATE TABLE` on the target database.
  The ClickHouse credential below applies only when the shim is on ClickHouse
  (v2 external, or hybrid pinned to an external ClickHouse).
- **Optional IAM DB/Redis auth (AWS)**: the v2 Go services accept
  `database.iamAuth` / `redis.iamAuth` (default false). When on they emit
  `DB_IAM_AUTH`/`DB_AUTH_MODE`/`POSTGRES_LOGIN=aws` (Postgres) or
  `REDIS_LOGIN=aws`/`REDIS_CACHE_NAME`/`REDIS_IAM_AUTH` (Redis) and ship no
  static password. AgentGateway and TrustGuard mint RDS **and** ElastiCache
  SigV4 tokens at connect time (require IRSA + `redis.{username,tls,cacheName}`;
  set `redis.awsServerless=true` for ElastiCache Serverless). `data-plane-api`
  Redis IAM uses `api.redis.iamAuth` (`REDIS_AUTH_MODE=aws_iam`). AlertEngine
  (v0.4.0+) mints RDS IAM tokens via `database.iamAuth` (`DB_AUTH_MODE=iam`) and
  requires `database.awsRegion` → `AWS_REGION`. RDS IAM is also live for the
  Python control-plane (`controlPlane.components.postgresql.authMode: iam`).
  Use `values-v2-managed-datastores.yaml.example` as the tracked starting point.
- **DataAgent** renders when `tenantId` and either `enrolmentToken` or
  (preferred) `enrolmentTokenExistingSecret.name` are set (SaaS-issued, never
  generated). Its `DATABASE_URL` and `DB_PASSWORD` auto-derive from shared
  hybrid `postgresql-secrets`; overlay `dataagent.database.host` +
  `database.password` only to opt out. Prefer
  `dataagent.enrolmentTokenExistingSecret` so the token never enters Helm
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
| Best for | Dev, staging, quick starts | Production with Vault/compliance |

## Security best practices

1. **Use auto-generated secrets for simplicity** — the default is the safest starting point
2. **Use external secret management for production** — Vault, Sealed Secrets, or External Secrets Operator
3. **Never commit secrets to git** — don't store real values in values files that are version-controlled
4. **Rotate secrets regularly** — especially JWT secrets
5. **Restrict access with RBAC** — limit who can read Kubernetes secrets

## Troubleshooting

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
