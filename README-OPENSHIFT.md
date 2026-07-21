# OpenShift Deployment Guide

This chart (2.x) is v2-only. The default OpenShift path is hybrid mode with
native Routes.

## Prerequisites

- OpenShift 4.10+
- Helm 3.2+
- `oc` access to the target project
- the NeuralTrust registry pull secret in the release namespace
- a wildcard domain such as `apps.example.com`

## Hybrid quick start

```bash
oc new-project neuraltrust

helm upgrade --install neuraltrust-platform \
  oci://europe-west1-docker.pkg.dev/neuraltrust-app-prod/helm-charts/neuraltrust-platform \
  --version <VERSION> \
  --namespace neuraltrust \
  -f values-openshift.yaml \
  --set global.domain=apps.example.com
```

`values-openshift.yaml` explicitly selects:

```yaml
global:
  deploymentMode: "hybrid"
  platform: "openshift"
```

Hybrid product OTLP is mandatory via the DataAgent-co-located egress collector
(enrolment-backed; no direct SaaS ClickStack bearer). Air-gapped or local-only
product telemetry requires `global.deploymentMode: external`. See
[SECRETS.md](./SECRETS.md).

Hybrid config-sync is on by default. Pre-create Secrets holding
`CONFIG_SYNC_TOKEN` and `CONFIG_SYNC_LKG_KEY`, then point overlays at them
(do not restate `enabled: true`):

```yaml
agentgateway:
  configSync:
    existingSecret:
      name: "agentgateway-config-sync"

trustguard:
  configSync:
    existingSecret:
      name: "trustguard-config-sync"
```

Set `configSync.enabled: false` only for Postgres-managed configuration. See
[`values-v2-hybrid.yaml.example`](./values-v2-hybrid.yaml.example).

DataAgent enrolment (`tenantId` plus `enrolment.token` or preferred
`enrolment.existingSecret.name`) is required for hybrid OTLP egress.

## Routes and Ingress

With `global.platform: openshift`, native Routes are the default for
AgentGateway (`agentgateway.ingress.resourceType: auto`). Use
`values-openshift-ingress.yaml.example` when the cluster standardizes on
Kubernetes Ingress (`resourceType: ingress`).

Both paths use `global.domain`. Route names remain stable; Ingress hostnames are
derived from each service's `hostPrefix`.

### Wildcard gateway / MCP Routes

Dynamic gateway subdomains (`*.llm.<domain>`, `*.mcp.<domain>`) render as
OpenShift Routes with `wildcardPolicy: Subdomain` (host = zone without `*.`).
Exact hosts use `wildcardPolicy: None`.

Operator prerequisites (not rendered by Helm):

1. The cluster IngressController must allow wildcards:

   ```yaml
   # IngressController spec.routeAdmission
   routeAdmission:
     wildcardPolicy: WildcardsAllowed
   ```

2. The router / Route certificate must cover the wildcard domains
   (or terminate TLS at an upstream edge that does).

3. Set AgentGateway discovery to subdomain mode. With empty base domains and
   empty `additionalHosts`, the chart derives `GATEWAY_BASE_DOMAIN=llm.<domain>`,
   `MCP_BASE_DOMAIN=mcp.<domain>`, and auto-adds `*.llm.<domain>` /
   `*.mcp.<domain>` Ingress/Route hosts. Explicit `additionalHosts` remain
   authoritative when set:

   ```yaml
   agentgateway:
     config:
       gatewayDiscoveryMode: "subdomain"
   ```

See `values-agentgateway-wildcard.yaml.example` and
[docs/platform-v2.md](./docs/platform-v2.md).

## Self-hosted external mode

Layer the external topology over the OpenShift values:

```bash
helm upgrade --install neuraltrust-platform <chart> \
  --namespace neuraltrust \
  -f values-openshift.yaml \
  -f values-v2-external.yaml.example \
  --set global.platform=openshift \
  --set global.domain=apps.example.com
```

External mode runs the product API/app, control and data planes, DataCore,
AlertEngine, and the ClickStack OTel Collector in the cluster. DataAgent is
absent. Set `global.observability.hostedExport.enabled: false` for a
no-egress deployment.

## Security Context Constraints

The chart adapts pod security settings when `global.platform: openshift`.
Grant additional SCC permissions only when required by cluster policy. GPU
Firewall workers may require a dedicated SCC because they use `hostIPC` and GPU
device resources.

## Storage and images

```yaml
global:
  storageClass: "<storage-class>"
  imageRegistry: "<registry>/neuraltrust"
```

The default image pull secret is `gcr-secret`. Mirror every required image for
disconnected clusters, including the external-mode ClickStack image.

## Validation

```bash
helm lint <chart> -f values-openshift.yaml
helm template neuraltrust-platform <chart> \
  --namespace neuraltrust \
  -f values-openshift.yaml \
  --api-versions route.openshift.io/v1
```

## Legacy v1

v1 (legacy TrustGate/Kafka) is maintained only on the `v1.14.x` release line;
pin `--version ~1.14.0` to install it. This chart (2.x) is v2-only.
