# NeuralTrust Platform Deployment on OpenShift

This guide provides step-by-step instructions for deploying the NeuralTrust Platform on OpenShift using Helm with pre-defined secrets.

## Prerequisites

- OpenShift 4.10+ cluster
- Helm 3.2.0+ installed and configured
- `oc` CLI configured to access your OpenShift cluster
- Appropriate permissions to create namespaces, secrets, and deploy Helm charts
- **Docker Registry Secret (Required for NeuralTrust/TrustGate images)**: A Kubernetes secret with permission to pull container images from Google Container Registry (GCR) must exist in your namespace. The default secret name is `gcr-secret`. For Docker Hub images (infrastructure components), the default is empty `[]` (for public images) or a user-provided Docker Hub secret (for private images). See [Image Pull Secrets](#image-pull-secrets) section below for details.
- (Optional) Ingress controller - **Not included in this chart**. OpenShift Routes are available by default, but if you want to use Ingress instead, install an Ingress controller separately (e.g., [ingress-nginx](https://kubernetes.github.io/ingress-nginx/deploy/))
- (Optional) cert-manager - **Not included in this chart**. Install separately if you want automatic TLS certificate management:
  - Install cert-manager: `helm install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --set installCRDs=true`
  - See [cert-manager documentation](https://cert-manager.io/docs/installation/) for details
  - If not using cert-manager, provide pre-existing `kubernetes.io/tls` secrets

## Table of Contents

1. [Quick Start](#quick-start)
2. [Required Secrets](#required-secrets)
3. [Creating Secrets](#creating-secrets)
4. [OpenShift-Specific Configuration](#openshift-specific-configuration)
5. [Deployment Steps](#deployment-steps)
6. [Verification](#verification)
7. [Troubleshooting](#troubleshooting)

## Quick Start

```bash
# 1. Create namespace
oc create namespace neuraltrust

# 2. Create all required secrets (see Required Secrets section)
# ... (create secrets using oc commands or the provided script)

# 3. Update Helm dependencies
helm dependency update

# 4. Deploy with OpenShift configuration
helm upgrade --install neuraltrust-platform . \
  --namespace neuraltrust \
  --set global.openshift=true \
  --set global.openshiftDomain="YOUR_DOMAIN" \
  -f values.yaml

# Optional: If using a custom image pull secret (instead of default 'gcr-secret'):
# Set imagePullSecrets for each component separately using subchart name prefix
helm upgrade --install neuraltrust-platform . \
  --namespace neuraltrust \
  --set global.openshift=true \
  --set global.openshiftDomain="YOUR_DOMAIN" \
  --set neuraltrust-data-plane.imagePullSecrets="my-custom-secret" \
  --set neuraltrust-control-plane.imagePullSecrets="my-custom-secret" \
  --set trustgate.imagePullSecrets="my-custom-secret" \
  -f values.yaml
```

## Required Secrets

All secrets must be created in the target namespace before deployment. The following table lists all required secrets with their names, keys, and descriptions.

### Data Plane Secrets

| Secret Name | Key | Required | Description |
|------------|-----|----------|-------------|
| `data-plane-jwt-secret` | `DATA_PLANE_JWT_SECRET` | **Yes** | JWT secret for Data Plane API authentication |
| `openai-secrets` | `OPENAI_API_KEY` | No | OpenAI API key for AI model integrations |
| `google-secrets` | `GOOGLE_API_KEY` | No | Google API key for Google services integration |
| `resend-secrets` | `RESEND_API_KEY` | No | Resend API key for email services |
| `huggingface-secrets` | `HUGGINGFACE_TOKEN` | No | Hugging Face token for model access |

### Control Plane Secrets

| Secret Name | Key | Required | Description |
|------------|-----|----------|-------------|
| `control-plane-secrets` | `CONTROL_PLANE_JWT_SECRET` | **Yes** | JWT secret for Control Plane API authentication |
| `control-plane-secrets` | `OPENAI_API_KEY` | No | OpenAI API key for AI model integrations |
| `control-plane-secrets` | `resend-api-key` | No | Resend API key for email services |
| `control-plane-secrets` | `resend-alert-sender` | No | Email address for alert notifications |
| `control-plane-secrets` | `resend-invite-sender` | No | Email address for invitation emails |
| `control-plane-secrets` | `TRUSTGATE_JWT_SECRET` | No | JWT secret for TrustGate integration |
| `control-plane-secrets` | `FIREWALL_JWT_SECRET` | No | JWT secret for firewall service |
| `control-plane-secrets` | `MODEL_SCANNER_SECRET` | No | Secret for model scanner service |

**Note:** As an alternative, you can use separate secrets `openai-secrets` (key: `OPENAI_API_KEY`) and `resend-secrets` (key: `RESEND_API_KEY`) instead of storing these in `control-plane-secrets`. The chart will automatically detect and use these if they exist.
| `postgresql-secrets` | `POSTGRES_HOST` | **Yes** | PostgreSQL database hostname |
| `postgresql-secrets` | `POSTGRES_PORT` | **Yes** | PostgreSQL database port (default: 5432) |
| `postgresql-secrets` | `POSTGRES_USER` | **Yes** | PostgreSQL database username |
| `postgresql-secrets` | `POSTGRES_PASSWORD` | **Yes** | PostgreSQL database password |
| `postgresql-secrets` | `POSTGRES_DB` | **Yes** | PostgreSQL database name |
| `postgresql-secrets` | `DATABASE_URL` | **Yes** | PostgreSQL connection URL (URL-encoded) |
| `postgresql-secrets` | `POSTGRES_PRISMA_URL` | **Yes** | Prisma-compatible PostgreSQL connection URL |

### Infrastructure Secrets

| Secret Name | Key | Required | Description |
|------------|-----|----------|-------------|
| `clickhouse` | `admin-password` | **Yes** (if deploying ClickHouse) | ClickHouse admin password for infrastructure ClickHouse instance |

**Note:** The data plane also uses a `clickhouse-secrets` secret, but this is **auto-generated** by the Helm chart and does not need to be created manually. It contains connection details (CLICKHOUSE_USER, CLICKHOUSE_DATABASE, CLICKHOUSE_HOST, CLICKHOUSE_PORT) and is created automatically from values.yaml configuration.

### TrustGate Secrets

| Secret Name | Key | Required | Description |
|------------|-----|----------|-------------|
| `trustgate-secrets` | `SERVER_SECRET_KEY` | No | TrustGate server secret key |
| `trustgate-secrets` | `SERVER_SECRET_KEY` | No | TrustGate server secret key |
| `trustgate-secrets` | `DATABASE_HOST` | No | Database hostname for TrustGate (if using external database) |
| `trustgate-secrets` | `DATABASE_PORT` | No | Database port for TrustGate (if using external database) |
| `trustgate-secrets` | `DATABASE_USER` | No | Database username for TrustGate (if using external database) |
| `trustgate-secrets` | `DATABASE_PASSWORD` | No | Database password for TrustGate (if using external database) |
| `trustgate-secrets` | `DATABASE_NAME` | No | Database name for TrustGate (if using external database) |
| `trustgate-secrets` | `DATABASE_URL` | No | Database connection URL for TrustGate (if using external database) |
| `hf-api-key` | `HUGGINGFACE_TOKEN` | No | Hugging Face API key for firewall service. **Note:** Can reuse the same token value from `huggingface-secrets` |

### Docker Registry Secret

| Secret Name | Type | Required | Description |
|------------|------|----------|-------------|
| `gcr-secret` | `docker-registry` | **Yes** (required for NeuralTrust/TrustGate images) | Docker registry credentials for pulling container images from Google Container Registry (GCR). NeuralTrust and TrustGate images are stored in a private GCR. |

## Creating Secrets

### Option 1: Using the Provided Script

The easiest way to create all secrets is using the provided script:

```bash
# Interactive mode
./create-secrets.sh --namespace neuraltrust

# With environment variables
export DATA_PLANE_JWT_SECRET="your-secret-here"
export CONTROL_PLANE_JWT_SECRET="your-secret-here"
export POSTGRES_HOST="postgresql.postgresql.svc.cluster.local"
export POSTGRES_PASSWORD="your-password"
export CLICKHOUSE_PASSWORD="your-password"
./create-secrets.sh --namespace neuraltrust
```

**Note:** The script uses `kubectl` commands. On OpenShift, you can use `oc` instead as it's compatible with `kubectl`.

**Tip:** When the script prompts for the Hugging Face API Key for Firewall, you can enter the same token value you used for `huggingface-secrets` (or leave it empty to skip). Both secrets use the same token value.

### Option 2: Manual Creation with oc/kubectl

#### Data Plane JWT Secret (Required)

```bash
oc create secret generic data-plane-jwt-secret \
  --from-literal=DATA_PLANE_JWT_SECRET="$(openssl rand -hex 32)" \
  -n neuraltrust
```

#### Control Plane Secrets (Required)

```bash
# Generate JWT secret
CONTROL_PLANE_JWT=$(openssl rand -hex 32)

# Create control plane secrets
oc create secret generic control-plane-secrets \
  --from-literal=CONTROL_PLANE_JWT_SECRET="$CONTROL_PLANE_JWT" \
  --from-literal=resend-alert-sender="alerts@example.com" \
  --from-literal=resend-invite-sender="invites@example.com" \
  -n neuraltrust
```

#### PostgreSQL Secrets (Required)

```bash
# Set PostgreSQL connection details
POSTGRES_HOST="postgresql.postgresql.svc.cluster.local"
POSTGRES_PORT="5432"
POSTGRES_USER="postgres"
POSTGRES_PASSWORD="your-secure-password"
POSTGRES_DB="neuraltrust"

# URL-encode the password for DATABASE_URL
POSTGRES_PASSWORD_ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$POSTGRES_PASSWORD', safe=''))")
DATABASE_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD_ENCODED}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}?connection_limit=15"

# Create PostgreSQL secrets
oc create secret generic postgresql-secrets \
  --from-literal=POSTGRES_HOST="$POSTGRES_HOST" \
  --from-literal=POSTGRES_PORT="$POSTGRES_PORT" \
  --from-literal=POSTGRES_USER="$POSTGRES_USER" \
  --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  --from-literal=POSTGRES_DB="$POSTGRES_DB" \
  --from-literal=DATABASE_URL="$DATABASE_URL" \
  --from-literal=POSTGRES_PRISMA_URL="$DATABASE_URL" \
  -n neuraltrust
```

#### ClickHouse Secret (Required if deploying ClickHouse)

```bash
oc create secret generic clickhouse \
  --from-literal=admin-password="$(openssl rand -base64 32)" \
  -n neuraltrust
```

#### Optional API Keys

```bash
# OpenAI API Key (optional)
oc create secret generic openai-secrets \
  --from-literal=OPENAI_API_KEY="sk-..." \
  -n neuraltrust

# Google API Key (optional)
oc create secret generic google-secrets \
  --from-literal=GOOGLE_API_KEY="your-google-api-key" \
  -n neuraltrust

# Resend API Key (optional)
oc create secret generic resend-secrets \
  --from-literal=RESEND_API_KEY="your-resend-api-key" \
  -n neuraltrust

# Hugging Face Token (optional)
oc create secret generic huggingface-secrets \
  --from-literal=HUGGINGFACE_TOKEN="your-huggingface-token" \
  -n neuraltrust
```

#### TrustGate Secrets (Optional)

```bash
# TrustGate Secrets
oc create secret generic trustgate-secrets \
  --from-literal=SERVER_SECRET_KEY="$(openssl rand -hex 32)" \
  -n neuraltrust

# Hugging Face API Key for Firewall
# Note: You can reuse the same token from huggingface-secrets if already created
# Option 1: Use the same token value
oc create secret generic hf-api-key \
  --from-literal=HUGGINGFACE_TOKEN="your-huggingface-token" \
  -n neuraltrust

# Option 2: Reuse value from existing huggingface-secrets secret
HF_TOKEN=$(oc get secret huggingface-secrets -n neuraltrust -o jsonpath='{.data.HUGGINGFACE_TOKEN}' | base64 -d)
oc create secret generic hf-api-key \
  --from-literal=HUGGINGFACE_TOKEN="$HF_TOKEN" \
  -n neuraltrust
```

#### Docker Registry Secret (Required for NeuralTrust/TrustGate images)

**Note:** NeuralTrust and TrustGate container images are hosted in a private GCR registry. You will receive a GCR JSON key file from NeuralTrust to access these images.

```bash
oc create secret docker-registry gcr-secret \
  --docker-server=europe-west1-docker.pkg.dev \
  --docker-username=_json_key \
  --docker-password="$(cat path/to/gcr-keys.json)" \
  --docker-email=admin@neuraltrust.ai \
  -n neuraltrust
```

### Option 3: Using OpenShift Secrets from Files

You can also create secrets from files:

```bash
# Create secret from literal values
echo -n "your-secret-value" | oc create secret generic data-plane-jwt-secret \
  --from-file=DATA_PLANE_JWT_SECRET=/dev/stdin \
  -n neuraltrust
```

## OpenShift-Specific Configuration

### Enable OpenShift Mode

Set the `global.openshift` flag to `true` in your values file or via Helm command:

```bash
helm upgrade --install neuraltrust-platform . \
  --namespace neuraltrust \
  --set global.openshift=true \
  --set global.openshiftDomain="YOUR_DOMAIN" \
  -f values.yaml
```

Or in your `values.yaml`:

```yaml
global:
  openshift: true
  openshiftDomain: "YOUR_DOMAIN"  # Your OpenShift wildcard DNS domain (e.g., apps.neuraltrust-dev.c4u5.p2.openshiftapps.com)
```

### Custom Image Pull Secret

To use a custom image pull secret instead of the default `gcr-secret`, set the imagePullSecrets for each component separately using the subchart name prefix:

```bash
helm upgrade --install neuraltrust-platform . \
  --namespace neuraltrust \
  --set global.openshift=true \
  --set global.openshiftDomain="YOUR_DOMAIN" \
  --set neuraltrust-data-plane.imagePullSecrets="my-custom-secret" \
  --set neuraltrust-control-plane.imagePullSecrets="my-custom-secret" \
  --set trustgate.imagePullSecrets="my-custom-secret" \
  -f values.yaml
```

Or configure in `values.yaml`:

```yaml
global:
  openshift: true
  openshiftDomain: "YOUR_DOMAIN"  # Your OpenShift wildcard DNS domain (e.g., apps.neuraltrust-dev.c4u5.p2.openshiftapps.com)

# Note: When using --set, use the subchart name prefix:
# --set neuraltrust-data-plane.imagePullSecrets="my-custom-secret"
# --set neuraltrust-control-plane.imagePullSecrets="my-custom-secret"
# --set trustgate.imagePullSecrets="my-custom-secret"

# Or in values.yaml, set at root level for subchart compatibility:
neuraltrust-data-plane:
  imagePullSecrets: "my-custom-secret"

neuraltrust-control-plane:
  imagePullSecrets: "my-custom-secret"

trustgate:
  imagePullSecrets: "my-custom-secret"

# Note: Kafka and ClickHouse use public images and don't need imagePullSecrets
# They are already set to empty arrays in values.yaml
```

**Note:** 
- Replace `my-custom-secret` with your actual secret name
- Ensure the secret exists in the namespace before deployment
- Set `imagePullSecrets` for each component (dataPlane, controlPlane, trustgate) separately
- Kafka and ClickHouse use public images and don't need imagePullSecrets (already configured as empty arrays)

### OpenShift Route Configuration

When `global.openshift=true` and `ingress.enabled=false` (default), the chart automatically creates OpenShift Routes instead of Ingress resources. Routes provide native OpenShift ingress capabilities.

**Note:** You can also use Ingress in OpenShift by setting `ingress.enabled=true` for the components you want to expose via Ingress. When Ingress is enabled, Routes are automatically disabled for those components.

### Security Context Constraints (SCC)

OpenShift uses Security Context Constraints (SCC) instead of Pod Security Policies. The chart automatically adapts security contexts for OpenShift compatibility when `global.openshift=true` is set.

If you encounter SCC-related issues, you may need to:

1. Grant appropriate SCC to the service account:

```bash
oc adm policy add-scc-to-user anyuid -z default -n neuraltrust
```

2. Or use a custom SCC that matches your security requirements.

### Storage Classes

OpenShift typically uses different storage classes. Configure the storage class in your values:

```yaml
global:
  storageClass: "gp2"  # or your OpenShift storage class
```

Or for specific components:

```yaml
infrastructure:
  clickhouse:
    chart:
      persistence:
        storageClass: "gp2"
```

## Deployment Steps

### Step 1: Create Namespace

```bash
oc create namespace neuraltrust
```

### Step 2: Create All Required Secrets

Create all secrets as described in the [Creating Secrets](#creating-secrets) section. At minimum, you need:

- `data-plane-jwt-secret`
- `control-plane-secrets` (with `CONTROL_PLANE_JWT_SECRET`)
- `postgresql-secrets`
- `clickhouse` (if deploying ClickHouse) - with key `admin-password`
- `gcr-secret` (if using private images)

**Note:** The `clickhouse-secrets` secret used by the data plane is auto-generated by the Helm chart and does not need to be created manually.

### Step 3: Update Helm Dependencies

```bash
helm dependency update
```

### Step 4: Configure Values File

Create or modify your values file for OpenShift:

```yaml
global:
  openshift: true
  openshiftDomain: "YOUR_DOMAIN"  # Your OpenShift wildcard DNS domain (e.g., apps.neuraltrust-dev.c4u5.p2.openshiftapps.com)
  storageClass: "gp2"  # Your OpenShift storage class

infrastructure:
  clickhouse:
    deploy: true
    chart:
      auth:
        password: ""  # Will use secret 'clickhouse' with key 'admin-password'
  
  kafka:
    deploy: true
  
  postgresql:
    deploy: false  # Use external PostgreSQL
    external:
      host: "postgresql.postgresql.svc.cluster.local"
      port: "5432"
      user: "postgres"
      database: "neuraltrust"

neuraltrust-data-plane:
  dataPlane:
    enabled: true

neuraltrust-control-plane:
  controlPlane:
    enabled: true

trustgate:
  enabled: true
```

### Step 5: Deploy with Helm

```bash
helm upgrade --install neuraltrust-platform . \
  --namespace neuraltrust \
  --set global.openshift=true \
  --set global.openshiftDomain="YOUR_DOMAIN" \
  -f values.yaml
```

### Step 6: Verify Deployment

```bash
# Check all pods are running
oc get pods -n neuraltrust

# Check services
oc get svc -n neuraltrust

# Check routes
oc get routes -n neuraltrust
```

## Verification

### Check Pod Status

```bash
oc get pods -n neuraltrust
```

All pods should be in `Running` state. If any pod is in `Error` or `CrashLoopBackOff`, check the logs:

```bash
oc logs <pod-name> -n neuraltrust
```

### Check Routes

```bash
oc get routes -n neuraltrust
```

Routes should be created for:
- Data Plane API
- Control Plane API
- Control Plane App
- TrustGate services (if enabled)

### Test Connectivity

```bash
# Test Data Plane API
curl https://$(oc get route data-plane-api-route -n neuraltrust -o jsonpath='{.spec.host}')/health

# Test Control Plane API
curl https://$(oc get route control-plane-api-route -n neuraltrust -o jsonpath='{.spec.host}')/health
```

### Verify Secrets

```bash
# List all secrets
oc get secrets -n neuraltrust

# Verify a specific secret
oc get secret data-plane-jwt-secret -n neuraltrust -o yaml
```

## Troubleshooting

### Pods Failing to Start

1. **Check pod logs:**
   ```bash
   oc logs <pod-name> -n neuraltrust
   ```

2. **Check events:**
   ```bash
   oc get events -n neuraltrust --sort-by='.lastTimestamp'
   ```

3. **Check pod description:**
   ```bash
   oc describe pod <pod-name> -n neuraltrust
   ```

### Secret Not Found Errors

If you see errors about missing secrets:

```bash
# List all secrets
oc get secrets -n neuraltrust

# Verify secret exists and has correct keys
oc get secret <secret-name> -n neuraltrust -o jsonpath='{.data}' | jq
```

### SCC (Security Context Constraints) Issues

If pods fail due to SCC restrictions:

```bash
# Check current SCC
oc get scc

# Grant appropriate SCC (adjust as needed)
oc adm policy add-scc-to-user anyuid -z default -n neuraltrust
```

### Image Pull Errors

If you see image pull errors:

1. **Verify registry secret exists:**
   ```bash
   oc get secret gcr-secret -n neuraltrust
   ```

2. **Link secret to service account:**
   ```bash
   oc secrets link default gcr-secret --for=pull -n neuraltrust
   ```

### Route Not Accessible

1. **Check route status:**
   ```bash
   oc get route <route-name> -n neuraltrust -o yaml
   ```

2. **Check route events:**
   ```bash
   oc describe route <route-name> -n neuraltrust
   ```

### Database Connection Issues

1. **Verify PostgreSQL secret:**
   ```bash
   oc get secret postgresql-secrets -n neuraltrust -o jsonpath='{.data.DATABASE_URL}' | base64 -d
   ```

2. **Test connection from a pod:**
   ```bash
   oc run -it --rm postgres-test --image=postgres:17.2-alpine --restart=Never -- \
     psql "$(oc get secret postgresql-secrets -n neuraltrust -o jsonpath='{.data.DATABASE_URL}' | base64 -d)"
   ```

## Complete Secret Creation Script for OpenShift

Here's a complete script to create all required secrets:

```bash
#!/bin/bash
set -e

NAMESPACE="${NAMESPACE:-neuraltrust}"
RELEASE_NAME="${RELEASE_NAME:-neuraltrust-platform}"

# Create namespace if it doesn't exist
oc create namespace "$NAMESPACE" --dry-run=client -o yaml | oc apply -f -

# Generate random secrets
DATA_PLANE_JWT=$(openssl rand -hex 32)
CONTROL_PLANE_JWT=$(openssl rand -hex 32)
CLICKHOUSE_PASSWORD=$(openssl rand -base64 32)

# PostgreSQL configuration (adjust as needed)
POSTGRES_HOST="${POSTGRES_HOST:-postgresql.postgresql.svc.cluster.local}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(openssl rand -base64 32)}"
POSTGRES_DB="${POSTGRES_DB:-neuraltrust}"

# URL-encode password
POSTGRES_PASSWORD_ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$POSTGRES_PASSWORD', safe=''))")
DATABASE_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD_ENCODED}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}?connection_limit=15"

echo "Creating secrets in namespace: $NAMESPACE"

# Data Plane JWT Secret
oc create secret generic data-plane-jwt-secret \
  --from-literal=DATA_PLANE_JWT_SECRET="$DATA_PLANE_JWT" \
  -n "$NAMESPACE" --dry-run=client -o yaml | oc apply -f -

# Control Plane Secrets
oc create secret generic control-plane-secrets \
  --from-literal=CONTROL_PLANE_JWT_SECRET="$CONTROL_PLANE_JWT" \
  -n "$NAMESPACE" --dry-run=client -o yaml | oc apply -f -

# PostgreSQL Secrets
oc create secret generic postgresql-secrets \
  --from-literal=POSTGRES_HOST="$POSTGRES_HOST" \
  --from-literal=POSTGRES_PORT="$POSTGRES_PORT" \
  --from-literal=POSTGRES_USER="$POSTGRES_USER" \
  --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  --from-literal=POSTGRES_DB="$POSTGRES_DB" \
  --from-literal=DATABASE_URL="$DATABASE_URL" \
  --from-literal=POSTGRES_PRISMA_URL="$DATABASE_URL" \
  -n "$NAMESPACE" --dry-run=client -o yaml | oc apply -f -

# ClickHouse Secret
oc create secret generic clickhouse \
  --from-literal=admin-password="$CLICKHOUSE_PASSWORD" \
  -n "$NAMESPACE" --dry-run=client -o yaml | oc apply -f -

# TrustGate Secrets
oc create secret generic trustgate-secrets \
  --from-literal=SERVER_SECRET_KEY="$(openssl rand -hex 32)" \
  -n "$NAMESPACE" --dry-run=client -o yaml | oc apply -f -

# Hugging Face API Key for Firewall (reuse from huggingface-secrets if it exists)
# Set HF_TOKEN if you want to use a specific token, otherwise it will try to reuse from huggingface-secrets
if [ -z "${HF_TOKEN:-}" ]; then
  if oc get secret huggingface-secrets -n "$NAMESPACE" &>/dev/null; then
    echo "Reusing Hugging Face token from existing huggingface-secrets..."
    HF_TOKEN=$(oc get secret huggingface-secrets -n "$NAMESPACE" -o jsonpath='{.data.HUGGINGFACE_TOKEN}' | base64 -d 2>/dev/null || echo "")
  fi
fi

# Only create hf-api-key if HF_TOKEN is set (optional secret)
if [ -n "${HF_TOKEN:-}" ]; then
  oc create secret generic hf-api-key \
    --from-literal=HUGGINGFACE_TOKEN="$HF_TOKEN" \
    -n "$NAMESPACE" --dry-run=client -o yaml | oc apply -f -
  echo "Created hf-api-key secret (reused from huggingface-secrets)"
fi

echo "Secrets created successfully!"
echo ""
echo "Next steps:"
echo "1. Update Helm dependencies: helm dependency update"
echo "2. Deploy with: helm upgrade --install $RELEASE_NAME . --namespace $NAMESPACE --set global.openshift=true --set global.openshiftDomain=\"YOUR_DOMAIN\" -f values-openshift.yaml"
```

Save this as `create-secrets-openshift.sh`, make it executable, and run:

```bash
chmod +x create-secrets-openshift.sh
./create-secrets-openshift.sh
```

## Additional Resources

- [Main README](./README.md) - General deployment guide
- [SECRETS.md](./SECRETS.md) - Detailed secrets management guide
- [DEPLOYMENT.md](./DEPLOYMENT.md) - Deployment scenarios and troubleshooting

## Support

For issues and questions:
- 📚 [Documentation](https://docs.neuraltrust.ai)
- 💬 [Slack Community](https://join.slack.com/t/neuraltrustcommunity/shared_invite/zt-2xl47cag6-_HFNpltIULnA3wh4R6AqBg)
- 🐛 [Report Issues](https://github.com/NeuralTrust/neuraltrust-platform/issues)

