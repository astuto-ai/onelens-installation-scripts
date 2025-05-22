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
    local var_name=$1
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
registry_url="376129875853.dkr.ecr.us-east-1.amazonaws.com"

# Take user input for required variables
echo "Please provide the following information:"
REGISTRATION_TOKEN=$(prompt_with_validation "REGISTRATION_TOKEN" "Enter registration token" "Registration token cannot be empty")
CLUSTER_NAME=$(prompt_with_validation "CLUSTER_NAME" "Enter cluster name" "Cluster name cannot be empty")
ACCOUNT=$(prompt_with_validation "ACCOUNT" "Enter account ID" "Account ID cannot be empty")
REGION=$(prompt_with_validation "REGION" "Enter region" "Region cannot be empty")
RELEASE_VERSION=$(prompt_with_validation "RELEASE_VERSION" "Enter release version" "Release version cannot be empty")

# Optional parameters with defaults
echo ""
info "Optional Parameters (press Enter to use defaults):"
read -p "Enter toleration key (optional): " TOLERATION_KEY
read -p "Enter toleration value (optional): " TOLERATION_VALUE
read -p "Enter toleration operator (optional): " TOLERATION_OPERATOR
read -p "Enter toleration effect (optional): " TOLERATION_EFFECT
read -p "Enter node selector key (optional): " NODE_SELECTOR_KEY
read -p "Enter node selector value (optional): " NODE_SELECTOR_VALUE

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

# Download configuration values
URL="https://raw.githubusercontent.com/astuto-ai/onelens-installation-scripts/refs/heads/master/globalvalues.yaml"
FILE="globalvalues.yaml"

info "Downloading $FILE from $URL..."

# Use -f to fail silently on server errors and -O to save with original name
if ! curl -s -f -O "$URL"; then
  error "Failed to download $FILE from $URL"
fi

info "Downloaded $FILE successfully."

# Prepare Helm command
info "Preparing Helm installation command..."
CMD="helm upgrade --install onelens-agent -n onelens-agent --create-namespace onelens/onelens-agent \
    --version \"${RELEASE_VERSION}\" \
    -f $FILE \
    --set job.env.imagePullSecrets="null" \
    --set onelens-agent.image.repository="609916866699.dkr.ecr.ap-southeast-1.amazonaws.com/onelens-agent" \
    --set onelens-agent.image.tag="v0.1.1-beta.2" \
    --set prometheus.server.image.repository="609916866699.dkr.ecr.ap-southeast-1.amazonaws.com/prometheus" \
    --set prometheus.server.image.tag="v3.1.0" \
    --set prometheus.configmapReload.prometheus.image.repository="609916866699.dkr.ecr.ap-southeast-1.amazonaws.com/prometheus-config-reloader" \
    --set prometheus.configmapReload.prometheus.image.tag="v0.79.2" \
    --set prometheus.kube-state-metrics.image.registry="609916866699.dkr.ecr.ap-southeast-1.amazonaws.com" \
    --set prometheus.kube-state-metrics.image.repository="kube-state-metrics" \
    --set prometheus.kube-state-metrics.image.tag="v2.14.0" \
    --set prometheus.prometheus-pushgateway.image.repository="609916866699.dkr.ecr.ap-southeast-1.amazonaws.com/pushgateway" \
    --set prometheus.prometheus-pushgateway.image.tag="v1.11.0" \
    --set prometheus-opencost-exporter.opencost.exporter.image.registry="609916866699.dkr.ecr.ap-southeast-1.amazonaws.com" \
    --set prometheus-opencost-exporter.opencost.exporter.image.repository="kubecost-cost-model" \
    --set "onelens-agent.imagePullSecrets[0].name=regcred" \
    --set "prometheus.imagePullSecrets[0].name=regcred" \
    --set "prometheus.kube-state-metrics.imagePullSecrets[0].name=regcred" \
    --set "prometheus.prometheus-pushgateway.imagePullSecrets[0].name=regcred" \
    --set "prometheus-opencost-exporter.imagePullSecrets[0].name=regcred"
    --set onelens-agent.env.CLUSTER_NAME=\"$CLUSTER_NAME\" \
    --set-string onelens-agent.env.ACCOUNT_ID=\"$ACCOUNT\" \
    --set onelens-agent.secrets.API_BASE_URL=\"$API_BASE_URL\" \
    --set onelens-agent.secrets.CLUSTER_TOKEN=\"$CLUSTER_TOKEN\" \
    --set onelens-agent.secrets.REGISTRATION_ID=\"$REGISTRATION_ID\" \
    --set prometheus-opencost-exporter.opencost.exporter.defaultClusterId=\"$CLUSTER_NAME\" \
    --set prometheus.server.persistentVolume.enabled=\"$PVC_ENABLED\""

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
    CMD+=" --set $path.nodeSelector.$NODE_SELECTOR_KEY=\"$NODE_SELECTOR_VALUE\""
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
