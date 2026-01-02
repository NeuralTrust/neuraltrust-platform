# NeuralTrust Platform Unified Deployment

This Helm chart provides a unified deployment for the complete NeuralTrust platform, including:

- **Infrastructure Components**: ClickHouse, Kafka, PostgreSQL (optional)
- **NeuralTrust Services**: Data Plane and Control Plane
- **TrustGate**: API Gateway

## Features

- **Unified Deployment**: Deploy all components with a single `helm upgrade --install` command
- **Flexible Infrastructure**: Choose to deploy infrastructure components or use pre-installed instances
- **Conditional Deployment**: Enable/disable components as needed
- **External Service Support**: Configure external ClickHouse, Kafka, and PostgreSQL instances

## Prerequisites

- Kubernetes 1.19+ or OpenShift 4.10+
- Helm 3.2.0+
- kubectl configured to access your cluster
- (Optional) Ingress controller - **Not included in this chart**. Install separately if needed:
  - For Kubernetes: [ingress-nginx](https://kubernetes.github.io/ingress-nginx/deploy/) or [Traefik](https://doc.traefik.io/traefik/getting-started/install-traefik/)
  - For OpenShift: Routes are available by default (no additional installation needed)
- (Optional) cert-manager - **Not included in this chart**. Install separately if you want automatic TLS certificate management:
  - Install cert-manager: `helm install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --set installCRDs=true`
  - See [cert-manager documentation](https://cert-manager.io/docs/installation/) for details
  - If not using cert-manager, provide pre-existing `kubernetes.io/tls` secrets

## Note on Helm Lint

When running `helm lint`, you may see errors related to subchart templates accessing values. This is typically a false positive because Helm lint validates templates without the full values context. The chart will deploy correctly when using `helm upgrade --install` with proper values.

## Quick Start

### 1. Install Dependencies

```bash
helm dependency update
```

### 2. Configure Values

Copy and edit the values file:

```bash
cp values.yaml my-values.yaml
# Edit my-values.yaml with your configuration
```

**Set your secrets in `my-values.yaml`.** By default (`preserveExistingSecrets: false`), Helm will automatically create Kubernetes secrets from the values you provide:

```yaml
global:
  preserveExistingSecrets: false  # Default: Helm creates secrets from values.yaml

neuraltrust-control-plane:
  controlPlane:
    secrets:
      controlPlaneJWTSecret: "your-jwt-secret"
      trustgateJwtSecret: "your-trustgate-secret"
      # ... set other required secrets

neuraltrust-data-plane:
  dataPlane:
    secrets:
      dataPlaneJWTSecret: "your-data-plane-secret"
      # ... set other required secrets
```

### 3. Deploy

```bash
helm upgrade --install neuraltrust-platform . \
  --namespace neuraltrust \
  --create-namespace \
  -f my-values.yaml
```

The Helm chart will automatically create all required Kubernetes secrets from your `values.yaml` configuration during deployment.

## Secrets Management

The chart supports two modes for managing secrets:

### Default Mode: Helm-Managed Secrets (`preserveExistingSecrets: false`)

**This is the recommended approach for most users.** Helm automatically creates Kubernetes secrets from values in your `values.yaml`:

```yaml
global:
  preserveExistingSecrets: false  # Default

neuraltrust-control-plane:
  controlPlane:
    secrets:
      controlPlaneJWTSecret: "your-secret-value"
      trustgateJwtSecret: "your-secret-value"
      # ... set other secrets in values.yaml
```

**Benefits:**
- Simple: Just set values in `values.yaml` and deploy
- No manual secret creation required
- Helm manages secret lifecycle (create/update)
- Secrets are updated automatically when you change values in `values.yaml`

**Note:** When `preserveExistingSecrets: false`, Helm will create secrets if they don't exist and update them if they do exist (based on your `values.yaml`). This allows Helm to fully manage secrets throughout the deployment lifecycle.

### Advanced Mode: Pre-Generated Secrets (`preserveExistingSecrets: true`)

For CI/CD pipelines or environments where secrets are managed externally, you can pre-generate secrets and tell Helm to use them:

```yaml
global:
  preserveExistingSecrets: true  # Helm will NOT create/update secrets
```

**When to use this mode:**
- Secrets are managed by external secret management systems (e.g., Vault, Sealed Secrets)
- CI/CD pipelines that generate secrets before deployment
- Compliance requirements for secret management

**How to pre-generate secrets:**

```bash
# Option A: Use the interactive script
./create-secrets.sh

# Option B: Use environment variables
export DATA_PLANE_JWT_SECRET="your-secret"
export CONTROL_PLANE_JWT_SECRET="your-secret"
# ... set other secrets ...
./create-secrets.sh --namespace neuraltrust

# Option C: Create secrets manually
kubectl create secret generic control-plane-secrets \
  --from-literal=CONTROL_PLANE_JWT_SECRET="your-secret" \
  --namespace neuraltrust
```

**Important:** When `preserveExistingSecrets: true`:
- Helm will **NOT** create or update any secrets
- All required secrets must exist before deployment
- Secret templates are not rendered (Helm skips them entirely)
- See [SECRETS.md](./SECRETS.md) for the complete list of required secrets

See [SECRETS.md](./SECRETS.md) for detailed secrets management guide, including all secret names and keys.

## Infrastructure Configuration

### ClickHouse

**Deploy ClickHouse (default):**
```yaml
infrastructure:
  clickhouse:
    deploy: true
    chart:
      auth:
        password: "your-password"
      persistence:
        size: 10Gi
```

**Use External ClickHouse:**
```yaml
infrastructure:
  clickhouse:
    deploy: false
    external:
      host: "clickhouse.clickhouse.svc.cluster.local"
      port: "8123"
      user: "neuraltrust"
      password: "your-password"
      database: "neuraltrust"
```

### Kafka

**Deploy Kafka (default):**
```yaml
infrastructure:
  kafka:
    deploy: true
    chart:
      persistence:
        size: 10Gi
```

**Use External Kafka:**
```yaml
infrastructure:
  kafka:
    deploy: false
    external:
      bootstrapServers: "kafka-kafka-bootstrap.kafka.svc.cluster.local:9092"
      # Or use individual brokers:
      # brokers:
      #   - "kafka-0.kafka-headless:9092"
      #   - "kafka-1.kafka-headless:9092"
```

### PostgreSQL

**Deploy PostgreSQL:**
```yaml
infrastructure:
  postgresql:
    deploy: true
    chart:
      persistence:
        size: 10Gi
```

**Use External PostgreSQL (default):**
```yaml
infrastructure:
  postgresql:
    deploy: false
    external:
      host: "postgresql.postgresql.svc.cluster.local"
      port: "5432"
      user: "postgres"
      password: "your-password"
      database: "neuraltrust"
```

## Component Configuration

### NeuralTrust Data Plane

Enable/disable the data plane:

```yaml
neuraltrust-data-plane:
  dataPlane:
    enabled: true
    components:
      api:
        enabled: true
        host: "data-plane-api.example.com"
      worker:
        enabled: true
```

### NeuralTrust Control Plane

Enable/disable the control plane:

```yaml
neuraltrust-control-plane:
  controlPlane:
    enabled: true
    components:
      api:
        enabled: true
        host: "control-plane-api.example.com"
      app:
        enabled: true
        host: "control-plane-app.example.com"
      scheduler:
        enabled: true
```

### TrustGate

Enable/disable TrustGate:

```yaml
trustgate:
  enabled: true
  controlPlane:
    replicas: 1
  dataPlane:
    replicas: 1
  redis:
    enabled: true
```

## Example: Deploy with External Services

If you have pre-installed ClickHouse, Kafka, and PostgreSQL:

```yaml
infrastructure:
  clickhouse:
    deploy: false
    external:
      host: "clickhouse.clickhouse.svc.cluster.local"
      port: "8123"
      user: "neuraltrust"
      password: "your-clickhouse-password"
      database: "neuraltrust"
  
  kafka:
    deploy: false
    external:
      bootstrapServers: "kafka-kafka-bootstrap.kafka.svc.cluster.local:9092"
  
  postgresql:
    deploy: false
    external:
      host: "postgresql.postgresql.svc.cluster.local"
      port: "5432"
      user: "postgres"
      password: "your-postgres-password"
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

Then deploy:

```bash
helm upgrade --install neuraltrust-platform . \
  --namespace neuraltrust \
  --create-namespace \
  -f values-external-services.yaml
```

## Example: Deploy Everything (Default)

Deploy all infrastructure and services:

```yaml
infrastructure:
  clickhouse:
    deploy: true  # Default
  kafka:
    deploy: true  # Default
  postgresql:
    deploy: false  # Default: use external

neuraltrust-data-plane:
  dataPlane:
    enabled: true

neuraltrust-control-plane:
  controlPlane:
    enabled: true

trustgate:
  enabled: true
```

## Upgrading

To upgrade the deployment:

```bash
helm dependency update
helm upgrade neuraltrust-platform . \
  --namespace neuraltrust \
  -f my-values.yaml
```

## Uninstalling

To uninstall the deployment:

```bash
helm uninstall neuraltrust-platform --namespace neuraltrust
```

**Note**: If you set `infrastructure.postgresql.chart.persistence.preserveOnDelete: true`, the PostgreSQL PVC will be preserved.

## TLS Certificate Management

The chart supports TLS certificates in two ways:

### Option 1: Pre-existing TLS Secrets (Default)

Create `kubernetes.io/tls` secrets manually and reference them in your values:

```yaml
trustgate:
  ingress:
    tls:
      enabled: true
      secretName: "wildcard-tls-secret"  # Pre-existing secret

neuraltrust-control-plane:
  controlPlane:
    components:
      api:
        ingress:
          tls:
            enabled: true
            secretName: "api-tls-secret"  # Pre-existing secret
```

### Option 2: cert-manager (Automatic Certificate Management)

**Note:** cert-manager is not included in this chart. You must install it separately before using this option.

**Install cert-manager:**
```bash
# Add the Jetstack Helm repository
helm repo add jetstack https://charts.jetstack.io
helm repo update

# Install cert-manager
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set installCRDs=true
```

**Create a ClusterIssuer (example for Let's Encrypt):**
```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your-email@example.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: nginx
```

**Configure the chart to use cert-manager:**

Add cert-manager annotations to Ingress resources. cert-manager will automatically create and manage the TLS secrets:

```yaml
trustgate:
  ingress:
    enabled: true
    annotations:
      cert-manager.io/cluster-issuer: "letsencrypt-prod"  # or "letsencrypt-staging"
    tls:
      enabled: true
      # secretName will be auto-created by cert-manager

neuraltrust-control-plane:
  controlPlane:
    components:
      api:
        ingress:
          enabled: true
          annotations:
            cert-manager.io/cluster-issuer: "letsencrypt-prod"
          tls:
            enabled: true
```

**Note:** When using cert-manager, you don't need to create the TLS secrets manually. cert-manager will create them automatically based on the annotations. See [cert-manager documentation](https://cert-manager.io/docs/) for more details.

## Configuration Reference

See `values.yaml` for all available configuration options. Key sections:

- `infrastructure.*` - Infrastructure component configuration
- `neuraltrust-data-plane.*` - NeuralTrust Data Plane service configuration
- `neuraltrust-control-plane.*` - NeuralTrust Control Plane service configuration
- `trustgate.*` - TrustGate configuration
- `global.*` - Global settings

## Advanced Secrets Management

For advanced use cases, see [SECRETS.md](./SECRETS.md) for:
- Complete list of all required secrets and their keys
- Using the `create-secrets.sh` script for pre-generating secrets
- Environment variable support for secret creation
- Secret names and structure
- Security best practices
- Troubleshooting secret-related issues

## Troubleshooting

For troubleshooting deployment issues, see:

- **[DEPLOYMENT.md](./DEPLOYMENT.md)** - Deployment scenarios, connection verification, and common issues
- **[README-OPENSHIFT.md](./README-OPENSHIFT.md)** - OpenShift-specific troubleshooting (SCC issues, Routes, image pull errors, etc.)
- **[SECRETS.md](./SECRETS.md)** - Troubleshooting secret-related issues

### Common Issues

- **Kafka Cluster ID Mismatch**: See [DEPLOYMENT.md](./DEPLOYMENT.md#troubleshooting) for solutions
- **Pod startup failures**: Check pod logs and events (see [DEPLOYMENT.md](./DEPLOYMENT.md#troubleshooting))
- **Secret not found errors**: See [SECRETS.md](./SECRETS.md#troubleshooting)
- **OpenShift-specific issues**: See [README-OPENSHIFT.md](./README-OPENSHIFT.md#troubleshooting)

## Support

For issues and questions:
- 📚 [Documentation](https://docs.neuraltrust.ai)
- 💬 [Slack Community](https://join.slack.com/t/neuraltrustcommunity/shared_invite/zt-2xl47cag6-_HFNpltIULnA3wh4R6AqBg)
- 🐛 [Report Issues](https://github.com/NeuralTrust/neuraltrust-deploy/issues)

## License

Apache License 2.0

