# NeuralTrust Platform

Deploy the complete NeuralTrust AI governance and runtime security stack on any Kubernetes cluster with a single Helm chart.

## What's included

| Component | Description |
|---|---|
| **TrustGate** | Low-latency AI gateway with plugin system and admin API |
| **Control Plane** | Management API, product UI, and scheduler |
| **Data Plane** | Telemetry and analytics API with Kafka workers |
| **Firewall** *(optional)* | Prompt and response safety — gateway + ML worker pool (CPU or GPU) |
| **ClickHouse** | Analytics database (in-cluster or external) |
| **Kafka** | Event streaming (in-cluster or external) |
| **PostgreSQL** | Relational store (in-cluster or external) |

Every component is independently toggleable via feature flags. Enable only what you need.

## Quick start

### 1. Install from OCI registry (recommended)

```bash
helm upgrade --install neuraltrust-platform \
  oci://europe-west1-docker.pkg.dev/neuraltrust-app-prod/helm-charts/neuraltrust-platform \
  --version <VERSION> \
  --namespace neuraltrust --create-namespace
```

Replace `<VERSION>` with a [release version](https://github.com/NeuralTrust/neuraltrust-platform/releases) (e.g. `1.10.0`).

That's it. All secrets are **auto-generated** on first install and preserved on upgrades.

### 2. Customize (optional)

Copy the minimal values template and override only what you need:

```bash
curl -sLO https://raw.githubusercontent.com/NeuralTrust/neuraltrust-platform/main/values-required.yaml
cp values-required.yaml my-values.yaml
```

Edit `my-values.yaml`, then deploy:

```bash
helm upgrade --install neuraltrust-platform \
  oci://europe-west1-docker.pkg.dev/neuraltrust-app-prod/helm-charts/neuraltrust-platform \
  --version <VERSION> \
  --namespace neuraltrust --create-namespace \
  -f my-values.yaml
```

### Alternative install methods

<details>
<summary>Download tarball from a GitHub Release</summary>

```bash
curl -sLO https://github.com/NeuralTrust/neuraltrust-platform/releases/download/v<VERSION>/neuraltrust-platform-<VERSION>.tgz
helm upgrade --install neuraltrust-platform ./neuraltrust-platform-<VERSION>.tgz \
  --namespace neuraltrust --create-namespace -f my-values.yaml
```

</details>

<details>
<summary>Clone source at a release tag</summary>

Use this only when you need to inspect or modify the chart source.

```bash
git clone --branch v<VERSION> --depth 1 https://github.com/NeuralTrust/neuraltrust-platform.git
cd neuraltrust-platform
helm dependency update
helm upgrade --install neuraltrust-platform . \
  --namespace neuraltrust --create-namespace -f my-values.yaml
```

</details>

## Platform support

Set `global.platform` to match your target environment. The chart auto-configures ingress, security contexts, and annotations accordingly.

| Platform | Value | Ingress | Notes |
|---|---|---|---|
| GCP (GKE) | `gcp` | GCE load balancer | Default. Supports NEG, PSC, managed certificates |
| AWS (EKS) | `aws` | ALB via AWS LB Controller | Supports ACM, WAF, target groups |
| Azure (AKS) | `azure` | Application Gateway (AGIC) | Supports AGIC SSL, WAF policies |
| OpenShift | `openshift` | Routes (default) or Ingress | See [OpenShift guide](./README-OPENSHIFT.md) |
| Generic K8s | `kubernetes` | Bring your own controller | No cloud-specific annotations |

```yaml
global:
  platform: "aws"          # your cloud provider
  domain: "example.com"    # base domain for service URLs
```

## Ingress hostnames

When `global.domain` is set, every Ingress auto-fills its hostname as `<prefix>.<global.domain>`. No per-service host configuration is required for the common case.

| Service | Default prefix | Resolves to |
|---|---|---|
| TrustGate Admin | `admin` | `admin.<global.domain>` |
| TrustGate Gateway | `gateway` | `gateway.<global.domain>` |
| TrustGate Actions | `actions` | `actions.<global.domain>` |
| Control Plane API | `api` | `api.<global.domain>` |
| Control Plane App | `app` | `app.<global.domain>` |
| Scheduler | `scheduler` | `scheduler.<global.domain>` |
| Data Plane API | `data-plane-api` | `data-plane-api.<global.domain>` |

Resolution priority per service:

```
explicit .host  >  <hostPrefix>.<global.domain>  >  empty (catch-all)
```

Override per service in either way:

```yaml
trustgate:
  ingress:
    controlPlane:
      host: "tg-admin.example.com"   # full hostname override
    dataPlane:
      hostPrefix: "tg"               # subdomain only → tg.<global.domain>

neuraltrust-control-plane:
  controlPlane:
    components:
      app:
        hostPrefix: ""               # disable auto-derive (catch-all)
```

OpenShift Routes are unaffected — they use their existing `<service-name>.<domain>` long-prefix derivation. See [README-OPENSHIFT.md](./README-OPENSHIFT.md).

## Image pull secret

NeuralTrust container images are hosted in a private registry. You will receive a JSON key file from NeuralTrust.

```bash
# Using the provided script
./create-image-pull-secret.sh --namespace neuraltrust

# Or manually
kubectl create secret docker-registry gcr-secret \
  --docker-server=europe-west1-docker.pkg.dev \
  --docker-username=_json_key \
  --docker-password="$(cat path/to/gcr-keys.json)" \
  --docker-email=admin@neuraltrust.ai \
  -n neuraltrust
```

## Private / mirrored image registry

If your environment cannot reach `europe-west1-docker.pkg.dev`, mirror the images to your own registry and set `global.imageRegistry`. Every subchart inherits this setting.

```yaml
global:
  imageRegistry: "my-registry.corp/neuraltrust"
```

The chart helpers automatically strip the default GCP prefix and prepend your registry, so `europe-west1-docker.pkg.dev/neuraltrust-app-prod/nt-docker/control-plane-api` becomes `my-registry.corp/neuraltrust/control-plane-api` with no other changes required.

Three escalating customization levels:

| You mirror images with… | What to override |
|---|---|
| Same short names, same tags | only `global.imageRegistry` |
| Same short names, custom tags | `global.imageRegistry` + per-component `image.tag` |
| Renamed paths (e.g. `my-registry.corp/cp-api`) | `global.imageRegistry` + per-component `image.repository` and `image.tag` |

For renamed paths, set `image.repository` to the **full path** starting with your registry host. The helper detects the host already matches and uses the value as-is. See `accounts/unicaja/values-unicaja-pre-v2.yaml` for a worked example with mixed namespaces (`docker-neuraltrust/...` plus `hub/postgres`, `hub/redislabs/...`).

Verify rendered images before rolling out:

```bash
helm template . -f my-values.yaml | grep -E '^\s+image:' | sort -u
```

## Secrets

Secrets are **auto-generated by default** (`global.autoGenerateSecrets: true`). No manual setup is required for a working deployment.

| What happens | When |
|---|---|
| Secrets are generated automatically | First `helm install` |
| Existing secrets are preserved | Every `helm upgrade` |
| Your explicit values win | When you set a non-empty value |
| `SERVER_SECRET_KEY` = `TRUSTGATE_JWT_SECRET` | Always synchronized |

For production environments with Vault, Sealed Secrets, or External Secrets Operator, see the [Secrets Management Guide](./SECRETS.md).

## Infrastructure options

Each infrastructure component can be deployed in-cluster or pointed at an external instance.

### In-cluster (default)

```yaml
infrastructure:
  clickhouse:
    deploy: true
  kafka:
    deploy: true

neuraltrust-control-plane:
  infrastructure:
    postgresql:
      deploy: true
```

### External services

```yaml
infrastructure:
  clickhouse:
    deploy: false
    external:
      host: "clickhouse.example.com"
      port: "8123"
      user: "neuraltrust"
      password: ""  # use --set or pre-created secret
      database: "neuraltrust"

  kafka:
    deploy: false
    external:
      bootstrapServers: "kafka.example.com:9092"

neuraltrust-control-plane:
  infrastructure:
    postgresql:
      deploy: false
  controlPlane:
    components:
      postgresql:
        secrets:
          host: "postgres.example.com"
          port: "5432"
          user: "neuraltrust"
          password: ""  # use --set or pre-created secret
          database: "neuraltrust"
```

## Component toggles

Enable or disable any component:

```yaml
neuraltrust-data-plane:
  dataPlane:
    enabled: true       # Data Plane API + workers

neuraltrust-control-plane:
  controlPlane:
    enabled: true       # Control Plane API + UI + scheduler

trustgate:
  enabled: true         # TrustGate AI gateway

neuraltrust-firewall:
  firewall:
    enabled: true       # Firewall gateway + workers (on by default, CPU image)
```

## Corporate proxy

For environments behind a forward proxy:

```yaml
global:
  proxy:
    enabled: true
    httpProxy: "http://proxy.corp.example:3128"
    httpsProxy: "http://proxy.corp.example:3128"
    noProxy: "localhost,127.0.0.1,.cluster.local,.svc"
```

## Custom environment variables

Inject extra environment variables into any service container without forking the chart. Every main service exposes `extraEnv` and `extraEnvFrom`:

```yaml
neuraltrust-data-plane:
  dataPlane:
    components:
      api:
        extraEnv:
          - name: LOG_LEVEL
            value: "debug"
          - name: CUSTOM_API_KEY
            valueFrom:
              secretKeyRef:
                name: my-secrets
                key: API_KEY
        extraEnvFrom:
          - configMapRef:
              name: my-feature-flags
```

Available on: control plane (api, app, scheduler), data plane (api, worker), TrustGate (control-plane, data-plane, actions), and firewall (gateway, workers).

## ClickHouse backups

Schedule automated ClickHouse backups to S3, GCS, or Azure Blob Storage:

```yaml
clickhouse:
  backup:
    enabled: true
    schedule: "0 2 * * *"  # daily at 2 AM UTC
    storage:
      type: s3            # or "azblob"
      s3:
        endpoint: "https://s3.eu-west-1.amazonaws.com/my-bucket/clickhouse-backups"
        accessKeyId: ""   # leave empty to use IAM / IRSA / Workload Identity
        secretAccessKey: ""
```

For GCS, use the S3-compatible endpoint `https://storage.googleapis.com/<bucket>/<prefix>`. For Workload Identity on GKE, set `backup.serviceAccount.create: true` and add the IAM annotation. See the `clickhouse.backup.*` section in `values.yaml` for all options.

## TLS certificates

The chart supports three approaches:

| Method | When to use |
|---|---|
| **Self-signed** (default) | Quick starts — chart creates a shared TLS secret automatically |
| **Pre-existing secrets** | You manage certificates externally and reference them by `secretName` |
| **cert-manager** | Automatic issuance via Let's Encrypt or internal CA |

See `global.ingress.tls.*` in `values.yaml` for configuration details.

## Upgrading

```bash
helm upgrade neuraltrust-platform \
  oci://europe-west1-docker.pkg.dev/neuraltrust-app-prod/helm-charts/neuraltrust-platform \
  --version <NEW_VERSION> \
  --namespace neuraltrust \
  -f my-values.yaml
```

Secrets and persistent data are preserved automatically. See the [release notes](https://github.com/NeuralTrust/neuraltrust-platform/releases) for any version-specific migration steps.

## Uninstalling

```bash
helm uninstall neuraltrust-platform --namespace neuraltrust
```

Persistent volume claims are retained by default to prevent accidental data loss.

## Values files reference

| File | Purpose |
|---|---|
| `values-required.yaml` | Minimal starting template — recommended for first-time setup |
| `values.yaml` | Complete reference with all options and inline comments |
| `values-openshift.yaml` | Pre-configured for OpenShift with Routes |
| `values-external-services.yaml.example` | External ClickHouse, Kafka, and PostgreSQL |
| `values-dataplane-gpu.yaml.example` | Data Plane + GPU firewall workers |
| `values-all-deployed.yaml.example` | Everything enabled |
| `values-openshift-ingress.yaml.example` | OpenShift with Ingress instead of Routes |

## Further reading

| Guide | Description |
|---|---|
| [Deployment Guide](./DEPLOYMENT.md) | Deployment scenarios, firewall setup, connection details, and troubleshooting |
| [OpenShift Guide](./README-OPENSHIFT.md) | OpenShift-specific configuration, Routes, SCC, and troubleshooting |
| [Secrets Guide](./SECRETS.md) | Secret names, keys, auto-generation behavior, and external secret managers |
| [Values Scenarios](./VALUES_SCENARIOS.md) | Side-by-side comparison of all values files and configuration scenarios |

## Support

- [Documentation](https://docs.neuraltrust.ai)
- [Slack Community](https://join.slack.com/t/neuraltrustcommunity/shared_invite/zt-2xl47cag6-_HFNpltIULnA3wh4R6AqBg)
- [Report Issues](https://github.com/NeuralTrust/neuraltrust-platform/issues)

## License

Apache License 2.0
