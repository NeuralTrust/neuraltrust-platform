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
    # Pass "raw" as the fourth argument to store the value byte-exact. trim_value
    # ends in `tr -d '\n\r'`, which collapses a PEM into one line that no PEM
    # parser accepts — the Secret looks right and the consumer fails at runtime.
    local mode=${4:-trim}

    if [ "$mode" != "raw" ]; then
        # Trim whitespace from value
        value=$(trim_value "$value")
    fi
    
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

# Ensure a stable generated key exists without printing its value. An explicit
# environment variable wins; otherwise an existing key is preserved, then a new
# random value is generated.
ensure_generated_secret_key() {
    local secret_name=$1
    local key=$2
    local env_name=$3
    local value="${!env_name:-}"

    if [ -z "$value" ]; then
        value=$(kubectl get secret "$secret_name" -n "$NAMESPACE" \
            -o "jsonpath={.data.${key}}" 2>/dev/null | base64 -d 2>/dev/null || true)
    fi
    if [ -z "$value" ]; then
        value=$(openssl rand -base64 48 | tr -d '\n\r')
    fi
    add_secret_key "$secret_name" "$key" "$value"
}

# Ensure the config-sync last-known-good cache key exists in the Secret the data
# planes actually read. The chart generates this key only while it owns the
# service Secret (autoGenerateSecrets=true and preserveExistingSecrets=false).
# On the pre-provisioned path this script exists to serve, the chart owns no
# Secret and instead emits a secretKeyRef into configSync.existingSecret, so the
# key has to be there or TrustGate/TrustGuard refuse to start (AUT-393).
#
# The value must be base64 decoding to exactly 32 bytes: the runtimes use it
# directly as an AES-256-GCM key, which is what the chart's randBytes 32 yields.
ensure_config_sync_lkg_key() {
    local secret_name=$1
    local key=$2
    local env_name=$3
    local value="${!env_name:-}"
    local source="$env_name"

    if [ -z "$value" ]; then
        value="${CONFIG_SYNC_LKG_KEY:-}"
        source="CONFIG_SYNC_LKG_KEY"
    fi
    if [ -z "$value" ]; then
        value=$(read_secret_key_value "$secret_name" "$key")
        source="existing ${secret_name}/${key}"
    fi
    if [ -z "$value" ]; then
        value=$(openssl rand -base64 32 | tr -d '\n\r')
        source="generated"
    fi

    local decoded_bytes
    decoded_bytes=$(printf '%s' "$value" | base64 -d 2>/dev/null | wc -c | tr -d '[:space:]')
    if [ "${decoded_bytes:-0}" != "32" ]; then
        echo -e "${RED}Error: ${key} for ${secret_name} must be base64 that decodes to exactly 32 bytes (AES-256-GCM), but ${source} decodes to ${decoded_bytes:-0}.${NC}" >&2
        echo -e "${RED}Generate one with: openssl rand -base64 32${NC}" >&2
        exit 1
    fi

    add_secret_key "$secret_name" "$key" "$value"
}

# Ensure AgentGateway's MCP STS signer receives an RSA private key. The runtime
# accepts PEM or base64-wrapped PEM; storing the wrapped form keeps the Secret
# value single-line and avoids shell/YAML newline corruption.
ensure_rsa_private_key_secret_key() {
    local secret_name=$1
    local key=$2
    local env_name=$3
    local value="${!env_name:-}"
    local explicit=false
    local pem=""

    if [ -n "$value" ]; then
        explicit=true
    else
        value=$(kubectl get secret "$secret_name" -n "$NAMESPACE" \
            -o "jsonpath={.data.${key}}" 2>/dev/null | base64 -d 2>/dev/null || true)
    fi

    if [ -n "$value" ]; then
        if [[ "$value" == *"-----BEGIN"* ]]; then
            pem="${value//\\n/$'\n'}"
        else
            pem=$(printf '%s' "$value" | base64 -d 2>/dev/null || true)
        fi
    fi

    if [ -n "$pem" ] && printf '%s' "$pem" | openssl rsa -noout -check >/dev/null 2>&1; then
        local pkcs1=""
        pkcs1=$(printf '%s' "$pem" | openssl rsa -traditional 2>/dev/null || true)
        if [[ "$pkcs1" != *"-----BEGIN RSA PRIVATE KEY-----"* ]]; then
            pkcs1=$(printf '%s' "$pem" | openssl rsa 2>/dev/null || true)
        fi
        if [[ "$pkcs1" != *"-----BEGIN RSA PRIVATE KEY-----"* ]]; then
            echo -e "${RED}Error: unable to normalize ${env_name} to RSA PKCS#1 PEM${NC}" >&2
            return 1
        fi
        pem="$pkcs1"
        value=$(printf '%s' "$pem" | base64 | tr -d '\n\r')
    elif [ "$explicit" = true ]; then
        echo -e "${RED}Error: ${env_name} must contain an RSA private key in PEM or base64-encoded PEM format${NC}" >&2
        return 1
    else
        if [ -n "$value" ]; then
            echo -e "${YELLOW}Replacing invalid ${key} in ${secret_name} with an RSA private key${NC}"
        fi
        pem=$(openssl genrsa -traditional 2048 2>/dev/null || openssl genrsa 2048 2>/dev/null)
        value=$(printf '%s' "$pem" | base64 | tr -d '\n\r')
    fi

    add_secret_key "$secret_name" "$key" "$value"
}

# Canonical logical keys from neuraltrust-platform.platformSecret.registry.
# scripts/test-helm-render.sh asserts this list cannot drift from the helper.
# PLATFORM_SECRET_REGISTRY_KEYS_BEGIN
PLATFORM_SECRET_REGISTRY_KEYS=(
    SERVER_SECRET_KEY
    ADMIN_JWT_SECRET
    TRUSTGUARD_TOKEN_SIGNING_SECRET
    REDIS_EVENTS_SECRET
    AUTH_JWT_HS256_SECRET
    AUTH_JWT_SECRET
    APP_ENCRYPTION_KEY
    TRUSTLENS_JWT_SECRET
    ENCRYPTION_KEYSET
    JWT_SECRET
    DATA_PLANE_JWT_SECRET
    CONTROL_PLANE_JWT_SECRET
    AUTH_SECRET
    NEXTAUTH_SECRET
    MODEL_SCANNER_SECRET
    MCP_OAUTH_CLIENT_SECRET
    MCP_OAUTH_SIGNING_KEY
    AUTH_SECRET_KEY
    ENROLMENT_INTROSPECTION_TOKEN
    DATACORE_SERVICE_TOKEN
    ENROLMENT_SIGNING_SECRET
    TELEMETRY_JWT_PRIVATE_KEY_PEM
)
# PLATFORM_SECRET_REGISTRY_KEYS_END

PLATFORM_SECRET_NAME="platform-secrets"
PLATFORM_SHAPES=()

shape_enabled() {
    local want=$1
    local s
    for s in "${PLATFORM_SHAPES[@]+"${PLATFORM_SHAPES[@]}"}"; do
        if [ "$s" = "$want" ]; then
            return 0
        fi
    done
    return 1
}

requires_any_shape() {
    local requires=$1
    local shape
    for shape in $requires; do
        if shape_enabled "$shape"; then
            return 0
        fi
    done
    return 1
}

read_secret_key_value() {
    local secret_name=$1
    local key=$2
    kubectl get secret "$secret_name" -n "$NAMESPACE" \
        -o "jsonpath={.data.${key}}" 2>/dev/null | base64 -d 2>/dev/null || true
}

# Write one registry key into platform-secrets. generate: adopt keys are only
# written when an env/legacy value exists (never invented). aliasOf keys mirror
# their target. MCP_OAUTH_SIGNING_KEY stays adopt-only — the chart's hook Job
# owns generation (AUT-393 out of scope).
ensure_platform_secret_key() {
    local key=$1
    local legacy_name=$2
    local legacy_key=$3
    local generate=$4
    local env_name=$5
    local requires=$6
    local alias_of=${7:-}

    if ! requires_any_shape "$requires"; then
        return 0
    fi

    local value=""
    if [ -n "$env_name" ]; then
        value="${!env_name:-}"
    fi
    if [ -z "$value" ]; then
        value=$(read_secret_key_value "$PLATFORM_SECRET_NAME" "$key")
    fi
    if [ -z "$value" ] && [ -n "$alias_of" ]; then
        value=$(read_secret_key_value "$PLATFORM_SECRET_NAME" "$alias_of")
    fi
    if [ -z "$value" ] && [ -n "$legacy_name" ]; then
        value=$(read_secret_key_value "$legacy_name" "$legacy_key")
    fi
    if [ -z "$value" ] && [ -n "$alias_of" ] && [ -n "$legacy_name" ]; then
        value=$(read_secret_key_value "$legacy_name" "$alias_of")
    fi

    if [ -z "$value" ]; then
        case "$generate" in
            random|install)
                value=$(openssl rand -base64 48 | tr -d '\n\r')
                ;;
            rsa)
                # Signing key, not a shared secret: the verifier side reads the
                # public half off DataCore's JWKS, so only the PEM is stored.
                # PKCS#1 at 4096 to match what the chart's own genPrivateKey
                # "rsa" produces, so the two bootstrap paths agree. OpenSSL 3.x
                # defaults to PKCS#8 and needs -traditional asked for by name.
                value=$(openssl genrsa -traditional 4096 2>/dev/null \
                    || openssl genrsa 4096 2>/dev/null)
                ;;
            adopt)
                echo -e "${YELLOW}Skipping ${key} in ${PLATFORM_SECRET_NAME} (adopt-only; supply ${env_name:-$key})${NC}"
                return 0
                ;;
            *)
                if [ -n "$alias_of" ]; then
                    # An alias with no generator of its own. Skipping quietly
                    # would leave DataBridge without the credential it presents
                    # to DataCore, which 401s every agent that tries to enrol.
                    echo -e "${RED}Error: ${key} mirrors ${alias_of}, which could not be resolved${NC}" >&2
                    return 1
                fi
                return 0
                ;;
        esac
    fi

    # A PEM must reach the consumer with its line structure intact.
    local store_mode="trim"
    case "$value" in
        *"-----BEGIN"*) store_mode="raw" ;;
    esac
    add_secret_key "$PLATFORM_SECRET_NAME" "$key" "$value" "$store_mode"
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
            echo "  - DEPLOYMENT_MODE       hybrid|external|saas (default: external)"
            echo "  - ENABLE_TRUSTGATE / ENABLE_TRUSTGUARD / ENABLE_DATAPLANE"
            echo "  - ENABLE_TRUSTLENS / ENABLE_MCP_OAUTH / ENABLE_WATCHDOG"
            echo "  - ENABLE_CONFIG_SYNC (default: on for hybrid, off for external)"
            echo "  - CONFIG_SYNC_LKG_KEY (base64, exactly 32 bytes; generated when unset)"
            echo "    TRUSTGATE_CONFIG_SYNC_LKG_KEY / TRUSTGUARD_CONFIG_SYNC_LKG_KEY override per product"
            echo "    CONFIG_SYNC_SECRET_TRUSTGATE / CONFIG_SYNC_SECRET_TRUSTGUARD set the Secret names"
            echo "    (defaults: agentgateway-config-sync / trustguard-config-sync)"
            echo "  - DATA_PLANE_JWT_SECRET"
            echo "  - DATA_PLANE_REDIS_URL (optional; platform-v2 evaluation-progress cache)"
            echo "  - CONTROL_PLANE_JWT_SECRET"
            echo "  - OPENAI_API_KEY"
            echo "  - GOOGLE_API_KEY"
            echo "  - RESEND_API_KEY"
            echo "  - HUGGINGFACE_TOKEN"
            echo "  - CLICKHOUSE_PASSWORD"
            echo "  - POSTGRES_PASSWORD / POSTGRES_AUTH_MODE / POSTGRES_SSLMODE"
            echo "  - FIREWALL_JWT_SECRET"
            echo "  - OBSERVABILITY_TOKEN (hosted OTLP bearer for collector.neuraltrust.ai)"
            echo "  - APP_AUTH_SECRET (written to AUTH_SECRET and NEXTAUTH_SECRET)"
            echo "  - AUTH_SECRET_KEY / MODEL_SCANNER_SECRET / MCP_OAUTH_CLIENT_SECRET"
            echo "  - AGENTGATEWAY_SERVER_SECRET_KEY / AGENTGATEWAY_STS_SIGNING_KEY (RSA PEM)"
            echo "  - TRUSTGUARD_CLIENT_ID / TRUSTGUARD_CLIENT_SECRET"
            echo "  - TRUSTGUARD_ADMIN_JWT_SECRET / TRUSTGUARD_TOKEN_SIGNING_SECRET"
            echo "  - TRUSTGUARD_REDIS_EVENTS_SECRET"
            echo "  - DATACORE_JWT_SECRET / DATACORE_DB_PASSWORD / ALERTENGINE_JWT_SECRET"
            echo "  - TRUSTLENS_JWT_SECRET / TRUSTLENS_ENCRYPTION_KEYSET"
            echo "  - DATAAGENT_DB_PASSWORD (ENROLMENT_TOKEN is never generated)"
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
# DEPLOYMENT SHAPE (drives which platform-secrets keys are created)
# ============================================================================
echo -e "${BLUE}=== Deployment shape ===${NC}"
DEPLOYMENT_MODE=$(prompt_secret "DEPLOYMENT_MODE" "Enter deployment mode (hybrid|external|saas, default: external)")
DEPLOYMENT_MODE=$(printf '%s' "${DEPLOYMENT_MODE:-external}" | tr '[:upper:]' '[:lower:]')
case "$DEPLOYMENT_MODE" in
    hybrid|external|saas) ;;
    *)
        echo -e "${RED}Error: DEPLOYMENT_MODE must be hybrid, external or saas${NC}"
        exit 1
        ;;
esac

prompt_yes_default() {
    local env_name=$1
    local prompt=$2
    local default_yes=$3
    local current="${!env_name:-}"
    if [ -n "$current" ]; then
        case "$(printf '%s' "$current" | tr '[:upper:]' '[:lower:]')" in
            1|true|yes|y) return 0 ;;
            *) return 1 ;;
        esac
    fi
    if [ -t 0 ]; then
        local hint="y/N"
        [ "$default_yes" = "true" ] && hint="Y/n"
        read -p "${prompt} (${hint}): " -n 1 -r
        echo
        if [ -z "$REPLY" ]; then
            [ "$default_yes" = "true" ]
            return $?
        fi
        [[ $REPLY =~ ^[Yy]$ ]]
        return $?
    fi
    [ "$default_yes" = "true" ]
}

if [ "$DEPLOYMENT_MODE" = "external" ] || [ "$DEPLOYMENT_MODE" = "saas" ]; then
    PLATFORM_SHAPES+=(external trustgate trustguard dataPlane)
    # saas is external plus the credentials its remote data planes enrol with.
    if [ "$DEPLOYMENT_MODE" = "saas" ]; then
        PLATFORM_SHAPES+=(saas)
    fi
else
    if prompt_yes_default "ENABLE_TRUSTGATE" "Enable TrustGate product secrets?" "true"; then
        PLATFORM_SHAPES+=(trustgate)
    fi
    if prompt_yes_default "ENABLE_TRUSTGUARD" "Enable TrustGuard product secrets?" "true"; then
        PLATFORM_SHAPES+=(trustguard)
    fi
    if prompt_yes_default "ENABLE_DATAPLANE" "Enable data-plane product secrets?" "true"; then
        PLATFORM_SHAPES+=(dataPlane)
    fi
fi
if prompt_yes_default "ENABLE_TRUSTLENS" "Enable TrustLens secrets?" "false"; then
    PLATFORM_SHAPES+=(trustlens)
fi
if shape_enabled external && prompt_yes_default "ENABLE_MCP_OAUTH" "Enable MCP OAuth client secret?" "true"; then
    PLATFORM_SHAPES+=(mcpOAuth)
fi
if prompt_yes_default "ENABLE_WATCHDOG" "Enable Watchdog usage-export JWT secrets?" "false"; then
    PLATFORM_SHAPES+=(watchdog)
fi
echo -e "${GREEN}Active shapes: ${PLATFORM_SHAPES[*]:-none}${NC}"
echo ""

# ============================================================================
# PLATFORM V2 STABLE SECRETS
# ============================================================================
echo -e "${BLUE}=== Platform v2 Stable Secrets ===${NC}"

ensure_generated_secret_key "agentgateway-secrets" "SERVER_SECRET_KEY" "AGENTGATEWAY_SERVER_SECRET_KEY"
ensure_rsa_private_key_secret_key "agentgateway-secrets" "STS_SIGNING_KEY" "AGENTGATEWAY_STS_SIGNING_KEY"
ensure_generated_secret_key "agentgateway-secrets" "DB_PASSWORD" "AGENTGATEWAY_DB_PASSWORD"

ensure_generated_secret_key "trustguard-secrets" "ADMIN_JWT_SECRET" "TRUSTGUARD_ADMIN_JWT_SECRET"
ensure_generated_secret_key "trustguard-secrets" "TRUSTGUARD_TOKEN_SIGNING_SECRET" "TRUSTGUARD_TOKEN_SIGNING_SECRET"
ensure_generated_secret_key "trustguard-secrets" "REDIS_EVENTS_SECRET" "TRUSTGUARD_REDIS_EVENTS_SECRET"
ensure_generated_secret_key "trustguard-secrets" "DB_PASSWORD" "TRUSTGUARD_DB_PASSWORD"

TRUSTGUARD_CLIENT_ID_VALUE="${TRUSTGUARD_CLIENT_ID:-${V2_TRUSTGUARD_CLIENT_ID:-}}"
if [ -z "$TRUSTGUARD_CLIENT_ID_VALUE" ]; then
    TRUSTGUARD_CLIENT_ID_VALUE=$(kubectl get secret trustguard-client-credentials -n "$NAMESPACE" \
        -o jsonpath='{.data.CLIENT_ID}' 2>/dev/null | base64 -d 2>/dev/null || true)
fi
if [ -z "$TRUSTGUARD_CLIENT_ID_VALUE" ]; then
    TRUSTGUARD_CLIENT_ID_VALUE=$(kubectl get secret v2-trustguard-client-secret -n "$NAMESPACE" \
        -o jsonpath='{.data.CLIENT_ID}' 2>/dev/null | base64 -d 2>/dev/null || true)
fi
TRUSTGUARD_CLIENT_ID_VALUE="${TRUSTGUARD_CLIENT_ID_VALUE:-agentgateway-platform}"

TRUSTGUARD_CLIENT_SECRET_VALUE="${TRUSTGUARD_CLIENT_SECRET:-${V2_TRUSTGUARD_CLIENT_SECRET:-}}"
if [ -z "$TRUSTGUARD_CLIENT_SECRET_VALUE" ]; then
    TRUSTGUARD_CLIENT_SECRET_VALUE=$(kubectl get secret trustguard-client-credentials -n "$NAMESPACE" \
        -o jsonpath='{.data.CLIENT_SECRET}' 2>/dev/null | base64 -d 2>/dev/null || true)
fi
if [ -z "$TRUSTGUARD_CLIENT_SECRET_VALUE" ]; then
    TRUSTGUARD_CLIENT_SECRET_VALUE=$(kubectl get secret v2-trustguard-client-secret -n "$NAMESPACE" \
        -o jsonpath='{.data.CLIENT_SECRET}' 2>/dev/null | base64 -d 2>/dev/null || true)
fi
if [ -z "$TRUSTGUARD_CLIENT_SECRET_VALUE" ]; then
    TRUSTGUARD_CLIENT_SECRET_VALUE=$(openssl rand -base64 48 | tr -d '\n\r')
fi

add_secret_key "trustguard-client-credentials" "CLIENT_ID" "$TRUSTGUARD_CLIENT_ID_VALUE"
add_secret_key "trustguard-client-credentials" "CLIENT_SECRET" "$TRUSTGUARD_CLIENT_SECRET_VALUE"
unset TRUSTGUARD_CLIENT_ID_VALUE TRUSTGUARD_CLIENT_SECRET_VALUE

ensure_generated_secret_key "datacore-secrets" "AUTH_JWT_HS256_SECRET" "DATACORE_JWT_SECRET"
ensure_generated_secret_key "datacore-secrets" "POSTGRES_PASSWORD" "DATACORE_DB_PASSWORD"
ensure_generated_secret_key "alertengine-secrets" "AUTH_JWT_SECRET" "ALERTENGINE_JWT_SECRET"
ensure_generated_secret_key "alertengine-secrets" "APP_ENCRYPTION_KEY" "ALERTENGINE_APP_ENCRYPTION_KEY"
ensure_generated_secret_key "alertengine-secrets" "DB_PASSWORD" "ALERTENGINE_DB_PASSWORD"

APP_AUTH_SECRET_VALUE="${APP_AUTH_SECRET:-}"
if [ -z "$APP_AUTH_SECRET_VALUE" ]; then
    APP_AUTH_SECRET_VALUE=$(kubectl get secret control-plane-secrets -n "$NAMESPACE" \
        -o jsonpath='{.data.AUTH_SECRET}' 2>/dev/null | base64 -d 2>/dev/null || true)
fi
if [ -z "$APP_AUTH_SECRET_VALUE" ]; then
    APP_AUTH_SECRET_VALUE=$(kubectl get secret control-plane-secrets -n "$NAMESPACE" \
        -o jsonpath='{.data.NEXTAUTH_SECRET}' 2>/dev/null | base64 -d 2>/dev/null || true)
fi
if [ -z "$APP_AUTH_SECRET_VALUE" ]; then
    APP_AUTH_SECRET_VALUE=$(openssl rand -base64 48 | tr -d '\n\r')
fi
add_secret_key "control-plane-secrets" "AUTH_SECRET" "$APP_AUTH_SECRET_VALUE"
add_secret_key "control-plane-secrets" "NEXTAUTH_SECRET" "$APP_AUTH_SECRET_VALUE"
unset APP_AUTH_SECRET_VALUE

# DataAgent DB credential may be generated; ENROLMENT_TOKEN is never created here.
ensure_generated_secret_key "dataagent-secrets" "DB_PASSWORD" "DATAAGENT_DB_PASSWORD"
DATAAGENT_DB_PASSWORD_VALUE=$(kubectl get secret dataagent-secrets -n "$NAMESPACE" \
    -o jsonpath='{.data.DB_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || true)
DATAAGENT_DB_PASSWORD_ENCODED=$(url_encode "$DATAAGENT_DB_PASSWORD_VALUE")
DATAAGENT_DATABASE_URL="${DATAAGENT_DATABASE_URL:-postgresql://${DATAAGENT_DB_USER:-neuraltrust}:${DATAAGENT_DB_PASSWORD_ENCODED}@${DATAAGENT_DB_HOST:-control-plane-postgresql}:${DATAAGENT_DB_PORT:-5432}/${DATAAGENT_DB_NAME:-neuraltrust}?sslmode=${DATAAGENT_DB_SSLMODE:-prefer}}"
add_secret_key "dataagent-secrets" "DATABASE_URL" "$DATAAGENT_DATABASE_URL"
unset DATAAGENT_DB_PASSWORD_VALUE DATAAGENT_DB_PASSWORD_ENCODED DATAAGENT_DATABASE_URL
echo -e "${GREEN}✓ Platform v2 stable secret keys are ready (values not printed)${NC}"
echo -e "${YELLOW}DataAgent ENROLMENT_TOKEN was not generated; provide the enrolment token separately.${NC}"
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

# Data Plane Redis URL (optional; only needed for platform-v2, or a v1 override).
# The chart auto-generates this key from neuraltrust-data-plane.dataPlane.components.api.redis
# on every render UNLESS global.preserveExistingSecrets=true — set this when pre-provisioning
# secrets for external/ACL/IAM Redis. Uses add_secret_key so DATA_PLANE_JWT_SECRET is preserved.
echo "--- Data Plane Redis URL (Optional; platform-v2 evaluation-progress cache) ---"
SECRET_NAME="data-plane-jwt-secret"
DATA_PLANE_REDIS_URL=$(prompt_secret "DATA_PLANE_REDIS_URL" "Enter Data Plane Redis URL, e.g. redis://[user:pass@]host:6379/0 (optional, only with global.preserveExistingSecrets=true)")
if [ -n "$DATA_PLANE_REDIS_URL" ]; then
    add_secret_key "$SECRET_NAME" "REDIS_URL" "$DATA_PLANE_REDIS_URL"
    echo -e "${GREEN}Added REDIS_URL to ${SECRET_NAME}${NC}"
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

# Firewall JWT Secret — legacy control-plane key plus the chart's firewall-secrets
# contract (JWT_SECRET) that platform-secrets adopts from.
echo "--- Firewall JWT Secret (Optional) ---"
FIREWALL_JWT_SECRET=$(prompt_secret "FIREWALL_JWT_SECRET" "Enter Firewall JWT Secret (optional)")
if [ -n "$FIREWALL_JWT_SECRET" ]; then
    add_secret_key "$SECRET_NAME" "FIREWALL_JWT_SECRET" "$FIREWALL_JWT_SECRET"
    add_secret_key "firewall-secrets" "JWT_SECRET" "$FIREWALL_JWT_SECRET"
elif shape_enabled "trustguard" || shape_enabled "external"; then
    ensure_generated_secret_key "firewall-secrets" "JWT_SECRET" "FIREWALL_JWT_SECRET"
fi
echo ""

# Model Scanner Secret
echo "--- Model Scanner Secret (Optional) ---"
MODEL_SCANNER_SECRET=$(prompt_secret "MODEL_SCANNER_SECRET" "Enter Model Scanner Secret (optional)")
if [ -n "$MODEL_SCANNER_SECRET" ]; then
    add_secret_key "$SECRET_NAME" "MODEL_SCANNER_SECRET" "$MODEL_SCANNER_SECRET"
fi
echo ""

# TrustLens secrets (only when the TrustLens shape is active)
if shape_enabled "trustlens"; then
    echo "--- TrustLens Secrets ---"
    ensure_generated_secret_key "trustlens-secrets" "JWT_SECRET" "TRUSTLENS_JWT_SECRET"
    ensure_generated_secret_key "trustlens-secrets" "ENCRYPTION_KEYSET" "TRUSTLENS_ENCRYPTION_KEYSET"
    echo ""
fi

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

# Hosted observability token (collector.neuraltrust.ai bearer)
echo "--- Hosted Observability Token ---"
OBSERVABILITY_SECRET_NAME="neuraltrust-observability-token"
OBSERVABILITY_SECRET_KEY="token"

if kubectl get secret "$OBSERVABILITY_SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
    if should_replace_secret "$OBSERVABILITY_SECRET_NAME"; then
        OBSERVABILITY_TOKEN=$(prompt_secret "OBSERVABILITY_TOKEN" "Enter hosted OTLP bearer token")
        if [ -z "$OBSERVABILITY_TOKEN" ]; then
            echo -e "${RED}Error: OBSERVABILITY_TOKEN is required for hosted export${NC}"
            exit 1
        fi
        create_secret "$OBSERVABILITY_SECRET_NAME" "$OBSERVABILITY_SECRET_KEY" "$OBSERVABILITY_TOKEN" "Hosted OTLP bearer token"
    else
        echo -e "${GREEN}Skipping ${OBSERVABILITY_SECRET_NAME} (already exists)${NC}"
    fi
else
    OBSERVABILITY_TOKEN=$(prompt_secret "OBSERVABILITY_TOKEN" "Enter hosted OTLP bearer token")
    if [ -z "$OBSERVABILITY_TOKEN" ]; then
        echo -e "${YELLOW}No OBSERVABILITY_TOKEN provided — skipping ${OBSERVABILITY_SECRET_NAME}.${NC}"
        echo -e "${YELLOW}Watchdog hosted export stays offline until this Secret exists.${NC}"
    else
        create_secret "$OBSERVABILITY_SECRET_NAME" "$OBSERVABILITY_SECRET_KEY" "$OBSERVABILITY_TOKEN" "Hosted OTLP bearer token"
    fi
fi
echo ""

# PostgreSQL Connection — canonical POSTGRES_* family only.
# No SENSIBLE_PG_DSN / DATABASE_URL composition: hybrid readers (TrustGate /
# TrustGuard telemetry, DataAgent) and the control-plane app build connections
# from the discrete parts (RUN-1086, RUN-1093, AUT-413). POSTGRES_PRISMA_URL is
# still written for external installs that pin an older app image; omit it when
# authMode=iam (passwordless) or when POSTGRES_PASSWORD is empty (operator-owned
# passwordSecret path).
echo "--- PostgreSQL Connection Configuration ---"
POSTGRES_SECRET_NAME="postgresql-secrets"

if kubectl get secret "$POSTGRES_SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
    EXISTING_POSTGRES_HOST=$(kubectl get secret "$POSTGRES_SECRET_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.data.POSTGRES_HOST}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    if [ -z "$EXISTING_POSTGRES_HOST" ] || should_replace_secret "$POSTGRES_SECRET_NAME"; then
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
    EXISTING_POSTGRES_HOST=$(kubectl get secret "$POSTGRES_SECRET_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.data.POSTGRES_HOST}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
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
    POSTGRES_PASSWORD=$(prompt_secret "POSTGRES_PASSWORD" "Enter NeuralTrust Password (empty when using passwordSecret / IAM)")
    POSTGRES_DB=$(prompt_secret "POSTGRES_DB" "Enter PostgreSQL Database Name (default: neuraltrust)")
    POSTGRES_DB=${POSTGRES_DB:-neuraltrust}
    POSTGRES_AUTH_MODE=$(prompt_secret "POSTGRES_AUTH_MODE" "Enter PostgreSQL authMode (password|iam, default: password)")
    POSTGRES_AUTH_MODE=$(printf '%s' "${POSTGRES_AUTH_MODE:-password}" | tr '[:upper:]' '[:lower:]')
    POSTGRES_SSLMODE=$(prompt_secret "POSTGRES_SSLMODE" "Enter PostgreSQL SSL mode (default: prefer for password, require for iam)")
    if [ -z "$POSTGRES_SSLMODE" ]; then
        if [ "$POSTGRES_AUTH_MODE" = "iam" ]; then
            POSTGRES_SSLMODE="require"
        else
            POSTGRES_SSLMODE="prefer"
        fi
    fi

    POSTGRES_HOST=$(trim_value "$POSTGRES_HOST")
    POSTGRES_PORT=$(trim_value "$POSTGRES_PORT")
    POSTGRES_USER=$(trim_value "$POSTGRES_USER")
    POSTGRES_PASSWORD=$(trim_value "$POSTGRES_PASSWORD")
    POSTGRES_DB=$(trim_value "$POSTGRES_DB")
    POSTGRES_SSLMODE=$(trim_value "$POSTGRES_SSLMODE")
    POSTGRES_AUTH_MODE=$(trim_value "$POSTGRES_AUTH_MODE")

    if [ -z "$POSTGRES_HOST" ]; then
        echo -e "${RED}Error: PostgreSQL host is required${NC}"
        exit 1
    fi
    if [ "$POSTGRES_AUTH_MODE" = "iam" ]; then
        POSTGRES_LOGIN="aws"
        POSTGRES_CONNECTION_TYPE="aurora"
    else
        POSTGRES_LOGIN="default"
        POSTGRES_CONNECTION_TYPE="postgres"
        if [ -z "$POSTGRES_PASSWORD" ]; then
            echo -e "${YELLOW}Warning: PostgreSQL password is empty (ok for passwordSecret)${NC}"
        fi
    fi

    echo -e "${GREEN}Creating PostgreSQL connection secret (canonical family)${NC}"
    kubectl_pg_cmd=(kubectl create secret generic "$POSTGRES_SECRET_NAME" -n "$NAMESPACE"
        --from-literal=POSTGRES_HOST="$POSTGRES_HOST"
        --from-literal=POSTGRES_PORT="$POSTGRES_PORT"
        --from-literal=POSTGRES_USER="$POSTGRES_USER"
        --from-literal=POSTGRES_DB="$POSTGRES_DB"
        --from-literal=POSTGRES_SSLMODE="$POSTGRES_SSLMODE"
        --from-literal=POSTGRES_LOGIN="$POSTGRES_LOGIN"
        --from-literal=POSTGRES_AUTH_MODE="$POSTGRES_AUTH_MODE"
        --from-literal=POSTGRES_CONNECTION_TYPE="$POSTGRES_CONNECTION_TYPE")
    if [ -n "$POSTGRES_PASSWORD" ] && [ "$POSTGRES_AUTH_MODE" != "iam" ]; then
        kubectl_pg_cmd+=(--from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD")
        POSTGRES_PASSWORD_ENCODED=$(url_encode "$POSTGRES_PASSWORD")
        POSTGRES_PRISMA_URL=$(printf 'postgresql://%s:%s@%s:%s/%s?connection_limit=15&sslmode=%s' \
            "$POSTGRES_USER" "$POSTGRES_PASSWORD_ENCODED" "$POSTGRES_HOST" "$POSTGRES_PORT" \
            "$POSTGRES_DB" "$POSTGRES_SSLMODE" | tr -d '\n\r')
        kubectl_pg_cmd+=(--from-literal=POSTGRES_PRISMA_URL="$POSTGRES_PRISMA_URL")
    elif [ "$POSTGRES_AUTH_MODE" = "iam" ]; then
        POSTGRES_PRISMA_URL=$(printf 'postgresql://%s@%s:%s/%s?connection_limit=15&sslmode=%s' \
            "$POSTGRES_USER" "$POSTGRES_HOST" "$POSTGRES_PORT" "$POSTGRES_DB" "$POSTGRES_SSLMODE" | tr -d '\n\r')
        kubectl_pg_cmd+=(--from-literal=POSTGRES_PRISMA_URL="$POSTGRES_PRISMA_URL")
    fi
    "${kubectl_pg_cmd[@]}" --dry-run=client -o yaml | kubectl apply -f -

    echo -e "${GREEN}✓ PostgreSQL connection secret created${NC}"
fi
echo ""

# ============================================================================
# FIREWALL SECRETS
# ============================================================================
echo -e "${BLUE}=== Firewall Secrets ===${NC}"

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

# The legacy control-plane section may recreate control-plane-secrets when
# --replace-existing is used. Reassert the v2 auth aliases last so both keys
# always finish with the same value.
APP_AUTH_SECRET_VALUE="${APP_AUTH_SECRET:-}"
if [ -z "$APP_AUTH_SECRET_VALUE" ]; then
    APP_AUTH_SECRET_VALUE=$(kubectl get secret control-plane-secrets -n "$NAMESPACE" \
        -o jsonpath='{.data.AUTH_SECRET}' 2>/dev/null | base64 -d 2>/dev/null || true)
fi
if [ -z "$APP_AUTH_SECRET_VALUE" ]; then
    APP_AUTH_SECRET_VALUE=$(kubectl get secret control-plane-secrets -n "$NAMESPACE" \
        -o jsonpath='{.data.NEXTAUTH_SECRET}' 2>/dev/null | base64 -d 2>/dev/null || true)
fi
if [ -z "$APP_AUTH_SECRET_VALUE" ]; then
    APP_AUTH_SECRET_VALUE=$(openssl rand -base64 48 | tr -d '\n\r')
fi
add_secret_key "control-plane-secrets" "AUTH_SECRET" "$APP_AUTH_SECRET_VALUE"
add_secret_key "control-plane-secrets" "NEXTAUTH_SECRET" "$APP_AUTH_SECRET_VALUE"
unset APP_AUTH_SECRET_VALUE

# ============================================================================
# SHARED PLATFORM SECRET (platform-secrets)
# Driven by the same logical key list as platformSecret.registry so consumers
# that read via secretRef work under preserveExistingSecrets / autoGenerateSecrets=false.
# ============================================================================
echo -e "${BLUE}=== Shared platform-secrets ===${NC}"
# Args: key legacyName legacyKey generate envName requires [aliasOf]
ensure_platform_secret_key "SERVER_SECRET_KEY" "agentgateway-secrets" "SERVER_SECRET_KEY" "random" "AGENTGATEWAY_SERVER_SECRET_KEY" "external trustgate"
ensure_platform_secret_key "ADMIN_JWT_SECRET" "trustguard-secrets" "ADMIN_JWT_SECRET" "random" "TRUSTGUARD_ADMIN_JWT_SECRET" "external trustguard"
ensure_platform_secret_key "TRUSTGUARD_TOKEN_SIGNING_SECRET" "trustguard-secrets" "TRUSTGUARD_TOKEN_SIGNING_SECRET" "random" "TRUSTGUARD_TOKEN_SIGNING_SECRET" "external trustguard"
ensure_platform_secret_key "REDIS_EVENTS_SECRET" "trustguard-secrets" "REDIS_EVENTS_SECRET" "random" "TRUSTGUARD_REDIS_EVENTS_SECRET" "external trustguard"
ensure_platform_secret_key "AUTH_JWT_HS256_SECRET" "datacore-secrets" "AUTH_JWT_HS256_SECRET" "random" "DATACORE_JWT_SECRET" "external"
ensure_platform_secret_key "AUTH_JWT_SECRET" "alertengine-secrets" "AUTH_JWT_SECRET" "random" "ALERTENGINE_JWT_SECRET" "external"
ensure_platform_secret_key "APP_ENCRYPTION_KEY" "alertengine-secrets" "APP_ENCRYPTION_KEY" "random" "ALERTENGINE_APP_ENCRYPTION_KEY" "external"
ensure_platform_secret_key "TRUSTLENS_JWT_SECRET" "trustlens-secrets" "JWT_SECRET" "random" "TRUSTLENS_JWT_SECRET" "trustlens"
ensure_platform_secret_key "ENCRYPTION_KEYSET" "trustlens-secrets" "ENCRYPTION_KEYSET" "random" "TRUSTLENS_ENCRYPTION_KEYSET" "trustlens"
ensure_platform_secret_key "JWT_SECRET" "firewall-secrets" "JWT_SECRET" "random" "FIREWALL_JWT_SECRET" "external trustguard"
ensure_platform_secret_key "DATA_PLANE_JWT_SECRET" "data-plane-jwt-secret" "DATA_PLANE_JWT_SECRET" "random" "DATA_PLANE_JWT_SECRET" "external dataPlane watchdog"
ensure_platform_secret_key "CONTROL_PLANE_JWT_SECRET" "control-plane-secrets" "CONTROL_PLANE_JWT_SECRET" "random" "CONTROL_PLANE_JWT_SECRET" "external watchdog"
ensure_platform_secret_key "AUTH_SECRET" "control-plane-secrets" "AUTH_SECRET" "random" "APP_AUTH_SECRET" "external"
ensure_platform_secret_key "NEXTAUTH_SECRET" "control-plane-secrets" "NEXTAUTH_SECRET" "random" "APP_AUTH_SECRET" "external" "AUTH_SECRET"
ensure_platform_secret_key "MODEL_SCANNER_SECRET" "control-plane-secrets" "MODEL_SCANNER_SECRET" "adopt" "MODEL_SCANNER_SECRET" "external"
ensure_platform_secret_key "MCP_OAUTH_CLIENT_SECRET" "control-plane-secrets" "MCP_OAUTH_CLIENT_SECRET" "random" "MCP_OAUTH_CLIENT_SECRET" "mcpOAuth"
ensure_platform_secret_key "MCP_OAUTH_SIGNING_KEY" "control-plane-secrets" "MCP_OAUTH_SIGNING_KEY" "adopt" "MCP_OAUTH_SIGNING_KEY" "mcpOAuth"
ensure_platform_secret_key "AUTH_SECRET_KEY" "control-plane-secrets" "AUTH_SECRET_KEY" "install" "AUTH_SECRET_KEY" "external"
# saas only: credentials shared between DataCore and DataBridge so data planes
# in other clusters can enrol. DATACORE_SERVICE_TOKEN aliases the introspection
# token because DataBridge presents exactly what DataCore compares against.
ensure_platform_secret_key "ENROLMENT_INTROSPECTION_TOKEN" "datacore-secrets" "ENROLMENT_INTROSPECTION_TOKEN" "random" "ENROLMENT_INTROSPECTION_TOKEN" "saas"
ensure_platform_secret_key "DATACORE_SERVICE_TOKEN" "databridge-secrets" "DATACORE_SERVICE_TOKEN" "" "ENROLMENT_INTROSPECTION_TOKEN" "saas" "ENROLMENT_INTROSPECTION_TOKEN"
ensure_platform_secret_key "ENROLMENT_SIGNING_SECRET" "datacore-secrets" "ENROLMENT_SIGNING_SECRET" "random" "ENROLMENT_SIGNING_SECRET" "saas"
ensure_platform_secret_key "TELEMETRY_JWT_PRIVATE_KEY_PEM" "datacore-secrets" "TELEMETRY_JWT_PRIVATE_KEY_PEM" "rsa" "TELEMETRY_JWT_PRIVATE_KEY_PEM" "saas"
echo -e "${GREEN}✓ ${PLATFORM_SECRET_NAME} keys ready for shapes: ${PLATFORM_SHAPES[*]:-none}${NC}"
echo ""

# ============================================================================
# CONFIG-SYNC LKG CACHE KEY (TrustGate / TrustGuard)
# Written into the operator-owned configSync.existingSecret, because that is the
# only place the chart looks under preserveExistingSecrets / autoGenerateSecrets=false
# (see neuraltrust-platform.configSyncTokenEnv). The companion CONFIG_SYNC_TOKEN
# is issued by the console and is never generated here.
# ============================================================================
if shape_enabled trustgate || shape_enabled trustguard; then
    CONFIG_SYNC_DEFAULT_YES="false"
    if [ "$DEPLOYMENT_MODE" = "hybrid" ]; then
        CONFIG_SYNC_DEFAULT_YES="true"
    fi
    if prompt_yes_default "ENABLE_CONFIG_SYNC" "Enable config-sync (SaaS-managed configuration) secrets?" "$CONFIG_SYNC_DEFAULT_YES"; then
        echo -e "${BLUE}=== Config-sync LKG cache key ===${NC}"
        CONFIG_SYNC_LKG_KEY_NAME="${CONFIG_SYNC_LKG_KEY_NAME:-CONFIG_SYNC_LKG_KEY}"
        if shape_enabled trustgate; then
            ensure_config_sync_lkg_key \
                "${CONFIG_SYNC_SECRET_TRUSTGATE:-agentgateway-config-sync}" \
                "$CONFIG_SYNC_LKG_KEY_NAME" \
                "TRUSTGATE_CONFIG_SYNC_LKG_KEY"
        fi
        if shape_enabled trustguard; then
            ensure_config_sync_lkg_key \
                "${CONFIG_SYNC_SECRET_TRUSTGUARD:-trustguard-config-sync}" \
                "$CONFIG_SYNC_LKG_KEY_NAME" \
                "TRUSTGUARD_CONFIG_SYNC_LKG_KEY"
        fi
        echo -e "${YELLOW}Note: CONFIG_SYNC_TOKEN is issued by the NeuralTrust console and is never generated.${NC}"
        echo -e "${YELLOW}Add it to the same Secret(s) and point <product>.configSync.existingSecret.name at them.${NC}"
        echo ""
    fi
fi

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
echo "Set global.preserveExistingSecrets=true (or autoGenerateSecrets=false) when"
echo "the chart must not overwrite the Secrets this script just wrote."

