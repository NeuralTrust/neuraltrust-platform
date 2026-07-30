# OpenShift Deployment Guide

The default OpenShift path is hybrid mode with native Routes. This guide covers
only what differs on OpenShift — follow the
[hybrid quick start](./README.md#quick-start-hybrid) for the general flow, or
[README-EXTERNAL.md](./README-EXTERNAL.md) for self-hosted deployments.

## Prerequisites

- OpenShift 4.10+
- Helm 3.2+ (3.8+ for OCI installs)
- `oc` access to the target project
- the NeuralTrust registry pull secret in the release namespace
- a wildcard domain such as `apps.example.com`

## Hybrid quick start

`values-openshift.yaml` is a **platform overlay, not a complete install**. It
selects the topology only:

```yaml
global:
  deploymentMode: "hybrid"
  platform: "openshift"
  ingress:
    provider: "openshift"
```

Layer it over a values file that selects products and enrolment, otherwise the
render fails with `v2 hybrid requires at least one product`:

```bash
oc new-project neuraltrust

# Pre-create the four hybrid Secrets first — see README.md step 3
helm upgrade --install neuraltrust-platform \
  oci://europe-west1-docker.pkg.dev/neuraltrust-app-prod/helm-charts/neuraltrust-platform \
  --version <VERSION> \
  --namespace neuraltrust \
  -f values-required.yaml \
  -f values-openshift.yaml \
  --set global.domain=apps.example.com
```

Order matters: `values-openshift.yaml` comes last so its `platform` and
`ingress.provider` win.

Hybrid product OTLP is mandatory via the DataAgent-co-located egress collector
(enrolment-backed; no direct ClickStack bearer on apps). Air-gapped or local-only
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
[`values-hybrid.yaml.example`](./values-hybrid.yaml.example).

DataAgent enrolment (`enrolment.token` or preferred
`enrolment.existingSecret.name`) is required for hybrid OTLP egress. The JWT
carries `tenant_id` and `instance_id`.

## Routes and Ingress

With `global.platform: openshift`, native Routes are the default for
AgentGateway (`agentgateway.ingress.resourceType: auto`). When the cluster
standardizes on Kubernetes Ingress instead, switch the resource type:

```yaml
agentgateway:
  ingress:
    resourceType: "ingress" # auto | route | ingress
```

Both paths use `global.domain`. Route names remain stable; Ingress hostnames are
derived from each service's `hostPrefix`.

### Route TLS certificates

A Route is readable by anyone holding `route/get`, so the chart never copies
private key material into one. Setting an ingress `tls.secretName` renders
`spec.tls.externalCertificate`, which points the router at the Secret:

```yaml
control-plane-app:
  controlPlane:
    components:
      app:
        ingress:
          tls:
            secretName: control-plane-app-tls   # cert-manager, etc.
```

This requires OpenShift 4.17+ (`externalCertificate` is GA there) and the router
service account needs read access to the Secret in the release namespace. On
older clusters either rely on the router's default wildcard certificate (omit
`secretName`) or supply `tls.certificate` / `tls.key` inline — inline values are
emitted verbatim and therefore land in Helm release history, so prefer
`secretName`.

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

3. With empty base domains and empty `additionalHosts`, the chart derives
   `GATEWAY_BASE_DOMAIN=llm.<domain>`, `MCP_BASE_DOMAIN=mcp.<domain>`, and
   auto-adds `*.llm.<domain>` / `*.mcp.<domain>` Ingress/Route hosts. Exact
   primary hosts still require the gateway header; wildcard slug hosts do not.
   Explicit `additionalHosts` remain authoritative when set. See
   [docs/architecture.md](./docs/architecture.md).

## Self-hosted external mode

Layer the external topology over the OpenShift values:

```bash
helm upgrade --install neuraltrust-platform <chart> \
  --namespace neuraltrust \
  -f values-openshift.yaml \
  -f values-external.yaml.example \
  --set global.platform=openshift \
  --set global.domain=apps.example.com
```

The two files disagree on purpose: `values-openshift.yaml` sets
`deploymentMode: hybrid` and `values-external.yaml.example` sets
`platform: kubernetes`. Ordering external last wins the mode, and the explicit
`--set global.platform=openshift` restores the platform. `global.ingress.provider`
from the OpenShift file is untouched by either.

External mode runs the product API/app, control and data planes, DataCore,
AlertEngine, and the ClickStack OTel Collector in the cluster. DataAgent is
absent, and no config-sync or enrolment Secrets are needed. Set
`global.observability.hostedExport.enabled: false` for a no-egress deployment.

Full walkthrough, including the bootstrap admin Secret and ClickHouse sizing:
[README-EXTERNAL.md](./README-EXTERNAL.md).

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

Render with the same file list you install with — `values-openshift.yaml` alone
does not select any product and will fail validation:

```bash
helm lint <chart> -f values-required.yaml -f values-openshift.yaml
helm template neuraltrust-platform <chart> \
  --namespace neuraltrust \
  -f values-required.yaml \
  -f values-openshift.yaml \
  --api-versions route.openshift.io/v1
```

---

<sup>**Looking for v1?** The legacy TrustGate/Kafka line ended at [v1.14.16](https://github.com/NeuralTrust/neuraltrust-platform/releases?page=3#release-v1.14.16) — install it with `--version ~1.14.0`.</sup>
