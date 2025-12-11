# NeuralTrust Platform Unified Deployment - Summary

## Overview

This unified Helm chart merges `neuraltrust-helm-charts` and `trustgate-helm-charts` into a single deployment solution. It allows deploying the complete NeuralTrust platform with a single `helm upgrade --install` command using one unified `values.yaml` file.

## Structure

```
neuraltrust-deploy/
├── Chart.yaml                    # Main chart with dependencies
├── values.yaml                   # Unified values file
├── README.md                     # Main documentation
├── DEPLOYMENT.md                 # Deployment guide
├── values-external-services.yaml.example  # Example: external services
├── values-all-deployed.yaml.example      # Example: deploy everything
├── templates/
│   ├── _helpers.tpl              # Helper templates
│   ├── NOTES.txt                 # Post-install notes
│   └── infrastructure-secrets.yaml  # Infrastructure secret templates
└── charts/                       # Subcharts
    ├── clickhouse/               # ClickHouse chart (conditional)
    ├── kafka/                    # Kafka chart (conditional)
    ├── neuraltrust-data-plane/   # NeuralTrust Data Plane
    ├── neuraltrust-control-plane/# NeuralTrust Control Plane
    └── trustgate/                # TrustGate components
```

## Key Features

### 1. Infrastructure Components

- **ClickHouse**: Deploy or use external (default: deploy)
- **Kafka**: Deploy or use external (default: deploy)
- **PostgreSQL**: Deploy or use external (default: NOT deploy)

### 2. Service Components

- **NeuralTrust Data Plane**: Always deployed when enabled
- **NeuralTrust Control Plane**: Always deployed when enabled
- **TrustGate**: Always deployed when enabled (includes control-plane, data-plane, redis)

### 3. Unified Configuration

All configuration is in a single `values.yaml` file with clear sections:
- `infrastructure.*` - Infrastructure component configuration
- `neuraltrust.*` - NeuralTrust service configuration
- `trustgate.*` - TrustGate configuration
- `global.*` - Global settings

## Deployment Flags

### ClickHouse

```yaml
infrastructure:
  clickhouse:
    deploy: true  # Default: deploy ClickHouse
    # OR
    deploy: false  # Use external ClickHouse
    external:
      host: "clickhouse.clickhouse.svc.cluster.local"
      port: "8123"
      user: "neuraltrust"
      password: "password"
      database: "neuraltrust"
```

### Kafka

```yaml
infrastructure:
  kafka:
    deploy: true  # Default: deploy Kafka
    # OR
    deploy: false  # Use external Kafka
    external:
      bootstrapServers: "kafka-kafka-bootstrap.kafka.svc.cluster.local:9092"
```

### PostgreSQL

```yaml
infrastructure:
  postgresql:
    deploy: false  # Default: do NOT deploy (use external)
    # OR
    deploy: true  # Deploy PostgreSQL
    chart:
      persistence:
        size: 10Gi
```

## Usage

### Basic Deployment

```bash
# Update dependencies
helm dependency update

# Deploy with default values
helm upgrade --install neuraltrust-platform . \
  --namespace neuraltrust \
  --create-namespace \
  -f values.yaml
```

### With Custom Values

```bash
# Deploy with custom values
helm upgrade --install neuraltrust-platform . \
  --namespace neuraltrust \
  --create-namespace \
  -f my-values.yaml
```

### Using External Services

```bash
# Deploy using external infrastructure
helm upgrade --install neuraltrust-platform . \
  --namespace neuraltrust \
  --create-namespace \
  -f values-external-services.yaml.example
```

## Value Mapping

The chart automatically handles value mapping between infrastructure configuration and subchart values:

1. **Infrastructure flags** (`infrastructure.*.deploy`) control whether components are deployed
2. **Subchart values** are automatically passed based on infrastructure configuration
3. **Connection details** are configured based on deploy flags (deployed vs external)

## Components Included

### Infrastructure (Conditional)
- ClickHouse 8.0.10
- Kafka 31.0.0
- PostgreSQL 17.2 (optional)

### NeuralTrust Services
- Data Plane API
- Data Plane Worker
- Control Plane API
- Control Plane App
- Control Plane Scheduler

### TrustGate Services
- Control Plane
- Data Plane
- Redis

## Next Steps

1. Review `values.yaml` and configure according to your needs
2. Set required secrets (API keys, passwords, etc.)
3. Configure ingress hosts and TLS
4. Deploy using `helm upgrade --install`
5. Verify deployment with `kubectl get pods -n neuraltrust`

## Documentation

- **README.md**: Main documentation with quick start
- **DEPLOYMENT.md**: Detailed deployment guide with scenarios
- **values.yaml**: Comprehensive configuration reference
- **values-*.yaml.example**: Example configurations

## Notes

- The chart uses Helm 3 dependency management
- Subcharts are included as file dependencies
- Infrastructure components are conditionally deployed based on flags
- External service configuration is supported for all infrastructure components
- All components can be enabled/disabled independently

