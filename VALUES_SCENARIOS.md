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

---

## Firewall: CPU and GPU

The firewall is controlled by `neuraltrust-firewall.firewall.enabled` (default: `false`). It deploys a **gateway** (CPU router) plus **5 specialized workers**.

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
