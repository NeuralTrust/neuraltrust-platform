# Deployment Guide

This guide covers the default Platform v2 deployment paths. Install a released
OCI chart whenever possible; replace `<chart>` below with the OCI URL, a release
archive, or `.` when testing the source tree.

## 1. Choose a topology

### Hybrid (default)

Hybrid runs AgentGateway and TrustGuard data-plane workloads in the cluster.
Their control planes stay in NeuralTrust SaaS. PostgreSQL, Redis, and
ClickHouse deploy in-cluster by default.

```bash
helm upgrade --install neuraltrust-platform <chart> \
  --namespace neuraltrust --create-namespace \
  -f values-required.yaml
```

DataAgent is enrolment-gated. It is omitted while its enrolment values are
empty. Add the SaaS-issued values together:

```yaml
dataagent:
  tenantId: "<tenant-id>"
  enrolmentToken: "<enrolment-token>"
```

Do not configure a partial enrolment. It is outbound-only and is not rendered
in external mode.

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

ClickStack does not run in hybrid mode. AlertEngine is the supported v2
replacement for the retired SIEM Connector component and preserves SIEM and
integration forwarding.

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

Platform v2 uses PostgreSQL, Redis, and ClickHouse. Kafka is not part of v2 and
never renders, regardless of `infrastructure.kafka.deploy`.

For managed datastores:

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

Then provide the service-specific database, Redis, and ClickHouse endpoints.
Reference existing Kubernetes Secrets for passwords. The full pattern is in
[`values-v2-managed-datastores.yaml.example`](./values-v2-managed-datastores.yaml.example).

When external PostgreSQL is selected, pre-create each required role and
database. The chart initialization Job only provisions the in-cluster
PostgreSQL instance.

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

## 5. Optional Firewall

The Firewall remains supported in v2. CPU workers use chart defaults. GPU
workers require a GPU image, resource limit, node selection, toleration, and
`hostIPC`:

```yaml
neuraltrust-firewall:
  firewall:
    enabled: true
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
as the complete v2 overlay.

## 6. Validate before rollout

```bash
helm lint <chart> -f <values-file>
helm template neuraltrust-platform <chart> \
  --namespace neuraltrust \
  -f <values-file> > /tmp/neuraltrust-rendered.yaml
```

For v2, verify the rendered output contains no Kafka, Kafka Connect,
data-plane worker, AISPM, or legacy SIEM Connector workloads.

## OpenShift

Use `values-openshift.yaml` for Routes or
`values-openshift-ingress.yaml.example` for Ingress. Both select v2 hybrid.
See [README-OPENSHIFT.md](./README-OPENSHIFT.md).

## Upgrades and secrets

With `global.autoGenerateSecrets: true`, generated values are reused through
Helm `lookup`. Environments whose deployment engine cannot use `lookup` should
pre-create secrets and set `global.preserveExistingSecrets: true`.

Persistent volume claims are retained by default. Review release notes before
each upgrade.

## Legacy v1 appendix

Use [`values-v1-legacy.yaml.example`](./values-v1-legacy.yaml.example) and pin:

```yaml
global:
  platformVersion: "v1"
```

v1 is the only topology that can run legacy TrustGate, Kafka, Kafka Connect,
Kafka workers, and the scheduler. The legacy external-Kafka example is
`values-external-services.yaml.example`. AISPM and SIEM Connector workloads are
retired; migrate SIEM/integration flows to external-mode AlertEngine.
