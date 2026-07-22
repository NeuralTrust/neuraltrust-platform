# Deployment Guide

This chart (2.x) is v2-only. This guide covers the default deployment paths.
Install a released OCI chart whenever possible; replace `<chart>` below with
the OCI URL, a release archive, or `.` when testing the source tree.

## 1. Choose a topology

### Hybrid (default)

Hybrid runs AgentGateway and TrustGuard data-plane workloads in the cluster.
Their control planes stay in NeuralTrust SaaS. PostgreSQL and Redis deploy
in-cluster by default; ClickHouse is not part of hybrid. The temporary
`data-plane-api` read shim renders by default on the shared hybrid PostgreSQL.

Hybrid product OTLP is mandatory via a local `clickstack-egress-collector` and
requires DataAgent enrolment (no direct SaaS bearer token; no
`global.clickstack.enabled` / `egress.enabled` opt-out). Air-gapped or
local-only product telemetry requires `global.deploymentMode: external`.

Hybrid config-sync is on by default. Point each runtime at a Secret holding
`CONFIG_SYNC_TOKEN` and `CONFIG_SYNC_LKG_KEY` via `existingSecret` (do not
restate `enabled: true`). Set `configSync.enabled: false` only for
Postgres-managed configuration. Full contract:
[`docs/platform-v2.md`](./docs/platform-v2.md) and
[`values-v2-hybrid.yaml.example`](./values-v2-hybrid.yaml.example).

```bash
helm upgrade --install neuraltrust-platform <chart> \
  --namespace neuraltrust --create-namespace \
  -f values-required.yaml
```

DataAgent enrolment is required for hybrid ClickStack egress (and for
DataAgent itself). Prefer `enrolment.existingSecret.name`:

```yaml
agentgateway:
  dataagent:
    enrolment:
      existingSecret:
        name: "dataagent-enrolment-trustgate"

trustguard:
  dataagent:
    enrolment:
      existingSecret:
        name: "dataagent-enrolment-trustguard"
```

The enrolment JWT carries `tenant_id` and `instance_id`. Do not configure a
partial enrolment. It is outbound-only and is not rendered in external mode.

### External (self-hosted)

External runs the control and data planes, product API/app, and self-hosted
analytics stack in the cluster:

```bash
helm upgrade --install neuraltrust-platform <chart> \
  --namespace neuraltrust --create-namespace \
  -f values-v2-external.yaml.example
```

The external-only analytics path is:

```text
OTLP senders -> ClickStack OTel Collector -> ClickHouse
                                            |-> DataCore
                                            `-> AlertEngine -> SIEM/integrations
```

ClickStack does not run in hybrid mode. AlertEngine provides the supported
alert evaluation, SIEM, and integration forwarding path.

## 2. Configure cluster integration

Set the provider, base domain, storage class, and optional registry mirror:

```yaml
global:
  platform: "kubernetes" # aws | gcp | azure | openshift | kubernetes
  domain: "platform.example.com"
  storageClass: ""
  imageRegistry: ""
```

The chart defaults to the `gcr-secret` image pull secret for private NeuralTrust
images. Use the documented per-component opt-out only when node or workload
identity already authorizes image pulls.

## 3. Choose datastore placement

The chart uses PostgreSQL, Redis, and (external mode only) ClickHouse.

In **hybrid**, PostgreSQL and Redis are driven by `global.postgresql` and
`global.redis`, which render shared `postgresql-secrets` / `redis-secrets`.

In **external**, runtime services use per-service `*.database` / `*.redis`
overlays; `global.postgresql` still gates in-cluster PostgreSQL and feeds
control-plane `postgresql-secrets` for control-plane-api/app.

For managed datastores:

```yaml
global:
  postgresql:
    deploy: false
  redis:
    deploy: false

infrastructure:
  clickhouse:
    deploy: false
```

Then provide the host/user/password (or `existingSecret`) for each. Reference
existing Kubernetes Secrets for passwords. The full pattern is in
[`values-v2-managed-datastores.yaml.example`](./values-v2-managed-datastores.yaml.example).

There is no chart-managed database init Job. When external PostgreSQL is
selected, pre-create the role and database before installing; application
migrations own their own tables.

## 4. Configure observability

The umbrella OTel Collector is available in both v2 modes. It is separate from
the external-only ClickStack collector:

- umbrella collector: cluster metrics, events, traces, optional hosted export
- ClickStack collector: external-mode product telemetry landing in ClickHouse

For no-egress external deployments:

```yaml
global:
  observability:
    hostedExport:
      enabled: false
```

See [docs/observability.md](./docs/observability.md).

## 5. TrustGuard Firewall

Firewall deploys whenever TrustGuard is selected. CPU workers use chart
defaults. GPU workers require a GPU image, resource limit, node selection,
toleration, and `hostIPC`:

```yaml
firewall:
  firewall:
    workerDefaults:
      image:
        repository: "<registry>/firewall-gpu"
      resources:
        limits:
          nvidia.com/gpu: "1"
      nodeSelector:
        accelerator: "nvidia"
      tolerations:
        - key: "nvidia.com/gpu"
          operator: "Exists"
          effect: "NoSchedule"
      hostIPC: true
```

Use [`values-dataplane-gpu.yaml.example`](./values-dataplane-gpu.yaml.example)
as the complete overlay.

## 6. Validate before rollout

```bash
helm lint <chart> -f <values-file>
helm template neuraltrust-platform <chart> \
  --namespace neuraltrust \
  -f <values-file> > /tmp/neuraltrust-rendered.yaml
```

## OpenShift

Use `values-openshift.yaml` for Routes or
`values-openshift-ingress.yaml.example` for Ingress. Both select hybrid mode.
See [README-OPENSHIFT.md](./README-OPENSHIFT.md).

## Upgrades and secrets

With `global.autoGenerateSecrets: true`, generated values are reused through
Helm `lookup`. Environments whose deployment engine cannot use `lookup` should
pre-create secrets and set `global.preserveExistingSecrets: true`.

Persistent volume claims are retained by default. Review release notes before
each upgrade.

## Legacy v1

v1 (legacy TrustGate/Kafka) is maintained only on the `v1.14.x` release line;
pin `--version ~1.14.0` to install it. This chart (2.x) is v2-only.
