# Observability and self-healing

The chart has two distinct OpenTelemetry collector roles.

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
DataAgent pod. The sidecar exchanges the DataAgent enrolment JWT for a
short-lived OTLP access token and exports to the hosted telemetry endpoint.
There is no direct bearer on apps and no hybrid opt-out
(`global.clickstack.enabled` / `egress.enabled` are rejected). Air-gapped or
local-only product telemetry requires `global.deploymentMode: external`.

The sidecar's destination is `https://telemetry.<domain>` where `<domain>` is
`global.controlPlane.domain` when set, otherwise the NeuralTrust host for
`global.saasRegion` (`telemetry.neuraltrust.ai` / `telemetry.us.neuraltrust.ai`).
Override a single install with `global.clickstack.egress.endpoint` or
`global.controlPlane.telemetryUrl`.

Watchdog follows the same topology with a **signal-neutral** `:4318` base
(products use a `/v1/logs` URL because their SDK uses `WithEndpointURL`). In
hybrid with a DataAgent egress Service, watchdog points at
`http://clickstack-egress-collector.<ns>.svc.cluster.local:4318` with no
`OPENTELEMETRY_AUTH_TOKEN`. Data-plane-only hybrid has no egress and therefore
no default watchdog OTLP endpoint — set `watchdog.telemetry.otlp.endpoint`
explicitly if needed.

## ClickStack OTel Collector

The ClickStack collector is an external-mode component, not a replacement
for the umbrella collector. It receives product OTLP on ports 4317/4318 and
writes traces, metrics, and logs to ClickHouse.

It never renders in hybrid mode (hybrid uses the DataAgent-co-located egress
sidecar above). In external mode, DataCore reads the landed telemetry and
AlertEngine evaluates rules over it.

Watchdog in external mode uses
`http://clickstack-collector.<ns>.svc.cluster.local:4318` and mounts
`OTEL_EXPORTER_OTLP_HEADERS` from `clickstack-collector-secrets` — the same
raw token the collector enforces. It does **not** default to
`collector.neuraltrust.ai` or `neuraltrust-observability-token`.

## AlertEngine SIEM and integrations

AlertEngine is the supported external-mode alert and integration path. Its
worker:

- evaluates configured detection rules over ClickHouse telemetry
- stores alert state in its PostgreSQL database
- deduplicates findings
- forwards findings to configured SIEM and integration destinations

Disabling hosted observability export does not disable AlertEngine or the
ClickStack-to-ClickHouse pipeline.

## Common overlays

- `values-observability-self-hosted.yaml.example`: umbrella collector and
  Prometheus Operator resources, hosted export off

To export straight to hosted observability without running the umbrella
collector, leave `global.observability.enabled: false` and keep
`global.observability.hostedExport.enabled: true`.

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

---

<sup>**Looking for v1?** The legacy TrustGate/Kafka line ended at [v1.14.16](https://github.com/NeuralTrust/neuraltrust-platform/releases?page=3#release-v1.14.16) — install it with `--version ~1.14.0`.</sup>
