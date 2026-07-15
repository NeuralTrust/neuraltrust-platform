# Values Files and Scenarios

All new deployments should start with Platform v2. Platform v1 examples are
explicitly marked legacy.

## Core examples

| File | Platform | Mode | Purpose |
|---|---|---|---|
| `values-required.yaml` | v2 | hybrid | Minimal starting point; DataAgent disabled until enrolment |
| `values-v2.yaml.example` | v2 | hybrid | Documented hybrid knobs |
| `values-v2-external.yaml.example` | v2 | external | Minimal self-hosted topology |
| `values-all-deployed.yaml.example` | v2 | external | Supported optional components enabled |
| `values-v2-managed-datastores.yaml.example` | v2 | external | Managed PostgreSQL, Redis, and ClickHouse |
| `values-v1-legacy.yaml.example` | v1 | legacy | Explicit legacy topology |
| `values-external-services.yaml.example` | v1 | legacy | Legacy external PostgreSQL, ClickHouse, and Kafka |

## Platform overlays

| File | Applies to | Notes |
|---|---|---|
| `values-openshift.yaml` | v2 hybrid | Native OpenShift Routes |
| `values-openshift-ingress.yaml.example` | v2 hybrid | Kubernetes Ingress on OpenShift |
| `values-aws-ipv6.yaml.example` | v2 hybrid | AWS provider and IPv6-safe v2 defaults |
| `values-dataplane-gpu.yaml.example` | v2 hybrid | GPU Firewall workers |

## Observability overlays

| File | Purpose |
|---|---|
| `values-minimal-observability.yaml.example` | Watchdog sends redacted telemetry directly to hosted observability |
| `values-observability-self-hosted.yaml.example` | Umbrella OTel Collector and monitoring resources with hosted export off |
| `values-self-monitoring.yaml.example` | Curated v2 watchdog checks, dry-run first |
| `values-watchdog.yaml.example` | Detailed v2 watchdog configuration |
| `values-watchdog-gmp.yaml.example` | Google Managed Prometheus resources |

The umbrella OTel Collector is portable across hybrid and external. The
ClickStack OTel Collector is a product analytics component and only renders in
v2 external.

## Scenario: default v2 hybrid

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

Enable DataAgent only after enrolment:

```yaml
dataagent:
  tenantId: "<tenant-id>"
  enrolmentToken: "<enrolment-token>"
```

## Scenario: self-hosted v2 external

```yaml
global:
  platformVersion: "v2"
  deploymentMode: "external"
  observability:
    hostedExport:
      enabled: false

alertengine:
  enabled: true
```

External mode renders ClickStack, DataCore, AlertEngine, the product API/app,
and the v2 control and data planes. It does not render DataAgent.

## Scenario: managed datastores

```yaml
infrastructure:
  postgresql:
    deploy: false
  redis:
    deploy: false
  clickhouse:
    deploy: false
  kafka:
    deploy: false
```

Use existing secrets and generic service endpoints as shown in
`values-v2-managed-datastores.yaml.example`. Pre-create PostgreSQL roles and
databases because the in-cluster initialization Job is skipped.

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

Pin v1 explicitly:

```yaml
global:
  platformVersion: "v1"
```

Only v1 supports legacy TrustGate, Kafka, Kafka Connect, Kafka workers, and the
scheduler. Kafka never runs in v2. AISPM and SIEM Connector components are
retired; AlertEngine in v2 external preserves the supported SIEM and integration
workflow.
