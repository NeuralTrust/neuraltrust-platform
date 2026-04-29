# Values Files and Scenarios

Side-by-side reference for all provided values files and common configuration scenarios.

## Values files

### `values-required.yaml` — Minimal starting template

Smallest possible configuration. All other options use chart defaults. Secrets are auto-generated.

```bash
# Zero-config deploy
helm upgrade --install neuraltrust-platform . --namespace neuraltrust --create-namespace

# With overrides
cp values-required.yaml my-values.yaml
helm upgrade --install neuraltrust-platform . --namespace neuraltrust --create-namespace -f my-values.yaml
```

### `values.yaml` — Full reference

Every available option with inline comments. Use as a reference or copy to customize everything.

```bash
cp values.yaml my-values.yaml
helm upgrade --install neuraltrust-platform . --namespace neuraltrust --create-namespace -f my-values.yaml
```

### `values-openshift.yaml` — OpenShift with Routes

Pre-configured for OpenShift: Routes enabled, Ingress disabled, relaxed security contexts.

```yaml
global:
  platform: "openshift"
  domain: "apps.mycluster.example.com"
```

```bash
helm upgrade --install neuraltrust-platform . -f values-openshift.yaml \
  --set global.domain="apps.mycluster.example.com"
```

> **Note:** The deprecated `global.openshift: true` / `global.openshiftDomain` fields still work. Prefer `global.platform` and `global.domain`.

### `values-openshift-ingress.yaml.example` — OpenShift with Ingress

OpenShift using Kubernetes Ingress instead of Routes. TLS via existing wildcard certificates.

```bash
cp values-openshift-ingress.yaml.example my-values.yaml
# Set domain, image pull secrets, and ingress class
helm upgrade --install neuraltrust-platform . -f my-values.yaml
```

### `values-all-deployed.yaml.example` — Everything enabled

All infrastructure and services deployed. Use as a reference for what a complete deployment looks like.

### `values-external-services.yaml.example` — External infrastructure

ClickHouse, Kafka, and PostgreSQL provided externally. Only NeuralTrust services and TrustGate are deployed in-cluster.

### `values-dataplane-gpu.yaml.example` — Data Plane + GPU firewall

Full stack with GPU firewall workers and TrustGate disabled. Includes GPU scheduling, CUDA MPS, and node selector placeholders.

```bash
cp values-dataplane-gpu.yaml.example my-values.yaml
# Set hosts, secrets, GPU node labels, and pool names
helm upgrade --install neuraltrust-platform . --namespace neuraltrust --create-namespace -f my-values.yaml
```

For CPU-only firewall, use chart defaults (`firewall-cpu` image, no GPU keys).

---

## Configuration scenarios

### Scenario 1: Kubernetes with Ingress

**File:** `values-required.yaml` or `values.yaml`

```yaml
global:
  platform: "aws"  # or "gcp", "azure", "kubernetes"
  domain: "platform.example.com"
```

### Scenario 2: OpenShift with Routes

**File:** `values-openshift.yaml`

```yaml
global:
  platform: "openshift"
  domain: "apps.mycluster.example.com"
```

### Scenario 3: OpenShift with Ingress

**File:** Based on `values-openshift-ingress.yaml.example`

```yaml
global:
  platform: "openshift"
  domain: "apps.mycluster.example.com"
  ingress:
    provider: "openshift"

trustgate:
  ingress:
    enabled: true
```

### Scenario 4: External infrastructure only

**File:** Based on `values-external-services.yaml.example`

```yaml
infrastructure:
  clickhouse:
    deploy: false
    external:
      host: "clickhouse.example.com"
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
```

### Scenario 5: No TrustGate

**File:** Based on `values-required.yaml` or `values-dataplane-gpu.yaml.example`

```yaml
trustgate:
  enabled: false

neuraltrust-control-plane:
  controlPlane:
    enabled: true

neuraltrust-data-plane:
  dataPlane:
    enabled: true
```

### Scenario 6: Pre-generated secrets (CI/CD)

**File:** Custom values

```yaml
global:
  autoGenerateSecrets: false
  preserveExistingSecrets: true
```

All secrets must exist in the namespace before deployment. See [SECRETS.md](./SECRETS.md).

### Scenario 7: Zero-config

**File:** None required

```bash
helm upgrade --install neuraltrust-platform . --namespace neuraltrust --create-namespace
```

### Scenario 8: ClickHouse backups to object storage

**File:** Custom values

```yaml
clickhouse:
  backup:
    enabled: true
    schedule: "0 2 * * *"
    storage:
      type: s3              # or "azblob"
      s3:
        endpoint: "https://s3.eu-west-1.amazonaws.com/my-bucket/clickhouse-backups"
        accessKeyId: ""     # empty = use IAM/IRSA/Workload Identity
        secretAccessKey: ""
```

For GCS, use `https://storage.googleapis.com/<bucket>/<prefix>` and Workload Identity. See [DEPLOYMENT.md](./DEPLOYMENT.md#clickhouse-backups) for full configuration.

### Scenario 9: Auto-derive Ingress hostnames from `global.domain`

**File:** any

When `global.domain` is set, every Ingress auto-fills its host. No per-service `host` is needed for the common case.

```yaml
global:
  domain: "platform.example.com"
```

Yields: `admin.platform.example.com`, `gateway.platform.example.com`, `actions.platform.example.com`, `api.platform.example.com`, `app.platform.example.com`, `scheduler.platform.example.com`, `data-plane-api.platform.example.com`.

Override per service:

```yaml
trustgate:
  ingress:
    controlPlane:
      host: "tg-admin.example.com"   # full hostname override
    dataPlane:
      hostPrefix: "tg"               # change subdomain only
```

Disable auto-derive (catch-all) by setting `hostPrefix: ""`. OpenShift Routes are unaffected. Full table of default prefixes in [DEPLOYMENT.md](./DEPLOYMENT.md#ingress-hostnames).

### Scenario 10: Mirror images to a private registry

**File:** any

Set once at the parent level and every subchart inherits:

```yaml
global:
  imageRegistry: "my-registry.corp/neuraltrust"
```

The image helpers strip the chart's default GCP prefix and prepend yours, so no per-component override is needed when you mirror with the same short names.

Need different tags or renamed paths? Override per component:

```yaml
neuraltrust-control-plane:
  controlPlane:
    components:
      api:
        image:
          repository: "my-registry.corp/cp-api"   # renamed path
          tag: "v1.13.9-corp1"                    # custom tag
```

When `image.repository` starts with your registry's host, the helper uses it as-is. See [DEPLOYMENT.md](./DEPLOYMENT.md#private--mirrored-image-registry) for the full list of components and the resolution rules.

### Scenario 11: Inject custom environment variables

**File:** Custom values

```yaml
neuraltrust-data-plane:
  dataPlane:
    components:
      api:
        extraEnv:
          - name: LOG_LEVEL
            value: "debug"
        extraEnvFrom:
          - configMapRef:
              name: feature-flags
```

Available on every main service container. See [DEPLOYMENT.md](./DEPLOYMENT.md#custom-environment-variables) for the full list of supported components.

---

## Firewall: CPU and GPU

The firewall is controlled by `neuraltrust-firewall.firewall.enabled` (default: `true`, CPU image). It deploys a **gateway** (CPU router) plus **5 specialized workers**. Disable with `enabled: false` if your environment doesn't need in-cluster prompt/response safety.

| Component | Image | Scheduling | CUDA MPS |
|---|---|---|---|
| Gateway | `firewall-cpu` | CPU only | N/A |
| Workers (default) | `firewall-cpu` | CPU only | Omit MPS keys |
| Workers (GPU) | `firewall-gpu` | Override image, add `nvidia.com/gpu`, `nodeSelector`, `tolerations`, `hostIPC` | Set `cudaMpsActiveThreadPercentage` + `cudaMpsPinnedDeviceMemLimit` |

CUDA MPS env vars are only rendered in the ConfigMap when **both** keys are set.

**Reference files:** `values-dataplane-gpu.yaml.example` (GPU, no TrustGate), `values.yaml` (full options).

---

## Secret management modes

| Mode | Flags | Behavior | Best for |
|---|---|---|---|
| Auto-generated (default) | `autoGenerateSecrets: true` | Helm creates and preserves secrets | Dev, staging, quick starts |
| Explicit values | `autoGenerateSecrets: true` + values set | Your values override auto-generation | Controlled environments |
| Pre-generated | `preserveExistingSecrets: true` | Helm never touches secrets | Vault, Sealed Secrets, compliance |

When `preserveExistingSecrets: true`, these secrets must exist:

- `clickhouse` — `admin-password`
- `postgresql-secrets` — `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`, `DATABASE_URL`, etc.
- `control-plane-secrets` — `CONTROL_PLANE_JWT_SECRET`, `TRUSTGATE_JWT_SECRET`, etc.
- `data-plane-jwt-secret` — `DATA_PLANE_JWT_SECRET`
- `trustgate-secrets` — `SERVER_SECRET_KEY`, `DATABASE_PASSWORD`, and optionally `NEURAL_TRUST_FIREWALL_URL`, `NEURAL_TRUST_FIREWALL_SECRET_KEY`

Optional: `openai-secrets`, `google-secrets`, `resend-secrets`, `huggingface-secrets`

See [SECRETS.md](./SECRETS.md) for the complete reference.

---

## Ingress vs Routes

| Feature | Ingress | Routes (OpenShift) |
|---|---|---|
| Platform | Any Kubernetes | OpenShift only |
| Controller | Required (NGINX, ALB, GCE, etc.) | Built-in |
| TLS | `kubernetes.io/tls` secrets or cloud-managed | OpenShift router |
| Enable | `ingress.enabled: true` per component | Default when `platform: "openshift"` |

---

## Quick reference

| Scenario | Values file | Platform | Ingress | Routes | Secrets |
|---|---|---|---|---|---|
| Zero-config | None (defaults) | Any | No | No | Auto |
| Kubernetes | `values-required.yaml` | `aws`/`gcp`/`azure`/`kubernetes` | Yes | No | Auto |
| OpenShift (Routes) | `values-openshift.yaml` | `openshift` | No | Yes | Auto |
| OpenShift (Ingress) | `values-openshift-ingress.yaml.example` | `openshift` | Yes | No | Pre-gen |
| Everything on | `values-all-deployed.yaml.example` | Configurable | Yes | Configurable | Auto |
| External infra | `values-external-services.yaml.example` | Configurable | Yes | Configurable | Auto |
| GPU firewall | `values-dataplane-gpu.yaml.example` | Configurable | Yes | Configurable | Explicit |
