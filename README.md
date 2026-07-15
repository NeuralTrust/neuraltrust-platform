# NeuralTrust Platform

Deploy NeuralTrust on Kubernetes with one Helm umbrella chart. Platform v2 in
`hybrid` mode is the default operator path.

## Default topology: v2 hybrid

Hybrid keeps control-plane services in NeuralTrust SaaS and runs the data path
in your cluster:

- AgentGateway proxy and MCP runtimes
- TrustGuard runtime
- the temporary data-plane API read shim (PostgreSQL-backed by default; no ClickHouse required)
- PostgreSQL and Redis by default (no in-cluster ClickHouse in hybrid)
- NeuralTrust Firewall when enabled
- DataAgent only after the deployment is enrolled

DataAgent is not required to install the platform. It is omitted until
NeuralTrust provides both a tenant identifier and enrolment token. With a
complete enrolment, it makes an outbound TLS connection to DataBridge; it
exposes no operator-facing ingress.

Kafka never renders under Platform v2. The v1 AISPM and SIEM Connector
subcharts are retired. In v2 external deployments, AlertEngine provides the
supported detection, SIEM, and integration path.

## Self-hosted topology: v2 external

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

`values-required.yaml` is the minimal v2-hybrid starting point. Set the cloud
provider and domain, then enable DataAgent only after enrolment:

```yaml
global:
  platformVersion: "v2"
  deploymentMode: "hybrid"
  platform: "kubernetes"
  domain: "platform.example.com"

dataagent:
  tenantId: ""
  enrolmentToken: ""
```

Secrets are generated on first install and reused on upgrades when
`global.autoGenerateSecrets: true`. Production deployments may instead
reference pre-created Kubernetes Secrets; see [SECRETS.md](./SECRETS.md).

## Deployment modes

| Mode | SaaS control plane | Workloads in cluster | Analytics path |
|---|---:|---|---|
| `hybrid` (default) | Yes | AgentGateway data plane, TrustGuard data plane, data-plane API shim (PostgreSQL) | Analytics in SaaS; optional enrolled DataAgent bridges entitled reads. No in-cluster ClickHouse |
| `external` | No | Control and data planes, product API/app, DataCore, AlertEngine | ClickStack OTel Collector writes to ClickHouse; data-plane API shim reads ClickHouse |

`full` remains a deprecated alias for `external`. New configuration must use
`external`.

## Datastores

Platform v2 deploys PostgreSQL and Redis in-cluster by default in both modes;
in-cluster ClickHouse renders only in `external` (hybrid keeps analytics in SaaS
and runs the data-plane API shim on PostgreSQL). Each can be replaced with a
managed service:

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
    deploy: false # explicit documentation; Kafka is always absent in v2
```

Use [`values-v2-managed-datastores.yaml.example`](./values-v2-managed-datastores.yaml.example)
for the complete endpoint and existing-secret pattern.

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

- `neuraltrust-firewall`: prompt and response safety, with CPU or GPU workers
- `trustlens`: v2 analytics/inventory service; still opt-in while WIP
- `neuraltrust-watchdog`: dry-run-first self-monitoring and self-healing
- umbrella OTel Collector: portable cluster observability
- AlertEngine: external-mode alert evaluation and SIEM/integration forwarding

## Values examples

| File | Purpose |
|---|---|
| `values-required.yaml` | Minimal v2 hybrid |
| `values-v2.yaml.example` | Documented v2 hybrid overlay |
| `values-v2-external.yaml.example` | Minimal self-hosted v2 external |
| `values-all-deployed.yaml.example` | v2 external with supported optional components |
| `values-v2-managed-datastores.yaml.example` | v2 with managed PostgreSQL, Redis, and ClickHouse |
| `values-openshift.yaml` | v2 hybrid on OpenShift Routes |
| `values-openshift-ingress.yaml.example` | v2 hybrid on OpenShift Ingress |
| `values-dataplane-gpu.yaml.example` | v2 hybrid with GPU Firewall workers |
| `values-aws-ipv6.yaml.example` | v2 hybrid AWS/IPv6 overlay |
| `values-minimal-observability.yaml.example` | hosted observability without the in-chart collector |
| `values-observability-self-hosted.yaml.example` | local-only observability |
| `values-self-monitoring.yaml.example` | v2 watchdog and curated checks |
| `values-v1-legacy.yaml.example` | explicit legacy v1 |
| `values-external-services.yaml.example` | legacy v1 with external datastores and Kafka |

## Legacy v1

Platform v1 is supported for upgrades but is no longer the default path. Pin it
explicitly:

```yaml
global:
  platformVersion: "v1"
```

Only v1 can deploy legacy TrustGate, Kafka workers/Kafka Connect, the scheduler,
and in-cluster or external Kafka. AISPM and the SIEM Connector subcharts are
retired and should not be used for new deployments.

Live upgrades with detected v1 workloads fail closed unless v1 is pinned or the
operator explicitly sets `global.confirmV2Migration: true`. Complete the staged
migration checklist in [Platform v2 architecture](./docs/platform-v2.md) before
authorizing replacement.

## Further reading

- [Deployment guide](./DEPLOYMENT.md)
- [Platform v2 architecture](./docs/platform-v2.md)
- [Values scenarios](./VALUES_SCENARIOS.md)
- [OpenShift guide](./README-OPENSHIFT.md)
- [Observability and self-healing](./docs/observability.md)
- [Secrets management](./SECRETS.md)

## License

Apache License 2.0
