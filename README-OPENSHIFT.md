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

Hybrid always dual-writes to the NeuralTrust SaaS ClickStack collector; supply
the bearer token via `--set global.clickstack.authToken=<token>` or an
`existingSecret` reference (see [SECRETS.md](./SECRETS.md)).

DataAgent stays disabled until the deployment is enrolled. Add the tenant and
enrolment token only after they are issued.

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

3. Set AgentGateway discovery to match the public zones:

   ```yaml
   agentgateway:
     config:
       gatewayDiscoveryMode: "subdomain"
       gatewayBaseDomain: "llm.apps.example.com"
       mcpBaseDomain: "mcp.apps.example.com"
     ingress:
       dataPlane:
         additionalHosts: ["*.llm.apps.example.com"]
       mcp:
         additionalHosts: ["*.mcp.apps.example.com"]
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
absent. Disable hosted export for a no-egress deployment.

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
