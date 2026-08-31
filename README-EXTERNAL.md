# External (Self-Hosted) Deployment Guide

`external` mode runs the **entire** platform in your cluster — control planes, data planes, the console, and the analytics stack. No
NeuralTrust-hosted control plane and no DataAgent.

Use this guide when payload data, telemetry, and configuration must never leave
your environment. For the default hosted-control-plane path, see the
[hybrid quick start](./README.md#quick-start-hybrid).

## Hybrid vs external


|                         | `hybrid` (default)                                 | `external`                                                |
| ----------------------- | -------------------------------------------------- | --------------------------------------------------------- |
| Console / control plane | Hosted by NeuralTrust                              | `control-plane-app` + `control-plane-api` in your cluster |
| Product selection       | `global.products` flags, at least one `true`       | **Flags ignored** — full stack always deploys             |
| Analytics store         | Hosted, via enrolment-backed OTLP egress           | In-cluster or managed **ClickHouse**                      |
| Telemetry collector     | `clickstack-egress-collector` sidecar on DataAgent | `clickstack-collector` Deployment writing to ClickHouse   |
| DataAgent               | One per enabled product                            | **Never renders**                                         |
| Config-sync             | On by default, needs console tokens                | Data planes do not dial it — configuration lives in PostgreSQL. The control plane still serves the listener; see below |
| Air-gap capable         | No (product OTLP egress is mandatory)              | Yes                                                       |




## Prerequisites

- A Kubernetes cluster with an ingress controller, and Helm 3.8+ for OCI installs
- **4–5 worker nodes at 8 vCPU / 16–32 GiB** — external adds the control plane,
ClickHouse, ClickStack collector, DataCore, and AlertEngine on top of the data
path. See `[docs/sizing.md](./docs/sizing.md)`
- A base domain you can point at the cluster ingress, plus TLS certificates for
it
- The NeuralTrust registry pull secret in the release namespace, or all images
mirrored into your own registry
- A storage class for the ClickHouse and PostgreSQL volumes



## Quick start



### 1. Create the namespace and image pull secret

```bash
kubectl create namespace neuraltrust

GCR_KEY_FILE=./gcr-keys.json ./create-image-pull-secret.sh --namespace neuraltrust
```



### 2. Create the bootstrap admin Secret

External mode has no hosted console to log into, so the first administrator is
seeded from a Secret. Keys default to `ONPREM_SUPERADMIN_EMAIL` and
`ONPREM_SUPERADMIN_PASSWORD`:

```bash
kubectl create secret generic onprem-superadmin -n neuraltrust \
  --from-literal=ONPREM_SUPERADMIN_EMAIL='admin@example.com' \
  --from-literal=ONPREM_SUPERADMIN_PASSWORD='<strong-password>'
```

Inline `global.superadmin.email` + `password` also works, but those values enter
Helm release history — prefer the Secret. Leaving both unset leaves the bootstrap
admin off entirely.

Unlike hybrid, external needs **no** config-sync tokens and **no** DataAgent
enrolment JWTs. Every other credential is generated on first install and reused
on upgrade while `global.autoGenerateSecrets: true` — see [SECRETS.md](./SECRETS.md).

#### Why two `*-configsync-tls` Secrets appear anyway

A default external install creates `agentgateway-configsync-tls` and
`trustguard-configsync-tls` even though config-sync is not in use. They are not
leftovers, and their presence does not mean config-sync is enabled.

The two halves are separately gated:

| | State in a default external install |
|---|---|
| Config-sync **client** (data planes dial the control plane) | **Off.** Configuration is read from PostgreSQL, and no console token is needed |
| Config-sync **server** (control plane listens on gRPC `:8083`) | **Always started**, and under a deployed `config.appEnv` — `prod`, `production`, `staging` or `stage` — it refuses to boot without a TLS keypair |

So the Secrets exist because the *server* always starts, not because anything
dials it. Both control planes hard-fail without them: TrustGate at
`pkg/container/modules/control_config_sync.go` and TrustGuard at
`internal/container/modules/control_config_sync.go` both return an invalid-config
error when `CONFIG_SYNC_GRPC_TLS_CERT` / `_KEY` are unset in a deployed
environment. The chart generates a self-signed CA and server certificate for
exactly this reason, and never rotates them.

You do not need to do anything with these Secrets. Two consequences worth knowing:

- Setting `configSync.grpcTls.autoGenerate: false` without supplying
  `configSync.grpcTls.existingSecret` is rejected at render time, because the
  control plane could not start.
- Turning on in-cluster control-plane → data-plane sync is supported and needs no
  new certificates: set `agentgateway.configSync.enabled: true` (and/or the
  TrustGuard equivalent). The TLS material is already there. That is a deliberate
  option, not the default.

### 3. Write your values file

`[values-external.yaml.example](./values-external.yaml.example)` is the
tracked minimal external overlay:

```yaml
global:
  deploymentMode: "external"
  platform: "kubernetes" # aws | gcp | azure | openshift | kubernetes
  domain: "platform.example.com"
  superadmin:
    existingSecret:
      name: "onprem-superadmin"
  observability:
    hostedExport:
      enabled: false
```

`global.products` flags are not needed — external always deploys the full stack.
`hostedExport.enabled: false` removes the umbrella collector's hosted telemetry
exporter; keep it `false` for no-egress deployments.

### 4. Install

```bash
helm upgrade --install neuraltrust-platform \
  oci://europe-west1-docker.pkg.dev/neuraltrust-app-prod/helm-charts/neuraltrust-platform \
  --version <VERSION> \
  --namespace neuraltrust --create-namespace \
  -f values-external.yaml.example
```



### 5. Verify

```bash
kubectl get pods -n neuraltrust
kubectl get ingress -n neuraltrust
```

Default hostnames derive from `global.domain`:


| Service               | Host                                    |
| --------------------- | --------------------------------------- |
| Console (web app)     | `app.<domain>`                          |
| Control-plane API     | `api.<domain>`                          |
| TrustGate LLM gateway | `gateway.<domain>` and `*.llm.<domain>` |
| TrustGate MCP         | `mcp.<domain>` and `*.mcp.<domain>`     |
| TrustGate Admin       | `admin.<domain>`                        |
| TrustGuard            | `trustguard.<domain>`                   |
| TrustGuard Admin      | `trustguard-admin.<domain>`             |
| data-plane API        | `data-plane-api.<domain>`               |


Point DNS at the ingress address, then log in at `https://app.<domain>` with the
bootstrap admin credentials from step 2 and rotate the password.

## What external deploys

External runs the whole platform in your cluster — both control planes and the
data path. With the defaults in `values-external.yaml.example`, the release
contains:

**TrustGate** (values key `agentgateway:`; Kubernetes names stay `agentgateway-`*)


| Workload             | Role                        |
| -------------------- | --------------------------- |
| `agentgateway-admin` | Control plane and admin API |
| `agentgateway-proxy` | LLM gateway runtime         |
| `agentgateway-mcp`   | MCP gateway runtime         |


**TrustGuard and Firewall**


| Workload                                                                                                                                   | Role                                                        |
| ------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------- |
| `trustguard-control-plane`                                                                                                                 | Policy and admin API                                        |
| `trustguard-data-plane`                                                                                                                    | `/v1/guard` evaluation runtime                              |
| `firewall`                                                                                                                                 | NeuralTrust Firewall model server, deployed with TrustGuard |
| `prompt-jailbreak-worker`, `response-jailbreak-worker`, `prompt-moderation-worker`, `toxicity-worker`, `indirect-prompt-injections-worker` | Per-detector Firewall workers                               |


**Platform control plane**


| Workload            | Role                                                              |
| ------------------- | ----------------------------------------------------------------- |
| `control-plane-api` | Platform API                                                      |
| `control-plane-app` | Console web application; runs Prisma migrations and seed on start |
| `data-plane-api`    | Read and analytics API over ClickHouse                            |


**Analytics and alerting**


| Workload                                                         | Role                                                          |
| ---------------------------------------------------------------- | ------------------------------------------------------------- |
| `clickstack-collector` (values key `clickstack-otel-collector:`) | Receives product OTLP on 4317/4318, writes to ClickHouse      |
| `clickhouse`                                                     | Analytics store (StatefulSet, external mode only)             |
| `datacore`                                                       | Residency and analytics queries over landed telemetry         |
| `alertengine-api` / `alertengine-worker`                         | Rule evaluation, alert state, SIEM and integration forwarding |


**Datastores and setup** — all in-cluster by default, see [Datastores](#datastores)


| Workload                                     | Role                                        |
| -------------------------------------------- | ------------------------------------------- |
| `control-plane-postgresql`                   | PostgreSQL for every service that needs one |
| `redis`                                      | Shared cache and queue                      |
| `neuraltrust-platform-mcp-signing-key` (Job) | Generates the MCP signing key on install    |


Absent in external: `dataagent`, `dataagent-trustguard`, and the
`clickstack-egress-collector` sidecar. External never enrols a DataAgent, so
`global.products` is ignored — every component above renders regardless.

The analytics path is:

```text
OTLP senders -> ClickStack OTel Collector -> ClickHouse
                                            |-> DataCore
                                            `-> AlertEngine -> SIEM/integrations
```

AlertEngine is the supported detection, SIEM, and integration path for external
deployments. Disabling hosted observability export does not disable AlertEngine
or the ClickStack-to-ClickHouse pipeline. See
`[docs/observability.md](./docs/observability.md)`.

## Datastores

External mode uses PostgreSQL, Redis, **and** ClickHouse. All three deploy
in-cluster by default.

Unlike hybrid's single shared PostgreSQL role, each external service owns its own
database and migrations, named by the per-service `*.database.name` /
`*.database.user`. The **endpoint** is shared: since chart 2.6.0 an empty
per-service `host`, `port` or `sslMode` (and `host`, `port`, `username`, `tls`
under `*.redis`) inherits from `global.postgresql` / `global.redis` before
falling back to the in-cluster Service names. So a managed datastore is named
once:

```yaml
global:
  postgresql:
    deploy: false
    host: "postgres.example.com"
    port: "5432"
    sslMode: "require"
  redis:
    deploy: false
    host: "redis.example.com"
    tls: "true"

  clickhouse:
    host: "clickhouse.example.com"
    httpPort: "8443"
    nativePort: "9440"
    user: "neuraltrust"
    tls: true
    existingSecret:
      name: "managed-clickhouse"
      key: "password"

infrastructure:
  clickhouse:
    deploy: false
```

ClickHouse needs two ports because the consumers split by protocol: DataCore,
AlertEngine and watchdog speak the **native** protocol, while data-plane-api and
the ClickStack collector use **HTTP**. A managed endpoint that only exposes TLS
still needs both named — usually its TLS port for each.

`infrastructure.clickhouse.deploy: false` stops the in-cluster ClickHouse from
rendering; `global.clickhouse` says where to reach the real one. Both are needed.

> **Changed in 2.14:** the endpoint used to be named under
> `infrastructure.clickhouse.external`, which never worked — `.Values.infrastructure`
> is an umbrella key that no subchart can read, so three of the five consumers
> ignored it and kept dialling the in-cluster Service that `deploy: false` had just
> removed. That block is now inert, and setting it without a real endpoint elsewhere
> fails the render rather than misconfiguring the install silently.

Add a per-service `database:` / `redis:` / `clickhouse:` block only to send one
service somewhere else — it still takes precedence over the global.

The **passwords** need not live in a values file at all. Name a Secret you created
under `<service>.database.existingSecret` (or `.redis.existingSecret`) and the
chart omits that key from the Secret it renders, having each pod read yours
through a `secretKeyRef` instead — so the credential stays out of values and out
of Helm release history:

```yaml
agentgateway:
  database:
    existingSecret:
      name: "managed-postgres-roles"
      key: "AGENTGATEWAY" # key is configurable, so one Secret serves every role
```

An inline `password` alongside the hook is rejected at render.

Since chart 2.8.0 the control-plane role is covered too, by
`global.postgresql.passwordSecret` — the same shape, only global, and only
against a managed instance:

```yaml
global:
  postgresql:
    deploy: false
    host: "postgres.example.com"
    passwordSecret:
      name: "managed-postgres-roles"
      key: "CONTROL_PLANE"
```

The chart then writes every `postgresql-secrets` key except the password and the
Prisma URL, drops the connection-string environment entries entirely so a stale
URL cannot outrank your Secret, and `control-plane-app` assembles its own
connection from the parts — so the app image has to carry
`scripts/postgres-password-url.mjs`, which the migration step needs. With every
hook in place a managed external values file holds no credential at all. See
[Datastore credentials without values](./SECRETS.md#datastore-credentials-without-values).

Who creates the PostgreSQL roles and databases depends on whose instance it is:

- **The chart's own PostgreSQL** (`global.postgresql.deploy: true`, the default):
  since chart 2.7.0 a `control-plane-postgresql-bootstrap` Job creates each role
  with the password the service's Secret already holds, creates the database owned
  by it, and grants it the `public` schema. Nothing to pre-create, and nothing to
  replay after a password rotation — the Job re-aligns roles on every upgrade.
- **A managed instance**: pre-create every role and database yourself. The Job is
  not rendered when `global.postgresql.host` names another instance, when `deploy`
  is false, or under IAM auth, so the chart never issues DDL against an instance
  it does not own.

DataCore, AlertEngine, the ClickStack collector, and `data-plane-api` all read one
shared ClickHouse credential; point their `clickhouse.existingSecret` at your
secret when using a managed cluster. Complete pattern:
`[values-managed-datastores.yaml.example](./values-managed-datastores.yaml.example)`.

In-cluster ClickHouse defaults to a 50 GiB volume with a ~4 GiB memory request.
Size the volume for your retention window before first install.

## Air-gapped and disconnected clusters

```yaml
global:
  deploymentMode: "external"
  imageRegistry: "<registry>/neuraltrust"
  observability:
    hostedExport:
      enabled: false
```

Mirror **every** required image, including the ClickHouse and ClickStack
collector images. With hosted export and observability off, `imageRegistry`
rewrites the full external image set on its own — verify with
`helm template ... | grep image:`. If you enable `global.observability`, also
override `global.observability.collector.image.repository`; that one repository
is pinned in full and `imageRegistry` does not rewrite it.

Create the pull Secret for your mirror as `gcr-secret`, the name every component
defaults to. The umbrella collector keeps collecting locally, ClickStack keeps
writing to your ClickHouse, and AlertEngine keeps forwarding to destinations
reachable from the cluster.

The hybrid network allowlist in `[docs/hybrid-network.md](./docs/hybrid-network.md)`  
does **not** apply — external needs no outbound path to NeuralTrust.

## Platform and ingress

`global.platform` selects provider-specific ingress and security behavior
(`gcp`, `aws`, `azure`, `openshift`, `kubernetes`). On OpenShift, layer the
external overlay over the OpenShift values:

```bash
helm upgrade --install neuraltrust-platform <chart> \
  --namespace neuraltrust \
  -f values-openshift.yaml \
  -f values-external.yaml.example \
  --set global.domain=apps.example.com
```

See [README-OPENSHIFT.md](./README-OPENSHIFT.md) for Routes, wildcard Route
prerequisites, and Security Context Constraints.

## Optional components

- umbrella OTel Collector: portable cluster observability, separate from
ClickStack
- AlertEngine: set `alertengine.enabled: false` to omit rule evaluation and SIEM
forwarding

**Firewall is not optional** in external — it always deploys with TrustGuard and
cannot be switched off. The only choice is CPU workers (default) or GPU via
`[values-dataplane-gpu.yaml.example](./values-dataplane-gpu.yaml.example)`.

## Validate before rollout

```bash
helm lint <chart> -f values-external.yaml.example
helm template neuraltrust-platform <chart> \
  --namespace neuraltrust \
  -f values-external.yaml.example > /tmp/rendered-external.yaml
```

Add `--api-versions route.openshift.io/v1` when rendering for OpenShift.

## Upgrades

Generated secrets are reused through Helm `lookup`. Deployment engines that
cannot use `lookup` should pre-create secrets and set
`global.preserveExistingSecrets: true` — in external mode that requires
`AUTH_SECRET` and `NEXTAUTH_SECRET` to already exist in `control-plane-secrets`.
Persistent volume claims are retained by default. Review release notes before
each upgrade.

## Further reading

- [Hybrid quick start](./README.md#quick-start-hybrid)
- [OpenShift guide](./README-OPENSHIFT.md)
- [Deployment guide](./DEPLOYMENT.md)
- [Secrets management](./SECRETS.md)
- [Values scenarios](./VALUES_SCENARIOS.md)
- [Architecture and topology contract](./docs/architecture.md)
- [Observability and self-healing](./docs/observability.md)
- [Cluster sizing](./docs/sizing.md)
- Public docs: [External (self-hosted)](https://docs.neuraltrust.ai/neuraltrust/deployment/external) ·
[Deployment models](https://docs.neuraltrust.ai/neuraltrust/deployment/deployment-models) ·
[Configuration](https://docs.neuraltrust.ai/neuraltrust/deployment/configuration) ·
[Sizing](https://docs.neuraltrust.ai/neuraltrust/deployment/sizing)

---

**Looking for v1?** The legacy TrustGate/Kafka line ended at [v1.14.16](https://github.com/NeuralTrust/neuraltrust-platform/releases?page=3#release-v1.14.16) — install it with `--version ~1.14.0`.