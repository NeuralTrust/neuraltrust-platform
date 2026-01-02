#!/bin/bash
# Unified script to create all necessary Kubernetes secrets for NeuralTrust Platform deployment
# Supports environment variables and pre-defined secrets
# This should be run before deploying with Helm

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default namespace
NAMESPACE="${NAMESPACE:-neuraltrust}"

# Option to replace existing secrets (default: ask)
REPLACE_EXISTING="${REPLACE_EXISTING:-}"

# Function to check if secret should be replaced
should_replace_secret() {
    local secret_name=$1
    
    # If REPLACE_EXISTING is set, use it
    if [ -n "$REPLACE_EXISTING" ]; then
        if [ "$REPLACE_EXISTING" = "true" ] || [ "$REPLACE_EXISTING" = "yes" ] || [ "$REPLACE_EXISTING" = "y" ]; then
            return 0  # true
        else
            return 1  # false
        fi
    else
        # Ask user if not set
        echo -e "${YELLOW}Secret ${secret_name} already exists.${NC}"
        read -p "Do you want to replace it? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            return 0  # true
        else
            return 1  # false
        fi
    fi
}

# Function to trim whitespace from a value
trim_value() {
    local value="$1"
    # Remove leading/trailing whitespace and control characters
    echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '\n\r'
}

# Function to URL encode a string
# This function encodes special characters commonly found in passwords and connection strings
url_encode() {
    local string="$1"
    local encoded
    
    # Use sed to replace common special characters with their URL-encoded equivalents
    # This covers the most common cases for database passwords and connection strings
    encoded=$(printf '%s' "$string" | sed \
        -e 's/%/%25/g' \
        -e 's/ /%20/g' \
        -e 's/!/%21/g' \
        -e 's/#/%23/g' \
        -e 's/\$/%24/g' \
        -e 's/&/%26/g' \
        -e 's/'\''/%27/g' \
        -e 's/(/%28/g' \
        -e 's/)/%29/g' \
        -e 's/*/%2A/g' \
        -e 's/+/%2B/g' \
        -e 's/,/%2C/g' \
        -e 's/\//%2F/g' \
        -e 's/:/%3A/g' \
        -e 's/;/%3B/g' \
        -e 's/=/%3D/g' \
        -e 's/?/%3F/g' \
        -e 's/@/%40/g' \
        -e 's/\[/%5B/g' \
        -e 's/\\/%5C/g' \
        -e 's/\]/%5D/g' \
        -e 's/\^/%5E/g' \
        -e 's/`/%60/g' \
        -e 's/{/%7B/g' \
        -e 's/|/%7C/g' \
        -e 's/}/%7D/g' \
        -e 's/~/%7E/g')
    
    echo "$encoded"
}

# Function to create secret
create_secret() {
    local secret_name=$1
    local key=$2
    local value=$3
    local description=$4
    
    # Trim whitespace from value
    value=$(trim_value "$value")
    
    # Check if secret already exists BEFORE asking for value
    if kubectl get secret "$secret_name" -n "$NAMESPACE" &>/dev/null; then
        if ! should_replace_secret "$secret_name"; then
            echo -e "${GREEN}Skipping secret ${secret_name} (already exists)${NC}"
            return 0
        fi
        echo -e "${YELLOW}Replacing secret ${secret_name}...${NC}"
        kubectl delete secret "$secret_name" -n "$NAMESPACE" --ignore-not-found=true
    fi
    
    if [ -z "$value" ]; then
        echo -e "${YELLOW}Warning: ${description} is empty, skipping secret ${secret_name}${NC}"
        return 0
    fi
    
    echo -e "${GREEN}Creating secret: ${secret_name} (key: ${key})${NC}"
    
    # Create secret
    kubectl create secret generic "$secret_name" \
        --from-literal="$key=$value" \
        -n "$NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    echo -e "${GREEN}✓ Secret ${secret_name} created/updated${NC}"
}

# Function to prompt for secret value
prompt_secret() {
    local var_name=$1
    local description=$2
    local current_value="${!var_name}"
    
    if [ -n "$current_value" ]; then
        echo -e "${GREEN}Using ${var_name} from environment${NC}" >&2
        trim_value "$current_value"
    else
        read -sp "${description}: " value
        echo >&2
        trim_value "$value"
    fi
}

# Function to add or update a key in an existing secret without losing other keys
add_secret_key() {
    local secret_name=$1
    local key=$2
    local value=$3
    
    # Trim whitespace from value
    value=$(trim_value "$value")
    
    # Check if secret exists
    if kubectl get secret "$secret_name" -n "$NAMESPACE" &>/dev/null; then
        # Secret exists - read all existing keys, merge with new key, and recreate
        local temp_dir=$(mktemp -d)
        local kubectl_cmd=("kubectl" "create" "secret" "generic" "$secret_name" "-n" "$NAMESPACE")
        
        # Get all existing keys from the secret and add them to the kubectl command
        # Use kubectl to get each key-value pair directly
        local secret_json
        secret_json=$(kubectl get secret "$secret_name" -n "$NAMESPACE" -o json 2>/dev/null)
        
        if [ -n "$secret_json" ]; then
            # Extract keys from the data section
            local existing_keys=""
            if command -v jq &> /dev/null; then
                # Use jq if available for better JSON parsing
                existing_keys=$(echo "$secret_json" | jq -r '.data | keys[]' 2>/dev/null || echo "")
            else
                # Fallback: extract keys from JSON using sed/grep
                # Look for keys in the "data" section
                existing_keys=$(echo "$secret_json" | sed -n '/"data":/,/}/p' | grep -o '"[^"]*":' | sed 's/":$//; s/^"//' | grep -v '^data$' || echo "")
            fi
            
            # Add all existing keys (decoded) to the kubectl command
            if [ -n "$existing_keys" ]; then
                while IFS= read -r existing_key; do
                    if [ -n "$existing_key" ] && [ "$existing_key" != "$key" ]; then
                        # Get the existing value and decode it
                        local existing_value
                        existing_value=$(kubectl get secret "$secret_name" -n "$NAMESPACE" -o jsonpath="{.data.$existing_key}" 2>/dev/null)
                        if [ -n "$existing_value" ]; then
                            # Decode base64 value
                            existing_value=$(echo "$existing_value" | base64 -d 2>/dev/null || echo "$existing_value")
                            if [ -n "$existing_value" ]; then
                                kubectl_cmd+=("--from-literal=${existing_key}=${existing_value}")
                            fi
                        fi
                    fi
                done <<< "$existing_keys"
            fi
        fi
        
        # Add the new/updated key
        kubectl_cmd+=("--from-literal=${key}=${value}")
        kubectl_cmd+=("--dry-run=client" "-o" "yaml")
        
        # Execute kubectl command and apply
        "${kubectl_cmd[@]}" | kubectl apply -f - 2>/dev/null
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ Updated ${key} in ${secret_name}${NC}"
        else
            echo -e "${RED}Error: Failed to update secret ${secret_name}${NC}" >&2
            rm -rf "$temp_dir"
            return 1
        fi
        
        rm -rf "$temp_dir"
    else
        # Secret doesn't exist - create it with just this key
        kubectl create secret generic "$secret_name" \
            --from-literal="$key=$value" \
            -n "$NAMESPACE" \
            --dry-run=client -o yaml | kubectl apply -f -
    fi
}

echo "=========================================="
echo "NeuralTrust Platform Secrets Creation"
echo "=========================================="
echo ""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --replace-existing)
            REPLACE_EXISTING="true"
            shift
            ;;
        --no-replace-existing)
            REPLACE_EXISTING="false"
            shift
            ;;
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --replace-existing      Replace existing secrets without asking"
            echo "  --no-replace-existing   Skip existing secrets without asking"
            echo "  --namespace NAMESPACE   Use specified namespace (default: neuraltrust)"
            echo "  --help, -h              Show this help message"
            echo ""
            echo "Environment variables:"
            echo "  All secret values can be provided via environment variables:"
            echo "  - DATA_PLANE_JWT_SECRET"
            echo "  - CONTROL_PLANE_JWT_SECRET"
            echo "  - OPENAI_API_KEY"
            echo "  - GOOGLE_API_KEY"
            echo "  - RESEND_API_KEY"
            echo "  - HUGGINGFACE_TOKEN"
            echo "  - CLICKHOUSE_PASSWORD"
            echo "  - POSTGRES_PASSWORD"
            echo "  - REDIS_PASSWORD"
            echo "  - TRUSTGATE_JWT_SECRET"
            echo "  - FIREWALL_JWT_SECRET"
            echo "  - SERVER_SECRET_KEY (TrustGate)"
            echo "  - And more..."
            echo ""
            echo "  REPLACE_EXISTING        Set to 'true' or 'false' to control replacement"
            echo "  NAMESPACE               Set the namespace to use"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Check if namespace exists, create if not
if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
    echo -e "${YELLOW}Namespace ${NAMESPACE} does not exist. Creating...${NC}"
    kubectl create namespace "$NAMESPACE"
fi

echo -e "${GREEN}Using namespace: ${NAMESPACE}${NC}"
echo ""

# ============================================================================
# DATA PLANE SECRETS
# ============================================================================
echo -e "${BLUE}=== Data Plane Secrets ===${NC}"

# Data Plane JWT Secret
echo "--- Data Plane JWT Secret ---"
SECRET_NAME="data-plane-jwt-secret"
if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
    if should_replace_secret "$SECRET_NAME"; then
        DATA_PLANE_JWT_SECRET=$(prompt_secret "DATA_PLANE_JWT_SECRET" "Enter Data Plane JWT Secret")
        if [ -n "$DATA_PLANE_JWT_SECRET" ]; then
            create_secret "$SECRET_NAME" "DATA_PLANE_JWT_SECRET" "$DATA_PLANE_JWT_SECRET" "Data Plane JWT Secret"
        fi
    else
        echo -e "${GREEN}Skipping ${SECRET_NAME} (already exists)${NC}"
    fi
else
    DATA_PLANE_JWT_SECRET=$(prompt_secret "DATA_PLANE_JWT_SECRET" "Enter Data Plane JWT Secret")
    if [ -n "$DATA_PLANE_JWT_SECRET" ]; then
        create_secret "$SECRET_NAME" "DATA_PLANE_JWT_SECRET" "$DATA_PLANE_JWT_SECRET" "Data Plane JWT Secret"
    fi
fi
echo ""

# OpenAI API Key
echo "--- OpenAI API Key (Optional) ---"
SECRET_NAME="openai-secrets"
if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
    if should_replace_secret "$SECRET_NAME"; then
        OPENAI_API_KEY=$(prompt_secret "OPENAI_API_KEY" "Enter OpenAI API Key (optional)")
        if [ -n "$OPENAI_API_KEY" ]; then
            create_secret "$SECRET_NAME" "OPENAI_API_KEY" "$OPENAI_API_KEY" "OpenAI API Key"
        fi
    else
        echo -e "${GREEN}Skipping ${SECRET_NAME} (already exists)${NC}"
    fi
else
    OPENAI_API_KEY=$(prompt_secret "OPENAI_API_KEY" "Enter OpenAI API Key (optional)")
    if [ -n "$OPENAI_API_KEY" ]; then
        create_secret "$SECRET_NAME" "OPENAI_API_KEY" "$OPENAI_API_KEY" "OpenAI API Key"
    fi
fi
echo ""

# Google API Key
echo "--- Google API Key (Optional) ---"
SECRET_NAME="google-secrets"
if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
    if should_replace_secret "$SECRET_NAME"; then
        GOOGLE_API_KEY=$(prompt_secret "GOOGLE_API_KEY" "Enter Google API Key (optional)")
        if [ -n "$GOOGLE_API_KEY" ]; then
            create_secret "$SECRET_NAME" "GOOGLE_API_KEY" "$GOOGLE_API_KEY" "Google API Key"
        fi
    else
        echo -e "${GREEN}Skipping ${SECRET_NAME} (already exists)${NC}"
    fi
else
    GOOGLE_API_KEY=$(prompt_secret "GOOGLE_API_KEY" "Enter Google API Key (optional)")
    if [ -n "$GOOGLE_API_KEY" ]; then
        create_secret "$SECRET_NAME" "GOOGLE_API_KEY" "$GOOGLE_API_KEY" "Google API Key"
    fi
fi
echo ""

# Resend API Key
echo "--- Resend API Key (Optional) ---"
SECRET_NAME="resend-secrets"
if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
    if should_replace_secret "$SECRET_NAME"; then
        RESEND_API_KEY=$(prompt_secret "RESEND_API_KEY" "Enter Resend API Key (optional)")
        if [ -n "$RESEND_API_KEY" ]; then
            create_secret "$SECRET_NAME" "RESEND_API_KEY" "$RESEND_API_KEY" "Resend API Key"
        fi
    else
        echo -e "${GREEN}Skipping ${SECRET_NAME} (already exists)${NC}"
    fi
else
    RESEND_API_KEY=$(prompt_secret "RESEND_API_KEY" "Enter Resend API Key (optional)")
    if [ -n "$RESEND_API_KEY" ]; then
        create_secret "$SECRET_NAME" "RESEND_API_KEY" "$RESEND_API_KEY" "Resend API Key"
    fi
fi
echo ""

# Hugging Face Token
echo "--- Hugging Face Token (Optional) ---"
SECRET_NAME="huggingface-secrets"
if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
    if should_replace_secret "$SECRET_NAME"; then
        HUGGINGFACE_TOKEN=$(prompt_secret "HUGGINGFACE_TOKEN" "Enter Hugging Face Token (optional)")
        if [ -n "$HUGGINGFACE_TOKEN" ]; then
            create_secret "$SECRET_NAME" "HUGGINGFACE_TOKEN" "$HUGGINGFACE_TOKEN" "Hugging Face Token"
        fi
    else
        echo -e "${GREEN}Skipping ${SECRET_NAME} (already exists)${NC}"
    fi
else
    HUGGINGFACE_TOKEN=$(prompt_secret "HUGGINGFACE_TOKEN" "Enter Hugging Face Token (optional)")
    if [ -n "$HUGGINGFACE_TOKEN" ]; then
        create_secret "$SECRET_NAME" "HUGGINGFACE_TOKEN" "$HUGGINGFACE_TOKEN" "Hugging Face Token"
    fi
fi
echo ""

# ============================================================================
# CONTROL PLANE SECRETS
# ============================================================================
echo -e "${BLUE}=== Control Plane Secrets ===${NC}"

# Control Plane JWT Secret
echo "--- Control Plane JWT Secret (REQUIRED) ---"
SECRET_NAME="${RELEASE_NAME:-control-plane}-secrets"
if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
    EXISTING_JWT=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.CONTROL_PLANE_JWT_SECRET}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    if [ -z "$EXISTING_JWT" ] || should_replace_secret "$SECRET_NAME"; then
        CONTROL_PLANE_JWT_SECRET=$(prompt_secret "CONTROL_PLANE_JWT_SECRET" "Enter Control Plane JWT Secret")
        if [ -z "$CONTROL_PLANE_JWT_SECRET" ]; then
            echo -e "${RED}Error: CONTROL_PLANE_JWT_SECRET is required${NC}"
            exit 1
        fi
        add_secret_key "$SECRET_NAME" "CONTROL_PLANE_JWT_SECRET" "$CONTROL_PLANE_JWT_SECRET"
        echo -e "${GREEN}✓ Updated CONTROL_PLANE_JWT_SECRET${NC}"
    else
        echo -e "${GREEN}CONTROL_PLANE_JWT_SECRET already exists in ${SECRET_NAME}${NC}"
    fi
else
    CONTROL_PLANE_JWT_SECRET=$(prompt_secret "CONTROL_PLANE_JWT_SECRET" "Enter Control Plane JWT Secret")
    if [ -z "$CONTROL_PLANE_JWT_SECRET" ]; then
        echo -e "${RED}Error: CONTROL_PLANE_JWT_SECRET is required${NC}"
        exit 1
    fi
    create_secret "$SECRET_NAME" "CONTROL_PLANE_JWT_SECRET" "$CONTROL_PLANE_JWT_SECRET" "Control Plane JWT Secret"
fi
echo ""

# Resend Alert Sender
echo "--- Resend Alert Sender Email (Optional) ---"
RESEND_ALERT_SENDER=$(prompt_secret "RESEND_ALERT_SENDER" "Enter Resend Alert Sender Email (optional)")
RESEND_ALERT_SENDER=${RESEND_ALERT_SENDER:-""}
add_secret_key "$SECRET_NAME" "resend-alert-sender" "$RESEND_ALERT_SENDER"
echo ""

# Resend Invite Sender
echo "--- Resend Invite Sender Email (Optional) ---"
RESEND_INVITE_SENDER=$(prompt_secret "RESEND_INVITE_SENDER" "Enter Resend Invite Sender Email (optional)")
RESEND_INVITE_SENDER=${RESEND_INVITE_SENDER:-""}
add_secret_key "$SECRET_NAME" "resend-invite-sender" "$RESEND_INVITE_SENDER"
echo ""

# TrustGate JWT Secret
echo "--- TrustGate JWT Secret ---"
if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
    EXISTING_TRUSTGATE_JWT=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.TRUSTGATE_JWT_SECRET}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    if [ -n "$EXISTING_TRUSTGATE_JWT" ]; then
        # Key already exists - check if we should replace it
        if should_replace_secret "$SECRET_NAME"; then
            TRUSTGATE_JWT_SECRET=$(prompt_secret "TRUSTGATE_JWT_SECRET" "Enter TrustGate JWT Secret")
            if [ -n "$TRUSTGATE_JWT_SECRET" ]; then
                add_secret_key "$SECRET_NAME" "TRUSTGATE_JWT_SECRET" "$TRUSTGATE_JWT_SECRET"
                echo -e "${GREEN}✓ Updated TRUSTGATE_JWT_SECRET${NC}"
            fi
        else
            echo -e "${GREEN}TRUSTGATE_JWT_SECRET already exists in ${SECRET_NAME}${NC}"
        fi
    else
        # Key doesn't exist - prompt for it
        TRUSTGATE_JWT_SECRET=$(prompt_secret "TRUSTGATE_JWT_SECRET" "Enter TrustGate JWT Secret")
        if [ -n "$TRUSTGATE_JWT_SECRET" ]; then
            add_secret_key "$SECRET_NAME" "TRUSTGATE_JWT_SECRET" "$TRUSTGATE_JWT_SECRET"
            echo -e "${GREEN}✓ Added TRUSTGATE_JWT_SECRET${NC}"
        fi
    fi
else
    # Secret doesn't exist - prompt for it
    TRUSTGATE_JWT_SECRET=$(prompt_secret "TRUSTGATE_JWT_SECRET" "Enter TrustGate JWT Secret")
    if [ -n "$TRUSTGATE_JWT_SECRET" ]; then
        add_secret_key "$SECRET_NAME" "TRUSTGATE_JWT_SECRET" "$TRUSTGATE_JWT_SECRET"
    fi
fi
echo ""

# Firewall JWT Secret
echo "--- Firewall JWT Secret (Optional) ---"
FIREWALL_JWT_SECRET=$(prompt_secret "FIREWALL_JWT_SECRET" "Enter Firewall JWT Secret (optional)")
if [ -n "$FIREWALL_JWT_SECRET" ]; then
    add_secret_key "$SECRET_NAME" "FIREWALL_JWT_SECRET" "$FIREWALL_JWT_SECRET"
fi
echo ""

# Model Scanner Secret
echo "--- Model Scanner Secret (Optional) ---"
MODEL_SCANNER_SECRET=$(prompt_secret "MODEL_SCANNER_SECRET" "Enter Model Scanner Secret (optional)")
if [ -n "$MODEL_SCANNER_SECRET" ]; then
    add_secret_key "$SECRET_NAME" "MODEL_SCANNER_SECRET" "$MODEL_SCANNER_SECRET"
fi
echo ""

# ============================================================================
# INFRASTRUCTURE SECRETS
# ============================================================================
echo -e "${BLUE}=== Infrastructure Secrets ===${NC}"

# ClickHouse Password
echo "--- ClickHouse Password ---"
SECRET_NAME="clickhouse"
if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
    if should_replace_secret "$SECRET_NAME"; then
        CLICKHOUSE_PASSWORD=$(prompt_secret "CLICKHOUSE_PASSWORD" "Enter ClickHouse Password")
        if [ -z "$CLICKHOUSE_PASSWORD" ]; then
            CLICKHOUSE_PASSWORD=$(openssl rand -base64 32)
            echo -e "${YELLOW}No password provided, generated random password${NC}"
        fi
        create_secret "$SECRET_NAME" "admin-password" "$CLICKHOUSE_PASSWORD" "ClickHouse Admin Password"
    else
        echo -e "${GREEN}Skipping ${SECRET_NAME} (already exists)${NC}"
    fi
else
    CLICKHOUSE_PASSWORD=$(prompt_secret "CLICKHOUSE_PASSWORD" "Enter ClickHouse Password")
    if [ -z "$CLICKHOUSE_PASSWORD" ]; then
        CLICKHOUSE_PASSWORD=$(openssl rand -base64 32)
        echo -e "${YELLOW}No password provided, generated random password${NC}"
    fi
    create_secret "$SECRET_NAME" "admin-password" "$CLICKHOUSE_PASSWORD" "ClickHouse Admin Password"
fi
echo ""

# ClickHouse Connection Secrets (for data-plane components)
echo "--- ClickHouse Connection Configuration ---"
CLICKHOUSE_SECRETS_NAME="clickhouse-secrets"
CLICKHOUSE_HOST="${CLICKHOUSE_HOST:-clickhouse}"
CLICKHOUSE_PORT="${CLICKHOUSE_PORT:-8123}"
CLICKHOUSE_USER="${CLICKHOUSE_USER:-neuraltrust}"
CLICKHOUSE_DATABASE="${CLICKHOUSE_DATABASE:-neuraltrust}"

if kubectl get secret "$CLICKHOUSE_SECRETS_NAME" -n "$NAMESPACE" &>/dev/null; then
    if should_replace_secret "$CLICKHOUSE_SECRETS_NAME"; then
        CLICKHOUSE_HOST=$(prompt_secret "CLICKHOUSE_HOST" "Enter ClickHouse Host (default: clickhouse)")
        CLICKHOUSE_HOST=${CLICKHOUSE_HOST:-clickhouse}
        CLICKHOUSE_PORT=$(prompt_secret "CLICKHOUSE_PORT" "Enter ClickHouse Port (default: 8123)")
        CLICKHOUSE_PORT=${CLICKHOUSE_PORT:-8123}
        CLICKHOUSE_USER=$(prompt_secret "CLICKHOUSE_USER" "Enter ClickHouse User (default: neuraltrust)")
        CLICKHOUSE_USER=${CLICKHOUSE_USER:-neuraltrust}
        CLICKHOUSE_DATABASE=$(prompt_secret "CLICKHOUSE_DATABASE" "Enter ClickHouse Database (default: neuraltrust)")
        CLICKHOUSE_DATABASE=${CLICKHOUSE_DATABASE:-neuraltrust}
        
        echo -e "${GREEN}Creating/updating ClickHouse connection secret${NC}"
        kubectl create secret generic "$CLICKHOUSE_SECRETS_NAME" \
            --from-literal=CLICKHOUSE_HOST="$(trim_value "$CLICKHOUSE_HOST")" \
            --from-literal=CLICKHOUSE_PORT="$(trim_value "$CLICKHOUSE_PORT")" \
            --from-literal=CLICKHOUSE_USER="$(trim_value "$CLICKHOUSE_USER")" \
            --from-literal=CLICKHOUSE_DATABASE="$(trim_value "$CLICKHOUSE_DATABASE")" \
            -n "$NAMESPACE" \
            --dry-run=client -o yaml | kubectl apply -f -
        echo -e "${GREEN}✓ ClickHouse connection secret created/updated${NC}"
    else
        echo -e "${GREEN}Skipping ${CLICKHOUSE_SECRETS_NAME} (already exists)${NC}"
    fi
else
    CLICKHOUSE_HOST=$(prompt_secret "CLICKHOUSE_HOST" "Enter ClickHouse Host (default: clickhouse)")
    CLICKHOUSE_HOST=${CLICKHOUSE_HOST:-clickhouse}
    CLICKHOUSE_PORT=$(prompt_secret "CLICKHOUSE_PORT" "Enter ClickHouse Port (default: 8123)")
    CLICKHOUSE_PORT=${CLICKHOUSE_PORT:-8123}
    CLICKHOUSE_USER=$(prompt_secret "CLICKHOUSE_USER" "Enter ClickHouse User (default: neuraltrust)")
    CLICKHOUSE_USER=${CLICKHOUSE_USER:-neuraltrust}
    CLICKHOUSE_DATABASE=$(prompt_secret "CLICKHOUSE_DATABASE" "Enter ClickHouse Database (default: neuraltrust)")
    CLICKHOUSE_DATABASE=${CLICKHOUSE_DATABASE:-neuraltrust}
    
    echo -e "${GREEN}Creating ClickHouse connection secret${NC}"
    kubectl create secret generic "$CLICKHOUSE_SECRETS_NAME" \
        --from-literal=CLICKHOUSE_HOST="$(trim_value "$CLICKHOUSE_HOST")" \
        --from-literal=CLICKHOUSE_PORT="$(trim_value "$CLICKHOUSE_PORT")" \
        --from-literal=CLICKHOUSE_USER="$(trim_value "$CLICKHOUSE_USER")" \
        --from-literal=CLICKHOUSE_DATABASE="$(trim_value "$CLICKHOUSE_DATABASE")" \
        -n "$NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f -
    echo -e "${GREEN}✓ ClickHouse connection secret created${NC}"
fi
echo ""

# PostgreSQL Connection
echo "--- PostgreSQL Connection Configuration ---"
POSTGRES_SECRET_NAME="postgresql-secrets"

if kubectl get secret "$POSTGRES_SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
    EXISTING_DATABASE_URL=$(kubectl get secret "$POSTGRES_SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.DATABASE_URL}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    if [ -z "$EXISTING_DATABASE_URL" ] || should_replace_secret "$POSTGRES_SECRET_NAME"; then
        if should_replace_secret "$POSTGRES_SECRET_NAME"; then
            kubectl delete secret "$POSTGRES_SECRET_NAME" -n "$NAMESPACE" --ignore-not-found=true
        else
            echo -e "${GREEN}Skipping PostgreSQL secrets (already exists)${NC}"
            echo ""
            POSTGRES_SECRET_NAME=""
        fi
    else
        echo -e "${GREEN}PostgreSQL connection secret already exists${NC}"
        POSTGRES_SECRET_NAME=""
    fi
fi

if [ -n "$POSTGRES_SECRET_NAME" ]; then
    # Check for existing POSTGRES_HOST in the secret
    EXISTING_POSTGRES_HOST=$(kubectl get secret "$POSTGRES_SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.POSTGRES_HOST}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    if [ -n "$EXISTING_POSTGRES_HOST" ]; then
        HOST_PROMPT="Enter PostgreSQL Host (current: $EXISTING_POSTGRES_HOST, default: control-plane-postgresql)"
    else
        HOST_PROMPT="Enter PostgreSQL Host (default: control-plane-postgresql)"
    fi
    POSTGRES_HOST=$(prompt_secret "POSTGRES_HOST" "$HOST_PROMPT")
    POSTGRES_HOST=${POSTGRES_HOST:-${EXISTING_POSTGRES_HOST:-control-plane-postgresql}}
    POSTGRES_PORT=$(prompt_secret "POSTGRES_PORT" "Enter PostgreSQL Port (default: 5432)")
    POSTGRES_PORT=${POSTGRES_PORT:-5432}
    POSTGRES_USER=$(prompt_secret "POSTGRES_USER" "Enter PostgreSQL User (default: neuraltrust)")
    POSTGRES_USER=${POSTGRES_USER:-neuraltrust}
    POSTGRES_PASSWORD=$(prompt_secret "POSTGRES_PASSWORD" "Enter NeuralTrust Password")
    POSTGRES_DB=$(prompt_secret "POSTGRES_DB" "Enter PostgreSQL Database Name (default: neuraltrust)")
    POSTGRES_DB=${POSTGRES_DB:-neuraltrust}
    
    # Trim all values to remove newlines and whitespace
    POSTGRES_HOST=$(trim_value "$POSTGRES_HOST")
    POSTGRES_PORT=$(trim_value "$POSTGRES_PORT")
    POSTGRES_USER=$(trim_value "$POSTGRES_USER")
    POSTGRES_PASSWORD=$(trim_value "$POSTGRES_PASSWORD")
    POSTGRES_DB=$(trim_value "$POSTGRES_DB")
    
    if [ -z "$POSTGRES_PASSWORD" ]; then
        echo -e "${YELLOW}Warning: PostgreSQL password is empty${NC}"
    fi
    
    if [ -z "$POSTGRES_HOST" ]; then
        echo -e "${RED}Error: PostgreSQL host is required${NC}"
        exit 1
    fi
    
    # Create DATABASE_URL (values are already trimmed)
    POSTGRES_PASSWORD_ENCODED=$(url_encode "$POSTGRES_PASSWORD")
    DATABASE_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD_ENCODED}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}?connection_limit=15"
    POSTGRES_PRISMA_URL="$DATABASE_URL"
    
    echo -e "${GREEN}Creating PostgreSQL connection secret${NC}"
    # Values are already trimmed, but trim again for safety and ensure DATABASE_URL has no newlines
    DATABASE_URL=$(printf '%s' "$DATABASE_URL" | tr -d '\n\r')
    POSTGRES_PRISMA_URL=$(printf '%s' "$POSTGRES_PRISMA_URL" | tr -d '\n\r')
    kubectl create secret generic "$POSTGRES_SECRET_NAME" \
        --from-literal=POSTGRES_HOST="$POSTGRES_HOST" \
        --from-literal=POSTGRES_PORT="$POSTGRES_PORT" \
        --from-literal=POSTGRES_USER="$POSTGRES_USER" \
        --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
        --from-literal=POSTGRES_DB="$POSTGRES_DB" \
        --from-literal=DATABASE_URL="$DATABASE_URL" \
        --from-literal=POSTGRES_PRISMA_URL="$POSTGRES_PRISMA_URL" \
        -n "$NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    echo -e "${GREEN}✓ PostgreSQL connection secret created${NC}"
fi
echo ""

# ============================================================================
# TRUSTGATE SECRETS
# ============================================================================
echo -e "${BLUE}=== TrustGate Secrets ===${NC}"

# TrustGate Server Secret Key
echo "--- TrustGate Server Secret Key ---"
TRUSTGATE_SECRET_NAME="trustgate-secrets"
if kubectl get secret "$TRUSTGATE_SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
    EXISTING_SERVER_SECRET_KEY=$(kubectl get secret "$TRUSTGATE_SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.SERVER_SECRET_KEY}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    if [ -n "$EXISTING_SERVER_SECRET_KEY" ]; then
        # Key already exists - check if we should replace it
        if should_replace_secret "$TRUSTGATE_SECRET_NAME"; then
            SERVER_SECRET_KEY=$(prompt_secret "SERVER_SECRET_KEY" "Enter TrustGate Server Secret Key")
            if [ -n "$SERVER_SECRET_KEY" ]; then
                add_secret_key "$TRUSTGATE_SECRET_NAME" "SERVER_SECRET_KEY" "$SERVER_SECRET_KEY"
                echo -e "${GREEN}✓ Updated SERVER_SECRET_KEY${NC}"
            fi
        else
            echo -e "${GREEN}SERVER_SECRET_KEY already exists in ${TRUSTGATE_SECRET_NAME}${NC}"
        fi
    else
        # Key doesn't exist - prompt for it
        SERVER_SECRET_KEY=$(prompt_secret "SERVER_SECRET_KEY" "Enter TrustGate Server Secret Key")
        if [ -n "$SERVER_SECRET_KEY" ]; then
            add_secret_key "$TRUSTGATE_SECRET_NAME" "SERVER_SECRET_KEY" "$SERVER_SECRET_KEY"
            echo -e "${GREEN}✓ Added SERVER_SECRET_KEY${NC}"
        fi
    fi
else
    # Secret doesn't exist - prompt for it
    SERVER_SECRET_KEY=$(prompt_secret "SERVER_SECRET_KEY" "Enter TrustGate Server Secret Key")
    if [ -n "$SERVER_SECRET_KEY" ]; then
        create_secret "$TRUSTGATE_SECRET_NAME" "SERVER_SECRET_KEY" "$SERVER_SECRET_KEY" "TrustGate Server Secret Key"
    fi
fi
echo ""

# Redis Password (for TrustGate - stored in trustgate-secrets)
echo "--- Redis Password for TrustGate (Optional) ---"
REDIS_PASSWORD=$(prompt_secret "REDIS_PASSWORD" "Enter Redis Password (optional)")
if [ -z "$REDIS_PASSWORD" ]; then
    REDIS_PASSWORD=$(openssl rand -base64 32)
    echo -e "${YELLOW}No password provided, generated random password${NC}"
fi
if [ -n "$REDIS_PASSWORD" ]; then
    if kubectl get secret "$TRUSTGATE_SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
        add_secret_key "$TRUSTGATE_SECRET_NAME" "redis-password" "$REDIS_PASSWORD"
        echo -e "${GREEN}✓ Added redis-password to ${TRUSTGATE_SECRET_NAME}${NC}"
    else
        # Create trustgate-secrets if it doesn't exist
        create_secret "$TRUSTGATE_SECRET_NAME" "redis-password" "$REDIS_PASSWORD" "Redis Password"
    fi
fi
echo ""

# PostgreSQL Connection (for TrustGate - stored in trustgate-secrets)
# Note: TrustGate uses a separate database from the control-plane
echo "--- PostgreSQL Connection for TrustGate (Separate Database) ---"
echo -e "${YELLOW}Note: TrustGate requires its own PostgreSQL database, user, and credentials${NC}"
echo ""

# Check if database connection info already exists in trustgate-secrets
EXISTING_DB_HOST=""
EXISTING_DB_PORT=""
EXISTING_DB_USER=""
EXISTING_DB_PASSWORD=""
EXISTING_DB_NAME=""
SHOULD_REPLACE_DB=false

if kubectl get secret "$TRUSTGATE_SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
    EXISTING_DB_HOST=$(kubectl get secret "$TRUSTGATE_SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.DATABASE_HOST}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    if [ -n "$EXISTING_DB_HOST" ]; then
        EXISTING_DB_PORT=$(kubectl get secret "$TRUSTGATE_SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.DATABASE_PORT}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
        EXISTING_DB_USER=$(kubectl get secret "$TRUSTGATE_SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.DATABASE_USER}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
        EXISTING_DB_PASSWORD=$(kubectl get secret "$TRUSTGATE_SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.DATABASE_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
        EXISTING_DB_NAME=$(kubectl get secret "$TRUSTGATE_SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.DATABASE_NAME}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
        
        echo -e "${GREEN}Existing PostgreSQL connection found in ${TRUSTGATE_SECRET_NAME}:${NC}"
        echo -e "  Host: ${EXISTING_DB_HOST}"
        echo -e "  Port: ${EXISTING_DB_PORT}"
        echo -e "  User: ${EXISTING_DB_USER}"
        echo -e "  Database: ${EXISTING_DB_NAME}"
        echo ""
        if should_replace_secret "${TRUSTGATE_SECRET_NAME}-database-connection"; then
            SHOULD_REPLACE_DB=true
        else
            echo -e "${GREEN}Keeping existing PostgreSQL connection in ${TRUSTGATE_SECRET_NAME}${NC}"
            echo ""
            # Use existing values
            DATABASE_HOST="$EXISTING_DB_HOST"
            DATABASE_PORT="$EXISTING_DB_PORT"
            DATABASE_USER="$EXISTING_DB_USER"
            DATABASE_PASSWORD="$EXISTING_DB_PASSWORD"
            DATABASE_NAME="$EXISTING_DB_NAME"
        fi
    fi
fi

# Only prompt if we need to replace or if values don't exist
if [ "$SHOULD_REPLACE_DB" = true ] || [ -z "$EXISTING_DB_HOST" ]; then
    # Build prompt messages with defaults
    if [ -n "$EXISTING_DB_HOST" ]; then
        HOST_PROMPT="Enter Database Host for TrustGate (current: $EXISTING_DB_HOST, default: control-plane-postgresql)"
    else
        HOST_PROMPT="Enter Database Host for TrustGate (default: control-plane-postgresql)"
    fi
    DATABASE_HOST=$(prompt_secret "TRUSTGATE_DATABASE_HOST" "$HOST_PROMPT")
    DATABASE_HOST=${DATABASE_HOST:-${EXISTING_DB_HOST:-control-plane-postgresql}}
    if [ -z "$DATABASE_HOST" ]; then
        echo -e "${RED}Error: Database host is required for TrustGate${NC}"
        exit 1
    fi

    if [ -n "$EXISTING_DB_PORT" ]; then
        PORT_PROMPT="Enter Database Port for TrustGate (current: $EXISTING_DB_PORT, default: 5432)"
    else
        PORT_PROMPT="Enter Database Port for TrustGate (default: 5432)"
    fi
    DATABASE_PORT=$(prompt_secret "TRUSTGATE_DATABASE_PORT" "$PORT_PROMPT")
    DATABASE_PORT=${DATABASE_PORT:-${EXISTING_DB_PORT:-5432}}

    if [ -n "$EXISTING_DB_USER" ]; then
        USER_PROMPT="Enter Database User for TrustGate (current: $EXISTING_DB_USER, default: trustgate)"
    else
        USER_PROMPT="Enter Database User for TrustGate (default: trustgate)"
    fi
    DATABASE_USER=$(prompt_secret "TRUSTGATE_DATABASE_USER" "$USER_PROMPT")
    DATABASE_USER=${DATABASE_USER:-${EXISTING_DB_USER:-trustgate}}

    if [ -n "$EXISTING_DB_PASSWORD" ]; then
        PASSWORD_PROMPT="Enter Database Password for TrustGate (press Enter to keep existing)"
    else
        PASSWORD_PROMPT="Enter Database Password for TrustGate (required)"
    fi
    DATABASE_PASSWORD=$(prompt_secret "TRUSTGATE_DATABASE_PASSWORD" "$PASSWORD_PROMPT")
    if [ -z "$DATABASE_PASSWORD" ] && [ -z "$EXISTING_DB_PASSWORD" ]; then
        echo -e "${RED}Error: Database password is required for TrustGate${NC}"
        exit 1
    fi
    DATABASE_PASSWORD=${DATABASE_PASSWORD:-$EXISTING_DB_PASSWORD}

    if [ -n "$EXISTING_DB_NAME" ]; then
        NAME_PROMPT="Enter Database Name for TrustGate (current: $EXISTING_DB_NAME, default: trustgate)"
    else
        NAME_PROMPT="Enter Database Name for TrustGate (default: trustgate)"
    fi
    DATABASE_NAME=$(prompt_secret "TRUSTGATE_DATABASE_NAME" "$NAME_PROMPT")
    DATABASE_NAME=${DATABASE_NAME:-${EXISTING_DB_NAME:-trustgate}}
fi

# Only update/create if we have values to set AND (we're replacing OR values don't exist)
# Skip update if user chose to keep existing values
if [ -n "$DATABASE_HOST" ] && [ -n "$DATABASE_PASSWORD" ] && ([ "$SHOULD_REPLACE_DB" = true ] || [ -z "$EXISTING_DB_HOST" ]); then
    # Trim all values to remove newlines and whitespace
    DATABASE_HOST=$(trim_value "$DATABASE_HOST")
    DATABASE_PORT=$(trim_value "$DATABASE_PORT")
    DATABASE_USER=$(trim_value "$DATABASE_USER")
    DATABASE_PASSWORD=$(trim_value "$DATABASE_PASSWORD")
    DATABASE_NAME=$(trim_value "$DATABASE_NAME")
    
    # Create PostgreSQL connection string (values are already trimmed)
    DATABASE_PASSWORD_ENCODED=$(url_encode "$DATABASE_PASSWORD")
    DATABASE_URL="postgresql://${DATABASE_USER}:${DATABASE_PASSWORD_ENCODED}@${DATABASE_HOST}:${DATABASE_PORT}/${DATABASE_NAME}?connection_limit=15"
    # Remove any newlines from DATABASE_URL
    DATABASE_URL=$(printf '%s' "$DATABASE_URL" | tr -d '\n\r')
    
    # Add to trustgate-secrets (values are already trimmed)
    if kubectl get secret "$TRUSTGATE_SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
        add_secret_key "$TRUSTGATE_SECRET_NAME" "DATABASE_HOST" "$DATABASE_HOST"
        add_secret_key "$TRUSTGATE_SECRET_NAME" "DATABASE_PORT" "$DATABASE_PORT"
        add_secret_key "$TRUSTGATE_SECRET_NAME" "DATABASE_USER" "$DATABASE_USER"
        add_secret_key "$TRUSTGATE_SECRET_NAME" "DATABASE_PASSWORD" "$DATABASE_PASSWORD"
        add_secret_key "$TRUSTGATE_SECRET_NAME" "DATABASE_NAME" "$DATABASE_NAME"
        add_secret_key "$TRUSTGATE_SECRET_NAME" "DATABASE_URL" "$DATABASE_URL"
        if [ "$SHOULD_REPLACE_DB" = true ]; then
            echo -e "${GREEN}✓ Updated PostgreSQL connection info in ${TRUSTGATE_SECRET_NAME}${NC}"
        else
            echo -e "${GREEN}✓ Verified PostgreSQL connection info in ${TRUSTGATE_SECRET_NAME}${NC}"
        fi
    else
        # Create trustgate-secrets with PostgreSQL connection info (values are already trimmed)
        kubectl create secret generic "$TRUSTGATE_SECRET_NAME" \
            --from-literal=DATABASE_HOST="$DATABASE_HOST" \
            --from-literal=DATABASE_PORT="$DATABASE_PORT" \
            --from-literal=DATABASE_USER="$DATABASE_USER" \
            --from-literal=DATABASE_PASSWORD="$DATABASE_PASSWORD" \
            --from-literal=DATABASE_NAME="$DATABASE_NAME" \
            --from-literal=DATABASE_URL="$DATABASE_URL" \
            -n "$NAMESPACE" \
            --dry-run=client -o yaml | kubectl apply -f -
        echo -e "${GREEN}✓ Created ${TRUSTGATE_SECRET_NAME} with PostgreSQL connection info${NC}"
    fi
elif [ -n "$EXISTING_DB_HOST" ] && [ "$SHOULD_REPLACE_DB" != true ]; then
    # User chose to keep existing values - no update needed
    echo -e "${GREEN}Skipping update - keeping existing PostgreSQL connection in ${TRUSTGATE_SECRET_NAME}${NC}"
fi
echo ""

# Hugging Face API Key for Firewall
echo "--- Hugging Face API Key for Firewall (Optional) ---"
HF_API_KEY=$(prompt_secret "HF_API_KEY" "Enter Hugging Face API Key for Firewall (optional)")
if [ -n "$HF_API_KEY" ]; then
    HF_SECRET_NAME="hf-api-key"
    if kubectl get secret "$HF_SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
        if should_replace_secret "$HF_SECRET_NAME"; then
            create_secret "$HF_SECRET_NAME" "HUGGINGFACE_TOKEN" "$HF_API_KEY" "Hugging Face API Key"
        else
            echo -e "${GREEN}Skipping ${HF_SECRET_NAME} (already exists)${NC}"
        fi
    else
        create_secret "$HF_SECRET_NAME" "HUGGINGFACE_TOKEN" "$HF_API_KEY" "Hugging Face API Key"
    fi
fi
echo ""

# ============================================================================
# DOCKER REGISTRY SECRET
# ============================================================================
echo -e "${BLUE}=== Docker Registry Secret ===${NC}"
if kubectl get secret gcr-secret -n "$NAMESPACE" &>/dev/null; then
    echo -e "${GREEN}GCR secret already exists${NC}"
else
    echo -e "${YELLOW}GCR secret not found.${NC}"
    echo "To create it, run:"
    echo "  kubectl create secret docker-registry gcr-secret \\"
    echo "    --docker-server=europe-west1-docker.pkg.dev \\"
    echo "    --docker-username=_json_key \\"
    echo "    --docker-password=\"\$(cat path/to/gcr-keys.json)\" \\"
    echo "    --docker-email=admin@neuraltrust.ai \\"
    echo "    -n ${NAMESPACE}"
    echo ""
    read -p "Do you want to create it now? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        read -p "Enter path to GCR keys JSON file: " gcr_key_path
        gcr_key_path=$(trim_value "$gcr_key_path")
        if [ -f "$gcr_key_path" ]; then
            gcr_key_content=$(cat "$gcr_key_path" | tr -d '\n\r')
            kubectl create secret docker-registry gcr-secret \
                --docker-server=europe-west1-docker.pkg.dev \
                --docker-username=_json_key \
                --docker-password="$gcr_key_content" \
                --docker-email=admin@neuraltrust.ai \
                -n "$NAMESPACE" \
                --dry-run=client -o yaml | kubectl apply -f -
            echo -e "${GREEN}✓ GCR secret created${NC}"
        else
            echo -e "${RED}Error: File not found: $gcr_key_path${NC}"
        fi
    fi
fi
echo ""

# ============================================================================
# SUMMARY
# ============================================================================
echo "=========================================="
echo -e "${GREEN}All secrets created successfully!${NC}"
echo "=========================================="
echo ""
echo "You can now deploy using Helm:"
echo "  helm dependency update"
echo "  helm upgrade --install neuraltrust-platform . \\"
echo "    --namespace ${NAMESPACE} \\"
echo "    -f values.yaml"
echo ""
echo "The Helm chart will automatically reference these pre-created secrets."

