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

# Function to check if a connector exists
connector_exists() {
  local connector_name=$1
  if curl -s -f ${KAFKA_CONNECT_URL}/connectors/${connector_name} > /dev/null 2>&1; then
    return 0  # Connector exists
  else
    return 1  # Connector does not exist
  fi
}

# Function to create or update a connector
create_or_update_connector() {
  local connector_name=$1
  local connector_config=$2
  
  if connector_exists "${connector_name}"; then
    echo "Connector '${connector_name}' already exists, skipping creation."
    return 0
  else
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
  fi
}

echo "Checking existing connectors..."
EXISTING_CONNECTORS=$(curl -s ${KAFKA_CONNECT_URL}/connectors 2>/dev/null || echo "[]")
echo "Existing connectors: ${EXISTING_CONNECTORS}"

echo "Creating ClickHouse traces_processed sink connector..."
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

echo "Creating ClickHouse metrics sink connector..."
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

echo "Creating ClickHouse traces sink connector..."
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

echo "Creating ClickHouse discover events sink connector..."
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

echo "Creating ClickHouse agents events sink connector..."
create_or_update_connector "clickhouse-agents-events-sink" '{
  "name": "clickhouse-agents-events-sink",
  "config": {
    "connector.class": "com.clickhouse.kafka.connect.ClickHouseSinkConnector",
    "tasks.max": "1",
    "topics": "agent_traces",
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
    "table.name": "agent_traces",
    "value.converter.schemas.enable": "false",
    "key.converter": "org.apache.kafka.connect.storage.StringConverter",
    "value.converter": "org.apache.kafka.connect.storage.StringConverter",
    "transforms": "hoist",
    "transforms.hoist.type": "org.apache.kafka.connect.transforms.HoistField$Value",
    "transforms.hoist.field": "raw_json"
  }
}'

echo "Creating ClickHouse gpt_usage sink connector..."
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

echo ""
echo "=== Connector creation summary ==="
echo "Checking final connector status..."
FINAL_CONNECTORS=$(curl -s ${KAFKA_CONNECT_URL}/connectors 2>/dev/null || echo "[]")
echo "All connectors: ${FINAL_CONNECTORS}"

# Verify all expected connectors exist
EXPECTED_CONNECTORS="clickhouse-traces-processed-sink clickhouse-metrics-sink clickhouse-traces-sink clickhouse-discover-events-sink clickhouse-agents-events-sink clickhouse-gpt-usage-sink"
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