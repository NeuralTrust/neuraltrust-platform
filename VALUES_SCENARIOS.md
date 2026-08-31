# Values Files and Scenarios

Every file listed here exists in this repo. For a
guided first install see the [hybrid quick start](./README.md#quick-start-hybrid)
or [README-EXTERNAL.md](./README-EXTERNAL.md).

## How layering works

Most files here are **overlays**, not complete installs. Pick one base that
selects a topology and its products, then layer overlays on top:

```bash
helm upgrade --install neuraltrust-platform <chart> \
  -f <base>.yaml \
  -f <overlay>.yaml
```

Two rules cover almost every mistake:

- **Later `-f` wins.** When two files set the same key, the last one on the
  command line takes effect. Put the file whose opinion should survive last.
- **An overlay alone will not install.** Platform and product overlays set a few
  keys each. Without a base that selects `global.products`, the render fails
  with `hybrid requires at least one product`.

The `.yaml.example` suffix means "copy and edit" — none are applied as-is in
production. `values-required.yaml` and `values-openshift.yaml` carry no suffix
because they are usable directly.

## Core examples

The **Base?** column says whether a file installs on its own. A file marked "no"
renders an error until you layer it over one marked "yes".

| File | Mode | Base? | Purpose |
|---|---|:---:|---|
| [`values-required.yaml`](./values-required.yaml) | hybrid | yes | Full-hybrid preset (all three products on) + enrolment / config-sync Secrets |
| [`values-hybrid.yaml.example`](./values-hybrid.yaml.example) | hybrid | yes | Hybrid topology with managed datastores |
| [`values-trustgate.yaml.example`](./values-trustgate.yaml.example) | hybrid | yes | Positive TrustGate + DataAgent slice |
| [`values-trustguard.yaml.example`](./values-trustguard.yaml.example) | hybrid | yes | Positive TrustGuard + Firewall + DataAgent slice |
| [`values-red-teaming.yaml.example`](./values-red-teaming.yaml.example) | hybrid | yes | Positive data-plane-api-only slice |
| [`values-hybrid-reference.yaml.example`](./values-hybrid-reference.yaml.example) | hybrid | no | Annotated reference for every hybrid knob — selects no products |
| [`values-external.yaml.example`](./values-external.yaml.example) | external | yes | Minimal self-hosted topology |
| [`values-managed-datastores.yaml.example`](./values-managed-datastores.yaml.example) | external | yes | Managed PostgreSQL, Redis, and ClickHouse |

The three positive slices combine in any order, so
`-f values-trustgate.yaml.example -f values-trustguard.yaml.example` is a valid
alternative to `values-required.yaml` when you want only two products.

## Platform overlays

Layer these over a core example.

| File | Applies to | Notes |
|---|---|---|
| [`values-openshift.yaml`](./values-openshift.yaml) | hybrid | Native OpenShift Routes. Sets `deploymentMode: hybrid`, so for external put it **before** the external file and re-assert `--set global.platform=openshift` |
| [`values-dataplane-gpu.yaml.example`](./values-dataplane-gpu.yaml.example) | both | GPU Firewall workers |

For Kubernetes Ingress on OpenShift, set
`agentgateway.ingress.resourceType: ingress` — see
[README-OPENSHIFT.md](./README-OPENSHIFT.md).

AgentGateway dual discovery (exact host + header, or `*.llm` / `*.mcp` slug
with no header) is the chart default — no overlay is required. See
[docs/architecture.md](./docs/architecture.md).

## Observability overlays

| File | Purpose |
|---|---|
| [`values-observability-self-hosted.yaml.example`](./values-observability-self-hosted.yaml.example) | Umbrella OTel Collector and monitoring resources with hosted export off |

The umbrella OTel Collector is portable across hybrid and external. The
ClickStack OTel Collector is a product analytics component and only renders in
external mode.

## Scenario: default hybrid

```yaml
global:
  deploymentMode: "hybrid"
  platform: "kubernetes"
  domain: "platform.example.com"

agentgateway:
  configSync:
    existingSecret:
      name: "agentgateway-config-sync"
  dataagent:
    enrolment:
      existingSecret:
        name: "dataagent-enrolment-trustgate"

trustguard:
  configSync:
    existingSecret:
      name: "trustguard-config-sync"
  dataagent:
    enrolment:
      existingSecret:
        name: "dataagent-enrolment-trustguard"
```

Hybrid product OTLP is mandatory (enrolment-backed egress collector; no
`global.clickstack.enabled` / `egress.enabled` opt-out). Air-gapped or
local-only product telemetry requires `global.deploymentMode: external`.
Config-sync is on by default — overlays set `existingSecret` only (see
`values-hybrid.yaml.example`). Set `configSync.enabled: false` only for
Postgres-managed configuration.

## Scenario: self-hosted external

```yaml
global:
  deploymentMode: "external"
  superadmin:
    existingSecret:
      name: "onprem-superadmin"
  observability:
    hostedExport:
      enabled: false

alertengine:
  enabled: true
```

External mode renders ClickStack, DataCore, AlertEngine, the product API/app,
and the control and data planes. It does not render DataAgent. Bootstrap
admin: prefer `global.superadmin.existingSecret.name` pointing at a
pre-created Secret; inline `email` + `password` still works but enters Helm
release history.

## Scenario: managed datastores

```yaml
global:
  deploymentMode: "external"
  postgresql:
    deploy: false
  redis:
    deploy: false
  clickhouse:
    host: "clickhouse.example.com"
    httpPort: "8443"
    nativePort: "9440"

infrastructure:
  clickhouse:
    deploy: false
```

Use existing secrets and generic service endpoints as shown in
`values-managed-datastores.yaml.example`. Pre-create the PostgreSQL role
and database — there is no chart-managed database init Job. In external mode,
runtime services use per-service `*.database` / `*.redis` overlays;
`global.postgresql` still gates in-cluster PG and feeds control-plane
`postgresql-secrets`.

## Scenario: OpenShift

`values-openshift.yaml` selects Routes and the OpenShift platform only, so layer
it over a file that selects products:

```bash
helm upgrade --install neuraltrust-platform <chart> \
  --namespace neuraltrust --create-namespace \
  -f values-required.yaml \
  -f values-openshift.yaml \
  --set global.domain=apps.example.com
```

When an Ingress controller and certificate Secret are managed separately, add
`agentgateway.ingress.resourceType: ingress` to keep Kubernetes Ingress instead
of Routes.

## Scenario: GPU Firewall

Layer `values-dataplane-gpu.yaml.example` over `values-required.yaml`. Replace
the generic image registry and scheduling labels with values for the GPU pool.
The gateway remains CPU-only; workers request GPUs.

## Scenario: no hosted telemetry egress

Layer `values-observability-self-hosted.yaml.example`. This disables hosted
export while retaining the umbrella collector and Prometheus Operator resources
when CRDs are available.

In external mode, the ClickStack collector still writes product telemetry to
the selected ClickHouse instance; it does not export to the hosted telemetry path.

---

<sup>**Looking for v1?** The legacy TrustGate/Kafka line ended at [v1.14.16](https://github.com/NeuralTrust/neuraltrust-platform/releases?page=3#release-v1.14.16) — install it with `--version ~1.14.0`.</sup>
