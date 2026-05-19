# Changelog

All notable changes to the `neuraltrust-platform` umbrella chart are tracked in this file. The chart follows semantic versioning at the chart level (`Chart.yaml#version`).

## [Unreleased]

### Added

- **`neuraltrust-watchdog` subchart** (default `enabled: false`). Long-running Go service that periodically probes platform components (TrustGate, Control Plane, Data Plane, Firewall, ClickHouse, Kafka, Kafka Connect, Postgres, Redis) and emits OTel events + Prometheus metrics. Optionally restarts Deployments / Kafka Connect tasks behind a `dryRun` flag. See [`charts/neuraltrust-watchdog/README.md`](charts/neuraltrust-watchdog/README.md).
- **In-chart OpenTelemetry Collector** (`templates/otel-collector/`, default `global.observability.enabled: true`). Exports cluster + component telemetry to `collector.neuraltrust.ai` with payload redaction. Gracefully degrades to a local-only collector when no token is configured — installs never break in air-gapped clusters.
- **Optional `global.monitoring.enabled` flag**. When the cluster ships `monitoring.coreos.com/v1` CRDs (Prometheus Operator), every subchart renders a `PrometheusRule` (and TrustGate / OTel Collector additionally render `PodMonitor`/`ServiceMonitor`). Default OFF.
- **`global.observability.collector.endpoint`** umbrella override. Set once and every subchart (TrustGate, Firewall, AISPM) routes OTLP to that endpoint without per-subchart edits. Defaults preserved for upgrades.
- **HTTP liveness + readiness probes** on `control-plane-app` and `control-plane-scheduler`. Default ON; opt out per component via `controlPlane.components.<name>.healthProbes.enabled: false` for older images that don't expose `/health`.
- **Optional `PodDisruptionBudget`s** for every Control Plane Deployment, gated per component (`controlPlane.components.<name>.podDisruptionBudget.enabled: true`). Default OFF; only renders when `replicaCount > 1`.
- **Hardened ClickHouse backup CronJob**. Adds `set -euo pipefail`, `activeDeadlineSeconds`, and synchronous BACKUP by default (operators can re-enable ASYNC fire-and-forget via `dataPlane.components.clickhouse.backup.failOnError: false`). The Job now fails loudly on a server-side ClickHouse error instead of always exiting 0.
- **Helm render assertions** (`scripts/test-helm-render.sh`, `.github/workflows/helm-render-tests.yml`) covering: graceful degradation of the hosted exporter, payload redaction processors, watchdog rendering, monitoring CRD gating, and TrustGate/Firewall/AISPM endpoint flipping.
- **Docs**: [`docs/observability.md`](docs/observability.md) (rollout / dry-run / per-check cutover) and the companion [`cloud-infrastructure/docs/alerts-migration.md`](../cloud-infrastructure/docs/alerts-migration.md).
- **Example values**: `values-observability-self-hosted.yaml.example` (in-chart Collector + own Alertmanager) and `values-watchdog.yaml.example` (watchdog standalone with safe defaults).

### Changed

- TrustGate's `OPENTELEMETRY_ENABLED` auto-flips to `true` when `global.observability.collector.endpoint` is set; legacy off-by-default behaviour preserved otherwise.
- Firewall and AISPM ConfigMaps prefer `global.observability.collector.endpoint` over their per-subchart defaults. No behaviour change when the global override is unset.
- OTel Collector internal telemetry (`address: 0.0.0.0:8888`) is now exposed via the Collector Service so existing Prometheus Operator installs can scrape collector internals.
- **Fixed**: TrustGate's OTel endpoint ConfigMap now emits the only env names TrustGate-EE actually reads — `OPENTELEMETRY_TRACES_ENDPOINT` and `OPENTELEMETRY_METRICS_ENDPOINT` (`internal/config/config.go`). The previously written `OPENTELEMETRY_ENDPOINT` / `OPENTELEMETRY_OTLP_ENDPOINT` keys were never consumed by the binary and have been removed (safe because no customer is on TrustGate OTel yet). Without this fix TrustGate's OTLP egress was silently a no-op even when the umbrella endpoint was set.
- Control Plane (`api`, `app`) and Data Plane (`api`, `worker`) subcharts now ship an `<component>-otel` ConfigMap that emits `OTEL_ENABLED`, `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_SERVICE_NAME`, `OTEL_ENVIRONMENT` whenever `global.observability.collector.endpoint` is resolved. Each Deployment auto-`envFrom`s the matching ConfigMap. Backward-compatible: ConfigMap and `envFrom` are both omitted when the endpoint is empty.
- `neuraltrust-watchdog` `data-plane-synthetic` check added (covers `data-plane-api` `/health`, `/health/ready`, `/health/deep`). Default `enabled: false`.
- `neuraltrust-watchdog` `control-plane-synthetic` check now targets the scheduler's actual route — `http://control-plane-scheduler:3000/v1/health` instead of the previously incorrect `/health`.

### Added

- **`global.selfMonitoring.enabled`** umbrella flag and companion overlay `values-self-monitoring.yaml.example`. Merging the overlay on top of customer values enables the watchdog subchart and flips a curated default check set (control plane / data plane / trustgate / firewall synthetics, pod- and deployment-health, otel-collector, cert-renewal, kafka and clickhouse infra) without re-declaring every `target` / `thresholds` / `actions` block.
- **`neuraltrust-watchdog.enabledCheckIds`** additive overlay. Lists check ids to flip on by id without replacing the rest of the check definition. Per-check `enabled: true/false` in `.Values.checks` still wins. Lets the umbrella opt-in stay compact and customer-edits stay surgical.

### Removed

- **`kafka.connectorMonitor` CronJob and Secret are gone.** Functionality moved into the `neuraltrust-watchdog` subchart's `kafka_connect_connectors` check. The `kafka.connectorMonitor` values key is preserved as an empty placeholder so existing customer values files keep rendering, but every nested key under it is now ignored.
  - **Migration**: enable the watchdog (`neuraltrust-watchdog.enabled: true`) and add a `kafka-connect` check pointing at your Kafka Connect URL. To restart FAILED tasks automatically, leave `neuraltrust-watchdog.actions.dryRun: false` and include `kafka_connect.restart_task` in the check's `actions:` list (default keeps `dryRun: true`).
  - **No data loss**: the Helm upgrade garbage-collects `connector-monitor` CronJob + the `kafka-connect-monitor-secrets` Secret. The `monitor-connectors.sh` script remains in the `kafka-connect` image as a manual debug tool but is no longer the production self-heal path.
  - **Auto-bumper**: `.github/workflows/bump-images.yml` no longer touches `kafka.connectorMonitor.image.tag`.
