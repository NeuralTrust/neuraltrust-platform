# Changelog

All notable changes to the `neuraltrust-platform` umbrella chart are tracked in this file. The chart follows semantic versioning at the chart level (`Chart.yaml#version`).

## [Unreleased]

### Added

- **External Kafka auth/TLS wiring** — `global.kafka` configures bootstrap servers, SASL credentials via an existing Secret (`auth.existingSecret` + `usernameKey`/`passwordKey`, or `jaasConfigKey`), and broker CA trust (`tls.existingSecret`). All Kafka consumers receive consistent `KAFKA_*` / `CONNECT_*` env vars. Renders a shared `kafka-connection` ConfigMap when `global.kafka.bootstrapServers` (or `brokers`) is set. `global.customCaCert` does not enable Kafka TLS unless `global.kafka.tls.enabled` is true.

### Changed

- **Kafka bootstrap resolution** — components no longer hardcode `kafka:9092` when `global.kafka.bootstrapServers` is configured (with `infrastructure.kafka.deploy: false`). Override per component only when needed (e.g. `neuraltrust-data-plane.dataPlane.components.kafka.connect.bootstrapServers`).
- **Removed `infrastructure.kafka.external`** — external broker settings live only under `global.kafka` (visible to all subcharts). No clients had adopted the old alias path.


### Changed

- **Right-sized default resource requests/limits to fit 16 GiB worker nodes.** Reduced inflated umbrella defaults toward the values NeuralTrust runs in SaaS prod, so the documented sizing baselines now target **8 vCPU / 16 GiB** nodes instead of 8 vCPU / 32 GiB: hybrid fits **4 nodes** (~12.25 vCPU / ~40.5 GiB requests, down from ~58.5 GiB), self-hosted **5 nodes** (~43.75 GiB), self-hosted + AISPM **6 nodes** (~45 GiB). Changes (req/lim memory): TrustGate gateway `4Gi→8Gi` ⇒ `3Gi→6Gi`; TrustGate admin & actions `2Gi→4Gi` ⇒ `1Gi→2Gi`; Data Plane API `4Gi→6Gi` ⇒ `3Gi→6Gi`; Data Plane worker `4Gi→8Gi` ⇒ `3Gi→6Gi`; Firewall worker defaults `4Gi→6Gi` ⇒ `2Gi→3Gi`, with a per-worker override keeping the heavier `prompt-moderation` worker at `3Gi→4Gi`. **ClickHouse memory is intentionally unchanged at `4Gi`/`8Gi`** (the chart ships no in-chart memory caps, so lowering it risks `MEMORY_LIMIT_EXCEEDED`/OOM) — only its CPU *request* was relaxed `2→1` (limit stays `4`) to improve bin-packing. Control Plane API (`1Gi`/`2Gi`), PostgreSQL (`2Gi`/`4Gi`), Kafka (`1Gi`/`2Gi`), Redis (`1Gi`/`2Gi`, tied to the hardcoded `maxmemory 1gb`) and Kafka Connect (`2Gi`, JVM heap floor) are unchanged. All values remain operator-overridable; HPAs still scale components above these baselines under load.
- **HPA and PDB off by default across all Deployments.** `autoscaling.enabled` and `podDisruptionBudget.enabled` now default to `false` on every workload that supports them (TrustGate, Control Plane api/app/scheduler, Data Plane api/worker/kafka-connect, Firewall, AISPM, SIEM connectors, OTel Collector). New optional HPA/PDB templates were added for Control Plane and Data Plane components that previously lacked them. Fixed replica counts come from each component's `replicas` / `replicaCount` value. Opt in per component when your cluster has a metrics server (HPA) or you want voluntary-disruption guards during node drains (PDB).

### Added

- **`global.postgresql.deploy` — single switch for external PostgreSQL.** A new umbrella-wide flag (default `true`) controls in-cluster vs external PostgreSQL across **all** subcharts (Control Plane, TrustGate, AISPM). When set to `false`, the chart skips every consumer of the heavy `postgres` image so it is never pulled:
  - the in-cluster `control-plane-postgresql` Deployment,
  - the Control Plane API/scheduler `wait-for-postgresql` initContainers,
  - the TrustGate and AISPM `postgresql-init` Jobs.
  - The operator must pre-create the users/databases on the external server. The Control Plane app `init-db` initContainer (Prisma migrations, app image) still runs. The legacy `neuraltrust-control-plane.infrastructure.postgresql.deploy` remains honored and takes precedence; `global.postgresql.deploy` is the recommended single override. Defaults preserve existing behavior. Render coverage added to `scripts/test-helm-render.sh` (scenario 26).

### Removed

- **Dead `controlPlane.components.api.healthCheck.image` (curl) value.** No template referenced it; removed from `values.yaml`, the `release-images-markdown.sh` image table, and the `bump-images.yml` doc-only bump. The functional `curl` usage (ClickHouse backup CronJob, gated by `backup.enabled`) is unchanged.

## [v1.13.0] — 2026-06-05

### Added

- **Global node pinning via `global.nodeSelector` and `global.tolerations`.** Operators can now pin **every** platform workload to a dedicated node pool with a single setting instead of configuring each component separately. Both default to empty (`{}` / `[]`), so existing releases are unaffected.
  - `global.nodeSelector` is merged into every pod spec across all subcharts (TrustGate, Control Plane, Data Plane, Firewall, AISPM, SIEM connectors, ClickHouse, Kafka, Watchdog) and the parent-chart workloads (OTel Collector, init/cron Jobs). Per-component `nodeSelector` still works and **wins on key conflicts**.
  - `global.tolerations` is concatenated onto every pod spec (companion for an *exclusive*, tainted pool — a `nodeSelector` alone won't keep other tenants off). Per-component tolerations are preserved and merged.
  - The Firewall workers keep expressing their per-worker GPU-pool selection as `nodeAffinity` (its values are lists); `global.nodeSelector` is added there as a plain `nodeSelector` (ANDed with the affinity), so a GPU pool can still be pinned under a broader dedicated pool.
  - Implemented via the shared helpers `neuraltrust-platform.nodeSelector` / `neuraltrust-platform.tolerations` in `templates/_helpers.tpl`. Render coverage added to `scripts/test-helm-render.sh` (scenario 25).

## [v1.12.19] — 2026-06-03

### Changed

- **data-plane-api evaluation Jobs reuse the shared `data-plane` ServiceAccount.** The chart no longer creates a separate `data-plane-api` ServiceAccount for the k8sJobs feature. The API Deployment now always runs under the existing `data-plane` SA (like the worker and kafka-connect components, and matching the app's own `K8S_JOB_SERVICE_ACCOUNT=data-plane` default and the SaaS manifests). When `k8sJobs.enabled: true`, the `data-plane-job-creator` Role/RoleBinding is bound to `data-plane`, and spawned Job pods also run under `data-plane`. Removed `dataPlane.components.api.k8sJobs.serviceAccount`.
  - **Why:** the bespoke SA was the only thing referencing `data-plane-api`, and flipping `k8sJobs` off pruned that SA while leaving the Deployment pinned to it — Helm's 3-way merge does not clear a field that is absent in both the previous and current rendered manifests, so the live Deployment kept a dangling `serviceAccountName: data-plane-api` and pods failed with `serviceaccount … not found`.
  - **Upgrade note:** a release that previously had `k8sJobs` enabled may carry a stale `serviceAccountName: data-plane-api` on the live `data-plane-api` Deployment. This upgrade re-renders the Deployment with `serviceAccountName: data-plane`, which produces a real diff and a clean rollout. If you upgraded across the earlier OFF→OFF window and pods are stuck, clear it once with `kubectl patch deploy data-plane-api -n <ns> -p '{"spec":{"template":{"spec":{"serviceAccountName":"data-plane"}}}}'`.

### Fixed

- **`ImagePullBackOff` on private images that lacked a pull secret.** Three workloads pulled private GCP Artifact Registry images without resolving the chart-wide `gcr-secret`:
  - **In-chart OTel Collector** only honored `global.imagePullSecrets` (empty by default). It now defaults to `gcr-secret` (`global.observability.collector.imagePullSecret`), still honoring `global.imagePullSecrets` first. Opt out with `"none"`/`""` on IAM / Workload Identity clusters.
  - **`neuraltrust-watchdog`** subchart defaulted `imagePullSecrets: []`. It now defaults to `gcr-secret`. The bundled Prometheus uses a public image and is unaffected. Set `[]` to opt out.
  - **data-plane-api evaluation Jobs** (`rt-eval-*`) are created at runtime by the API process and were created with no `imagePullSecrets`. The chart now forwards the resolved pull-secret name to the API as `K8S_JOB_IMAGE_PULL_SECRET`, so spawned Job pods inherit the same secret as the Deployment. Resolves to the same value (and opt-out) as `neuraltrust-data-plane.imagePullSecrets`; omitted entirely when suppressed.
  - **In-chart OTel Collector CrashLoopBackOff on v0.153.x** — `service.telemetry.metrics.address` was removed in Collector v0.128+. Config now uses the `readers` / `pull` / `prometheus` block so the collector starts cleanly.

### Changed

- **GitHub Release notes** — `auto-release` (workflows `ai-release-bump`) writes **What changed** + **Commits**; `publish-chart.yml` appends a **Container images** table (`scripts/release-images-markdown.sh`) and **Installation** when the chart is published.
- **`data-plane-api k8sJobs` default is now OFF** (`dataPlane.components.api.k8sJobs.enabled: false`). Matches data-plane-api's `K8S_JOBS_ENABLED=false` when unset — red teaming / evaluation workloads run as in-process FastAPI background tasks unless the operator opts in. Set `k8sJobs.enabled: true` (requires `data-plane-api >= v1.25.0`) to spawn evaluation workloads as Kubernetes Jobs with the bundled SA/RBAC and `K8S_*` env wiring. Clusters that relied on the prior default must add the explicit opt-in to their values overlay.
- **`neuraltrust-watchdog` resources dropped the release-name prefix.** Set `fullnameOverride: "neuraltrust-watchdog"` so the Deployment/Service/ConfigMap/RBAC/PrometheusRule are named `neuraltrust-watchdog` (and `neuraltrust-watchdog-prometheus`) — matching `clickhouse`, `kafka`, `data-plane-api`, … — instead of `<release>-neuraltrust-watchdog`. The `app.kubernetes.io/name` label is unchanged, so OTel Collector label-based scraping and monitoring discovery are unaffected. On upgrade Helm replaces the prior `<release>-neuraltrust-watchdog` objects with the new names.
- **In-chart OTel Collector resources dropped the release-name prefix.** Set `global.observability.collector.fullnameOverride: "otel-collector"` so the Deployment/Service/ConfigMap/RBAC/PVC/ServiceMonitor are named `otel-collector` (and `otel-collector-config`, `otel-collector-buffer`, …) instead of `<release>-otel-collector`. Label-based discovery (`app.kubernetes.io/component: otel-collector`) is unchanged. On upgrade Helm replaces the prior prefixed objects.

## [v1.12.11] — 2026-05-22

### Added

- **data-plane-api Kubernetes Job runner is now the default** (`dataPlane.components.api.k8sJobs.enabled: true`). The data-plane-api Deployment spawns evaluation workloads as ephemeral Jobs in the release namespace instead of running them as FastAPI background tasks — keeping the API pod responsive and bounding per-evaluation resource usage. A new namespaced `ServiceAccount data-plane-api`, `Role data-plane-job-creator`, and matching `RoleBinding` are rendered automatically; the API Deployment binds to the new SA and receives `K8S_JOBS_ENABLED`, `K8S_JOBS_NAMESPACE`, `K8S_JOB_IMAGE`, `K8S_JOB_SERVICE_ACCOUNT` plus tunable resource/TTL/concurrency env vars. The API process inherits its own env into each Job pod's `env:` block at job-creation time, so the same code path works on Helm (Kubernetes Secrets via `secretKeyRef`) and Flux + Secret Manager (CSI) — no separate Secret object, SecretProviderClass, or mount is needed for Jobs. **Requires `data-plane-api >= v1.25.0`**. To opt out on older images, set `dataPlane.components.api.k8sJobs.enabled: false`.
- **`neuraltrust-watchdog` subchart** (default `enabled: false`). Long-running Go service that periodically probes platform components (TrustGate, Control Plane, Data Plane, Firewall, ClickHouse, Kafka, Kafka Connect, Postgres, Redis) and emits OTel events + Prometheus metrics. Optionally restarts Deployments / Kafka Connect tasks behind a `dryRun` flag. See [`charts/neuraltrust-watchdog/README.md`](charts/neuraltrust-watchdog/README.md).
- **In-chart OpenTelemetry Collector** (`templates/otel-collector/`, default `global.observability.enabled: false`). Renders when `global.observability.enabled: true` or when `neuraltrust-watchdog.enabled: true` (watchdog stack expects the in-chart collector for scrapes and optional hosted export). Exports cluster + component telemetry to `collector.neuraltrust.ai` with payload redaction. Gracefully degrades to a local-only collector when no token is configured — installs never break in air-gapped clusters.
- **Optional `global.monitoring.enabled` flag**. When the cluster ships `monitoring.coreos.com/v1` CRDs (Prometheus Operator), every subchart renders a `PrometheusRule` (and TrustGate / OTel Collector additionally render `PodMonitor`/`ServiceMonitor`). Default OFF.
- **`global.observability.collector.endpoint`** umbrella override. Set once and every subchart (TrustGate, Firewall, AISPM) routes OTLP to that endpoint without per-subchart edits. Defaults preserved for upgrades.
- **HTTP liveness + readiness probes** on `control-plane-app` and `control-plane-scheduler`. Default ON; opt out per component via `controlPlane.components.<name>.healthProbes.enabled: false` for older images that don't expose the health route.
- **Optional `PodDisruptionBudget`s** for every Control Plane Deployment, gated per component (`controlPlane.components.<name>.podDisruptionBudget.enabled: true`). Default OFF; only renders when `replicaCount > 1`.
- **Hardened ClickHouse backup CronJob**. Adds `set -euo pipefail`, `activeDeadlineSeconds`, and synchronous BACKUP by default (operators can re-enable ASYNC fire-and-forget via `dataPlane.components.clickhouse.backup.failOnError: false`). The Job now fails loudly on a server-side ClickHouse error instead of always exiting 0.
- **Helm render assertions** (`scripts/test-helm-render.sh`, `.github/workflows/helm-render-tests.yml`) covering: graceful degradation of the hosted exporter, payload redaction processors, watchdog rendering, monitoring CRD gating, and TrustGate/Firewall/AISPM endpoint flipping.
- **Docs**: [`docs/observability.md`](docs/observability.md) (rollout / dry-run / per-check cutover) and the companion [`cloud-infrastructure/docs/alerts-migration.md`](../cloud-infrastructure/docs/alerts-migration.md).
- **Example values**: `values-observability-self-hosted.yaml.example` (in-chart Collector + own Alertmanager) and `values-watchdog.yaml.example` (watchdog standalone with safe defaults).

### Changed

- **In-chart OTel Collector is now OFF by default** (`global.observability.enabled: false`). It auto-deploys when `neuraltrust-watchdog.enabled: true`, or when operators set `global.observability.enabled: true` explicitly. Clusters that relied on the prior always-on default should set one of those flags (or merge `values-self-monitoring.yaml.example`).
- TrustGate's `OPENTELEMETRY_ENABLED` auto-flips to `true` when `global.observability.collector.endpoint` is set; legacy off-by-default behaviour preserved otherwise.
- Firewall and AISPM ConfigMaps prefer `global.observability.collector.endpoint` over their per-subchart defaults. No behaviour change when the global override is unset.
- OTel Collector internal telemetry (`address: 0.0.0.0:8888`) is now exposed via the Collector Service so existing Prometheus Operator installs can scrape collector internals.
- **Fixed**: TrustGate's OTel endpoint ConfigMap now emits the only env names TrustGate-EE actually reads — `OPENTELEMETRY_TRACES_ENDPOINT` and `OPENTELEMETRY_METRICS_ENDPOINT` (`internal/config/config.go`). The previously written `OPENTELEMETRY_ENDPOINT` / `OPENTELEMETRY_OTLP_ENDPOINT` keys were never consumed by the binary and have been removed (safe because no customer is on TrustGate OTel yet). Without this fix TrustGate's OTLP egress was silently a no-op even when the umbrella endpoint was set.
- Control Plane (`api`, `app`) and Data Plane (`api`, `worker`) subcharts now ship an `<component>-otel` ConfigMap that emits `OTEL_ENABLED`, `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_SERVICE_NAME`, `OTEL_ENVIRONMENT` whenever `global.observability.collector.endpoint` is resolved. Each Deployment auto-`envFrom`s the matching ConfigMap. Backward-compatible: ConfigMap and `envFrom` are both omitted when the endpoint is empty.
- **Fixed**: `control-plane-scheduler` liveness/readiness probes now default to `/v1/health` (the route the scheduler binary actually exposes). Probing `/health` hit auth middleware and returned 401, causing CrashLoopBackOff.
- **Fixed**: IPv6-only Kubernetes clusters (e.g. EKS with IPv6-only pod networking) could not start `clickhouse`, `trustgate-redis`, or `control-plane-app` because the bind addresses were hardcoded to `0.0.0.0`. New overrides `clickhouse.listenHost`, `trustgate.redis.bind`, and `controlPlane.components.app.hostname` make the bind address tunable per cluster topology.
  - `clickhouse.listenHost` and `controlPlane.components.app.hostname` default to `::` — on Linux a socket bound to `::` accepts both IPv4 and IPv6 when `net.ipv6.bindv6only=0` (the kernel default), so a single value works on IPv4-only, dual-stack, and IPv6-only clusters.
  - `trustgate.redis.bind` defaults to **`0.0.0.0 -::`** (Redis 7.0+ multi-bind syntax: the `-` prefix marks an address optional, so Redis skips it instead of aborting when the socket cannot be created). This is Redis-specific because the kubelet `tcpSocket` liveness probe connects to the pod's IPv4 address — on certain IPv4-only nodes (notably AWS EKS) a Redis instance bound only to `::` rejected those probes and entered a SIGTERM crash loop. The new default explicitly takes the IPv4 wildcard and adds IPv6 opportunistically. IPv6-only clusters override to `bind: "::"`.
  - Firewall gateway/workers and AISPM were already addressed via image bumps (`firewall v2.9.5`, AISPM CMD) whose entrypoints dual-bind to `0.0.0.0` and `::` at startup; firewall probes also omit `httpGet.host` so kubelet uses the pod IP.
  - Existing IPv4-only clusters continue to work with no change.
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
