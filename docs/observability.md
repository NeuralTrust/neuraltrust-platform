# Observability and self-healing

The umbrella chart ships an opinionated, customer-portable observability
plane:

1. **In-chart OpenTelemetry Collector** (`templates/otel-collector/`)
   — receives OTLP from every component, scrapes Prometheus endpoints
   exposed in-cluster, and forwards to `collector.neuraltrust.ai`. The
   `attributes/redact` processor strips prompt/response/header payloads
   before any data leaves the cluster.
2. **`neuraltrust-watchdog` subchart** — a small Go service that
   actively probes Kafka brokers, ClickHouse disk/replication, Kafka
   Connect, HTTP/TCP synthetics, and consumer lag. On failure it
   dispatches a healing action (restart Deployment, restart Connect
   task, post Slack/OTLP) — every action gated by an explicit
   `dryRun` boolean.
3. **Per-subchart `PrometheusRule`** — every component renders an
   alert bundle that fires on `kube_deployment_status_replicas_available`
   / `kube_statefulset_status_replicas_ready` / `kube_job_failed`.
   Both gates have to be on (operator opt-in **AND** the cluster
   ships `monitoring.coreos.com/v1` CRDs) — otherwise nothing renders
   and `helm install` never breaks on a non-Prometheus cluster.

## Per-subchart wiring at a glance

What each platform service contributes to the observability plane:

| Service                       | Subchart                      | Prometheus `/metrics` scraped by the Collector | OTLP push (auto-wired when `global.observability.collector.endpoint` is set) | Watchdog check id        |
|-------------------------------|-------------------------------|------------------------------------------------|------------------------------------------------------------------------------|--------------------------|
| TrustGate (OSS + EE)          | `trustgate`                   | yes (`:9090`)                                  | yes (`OPENTELEMETRY_TRACES_ENDPOINT` / `OPENTELEMETRY_METRICS_ENDPOINT`)     | `trustgate-synthetic`    |
| control-plane-api             | `neuraltrust-control-plane`   | no                                             | yes (`OTEL_EXPORTER_OTLP_ENDPOINT`)                                          | `control-plane-synthetic` |
| control-plane-app (Next.js)   | `neuraltrust-control-plane`   | no                                             | yes (`OTEL_EXPORTER_OTLP_ENDPOINT`)                                          | `control-plane-synthetic` |
| control-plane-scheduler       | `neuraltrust-control-plane`   | no                                             | no (no OTel SDK)                                                             | `control-plane-synthetic` (HTTP `/v1/health`) |
| data-plane-api                | `neuraltrust-data-plane`      | no                                             | yes (`OTEL_EXPORTER_OTLP_ENDPOINT`)                                          | `data-plane-synthetic`   |
| kafka-workers                 | `neuraltrust-data-plane`      | no                                             | yes (`OTEL_EXPORTER_OTLP_ENDPOINT`)                                          | `data-plane-worker-lag`  |
| kafka-connect                 | `neuraltrust-data-plane`      | no (Strimzi JMX exporter disabled in image)    | no                                                                           | `kafka-connect`          |
| firewall (gateway + workers)  | `neuraltrust-firewall`        | no                                             | yes (`OTEL_EXPORTER_OTLP_ENDPOINT`)                                          | `firewall-synthetic`     |
| aispm                         | `neuraltrust-aispm`           | no                                             | yes (`OTEL_EXPORTER_ENDPOINT` — note legacy name)                            | (none — add via `httpsynthetic` if needed) |
| watchdog                      | `neuraltrust-watchdog`        | yes (`:8080`)                                  | yes                                                                          | self-scraped              |
| ClickHouse                    | `clickhouse`                  | yes (`:9363`)                                  | n/a (server)                                                                 | `clickhouse`             |
| Kafka                         | `kafka`                       | varies (JMX)                                   | n/a                                                                          | `kafka-broker`           |

The Collector's `prometheus` receiver only scrapes endpoints that
actually exist — when a subchart is disabled, its pod label selector
matches nothing and the scrape is a no-op.

## Quickstart: one-flag self-monitoring

```sh
helm upgrade --install neuraltrust . \
  -f accounts/<client>/values-<client>.yaml \
  -f values-self-monitoring.yaml.example
```

This overlay:

1. Sets `global.selfMonitoring.enabled: true` (informational marker).
2. Enables the `neuraltrust-watchdog` subchart.
3. Flips a curated check set via `neuraltrust-watchdog.enabledCheckIds`
   — an additive overlay that toggles checks by id without replacing
   their `target` / `thresholds` / `actions` blocks.
4. Keeps `actions.dryRun: true` for every mutating action. Flip
   per-check as you validate parity with the corresponding Cloud
   Monitoring policy.

## Phased rollout

The watchdog and the in-chart alerts are intentionally additive — they
sit alongside the existing Cloud Monitoring policies in
`cloud-infrastructure/gcp/`. Cut over in three phases:

### Phase 1 — Dry-run side by side (no behaviour change)

Goal: prove that the new alerts cover the same incidents the
Terraform alerts do, before retiring anything.

```yaml
# values-watchdog-dryrun.yaml
neuraltrust-watchdog:
  enabled: true
  actions:
    dryRun: true                 # actions log + emit, never mutate
    slack:
      existingSecret: slack-watchdog
      secretKey: webhook
  monitoring:
    scrapeAnnotations:
      enabled: true              # universal contract; works in all clusters
    podMonitor:
      enabled: true              # rendered iff monitoring.coreos.com/v1 is present
      additionalLabels:
        release: kube-prometheus-stack
    prometheusRule:
      enabled: true              # rendered iff monitoring.coreos.com/v1 is present
      alertLabels:
        team: platform
global:
  observability:
    enabled: true                # in-chart OTel Collector
    hostedExport:
      enabled: true
      auth:
        tokenSecretName: neuraltrust-observability-token
```

Deploy this for one full on-call rotation. Compare:

- Slack: did every Cloud-Monitoring incident also surface as a
  watchdog notification or in-chart alert?
- Watchdog `/checks` HTTP endpoint: which checks reported `failed` /
  `critical` and would have actioned (`dryRun: true`)?

### Phase 2 — Per-check cutover, smallest blast first

Once a check has matched the Terraform behaviour for an incident,
flip its action to live and remove the corresponding TF policy.
Suggested order (smallest blast first):

| Step | Watchdog flip | TF deletion |
|---|---|---|
| 1 | `kafka_connect.restart_task` (dryRun → false) | (none — pure addition) |
| 2 | `k8s.restart_deployment` for stuck consumers | `metric_based_alerts.tf` container-waiting policies |
| 3 | (none — alerts only) | `log_based_alerts.tf` application-error rate |
| 4 | (none — alerts only) | `clickhouse_monitoring.tf` (after watchdog `clickhouse` check matches a real incident) |
| 5 | (none — alerts only) | `alerting_golden_metrics.tf` (after watchdog HTTP synthetics match a real incident) |

Steps 3–5 are TF-only deletions; the chart-side alerts already replace
them. See `cloud-infrastructure/docs/alerts-migration.md` for the full
mapping.

### Phase 3 — Steady state

After all five steps land, the only `cloud-infrastructure/gcp/` alerts
remaining are the cloud-native ones the watchdog cannot observe from
inside the cluster (Cloud SQL, Cloud IDS, GCE quota, uptime checks,
cluster-up). Those stay forever.

## How to flip a single watchdog check out of dry-run

The chart accepts a YAML LIST under `checks:` (one entry per check,
identified by `id`). Each entry supports an optional `dryRun: false`
override. Flip them individually so a misconfiguration doesn't trigger
every action at once:

```yaml
neuraltrust-watchdog:
  # Global default (panic-stop knob): when true, EVERY mutating action
  # is logged and skipped, regardless of per-check overrides below.
  actions:
    dryRun: false

  checks:
    - id: kafka-connect
      kind: kafka_connect
      enabled: true
      dryRun: false                  # live for this check
      target:
        url: http://kafka-connect:8083
      actions: [notify.otlp, notify.slack, kafka_connect.restart_task]

    - id: data-plane-worker-lag
      kind: kafka_consumer_lag
      enabled: true
      dryRun: true                   # still dry while we tune the threshold
      target:
        bootstrapServers: ["kafka:9092"]
        group: data-plane-worker
        k8sDeployment: data-plane-kafka-worker
        k8sNamespace: data-plane-workers
      thresholds:
        maxLag: 100000
      actions: [notify.otlp, notify.slack, k8s.restart_deployment]
```

Precedence: a per-check `dryRun: true` always wins, so the safest
panic-stop is `actions.dryRun: true` at the top level. The
`rbac.actions.restartDeployment.enabled` flag is the second independent
gate — without it the Kubernetes API rejects mutating actions before
the watchdog can even attempt them.

## Air-gapped customers

The chart never requires outbound connectivity. With
`global.observability.hostedExport.enabled: false` (or no token), the
in-chart Collector still runs locally and the in-chart PrometheusRule
resources still feed the customer's own Alertmanager. The watchdog
likewise still probes its targets and fires actions in-cluster — only
the Slack notifier requires a webhook URL, which the customer
controls.

## How to add a new OTel-emitting component

1. The component image must read **`OTEL_EXPORTER_OTLP_ENDPOINT`** (and
   ideally `OTEL_SERVICE_NAME` / `OTEL_ENVIRONMENT`). TrustGate is the
   one exception — it reads `OPENTELEMETRY_TRACES_ENDPOINT` and
   `OPENTELEMETRY_METRICS_ENDPOINT` directly. The chart writes only
   those two TrustGate-specific names.
2. In the component's subchart, create
   `templates/<component>/otel-configmap.yaml` that mirrors
   `charts/neuraltrust-control-plane/templates/api/otel-configmap.yaml`
   — it should render only when the OTel endpoint helper resolves to a
   non-empty string.
3. Add a single line in the component Deployment's container spec:

   ```gotemplate
   {{- include "<subchart>.envFrom" (dict "component" "<name>" "extraEnvFrom" $extra "context" .) | nindent 8 }}
   ```

   This merges the OTel ConfigMap reference with any operator-supplied
   `extraEnvFrom`. The helper emits *nothing* when no endpoint is set,
   so customers who don't enable observability see zero diff.
4. Add a synthetic check entry to
   `charts/neuraltrust-watchdog/values.yaml` (start with `enabled: false`)
   and add its id to `values-self-monitoring.yaml.example`.

## See also

- `cloud-infrastructure/docs/alerts-migration.md` — the
  Terraform-side mapping and deletion checklist.
- `charts/neuraltrust-watchdog/README.md` — check catalog and
  configuration reference.
- `templates/otel-collector/configmap.yaml` — pipelines and the
  redaction processor.
- `values-self-monitoring.yaml.example` — single-overlay opt-in for
  the curated check set.
