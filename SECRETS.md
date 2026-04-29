# Secrets Management Guide

How secrets are created, stored, and managed across the NeuralTrust Platform chart.

## Quick start

### Auto-generated secrets (default — recommended)

No action required. Deploy and all secrets are created automatically:

```bash
helm upgrade --install neuraltrust-platform . --namespace neuraltrust --create-namespace
```

| Secret | Kubernetes Secret | Key |
|---|---|---|
| TrustGate server key | `trustgate-secrets` | `SERVER_SECRET_KEY` |
| TrustGate DB password | `trustgate-secrets` | `DATABASE_PASSWORD` |
| Control Plane JWT | `control-plane-secrets` | `CONTROL_PLANE_JWT_SECRET` |
| TrustGate JWT (synced) | `control-plane-secrets` | `TRUSTGATE_JWT_SECRET` |
| Data Plane JWT | `data-plane-jwt-secret` | `DATA_PLANE_JWT_SECRET` |
| PostgreSQL password | `postgresql-secrets` | `POSTGRES_PASSWORD` |

> `SERVER_SECRET_KEY` (TrustGate) and `TRUSTGATE_JWT_SECRET` (Control Plane) are always synchronized to the same value.

**How it works:**

1. On first install, random 64-character alphanumeric values are generated
2. On `helm upgrade`, existing values are read from the cluster via `lookup` and reused
3. Explicit (non-empty) values in your values file always take priority

**Override a specific secret:**

```yaml
trustgate:
  global:
    env:
      SERVER_SECRET_KEY: "my-explicit-key"
```

### Pre-create secrets with the script

For environments that require secrets before deployment:

```bash
# Interactive
./create-secrets.sh --namespace neuraltrust

# With environment variables
export DATA_PLANE_JWT_SECRET="your-secret"
export CONTROL_PLANE_JWT_SECRET="your-secret"
./create-secrets.sh --namespace neuraltrust

# Script options
./create-secrets.sh --replace-existing      # replace without asking
./create-secrets.sh --no-replace-existing   # skip existing without asking
```

### Pre-existing secrets (external management)

For Vault, Sealed Secrets, or External Secrets Operator:

```yaml
global:
  autoGenerateSecrets: false
  preserveExistingSecrets: true   # Helm will NOT create or update secrets
```

All required secrets must exist in the namespace before deployment.

## Secret reference

### Data Plane

| Kubernetes Secret | Key | Required | Description |
|---|---|---|---|
| `data-plane-jwt-secret` | `DATA_PLANE_JWT_SECRET` | Auto-generated | JWT for Data Plane API auth |
| `openai-secrets` | `OPENAI_API_KEY` | No | OpenAI API key |
| `google-secrets` | `GOOGLE_API_KEY` | No | Google API key |
| `resend-secrets` | `RESEND_API_KEY` | No | Resend email API key |
| `huggingface-secrets` | `HUGGINGFACE_TOKEN` | No | Hugging Face model access |

### Control Plane

| Kubernetes Secret | Key | Required | Description |
|---|---|---|---|
| `control-plane-secrets` | `CONTROL_PLANE_JWT_SECRET` | Auto-generated | JWT for Control Plane API auth |
| `control-plane-secrets` | `TRUSTGATE_JWT_SECRET` | Auto-generated | Synced with `SERVER_SECRET_KEY` |
| `control-plane-secrets` | `FIREWALL_JWT_SECRET` | No | JWT for firewall service |
| `control-plane-secrets` | `FIREWALL_API_URL` | Auto-populated | Firewall base URL (FQDN when firewall enabled, data-plane fallback otherwise) |
| `control-plane-secrets` | `MODEL_SCANNER_SECRET` | No | Model scanner service secret |
| `control-plane-secrets` | `OPENAI_API_KEY` | No | OpenAI API key |
| `control-plane-secrets` | `resend-api-key` | No | Resend API key |
| `control-plane-secrets` | `resend-alert-sender` | No | Alert notification email |
| `control-plane-secrets` | `resend-invite-sender` | No | Invitation email |

### PostgreSQL

| Kubernetes Secret | Key | Required | Description |
|---|---|---|---|
| `postgresql-secrets` | `POSTGRES_HOST` | Yes (if pre-generating) | Database hostname |
| `postgresql-secrets` | `POSTGRES_PORT` | Yes (if pre-generating) | Database port |
| `postgresql-secrets` | `POSTGRES_USER` | Yes (if pre-generating) | Database username |
| `postgresql-secrets` | `POSTGRES_PASSWORD` | Auto-generated | Database password |
| `postgresql-secrets` | `POSTGRES_DB` | Yes (if pre-generating) | Database name |
| `postgresql-secrets` | `DATABASE_URL` | Yes (if pre-generating) | Connection URL (URL-encoded) |
| `postgresql-secrets` | `POSTGRES_PRISMA_URL` | Yes (if pre-generating) | Prisma-compatible URL |

### Infrastructure

| Kubernetes Secret | Key | Required | Description |
|---|---|---|---|
| `clickhouse` | `admin-password` | Auto-generated | ClickHouse admin password |

### TrustGate

| Kubernetes Secret | Key | Required | Description |
|---|---|---|---|
| `trustgate-secrets` | `SERVER_SECRET_KEY` | Auto-generated | Server secret key |
| `trustgate-secrets` | `DATABASE_HOST` | No | PostgreSQL host (external DB) |
| `trustgate-secrets` | `DATABASE_PORT` | No | PostgreSQL port (external DB) |
| `trustgate-secrets` | `DATABASE_USER` | No | PostgreSQL user (external DB) |
| `trustgate-secrets` | `DATABASE_PASSWORD` | Auto-generated | PostgreSQL password |
| `trustgate-secrets` | `DATABASE_NAME` | No | PostgreSQL database (external DB) |
| `trustgate-secrets` | `DATABASE_URL` | No | Connection URL (external DB) |
| `trustgate-secrets` | `NEURAL_TRUST_FIREWALL_URL` | No | Firewall base URL |
| `trustgate-secrets` | `NEURAL_TRUST_FIREWALL_SECRET_KEY` | No | Firewall API key |

### Firewall

Created when `neuraltrust-firewall.firewall.enabled: true`:

| Kubernetes Secret | Key | Required | Description |
|---|---|---|---|
| `firewall-secrets` | `JWT_SECRET` | Yes | Shared with services calling the firewall |
| `firewall-secrets` | `HUGGINGFACE_TOKEN` | No | HF token for model weights |

Align `controlPlane.secrets.firewallJwtSecret` (`FIREWALL_JWT_SECRET`) with `firewall-secrets` `JWT_SECRET` when the Control Plane validates firewall tokens.

### Docker registry

| Kubernetes Secret | Type | Required | Description |
|---|---|---|---|
| `gcr-secret` | `docker-registry` | Yes | Credentials for NeuralTrust container images |

## TrustGate firewall integration

TrustGate calls the NeuralTrust Firewall using two keys stored in `trustgate-secrets`. With `global.autoGenerateSecrets: true` and `neuraltrust-firewall.firewall.enabled: true` (default), both are auto-populated to the in-cluster firewall Service:

```
NEURAL_TRUST_FIREWALL_URL        = http://firewall.<release-namespace>.svc.cluster.local
NEURAL_TRUST_FIREWALL_SECRET_KEY = <auto-generated, shared with firewall-secrets/JWT_SECRET>
```

To point TrustGate at a cross-namespace or external firewall, override explicitly:

```yaml
trustgate:
  global:
    env:
      NEURAL_TRUST_FIREWALL_URL: "http://firewall.shared-ns.svc.cluster.local"
      NEURAL_TRUST_FIREWALL_SECRET_KEY: "your-secret-key"
```

| Kubernetes Secret | Key | Required |
|---|---|---|
| `trustgate-secrets` | `NEURAL_TRUST_FIREWALL_URL` | No — auto-populated when firewall enabled; omit to disable firewall calls |
| `trustgate-secrets` | `NEURAL_TRUST_FIREWALL_SECRET_KEY` | No — auto-populated when firewall enabled; omit if not using secret-key auth |

With `global.autoGenerateSecrets: true`, these are merged into `trustgate-secrets` from `trustgate.global.env`. With `global.preserveExistingSecrets: true`, add them to a pre-created `trustgate-secrets`.

The Control Plane app's `FIREWALL_API_URL` follows the same auto-derivation rules from `control-plane-secrets/FIREWALL_API_URL`. See `accounts/bv/values-bv-pre.yaml` for a worked cross-namespace example.

After changing firewall secrets, **restart TrustGate** so pods pick up the new values:

```bash
kubectl rollout restart deployment/trustgate-control-plane -n neuraltrust
kubectl rollout restart deployment/trustgate-data-plane -n neuraltrust
kubectl rollout restart deployment/trustgate-actions -n neuraltrust
```

## Secret reference in values

### Direct value (less secure)

```yaml
neuraltrust-data-plane:
  dataPlane:
    secrets:
      dataPlaneJWTSecret: "your-secret-value"
```

### Secret reference (recommended)

```yaml
neuraltrust-data-plane:
  dataPlane:
    secrets:
      dataPlaneJWTSecret:
        secretName: "data-plane-jwt-secret"
        secretKey: "DATA_PLANE_JWT_SECRET"
```

## Environment variables for the script

All secrets can be provided via environment variables:

```bash
# Data Plane
export DATA_PLANE_JWT_SECRET="your-secret"
export OPENAI_API_KEY="sk-..."
export GOOGLE_API_KEY="your-key"
export RESEND_API_KEY="your-key"
export HUGGINGFACE_TOKEN="your-token"

# Control Plane
export CONTROL_PLANE_JWT_SECRET="your-secret"
export TRUSTGATE_JWT_SECRET="your-secret"
export FIREWALL_JWT_SECRET="your-secret"
export MODEL_SCANNER_SECRET="your-secret"

# Infrastructure
export CLICKHOUSE_PASSWORD="your-password"
export POSTGRES_HOST="postgres.example.com"
export POSTGRES_PORT="5432"
export POSTGRES_USER="postgres"
export POSTGRES_PASSWORD="your-password"
export POSTGRES_DB="neuraltrust"

# TrustGate
export SERVER_SECRET_KEY="your-secret"

./create-secrets.sh --namespace neuraltrust
```

## Using external secret management

Example with External Secrets Operator:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: data-plane-jwt-secret
  namespace: neuraltrust
spec:
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: data-plane-jwt-secret
  data:
    - secretKey: DATA_PLANE_JWT_SECRET
      remoteRef:
        key: neuraltrust/data-plane/jwt-secret
```

## Comparison: auto-generated vs pre-generated

| Feature | Auto-generated | Pre-generated |
|---|---|---|
| Setup effort | None — just deploy | Must create all secrets first |
| Secret creation | Helm creates automatically | User/CI creates before deploy |
| Upgrade behavior | Existing values preserved via `lookup` | Helm never touches secrets |
| Secret sync | `SERVER_SECRET_KEY` = `TRUSTGATE_JWT_SECRET` automatic | Manual — user must ensure consistency |
| Best for | Dev, staging, quick starts | Production with Vault/compliance |

## Security best practices

1. **Use auto-generated secrets for simplicity** — the default is the safest starting point
2. **Use external secret management for production** — Vault, Sealed Secrets, or External Secrets Operator
3. **Never commit secrets to git** — don't store real values in values files that are version-controlled
4. **Rotate secrets regularly** — especially JWT secrets
5. **Restrict access with RBAC** — limit who can read Kubernetes secrets

## Troubleshooting

### TrustGate firewall env vars not updating

TrustGate reads `NEURAL_TRUST_FIREWALL_URL` and `NEURAL_TRUST_FIREWALL_SECRET_KEY` from `trustgate-secrets`. After `helm upgrade`, restart TrustGate deployments to reload.

### Secret not found

```bash
kubectl get secret <secret-name> -n neuraltrust
kubectl get secrets -n neuraltrust
kubectl get secret <secret-name> -n neuraltrust -o yaml
```

### Wrong secret key

```bash
kubectl patch secret <secret-name> -n neuraltrust \
  --type='json' \
  -p='[{"op": "replace", "path": "/data/<key>", "value": "<base64-encoded-value>"}]'
```

### Secret format issues

When creating secrets manually:

- URL-encode passwords in `DATABASE_URL`
- Base64-encode all values in Kubernetes secrets
- Avoid trailing newlines or whitespace
