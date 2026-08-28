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

In hybrid mode, product OTLP is always on for the **metadata** class.
AgentGateway and TrustGuard read exporters from
`TELEMETRY_EXPORTERS_METADATA` / `TELEMETRY_EXPORTERS_RAW` as named exporter
lists (no `telemetry.yaml` ConfigMap; requires TrustGate v0.37.0+ /
TrustGuard v0.37.1+). Hybrid is `otlp` / `postgres`: metadata goes as plain
OTLP to a local ClusterIP Service (`clickstack-egress-collector`) on the
DataAgent pod, and raw payloads stay in local Postgres for DataAgent. The
sidecar exchanges the DataAgent enrolment JWT for a short-lived OTLP access
token and exports to the hosted (or customer-central) telemetry endpoint.
There is no hybrid raw-OTLP dual-write and no hybrid opt-out
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

## What detects a failure, and what only forwards signals

The chart ships **two independent detection mechanisms**, and both are **off by
default**. Knowing which one you are relying on matters, because they need
different things from you.

| | Mechanism | Switch (default) | Requires | Provides |
|---|---|---|---|---|
| 1 | `PrometheusRule` objects (`charts/*/templates/monitoring.yaml`) | `global.monitoring.enabled` (**false**) | a Prometheus Operator **you** run, with the `monitoring.coreos.com/v1` CRD | alert rules only — no evaluation, no delivery |
| 2 | watchdog checks (`charts/watchdog`) | `watchdog.enabled` (**false**) | a reachable ClickHouse via `watchdog.runner.clickstack` | detection, paging, and self-healing |

Mechanism 1 is an *integration*: the chart writes rule objects and your
Prometheus evaluates and routes them. Nothing in the chart evaluates them, and
they render only when the CRD exists, so on a cluster without the operator they
silently do not appear.

Mechanism 2 is the NeuralTrust-native path. It works in every deployment mode
because every mode either has a ClickHouse or ships its telemetry to one. It is
also the only mechanism that can restart a workload.

**A default install has no alerting from either path.** If you want alerting,
enable one deliberately. For most operators mechanism 2 is the better default —
it needs no extra infrastructure. Set:

```yaml
watchdog:
  enabled: true
  runner:
    clickstack:
      address: "clickhouse:9000"   # external / saas; hybrid has no local ClickHouse
      database: otel
```

In `hybrid` there is no in-cluster ClickHouse, so RED and freshness checks cannot
run locally — that telemetry reaches the NeuralTrust sink and is evaluated
centrally instead. Direct probe checks still work locally.

### Overlap is deliberate but narrow

Where both mechanisms cover the same condition, watchdog owns it. Deployment
liveness is the example: watchdog's `v2-deployment-health` check already covers
`agentgateway-proxy`, `trustguard-data-plane` and `data-plane-api`, and the
matching `PrometheusRule` alerts exist for operators whose paging already runs
through Prometheus. Enabling both simply gives you two notifications.

## Process self-observability by service and mode

This is telemetry about the *processes* — traces and metrics for troubleshooting
— and is distinct from the product event stream (`TELEMETRY_EXPORTERS_*`), which
carries evaluation results and is always on.

Verified against a live external/saas cluster and a live hybrid cluster:

| Service | Wired in external / saas | Wired in hybrid | Actually emitting |
|---|---|---|---|
| trustguard | yes — `OPENTELEMETRY_ENABLED=true` + traces/metrics endpoints | **no** — service name only | **yes**, the only one |
| agentgateway | product-event OTLP only | product-event OTLP only | no |
| firewall | `OTEL_ENABLED=false` | `OTEL_ENABLED=false` | no |
| control-plane-api / app | only if an endpoint is set (see below) | n/a | no |
| data-plane-api | only if an endpoint is set (see below) | only if set | no |
| datacore, databridge, alertengine, trustlens, dataagent | not wired | not wired | no |

Two mechanisms decide this, which is why the result is uneven:

* `agentgateway` and `trustguard` **derive** the in-cluster collector
  (`http://clickstack-collector.<namespace>.svc.cluster.local:4318`) in external
  mode, so they are wired with no operator input.
* `control-plane-api`, `control-plane-app`, `data-plane-api` and `firewall` wire
  OTel **only when `global.observability.collector.endpoint` is set**. It has no
  default and `global.observability.enabled` is `false`, so out of the box their
  OTel ConfigMaps do not render at all.

If you want process telemetry from those services on a cluster running the
in-cluster ClickStack collector, set the endpoint explicitly:

```yaml
global:
  observability:
    collector:
      endpoint: "http://clickstack-collector.<namespace>.svc.cluster.local:4318"
```

Self-observability is only worth enabling when something consumes it — watchdog
RED and saturation checks, or your own dashboards. With `watchdog.enabled: false`
and no Prometheus, leaving it off is a reasonable choice rather than a gap.

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
