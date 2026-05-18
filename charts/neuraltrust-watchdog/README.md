# neuraltrust-watchdog Helm chart

Self-monitoring and self-healing controller for the NeuralTrust platform.

Designed to be installed in two ways, from the same chart source:

- As a **subchart** of `neuraltrust-platform` (enable via `neuraltrust-watchdog.enabled: true` in the umbrella's values).
- As a **standalone Helm release** in clusters that already run the platform but want the watchdog managed independently.

## Quick start (standalone)

Run from the root of the `neuraltrust-platform` repo:

```sh
helm install watchdog ./charts/neuraltrust-watchdog \
  --namespace neuraltrust \
  --create-namespace \
  --set telemetry.otlp.endpoint=https://collector.neuraltrust.ai:4318
```

## Healing actions and dry run

Mutating actions default to `actions.dryRun: true`. To enable them:

1. Flip `rbac.actions.restartDeployment.enabled: true` to grant
   `patch deployments` (and `patch deployments/scale`) on the namespace.
   The same toggle gates BOTH `k8s.restart_deployment` and
   `k8s.scale_deployment` — they need the same Deployments verbs.
2. Flip `actions.dryRun: false` (global) **or** `dryRun: false` on the
   specific check entry under `checks:`.

This two-step gate exists so an accidental flip of `dryRun` cannot fire
without the corresponding RBAC.

## Action catalog

| Action ID | Effect | Required `Result.Attributes` | RBAC gate |
|---|---|---|---|
| `notify.otlp` | Emits an OTel event | — | — |
| `notify.slack` | Posts to `SLACK_WEBHOOK_URL` | — | — |
| `k8s.restart_deployment` | `kubectl rollout restart` semantics | `k8s.deployment` (falls back to check id); `k8s.namespace` (defaults to pod's namespace) | `rbac.actions.restartDeployment.enabled` |
| `k8s.scale_deployment` | Updates `Deployment.spec.replicas` via the `scale` subresource | `k8s.deployment`, `k8s.target_replicas`, optional `k8s.namespace` | `rbac.actions.restartDeployment.enabled` |
| `kafka_connect.restart_task` | Restarts a single FAILED task; falls back to the connector | `kafka_connect.url`, `kafka_connect.connector`, optional `kafka_connect.task` | — |

## Check catalog

| Kind | Source signal | Status |
|---|---|---|
| `clickhouse` | Disk free %, mutation age, replication queue, memory ratio, parts-per-partition, system.errors growth, scrape liveness | Stable; replaces `cloud-infrastructure/gcp/clickhouse_monitoring.tf` |
| `kafka_broker` | Broker connectivity, controller presence | Stable |
| `kafka_connect` | Connector/task FAILED state | Stable; pairs with `kafka_connect.restart_task` |
| `kafka_consumer_lag` | Consumer-group lag > maxLag | Stable; pairs with `k8s.restart_deployment` when `k8sDeployment`/`k8sNamespace` set |
| `httpsynthetic` | HTTP probe + `expectedStatus` / `expectedStatusList` + latency budget (`latencyWarnMs`, `latencyCriticalMs`) | Stable; replaces `cloud-infrastructure/gcp/alerting_golden_metrics.tf` |
| `tcpsynthetic` | TCP connect | Stable |
| `redis` | Redis `PING` + auth | Stable |
| `postgres_ping` | `pgx.Connect` + `SELECT 1` smoke probe | Stable (CPU/mem/disk for Cloud SQL stays in TF) |
| `pod_health` | Pods in Waiting state with selected reasons across one or more namespaces | Stable; replaces `cloud-infrastructure/gcp/metric_based_alerts.tf:pod_crash_alert` |
| `deployment_health` | Available replicas vs spec + restart-count delta over the interval | Stable; replaces `metric_based_alerts.tf:container_restart_rate` |
| `gateway_health` | HTTP probe + ready-pod cross-check in the gateway namespace | Stable |
| `cert_renewal` | `cert-manager.io/v1/Certificate` `status.notAfter` budget | Stable |
| `otel_collector` | Collector `/health` (default `:13133/`) + ready-pod cross-check | Stable |
| `tenant_discovery` | Lists tenant namespaces by label selector (default `project=multitenant-gateway`) + per-tenant availability & restart-count delta | Requires `rbac.watchAllNamespaces=true`; SaaS-targeted — single-tenant installs leave OFF |

## Multi-namespace

By default the watchdog watches its own release namespace only
(`Role` + `RoleBinding`). Set `rbac.watchAllNamespaces: true` to issue
a `ClusterRole` + `ClusterRoleBinding`. Use sparingly.

## Telemetry

Three knobs:

- `telemetry.otlp.endpoint` — full URL to your OTel collector.
  Leave empty to fall back to the `OTEL_EXPORTER_OTLP_ENDPOINT` env
  var. Leave both empty to run with no-op providers (no egress).
- `telemetry.tenantId` — surfaced as `nt.tenant_id` on every span/log.
- `telemetry.enableTraces` / `telemetry.enableLogs` — fine control.

## Notification

- `actions.slack.webhookUrl` — when set, rendered into a Secret and
  exposed as `SLACK_WEBHOOK_URL`. Empty = `notify.slack` is a silent
  no-op.

## /metrics

Scrape `Service` `:8080`, path `/metrics`. The chart ships five
independent, capability-gated monitoring resources — pick what your
cluster's stack supports:

| Values key | Default | Capability gate | Renders |
|---|---|---|---|
| `monitoring.scrapeAnnotations.enabled` | `true` | none | Pod `prometheus.io/{scrape,port,path}` annotations on the Deployment |
| `monitoring.podMonitor.enabled` | `true` | `monitoring.coreos.com/v1` (Prometheus Operator) | `PodMonitor` |
| `monitoring.prometheusRule.enabled` | `true` | `monitoring.coreos.com/v1` | `PrometheusRule` |
| `monitoring.podMonitoring.enabled` | `false` | `monitoring.googleapis.com/v1` (Google Managed Prometheus) | `PodMonitoring` |
| `monitoring.gmpRules.enabled` | `false` | `monitoring.googleapis.com/v1` | GMP `Rules` |

Each toggle no-ops silently when its CRD is absent, so misconfiguration
is non-fatal. The annotations baseline is the uniform contract across
every environment — Prometheus Operator, GMP, Amazon Managed Prometheus,
Azure Monitor for Containers, the in-chart OTel collector, and
air-gapped setups all honour it.

## /checks API

- `GET /checks` — last result per check.
- `POST /checks/{id}/run` — force-run; protected by bearer token if
  `server.authToken.value` (or `server.authToken.existingSecret`) is set.
