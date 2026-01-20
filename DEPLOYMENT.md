# Deployment Guide

This guide explains how to deploy the NeuralTrust Platform using the unified Helm chart.

**Chart source:** Prefer a [GitHub Release](https://github.com/NeuralTrust/neuraltrust-platform/releases) or OCI (Artifact Registry) over cloning `main`. See [Releases and Installing the Chart](README.md#releases-and-installing-the-chart) in the main README for OCI and tarball installs. The examples below use `.` for a local chart (e.g. after `helm pull` or clone at a tag); replace with your chart path or OCI URL as needed.

## Quick Start

```bash
# 1. Update dependencies (only if using a local clone; skip when using OCI or a .tgz)
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

neuraltrust-data-plane:
  dataPlane:
    enabled: true

neuraltrust-control-plane:
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

neuraltrust-data-plane:
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

neuraltrust-control-plane:
  controlPlane:
    enabled: true
    components:
      postgresql:
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

neuraltrust-control-plane:
  controlPlane:
    enabled: true
    components:
      postgresql:
        secrets:
          password: "your-password"
          database: "neuraltrust"
```

## Value Mapping

### Infrastructure to Subchart Values

The chart automatically maps infrastructure configuration to subchart values:

- **ClickHouse**: When `infrastructure.clickhouse.deploy=true`, the ClickHouse subchart is deployed. The `neuraltrust-data-plane.dataPlane.components.clickhouse.*` values are used by the data-plane subchart for connection configuration.

- **Kafka**: When `infrastructure.kafka.deploy=true`, the Kafka subchart is deployed. The data-plane subchart connects to Kafka using the service name.

- **PostgreSQL**: When `neuraltrust-control-plane.infrastructure.postgresql.deploy=true`, PostgreSQL is deployed by the control-plane subchart. The connection is automatically configured to use the in-cluster PostgreSQL service.

### Connection Details

**ClickHouse Connection:**
- Deployed: Uses service name `<release-name>-clickhouse` (managed by ClickHouse subchart)
- External: Uses `infrastructure.clickhouse.external.host`

**Kafka Connection:**
- Deployed: Uses service name `kafka` (managed by Kafka subchart)
- External: Uses `infrastructure.kafka.external.bootstrapServers`

**PostgreSQL Connection:**
- Deployed: Uses service name `control-plane-postgresql` (managed by control-plane subchart)
- External: Uses `neuraltrust-control-plane.controlPlane.components.postgresql.secrets.host`

## Troubleshooting

### Check Pod Status

```bash
kubectl get pods -n neuraltrust
```

All pods should be in `Running` state. If any pod is in `Error` or `CrashLoopBackOff`, check the logs and events.

### View Logs

```bash
# NeuralTrust Data Plane API
kubectl logs -n neuraltrust -l app=neuraltrust-data-plane-api

# NeuralTrust Control Plane API
kubectl logs -n neuraltrust -l app=neuraltrust-control-plane-api

# TrustGate Control Plane
kubectl logs -n neuraltrust -l app=trustgate-control-plane

# View logs for a specific pod
kubectl logs -n neuraltrust <pod-name>

# Follow logs in real-time
kubectl logs -n neuraltrust <pod-name> -f
```

### Check Services

```bash
kubectl get svc -n neuraltrust
```

Verify that all expected services are created and have the correct type (ClusterIP for internal services).

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
kubectl run -it --rm clickhouse-client --image=clickhouse/clickhouse-client --restart=Never -n neuraltrust -- \
  clickhouse-client --host=<clickhouse-host> --port=8123 --user=neuraltrust --password=<password>

# Test Kafka connection
kubectl run -it --rm kafka-client --image=bitnami/kafka:latest --restart=Never -n neuraltrust -- \
  kafka-topics.sh --bootstrap-server <kafka-host>:9092 --list

# Test PostgreSQL connection
kubectl run -it --rm postgres-client --image=postgres:17.2-alpine --restart=Never -n neuraltrust -- \
  psql -h <postgres-host> -U postgres -d neuraltrust
```

### Common Issues

1. **ClickHouse connection fails**: Verify `neuraltrust-data-plane.dataPlane.components.clickhouse.host` matches the actual ClickHouse service name.

2. **Kafka connection fails**: Check that `KAFKA_BOOTSTRAP_SERVERS` environment variable is set correctly in data-plane pods.

3. **PostgreSQL connection fails**: Verify `neuraltrust-control-plane.controlPlane.components.postgresql.secrets.host` and credentials are correct.

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

### Check Events

If pods are failing to start, check Kubernetes events for more details:

```bash
# View recent events
kubectl get events -n neuraltrust --sort-by='.lastTimestamp'

# View events for a specific pod
kubectl describe pod <pod-name> -n neuraltrust
```

### Pod Description

For detailed information about a failing pod:

```bash
kubectl describe pod <pod-name> -n neuraltrust
```

This will show:
- Pod status and conditions
- Recent events
- Container status
- Resource requests/limits
- Volume mounts
- Environment variables

## Next Steps

After deployment:
1. Configure ingress hosts and TLS certificates
2. Set up secrets for API keys (OpenAI, Google, etc.)
3. Configure TrustGate domains
4. Set up monitoring and alerting

See the main [README.md](README.md) for more details, including [releases and install options](README.md#releases-and-installing-the-chart).

