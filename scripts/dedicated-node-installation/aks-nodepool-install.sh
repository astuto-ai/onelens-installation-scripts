#!/bin/bash
set -e

# =============================================================================
# OneLens Dedicated Node Pool Installation for Azure AKS
# =============================================================================
# This script creates a dedicated AKS node pool for OneLens workloads with
# taints to prevent other workloads from scheduling on it.
# =============================================================================

# ---------- Loading animation function ----------
show_loading() {
    local message="$1"
    local pid="$2"
    local delay=0.5
    local spinstr='|/-\'
    
    while kill -0 "$pid" 2>/dev/null; do
        local temp=${spinstr#?}
        printf "\r[%c] %s" "$spinstr" "$message"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
    done
    printf "\r[✓] %s\n" "$message"
}

# ---------- Usage check ----------
if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <cluster-name> <resource-group>"
  echo ""
  echo "Arguments:"
  echo "  cluster-name    Name of your AKS cluster"
  echo "  resource-group  Azure resource group containing the cluster"
  echo ""
  echo "Example:"
  echo "  $0 my-aks-cluster my-resource-group"
  exit 1
fi

CLUSTER_NAME=$1
RESOURCE_GROUP=$2
NODEPOOL_NAME="onelenspool"

# ---------- Check Azure CLI ----------
echo "Checking Azure CLI..."
if ! command -v az &> /dev/null; then
    echo "❌ Azure CLI is not installed. Please install it first:"
    echo "   https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
    exit 1
fi

# ---------- Check Azure login ----------
echo "Checking Azure login status..."
if ! az account show &> /dev/null; then
    echo "❌ Not logged in to Azure. Please run 'az login' first."
    exit 1
fi

# ---------- Fetch Azure subscription info ----------
echo "Fetching Azure subscription info..."
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
SUBSCRIPTION_NAME=$(az account show --query name -o tsv)
echo "Detected Azure Subscription: $SUBSCRIPTION_NAME ($SUBSCRIPTION_ID)"

# ---------- Verify cluster exists ----------
echo "Verifying AKS cluster exists..."
CLUSTER_INFO=$(az aks show --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" 2>/dev/null) || {
    echo "❌ Cluster '$CLUSTER_NAME' not found in resource group '$RESOURCE_GROUP'"
    exit 1
}

CLUSTER_LOCATION=$(echo "$CLUSTER_INFO" | jq -r '.location')
echo "Cluster location: $CLUSTER_LOCATION"

# ---------- Initial confirmation ----------
echo ""
echo "================================================="
echo "Initial Configuration:"
echo "Azure Subscription : $SUBSCRIPTION_NAME"
echo "Subscription ID    : $SUBSCRIPTION_ID"
echo "Resource Group     : $RESOURCE_GROUP"
echo "Cluster Name       : $CLUSTER_NAME"
echo "Location           : $CLUSTER_LOCATION"
echo "Node Pool Name     : $NODEPOOL_NAME"
echo "================================================="

read -p "Proceed with this configuration? (yes/no): " INITIAL_CONFIRM
if [[ "$INITIAL_CONFIRM" == "no" ]]; then
  echo "Please rerun the script with the correct parameters."
  exit 0
fi

# ---------- Get kubectl credentials ----------
echo ""
echo "Getting kubectl credentials for cluster..."
az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" --overwrite-existing

# ---------- Compute Configuration ----------
echo ""
echo "================================================="
echo "Compute Configuration:"
echo "================================================="

# ---------- Fetch number of pods ----------
echo "Counting pods in cluster $CLUSTER_NAME..."
NUM_RUNNING=$(kubectl get pods --field-selector=status.phase=Running --all-namespaces 2>/dev/null | wc -l | tr -d '[:space:]')
NUM_PENDING=$(kubectl get pods --field-selector=status.phase=Pending --all-namespaces 2>/dev/null | wc -l | tr -d '[:space:]')
NUM_PODS=$((NUM_RUNNING + NUM_PENDING))
# Add 20% buffer to the pods count
NUM_PODS=$(((NUM_PODS * 12 + 9) / 10))
echo "Detected Pods with additional 20% buffer: $NUM_PODS"

read -p "Type Enter to continue with the detected pods count ($NUM_PODS) or enter a new count: " MODIFY_PODS

if [[ "$MODIFY_PODS" =~ ^[0-9]+$ ]]; then
  NUM_PODS=$MODIFY_PODS
fi

if ! [[ "$NUM_PODS" =~ ^[0-9]+$ ]]; then
  echo "Invalid input. Please enter a positive number."
  exit 1
fi

echo "Pod count set to: $NUM_PODS"

# ---------- Instance type selection ----------
# Azure VM sizes equivalent to AWS t4g instances:
# t4g.medium (2 vCPU, 4GB)  -> Standard_B2s (2 vCPU, 4GB) or Standard_D2as_v4 (ARM)
# t4g.xlarge (4 vCPU, 16GB) -> Standard_B4ms (4 vCPU, 16GB) or Standard_D4as_v4 (ARM)

if [ "$NUM_PODS" -lt 100 ]; then
  VM_SIZE="Standard_B2s"
elif [ "$NUM_PODS" -lt 500 ]; then
  VM_SIZE="Standard_B2s"
elif [ "$NUM_PODS" -lt 1500 ]; then
  VM_SIZE="Standard_B4ms"
else
  VM_SIZE="Standard_B4ms"
fi
echo "Recommended VM Size: $VM_SIZE"

# ---------- OS Type ----------
OS_TYPE="Linux"
echo "Default OS Type: $OS_TYPE"

echo "================================================="

# ---------- User Input for Compute Configuration ----------
echo ""
echo "Please configure compute settings:"
read -p "Enter VM Size [$VM_SIZE] for $NUM_PODS pods: " INPUT_VM_SIZE
if [[ -n "$INPUT_VM_SIZE" ]]; then
  VM_SIZE="$INPUT_VM_SIZE"
fi

echo ""
echo "Final Compute Configuration:"
echo "  VM Size: $VM_SIZE"
echo "  OS Type: $OS_TYPE"

# ---------- Show final config ----------
echo ""
echo "================================================="
echo "Final Configuration:"
echo "Azure Subscription : $SUBSCRIPTION_NAME"
echo "Resource Group     : $RESOURCE_GROUP"
echo "Cluster Name       : $CLUSTER_NAME"
echo "Location           : $CLUSTER_LOCATION"
echo "Node Pool Name     : $NODEPOOL_NAME"
echo "Detected Pods      : $NUM_PODS"
echo "VM Size            : $VM_SIZE"
echo "OS Type            : $OS_TYPE"
echo "================================================="

# ---------- Ask for confirmation ----------
read -p "Proceed with this configuration? (yes/no): " CONFIRM
if [[ "$CONFIRM" == "no" ]]; then
  echo "Please rerun the script with the desired configuration."
  exit 0
fi

echo "Proceeding with node pool creation..."

# ---------- Check if node pool already exists ----------
echo "Checking if node pool '$NODEPOOL_NAME' already exists..."
if az aks nodepool show --resource-group "$RESOURCE_GROUP" --cluster-name "$CLUSTER_NAME" --name "$NODEPOOL_NAME" &>/dev/null; then
    echo "⚠️  Node pool '$NODEPOOL_NAME' already exists."
    read -p "Do you want to delete and recreate it? (yes/no): " RECREATE
    if [[ "$RECREATE" == "yes" ]]; then
        echo "Deleting existing node pool..."
        az aks nodepool delete \
            --resource-group "$RESOURCE_GROUP" \
            --cluster-name "$CLUSTER_NAME" \
            --name "$NODEPOOL_NAME" \
            --yes
        echo "Waiting for deletion to complete..."
        sleep 30
    else
        echo "Keeping existing node pool. Exiting."
        exit 0
    fi
fi

# ---------- Create node pool ----------
echo "Creating node pool $NODEPOOL_NAME in cluster $CLUSTER_NAME..."

az aks nodepool add \
  --resource-group "$RESOURCE_GROUP" \
  --cluster-name "$CLUSTER_NAME" \
  --name "$NODEPOOL_NAME" \
  --node-count 1 \
  --node-vm-size "$VM_SIZE" \
  --os-type "$OS_TYPE" \
  --mode User \
  --node-taints "onelens-workload=agent:NoSchedule" \
  --labels "onelens-workload=agent" \
  --no-wait

# Wait for node pool to be ready
echo "Waiting for node pool to become ready..."
az aks nodepool wait \
    --resource-group "$RESOURCE_GROUP" \
    --cluster-name "$CLUSTER_NAME" \
    --name "$NODEPOOL_NAME" \
    --created &
WAIT_PID=$!

show_loading "Waiting for nodepool $NODEPOOL_NAME to become ready..." "$WAIT_PID"
wait $WAIT_PID || true

# Verify the node pool is running
NODEPOOL_STATUS=$(az aks nodepool show \
    --resource-group "$RESOURCE_GROUP" \
    --cluster-name "$CLUSTER_NAME" \
    --name "$NODEPOOL_NAME" \
    --query provisioningState -o tsv)

if [[ "$NODEPOOL_STATUS" == "Succeeded" ]]; then
    echo "✅ Node pool $NODEPOOL_NAME is now ACTIVE with VM size $VM_SIZE."
else
    echo "⚠️  Node pool status: $NODEPOOL_STATUS. Please check Azure portal for details."
fi

# ---------- Display helm installation command ----------
echo ""
echo "✅ Your agent can now be installed with the following Helm commands:"
echo "======================================================================"
cat <<EOF
helm repo add onelens https://astuto-ai.github.io/onelens-installation-scripts/
helm repo update

helm upgrade --install onelensdeployer onelens/onelensdeployer -n onelens-agent --create-namespace \\
  --set job.env.CLUSTER_NAME=$CLUSTER_NAME \\
  --set job.env.REGION=$CLUSTER_LOCATION \\
  --set-string job.env.ACCOUNT=$SUBSCRIPTION_ID \\
  --set job.env.REGISTRATION_TOKEN="<registration-token>" \\
  --set job.env.NODE_SELECTOR_KEY=onelens-workload \\
  --set job.env.NODE_SELECTOR_VALUE=agent \\
  --set job.env.TOLERATION_KEY=onelens-workload \\
  --set job.env.TOLERATION_VALUE=agent \\
  --set job.env.TOLERATION_OPERATOR=Equal \\
  --set job.env.TOLERATION_EFFECT=NoSchedule \\
  --set job.nodeSelector.onelens-workload=agent \\
  --set 'job.tolerations[0].key=onelens-workload' \\
  --set 'job.tolerations[0].operator=Equal' \\
  --set 'job.tolerations[0].value=agent' \\
  --set 'job.tolerations[0].effect=NoSchedule'
EOF
echo "======================================================================"
