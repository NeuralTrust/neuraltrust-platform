# Values Files and Scenarios

This chart (2.x) is v2-only.

## Core examples

| File | Mode | Purpose |
|---|---|---|
| `values-required.yaml` | hybrid | Minimal starting point; DataAgent disabled until enrolment |
| `values-v2.yaml.example` | hybrid | Documented hybrid knobs |
| `values-v2-hybrid.yaml.example` | hybrid | Hybrid topology overlay |
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
  clickstack:
    existingSecret:
      name: "clickstack-otlp"
      # key defaults to OTEL_EXPORTER_OTLP_HEADERS

dataagent:
  tenantId: ""
  enrolmentTokenExistingSecret:
    name: ""
    key: "ENROLMENT_TOKEN"
```

ClickStack is mandatory for hybrid render unless
`global.clickstack.enabled: false`. For SaaS-managed hybrid, also enable
config-sync via `existingSecret` references (see
`values-v2-hybrid.yaml.example`).

Enable DataAgent only after enrolment (`tenantId` plus token or
`enrolmentTokenExistingSecret.name`):

```yaml
dataagent:
  tenantId: "<tenant-id>"
  enrolmentTokenExistingSecret:
    name: "dataagent-enrolment"
    key: "ENROLMENT_TOKEN"
```

## Scenario: self-hosted external

```yaml
global:
  deploymentMode: "external"
  observability:
    hostedExport:
      enabled: false

alertengine:
  enabled: true
```

External mode renders ClickStack, DataCore, AlertEngine, the product API/app,
and the control and data planes. It does not render DataAgent.

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
