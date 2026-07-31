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
| Config-sync             | On by default, needs console tokens                | Off — configuration lives in PostgreSQL                   |
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

infrastructure:
  clickhouse:
    deploy: false
    external:
      host: "clickhouse.example.com"
      port: "8443"
      secretName: "managed-clickhouse"
      secretKey: "password"
```

Add a per-service `database:` / `redis:` block only to send one service somewhere
else — it still takes precedence. ClickHouse has no global block, so its endpoint
is named per consumer.

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

An inline `password` alongside the hook is rejected at render. The one credential
this cannot cover is the control-plane role in `global.postgresql.password`, which
the chart bakes into the Prisma and telemetry connection strings while rendering.
See [Datastore credentials without values](./SECRETS.md#datastore-credentials-without-values).

Pre-create every PostgreSQL role and database before installing — there is no
chart-managed init Job. DataCore, AlertEngine, the ClickStack collector, and
`data-plane-api` all read one shared ClickHouse credential; point their
`clickhouse.existingSecret` at your secret when using a managed cluster. Complete
pattern: `[values-managed-datastores.yaml.example](./values-managed-datastores.yaml.example)`.

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