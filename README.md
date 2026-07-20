# NeuralTrust Platform

Deploy NeuralTrust on Kubernetes with one Helm umbrella chart. This chart
(2.x) is v2-only; `hybrid` mode is the default operator path.

## Default topology: hybrid

Hybrid keeps control-plane services in NeuralTrust SaaS and runs the data path
in your cluster:

- AgentGateway proxy and MCP runtimes
- TrustGuard runtime
- the temporary data-plane API read shim (PostgreSQL-backed by default; no ClickHouse required)
- PostgreSQL and Redis by default (no in-cluster ClickHouse in hybrid)
- NeuralTrust Firewall when enabled
- DataAgent only after the deployment is enrolled

Hybrid dual-writes AgentGateway and TrustGuard product telemetry via a local
`clickstack-egress-collector`: apps send plain OTLP in-cluster; the egress
collector exchanges the DataAgent enrolment JWT at DataCore for a short-lived
OTLP access token and forwards to SaaS. There is no direct SaaS ClickStack
bearer-token path. Hybrid ClickStack therefore requires DataAgent enrolment
(`dataagent.enrolmentToken` or `enrolmentTokenExistingSecret`). Set
`global.clickstack.enabled: false` for air-gap. For SaaS-managed hybrid,
enable `agentgateway.configSync` and `trustguard.configSync` separately
(defaults `enabled: false`); prefer `existingSecret.name` Secrets that hold
both `CONFIG_SYNC_TOKEN` and `CONFIG_SYNC_LKG_KEY`. See
[`docs/platform-v2.md`](./docs/platform-v2.md) and
[`values-v2-hybrid.yaml.example`](./values-v2-hybrid.yaml.example).

DataAgent renders when `tenantId` and either `enrolmentToken` or
`enrolmentTokenExistingSecret.name` are set (also required for hybrid
ClickStack egress). Prefer the existing-Secret path so the token never enters
Helm values. With a complete enrolment, it makes an outbound TLS connection to
DataBridge; it exposes no operator-facing ingress.

In external deployments, AlertEngine provides the supported detection, SIEM,
and integration path.

## Self-hosted topology: external

Set `global.deploymentMode: external` for a self-hosted deployment. It adds:

- AgentGateway and TrustGuard control planes
- the product API and web application
- ClickStack OTel Collector writing OTLP telemetry to ClickHouse
- DataCore for residency queries
- AlertEngine for rule evaluation and SIEM/integration forwarding

ClickStack is external-mode only. DataAgent never runs in external mode.
Disable `global.observability.hostedExport.enabled` when the deployment must
have no SaaS telemetry egress.

## Quick start

```bash
helm upgrade --install neuraltrust-platform \
  oci://europe-west1-docker.pkg.dev/neuraltrust-app-prod/helm-charts/neuraltrust-platform \
  --version <VERSION> \
  --namespace neuraltrust --create-namespace \
  -f values-required.yaml
```

`values-required.yaml` is the minimal hybrid starting point. Set the cloud
provider, domain, and DataAgent enrolment (powers DataBridge and ClickStack
egress):

```yaml
global:
  deploymentMode: "hybrid"
  platform: "kubernetes"
  domain: "platform.example.com"

dataagent:
  tenantId: "<tenant-id>"
  enrolmentTokenExistingSecret:
    name: "dataagent-enrolment"
    key: "ENROLMENT_TOKEN"
```

Secrets are generated on first install and reused on upgrades when
`global.autoGenerateSecrets: true`. Production deployments may instead
reference pre-created Kubernetes Secrets; see [SECRETS.md](./SECRETS.md).

## Deployment modes

| Mode | SaaS control plane | Workloads in cluster | Analytics path |
|---|---:|---|---|
| `hybrid` (default) | Yes | AgentGateway data plane, TrustGuard data plane, data-plane API shim (PostgreSQL) | Analytics in SaaS via mandatory ClickStack OTLP; optional enrolled DataAgent bridges entitled reads. No in-cluster ClickHouse |
| `external` | No | Control and data planes, product API/app, DataCore, AlertEngine | ClickStack OTel Collector writes to ClickHouse; data-plane API shim reads ClickHouse |

## Datastores

The chart deploys PostgreSQL and Redis in-cluster by default in both modes;
in-cluster ClickHouse renders only in `external` (hybrid keeps analytics in SaaS
and runs the data-plane API shim on PostgreSQL). Each can be replaced with a
managed service:

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

Use [`values-v2-managed-datastores.yaml.example`](./values-v2-managed-datastores.yaml.example)
for the complete endpoint and existing-secret pattern.

In **hybrid**, AgentGateway, TrustGuard, DataAgent, and the `data-plane-api`
read shim share ONE PostgreSQL role owning ONE database, driven by
`global.postgresql` (defaults: user `neuraltrust`, database `neuraltrust`).
The chart renders shared `postgresql-secrets` and `redis-secrets` (from
`global.redis`) that every hybrid workload `envFrom`'s. There is no
chart-managed init Job — application migrations own their tables.

In **external**, runtime services use per-service `*.database` / `*.redis`
overlays. `global.postgresql` still gates in-cluster PostgreSQL and feeds
control-plane `postgresql-secrets` for control-plane-api/app. For managed
PostgreSQL, set `global.postgresql.deploy: false` and point the chart at
host/user/password (or `global.postgresql.existingSecret.name`). See
[`docs/platform-v2.md`](./docs/platform-v2.md) for the full contract.

## Platform and ingress

`global.platform` selects provider-specific ingress and security behavior:

| Value | Target |
|---|---|
| `gcp` | GKE / GCE Ingress |
| `aws` | EKS / AWS Load Balancer Controller |
| `azure` | AKS / Application Gateway |
| `openshift` | OpenShift Routes or Ingress |
| `kubernetes` | Generic Kubernetes |

Set `global.domain` to derive service hostnames. Set
`global.imageRegistry` to mirror all images into a private registry.

## Supported optional components

- `firewall`: prompt and response safety, with CPU or GPU workers
- `trustlens`: analytics/inventory service; still opt-in while WIP
- `watchdog`: dry-run-first self-monitoring and self-healing (stable Kubernetes name `neuraltrust-watchdog`)
- umbrella OTel Collector: portable cluster observability
- AlertEngine: external-mode alert evaluation and SIEM/integration forwarding

## Values examples

| File | Purpose |
|---|---|
| `values-required.yaml` | Minimal hybrid |
| `values-v2.yaml.example` | Documented hybrid overlay |
| `values-v2-hybrid.yaml.example` | Hybrid topology overlay |
| `values-v2-external.yaml.example` | Minimal self-hosted external |
| `values-all-deployed.yaml.example` | External with supported optional components |
| `values-v2-managed-datastores.yaml.example` | Managed PostgreSQL, Redis, and ClickHouse |
| `values-openshift.yaml` | Hybrid on OpenShift Routes |
| `values-openshift-ingress.yaml.example` | Hybrid on OpenShift Ingress |
| `values-dataplane-gpu.yaml.example` | Hybrid with GPU Firewall workers |
| `values-aws-ipv6.yaml.example` | Hybrid AWS/IPv6 overlay |
| `values-minimal-observability.yaml.example` | hosted observability without the in-chart collector |
| `values-observability-self-hosted.yaml.example` | local-only observability |
| `values-self-monitoring.yaml.example` | watchdog and curated checks |

## Legacy v1

v1 (legacy TrustGate/Kafka) is maintained only on the `v1.14.x` release line;
pin `--version ~1.14.0` to install it. This chart (2.x) is v2-only.

## Further reading

- [Deployment guide](./DEPLOYMENT.md)
- [Platform v2 architecture](./docs/platform-v2.md)
- [Values scenarios](./VALUES_SCENARIOS.md)
- [OpenShift guide](./README-OPENSHIFT.md)
- [Observability and self-healing](./docs/observability.md)
- [Secrets management](./SECRETS.md)

## License

Apache License 2.0
