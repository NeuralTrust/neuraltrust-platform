# Observability and self-healing

This chart (2.x) is v2-only. It has two distinct OpenTelemetry collector roles.

## Umbrella OTel Collector

The umbrella collector is controlled by `global.observability.*` and is
available in hybrid and external modes. It receives component OTLP, scrapes
supported Prometheus endpoints, collects Kubernetes signals, redacts sensitive
payload attributes, and can export to hosted observability.

For local-only collection:

```yaml
global:
  observability:
    enabled: true
    hostedExport:
      enabled: false
```

The chart does not install Prometheus or Grafana. When
`global.monitoring.enabled: true` and the cluster exposes the matching CRDs,
the chart renders ServiceMonitor, PodMonitor, and PrometheusRule resources.

## Hybrid ClickStack OTLP egress (mandatory)

In hybrid mode, product OTLP is always on. AgentGateway and TrustGuard send
plain OTLP to a local ClusterIP Service (`clickstack-egress-collector`) on the
DataAgent pod. The sidecar exchanges the DataAgent enrolment JWT at DataCore
for a short-lived OTLP access token and forwards to SaaS. There is no direct
SaaS bearer on apps and no hybrid opt-out (`global.clickstack.enabled` /
`egress.enabled` are rejected). Air-gapped or local-only product telemetry
requires `global.deploymentMode: external`.

## ClickStack OTel Collector

The ClickStack collector is an external-mode component, not a replacement
for the umbrella collector. It receives product OTLP on ports 4317/4318 and
writes traces, metrics, and logs to ClickHouse.

It never renders in hybrid mode (hybrid uses the DataAgent-co-located egress
sidecar above). In external mode, DataCore reads the landed telemetry and
AlertEngine evaluates rules over it.

## AlertEngine SIEM and integrations

AlertEngine is the supported external-mode alert and integration path. Its
worker:

- evaluates configured detection rules over ClickHouse telemetry
- stores alert state in its PostgreSQL database
- deduplicates findings
- forwards findings to configured SIEM and integration destinations

Disabling hosted observability export does not disable AlertEngine or the
ClickStack-to-ClickHouse pipeline.

## Watchdog

`watchdog` (stable Kubernetes name `neuraltrust-watchdog`) provides direct
probes and optional healing actions. Start with every action in dry-run:

```yaml
watchdog:
  enabled: true
  actions:
    dryRun: true
```

Use checks that target rendered or shared resources, such as ClickHouse, the
data-plane API shim, Firewall, pod health, deployment health, certificate
renewal, and the umbrella collector.

Promote healing actions one check at a time after observing alert parity.
Mutating actions require both `actions.dryRun: false` and the corresponding
RBAC action permission.

## Common overlays

- `values-minimal-observability.yaml.example`: watchdog sends redacted telemetry
  directly to hosted observability; umbrella collector stays off
- `values-observability-self-hosted.yaml.example`: umbrella collector and
  Prometheus Operator resources, hosted export off
- `values-self-monitoring.yaml.example`: curated check identifiers
- `values-watchdog.yaml.example`: detailed dry-run-first configuration
- `values-watchdog-gmp.yaml.example`: Google Managed Prometheus resources

## Air-gapped external deployment

Use external mode, disable hosted export, and mirror all images:

```yaml
global:
  deploymentMode: "external"
  imageRegistry: "<registry>/neuraltrust"
  observability:
    hostedExport:
      enabled: false
```

The umbrella collector remains local. ClickStack continues writing to the
configured local or managed ClickHouse. AlertEngine continues evaluating and
forwarding to destinations reachable from the cluster.

## Legacy v1

v1 (legacy TrustGate/Kafka) is maintained only on the `v1.14.x` release line;
pin `--version ~1.14.0` to install it. This chart (2.x) is v2-only.
