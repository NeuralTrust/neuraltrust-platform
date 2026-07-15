# OpenShift Deployment Guide

The default OpenShift path is Platform v2 hybrid with native Routes.

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
  platformVersion: "v2"
  deploymentMode: "hybrid"
  platform: "openshift"
```

DataAgent stays disabled until the deployment is enrolled. Add the tenant and
enrolment token only after they are issued.

## Routes and Ingress

With `global.platform: openshift`, native Routes are the default. Use
`values-openshift-ingress.yaml.example` when the cluster standardizes on
Kubernetes Ingress.

Both paths use `global.domain`. Route names remain stable; Ingress hostnames are
derived from each v2 service's `hostPrefix`.

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

External mode runs the product API/app, v2 control and data planes, DataCore,
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

For v2, confirm Kafka, Kafka Connect, Kafka workers, AISPM, and the legacy SIEM
Connector do not render.

## Legacy v1

Legacy OpenShift deployments must pin `global.platformVersion: v1` explicitly.
Use `values-v1-legacy.yaml.example` as the base, then apply OpenShift provider
settings. New OpenShift deployments should not enable the retired AISPM or SIEM
Connector components.
