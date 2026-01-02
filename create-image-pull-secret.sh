#!/bin/bash
# Simple script to create Kubernetes docker-registry secret for Google Container Registry (GCR)
# This is required to pull private container images from GCR

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values (GCR-specific)
NAMESPACE="${NAMESPACE:-neuraltrust}"
SECRET_NAME="${SECRET_NAME:-gcr-secret}"
DOCKER_SERVER="${DOCKER_SERVER:-europe-west1-docker.pkg.dev}"
DOCKER_USERNAME="${DOCKER_USERNAME:-_json_key}"
DOCKER_EMAIL="${DOCKER_EMAIL:-admin@neuraltrust.ai}"

# Function to trim whitespace from a value
trim_value() {
    local value="$1"
    echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '\n\r'
}

# Function to check if secret should be replaced
should_replace_secret() {
    local secret_name=$1
    
    if [ -n "$REPLACE_EXISTING" ]; then
        if [ "$REPLACE_EXISTING" = "true" ] || [ "$REPLACE_EXISTING" = "yes" ] || [ "$REPLACE_EXISTING" = "y" ]; then
            return 0  # true
        else
            return 1  # false
        fi
    else
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

echo "=========================================="
echo "NeuralTrust Platform Image Pull Secret"
echo "=========================================="
echo ""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --secret-name)
            SECRET_NAME="$2"
            shift 2
            ;;
        --docker-server)
            DOCKER_SERVER="$2"
            shift 2
            ;;
        --docker-email)
            DOCKER_EMAIL="$2"
            shift 2
            ;;
        --replace-existing)
            REPLACE_EXISTING="true"
            shift
            ;;
        --no-replace-existing)
            REPLACE_EXISTING="false"
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Creates a Kubernetes docker-registry secret for Google Container Registry (GCR)."
            echo ""
            echo "Options:"
            echo "  --namespace NAMESPACE       Use specified namespace (default: neuraltrust)"
            echo "  --secret-name NAME          Secret name (default: gcr-secret)"
            echo "  --docker-server SERVER      GCR server (default: europe-west1-docker.pkg.dev)"
            echo "  --docker-email EMAIL        Docker email (default: admin@neuraltrust.ai)"
            echo "  --replace-existing          Replace existing secret without asking"
            echo "  --no-replace-existing       Skip if secret exists without asking"
            echo "  --help, -h                  Show this help message"
            echo ""
            echo "Environment variables:"
            echo "  NAMESPACE                   Set the namespace to use"
            echo "  SECRET_NAME                 Set the secret name (default: gcr-secret)"
            echo "  DOCKER_SERVER               Set the GCR server (default: europe-west1-docker.pkg.dev)"
            echo "  DOCKER_EMAIL                Set the docker email (default: admin@neuraltrust.ai)"
            echo "  GCR_KEY_FILE                Path to GCR JSON key file (alternative to interactive input)"
            echo "  REPLACE_EXISTING             Set to 'true' or 'false' to control replacement"
            echo ""
            echo "Examples:"
            echo "  # Create GCR secret (interactive - will prompt for JSON key file)"
            echo "  $0 --namespace neuraltrust"
            echo ""
            echo "  # Create GCR secret with key file from environment"
            echo "  GCR_KEY_FILE=./gcr-keys.json $0 --namespace neuraltrust"
            echo ""
            echo "  # Create secret with JSON key content from environment"
            echo "  DOCKER_PASSWORD=\$(cat gcr-keys.json) $0 --namespace neuraltrust"
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
echo -e "${GREEN}Secret name: ${SECRET_NAME}${NC}"
echo ""

# Check if secret already exists
if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
    if ! should_replace_secret "$SECRET_NAME"; then
        echo -e "${GREEN}Secret ${SECRET_NAME} already exists. Skipping.${NC}"
        exit 0
    fi
    echo -e "${YELLOW}Deleting existing secret ${SECRET_NAME}...${NC}"
    kubectl delete secret "$SECRET_NAME" -n "$NAMESPACE" --ignore-not-found=true
fi

# Get GCR JSON key
if [ -n "$DOCKER_PASSWORD" ]; then
    echo -e "${GREEN}Using DOCKER_PASSWORD from environment (GCR JSON key)${NC}"
    DOCKER_PASSWORD=$(trim_value "$DOCKER_PASSWORD")
elif [ -n "$GCR_KEY_FILE" ] && [ -f "$GCR_KEY_FILE" ]; then
    echo -e "${GREEN}Reading GCR JSON key from file: ${GCR_KEY_FILE}${NC}"
    DOCKER_PASSWORD=$(cat "$GCR_KEY_FILE" | tr -d '\n\r')
else
    # Prompt for GCR JSON key file
    read -p "Enter path to GCR JSON key file (or press Enter to paste JSON content): " key_path
    key_path=$(trim_value "$key_path")
    
    if [ -n "$key_path" ] && [ -f "$key_path" ]; then
        DOCKER_PASSWORD=$(cat "$key_path" | tr -d '\n\r')
        echo -e "${GREEN}Read JSON key from file${NC}"
    else
        echo "Paste the GCR JSON key content (press Ctrl+D when done):"
        DOCKER_PASSWORD=$(cat | tr -d '\n\r')
    fi
fi

if [ -z "$DOCKER_PASSWORD" ]; then
    echo -e "${RED}Error: GCR JSON key is required${NC}"
    exit 1
fi

# Validate that it looks like JSON
if ! echo "$DOCKER_PASSWORD" | grep -q '"type"'; then
    echo -e "${YELLOW}Warning: The provided key doesn't appear to be a valid GCR JSON key${NC}"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Create the secret
echo -e "${GREEN}Creating GCR docker-registry secret: ${SECRET_NAME}${NC}"
kubectl create secret docker-registry "$SECRET_NAME" \
    --docker-server="$DOCKER_SERVER" \
    --docker-username="$DOCKER_USERNAME" \
    --docker-password="$DOCKER_PASSWORD" \
    --docker-email="$DOCKER_EMAIL" \
    -n "$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

echo -e "${GREEN}✓ GCR secret ${SECRET_NAME} created successfully${NC}"
echo ""
echo "You can now use this secret in your values.yaml:"
echo "  neuraltrust-control-plane:"
echo "    controlPlane:"
echo "      imagePullSecrets: \"${SECRET_NAME}\""
echo ""
echo "  neuraltrust-data-plane:"
echo "    dataPlane:"
echo "      imagePullSecrets: \"${SECRET_NAME}\""
echo ""
echo "  trustgate:"
echo "    global:"
echo "      image:"
echo "        imagePullSecrets: [\"${SECRET_NAME}\"]"
echo ""
echo "Note: For Docker Hub or other registries, create the secret manually using:"
echo "  kubectl create secret docker-registry <secret-name> \\"
echo "    --docker-server=<registry-server> \\"
echo "    --docker-username=<username> \\"
echo "    --docker-password=<password> \\"
echo "    --docker-email=<email> \\"
echo "    -n ${NAMESPACE}"

