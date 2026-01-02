# Values Files Scenarios Guide

This document explains the different values files available and when to use each one.

## Available Values Files

### 1. `values.yaml` - Base Configuration (Kubernetes with Ingress)
**Use case:** Standard Kubernetes deployment with Ingress for external access

**Features:**
- Kubernetes cluster
- Ingress enabled by default for all services
- Helm-managed secrets (`preserveExistingSecrets: false`)
- Deploys all infrastructure and services by default

**Key settings:**
```yaml
global:
  openshift: false
  preserveExistingSecrets: false
```

**Usage:**
```bash
helm install neuraltrust-platform . -f values.yaml
```

---

### 2. `values-openshift.yaml` - OpenShift with Routes (Default)
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
helm install neuraltrust-platform . -f values-openshift.yaml
```

---

### 3. `values-openshift-ingress.yaml.example` - OpenShift with Ingress
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

helm install neuraltrust-platform . -f values-openshift-ingress.yaml
```

---

### 4. `values-all-deployed.yaml.example` - Example: Deploy Everything
**Use case:** Example configuration showing how to deploy all components

**Features:**
- Deploys all infrastructure (ClickHouse, Kafka, PostgreSQL)
- Deploys all NeuralTrust components
- Deploys TrustGate
- Helm-managed secrets
- Ingress enabled

**Usage:**
```bash
helm install neuraltrust-platform . -f values-all-deployed.yaml.example
```

---

### 5. `values-external-services.yaml.example` - Example: External Services
**Use case:** Example configuration using external infrastructure services

**Features:**
- Uses external ClickHouse, Kafka, and PostgreSQL
- Deploys NeuralTrust components only
- Deploys TrustGate
- Helm-managed secrets
- Ingress enabled

**Usage:**
```bash
helm install neuraltrust-platform . -f values-external-services.yaml.example
```

---

## Configuration Scenarios

### Scenario 1: Kubernetes with Ingress
**File:** `values.yaml`
- Set `global.openshift: false` (default for Kubernetes)
- Set `ingress.enabled: true` for all services
- Set `preserveExistingSecrets: false` (Helm manages secrets)

### Scenario 2: OpenShift with Routes (Default)
**File:** `values-openshift.yaml`
- Set `global.openshift: true`
- Set `global.openshiftDomain: "your-domain"`
- Set `ingress.enabled: false` (Routes are used automatically)
- Set `preserveExistingSecrets: false` (Helm manages secrets)

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
- Set `infrastructure.postgresql.deploy: false`
- Configure external PostgreSQL connection

### Scenario 5: Deploy Only NeuralTrust + Infrastructure (No TrustGate)
**File:** Custom values file based on `values.yaml`
- Set `trustgate.enabled: false`
- Keep `infrastructure.*.deploy: true`
- Keep `neuraltrust-control-plane.controlPlane.enabled: true`
- Keep `neuraltrust-data-plane.dataPlane.enabled: true`

### Scenario 6: Use Pre-generated Secrets (CICD-friendly)
**File:** Custom values file based on `values-openshift.yaml`
- Set `global.preserveExistingSecrets: true` (single global flag controls all subcharts)
- Pre-generate all required secrets before deployment
- Secret templates will NOT be rendered (prevents conflicts)

---

## Secret Management

### Helm-Managed Secrets (`preserveExistingSecrets: false`)
- Helm creates and manages secrets from values
- Secrets are defined in values files
- Helm can update secrets on upgrades
- **Use when:** You want Helm to manage secrets

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
- `openai-secrets`, `google-secrets`, `resend-secrets`, `huggingface-secrets`
- `trustgate-secrets` (with TrustGate configuration)

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
        # PostgreSQL deployment controlled by infrastructure.postgresql.deploy
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
| Kubernetes | `values.yaml` | No | Yes | No | Helm |
| OpenShift Default | `values-openshift.yaml` | Yes | No | Yes | Helm |
| OpenShift Ingress | `values-openshift-ingress.yaml.example` | Yes | Yes | No | Pre-gen |
| All Deployed | `values-all-deployed.yaml.example` | Configurable | Yes | Configurable | Helm |
| External Services | `values-external-services.yaml.example` | Configurable | Yes | Configurable | Helm |

