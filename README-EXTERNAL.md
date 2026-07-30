# External (Self-Hosted) Deployment Guide

`external` mode runs the **entire** platform in your cluster — control planes, data planes, the console, and the analytics stack. No
NeuralTrust-hosted control plane and no DataAgent.

Use this guide when payload data, telemetry, and configuration must never leave
your environment. For the default hosted-control-plane path, see the
[hybrid quick start](./README.md#quick-start-hybrid).

## Hybrid vs external

| | `hybrid` (default) | `external` |
|---|---|---|
| Console / control plane | Hosted by NeuralTrust | `control-plane-app` + `control-plane-api` in your cluster |
| Product selection | `global.products` flags, at least one `true` | **Flags ignored** — full stack always deploys |
| Analytics store | Hosted, via enrolment-backed OTLP egress | In-cluster or managed **ClickHouse** |
| Telemetry collector | `clickstack-egress-collector` sidecar on DataAgent | `clickstack-collector` Deployment writing to ClickHouse |
| DataAgent | One per enabled product | **Never renders** |
| Config-sync | On by default, needs console tokens | Off — configuration lives in PostgreSQL |
| Air-gap capable | No (product OTLP egress is mandatory) | Yes |

## Prerequisites

- A Kubernetes cluster with an ingress controller, and Helm 3.8+ for OCI installs
- **4–5 worker nodes at 8 vCPU / 16–32 GiB** — external adds the control plane,
  ClickHouse, ClickStack collector, DataCore, and AlertEngine on top of the data
  path. See [`docs/sizing.md`](./docs/sizing.md)
- A base domain you can point at the cluster ingress, plus TLS certificates for
  it
- The NeuralTrust registry pull secret in the release namespace, or all images
  mirrored into your own registry
- A storage class for the ClickHouse and PostgreSQL volumes

## Quick start

### 1. Create the namespace and image pull secret

```bash
kubectl create namespace neuraltrust

GCR_KEY_FILE=./gcr-keys.json ./create-image-pull-secret.sh --namespace neuraltrust
```

### 2. Create the bootstrap admin Secret

External mode has no hosted console to log into, so the first administrator is
seeded from a Secret. Keys default to `ONPREM_SUPERADMIN_EMAIL` and
`ONPREM_SUPERADMIN_PASSWORD`:

```bash
kubectl create secret generic onprem-superadmin -n neuraltrust \
  --from-literal=ONPREM_SUPERADMIN_EMAIL='admin@example.com' \
  --from-literal=ONPREM_SUPERADMIN_PASSWORD='<strong-password>'
```

Inline `global.superadmin.email` + `password` also works, but those values enter
Helm release history — prefer the Secret. Leaving both unset leaves the bootstrap
admin off entirely.

Unlike hybrid, external needs **no** config-sync tokens and **no** DataAgent
enrolment JWTs. Every other credential is generated on first install and reused
on upgrade while `global.autoGenerateSecrets: true` — see [SECRETS.md](./SECRETS.md).

### 3. Write your values file

[`values-external.yaml.example`](./values-external.yaml.example) is the
tracked minimal external overlay:

```yaml
global:
  deploymentMode: "external"
  platform: "kubernetes" # aws | gcp | azure | openshift | kubernetes
  domain: "platform.example.com"
  superadmin:
    existingSecret:
      name: "onprem-superadmin"
  observability:
    hostedExport:
      enabled: false
```

`global.products` flags are not needed — external always deploys the full stack.
`hostedExport.enabled: false` removes the umbrella collector's hosted telemetry
exporter; keep it `false` for no-egress deployments.

### 4. Install

```bash
helm upgrade --install neuraltrust-platform \
  oci://europe-west1-docker.pkg.dev/neuraltrust-app-prod/helm-charts/neuraltrust-platform \
  --version <VERSION> \
  --namespace neuraltrust --create-namespace \
  -f values-external.yaml.example
```

### 5. Verify

```bash
kubectl get pods -n neuraltrust
kubectl get ingress -n neuraltrust
```

Default hostnames derive from `global.domain`:

| Service | Host |
|---|---|
| Console (web app) | `app.<domain>` |
| Control-plane API | `api.<domain>` |
| TrustGate LLM gateway | `gateway.<domain>` and `*.llm.<domain>` |
| TrustGate MCP | `mcp.<domain>` and `*.mcp.<domain>` |
| TrustGate Admin | `admin.<domain>` |
| TrustGuard | `trustguard.<domain>` |
| TrustGuard Admin | `trustguard-admin.<domain>` |
| data-plane API | `data-plane-api.<domain>` |

Point DNS at the ingress address, then log in at `https://app.<domain>` with the
bootstrap admin credentials from step 2 and rotate the password.

## What external deploys

Everything hybrid runs, plus:

| Component | Role |
|---|---|
| `agentgateway-admin` | TrustGate control plane |
| `trustguard-control-plane` | TrustGuard control plane |
| `control-plane-api` | Platform API |
| `control-plane-app` | Console web application; runs Prisma migrations and seed on start |
| `clickstack-collector` (values key `clickstack-otel-collector:`) | Receives product OTLP on 4317/4318, writes to ClickHouse |
| `clickhouse` | Analytics store (StatefulSet, external mode only) |
| `datacore` | Residency and analytics queries over landed telemetry |
| `alertengine-api` / `alertengine-worker` | Rule evaluation, alert state, SIEM and integration forwarding |

Absent in external: `dataagent`, `dataagent-trustguard`, and the
`clickstack-egress-collector` sidecar.

The analytics path is:

```text
OTLP senders -> ClickStack OTel Collector -> ClickHouse
                                            |-> DataCore
                                            `-> AlertEngine -> SIEM/integrations
```

AlertEngine is the supported detection, SIEM, and integration path for external
deployments. Disabling hosted observability export does not disable AlertEngine
or the ClickStack-to-ClickHouse pipeline. See
[`docs/observability.md`](./docs/observability.md).

## Datastores

External mode uses PostgreSQL, Redis, **and** ClickHouse. All three deploy
in-cluster by default.

Unlike hybrid's single shared PostgreSQL role, external runtime services use
per-service `*.database` / `*.redis` blocks — each control plane owns its own
database and migrations. `global.postgresql` still gates in-cluster PostgreSQL
and feeds `postgresql-secrets` for control-plane-api/app.

To use managed services:

```yaml
global:
  postgresql:
    deploy: false
  redis:
    deploy: false

infrastructure:
  clickhouse:
    deploy: false
    external:
      host: "clickhouse.example.com"
      port: "8443"
      secretName: "managed-clickhouse"
      secretKey: "password"
```

Pre-create every PostgreSQL role and database before installing — there is no
chart-managed init Job. DataCore, AlertEngine, the ClickStack collector, and
`data-plane-api` all read one shared ClickHouse credential; point their
`clickhouse.existingSecret` at your secret when using a managed cluster. Complete
pattern: [`values-managed-datastores.yaml.example`](./values-managed-datastores.yaml.example).

In-cluster ClickHouse defaults to a 50 GiB volume with a ~4 GiB memory request.
Size the volume for your retention window before first install.

## Air-gapped and disconnected clusters

```yaml
global:
  deploymentMode: "external"
  imageRegistry: "<registry>/neuraltrust"
  observability:
    hostedExport:
      enabled: false
```

Mirror **every** required image, including the ClickHouse and ClickStack
collector images. With hosted export and observability off, `imageRegistry`
rewrites the full external image set on its own — verify with
`helm template ... | grep image:`. If you enable `global.observability`, also
override `global.observability.collector.image.repository`; that one repository
is pinned in full and `imageRegistry` does not rewrite it.

Create the pull Secret for your mirror as `gcr-secret`, the name every component
defaults to. The umbrella collector keeps collecting locally, ClickStack keeps
writing to your ClickHouse, and AlertEngine keeps forwarding to destinations
reachable from the cluster.

The hybrid network allowlist in [`docs/hybrid-network.md`](./docs/hybrid-network.md)
does **not** apply — external needs no outbound path to NeuralTrust.

### Login CAPTCHA can lock admins out

The published `control-plane-app` images embed a Cloudflare Turnstile **site**
key and show a CAPTCHA after three failed logins. The matching **secret** key is
a runtime value the chart does not set, and verification calls
`challenges.cloudflare.com` directly. Without that key — or without egress to
Cloudflare — a user who mistypes a password three times cannot log in until the
pod gets the key or the browser state is cleared. An air-gapped install needs an
image built without a site key. Details and the `extraEnv` workaround are in
[SECRETS.md](./SECRETS.md#login-captcha-turnstile_secret_key--can-lock-users-out).

## Platform and ingress

`global.platform` selects provider-specific ingress and security behavior
(`gcp`, `aws`, `azure`, `openshift`, `kubernetes`). On OpenShift, layer the
external overlay over the OpenShift values:

```bash
helm upgrade --install neuraltrust-platform <chart> \
  --namespace neuraltrust \
  -f values-openshift.yaml \
  -f values-external.yaml.example \
  --set global.domain=apps.example.com
```

See [README-OPENSHIFT.md](./README-OPENSHIFT.md) for Routes, wildcard Route
prerequisites, and Security Context Constraints.

## Optional components

- `firewall`: always on in external (CPU workers by default; GPU via
  [`values-dataplane-gpu.yaml.example`](./values-dataplane-gpu.yaml.example))
- `trustlens`: opt-in analytics/inventory service; requires `trustlens.image.tag`
- `watchdog`: dry-run-first self-monitoring and self-healing
- umbrella OTel Collector: portable cluster observability, separate from
  ClickStack

## Validate before rollout

```bash
helm lint <chart> -f values-external.yaml.example
helm template neuraltrust-platform <chart> \
  --namespace neuraltrust \
  -f values-external.yaml.example > /tmp/rendered-external.yaml
```

Add `--api-versions route.openshift.io/v1` when rendering for OpenShift.

## Upgrades

Generated secrets are reused through Helm `lookup`. Deployment engines that
cannot use `lookup` should pre-create secrets and set
`global.preserveExistingSecrets: true` — in external mode that requires
`AUTH_SECRET` and `NEXTAUTH_SECRET` to already exist in `control-plane-secrets`.
Persistent volume claims are retained by default. Review release notes before
each upgrade.

## Further reading

- [Hybrid quick start](./README.md#quick-start-hybrid)
- [OpenShift guide](./README-OPENSHIFT.md)
- [Deployment guide](./DEPLOYMENT.md)
- [Secrets management](./SECRETS.md)
- [Values scenarios](./VALUES_SCENARIOS.md)
- [Architecture and topology contract](./docs/architecture.md)
- [Observability and self-healing](./docs/observability.md)
- [Cluster sizing](./docs/sizing.md)
- Public docs: [External (self-hosted)](https://docs.neuraltrust.ai/neuraltrust/deployment/external) ·
  [Deployment models](https://docs.neuraltrust.ai/neuraltrust/deployment/deployment-models) ·
  [Configuration](https://docs.neuraltrust.ai/neuraltrust/deployment/configuration) ·
  [Sizing](https://docs.neuraltrust.ai/neuraltrust/deployment/sizing)

---

<sup>**Looking for v1?** The legacy TrustGate/Kafka line ended at [v1.14.16](https://github.com/NeuralTrust/neuraltrust-platform/releases?page=3#release-v1.14.16) — install it with `--version ~1.14.0`.</sup>
