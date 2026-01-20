# Secrets Management Guide

This guide explains how to manage secrets for the NeuralTrust Platform deployment.

## Quick Start

### Option 1: Use the Secrets Script (Recommended)

The easiest way to configure all secrets is using the provided script:

```bash
# Run the script interactively
./create-secrets.sh

# Or use environment variables
export DATA_PLANE_JWT_SECRET="your-secret"
export CONTROL_PLANE_JWT_SECRET="your-secret"
export OPENAI_API_KEY="sk-..."
./create-secrets.sh

# Or with flags
./create-secrets.sh --namespace neuraltrust --replace-existing
```

### Option 2: Use Pre-defined Secrets

If you already have secrets in your cluster, the Helm chart will automatically use them. Just ensure the secret names match what the chart expects (see Secret Names section below).

### Option 3: Use Environment Variables in Values

You can also pass secrets directly via Helm values, though this is less secure:

```yaml
neuraltrust-data-plane:
  dataPlane:
    secrets:
      dataPlaneJWTSecret: "your-secret"
      openaiApiKey: "sk-..."
```

## Secret Names

The chart expects the following secret names in your namespace:

### Data Plane Secrets
- `data-plane-jwt-secret` - Data Plane JWT Secret (key: `DATA_PLANE_JWT_SECRET`)
- `openai-secrets` - OpenAI API Key (key: `OPENAI_API_KEY`)
- `google-secrets` - Google API Key (key: `GOOGLE_API_KEY`)
- `resend-secrets` - Resend API Key (key: `RESEND_API_KEY`)
- `huggingface-secrets` - Hugging Face Token (key: `HUGGINGFACE_TOKEN`)

### Control Plane Secrets
- `<release-name>-secrets` or `control-plane-secrets` - Control Plane secrets (keys: `CONTROL_PLANE_JWT_SECRET`, `OPENAI_API_KEY`, `resend-api-key`, `resend-alert-sender`, `resend-invite-sender`, `TRUSTGATE_JWT_SECRET`, `FIREWALL_JWT_SECRET`, `MODEL_SCANNER_SECRET`)
- `postgresql-secrets` - PostgreSQL connection (keys: `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`, `DATABASE_URL`, `POSTGRES_PRISMA_URL`)

### Infrastructure Secrets
- `clickhouse` - ClickHouse password (key: `admin-password`)
- `postgresql-secrets` - PostgreSQL connection (shared with control plane)

### TrustGate Secrets
- `trustgate-secrets` - TrustGate server secret and database connection details (keys: `SERVER_SECRET_KEY` and database connection details)
- `hf-api-key` - Hugging Face API key for firewall (key: `HUGGINGFACE_TOKEN`)

### Docker Registry
- `gcr-secret` - Docker registry credentials (type: `docker-registry`)

## Environment Variables

All secrets can be provided via environment variables when running the script:

```bash
# Data Plane
export DATA_PLANE_JWT_SECRET="your-secret"
export OPENAI_API_KEY="sk-..."
export GOOGLE_API_KEY="your-key"
export RESEND_API_KEY="your-key"
export HUGGINGFACE_TOKEN="your-token"

# Control Plane
export CONTROL_PLANE_JWT_SECRET="your-secret"
export RESEND_ALERT_SENDER="alerts@example.com"
export RESEND_INVITE_SENDER="invites@example.com"
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
export HF_API_KEY="your-key"

# Run the script
./create-secrets.sh
```

## Using Pre-defined Secrets

If you already have secrets in your cluster, the Helm chart will automatically reference them. The chart uses Kubernetes secret references, so as long as the secret names match, they will be used.

### Example: Using Existing Secrets

```bash
# Create a secret manually
kubectl create secret generic data-plane-jwt-secret \
  --from-literal=DATA_PLANE_JWT_SECRET="your-secret" \
  -n neuraltrust

# The Helm chart will automatically use it
helm upgrade --install neuraltrust-platform . \
  --namespace neuraltrust \
  -f my-values.yaml
```

## Secret Reference in Values

The Helm chart supports referencing secrets in two ways:

### 1. Direct Value (Less Secure)

```yaml
neuraltrust-data-plane:
  dataPlane:
    secrets:
      dataPlaneJWTSecret: "your-secret-value"
```

### 2. Secret Reference (Recommended)

```yaml
neuraltrust-data-plane:
  dataPlane:
    secrets:
      dataPlaneJWTSecret:
        secretName: "data-plane-jwt-secret"
        secretKey: "DATA_PLANE_JWT_SECRET"
```

## Script Options

```bash
./create-secrets.sh [OPTIONS]

Options:
  --replace-existing      Replace existing secrets without asking
  --no-replace-existing   Skip existing secrets without asking
  --namespace NAMESPACE   Use specified namespace (default: neuraltrust)
  --help, -h              Show help message
```

## Script Features

- **Environment Variable Support**: All secrets can be provided via environment variables
- **Interactive Mode**: Prompts for missing values
- **Pre-existing Secret Detection**: Checks if secrets already exist
- **Non-destructive Updates**: Can update individual keys in multi-key secrets
- **Namespace Management**: Automatically creates namespace if it doesn't exist
- **Password Generation**: Auto-generates passwords for ClickHouse and Redis if not provided

## Security Best Practices

1. **Use Pre-defined Secrets**: Create secrets before deployment using the script or kubectl
2. **Avoid Values Files**: Don't store secrets in your values file (e.g. my-values.yaml) if it is committed to git
3. **Use Secret Management**: Consider using external secret management systems (Sealed Secrets, External Secrets Operator, etc.)
4. **Rotate Secrets**: Regularly rotate secrets, especially JWT secrets
5. **Limit Access**: Use RBAC to limit who can read secrets

## Troubleshooting

### Secret Not Found

If you see errors about missing secrets:

```bash
# Check if secret exists
kubectl get secret <secret-name> -n neuraltrust

# List all secrets
kubectl get secrets -n neuraltrust

# View secret (base64 encoded)
kubectl get secret <secret-name> -n neuraltrust -o yaml
```

### Wrong Secret Key

If the secret exists but has the wrong key:

```bash
# Update the key
kubectl patch secret <secret-name> -n neuraltrust \
  --type='json' \
  -p='[{"op": "replace", "path": "/data/<key>", "value": "<base64-encoded-value>"}]'
```

### Secret Format Issues

The script handles URL encoding for PostgreSQL connection strings automatically. If you create secrets manually, ensure:
- Passwords are properly URL-encoded in DATABASE_URL
- All values are base64 encoded in Kubernetes secrets
- No trailing newlines or whitespace

## Examples

### Full Deployment with Script

```bash
# 1. Set environment variables
export DATA_PLANE_JWT_SECRET=$(openssl rand -hex 32)
export CONTROL_PLANE_JWT_SECRET=$(openssl rand -hex 32)
export POSTGRES_PASSWORD=$(openssl rand -hex 16)
export CLICKHOUSE_PASSWORD=$(openssl rand -hex 16)

# 2. Run secrets script
./create-secrets.sh --namespace neuraltrust

# 3. Deploy
helm dependency update
helm upgrade --install neuraltrust-platform . \
  --namespace neuraltrust \
  -f my-values.yaml
```

### Using External Secret Management

If you use External Secrets Operator or similar:

```yaml
# The Helm chart will use pre-created secrets
# Just ensure secret names match
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

## Next Steps

After creating secrets:
1. Verify secrets are created: `kubectl get secrets -n neuraltrust`
2. Deploy the Helm chart: `helm upgrade --install neuraltrust-platform . -n neuraltrust -f my-values.yaml`
3. Check pod logs if issues occur: `kubectl logs -n neuraltrust <pod-name>`

