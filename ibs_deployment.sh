#!/bin/bash
set -e

# Function to display information
info() {
    echo "[INFO] $1"
}

# Function to display warnings
warn() {
    echo "[WARNING] $1"
}

# Function to display errors
error() {
    echo "[ERROR] $1"
    exit 1
}

# Function to prompt for input with validation
prompt_with_validation() {
    local prompt_text=$2
    local validation_msg=$3
    local value=""

    while [ -z "$value" ]; do
        read -p "$prompt_text: " value
        if [ -z "$value" ]; then
            warn "$validation_msg"
        fi
    done

    # Return the value
    echo "$value"
}

# Print welcome message
info "Welcome to the OneLens Agent Installation Script"
info "This script will install the OneLens Agent on your Kubernetes cluster"
echo ""

# Set default values
API_BASE_URL="${API_BASE_URL:=https://api-in.onelens.cloud}"
PVC_ENABLED="${PVC_ENABLED:=true}"
IMAGE_TAG="${IMAGE_TAG:=latest}"
DEFAULT_REGISTRY_URL="471112871310.dkr.ecr.ap-south-2.amazonaws.com"
echo "Default registry URL is: $DEFAULT_REGISTRY_URL"
read -p "Is this registry URL OK? (Y/n): " CONFIRM_REGISTRY
echo ""
if [[ "$CONFIRM_REGISTRY" =~ ^([nN][oO]?|[nN])$ ]]; then
    registry_url=$(prompt_with_validation "REGISTRY_URL" "Enter registry URL" "Registry URL cannot be empty")
    echo ""
else
    registry_url="$DEFAULT_REGISTRY_URL"
fi

# Take user input for required variables
echo "Please provide the following information:"
# Extract ACCOUNT and REGION from registry_url if ECR pattern matches
# Extract ACCOUNT and REGION from registry_url if ECR pattern matches

if [[ "$registry_url" =~ ^([0-9]+)\.dkr\.ecr\.([a-z0-9-]+)\.amazonaws\.com$ ]]; then
    ACCOUNT="${BASH_REMATCH[1]}"
    REGION="${BASH_REMATCH[2]}"
    info "Extracted ACCOUNT: $ACCOUNT"
    info "Extracted REGION: $REGION"
    read -p "Press Enter to keep region [$REGION] or type a new region: " REGION_INPUT
    if [[ -n "$REGION_INPUT" ]]; then
        REGION="$REGION_INPUT"
    fi
    echo ""
    read -p "Press Enter to keep account [$ACCOUNT] or type a new account: " ACCOUNT_INPUT
    if [[ -n "$ACCOUNT_INPUT" ]]; then
        ACCOUNT="$ACCOUNT_INPUT"
    fi
    echo ""
else
    ACCOUNT=$(prompt_with_validation "ACCOUNT" "Enter account ID" "Account ID cannot be empty")
    echo ""
    REGION=$(prompt_with_validation "REGION" "Enter region" "Region cannot be empty")
    echo ""
fi

# Default registration token
DEFAULT_REGISTRATION_TOKEN="a8e0adcd-8b31-4c6d-b086-ae06d9dd9e78"
echo "Default registration token is: $DEFAULT_REGISTRATION_TOKEN"
read -p "Press Enter to keep registration token or type a new one: " REGISTRATION_TOKEN_INPUT
if [[ -n "$REGISTRATION_TOKEN_INPUT" ]]; then
    REGISTRATION_TOKEN="$REGISTRATION_TOKEN_INPUT"
else
    REGISTRATION_TOKEN="$DEFAULT_REGISTRATION_TOKEN"
fi
echo ""

CLUSTER_NAME=$(prompt_with_validation "CLUSTER_NAME" "Enter cluster name" "Cluster name cannot be empty")
echo ""

# Default release version
DEFAULT_RELEASE_VERSION="1.8.0"
echo "Default release version is: $DEFAULT_RELEASE_VERSION"
read -p "Press Enter to keep release version or type a new one: " RELEASE_VERSION_INPUT
if [[ -n "$RELEASE_VERSION_INPUT" ]]; then
    RELEASE_VERSION="$RELEASE_VERSION_INPUT"
else
    RELEASE_VERSION="$DEFAULT_RELEASE_VERSION"
fi
echo ""

# Prompt for regcred input
DEFAULT_REGCRED="regcred"
echo "Default image pull secret is: $DEFAULT_REGCRED"
read -p "Press Enter to keep image pull secret [$DEFAULT_REGCRED] or type a new one: " REGCRED_INPUT
if [[ -n "$REGCRED_INPUT" ]]; then
    REGCRED="$REGCRED_INPUT"
else
    REGCRED="$DEFAULT_REGCRED"
fi
echo ""

# Optional parameters with defaults
echo ""
info "Optional Parameters (press Enter to skip toleration and node selector configuration):"

read -p "Enter toleration key (press Enter to skip all toleration and node selector fields): " TOLERATION_KEY
if [[ -n "$TOLERATION_KEY" ]]; then
    read -p "Enter toleration value: " TOLERATION_VALUE
    read -p "Enter toleration operator: " TOLERATION_OPERATOR
    read -p "Enter toleration effect: " TOLERATION_EFFECT
    read -p "Enter node selector key (press Enter to skip node selector): " NODE_SELECTOR_KEY
    if [[ -n "$NODE_SELECTOR_KEY" ]]; then
        read -p "Enter node selector value: " NODE_SELECTOR_VALUE
    else
        NODE_SELECTOR_VALUE=""
    fi
else
    TOLERATION_VALUE=""
    TOLERATION_OPERATOR=""
    TOLERATION_EFFECT=""
    NODE_SELECTOR_KEY=""
    NODE_SELECTOR_VALUE=""
fi
echo ""

# Check if kubectl is installed
info "Checking if kubectl is installed..."
if ! command -v kubectl &> /dev/null; then
    error "kubectl not found. Please install kubectl."
fi
kubectl version --client || error "Failed to get kubectl version"

# Check if jq is installed
info "Checking if jq is installed..."
if ! command -v jq &> /dev/null; then
    error "jq not found. Please install jq for JSON processing."
fi

# Phase 3: API Registration
info "Registering with OneLens API..."

echo "Registration payload:"
echo "  registration_token: $REGISTRATION_TOKEN"
echo "  cluster_name: $CLUSTER_NAME"
echo "  account_id: $ACCOUNT"
echo "  region: $REGION"
echo "  agent_version: $RELEASE_VERSION"
echo "  API URL: $API_BASE_URL"
echo ""

info "Registering with OneLens API..."
response=$(curl -s -X POST \
  "$API_BASE_URL/v1/kubernetes/registration" \
  -H "Content-Type: application/json" \
  -d "{
    \"registration_token\": \"$REGISTRATION_TOKEN\",
    \"cluster_name\": \"$CLUSTER_NAME\",
    \"account_id\": \"$ACCOUNT\",
    \"region\": \"$REGION\",
    \"agent_version\": \"$RELEASE_VERSION\"
  }")

REGISTRATION_ID=$(echo $response | jq -r '.data.registration_id')
CLUSTER_TOKEN=$(echo $response | jq -r '.data.cluster_token')

if [[ -n "$REGISTRATION_ID" && "$REGISTRATION_ID" != "null" && -n "$CLUSTER_TOKEN" && "$CLUSTER_TOKEN" != "null" ]]; then
    info "Registration successful."
    info "Registration ID: $REGISTRATION_ID"
else
    error "API registration failed. One or both of REGISTRATION_ID and CLUSTER_TOKEN are empty or null."
fi

# Cluster Pod Count and Resource Allocation
info "Analyzing cluster size for resource allocation..."
TOTAL_PODS=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | wc -l)

if [ $? -ne 0 ]; then
    error "Failed to fetch pod details. Please check if Kubernetes is running and kubectl is configured correctly."
fi

info "Total number of pods in the cluster: $TOTAL_PODS"

if [ "$TOTAL_PODS" -lt 100 ]; then
    echo "Setting resources for small cluster (<100 pods)"
    # Prometheus resources
    PROMETHEUS_CPU_REQUEST="300m"
    PROMETHEUS_MEMORY_REQUEST="1188Mi"
    PROMETHEUS_CPU_LIMIT="300m"
    PROMETHEUS_MEMORY_LIMIT="1188Mi"
    
    # OpenCost resources
    OPENCOST_CPU_REQUEST="200m"
    OPENCOST_MEMORY_REQUEST="200Mi"
    OPENCOST_CPU_LIMIT="200m"
    OPENCOST_MEMORY_LIMIT="200Mi"
    
    # OneLens Agent resources
    ONELENS_CPU_REQUEST="400m"
    ONELENS_MEMORY_REQUEST="400Mi"
    ONELENS_CPU_LIMIT="400m"
    ONELENS_MEMORY_LIMIT="400Mi"
    
    # KSM resources
    KSM_CPU_REQUEST="100m"
    KSM_MEMORY_REQUEST="100Mi"
    KSM_CPU_LIMIT="100m"
    KSM_MEMORY_LIMIT="100Mi"
    
    # Pushgateway resources
    PUSHGATEWAY_CPU_REQUEST="100m"
    PUSHGATEWAY_MEMORY_REQUEST="100Mi"
    PUSHGATEWAY_CPU_LIMIT="100m"
    PUSHGATEWAY_MEMORY_LIMIT="100Mi"
    
elif [ "$TOTAL_PODS" -lt 500 ]; then
    echo "Setting resources for medium cluster (100-499 pods)"
    # Prometheus resources
    PROMETHEUS_CPU_REQUEST="350m"
    PROMETHEUS_MEMORY_REQUEST="1771Mi"
    PROMETHEUS_CPU_LIMIT="350m"
    PROMETHEUS_MEMORY_LIMIT="1771Mi"
    
    # OpenCost resources
    OPENCOST_CPU_REQUEST="200m"
    OPENCOST_MEMORY_REQUEST="250Mi"
    OPENCOST_CPU_LIMIT="200m"
    OPENCOST_MEMORY_LIMIT="250Mi"
    
    # OneLens Agent resources
    ONELENS_CPU_REQUEST="500m"
    ONELENS_MEMORY_REQUEST="500Mi"
    ONELENS_CPU_LIMIT="500m"
    ONELENS_MEMORY_LIMIT="500Mi"
    
    # KSM resources
    KSM_CPU_REQUEST="100m"
    KSM_MEMORY_REQUEST="100Mi"
    KSM_CPU_LIMIT="100m"
    KSM_MEMORY_LIMIT="100Mi"

    # Pushgateway resources
    PUSHGATEWAY_CPU_REQUEST="100m"
    PUSHGATEWAY_MEMORY_REQUEST="100Mi"
    PUSHGATEWAY_CPU_LIMIT="100m"
    PUSHGATEWAY_MEMORY_LIMIT="100Mi"
    
elif [ "$TOTAL_PODS" -lt 1000 ]; then
    echo "Setting resources for large cluster (500-999 pods)"
    # Prometheus resources
    PROMETHEUS_CPU_REQUEST="1000m"
    PROMETHEUS_MEMORY_REQUEST="3533Mi"
    PROMETHEUS_CPU_LIMIT="1000m"
    PROMETHEUS_MEMORY_LIMIT="3533Mi"
    
    # OpenCost resources
    OPENCOST_CPU_REQUEST="250m"
    OPENCOST_MEMORY_REQUEST="360Mi"
    OPENCOST_CPU_LIMIT="250m"
    OPENCOST_MEMORY_LIMIT="360Mi"
    
    # OneLens Agent resources
    ONELENS_CPU_REQUEST="500m"
    ONELENS_MEMORY_REQUEST="500Mi"
    ONELENS_CPU_LIMIT="500m"
    ONELENS_MEMORY_LIMIT="500Mi"
    
    # KSM resources
    KSM_CPU_REQUEST="100m"
    KSM_MEMORY_REQUEST="100Mi"
    KSM_CPU_LIMIT="100m"
    KSM_MEMORY_LIMIT="100Mi"

    # Pushgateway resources
    PUSHGATEWAY_CPU_REQUEST="100m"
    PUSHGATEWAY_MEMORY_REQUEST="100Mi"
    PUSHGATEWAY_CPU_LIMIT="100m"
    PUSHGATEWAY_MEMORY_LIMIT="100Mi"
    
elif [ "$TOTAL_PODS" -lt 1500 ]; then
    echo "Setting resources for extra large cluster (1000-1499 pods)"
    # Prometheus resources
    PROMETHEUS_CPU_REQUEST="1150m"
    PROMETHEUS_MEMORY_REQUEST="5400Mi"
    PROMETHEUS_CPU_LIMIT="1150m"
    PROMETHEUS_MEMORY_LIMIT="5400Mi"
    
    # OpenCost resources
    OPENCOST_CPU_REQUEST="250m"
    OPENCOST_MEMORY_REQUEST="450Mi"
    OPENCOST_CPU_LIMIT="250m"
    OPENCOST_MEMORY_LIMIT="450Mi"
    
    # OneLens Agent resources
    ONELENS_CPU_REQUEST="600m"
    ONELENS_MEMORY_REQUEST="600Mi"
    ONELENS_CPU_LIMIT="600m"
    ONELENS_MEMORY_LIMIT="600Mi"
    
    # KSM resources
    KSM_CPU_REQUEST="250m"
    KSM_MEMORY_REQUEST="400Mi"
    KSM_CPU_LIMIT="250m"
    KSM_MEMORY_LIMIT="400Mi"

    # Pushgateway resources
    PUSHGATEWAY_CPU_REQUEST="250m"
    PUSHGATEWAY_MEMORY_REQUEST="400Mi"
    PUSHGATEWAY_CPU_LIMIT="250m"
    PUSHGATEWAY_MEMORY_LIMIT="400Mi"
    
else
    echo "Setting resources for very large cluster (1500+ pods)"
    # Prometheus resources
    PROMETHEUS_CPU_REQUEST="1500m"
    PROMETHEUS_MEMORY_REQUEST="7066Mi"
    PROMETHEUS_CPU_LIMIT="1500m"
    PROMETHEUS_MEMORY_LIMIT="7066Mi"
    
    # OpenCost resources
    OPENCOST_CPU_REQUEST="300m"
    OPENCOST_MEMORY_REQUEST="600Mi"
    OPENCOST_CPU_LIMIT="300m"
    OPENCOST_MEMORY_LIMIT="600Mi"
    
    # OneLens Agent resources
    ONELENS_CPU_REQUEST="700m"
    ONELENS_MEMORY_REQUEST="700Mi"
    ONELENS_CPU_LIMIT="700m"
    ONELENS_MEMORY_LIMIT="700Mi"
    
    # KSM resources
    KSM_CPU_REQUEST="250m"
    KSM_MEMORY_REQUEST="400Mi"
    KSM_CPU_LIMIT="250m"
    KSM_MEMORY_LIMIT="400Mi"

    # Pushgateway resources
    PUSHGATEWAY_CPU_REQUEST="250m"
    PUSHGATEWAY_MEMORY_REQUEST="400Mi"
    PUSHGATEWAY_CPU_LIMIT="250m"
    PUSHGATEWAY_MEMORY_LIMIT="400Mi"
fi


PROMETHEUS_RETENTION="10d"

if [ "$TOTAL_PODS" -lt 100 ]; then
    PROMETHEUS_RETENTION_SIZE="6GB"
    PROMETHEUS_VOLUME_SIZE="10Gi"
elif [ "$TOTAL_PODS" -lt 500 ]; then
    PROMETHEUS_RETENTION_SIZE="12GB"
    PROMETHEUS_VOLUME_SIZE="20Gi"
elif [ "$TOTAL_PODS" -lt 1000 ]; then
    PROMETHEUS_RETENTION_SIZE="20GB"
    PROMETHEUS_VOLUME_SIZE="30Gi"
elif [ "$TOTAL_PODS" -lt 1500 ]; then
    PROMETHEUS_RETENTION_SIZE="30GB"
    PROMETHEUS_VOLUME_SIZE="40Gi"
else
    PROMETHEUS_RETENTION_SIZE="35GB"
    PROMETHEUS_VOLUME_SIZE="50Gi"
fi


# Download configuration values
URL="https://raw.githubusercontent.com/astuto-ai/onelens-installation-scripts/refs/heads/master/globalvalues.yaml"
FILE="globalvalues.yaml"

info "Downloading $FILE from $URL..."

# Use -f to fail silently on server errors and -O to save with original name
if ! curl -s -f -O "$URL"; then
  error "Failed to download $FILE from $URL"
fi

info "Downloaded $FILE successfully."

# Add or update helm repo (--force-update handles existing repos)
info "Adding/updating Helm repository 'onelens'..."
helm repo add onelens https://astuto-ai.github.io/onelens-installation-scripts/ --force-update
helm repo update
info "Preparing Helm installation command..."
CMD="helm upgrade --install onelens-agent -n onelens-agent --create-namespace onelens/onelens-agent \
    --version \"${RELEASE_VERSION}\" \
    -f $FILE \
    --set job.env.imagePullSecrets=\"null\" \
    --set onelens-agent.image.repository=\"$registry_url/onelens-agent\" \
    --set onelens-agent.image.tag=\"v1.8.0\" \
    --set prometheus.server.image.repository=\"$registry_url/prometheus\" \
    --set prometheus.server.image.tag=\"v3.1.0\" \
    --set prometheus.configmapReload.prometheus.image.repository=\"$registry_url/prometheus-config-reloader\" \
    --set prometheus.configmapReload.prometheus.image.tag=\"v0.79.2\" \
    --set prometheus.kube-state-metrics.image.registry=\"$registry_url\" \
    --set prometheus.kube-state-metrics.image.repository=\"kube-state-metrics\" \
    --set prometheus.kube-state-metrics.image.tag=\"v2.14.0\" \
    --set prometheus.prometheus-pushgateway.image.repository=\"$registry_url/pushgateway\" \
    --set prometheus.prometheus-pushgateway.image.tag=\"v1.11.0\" \
    --set prometheus-opencost-exporter.opencost.exporter.image.registry=\"$registry_url\" \
    --set prometheus-opencost-exporter.opencost.exporter.image.repository=\"kubecost-cost-model\" \
    --set onelens-agent.env.CLUSTER_NAME=\"$CLUSTER_NAME\" \
    --set-string onelens-agent.env.ACCOUNT_ID=\"$ACCOUNT\" \
    --set onelens-agent.secrets.API_BASE_URL=\"$API_BASE_URL\" \
    --set onelens-agent.secrets.CLUSTER_TOKEN=\"$CLUSTER_TOKEN\" \
    --set onelens-agent.secrets.REGISTRATION_ID=\"$REGISTRATION_ID\" \
    --set prometheus-opencost-exporter.opencost.exporter.defaultClusterId=\"$CLUSTER_NAME\" \
    --set prometheus.server.persistentVolume.enabled=\"$PVC_ENABLED\" \
    --set-string prometheus.server.retention=\"$PROMETHEUS_RETENTION\" \
    --set-string prometheus.server.retentionSize=\"$PROMETHEUS_RETENTION_SIZE\" \
    --set-string prometheus.server.persistentVolume.size=\"$PROMETHEUS_VOLUME_SIZE\" \
    --set prometheus.server.resources.requests.cpu=\"$PROMETHEUS_CPU_REQUEST\" \
    --set prometheus.server.resources.requests.memory=\"$PROMETHEUS_MEMORY_REQUEST\" \
    --set prometheus.server.resources.limits.cpu=\"$PROMETHEUS_CPU_LIMIT\" \
    --set prometheus.server.resources.limits.memory=\"$PROMETHEUS_MEMORY_LIMIT\" \
    --set prometheus-opencost-exporter.opencost.exporter.resources.requests.cpu=\"$OPENCOST_CPU_REQUEST\" \
    --set prometheus-opencost-exporter.opencost.exporter.resources.requests.memory=\"$OPENCOST_MEMORY_REQUEST\" \
    --set prometheus-opencost-exporter.opencost.exporter.resources.limits.cpu=\"$OPENCOST_CPU_LIMIT\" \
    --set prometheus-opencost-exporter.opencost.exporter.resources.limits.memory=\"$OPENCOST_MEMORY_LIMIT\" \
    --set prometheus.kube-state-metrics.resources.requests.cpu=\"$KSM_CPU_REQUEST\" \
    --set prometheus.kube-state-metrics.resources.requests.memory=\"$KSM_MEMORY_REQUEST\" \
    --set prometheus.kube-state-metrics.resources.limits.cpu=\"$KSM_CPU_LIMIT\" \
    --set prometheus.kube-state-metrics.resources.limits.memory=\"$KSM_MEMORY_LIMIT\" \
    --set prometheus.prometheus-pushgateway.resources.requests.cpu=\"$PUSHGATEWAY_CPU_REQUEST\" \
    --set prometheus.prometheus-pushgateway.resources.requests.memory=\"$PUSHGATEWAY_MEMORY_REQUEST\" \
    --set prometheus.prometheus-pushgateway.resources.limits.cpu=\"$PUSHGATEWAY_CPU_LIMIT\" \
    --set prometheus.prometheus-pushgateway.resources.limits.memory=\"$PUSHGATEWAY_MEMORY_LIMIT\" \
    --set onelens-agent.resources.requests.cpu=\"$ONELENS_CPU_REQUEST\" \
    --set onelens-agent.resources.requests.memory=\"$ONELENS_MEMORY_REQUEST\" \
    --set onelens-agent.resources.limits.cpu=\"$ONELENS_CPU_LIMIT\" \
    --set onelens-agent.resources.limits.memory=\"$ONELENS_MEMORY_LIMIT\""

# Append imagePullSecrets only if REGCRED is not null
if [[ "$REGCRED" != "null" ]]; then
  for path in \
    onelens-agent \
    prometheus \
    prometheus.kube-state-metrics \
    prometheus.prometheus-pushgateway \
    prometheus-opencost-exporter; do
    CMD+=" --set \"$path.imagePullSecrets[0].name=$REGCRED\""
  done
fi

# Append tolerations only if set
if [[ -n "$TOLERATION_KEY" && -n "$TOLERATION_VALUE" && -n "$TOLERATION_OPERATOR" && -n "$TOLERATION_EFFECT" ]]; then
  info "Adding tolerance configurations..."
  for path in \
    prometheus-opencost-exporter.opencost \
    prometheus.server \
    onelens-agent.cronJob \
    prometheus.prometheus-pushgateway \
    prometheus.kube-state-metrics; do
    CMD+=" \
      --set $path.tolerations[0].key=\"$TOLERATION_KEY\" \
      --set $path.tolerations[0].operator=\"$TOLERATION_OPERATOR\" \
      --set $path.tolerations[0].value=\"$TOLERATION_VALUE\" \
      --set $path.tolerations[0].effect=\"$TOLERATION_EFFECT\""
  done
fi

# Append node selectors if set
if [[ -n "$NODE_SELECTOR_KEY" && -n "$NODE_SELECTOR_VALUE" ]]; then
  info "Adding node selector configurations..."
  for path in \
    prometheus-opencost-exporter.opencost \
    prometheus.server \
    onelens-agent.cronJob \
    prometheus.prometheus-pushgateway \
    prometheus.kube-state-metrics; do
    CMD+=" \
      --set $path.nodeSelector.$NODE_SELECTOR_KEY=\"$NODE_SELECTOR_VALUE\""
  done
fi

# Final execution
CMD+=" --wait || { echo \"Error: Helm deployment failed.\"; exit 1; }"

# Run Helm installation
info "Installing OneLens Agent using Helm..."
echo "Running: $CMD"
eval "$CMD"

# Wait for pods to be ready
info "Waiting for OneLens pods to become ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=prometheus-opencost-exporter -n onelens-agent --timeout=300s || {
    error "Pods failed to become ready. Installation Failed."
}

# Update registration status
info "Updating registration status to CONNECTED..."
curl -s -X PUT "$API_BASE_URL/v1/kubernetes/registration" \
    -H "Content-Type: application/json" \
    -d "{
        \"registration_id\": \"$REGISTRATION_ID\",
        \"cluster_token\": \"$CLUSTER_TOKEN\",
        \"status\": \"CONNECTED\"
    }"

# Finalization
info "Installation complete!"
info "To verify deployment: kubectl get pods -n onelens-agent"
