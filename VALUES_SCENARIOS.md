# Values Files and Scenarios

This chart (2.x) is v2-only.

## Core examples

| File | Mode | Purpose |
|---|---|---|
| `values-required.yaml` | hybrid | Full-hybrid preset (all three products on) + enrolment / config-sync Secrets |
| `values-v2.yaml.example` | hybrid | Documented hybrid knobs |
| `values-v2-hybrid.yaml.example` | hybrid | Hybrid topology overlay |
| `values-trustgate.yaml.example` | hybrid | Positive TrustGate + DataAgent slice |
| `values-trustguard.yaml.example` | hybrid | Positive TrustGuard + Firewall + DataAgent slice |
| `values-red-teaming.yaml.example` | hybrid | Positive data-plane-api-only slice |
| `values-v2-external.yaml.example` | external | Minimal self-hosted topology |
| `values-all-deployed.yaml.example` | external | Supported optional components enabled |
| `values-v2-managed-datastores.yaml.example` | external | Managed PostgreSQL, Redis, and ClickHouse |

## Platform overlays

| File | Applies to | Notes |
|---|---|---|
| `values-openshift.yaml` | hybrid | Native OpenShift Routes |
| `values-openshift-ingress.yaml.example` | hybrid | Kubernetes Ingress on OpenShift |
| `values-aws-ipv6.yaml.example` | hybrid | AWS provider and IPv6-safe defaults |
| `values-dataplane-gpu.yaml.example` | hybrid | GPU Firewall workers |

AgentGateway dual discovery (exact host + header, or `*.llm` / `*.mcp` slug
with no header) is the chart default — no overlay is required. See
[docs/platform-v2.md](./docs/platform-v2.md).

## Observability overlays

| File | Purpose |
|---|---|
| `values-minimal-observability.yaml.example` | Watchdog sends redacted telemetry directly to hosted observability |
| `values-observability-self-hosted.yaml.example` | Umbrella OTel Collector and monitoring resources with hosted export off |
| `values-self-monitoring.yaml.example` | Curated watchdog checks, dry-run first |
| `values-watchdog.yaml.example` | Detailed watchdog configuration |
| `values-watchdog-gmp.yaml.example` | Google Managed Prometheus resources |

The umbrella OTel Collector is portable across hybrid and external. The
ClickStack OTel Collector is a product analytics component and only renders in
external mode.

## Scenario: default hybrid

```yaml
global:
  deploymentMode: "hybrid"
  platform: "kubernetes"
  domain: "platform.example.com"

agentgateway:
  configSync:
    existingSecret:
      name: "agentgateway-config-sync"
  dataagent:
    enrolment:
      existingSecret:
        name: "dataagent-enrolment-trustgate"

trustguard:
  configSync:
    existingSecret:
      name: "trustguard-config-sync"
  dataagent:
    enrolment:
      existingSecret:
        name: "dataagent-enrolment-trustguard"
```

Hybrid product OTLP is mandatory (enrolment-backed egress collector; no
`global.clickstack.enabled` / `egress.enabled` opt-out). Air-gapped or
local-only product telemetry requires `global.deploymentMode: external`.
Config-sync is on by default — overlays set `existingSecret` only (see
`values-v2-hybrid.yaml.example`). Set `configSync.enabled: false` only for
Postgres-managed configuration.

## Scenario: self-hosted external

```yaml
global:
  deploymentMode: "external"
  superadmin:
    existingSecret:
      name: "onprem-superadmin"
  observability:
    hostedExport:
      enabled: false

alertengine:
  enabled: true
```

External mode renders ClickStack, DataCore, AlertEngine, the product API/app,
and the control and data planes. It does not render DataAgent. Bootstrap
admin: prefer `global.superadmin.existingSecret.name` pointing at a
pre-created Secret; inline `email` + `password` still works but enters Helm
release history.

## Scenario: managed datastores

```yaml
global:
  deploymentMode: "external"
  postgresql:
    deploy: false
  redis:
    deploy: false

infrastructure:
  clickhouse:
    deploy: false
```

Use existing secrets and generic service endpoints as shown in
`values-v2-managed-datastores.yaml.example`. Pre-create the PostgreSQL role
and database — there is no chart-managed database init Job. In external mode,
runtime services use per-service `*.database` / `*.redis` overlays;
`global.postgresql` still gates in-cluster PG and feeds control-plane
`postgresql-secrets`.

## Scenario: OpenShift

Use `values-openshift.yaml` for Routes:

```bash
helm upgrade --install neuraltrust-platform <chart> \
  --namespace neuraltrust --create-namespace \
  -f values-openshift.yaml \
  --set global.domain=apps.example.com
```

Use `values-openshift-ingress.yaml.example` when an Ingress controller and
certificate Secret are managed separately.

## Scenario: GPU Firewall

Layer `values-dataplane-gpu.yaml.example` over `values-required.yaml`. Replace
the generic image registry and scheduling labels with values for the GPU pool.
The gateway remains CPU-only; workers request GPUs.

## Scenario: no hosted telemetry egress

Layer `values-observability-self-hosted.yaml.example`. This disables hosted
export while retaining the umbrella collector, Prometheus Operator resources
when CRDs are available, and optional watchdog actions.

In external mode, the ClickStack collector still writes product telemetry to
the selected ClickHouse instance; it does not export to NeuralTrust SaaS.

## Legacy v1

v1 (legacy TrustGate/Kafka) is maintained only on the `v1.14.x` release line;
pin `--version ~1.14.0` to install it. This chart (2.x) is v2-only.
