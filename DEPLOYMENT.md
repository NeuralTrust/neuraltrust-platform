# Deployment Guide

This guide explains how to deploy the NeuralTrust Platform using the unified Helm chart.

## Quick Start

```bash
# 1. Update dependencies
helm dependency update

# 2. Deploy with default values (deploys ClickHouse and Kafka, uses external PostgreSQL)
helm upgrade --install neuraltrust-platform . \
  --namespace neuraltrust \
  --create-namespace \
  -f values.yaml

# 3. Or use a custom values file
helm upgrade --install neuraltrust-platform . \
  --namespace neuraltrust \
  --create-namespace \
  -f my-values.yaml
```

## Deployment Scenarios

### Scenario 1: Deploy Everything (Default)

Deploy ClickHouse, Kafka, and all services. PostgreSQL is NOT deployed by default.

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

### Scenario 2: Use External Infrastructure

If you have pre-installed ClickHouse, Kafka, and PostgreSQL:

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
      password: "your-password"
      database: "neuraltrust"

neuraltrust:
  dataPlane:
    enabled: true
    components:
      clickhouse:
        enabled: false  # External
        host: "clickhouse.clickhouse.svc.cluster.local"
        port: "8123"
        user: "neuraltrust"
        database: "neuraltrust"
      kafka:
        enabled: false  # External
  controlPlane:
    enabled: true
    components:
      postgresql:
        installInCluster: false  # External
        secrets:
          host: "postgresql.postgresql.svc.cluster.local"
          port: "5432"
          user: "postgres"
          password: "your-password"
          database: "neuraltrust"

trustgate:
  enabled: true
  global:
    env:
      DATABASE_HOST: "postgresql.postgresql.svc.cluster.local"
      DATABASE_PORT: "5432"
      DATABASE_USER: "postgres"
      DATABASE_PASSWORD: "your-password"
      DATABASE_NAME: "trustgate"
```

### Scenario 3: Deploy PostgreSQL Too

To also deploy PostgreSQL:

```yaml
infrastructure:
  clickhouse:
    deploy: true
  kafka:
    deploy: true
  postgresql:
    deploy: true  # Deploy PostgreSQL

neuraltrust:
  controlPlane:
    enabled: true
    components:
      postgresql:
        installInCluster: true  # Use deployed PostgreSQL
        secrets:
          password: "your-password"
          database: "neuraltrust"
```

## Value Mapping

### Infrastructure to Subchart Values

The chart automatically maps infrastructure configuration to subchart values:

- **ClickHouse**: When `infrastructure.clickhouse.deploy=true`, the ClickHouse subchart is deployed. The `neuraltrust.dataPlane.components.clickhouse.*` values are used by the data-plane subchart for connection configuration.

- **Kafka**: When `infrastructure.kafka.deploy=true`, the Kafka subchart is deployed. The data-plane subchart connects to Kafka using the service name.

- **PostgreSQL**: When `infrastructure.postgresql.deploy=true`, PostgreSQL is deployed by the control-plane subchart. Set `neuraltrust.controlPlane.components.postgresql.installInCluster=true`.

### Connection Details

**ClickHouse Connection:**
- Deployed: Uses service name `<release-name>-clickhouse` (managed by ClickHouse subchart)
- External: Uses `infrastructure.clickhouse.external.host`

**Kafka Connection:**
- Deployed: Uses service name `kafka` (managed by Kafka subchart)
- External: Uses `infrastructure.kafka.external.bootstrapServers`

**PostgreSQL Connection:**
- Deployed: Uses service name `<release-name>-postgresql` (managed by control-plane subchart)
- External: Uses `infrastructure.postgresql.external.host`

## Troubleshooting

### Check Infrastructure Deployment

```bash
# Check if ClickHouse is deployed
kubectl get pods -n neuraltrust | grep clickhouse

# Check if Kafka is deployed
kubectl get pods -n neuraltrust | grep kafka

# Check if PostgreSQL is deployed
kubectl get pods -n neuraltrust | grep postgresql
```

### Verify Connections

```bash
# Test ClickHouse connection
kubectl exec -it -n neuraltrust <data-plane-api-pod> -- \
  clickhouse-client --host=<clickhouse-host> --port=8123 --user=neuraltrust --password=<password>

# Test Kafka connection
kubectl exec -it -n neuraltrust <data-plane-api-pod> -- \
  kafka-topics.sh --bootstrap-server <kafka-host>:9092 --list

# Test PostgreSQL connection
kubectl exec -it -n neuraltrust <control-plane-api-pod> -- \
  psql -h <postgres-host> -U postgres -d neuraltrust
```

### Common Issues

1. **ClickHouse connection fails**: Verify `neuraltrust.dataPlane.components.clickhouse.host` matches the actual ClickHouse service name.

2. **Kafka connection fails**: Check that `KAFKA_BOOTSTRAP_SERVERS` environment variable is set correctly in data-plane pods.

3. **PostgreSQL connection fails**: Verify `neuraltrust.controlPlane.components.postgresql.secrets.host` and credentials are correct.

## Next Steps

After deployment:
1. Configure ingress hosts and TLS certificates
2. Set up secrets for API keys (OpenAI, Google, etc.)
3. Configure TrustGate domains
4. Set up monitoring and alerting

See the main README.md for more details.

