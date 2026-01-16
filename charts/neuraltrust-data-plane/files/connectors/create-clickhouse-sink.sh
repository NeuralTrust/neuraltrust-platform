#!/bin/sh

NAMESPACE=${1:-neuraltrust}
KAFKA_CONNECT_URL="http://kafka-connect-svc.${NAMESPACE}.svc.cluster.local:8083"
echo "NAMESPACE: ${NAMESPACE}"

echo "Waiting for Kafka Connect to be ready..."
MAX_WAIT=600  # 10 minutes
WAITED=0
until curl -s -f ${KAFKA_CONNECT_URL}/connectors > /dev/null 2>&1; do
  if [ $WAITED -ge $MAX_WAIT ]; then
    echo "ERROR: Kafka Connect did not become ready within ${MAX_WAIT} seconds"
    exit 1
  fi
  sleep 5
  WAITED=$((WAITED + 5))
  echo "Waiting for Kafka Connect... (${WAITED}s/${MAX_WAIT}s)"
done

echo "Kafka Connect is ready!"

# Function to delete a connector (idempotent - safe if doesn't exist)
delete_connector() {
  local connector_name=$1
  echo "Deleting connector '${connector_name}'..."
  local response=$(curl -s -w "\n%{http_code}" -X DELETE ${KAFKA_CONNECT_URL}/connectors/${connector_name})
  local http_code=$(echo "$response" | tail -n1)
  
  if [ "$http_code" -eq 204 ] || [ "$http_code" -eq 200 ]; then
    echo "✓ Successfully deleted connector '${connector_name}'"
  else
    # Connector might not exist, which is fine - we'll create it anyway
    echo "  Connector '${connector_name}' not found or already deleted (HTTP ${http_code})"
  fi
  # Wait a moment for deletion to complete
  sleep 2
}

# Function to create a connector
create_connector() {
  local connector_name=$1
  local connector_config=$2
  
  echo "Creating connector '${connector_name}'..."
  local response=$(curl -s -w "\n%{http_code}" -X POST ${KAFKA_CONNECT_URL}/connectors \
    -H "Content-Type: application/json" \
    -d "${connector_config}")
  local http_code=$(echo "$response" | tail -n1)
  local body=$(echo "$response" | sed '$d')
  
  if [ "$http_code" -eq 201 ] || [ "$http_code" -eq 200 ]; then
    echo "✓ Successfully created connector '${connector_name}'"
    return 0
  else
    echo "✗ Failed to create connector '${connector_name}'. HTTP code: ${http_code}"
    echo "Response: ${body}"
    return 1
  fi
}

# Function to delete and recreate a connector (always on upgrade)
create_or_update_connector() {
  local connector_name=$1
  local connector_config=$2
  
  # Always delete first (idempotent - safe if doesn't exist)
  delete_connector "${connector_name}"
  
  # Then create (or recreate)
  create_connector "${connector_name}" "${connector_config}"
}

echo "=== Creating/Updating ClickHouse Connectors ==="
echo "All connectors will be deleted and recreated on every upgrade/sync"
echo ""

echo "Creating ClickHouse Audit Logs Ingest sink connector..."
create_or_update_connector "clickhouse-audit-logs-ingest-sink" '{
  "name": "clickhouse-audit-logs-ingest-sink",
  "config": {
    "connector.class": "com.clickhouse.kafka.connect.ClickHouseSinkConnector",
    "tasks.max": "1",
    "topics": "audit_logs_ingest",
    "hostname": "'${CLICKHOUSE_HOST}'",
    "port": "'${CLICKHOUSE_PORT}'",
    "database": "'${CLICKHOUSE_DATABASE}'",
    "username": "'${CLICKHOUSE_USER}'",
    "password": "'${CLICKHOUSE_PASSWORD}'",
    "ssl": "false",
    "exactlyOnce": "false",
    "state.provider.class": "com.clickhouse.kafka.connect.sink.state.provider.FileStateProvider",
    "state.provider.working.dir": "/tmp/clickhouse-sink",
    "queue.max.wait.ms": "5000",
    "retry.max.count": "5",
    "errors.retry.timeout": "60",
    "errors.tolerance": "all",
    "errors.log.enable": "true",
    "errors.log.include.messages": "true",
    "table.name": "audit_logs_ingest",
    "key.converter": "org.apache.kafka.connect.storage.StringConverter",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter.schemas.enable": "false",
    "transforms": "flattenJson",
    "transforms.flattenJson.type": "org.apache.kafka.connect.transforms.Flatten$Value",
    "transforms.flattenJson.delimiter": "_"
  }
}'

echo "Creating ClickHouse Discover Events sink connector..."
create_or_update_connector "clickhouse-discover-events-sink" '{
  "name": "clickhouse-discover-events-sink",
  "config": {
    "connector.class": "com.clickhouse.kafka.connect.ClickHouseSinkConnector",
    "tasks.max": "1",
    "topics": "discover_events",
    "hostname": "'${CLICKHOUSE_HOST}'",
    "port": "'${CLICKHOUSE_PORT}'",
    "database": "'${CLICKHOUSE_DATABASE}'",
    "username": "'${CLICKHOUSE_USER}'",
    "password": "'${CLICKHOUSE_PASSWORD}'",
    "ssl": "false",
    "exactlyOnce": "false",
    "state.provider.class": "com.clickhouse.kafka.connect.sink.state.provider.FileStateProvider",
    "state.provider.working.dir": "/tmp/clickhouse-sink",
    "queue.max.wait.ms": "5000",
    "retry.max.count": "5",
    "errors.retry.timeout": "60",
    "errors.tolerance": "all",
    "errors.log.enable": "true",
    "errors.log.include.messages": "true",
    "table.name": "discover_events",
    "key.converter": "org.apache.kafka.connect.storage.StringConverter",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter.schemas.enable": "false",
    "transforms": "flattenJson",
    "transforms.flattenJson.type": "org.apache.kafka.connect.transforms.Flatten$Value",
    "transforms.flattenJson.delimiter": "_"
  }
}'

echo "Creating ClickHouse Gpt Usage sink connector..."
create_or_update_connector "clickhouse-gpt-usage-sink" '{
  "name": "clickhouse-gpt-usage-sink",
  "config": {
    "connector.class": "com.clickhouse.kafka.connect.ClickHouseSinkConnector",
    "tasks.max": "1",
    "topics": "gpt_usage",
    "hostname": "'${CLICKHOUSE_HOST}'",
    "port": "'${CLICKHOUSE_PORT}'",
    "database": "'${CLICKHOUSE_DATABASE}'",
    "username": "'${CLICKHOUSE_USER}'",
    "password": "'${CLICKHOUSE_PASSWORD}'",
    "ssl": "false",
    "exactlyOnce": "false",
    "state.provider.class": "com.clickhouse.kafka.connect.sink.state.provider.FileStateProvider",
    "state.provider.working.dir": "/tmp/clickhouse-sink",
    "queue.max.wait.ms": "5000",
    "retry.max.count": "5",
    "errors.retry.timeout": "60",
    "errors.tolerance": "all",
    "errors.log.enable": "true",
    "errors.log.include.messages": "true",
    "table.name": "gpt_usage",
    "key.converter": "org.apache.kafka.connect.storage.StringConverter",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter.schemas.enable": "false",
    "transforms": "flattenJson",
    "transforms.flattenJson.type": "org.apache.kafka.connect.transforms.Flatten$Value",
    "transforms.flattenJson.delimiter": "_",
    "primary.key.fields": "team_id,gizmo_id,author_user_id",
    "primary.key.mode": "record_value",
    "delete.enabled": "true"
  }
}'

echo "Creating ClickHouse Metrics sink connector..."
create_or_update_connector "clickhouse-metrics-sink" '{
  "name": "clickhouse-metrics-sink",
  "config": {
    "connector.class": "com.clickhouse.kafka.connect.ClickHouseSinkConnector",
    "tasks.max": "1",
    "topics": "metrics",
    "hostname": "'${CLICKHOUSE_HOST}'",
    "port": "'${CLICKHOUSE_PORT}'",
    "database": "'${CLICKHOUSE_DATABASE}'",
    "username": "'${CLICKHOUSE_USER}'",
    "password": "'${CLICKHOUSE_PASSWORD}'",
    "ssl": "false",
    "exactlyOnce": "false",
    "state.provider.class": "com.clickhouse.kafka.connect.sink.state.provider.FileStateProvider",
    "state.provider.working.dir": "/tmp/clickhouse-sink",
    "queue.max.wait.ms": "5000",
    "retry.max.count": "5",
    "errors.retry.timeout": "60",
    "errors.tolerance": "all",
    "errors.log.enable": "true",
    "errors.log.include.messages": "true",
    "table.name": "metrics",
    "key.converter": "org.apache.kafka.connect.storage.StringConverter",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter.schemas.enable": "false"
  }
}'

echo "Creating ClickHouse Traces Processed sink connector..."
create_or_update_connector "clickhouse-traces-processed-sink" '{
  "name": "clickhouse-traces-processed-sink",
  "config": {
    "connector.class": "com.clickhouse.kafka.connect.ClickHouseSinkConnector",
    "tasks.max": "1",
    "topics": "traces_processed",
    "hostname": "'${CLICKHOUSE_HOST}'",
    "port": "'${CLICKHOUSE_PORT}'",
    "database": "'${CLICKHOUSE_DATABASE}'",
    "username": "'${CLICKHOUSE_USER}'",
    "password": "'${CLICKHOUSE_PASSWORD}'",
    "ssl": "false",
    "exactlyOnce": "false",
    "state.provider.class": "com.clickhouse.kafka.connect.sink.state.provider.FileStateProvider",
    "state.provider.working.dir": "/tmp/clickhouse-sink",
    "queue.max.wait.ms": "5000",
    "retry.max.count": "5",
    "errors.retry.timeout": "60",
    "errors.tolerance": "all",
    "errors.log.enable": "true",
    "errors.log.include.messages": "true",
    "table.name": "traces_processed",
    "key.converter": "org.apache.kafka.connect.storage.StringConverter",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter.schemas.enable": "false",
    "transforms": "flattenJson",
    "transforms.flattenJson.type": "org.apache.kafka.connect.transforms.Flatten$Value",
    "transforms.flattenJson.delimiter": "_"
  }
}'

echo "Creating ClickHouse Traces sink connector..."
create_or_update_connector "clickhouse-traces-sink" '{
  "name": "clickhouse-traces-sink",
  "config": {
    "connector.class": "com.clickhouse.kafka.connect.ClickHouseSinkConnector",
    "tasks.max": "1",
    "topics": "traces",
    "hostname": "'${CLICKHOUSE_HOST}'",
    "port": "'${CLICKHOUSE_PORT}'",
    "database": "'${CLICKHOUSE_DATABASE}'",
    "username": "'${CLICKHOUSE_USER}'",
    "password": "'${CLICKHOUSE_PASSWORD}'",
    "ssl": "false",
    "exactlyOnce": "false",
    "state.provider.class": "com.clickhouse.kafka.connect.sink.state.provider.FileStateProvider",
    "state.provider.working.dir": "/tmp/clickhouse-sink",
    "queue.max.wait.ms": "5000",
    "retry.max.count": "5",
    "errors.retry.timeout": "60",
    "errors.tolerance": "all",
    "errors.log.enable": "true",
    "errors.log.include.messages": "true",
    "table.name": "traces",
    "key.converter": "org.apache.kafka.connect.storage.StringConverter",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter.schemas.enable": "false",
    "transforms": "flattenJson",
    "transforms.flattenJson.type": "org.apache.kafka.connect.transforms.Flatten$Value",
    "transforms.flattenJson.delimiter": "_"
  }
}'

echo ""
echo "=== Connector creation summary ==="
echo "Checking final connector status..."
FINAL_CONNECTORS=$(curl -s ${KAFKA_CONNECT_URL}/connectors 2>/dev/null || echo "[]")
echo "All connectors: ${FINAL_CONNECTORS}"

# Function to check if a connector exists (for summary verification)
connector_exists() {
  local connector_name=$1
  if curl -s -f ${KAFKA_CONNECT_URL}/connectors/${connector_name} > /dev/null 2>&1; then
    return 0  # Connector exists
  else
    return 1  # Connector does not exist
  fi
}

# Verify all expected connectors exist
EXPECTED_CONNECTORS="clickhouse-audit-logs-ingest-sink clickhouse-discover-events-sink clickhouse-gpt-usage-sink clickhouse-metrics-sink clickhouse-traces-processed-sink clickhouse-traces-sink"
MISSING_CONNECTORS=""

for connector in ${EXPECTED_CONNECTORS}; do
  if ! connector_exists "${connector}"; then
    MISSING_CONNECTORS="${MISSING_CONNECTORS} ${connector}"
  fi
done

if [ -n "${MISSING_CONNECTORS}" ]; then
  echo "WARNING: The following connectors are missing:${MISSING_CONNECTORS}"
  echo "This is not a fatal error - connectors can be created manually later."
  exit 0  # Don't fail the Helm install if connectors can't be created
else
  echo "✓ All expected connectors are present!"
  exit 0
fi
