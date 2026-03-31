# Values Files Scenarios Guide

This document explains the different values files available and when to use each one.

## Available Values Files

### 1. `values-required.yaml` - Minimal / Required-Only Configuration
**Use case:** Minimal, working deployment with only required settings

**Features:**
- Minimal configuration; all other options use chart defaults
- All secrets auto-generated if left empty (`autoGenerateSecrets: true`)
- Kubernetes cluster (set `global.openshift: true` for OpenShift)
- Deploys all infrastructure and services by default

**Usage:** Deploy with defaults (zero-config) or customize:
```bash
# Zero-config deploy (all secrets auto-generated):
helm upgrade --install neuraltrust-platform . --namespace neuraltrust --create-namespace

# Or with custom overrides:
cp values-required.yaml my-values.yaml
# Edit my-values.yaml: customize domains, resources, etc. (secrets auto-generated if empty)
helm upgrade --install neuraltrust-platform . --namespace neuraltrust --create-namespace -f my-values.yaml
```

---

### 2. `values.yaml` - Full Kubernetes Configuration
**Use case:** Full customization with all options and inline comments

**Features:**
- All available keys with comments and examples
- Auto-generated secrets by default; override any secret with an explicit value
- Ingress, resources, autoscaling, TLS, and other advanced options

**Usage:** Copy from the repo and customize as needed:
```bash
cp values.yaml my-values.yaml
# Edit my-values.yaml: customize as needed (secrets auto-generated if empty)
helm upgrade --install neuraltrust-platform . --namespace neuraltrust --create-namespace -f my-values.yaml
```

---

### 3. `values-openshift.yaml` - OpenShift with Routes (Default)
**Use case:** OpenShift deployment using Routes for external access

**Features:**
- OpenShift cluster (`openshift: true`)
- Routes enabled by default (Ingress disabled)
- Helm-managed secrets (`preserveExistingSecrets: false`)
- Services use `ClusterIP` type (Routes handle external access)

**Key settings:**
```yaml
global:
  openshift: true
  openshiftDomain: "YOUR_DOMAIN"
  preserveExistingSecrets: false
```

**To use Ingress instead of Routes in OpenShift:**
- Set `ingress.enabled: true` in TrustGate section
- Set `ingress.enabled: true` for each NeuralTrust component
- Routes will be automatically disabled when Ingress is enabled

**Usage:**
```bash
helm upgrade --install neuraltrust-platform . -f values-openshift.yaml
```

---

### 4. `values-openshift-ingress.yaml.example` - OpenShift with Ingress
**Use case:** OpenShift deployment using Ingress instead of Routes (best working example)

**Features:**
- OpenShift cluster (`openshift: true`)
- Ingress enabled for all services
- Pre-generated secrets (`preserveExistingSecrets: true`)
- TLS configuration with existing wildcard certificates
- Services use `ClusterIP` type

**Key settings:**
```yaml
global:
  openshift: true
  openshiftDomain: "your-domain.com"  # Your OpenShift wildcard domain
  preserveExistingSecrets: true  # Secrets are pre-generated
```

**Usage:**
```bash
# Copy and customize the example file
cp values-openshift-ingress.yaml.example values-openshift-ingress.yaml

# Edit values-openshift-ingress.yaml:
# - Replace YOUR_DOMAIN with your actual domain
# - Update image registries and pull secrets
# - Pre-generate all required secrets

helm upgrade --install neuraltrust-platform . -f values-openshift-ingress.yaml
```

---

### 5. `values-all-deployed.yaml.example` - Example: Deploy Everything
**Use case:** Example configuration showing how to deploy all components

**Features:**
- Deploys all infrastructure (ClickHouse, Kafka, PostgreSQL)
- Deploys all NeuralTrust components
- Deploys TrustGate
- Helm-managed secrets
- Ingress enabled

**Usage:**
```bash
helm upgrade --install neuraltrust-platform . -f values-all-deployed.yaml.example
```

---

### 6. `values-external-services.yaml.example` - Example: External Services
**Use case:** Example configuration using external infrastructure services

**Features:**
- Uses external ClickHouse, Kafka, and PostgreSQL
- Deploys NeuralTrust components only
- Deploys TrustGate
- Helm-managed secrets
- Ingress enabled

**Usage:**
```bash
helm upgrade --install neuraltrust-platform . -f values-external-services.yaml.example
```

---

### 7. `values-dataplane-gpu.yaml.example` — Data Plane + GPU firewall (no TrustGate)
**Use case:** Full in-cluster stack (ClickHouse, Kafka, PostgreSQL, Control Plane, Data Plane) plus the **GPU** firewall (gateway + workers), with **TrustGate disabled**. Suitable for internal clusters, direct data-plane access, or security testing workflows where the TrustGate API gateway is not required.

**Features:**
- `trustgate.enabled: false`
- `neuraltrust-firewall.firewall.enabled: true` with a CPU **gateway** (`firewall-cpu`) and GPU **workers** (`firewall-gpu`), GPU resources, **`hostIPC`**, CUDA MPS under `firewall.config`, and **placeholder** `workerDefaults.nodeSelector` / `tolerations` (must match your GPU nodes)
- Uses the same firewall **tag** across `firewall-cpu` and `firewall-gpu` (bump workflow reads tags from `firewall-cpu`)

**Usage:**
```bash
cp values-dataplane-gpu.yaml.example my-dataplane-gpu.yaml
# Edit hosts, secrets, GPU node labels, and pool names
helm upgrade --install neuraltrust-platform . --namespace neuraltrust --create-namespace -f my-dataplane-gpu.yaml
```

For **CPU-only** firewall, start from chart defaults (`firewall-cpu`, no GPU keys) or trim the GPU block from this example.

---

## NeuralTrust Firewall (Gateway + Workers, CPU and GPU)

The firewall is an **optional** subchart controlled by **`neuraltrust-firewall.firewall.enabled`** (root `Chart.yaml` condition: `neuraltrust-firewall.firewall.enabled`). It deploys a **gateway** (CPU router) plus **5 specialised workers** (inference). Each worker can be individually enabled/disabled under `firewall.workers`.

| Component | Image suffix | Scheduling / Resources | CUDA MPS in `firewall.config` |
|-----------|--------------|----------------------|------------------------------|
| **Gateway** | `firewall-cpu` | CPU resources, no GPU scheduling | N/A |
| **Workers (CPU, default)** | `firewall-cpu` | CPU resources, no GPU scheduling | Omit both MPS keys → not rendered in ConfigMap |
| **Workers (GPU override)** | `firewall-gpu` | Override `workerDefaults.image` to `firewall-gpu`; set `nodeSelector`, `tolerations`, `nvidia.com/gpu`, `hostIPC` | Set both `cudaMpsActiveThreadPercentage` and `cudaMpsPinnedDeviceMemLimit` |

**Reference values:** `values.yaml` (`neuraltrust-firewall`), `regions/values-us-prod.yaml` (GPU production), `values-dataplane-gpu.yaml.example` (GPU, no TrustGate).

---

## Configuration Scenarios

### Scenario 1: Kubernetes with Ingress
**File:** `values-required.yaml` (minimal) or `values.yaml` (full options)
- Set `global.openshift: false` (default for Kubernetes)
- Set `ingress.enabled: true` for all services
- Secrets auto-generated by default (`autoGenerateSecrets: true`)

### Scenario 2: OpenShift with Routes (Default)
**File:** `values-openshift.yaml`
- Set `global.openshift: true`
- Set `global.openshiftDomain: "your-domain"`
- Set `ingress.enabled: false` (Routes are used automatically)
- Secrets auto-generated by default (`autoGenerateSecrets: true`)

### Scenario 3: OpenShift with Ingress
**File:** Custom values file based on `values-openshift.yaml`
- Set `global.openshift: true`
- Set `global.openshiftDomain: "your-domain"`
- Set `ingress.enabled: true` for all services
- Set `ingress.className: "openshift-default"` or your ingress class
- Set `preserveExistingSecrets: true` if using pre-generated secrets

### Scenario 4: Deploy Only NeuralTrust (No Infrastructure)
**File:** Custom values file based on `values-external-services.yaml.example`
- Set `infrastructure.clickhouse.deploy: false`
- Set `infrastructure.kafka.deploy: false`
- Configure external services in `infrastructure.*.external` sections
- Set `neuraltrust-control-plane.infrastructure.postgresql.deploy: false` to use external PostgreSQL
- **Configure external PostgreSQL connection** in `neuraltrust-control-plane.controlPlane.components.postgresql.secrets` section with `host`, `port`, `user`, `password`, and `database` keys

### Scenario 5: Deploy Only NeuralTrust + Infrastructure (No TrustGate)
**File:** Custom values file based on `values-required.yaml` or `values.yaml`, or start from [`values-dataplane-gpu.yaml.example`](./values-dataplane-gpu.yaml.example) if you also need the **GPU firewall**
- Set `trustgate.enabled: false`
- Keep `infrastructure.*.deploy: true`
- Keep `neuraltrust-control-plane.controlPlane.enabled: true`
- Keep `neuraltrust-data-plane.dataPlane.enabled: true`
- Optional: set `neuraltrust-firewall.firewall.enabled: true` and choose **`firewall-cpu`** (defaults) or **`firewall-gpu`** plus GPU scheduling (see [NeuralTrust Firewall (CPU and GPU)](#neuraltrust-firewall-cpu-and-gpu))

### Scenario 6: Use Pre-generated Secrets (CICD-friendly)
**File:** Custom values file based on `values-openshift.yaml`
- Set `global.autoGenerateSecrets: false` and `global.preserveExistingSecrets: true`
- Pre-generate all required secrets before deployment
- Secret templates will NOT be rendered (prevents conflicts)

### Scenario 7: Zero-Config Deploy (Auto-Generated Secrets)
**File:** No values file needed (all defaults)
- All secrets auto-generated on first install
- Existing secrets preserved on upgrades
- `SERVER_SECRET_KEY` and `TRUSTGATE_JWT_SECRET` automatically synchronized
```bash
helm upgrade --install neuraltrust-platform . --namespace neuraltrust --create-namespace
```

---

## Secret Management

### Auto-Generated Secrets (`autoGenerateSecrets: true`) -- Default
- All required secrets (JWT keys, database passwords) are auto-generated on first install
- Existing secrets are preserved on `helm upgrade` (never overwritten)
- `SERVER_SECRET_KEY` and `TRUSTGATE_JWT_SECRET` are automatically synchronized
- Explicit values in your values file override auto-generation
- **Use when:** Quick starts, dev/staging, or any environment where auto-management is acceptable

### Helm-Managed Secrets from Values
- Provide explicit secret values in your values file
- Helm creates and manages secrets from those values
- Helm can update secrets on upgrades
- **Use when:** You want full control over secret values but still want Helm to manage the Secret resources

### Pre-generated Secrets (`preserveExistingSecrets: true`)
- Secrets must be created before deployment
- Secret templates are NOT rendered
- CICD-friendly (no secret conflicts)
- **Use when:** Using Vault or external secret management

**Required secrets when `preserveExistingSecrets: true`:**
- `clickhouse` (with key `admin-password`)
- `postgresql-secrets` (with keys: `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`, etc.)
- `control-plane-secrets` (with JWT secrets, API keys, etc.)
- `data-plane-jwt-secret` (with JWT secret)
- `trustgate-secrets` (with `SERVER_SECRET_KEY`, `DATABASE_PASSWORD`, database connection keys, and optionally `NEURAL_TRUST_FIREWALL_URL`, `NEURAL_TRUST_FIREWALL_SECRET_KEY` for TrustGate → firewall)
- Optional: `openai-secrets`, `google-secrets`, `resend-secrets`, `huggingface-secrets`

---

## Ingress vs Routes

### Ingress (Standard Kubernetes & OpenShift)
- Works on both Kubernetes and OpenShift
- Requires Ingress controller
- Supports TLS via `kubernetes.io/tls` secrets
- Configure via `ingress.enabled: true`

### Routes (OpenShift Only)
- OpenShift-native
- Automatically created when `global.openshift: true` and `ingress.enabled: false`
- Uses OpenShift's built-in routing
- TLS handled by OpenShift router
- Configure via `global.openshift: true` and `ingress.enabled: false`

---

## Component Selection

### Deploy All Components
```yaml
infrastructure:
  clickhouse:
    deploy: true
  kafka:
    deploy: true

neuraltrust-control-plane:
  controlPlane:
    enabled: true

neuraltrust-data-plane:
  dataPlane:
    enabled: true

trustgate:
  enabled: true
```

### Deploy Only NeuralTrust (Use External Infrastructure)
```yaml
infrastructure:
  clickhouse:
    deploy: false
    external:
      host: "external-clickhouse"
  kafka:
    deploy: false
    external:
      bootstrapServers: "external-kafka:9092"

neuraltrust-control-plane:
  controlPlane:
    enabled: true
    components:
      postgresql:
        # PostgreSQL deployment controlled by neuraltrust-control-plane.infrastructure.postgresql.deploy
        secrets:
          host: "external-postgresql"

neuraltrust-data-plane:
  dataPlane:
    enabled: true

trustgate:
  enabled: true
```

### Deploy Only Infrastructure
```yaml
infrastructure:
  clickhouse:
    deploy: true
  kafka:
    deploy: true

neuraltrust-control-plane:
  controlPlane:
    enabled: false

neuraltrust-data-plane:
  dataPlane:
    enabled: false

trustgate:
  enabled: false
```

---

## Quick Reference

| Scenario | File | OpenShift | Ingress | Routes | Secrets |
|----------|------|-----------|---------|--------|---------|
| Zero-config | None (defaults) | No | No | No | Auto-generated |
| Kubernetes | `values-required.yaml` or `values.yaml` | No | Yes | No | Auto-generated |
| OpenShift Default | `values-openshift.yaml` | Yes | No | Yes | Auto-generated |
| OpenShift Ingress | `values-openshift-ingress.yaml.example` | Yes | Yes | No | Pre-gen |
| All Deployed | `values-all-deployed.yaml.example` | Configurable | Yes | Configurable | Auto-generated |
| External Services | `values-external-services.yaml.example` | Configurable | Yes | Configurable | Auto-generated |
| Data Plane + GPU firewall (no TrustGate) | `values-dataplane-gpu.yaml.example` | Configurable | Yes | Configurable | Helm-managed / explicit in file |

