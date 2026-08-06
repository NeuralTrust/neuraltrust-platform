# Secrets Management Guide

How secrets are created, stored, and managed across the NeuralTrust Platform chart.

Most credentials are generated for you. A short list is not, and the chart fails
the install rather than starting a workload that cannot authenticate. Read
[Secrets you must create](#secrets-you-must-create) first; everything after it is
reference material.

## Secrets you must create

The chart never generates these. Create them in the release namespace **before**
`helm install`.

### Hybrid

| Secret | Keys | Needed when |
|---|---|---|
| `gcr-secret` | docker-registry credentials | Always, unless images are mirrored to a registry the nodes can already pull from |
| `agentgateway-config-sync` | `CONFIG_SYNC_TOKEN` (plus `CONFIG_SYNC_LKG_KEY` only when the chart generates no Secrets — see below) | `global.products.trustgate: true` |
| `trustguard-config-sync` | `CONFIG_SYNC_TOKEN` (plus `CONFIG_SYNC_LKG_KEY` only when the chart generates no Secrets — see below) | `global.products.trustguard: true` |
| `dataagent-enrolment-trustgate` | `ENROLMENT_TOKEN` | `global.products.trustgate: true` |
| `dataagent-enrolment-trustguard` | `ENROLMENT_TOKEN` | `global.products.trustguard: true` |

Config-sync tokens and DataAgent enrolment JWTs are issued by the NeuralTrust
console, one pair per product. A hybrid running only `global.products.dataPlane`
needs neither — red teaming deploys no DataAgent and no config-sync.

The names above are the ones [`values-required.yaml`](./values-required.yaml)
already points at. Copy-pasteable `kubectl create secret` commands are in
[README.md step 3](./README.md#3-create-the-four-operator-supplied-secrets).

### External

| Secret | Keys | Needed when |
|---|---|---|
| `gcr-secret` | docker-registry credentials | Same as hybrid |
| `onprem-superadmin` | `ONPREM_SUPERADMIN_EMAIL`, `ONPREM_SUPERADMIN_PASSWORD` | You want a bootstrap console administrator (recommended — there is no hosted console to log in from) |
| your own name | one key per managed datastore role | You would rather not write datastore passwords into a values file — see [Datastore credentials without values](#datastore-credentials-without-values) |

External needs no config-sync tokens and no enrolment JWTs; it runs its own
control planes and never deploys DataAgent. Before going live, read
[`NEXT_PUBLIC_*` cannot be configured at runtime](#next_public_-cannot-be-configured-at-runtime)
— it affects the tenant URL a self-hosted console advertises to IdPs.

## Quick start

### Auto-generated secrets (default — recommended)

Everything not listed above is created for you on first install and reused on
upgrade:

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

# Shape the shared Secret (defaults: external, all products on)
export DEPLOYMENT_MODE=hybrid
export ENABLE_TRUSTGATE=true ENABLE_TRUSTGUARD=true ENABLE_DATAPLANE=false
```

The script writes the canonical `POSTGRES_*` family (including `POSTGRES_SSLMODE`,
`POSTGRES_LOGIN`, `POSTGRES_AUTH_MODE`, `POSTGRES_CONNECTION_TYPE`) and the shared
`platform-secrets` keys for the shapes you select. It does **not** compose
`SENSIBLE_PG_DSN` or store the retired `DATABASE_URL`. Set
`global.preserveExistingSecrets: true` (or `autoGenerateSecrets: false`) when Helm
must leave those Secrets alone.

### Pre-existing secrets (external management)

For Vault, Sealed Secrets, or External Secrets Operator:

```yaml
global:
  autoGenerateSecrets: false
  preserveExistingSecrets: true   # Helm will NOT create or update secrets
```

All required secrets must exist in the namespace before deployment. In this mode
the chart generates nothing, so credentials it would otherwise create for you
become your responsibility — including `CONFIG_SYNC_LKG_KEY` alongside
`CONFIG_SYNC_TOKEN` in each `configSync.existingSecret`. The data planes refuse
to start without it.

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
control-plane-api/app. Hybrid keeps the console on the hosted control plane.

Optional bootstrap admin for control-plane-app (external only). Prefer a
pre-created Secret via `global.superadmin.existingSecret.name` (keys default
to `ONPREM_SUPERADMIN_EMAIL` / `ONPREM_SUPERADMIN_PASSWORD`). Inline
`global.superadmin.email` + `password` still works when both are set, but
those values enter Helm release history — prefer `existingSecret` and rotate
after first login when possible. Empty defaults leave the feature off.

| Kubernetes Secret | Key | Required | Description |
|---|---|---|---|
| `<your-name>` (caller-controlled) | `ONPREM_SUPERADMIN_EMAIL` / `ONPREM_SUPERADMIN_PASSWORD` (override via `emailKey` / `passwordKey`) | Only when `global.superadmin.existingSecret.name` is set | Bootstrap admin for control-plane-app. Chart does not create this Secret. |
| `control-plane-secrets` | `CONTROL_PLANE_JWT_SECRET` | Auto-generated | JWT for Control Plane API auth |
| `control-plane-secrets` | `FIREWALL_JWT_SECRET` | No | JWT for firewall service |
| `control-plane-secrets` | `FIREWALL_API_URL` | Auto-populated | Firewall base URL (FQDN when firewall enabled, data-plane fallback otherwise) |
| `control-plane-secrets` | `MODEL_SCANNER_SECRET` | No | Model scanner service secret |
| `control-plane-secrets` | `OPENAI_API_KEY` | No | OpenAI API key |
| `control-plane-secrets` | `ONPREM_SUPERADMIN_EMAIL` | No | Bootstrap admin address; only when `global.superadmin.email`/`password` are set inline |
| `control-plane-secrets` | `ONPREM_SUPERADMIN_PASSWORD` | No | Bootstrap admin password; referenced via `secretKeyRef`, never a plain env value |
| `control-plane-secrets` | `RESEND_API_KEY` | No | Resend API key (`global.email.resend.apiKey`) |
| `control-plane-secrets` | `SMTP_PASSWORD` | No | SMTP password; injected as `SMTP_PASS`, the name the app reads |
| `control-plane-secrets` | `SES_ACCESS_KEY_ID` | No | Static SES key; omit to use the pod IAM role |
| `control-plane-secrets` | `SES_SECRET_ACCESS_KEY` | No | Static SES secret; omit to use the pod IAM role |
| `control-plane-secrets` | `resend-api-key` | No | Legacy alias of `RESEND_API_KEY`, kept in sync |
| `control-plane-secrets` | `resend-alert-sender` | No | Legacy "from" address; superseded by `global.email.from` |
| `control-plane-secrets` | `resend-reply-to` | No | Legacy Reply-To; superseded by `global.email.replyTo` |

### Login CAPTCHA (`TURNSTILE_SECRET_KEY`) — optional

`control-plane-app` can put a Cloudflare Turnstile challenge in front of the login
form after three failed attempts in a 30-minute window. The whole path is gated on
the build-time `NEXT_PUBLIC_TURNSTILE_SITE_KEY`: with no site key in the image the
widget never renders, the verification route is never called, and
`TURNSTILE_SECRET_KEY` is never read. The chart sets neither key, and the
server-side brute-force lock applies either way.

If your image was built with a site key and you want the challenge to work, supply
the matching secret through the app's `extraEnv` (from your own Secret — do not
inline the value). The pod needs egress to `challenges.cloudflare.com`:

```yaml
control-plane-app:
  controlPlane:
    components:
      app:
        extraEnv:
          - name: TURNSTILE_SECRET_KEY
            valueFrom:
              secretKeyRef: { name: my-turnstile-secret, key: TURNSTILE_SECRET_KEY }
```

### `NEXT_PUBLIC_*` cannot be configured at runtime

`control-plane-app` is a Next.js build. Every `NEXT_PUBLIC_*` variable is inlined into
the JavaScript bundle when the image is built, so setting one as pod env — including
through `extraEnv` — has **no effect**. The chart deliberately sets none of them.

The one that matters on-premise is `NEXT_PUBLIC_APP_URL`, which falls back to the SaaS
default `https://app.neuraltrust.ai`. It is used by two server-side paths, so a
self-hosted install advertises the wrong host in:

- the SCIM **tenant URL** shown after generating a SCIM token
- the `meta.location` field of SCIM user resources, which IdPs consume

Both need an image rebuilt with your own `NEXT_PUBLIC_APP_URL`, which the app's
Dockerfile does not yet accept as a build argument — making these two paths read the
runtime `APP_URL` instead is planned. Most other
user-facing URLs are safe: the SSO/OIDC/Azure setup screens and the SCIM setup guide
derive the origin from the browser, and invite links, magic links and server-side SSO
callbacks use the runtime `APP_URL` / `NEXTAUTH_URL` that the chart does set from
`global.domain` (override with
`control-plane-app.controlPlane.components.app.config.appUrl`).

### Outbound email

`control-plane-app` is the only sender. It builds one transport, chosen by
`global.email.provider` (`resend` | `ses` | `smtp`), and a misconfigured provider
fails at render time rather than silently dropping mail.

| Provider | Required | Optional |
|---|---|---|
| `resend` | `resend.apiKey` | — |
| `ses` | `ses.region` | `ses.accessKeyId` + `ses.secretAccessKey` (omit both for IRSA) |
| `smtp` | `smtp.host`, `smtp.port` | `smtp.secure`, `smtp.user` + `smtp.password` |

Two things to know:

- **Addresses are not secrets.** `global.email.from` and `replyTo` ship in every
  message header, so they render as plain Deployment env (`SENDER` /
  `AUTH_EMAIL_FROM`, `REPLY_TO_EMAIL` / `AUTH_EMAIL_REPLY_TO`). Only credentials
  go through a Secret. When neither is set in values the chart falls back to the
  legacy `resend-alert-sender` / `resend-reply-to` keys, so installs that
  pre-created `control-plane-secrets` keep working.
- **Static SES keys are cluster-wide.** Setting `ses.accessKeyId` injects
  `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`, which override the AWS SDK
  credential chain for *every* AWS call in the pod — including Postgres IAM auth.
  Prefer IRSA and leave both empty.

`RESEND_API_KEY` is emitted for every provider because the legacy password-reset
and invite senders are Resend-only and read it directly, independent of
`AUTH_EMAIL_PROVIDER`.

Point `global.email.existingSecret.name` at your own Secret to keep credentials
out of Helm release history; the `*Key` fields there map your key names onto the
chart's. Inline credentials and `existingSecret` are mutually exclusive.

**`extraEnv` wins.** Before `global.email` existed, the only way to select a
provider was `controlPlane.components.app.extraEnv`. The chart skips any email
env name already present there, so those overlays upgrade unchanged. This matters
beyond precedence: two entries with the same `name` make the API server reject
the Deployment patch (`the order in patch list ... doesn't match
$setElementOrder`), which fails the whole release. Migrate to `global.email.*`
when convenient — it is validated at render time, `extraEnv` is not.

### PostgreSQL

> **Ownership.** Both the `control-plane-postgresql` Deployment/PVC/Service and the `postgresql-secrets` Secret are owned by the umbrella chart (`templates/postgresql/` — mirroring `templates/redis/`). The Kubernetes names, PVC identity, and the gating switch `global.postgresql.deploy` are stable so live clusters upgrade in place. `postgresql-secrets` is generated by `templates/platform-secrets.yaml` on the default auto-generate path and by `templates/postgresql/secrets.yaml` on the `autoGenerateSecrets: false` fallback path; the two are mutually exclusive by construction so the Secret is never rendered twice.

| Kubernetes Secret | Key | Required | Description |
|---|---|---|---|
| `postgresql-secrets` | `POSTGRES_HOST` | Yes (if pre-generating) | Database hostname |
| `postgresql-secrets` | `POSTGRES_PORT` | Yes (if pre-generating) | Database port |
| `postgresql-secrets` | `POSTGRES_USER` | Yes (if pre-generating) | Database username |
| `postgresql-secrets` | `POSTGRES_PASSWORD` | Auto-generated (password mode) | Database password. Empty when `controlPlane.components.postgresql.authMode: iam`. |
| `postgresql-secrets` | `POSTGRES_DB` | Yes (if pre-generating) | Database name |
| `postgresql-secrets` | `POSTGRES_SSLMODE` | No | `sslmode` for the connection. |
| `postgresql-secrets` | `POSTGRES_LOGIN` | No | `aws` (IAM) or `default`. The only IAM switch the Go services read (`pkg/config/config.go`). |
| `postgresql-secrets` | `POSTGRES_AUTH_MODE` | No | `password` (default) or `iam`. Read by the Next.js app (`lib/db/postgresConfig.ts`). |
| `postgresql-secrets` | `POSTGRES_CONNECTION_TYPE` | No | `postgres` (password) or `aurora` (IAM). Read by the Python API (`src/database.py`). |
| `postgresql-secrets` | `POSTGRES_PRISMA_URL` | Yes in external | Prisma-compatible URL, carrying `connection_limit`. Password-less when `authMode: iam` (init-db mints a token at migrate time). Not rendered in hybrid, which has no Prisma reader, nor when `global.postgresql.passwordSecret` owns the password — the app then builds the URL itself. `SENSIBLE_PG_DSN` is no longer written: hybrid readers build connections from the discrete `POSTGRES_*` / `DB_*` parts (RUN-1086, RUN-1093). |

#### Datastore credentials without values

External mode gives each service its own database and its own migrations, so their
passwords differ and none of them can inherit from a single global value. Writing
them into a values file is the default but not the only option: name a Secret you
created under `<service>.database.existingSecret` (or `.redis.existingSecret`) and
the chart leaves that key out of the Secret it renders, injecting the variable at
each Deployment with a `secretKeyRef` to yours instead. Nothing then reaches the
values file or Helm release history. An inline `password` alongside the hook is
rejected at render, since only one of the two can win.

| Values path | Variable | Key defaults to |
|---|---|---|
| `agentgateway.database.existingSecret` | `DB_PASSWORD` | `DB_PASSWORD` |
| `agentgateway.redis.existingSecret` | `REDIS_PASSWORD` | `REDIS_PASSWORD` |
| `trustguard.database.existingSecret` | `DB_PASSWORD` | `DB_PASSWORD` |
| `trustguard.redis.existingSecret` | `REDIS_PASSWORD` | `REDIS_PASSWORD` |
| `alertengine.database.existingSecret` | `DB_PASSWORD` | `DB_PASSWORD` |
| `datacore.database.existingSecret` | `POSTGRES_PASSWORD` | `POSTGRES_PASSWORD` |
| `data-plane-api.dataPlane.components.api.redis.existingSecret` | `REDIS_URL` | `REDIS_URL` |
| `global.postgresql.passwordSecret` | `POSTGRES_PASSWORD` | `POSTGRES_PASSWORD` |

Because `key` is configurable, one Secret can serve every role — five database
passwords under five keys, and a cache Secret holding both `REDIS_PASSWORD` for
the gateways and the assembled `REDIS_URL` that data-plane-api reads instead of a
password. `values-managed-datastores.yaml.example` shows that layout.

The last row is the control-plane `neuraltrust` role, and it works differently
enough to be worth spelling out. It is not a key inside one service's Secret but
the credential three workloads share, so setting it makes the chart omit
`POSTGRES_PASSWORD` **and** the composed `POSTGRES_PRISMA_URL` from
`postgresql-secrets` — every other key is still written — and point
`control-plane-app` (both containers), `control-plane-api` and `data-plane-api`
at your Secret. `control-plane-app` then assembles its own connection URL from
the `POSTGRES_*` parts, which needs an image carrying
`scripts/postgres-password-url.mjs` for the migration step. Available in both
external and hybrid once TrustGate / TrustGuard / DataAgent images fall back to
discrete parts (RUN-1086, RUN-1093). Rendering fails if you combine it with an
inline `password` — `global.postgresql.password` or the `control-plane-api`
overlay — or with `existingSecret`, or while the chart runs its own PostgreSQL
(which is initialised from that key).

Two details make the redirection airtight rather than merely intended. The
connection-string environment entries are **not rendered at all** in this mode:
a `POSTGRES_PRISMA_URL` left behind in a preserved or hand-written Secret would
otherwise outrank the credential you just named, and survive a rotation without
raising anything. And the reference to your Secret is **required**, unlike the
chart's own — a typo in `key` stops the pod with `CreateContainerConfigError`
rather than building a password-less connection that fails later as a generic
authentication error.

Do not confuse it with `global.postgresql.existingSecret`, which hands the chart
a whole Secret to inject as-is and leaves you hand-writing all eleven of its
keys, connection strings included — usually the worse trade.

IAM auth stays outside this mechanism entirely: there is no static password to
point at, so the hooks are ignored when `iamAuth: true`, and
`global.postgresql.passwordSecret` is likewise ignored under
`global.postgresql.authMode: iam` rather than rejected.

Hybrid needs none of this: every workload connects as the one shared role, taking
`postgresql-secrets` and `redis-secrets` wholesale through `envFrom`, so a
pre-created Secret is already supported there via `global.postgresql.existingSecret`
/ `global.redis.existingSecret`. The per-service hooks are inert in hybrid.

#### One canonical name per fact

The Secret stores **one** name for each fact. Services that spell a fact differently
are renamed at their own Deployment through the `neuraltrust-platform.postgresEnv`
helper, so the manifest shows which variables a pod actually reads:

| Stored key | Renamed to | Read by |
|---|---|---|
| `POSTGRES_HOST` / `_PORT` / `_USER` / `_PASSWORD` | `DB_HOST` / `DB_PORT` / `DB_USER` / `DB_PASSWORD` | TrustGate, TrustGuard |
| `POSTGRES_DB` | `DB_NAME` | TrustGate, TrustGuard |
| `POSTGRES_DB` | `POSTGRES_DATABASE` | control-plane-app, control-plane-api, DataCore |
| `POSTGRES_SSLMODE` | `DB_SSL_MODE` | TrustGate, TrustGuard |
| `POSTGRES_HOST` / `_PORT` / `_USER` / `_PASSWORD` / `_DB` / `_SSLMODE` | (same names) | DataAgent (`lib/pq`) — hybrid; builds its own keyword DSN (RUN-1093) |
| `POSTGRES_PRISMA_URL` | `DATABASE_URL` | control-plane-app (Prisma) — external only |

DataAgent must not receive the Prisma URL: its `connection_limit` parameter is not a
`lib/pq` connection option, so `lib/pq` forwards it to the server as a runtime
setting and every query fails with `42704`. The chart therefore injects the discrete
`POSTGRES_*` parts instead of any composed DSN.

Earlier revisions also stored `DB_*` copies of the first four rows plus
`DATABASE_URL`, `SENSIBLE_PG_DSN`, `DATABASE_AUTH_MODE` and `DATABASE_IAM_AUTH`.
Those keys had either a single reader or none, and every consumer had to take the
whole Secret through `envFrom` to get the few it used. They are no longer written.
Keys left over in an existing Secret are harmless — nothing references them — and
are removed on the next upgrade that rewrites the Secret.

> **IAM auth for Control-Plane Postgres.** Setting
> `control-plane-api.controlPlane.components.postgresql.authMode: iam`
> (and/or `global.postgresql.authMode: iam`) makes the chart emit a password-less
> `POSTGRES_PRISMA_URL` (external only), sets the three per-runtime switches
> (`POSTGRES_LOGIN`, `POSTGRES_AUTH_MODE`, `POSTGRES_CONNECTION_TYPE`), and stops
> generating `POSTGRES_PASSWORD`.
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

External mode only — hybrid deploys no ClickHouse.

| Kubernetes Secret | Key | Required | Description |
|---|---|---|---|
| `clickhouse` | `admin-password` | Auto-generated | ClickHouse admin password. Shared: DataCore, AlertEngine, the ClickStack collector, and `data-plane-api` all read it rather than keeping their own copy. |
| `clickhouse-secrets` | `CLICKHOUSE_HOST`, `CLICKHOUSE_PORT`, `CLICKHOUSE_USER`, `CLICKHOUSE_DATABASE` | Auto-generated | Non-secret connection metadata, kept alongside the password so consumers resolve one reference. Contains no credentials. |

> **`global.customCaCert`.** Mounts a corporate CA bundle for HTTP/TLS egress (LLM APIs, etc.).

### Observability

Created only when explicitly enabled. None are auto-generated — operators bring their own values.

| Kubernetes Secret | Key | Required | Description |
|---|---|---|---|
| `neuraltrust-observability-token` | `token` | When `global.observability.enabled: true` with hosted export | Bearer token for `collector.neuraltrust.ai`. **Never auto-generated randomly.** Supply via `global.observability.hostedExport.auth.tokenValue`, pre-create with `./create-secrets.sh` (`OBSERVABILITY_TOKEN` env), or let Helm preserve an existing Secret via `lookup` on upgrade. Without it, hosted OTLP export is omitted. |

### Firewall

Created when TrustGuard is selected (`global.products.trustguard: true` in
hybrid; always in external). Firewall always accompanies TrustGuard:

| Kubernetes Secret | Key | Required | Description |
|---|---|---|---|
| `firewall-secrets` | `JWT_SECRET` | Yes | Shared with services calling the firewall |
| `firewall-secrets` | `HUGGINGFACE_TOKEN` | No | Not needed for official images (models are baked in at build time). Only for custom runtime-download builds. |

In external mode the Control Plane validates firewall tokens, so
`control-plane-api.controlPlane.secrets.firewallJwtSecret` (`FIREWALL_JWT_SECRET`)
must match `firewall-secrets` `JWT_SECRET`. The app's `FIREWALL_API_URL` derives
itself from `control-plane-secrets/FIREWALL_API_URL`, pointing at the in-cluster
firewall Service when TrustGuard is selected and falling back to the data-plane
otherwise.

### Docker registry

| Kubernetes Secret | Type | Required | Description |
|---|---|---|---|
| `gcr-secret` | `docker-registry` | Yes | Credentials for NeuralTrust container images, built from the registry key NeuralTrust sends you. Create it with `./create-image-pull-secret.sh --namespace <ns>`; the chart never generates it. Mirroring images to your own registry? Name that registry's pull Secret `gcr-secret` too — `global.imagePullSecrets` does **not** override the per-component default. |

## Secret reference in values

A per-service credential path takes a **scalar**. It is an operator pin: set it
and the chart stores that value instead of generating one.

```yaml
data-plane-api:
  dataPlane:
    secrets:
      dataPlaneJWTSecret: "your-secret-value"
```

To keep the credential out of values entirely, point the chart at a Secret you
own instead of pinning a value — use the `*SecretName` key next to it, or
`global.platformSecret.existingSecret` for the shared Secret as a whole.

```yaml
data-plane-api:
  dataPlane:
    secrets:
      dataPlaneJWTSecretName: "data-plane-jwt-secret"
```

> A `{secretName, secretKey}` map in place of the scalar is **not** supported.
> The shared Secret discards non-scalar shapes as "not pinned", so a map is
> silently ignored and the chart generates a value instead. Earlier revisions of
> this document recommended that form; it never applied to the shared Secret and
> the one template that honoured it has been removed.

## Environment variables for the script

All secrets can be provided via environment variables:

```bash
# Data Plane
export DATA_PLANE_JWT_SECRET="your-secret"
export DATA_PLANE_REDIS_URL="redis://user:pass@host:6379/0"  # optional; requires global.preserveExistingSecrets=true
export OPENAI_API_KEY="sk-..."
export GOOGLE_API_KEY="your-key"
export RESEND_API_KEY="your-key"
export HUGGINGFACE_TOKEN="your-token"

# Control Plane
export CONTROL_PLANE_JWT_SECRET="your-secret"
export FIREWALL_JWT_SECRET="your-secret"
export MODEL_SCANNER_SECRET="your-secret"

# Infrastructure
export CLICKHOUSE_PASSWORD="your-password"
export POSTGRES_HOST="postgres.example.com"
export POSTGRES_PORT="5432"
export POSTGRES_USER="postgres"
export POSTGRES_PASSWORD="your-password"
export POSTGRES_DB="neuraltrust"

# Hosted observability (hosted OTLP export)
export OBSERVABILITY_TOKEN="your-customer-token"

./create-secrets.sh --namespace neuraltrust
```

## Full secret catalog

Every Secret and key the chart knows about, in one table. All of them follow the
auto-generate + `lookup`-preserve model unless the Notes column says otherwise:
under `global.autoGenerateSecrets: true` they are created on first install and
reused on upgrade.

Two columns that are easy to confuse: **Key** is the key name stored inside the
Kubernetes Secret. That is not always the environment variable the container
sees — where a Deployment maps a key to a differently-named variable, the Notes
column says so.

On names: **TrustGate** is the product; **AgentGateway** is its chart and
Kubernetes identity, so its resources are `agentgateway-*`. TrustGuard uses the
same name in both places.

| Secret | Kubernetes Secret | Key | Notes |
|---|---|---|---|
| AgentGateway server key | `agentgateway-secrets` | `SERVER_SECRET_KEY` | auto-generated |
| AgentGateway MCP STS signing | `agentgateway-secrets` | `STS_SIGNING_KEY` | auto-generated RSA PKCS#1 private key (RS256), lookup-preserved so MCP tokens survive upgrades; use `create-secrets.sh` to validate and pre-provision an explicit PEM/base64-PEM key |
| AgentGateway DB password | `agentgateway-secrets` | `DB_PASSWORD` | **External only** — auto-generated (app reads `DB_PASSWORD`, not `DATABASE_PASSWORD`); **omitted when `agentgateway.database.iamAuth=true`**. In **hybrid** the password comes from the shared `postgresql-secrets` (see below). |
| AgentGateway raw-telemetry Postgres | `postgresql-secrets` → `DB_*` env | (discrete parts) | **Hybrid only** — the telemetry exporter falls back to the service `DatabaseConfig` (`DB_HOST` / `DB_PASSWORD` / …) when no `dsn_env` is set (RUN-1086). `SENSIBLE_PG_DSN` is no longer written or injected. |
| TrustGuard admin JWT | `trustguard-secrets` | `ADMIN_JWT_SECRET` | auto-generated |
| TrustGuard token signing | `trustguard-secrets` | `TRUSTGUARD_TOKEN_SIGNING_SECRET` | auto-generated |
| TrustGuard Redis events | `trustguard-secrets` | `REDIS_EVENTS_SECRET` | auto-generated; authenticates cache pub/sub events |
| TrustGuard Firewall client | `firewall-secrets` (mounted as env) | `JWT_SECRET` → `NEURAL_TRUST_FIREWALL_SECRET_KEY` | Present when TrustGuard is on (hybrid product flag or external full stack). Base URL is ConfigMap `NEURAL_TRUST_FIREWALL_BASE_URL` → in-cluster `http://firewall.<ns>.svc.cluster.local`. |
| TrustGuard DB password | `trustguard-secrets` | `DB_PASSWORD` | **External only** — auto-generated; **omitted when `trustguard.database.iamAuth=true`**. In **hybrid** the password comes from the shared `postgresql-secrets`. |
| TrustGuard raw-telemetry Postgres | `postgresql-secrets` → `DB_*` env | (discrete parts) | Hybrid only, same as AgentGateway (RUN-1086). |
| Shared hybrid Postgres credential | `postgresql-secrets` | `POSTGRES_*` — see [One canonical name per fact](#one-canonical-name-per-fact) | **Hybrid only** — the umbrella renders one shared Secret from `global.postgresql.*` (default `user`/`database` = `neuraltrust`), and every hybrid workload connects as that one role. Containers receive `DB_*` / `POSTGRES_*` names through explicit `env` mappings; those are **not** keys in the Secret. Set `global.postgresql.existingSecret.name` to supply your own instead — but then the chart injects it with `envFrom` and cannot rename anything, so **your keys must be `DB_HOST` / `DB_PORT` / `DB_USER` / `DB_PASSWORD` / `DB_NAME` / `DB_SSL_MODE`** (gateways) or the canonical `POSTGRES_*` family (DataAgent). |
| Shared hybrid Redis credential | `redis-secrets` | `REDIS_HOST` / `REDIS_PORT` / `REDIS_PASSWORD` / `REDIS_USERNAME` / `REDIS_TLS` | **Hybrid only** — taken wholesale with `envFrom`, and rendered from `global.redis.*`. Empty `REDIS_PASSWORD` for the passwordless in-cluster default. Set `global.redis.existingSecret.name` to reuse a pre-created Secret. TLS is stored once as `REDIS_TLS`, which is the name TrustGuard reads; AgentGateway reads `REDIS_TLS_ENABLED` and is given that name through an explicit `env` mapping, so a supplied Secret only needs `REDIS_TLS`. |
| Shared TrustGuard client creds | `trustguard-client-credentials` | `CLIENT_ID` / `CLIENT_SECRET` | id defaults to `agentgateway-platform`; secret auto-generated (or `global.v2.trustguardClientSecret`). Injected into both AgentGateway (`TRUSTGUARD_CLIENT_ID`/`_SECRET`) and TrustGuard (`TRUSTGUARD_PLATFORM_CLIENT_ID`/`_SECRET`) so the pair matches. The prerelease `v2-trustguard-client-secret` values are copied during upgrade. |
| DataAgent Postgres | `postgresql-secrets` (shared) | `POSTGRES_HOST` / `PORT` / `USER` / `PASSWORD` / `DB` / `SSLMODE` | **Hybrid** — DataAgent builds a libpq keyword connection string from these parts when `DATABASE_URL` is unset (RUN-1093). It connects as `global.postgresql.user` (default `neuraltrust`). |
| DataAgent enrolment token | operator Secret (e.g. `dataagent-enrolment-trustgate`), or `dataagent-secrets` / `dataagent-trustguard-secrets` when supplied inline | `ENROLMENT_TOKEN` (configurable key) | **Never** auto-generated — from `agentgateway.dataagent.enrolment` / `trustguard.dataagent.enrolment`. With the preferred `existingSecret.name` path the chart-managed `dataagent-*-secrets` render empty and the token is read straight from your Secret. |
| AlertEngine DB password | `alertengine-secrets` | `DB_PASSWORD` | auto-generated (own `alertengine` DB; external only); **omitted when `alertengine.database.iamAuth=true`** |
| AlertEngine auth JWT | `alertengine-secrets` | `AUTH_JWT_SECRET` | auto-generated — must match the app BFF token signer for UI auth |
| AlertEngine encryption key | `alertengine-secrets` | `APP_ENCRYPTION_KEY` | auto-generated (AES-256-GCM for integration secrets) |
| DataCore JWT | `datacore-secrets` | `AUTH_JWT_HS256_SECRET` | auto-generated |
| DataCore DB password | `datacore-secrets` | `POSTGRES_PASSWORD` | auto-generated (own `datacore` DB; external only); **omitted when `datacore.database.iamAuth=true`** (`POSTGRES_LOGIN=aws`) |
| DataCore / AlertEngine / clickstack / data-plane-api ClickHouse password | `clickhouse` | `admin-password` | **shared** — all read `CLICKHOUSE_PASSWORD` from the in-cluster `clickhouse` secret via `clickhouse.existingSecret` (`dataPlane.components.clickhouse.existingSecret` for data-plane-api; no per-service key). External ClickHouse: point `existingSecret.name`/`key` at your secret. |
| Hybrid ClickStack OTLP | primary DataAgent enrolment Secret + in-memory access JWT | `ENROLMENT_TOKEN` (egress exchanges at DataCore) | **Hybrid — mandatory when TrustGate and/or TrustGuard enabled.** No direct bearer on apps. Local `clickstack-egress-collector` on the primary DataAgent exchanges enrolment for a short-lived OTLP JWT. Requires per-product `*.dataagent.enrolment`. data-plane-only hybrid skips this. Air-gapped / local-only product telemetry → `global.deploymentMode: external`. |
| Hybrid config-sync token (TrustGate / TrustGuard) | operator Secrets (e.g. `agentgateway-config-sync`, `trustguard-config-sync`) | `CONFIG_SYNC_TOKEN` | **On by default in hybrid** (mode-derived) for each enabled product. Never auto-generated — the console issues it and the hosted control plane verifies it. Prefer `agentgateway.configSync.existingSecret` / `trustguard.configSync.existingSecret`; do not restate `enabled: true`. Set `configSync.enabled: false` only for Postgres-managed configuration. |
| Config-sync LKG cache key (TrustGate / TrustGuard) | `agentgateway-secrets`, `trustguard-secrets` | `CONFIG_SYNC_LKG_KEY` | **Auto-generated** (32 random bytes) **while the chart owns the service Secret** — that is, `global.autoGenerateSecrets: true` and `global.preserveExistingSecrets: false`, the default. Reused across upgrades via `lookup`, delivered through `envFrom`. It encrypts only the local last-known-good snapshot file, which lives on an `emptyDir` and is discarded on restart anyway; the runtimes use it purely as the AES-256-GCM key for that file. Override with `configSync.lkgKey`. Putting the key in your `configSync.existingSecret` has no effect on this path: the chart deliberately does not consult the cluster to discover it, because a `lookup`-dependent reference renders differently under `helm upgrade` than under `helm template` or ArgoCD.<br><br>**Under `autoGenerateSecrets: false` or `preserveExistingSecrets: true` the chart owns no Secret to generate it into, so you must add `CONFIG_SYNC_LKG_KEY` (base64, decoding to exactly 32 bytes) to your `configSync.existingSecret` yourself.** The data planes refuse to start without it. `create-secrets.sh` writes it for you — it generates the key into `agentgateway-config-sync` / `trustguard-config-sync` (override with `CONFIG_SYNC_SECRET_TRUSTGATE` / `CONFIG_SYNC_SECRET_TRUSTGUARD`), so point `configSync.existingSecret.name` at the same Secret and add your console-issued `CONFIG_SYNC_TOKEN` to it. |
| External config-sync gRPC TLS (TrustGate / TrustGuard) | `agentgateway-configsync-tls`, `trustguard-configsync-tls` | `tls.crt`, `tls.key`, `ca.crt` | **External only, and only under a deployed `config.appEnv`** (`prod`/`production`/`staging`/`stage`). Auto-generated self-signed CA + server certificate; the control plane serves it, the data planes verify against the CA. Never rotated (`lookup` + `resource-policy: keep`). Bring your own with `configSync.grpcTls.existingSecret` (`kubernetes.io/tls`, must include `ca.crt`); setting `autoGenerate: false` without one is rejected at render, because the control plane cannot start without a keypair. |
| External ClickStack OTLP token | `clickstack-collector-secrets` | `OTLP_AUTH_TOKEN`, `OTEL_EXPORTER_OTLP_HEADERS` | **External only** — auto-generated (or `clickstack-otel-collector.otlpAuthToken`). `OTLP_AUTH_TOKEN` is what the collector enforces; `OTEL_EXPORTER_OTLP_HEADERS` is `authorization=<same token>` and is mounted on TrustGuard / AgentGateway via `secretKeyRef`. |
| Control-plane app auth | `control-plane-secrets` | `AUTH_SECRET` / `NEXTAUTH_SECRET` | one generated or reused value exposed under both aliases |

AlertEngine URLs are non-secret values wired directly into the control-plane app
Deployment, alongside the other backend service URLs. On first
install, missing Secrets/keys are created; later upgrades reuse them with `lookup`.

- **Postgres (hybrid)**: no chart-managed schema migration. Application migrations
  own their tables in the shared `neuraltrust` database
  (`trustgate_migration_versions` / `trustguard_migration_versions` are already
  namespaced). For **in-cluster PostgreSQL** the umbrella renders
  `control-plane-postgresql` with `POSTGRES_USER=neuraltrust` /
  `POSTGRES_DB=neuraltrust`, the pair every hybrid workload shares. For an
  **external / managed** PostgreSQL the DBA (or Terraform) pre-creates the database
  and login role; point the chart at it via `global.postgresql.deploy: false` +
  host/user/password (or `global.postgresql.existingSecret.name`).
- **Roles and databases on the chart's own PostgreSQL (chart 2.7.0+)**: external
  mode gives each service its own database, and the PostgreSQL image creates only
  the pair above, so a `control-plane-postgresql-bootstrap` Job creates the rest.
  Per deployed service it creates the role with the password already in that
  service's Secret — `agentgateway-secrets` / `trustguard-secrets` /
  `alertengine-secrets` (`DB_PASSWORD`), `datacore-secrets`
  (`POSTGRES_PASSWORD`), `trustlens-secrets` (`DATABASE_PASSWORD`), or the Secret
  named under `<service>.database.existingSecret` — then creates the database owned
  by it. So generated passwords never need transcribing, and rotating one is
  applied to the role on the next upgrade. Skipped per service when it is not
  deployed, uses `iamAuth`, or shares the bootstrap role, which is every hybrid
  service. It runs only when the chart owns the instance: naming another host,
  `deploy: false`, IAM auth, or
  `global.postgresql.bootstrapJob.enabled: false` all stop it rendering, and its
  target is templated rather than read from `postgresql-secrets`. Managed instances
  stay the DBA's to provision.
- **In-cluster Redis** (`redis`) is passwordless by default. Set
  `global.redis.password` / `global.redis.existingSecret.name` for a hosted /
  authenticated Redis; the chart stores it in the shared `redis-secrets` Secret
  every hybrid workload envFrom's.
- **Endpoints are declared once (chart 2.6.0+).** `host`, `port` and `sslMode`
  under any `<service>.database`, and `host`, `port`, `username` and `tls` under
  any `<service>.redis`, fall back to `global.postgresql` / `global.redis` before
  falling back to the in-cluster Service names. A managed Aurora/ElastiCache is
  therefore named once on the global blocks rather than repeated per service, in
  external mode as well as hybrid. A per-service value still wins, so an overlay
  can send one service elsewhere. What stays per-service is identity, not
  endpoint: in external mode each service keeps its own role and database via
  `database.name` / `database.user`.

  Exactly these keys inherit: `host`, `port` and `sslMode` under
  `<service>.database`, and `host`, `port`, `username`, `tls` and `password` under
  `<service>.redis`. Their neighbours — `tlsInsecureVerify`, `db`, `iamAuth`,
  `awsRegion`, `cacheName`, `awsServerless` — have no `global.*` counterpart, so
  setting them on a global block does nothing.

  Because an empty value inherits, switching an inherited flag back off for one
  service needs a **quoted** string: `tls: "false"` in a values file, or
  `--set-string <service>.redis.tls=false`. A bare `--set …redis.tls=false`
  renders as an empty string and therefore inherits the global `true` instead.
  The same applies to `username`, where `""` cannot mean "AUTH as the default
  user" while a global ACL username is set.

  One credential deserves care: `global.redis.password` reaches all three cache
  consumers, but the Redis this chart deploys runs without `--requirepass`. A
  password set while `global.redis.deploy: true` and `global.redis.host` is empty
  is therefore rejected at render, because every consumer would fail to
  authenticate against the chart's own Redis.
- **Shared ClickHouse credential**: DataCore, AlertEngine, `clickstack-otel-collector`
  and `data-plane-api` read the ClickHouse password from the single
  `clickhouse` secret (key `admin-password`) — none store their own
  `CLICKHOUSE_PASSWORD`. Override per service with
  `datacore.clickhouse.existingSecret` / `alertengine.clickhouse.existingSecret` /
  `clickstack-otel-collector.clickhouse.existingSecret` /
  `data-plane-api.dataPlane.components.clickhouse.existingSecret`. For
  external ClickHouse (`infrastructure.clickhouse.deploy=false`), point these at the
  secret matching `infrastructure.clickhouse.external.secretName`/`secretKey`, and set
  the ClickHouse host to your endpoint (a dotted/FQDN host is used verbatim; a bare
  name expands to `<name>.<namespace>.svc.cluster.local`).
- **`data-plane-api` PostgreSQL backend (hybrid default)**: in hybrid the API
  reads its evaluation store from PostgreSQL (`SQL_DATABASE=postgres`), so it needs
  no ClickHouse. It resolves its five `POSTGRES_*` connection vars from the
  umbrella-managed `postgresql-secrets` (keys `POSTGRES_HOST`/`POSTGRES_PORT`/
  `POSTGRES_USER`/`POSTGRES_PASSWORD`/`POSTGRES_DB`) by default — the password is
  ALWAYS a `secretKeyRef` (never inlined). For an EXTERNAL PostgreSQL, set the
  non-secret scalars under
  `data-plane-api.dataPlane.components.api.database.postgresql.{host,port,user,database}`
  (they override the matching Secret key) and/or point `…database.postgresql.existingSecret.name`
  (with an optional `keys` map) at a pre-created Secret holding the password. A
  `postgres-migrations` initContainer applies the idempotent tables and indexes.
  The schema defaults to `public`; set `…database.postgresql.schema` to use a
  custom pre-created schema. The configured role needs `USAGE` and `CREATE` on
  that schema, but does not need database-level `CREATE`.
  The ClickHouse credential below applies only when the API is on ClickHouse
  (external mode, or hybrid pinned to an external ClickHouse).
- **Optional IAM DB/Redis auth (AWS)**: the Go services accept
  `database.iamAuth` / `redis.iamAuth`. When `database.iamAuth` is **unset**, it
  inherits `global.postgresql.authMode=iam` (AUT-392) so an umbrella IAM setting
  cannot silently fall back to password auth on TrustGate / TrustGuard /
  DataCore / AlertEngine. An explicit per-service `true`/`false` still wins.
  When on they emit `POSTGRES_LOGIN=aws` (Postgres) or
  `REDIS_LOGIN=aws`/`REDIS_CACHE_NAME`/`REDIS_IAM_AUTH` (Redis) and ship no
  static password. AgentGateway and TrustGuard mint RDS **and** ElastiCache
  SigV4 tokens at connect time (require IRSA + `redis.{username,tls,cacheName}`;
  set `redis.awsServerless=true` for ElastiCache Serverless). `data-plane-api`
  Redis IAM uses `api.redis.iamAuth` (`REDIS_AUTH_MODE=aws_iam`). AlertEngine
  (v0.4.0+) mints RDS IAM tokens via `database.iamAuth` / inherited global auth
  mode (`DB_AUTH_MODE=iam`) and requires `database.awsRegion` → `AWS_REGION`.
  RDS IAM is also live for the Python control-plane
  (`controlPlane.components.postgresql.authMode: iam`).
  Every IAM service needs a region: IRSA supplies a role and a token file but no
  region, and the SigV4 signer fails without one. Set it once as
  `global.postgresql.awsRegion` — AgentGateway and TrustGuard fall back to it,
  and `<chart>.database.awsRegion` overrides per chart.
  Use `values-managed-datastores.yaml.example` as the tracked starting point.
- **Firewall Redis URL (AUT-386)**: the firewall Python client reads only
  `REDIS_URL` (defaulting to `redis://localhost:6379/0` when unset). The chart
  composes that URL from the shared Redis helpers into `firewall-config` (no
  password) or `firewall-secrets` (password present). **ElastiCache IAM is not
  supported** by this client — an IAM-only cache needs a static password or an
  in-cluster Redis.
- **Each selected product DataAgent** renders when its nested `dataagent`
  has either `enrolment.token` or (preferred)
  `enrolment.existingSecret.name` (never generated). The JWT
  carries `tenant_id` and `instance_id` — do not set them in Helm values.
  Its `DATABASE_URL` and `DB_PASSWORD` auto-derive from shared hybrid
  `postgresql-secrets`; overlay the product's `dataagent.database.host` +
  `database.password` only to opt out. Prefer
  `agentgateway.dataagent.enrolment.existingSecret` /
  `trustguard.dataagent.enrolment.existingSecret` so tokens never enter Helm
  values or release history. When chart secret generation is disabled, also set
  each product's `dataagent.existingSecret.name` to a Secret containing
  `DATABASE_URL` and `DB_PASSWORD`.

## Shared platform Secret (`platform-secrets`)

Several credentials above are read by more than one service — a signing key on one
side and a validator on the other. Each subchart used to generate its own copy, so
the copies could hold different values and produce silent `401`s.

`platform-secrets` is the single generator for all of them. Consumers reference it
instead of the per-service Secret, and the per-service Secrets in the table above
**keep being written for one release** so a rollback still finds the values.

Upgrades adopt whatever the live per-service Secret holds, so **nothing rotates**.
Resolution order per key: `global.platformSecret.values` → live `platform-secrets`
→ the legacy Secret below → generate (only where the chart owns the value).

| Logical key | Adopted from | Value | Emitted when |
|---|---|---|---|
| `SERVER_SECRET_KEY` | `agentgateway-secrets` / `SERVER_SECRET_KEY` | generated | external, TrustGate |
| `ADMIN_JWT_SECRET` | `trustguard-secrets` / `ADMIN_JWT_SECRET` | generated | external, TrustGuard |
| `TRUSTGUARD_TOKEN_SIGNING_SECRET` | `trustguard-secrets` / `TRUSTGUARD_TOKEN_SIGNING_SECRET` | generated | external, TrustGuard |
| `REDIS_EVENTS_SECRET` | `trustguard-secrets` / `REDIS_EVENTS_SECRET` | generated | external, TrustGuard |
| `JWT_SECRET` | `firewall-secrets` / `JWT_SECRET` | generated | external, TrustGuard |
| `DATA_PLANE_JWT_SECRET` | `data-plane-jwt-secret` / `DATA_PLANE_JWT_SECRET` | generated | external, data plane |
| `CONTROL_PLANE_JWT_SECRET` | `control-plane-secrets` / `CONTROL_PLANE_JWT_SECRET` | generated | external |
| `AUTH_SECRET` | `control-plane-secrets` / `AUTH_SECRET` | generated | external |
| `NEXTAUTH_SECRET` | `control-plane-secrets` / `NEXTAUTH_SECRET` | **= `AUTH_SECRET`** | external |
| `AUTH_JWT_HS256_SECRET` | `datacore-secrets` / `AUTH_JWT_HS256_SECRET` | generated | external |
| `AUTH_JWT_SECRET` | `alertengine-secrets` / `AUTH_JWT_SECRET` | generated | external |
| `APP_ENCRYPTION_KEY` | `alertengine-secrets` / `APP_ENCRYPTION_KEY` | generated | external |
| `MODEL_SCANNER_SECRET` | `control-plane-secrets` / `MODEL_SCANNER_SECRET` | adopted only | external |
| `AUTH_SECRET_KEY` | `control-plane-secrets` / `AUTH_SECRET_KEY` | generated on install only | external |
| `MCP_OAUTH_CLIENT_SECRET` | `control-plane-secrets` / `MCP_OAUTH_CLIENT_SECRET` | generated | external, when MCP OAuth is on |
| `MCP_OAUTH_SIGNING_KEY` | `control-plane-secrets` / `MCP_OAUTH_SIGNING_KEY` | adopted only — a key you supply. Otherwise generated into its own `mcp-oauth-signing` Secret by a hook Job | external, when you supply a key |

**Adopted only** means the chart never invents the value — the key is omitted
until you supply it, because an operator owns it.

**Generated on install only** applies to `AUTH_SECRET_KEY`, which encrypts SSO
client secrets and SMTP credentials at rest. It is a different key from
`AUTH_SECRET`, which signs sessions — one value for both signing and encryption
would be key reuse. The app ships a built-in default, so any install running
without this key has already encrypted rows with that default; handing it a new
key on upgrade would make those rows undecryptable. A fresh install therefore gets
a real key, an upgrade leaves it absent, and you can adopt one deliberately by
pinning `global.platformSecret.values.AUTH_SECRET_KEY` once the existing
ciphertext no longer matters (SSO client secrets and SMTP credentials have to be
re-entered afterwards).

Never `kubectl apply` the output of `helm template` to an existing release. Helm
renders every template as an *install*, so the output carries a freshly generated
`AUTH_SECRET_KEY` (and new values for the other generated keys). Applying it rotates
the at-rest encryption key and makes anything already encrypted unreadable. Use
`helm upgrade`, which resolves these keys from the live Secret. For the same reason
a `helm template`-based diff shows spurious credential changes.

Credentials that only one service reads stay in their own Secret and are **not**
here — third-party API keys (`OPENAI_API_KEY`), the TrustGuard client credential
pair, and every per-service database password. Copying those in would create a
second copy nobody reads, which is the drift this Secret exists to prevent.

**Emitted when** keeps an install down to the credentials its services actually
read, so a hybrid install carries far fewer keys than an external one. A key
already present in a live `platform-secrets` is kept even when this install's
shape does not ask for it, so an upgrade never drops a credential just because a
product was turned off.

That carry-over only covers keys that still have a registry row: the check runs
inside the loop over the registry, so a key whose row is removed is no longer
visited and disappears from the Secret on the next upgrade. Retiring a row is
therefore a deliberate decision to delete the key, not a way to leave it behind.

### MCP OAuth (`global.mcpOAuth`)

An MCP consumer normally needs an identity provider of its own before it can log
in. TrustGate can instead fall back to a built-in provider, with the
control-plane app acting as the OAuth2 authorization server, so a proof of concept
needs no external IdP.

**External mode only.** A hybrid install deploys no control-plane app — it talks
to the hosted platform — so there is no in-cluster issuer to point TrustGate at
and no client secret the two sides could agree on locally. Enabling it in hybrid
fails at render time instead of wiring a login that cannot complete.

**On by default in external, with nothing to configure.** `enabled` is
three-state, because wanting the feature and having the key it needs are separate
questions:

| `global.mcpOAuth.enabled` | Behaviour |
| --- | --- |
| unset (default) | On in external, always off in hybrid. The chart generates the signing key when nothing else provides one. |
| `true` | Required. The render **fails** when no signing key is available, which needs `generateSigningKey: false` and no key of your own. |
| `false` | Never. With no client id the app answers `503` on its MCP OAuth routes. |

```yaml
global:
  mcpOAuth:
    # enabled: left unset — on in external, and the key is generated for you.
    # Optional; only when the app is not served from app.<global.domain>.
    issuer: "https://app.example.com/api/mcp/oauth"
    allowedRedirectHosts: "https://*.mcp.example.com"
```

The two sides must agree on one client secret, so the chart gives both the same
`MCP_OAUTH_CLIENT_SECRET` from `platform-secrets` — the app reads it under that
name, TrustGate as `MCP_DEFAULT_IDP_CLIENT_SECRET`. Both also derive the issuer
from one helper, because a mismatch stays silent until TrustGate tries to fetch
JWKS from an issuer nobody serves. Only the MCP workload gets this configuration;
admin and proxy do not broker logins.

`allowedRedirectHosts` matters: left empty the app accepts an OAuth callback on
**any** https origin. The chart defaults it to `https://*.mcp.<global.domain>`,
the gateway's own MCP wildcard, and **refuses to enable MCP OAuth** when neither
that nor `global.domain` is set, rather than shipping an open redirect. Widen it
only to origins you control.

Two knobs configure only TrustGate's side of the exchange, so leave them at their
defaults unless you have checked the app agrees. `audience` is what TrustGate
validates the `aud` claim against; the app mints it from a compiled-in constant it
does not read from the environment, so the matching defaults are what make it work
and changing one side makes TrustGate reject every token. `scopes` is required by
TrustGate but never requested by the app.

`enabled` accepts `true`/`false` as booleans or as strings, since a Flux
`HelmRelease` sourcing values from a ConfigMap makes every value a string. Anything
that is neither is rejected rather than guessed at.

MCP OAuth also needs the shared platform Secret to be in play, because both sides
read one client secret from it. With `platformSecret.enabled: false`,
`preserveExistingSecrets`, `autoGenerateSecrets: false`, or an operator-owned
`platformSecret.existingSecret`, the chart cannot deliver that key and leaves the
feature off — an explicit `enabled: true` there fails with the reason.

#### The signing key

The app signs with RS256 and loads the key with `importPKCS8`, so it needs an RSA
key in PKCS#8 form, and it must be the *same* key on every replica — otherwise
each one mints its own ephemeral key and tokens stop validating across replicas
and restarts.

Helm's templating cannot produce that key: `genPrivateKey "rsa"` emits PKCS#1,
`"ecdsa"` emits SEC1, and the one generator that does emit PKCS#8 (`"ed25519"`) is
the wrong algorithm. So the chart generates it with a `pre-install,pre-upgrade`
hook Job instead, which:

- runs the **app image this chart already deploys**, so there is no extra image to
  mirror or take through a vulnerability review — Node generates PKCS#8 natively
  and reaches the API server with its projected service-account token;
- writes to its own `mcp-oauth-signing` Secret, kept separate from
  `platform-secrets` because pre-install hooks run before Helm creates any
  manifest, and pre-creating a chart-owned Secret would collide with Helm's
  ownership metadata on a fresh install;
- **never replaces an existing key.** Every run re-reads the Secret first and
  leaves any key it finds alone, because that key signs access tokens already in
  circulation. It also parses what it stores and logs the algorithm and size, so a
  broken key fails the upgrade instead of surfacing as a failed login;
- is skipped entirely as soon as you supply a key of your own, and can be turned
  off with `global.mcpOAuth.generateSigningKey: false` if you want to own the key —
  MCP OAuth then stays off until you do.

Because the Secret is hook-owned rather than release-owned, `helm uninstall` leaves
it in place and a later reinstall keeps the same key.

To supply your own key instead, generate one base64-encoded so it survives a values
file as a single line (the app accepts raw PEM, `\n`-escaped PEM, or base64):

```bash
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
  | openssl base64 -A > mcp-oauth-signing.b64
```

Node works too, if you would rather not depend on the local OpenSSL build:

```bash
node -e "const {generateKeyPairSync}=require('crypto');\
const {privateKey}=generateKeyPairSync('rsa',{modulusLength:2048});\
process.stdout.write(Buffer.from(privateKey.export({type:'pkcs8',format:'pem'})).toString('base64'))" \
  > mcp-oauth-signing.b64
```

Then put it in your values file, which must be kept out of git:

```yaml
global:
  platformSecret:
    values:
      MCP_OAUTH_SIGNING_KEY: "<the single line from mcp-oauth-signing.b64>"
```

You only need to supply it once. The chart writes it into `platform-secrets`, which
carries `helm.sh/resource-policy: keep`, and later upgrades adopt it from there.

Prefer keeping it out of your values file altogether? Put it straight into the
Secret and leave every file clean — nothing then appears in `helm get values` or in
stored release revisions:

```bash
kubectl -n <namespace> patch secret platform-secrets --type merge \
  -p "{\"stringData\":{\"MCP_OAUTH_SIGNING_KEY\":\"$(cat mcp-oauth-signing.b64)\"}}"
```

Your key always wins over a generated one. Swapping one in later is a key rotation:
it invalidates tokens signed by the previous key, so nothing does it implicitly.

### Managing it yourself

```yaml
global:
  platformSecret:
    # Point consumers at your own Secret. It must use the LOGICAL key names
    # from the table above, not the legacy per-service key names.
    existingSecret:
      name: my-platform-secrets
```

Pin individual credentials without owning the whole Secret:

```yaml
global:
  platformSecret:
    values:
      CONTROL_PLANE_JWT_SECRET: "<value>"
```

To stay entirely on the legacy per-service Secrets, set
`global.platformSecret.enabled: false`. `global.preserveExistingSecrets: true`
implies it, since there the operator already owns every per-service Secret.

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
