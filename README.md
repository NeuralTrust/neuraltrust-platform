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
- (Optional) cert-manager for TLS certificates
- (Optional) Ingress controller (nginx-ingress recommended)

## Note on Helm Lint

When running `helm lint`, you may see errors related to subchart templates accessing values. This is typically a false positive because Helm lint validates templates without the full values context. The chart will deploy correctly when using `helm upgrade --install` with proper values.

## Quick Start

### 1. Create Secrets (Required)

Before deploying, create all necessary secrets:

```bash
# Option A: Use the interactive script
./create-secrets.sh

# Option B: Use environment variables
export DATA_PLANE_JWT_SECRET="your-secret"
export CONTROL_PLANE_JWT_SECRET="your-secret"
# ... set other secrets ...
./create-secrets.sh --namespace neuraltrust

# Option C: Use pre-defined secrets
# If you already have secrets in your cluster, skip this step
# The Helm chart will automatically use them
```

See [SECRETS.md](./SECRETS.md) for detailed secrets management guide.

## Troubleshooting

### Kafka Cluster ID Mismatch Error

If you see an error like:
```
Invalid cluster.id in: /bitnami/kafka/data/meta.properties. Expected X, but read Y
```

This happens when the persistent volume has old cluster ID data from a previous deployment. To fix:

**Option 1: Delete and recreate the PVC (loses all data)**
```bash
# Scale down Kafka
kubectl scale statefulset kafka-broker -n neuraltrust --replicas=0

# Delete the PVC
kubectl delete pvc data-kafka-broker-0 -n neuraltrust

# Scale back up (new PVC will be created)
kubectl scale statefulset kafka-broker -n neuraltrust --replicas=1
```

**Option 2: Clear the meta.properties file (keeps other data)**
```bash
# Scale down Kafka
kubectl scale statefulset kafka-broker -n neuraltrust --replicas=0

# Delete the pod to release the volume
kubectl delete pod kafka-broker-0 -n neuraltrust

# Use a debug pod to clear the file
kubectl run -it --rm debug --image=bitnami/kafka:3.9.0 --restart=Never -n neuraltrust -- bash
# Inside the pod, mount the PVC and delete meta.properties
# Then exit and scale Kafka back up
```

### 2. Install Dependencies

```bash
helm dependency update
```

### 3. Configure Values

Copy and edit the values file:

```bash
cp values.yaml my-values.yaml
# Edit my-values.yaml with your configuration
```

### 4. Deploy

```bash
helm upgrade --install neuraltrust-platform . \
  --namespace neuraltrust \
  --create-namespace \
  -f my-values.yaml
```

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
neuraltrust:
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
neuraltrust:
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

neuraltrust:
  dataPlane:
    enabled: true
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

neuraltrust:
  dataPlane:
    enabled: true
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

## Troubleshooting

### Check Pod Status

```bash
kubectl get pods -n neuraltrust
```

### View Logs

```bash
# NeuralTrust Data Plane API
kubectl logs -n neuraltrust -l app=neuraltrust-data-plane-api

# NeuralTrust Control Plane API
kubectl logs -n neuraltrust -l app=neuraltrust-control-plane-api

# TrustGate Control Plane
kubectl logs -n neuraltrust -l app=trustgate-control-plane
```

### Check Services

```bash
kubectl get svc -n neuraltrust
```

### Verify Infrastructure Connections

```bash
# Test ClickHouse connection
kubectl run -it --rm clickhouse-client --image=clickhouse/clickhouse-client --restart=Never -- \
  clickhouse-client --host=<clickhouse-host> --port=8123 --user=neuraltrust --password=<password>

# Test Kafka connection
kubectl run -it --rm kafka-client --image=bitnami/kafka:latest --restart=Never -- \
  kafka-topics.sh --bootstrap-server <kafka-host>:9092 --list

# Test PostgreSQL connection
kubectl run -it --rm postgres-client --image=postgres:17.2-alpine --restart=Never -- \
  psql -h <postgres-host> -U postgres -d neuraltrust
```

## Configuration Reference

See `values.yaml` for all available configuration options. Key sections:

- `infrastructure.*` - Infrastructure component configuration
- `neuraltrust.*` - NeuralTrust service configuration
- `trustgate.*` - TrustGate configuration
- `global.*` - Global settings

## Secrets Management

The Helm chart supports using pre-defined Kubernetes secrets or environment variables. See [SECRETS.md](./SECRETS.md) for:
- How to create secrets using the provided script
- Environment variable support
- Using pre-defined secrets
- Secret names and keys
- Security best practices

## Support

For issues and questions:
- 📚 [Documentation](https://docs.neuraltrust.ai)
- 💬 [Slack Community](https://join.slack.com/t/neuraltrustcommunity/shared_invite/zt-2xl47cag6-_HFNpltIULnA3wh4R6AqBg)
- 🐛 [Report Issues](https://github.com/NeuralTrust/neuraltrust-deploy/issues)

## License

Apache License 2.0

