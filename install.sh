#!/bin/bash
echo "Running main installation steps here..."

set -e
trap -p

# Phase 1: Logging Setup
TIMESTAMP=$(date +"%Y%m%d%H%M%S")
LOG_FILE="/tmp/${TIMESTAMP}.log"
touch "$LOG_FILE"
# Capture all script output
exec > >(tee "$LOG_FILE") 2>&1

send_logs() {
    # Send install logs to the backend on failure so they appear in the dashboard.
    # Uses PUT /cluster-version (not POST /registration which requires initial registration fields).
    if [ -z "$REGISTRATION_ID" ] || [ -z "$CLUSTER_TOKEN" ]; then return; fi
    local _api_url="${API_BASE_URL:-https://api-in.onelens.cloud}"
    echo "Sending install logs to API..."
    sleep 0.1
    local log_content
    log_content=$(cat "$LOG_FILE" 2>/dev/null || true)
    if [ ${#log_content} -gt 10000 ]; then
        log_content="[truncated]...${log_content: -9900}"
    fi
    local payload
    payload=$(jq -n \
        --arg reg_id "$REGISTRATION_ID" \
        --arg token "$CLUSTER_TOKEN" \
        --arg logs "$log_content" \
        '{registration_id: $reg_id, cluster_token: $token, update_data: {logs: $logs}}' 2>/dev/null)
    if [ -n "$payload" ]; then
        curl -s --max-time 10 -X PUT "$_api_url/v1/kubernetes/cluster-version" \
            -H "Content-Type: application/json" \
            -d "$payload" >/dev/null 2>&1 || true
    fi
}

# Ensure we send logs on error, and preserve the original exit code
trap 'code=$?; if [ $code -ne 0 ]; then send_logs; fi; exit $code' EXIT

# Phase 2: Environment Variable Setup
: "${RELEASE_VERSION:=2.1.60}"
: "${IMAGE_TAG:=v$RELEASE_VERSION}"
: "${API_BASE_URL:=https://api-in.onelens.cloud}"
: "${PVC_ENABLED:=true}"

# Export the variables so they are available in the environment
export RELEASE_VERSION IMAGE_TAG API_BASE_URL TOKEN PVC_ENABLED

# Phase 3: Prerequisite Checks (moved before registration — needed for upgrade detection)
echo "Step 0: Checking prerequisites..."

# Define versions
HELM_VERSION="v3.13.2"
KUBECTL_VERSION="v1.28.2"

# Detect architecture
ARCH=$(uname -m)

if [[ "$ARCH" == "x86_64" ]]; then
    ARCH_TYPE="amd64"
elif [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
    ARCH_TYPE="arm64"
else
    echo "Unsupported architecture: $ARCH"
    exit 1
fi

echo "Detected architecture: $ARCH_TYPE"

echo "Installing Helm for $ARCH_TYPE..."
curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH_TYPE}.tar.gz" -o helm.tar.gz && \
    tar -xzvf helm.tar.gz && \
    mv linux-${ARCH_TYPE}/helm /usr/local/bin/helm && \
    rm -rf linux-${ARCH_TYPE} helm.tar.gz

helm version

echo "Installing kubectl for $ARCH_TYPE..."
curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH_TYPE}/kubectl" && \
    chmod +x kubectl && \
    mv kubectl /usr/local/bin/kubectl

kubectl version --client

if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl not found. Please install kubectl."
    exit 1
fi

# Phase 3.5: Detect existing installation
# If onelens-agent is already installed, read credentials from the existing secret
# and skip registration. This allows the deployer job to handle both first-time
# installs and upgrades of existing clusters.
IS_UPGRADE=false
EXISTING_SECRET_JSON=$(kubectl get secret onelens-agent-secrets -n onelens-agent -o json 2>/dev/null || true)

if [ -n "$EXISTING_SECRET_JSON" ]; then
    EXISTING_REG_ID=$(echo "$EXISTING_SECRET_JSON" | jq -r '.data.REGISTRATION_ID // empty' 2>/dev/null | base64 -d 2>/dev/null || true)
    EXISTING_CLUSTER_TOKEN=$(echo "$EXISTING_SECRET_JSON" | jq -r '.data.CLUSTER_TOKEN // empty' 2>/dev/null | base64 -d 2>/dev/null || true)

    unset EXISTING_SECRET_JSON

    if [ -n "$EXISTING_REG_ID" ] && [ "$EXISTING_REG_ID" != "null" ] && [ -n "$EXISTING_CLUSTER_TOKEN" ] && [ "$EXISTING_CLUSTER_TOKEN" != "null" ]; then
        IS_UPGRADE=true
        REGISTRATION_ID="$EXISTING_REG_ID"
        CLUSTER_TOKEN="$EXISTING_CLUSTER_TOKEN"
        echo "Existing installation detected. Credentials read from onelens-agent-secrets."
        echo "Skipping registration."
    else
        echo "ERROR: onelens-agent-secrets exists but credentials are incomplete."
        echo "Cannot re-register (API rejects already-connected clusters)."
        echo "To fix: ensure the secret has valid REGISTRATION_ID and CLUSTER_TOKEN values."
        exit 1
    fi
fi

# Phase 4: API Registration (skip for upgrades)
if [ "$IS_UPGRADE" != "true" ]; then
    if [ -z "${REGISTRATION_TOKEN:-}" ]; then
        echo "Error: REGISTRATION_TOKEN is not set"
        exit 1
    else
        echo "REGISTRATION_TOKEN is set"
    fi

    response=$(curl -X POST \
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
        echo "Both REGISTRATION_ID and CLUSTER_TOKEN have values."
    else
        echo "One or both of REGISTRATION_ID and CLUSTER_TOKEN are empty or null."
        exit 1
    fi
    sleep 2
fi

# Phase 5: Namespace Validation
NAMESPACE_EXISTS=false
if kubectl get namespace onelens-agent &> /dev/null; then
    echo "Namespace 'onelens-agent' already exists. Skipping creation."
    NAMESPACE_EXISTS=true
else
    echo "Namespace 'onelens-agent' does not exist. It will be created by helm with --create-namespace flag."
    NAMESPACE_EXISTS=false
fi

# Phase 5.5: Detect Cloud Provider
# Step 1: Always try auto-detection first (most reliable method)
detect_cloud_provider() {
    local cluster_endpoint
    cluster_endpoint=$(kubectl cluster-info 2>/dev/null | grep "Kubernetes control plane" | awk '{print $NF}' | sed 's/\x1b\[[0-9;]*m//g')

    # Primary detection: Check cluster endpoint URL
    # EKS: Always has *.eks.amazonaws.com (100% reliable)
    # AKS: Always has *.azmk8s.io (100% reliable)
    # GKE: Can be added later (*.gke.io pattern)
    if [[ "$cluster_endpoint" =~ \.eks\.amazonaws\.com ]]; then
        echo "AWS"
    elif [[ "$cluster_endpoint" =~ \.azmk8s\.io ]]; then
        echo "AZURE"
    else
        # Fallback detection: Check node provider ID (backup method)
        local node_provider
        node_provider=$(kubectl get nodes -o jsonpath='{.items[0].spec.providerID}' 2>/dev/null || echo "")
        if [[ "$node_provider" =~ ^aws:// ]]; then
            echo "AWS"
        elif [[ "$node_provider" =~ ^azure:// ]]; then
            echo "AZURE"
        else
            echo "UNKNOWN"
        fi
    fi
}

echo "Detecting cloud provider..."
CLOUD_PROVIDER=$(detect_cloud_provider)
echo "Auto-detected cloud provider: $CLOUD_PROVIDER"

# Step 2: If auto-detection failed, check for manual override
if [ "$CLOUD_PROVIDER" = "UNKNOWN" ]; then
    if [ -n "${CLOUD_PROVIDER_OVERRIDE:-}" ]; then
        echo "Auto-detection failed. Using manual override: $CLOUD_PROVIDER_OVERRIDE"
        if [[ "$CLOUD_PROVIDER_OVERRIDE" =~ ^(AWS|AZURE)$ ]]; then
            CLOUD_PROVIDER="$CLOUD_PROVIDER_OVERRIDE"
        else
            echo "ERROR: Invalid CLOUD_PROVIDER_OVERRIDE value: $CLOUD_PROVIDER_OVERRIDE"
            echo "Supported values: AWS, AZURE"
            exit 1
        fi
    fi
fi

# Set storage class configuration based on cloud provider
if [ "$CLOUD_PROVIDER" = "AWS" ]; then
    STORAGE_CLASS_PROVISIONER="ebs.csi.aws.com"
    STORAGE_CLASS_VOLUME_TYPE="gp3"
    echo "Using AWS EBS storage class (provisioner: $STORAGE_CLASS_PROVISIONER, type: $STORAGE_CLASS_VOLUME_TYPE)"
elif [ "$CLOUD_PROVIDER" = "AZURE" ]; then
    STORAGE_CLASS_PROVISIONER="disk.csi.azure.com"
    STORAGE_CLASS_SKU="StandardSSD_LRS"
    echo "Using Azure Disk storage class (provisioner: $STORAGE_CLASS_PROVISIONER, sku: $STORAGE_CLASS_SKU)"
else
    echo "ERROR: Cloud provider auto-detection failed."
    echo "Detected provider: $CLOUD_PROVIDER"
    echo ""
    echo "Supported providers: AWS (EKS), Azure (AKS)"
    echo ""
    echo "To manually specify the cloud provider, set the CLOUD_PROVIDER_OVERRIDE environment variable:"
    echo "  export CLOUD_PROVIDER_OVERRIDE=AWS    # For AWS EKS clusters"
    echo "  export CLOUD_PROVIDER_OVERRIDE=AZURE  # For Azure AKS clusters"
    echo ""
    echo "Note: Auto-detection should work for all standard EKS and AKS clusters."
    echo "If detection failed, please verify: kubectl cluster-info"
    exit 1
fi

# Phase 6: CSI Driver Check and Installation (Cloud-specific)
check_ebs_driver() {
    local retries=1
    local count=0

    echo "Checking if EBS CSI driver is installed..."

    # Check for the cluster-scoped CSIDriver object (works regardless of driver namespace)
    if kubectl get csidriver ebs.csi.aws.com &> /dev/null; then
        echo "EBS CSI driver is installed."
        return 0
    fi

    # Fallback: check for driver pods across all namespaces
    if kubectl get pods --all-namespaces -l app.kubernetes.io/name=aws-ebs-csi-driver --ignore-not-found 2>/dev/null | grep -q "ebs-csi"; then
        echo "EBS CSI driver is installed."
        return 0
    fi

    while [ $count -le $retries ]; do
        echo "EBS CSI driver is not detected. Installing... (Attempt $((count+1))/$((retries+1)))"

        if [ $count -eq 0 ]; then
            helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver
            helm install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver --namespace kube-system --set controller.serviceAccount.create=true
        fi

        echo "Waiting 10 seconds for driver to initialize..."
        sleep 10

        if kubectl get csidriver ebs.csi.aws.com &> /dev/null; then
            echo "EBS CSI driver is installed."
            return 0
        fi

        count=$((count+1))
    done

    echo "EBS CSI driver installation failed after $((retries+1)) attempts."
    return 1
}

check_azure_disk_driver() {
    echo "Checking if Azure Disk CSI driver is installed..."

    # Check if Azure Disk CSI driver is installed (it's typically pre-installed on AKS)
    if kubectl get csidriver disk.csi.azure.com &> /dev/null; then
        echo "Azure Disk CSI driver is installed."
        return 0
    fi

    # Check if default storage class exists (AKS typically has this)
    if kubectl get storageclass | grep -q "disk.csi.azure.com"; then
        echo "Azure Disk storage class is available."
        return 0
    fi

    echo "WARNING: Azure Disk CSI driver may not be fully configured."
    echo "For AKS clusters, this is typically pre-installed."
    echo "If you encounter storage issues, run: az aks update -g <rg> -n <cluster> --enable-disk-driver"
    return 0
}

# Run appropriate CSI driver check based on cloud provider
if [ "$CLOUD_PROVIDER" = "AWS" ]; then
    echo "Running AWS EBS CSI driver check..."
    check_ebs_driver
elif [ "$CLOUD_PROVIDER" = "AZURE" ]; then
    echo "Running Azure Disk CSI driver check..."
    check_azure_disk_driver
else
    echo "Unknown cloud provider. Skipping CSI driver check."
    echo "Please ensure your cluster has a CSI driver installed for persistent storage."
fi

echo "Persistent storage for Prometheus is ENABLED."

# Phase 7: Cluster Pod Count and Resource Allocation

# Source shared resource sizing library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/resource-sizing.sh"

# --- Pod count: count running + pending pods across all namespaces ---
echo "Calculating cluster pod count..."

# Wait for RBAC to propagate — the ClusterRoleBinding granting cluster-wide read
# may not be cached by the API server yet (created moments ago by helm install).
echo "Checking cluster-wide read access..."
_rbac_ready=false
for _rw in 1 2 3 4 5 6; do
    if kubectl get nodes --no-headers >/dev/null 2>&1; then
        _rbac_ready=true
        break
    fi
    echo "Waiting for RBAC propagation (attempt $_rw/6)..."
    sleep 5
done
if [ "$_rbac_ready" != "true" ]; then
    echo "ERROR: Cluster-wide read access not available after 30s."
    echo "The deployer ServiceAccount cannot list nodes/deployments/pods across namespaces."
    echo "Possible causes:"
    echo "  - ClusterRoleBinding not yet propagated (retry install)"
    echo "  - ClusterRole missing required permissions (check deployer RBAC)"
    echo "Aborting install to prevent incorrect resource allocation."
    exit 1
fi

# Count active pods (Running, Pending, ContainerCreating) using server-side field-selector.
# Single kubectl call with --chunk-size=500 keeps memory bounded (~500 pods of JSON at a time)
# regardless of cluster size. Excludes completed/failed job pods.
NUM_PODS=$(kubectl get pods --all-namespaces --no-headers --chunk-size=500 \
    --field-selector='status.phase!=Succeeded,status.phase!=Failed' \
    2>/dev/null | wc -l | tr -d '[:space:]')
TOTAL_PODS=$(( NUM_PODS * 130 / 100 ))  # 30% buffer

if [ "$TOTAL_PODS" -le 0 ]; then
    echo "WARNING: No active pods found. Using minimum tier."
    TOTAL_PODS=1
fi

echo "Cluster pod count: $NUM_PODS active pods"
echo "Adjusted pod count (with 30% buffer): $TOTAL_PODS"

# --- Label density ---
# Hardcoded to 6 (multiplier 1.0x) — no runtime measurement needed.
# Removes the kubectl call that could require large memory on 500+ pod clusters.
# If pods OOM due to high label cardinality, bump memory manually.
AVG_LABELS=6
LABEL_MULTIPLIER=$(get_label_multiplier "$AVG_LABELS")
echo "Label density: $AVG_LABELS (default), multiplier: ${LABEL_MULTIPLIER}x"

# --- GPU node detection ---
GPU_NODE_COUNT=0
TOTAL_GPU_COUNT=0
gpu_capacities=$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.capacity.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null || true)
if [ -n "$gpu_capacities" ]; then
    GPU_NODE_COUNT=$(echo "$gpu_capacities" | awk '$1+0 > 0 {c++} END {print c+0}')
    TOTAL_GPU_COUNT=$(echo "$gpu_capacities" | awk '{s+=$1} END {print s+0}')
fi
if [ "$GPU_NODE_COUNT" -gt 0 ]; then
    echo "GPU nodes: $GPU_NODE_COUNT nodes, $TOTAL_GPU_COUNT GPUs total"
    dcgm_pods=$(kubectl get pods --all-namespaces -l app=nvidia-dcgm-exporter --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
    if [ "$dcgm_pods" -eq 0 ] 2>/dev/null; then
        echo "WARNING: GPU nodes found but NVIDIA DCGM exporter not detected — GPU utilization metrics unavailable"
    else
        echo "NVIDIA DCGM exporter running ($dcgm_pods pods)"
    fi
fi

# --- Air-gapped self-detection ---
# If the deployer pod's image is NOT from public.ecr.aws, this is an air-gapped cluster.
# Extract the private registry URL from the image path for chart pulls and image overrides.
REGISTRY_URL=""
MY_IMAGE=$(kubectl get pod "$HOSTNAME" -n onelens-agent -o jsonpath='{.spec.containers[0].image}' 2>/dev/null || true)
if [ -n "$MY_IMAGE" ] && echo "$MY_IMAGE" | grep -qv "public.ecr.aws"; then
    REGISTRY_URL=$(echo "$MY_IMAGE" | sed 's|/onelens-deployer.*||')
    echo "Air-gapped mode detected. Registry: $REGISTRY_URL"
fi

# --- Chart source ---
if [ -n "$REGISTRY_URL" ]; then
    # Authenticate to ECR for helm OCI pull (kubelet handles Docker image pulls, but helm needs explicit auth)
    _ECR_DOMAIN=$(echo "$REGISTRY_URL" | sed 's|/.*||')
    _ECR_REGION=$(echo "$_ECR_DOMAIN" | sed 's/.*\.ecr\.\(.*\)\.amazonaws\.com/\1/')
    if [ "$_ECR_REGION" != "$_ECR_DOMAIN" ]; then
        echo "Authenticating to ECR: $_ECR_DOMAIN (region: $_ECR_REGION)"
        if ! aws ecr get-login-password --region "$_ECR_REGION" | helm registry login --username AWS --password-stdin "$_ECR_DOMAIN"; then
            echo "ERROR: ECR authentication failed for $_ECR_DOMAIN (region: $_ECR_REGION)."
            echo "Ensure the node IAM role has ecr:GetAuthorizationToken permission."
            exit 1
        fi
    else
        echo "Registry $_ECR_DOMAIN is not ECR — skipping ECR auth"
    fi

    echo "Pulling onelens-agent chart from private OCI registry..."
    helm pull "oci://$REGISTRY_URL/charts/onelens-agent" --version "$RELEASE_VERSION" --untar 2>/dev/null || \
        helm pull "oci://$REGISTRY_URL/charts/onelens-agent" --version "$RELEASE_VERSION"
    if [ -d "onelens-agent" ]; then
        CHART_SOURCE="./onelens-agent"
    else
        CHART_SOURCE="./onelens-agent-${RELEASE_VERSION}.tgz"
    fi
else
    helm repo add onelens https://astuto-ai.github.io/onelens-installation-scripts && helm repo update
    CHART_SOURCE="onelens/onelens-agent"
fi

# --- Resource tier selection ---
select_resource_tier "$TOTAL_PODS"
echo "Setting resources for $TIER cluster ($TOTAL_PODS pods) gpuNodes=$GPU_NODE_COUNT gpus=$TOTAL_GPU_COUNT"

# Apply label density multiplier to memory values for KSM, Prometheus, and onelens-agent
if [ "$LABEL_MULTIPLIER" != "1.0" ]; then
    echo "Applying label density multiplier (${LABEL_MULTIPLIER}x) to memory values..."

    # Prometheus memory
    PROMETHEUS_MEMORY_REQUEST=$(apply_memory_multiplier "$PROMETHEUS_MEMORY_REQUEST" "$LABEL_MULTIPLIER")
    PROMETHEUS_MEMORY_LIMIT=$(apply_memory_multiplier "$PROMETHEUS_MEMORY_LIMIT" "$LABEL_MULTIPLIER")

    # KSM memory
    KSM_MEMORY_REQUEST=$(apply_memory_multiplier "$KSM_MEMORY_REQUEST" "$LABEL_MULTIPLIER")
    KSM_MEMORY_LIMIT=$(apply_memory_multiplier "$KSM_MEMORY_LIMIT" "$LABEL_MULTIPLIER")

    # OneLens Agent memory
    ONELENS_MEMORY_REQUEST=$(apply_memory_multiplier "$ONELENS_MEMORY_REQUEST" "$LABEL_MULTIPLIER")
    ONELENS_MEMORY_LIMIT=$(apply_memory_multiplier "$ONELENS_MEMORY_LIMIT" "$LABEL_MULTIPLIER")

    echo "Adjusted resources after label multiplier:"
    echo "  Prometheus: ${PROMETHEUS_MEMORY_REQUEST} request / ${PROMETHEUS_MEMORY_LIMIT} limit"
    echo "  KSM: ${KSM_MEMORY_REQUEST} request / ${KSM_MEMORY_LIMIT} limit"
    echo "  OneLens Agent: ${ONELENS_MEMORY_REQUEST} request / ${ONELENS_MEMORY_LIMIT} limit"
fi

# Configmap-reload sidecar: fixed small footprint, does not scale with cluster size.
PROMETHEUS_CONFIGMAP_RELOAD_CPU_REQUEST="10m"
PROMETHEUS_CONFIGMAP_RELOAD_MEMORY_REQUEST="32Mi"
PROMETHEUS_CONFIGMAP_RELOAD_CPU_LIMIT="10m"
PROMETHEUS_CONFIGMAP_RELOAD_MEMORY_LIMIT="32Mi"

# --- Retention and volume sizing ---
select_retention_tier "$TOTAL_PODS"

# Phase 8: Helm Deployment
check_var() {
    if [ -z "${!1:-}" ]; then
        echo "Error: $1 is not set"
        exit 1
    fi
}

check_var CLUSTER_TOKEN
check_var REGISTRATION_ID

export TOLERATION_KEY="${TOLERATION_KEY:=}"
export TOLERATION_VALUE="${TOLERATION_VALUE:=}"
export TOLERATION_OPERATOR="${TOLERATION_OPERATOR:=}"
export TOLERATION_EFFECT="${TOLERATION_EFFECT:=}"
export NODE_SELECTOR_KEY="${NODE_SELECTOR_KEY:=}"
export NODE_SELECTOR_VALUE="${NODE_SELECTOR_VALUE:=}"
export IMAGE_PULL_SECRET="${IMAGE_PULL_SECRET:=}"

## EBS Driver custom tag and custom encryption (AWS-specific)
export EBS_TAGS_ENABLED="${EBS_TAGS_ENABLED:=false}"
export EBS_TAGS="${EBS_TAGS:=}"
export EBS_ENCRYPTION_ENABLED="${EBS_ENCRYPTION_ENABLED:=false}"
export EBS_ENCRYPTION_KEY="${EBS_ENCRYPTION_KEY:=}"

## Azure Disk Driver custom tags and encryption (Azure-specific)
export AZURE_DISK_TAGS_ENABLED="${AZURE_DISK_TAGS_ENABLED:=false}"
export AZURE_DISK_TAGS="${AZURE_DISK_TAGS:=}"
export AZURE_DISK_ENCRYPTION_ENABLED="${AZURE_DISK_ENCRYPTION_ENABLED:=false}"
export AZURE_DISK_ENCRYPTION_SET_ID="${AZURE_DISK_ENCRYPTION_SET_ID:=}"
export AZURE_DISK_CACHING_MODE="${AZURE_DISK_CACHING_MODE:=ReadOnly}"

FILE="globalvalues.yaml"

echo "using $FILE"

if [ -f "$FILE" ]; then
    echo "File $FILE exists"
else
    echo "File $FILE does not exist"
    exit 1
fi

# Conditionally add --create-namespace flag only if namespace doesn't exist
CREATE_NS_FLAG=""
if [ "$NAMESPACE_EXISTS" = false ]; then
    CREATE_NS_FLAG="--create-namespace"
fi

# Phase 7.5: Check existing PVC for prometheus data preservation
PVC_NAME="onelens-agent-prometheus-server"
EXISTING_CLAIM_FLAG=""
if kubectl get pvc "$PVC_NAME" -n onelens-agent &>/dev/null; then
    PVC_STATUS=$(kubectl get pvc "$PVC_NAME" -n onelens-agent -o jsonpath='{.status.phase}')
    if [ "$PVC_STATUS" = "Bound" ]; then
        echo "Found existing Bound PVC '$PVC_NAME' — reusing to preserve prometheus metrics data."
        EXISTING_CLAIM_FLAG="--set prometheus.server.persistentVolume.existingClaim=$PVC_NAME"
    else
        echo "Found existing PVC '$PVC_NAME' in '$PVC_STATUS' state — deleting and letting helm create a fresh one."
        kubectl delete pvc "$PVC_NAME" -n onelens-agent --wait=false
    fi
else
    echo "No existing PVC '$PVC_NAME' found — helm will create a new one."
fi

# Phase 7.6: Check helm release state before install
RELEASE_STATUS=$(helm status onelens-agent -n onelens-agent -o json 2>/dev/null | jq -r '.info.status' 2>/dev/null || echo "not-found")
if [ "$RELEASE_STATUS" = "failed" ]; then
    echo "Helm release 'onelens-agent' is in failed state — uninstalling before reinstall."
    helm uninstall onelens-agent -n onelens-agent --wait
    echo "Uninstall complete. Proceeding with fresh install."
fi

CMD="helm upgrade --install onelens-agent -n onelens-agent $CREATE_NS_FLAG $CHART_SOURCE \
    --version \"\${RELEASE_VERSION:=2.1.60}\" \
    --history-max 5 \
    -f $FILE \
    --set onelens-agent.env.CLUSTER_NAME=\"$CLUSTER_NAME\" \
    --set-string onelens-agent.env.ACCOUNT_ID=\"$ACCOUNT\" \
    --set onelens-agent.secrets.API_BASE_URL=\"$API_BASE_URL\" \
    --set onelens-agent.secrets.CLUSTER_TOKEN=\"$CLUSTER_TOKEN\" \
    --set onelens-agent.secrets.REGISTRATION_ID=\"$REGISTRATION_ID\" \
    --set prometheus-opencost-exporter.opencost.exporter.defaultClusterId=\"$CLUSTER_NAME\" \
    --set onelens-agent.image.tag=\"$IMAGE_TAG\" \
    --set prometheus.server.persistentVolume.enabled=$PVC_ENABLED \
    $EXISTING_CLAIM_FLAG \
    --set prometheus.server.resources.requests.cpu=\"$PROMETHEUS_CPU_REQUEST\" \
    --set prometheus.server.resources.requests.memory=\"$PROMETHEUS_MEMORY_REQUEST\" \
    --set prometheus.server.resources.limits.cpu=\"$PROMETHEUS_CPU_LIMIT\" \
    --set prometheus.server.resources.limits.memory=\"$PROMETHEUS_MEMORY_LIMIT\" \
    --set prometheus-opencost-exporter.opencost.exporter.resources.requests.cpu=\"$OPENCOST_CPU_REQUEST\" \
    --set prometheus-opencost-exporter.opencost.exporter.resources.requests.memory=\"$OPENCOST_MEMORY_REQUEST\" \
    --set prometheus-opencost-exporter.opencost.exporter.resources.limits.cpu=\"$OPENCOST_CPU_LIMIT\" \
    --set prometheus-opencost-exporter.opencost.exporter.resources.limits.memory=\"$OPENCOST_MEMORY_LIMIT\" \
    --set onelens-agent.resources.requests.cpu=\"$ONELENS_CPU_REQUEST\" \
    --set onelens-agent.resources.requests.memory=\"$ONELENS_MEMORY_REQUEST\" \
    --set onelens-agent.resources.limits.cpu=\"$ONELENS_CPU_LIMIT\" \
    --set onelens-agent.resources.limits.memory=\"$ONELENS_MEMORY_LIMIT\" \
    --set prometheus.kube-state-metrics.resources.requests.cpu=\"$KSM_CPU_REQUEST\" \
    --set prometheus.kube-state-metrics.resources.requests.memory=\"$KSM_MEMORY_REQUEST\" \
    --set prometheus.kube-state-metrics.resources.limits.cpu=\"$KSM_CPU_LIMIT\" \
    --set prometheus.kube-state-metrics.resources.limits.memory=\"$KSM_MEMORY_LIMIT\" \
    --set prometheus.prometheus-pushgateway.resources.requests.cpu=\"$PROMETHEUS_PUSHGATEWAY_CPU_REQUEST\" \
    --set prometheus.prometheus-pushgateway.resources.requests.memory=\"$PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST\" \
    --set prometheus.prometheus-pushgateway.resources.limits.cpu=\"$PROMETHEUS_PUSHGATEWAY_CPU_LIMIT\" \
    --set prometheus.prometheus-pushgateway.resources.limits.memory=\"$PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT\" \
    --set prometheus.configmapReload.prometheus.resources.requests.cpu=\"$PROMETHEUS_CONFIGMAP_RELOAD_CPU_REQUEST\" \
    --set prometheus.configmapReload.prometheus.resources.requests.memory=\"$PROMETHEUS_CONFIGMAP_RELOAD_MEMORY_REQUEST\" \
    --set prometheus.configmapReload.prometheus.resources.limits.cpu=\"$PROMETHEUS_CONFIGMAP_RELOAD_CPU_LIMIT\" \
    --set prometheus.configmapReload.prometheus.resources.limits.memory=\"$PROMETHEUS_CONFIGMAP_RELOAD_MEMORY_LIMIT\" \
    --set-string prometheus.server.retention=\"$PROMETHEUS_RETENTION\" \
    --set-string prometheus.server.retentionSize=\"$PROMETHEUS_RETENTION_SIZE\" \
    --set-string prometheus.server.persistentVolume.size=\"$PROMETHEUS_VOLUME_SIZE\" \
    --set onelens-agent.storageClass.provisioner=\"$STORAGE_CLASS_PROVISIONER\""

# Air-gapped: override all image sources to private registry.
# Charts that use "{repository}:{tag}" get repository=$REGISTRY_URL/<name>.
# Charts that use "{registry}/{repository}:{tag}" get registry=$REGISTRY_URL + repository=<name>
# to produce the flat path $REGISTRY_URL/<name>:{tag} matching what the migration script pushes.
if [ -n "$REGISTRY_URL" ]; then
    CMD+=" --set onelens-agent.image.repository=$REGISTRY_URL/onelens-agent"
    CMD+=" --set prometheus.server.image.repository=$REGISTRY_URL/prometheus"
    CMD+=" --set prometheus.configmapReload.prometheus.image.repository=$REGISTRY_URL/prometheus-config-reloader"
    CMD+=" --set prometheus-opencost-exporter.opencost.exporter.image.registry=$REGISTRY_URL"
    CMD+=" --set prometheus-opencost-exporter.opencost.exporter.image.repository=opencost"
    CMD+=" --set prometheus.kube-state-metrics.image.registry=$REGISTRY_URL"
    CMD+=" --set prometheus.kube-state-metrics.image.repository=kube-state-metrics"
    CMD+=" --set prometheus.prometheus-pushgateway.image.repository=$REGISTRY_URL/pushgateway"
    CMD+=" --set prometheus.kube-state-metrics.kubeRBACProxy.image.registry=$REGISTRY_URL"
    CMD+=" --set prometheus.kube-state-metrics.kubeRBACProxy.image.repository=kube-rbac-proxy"
    CMD+=" --set onelens-agent.env.REGISTRY_URL=$REGISTRY_URL"
fi

# Add cloud-specific storage class parameters
if [ "$CLOUD_PROVIDER" = "AWS" ]; then
    CMD+=" --set onelens-agent.storageClass.volumeType=\"$STORAGE_CLASS_VOLUME_TYPE\""
elif [ "$CLOUD_PROVIDER" = "AZURE" ]; then
    CMD+=" --set onelens-agent.storageClass.azure.skuName=\"$STORAGE_CLASS_SKU\""
fi

# Multi-AZ storage overrides (EFS for AWS, Azure Files for Azure)
# These override the default block-storage provisioner with a multi-AZ file-storage provisioner,
# eliminating PV AZ-lock scheduling issues on clusters with spot instances or limited AZ capacity.
if [ -n "${EFS_FILESYSTEM_ID:-}" ]; then
    echo "EFS storage configured (filesystem: $EFS_FILESYSTEM_ID). Using multi-AZ storage."
    CMD+=" --set onelens-agent.storageClass.provisioner=efs.csi.aws.com"
    CMD+=" --set onelens-agent.storageClass.efs.fileSystemId=\"$EFS_FILESYSTEM_ID\""
fi
if [ "${AZURE_FILES_ENABLED:-}" = "true" ]; then
    echo "Azure Files storage configured. Using multi-AZ storage."
    CMD+=" --set onelens-agent.storageClass.provisioner=file.csi.azure.com"
fi

# Continue building command

# Append tolerations only if set
# Handle both cases: operator=Exists (value can be empty) and operator=Equal (value required)
if [[ -n "$TOLERATION_KEY" && -n "$TOLERATION_OPERATOR" && -n "$TOLERATION_EFFECT" ]]; then
  # For operator=Exists, value is not required. For other operators, value is required.
  if [[ "$TOLERATION_OPERATOR" == "Exists" ]] || [[ -n "$TOLERATION_VALUE" ]]; then
    for path in \
      prometheus-opencost-exporter.opencost \
      prometheus.server \
      onelens-agent.cronJob \
      prometheus.prometheus-pushgateway \
      prometheus.kube-state-metrics; do
      CMD+=" \
      --set $path.tolerations[0].key=\"$TOLERATION_KEY\" \
      --set $path.tolerations[0].operator=\"$TOLERATION_OPERATOR\""
      # Only set value if operator is not "Exists" and value is provided
      if [[ "$TOLERATION_OPERATOR" != "Exists" && -n "$TOLERATION_VALUE" ]]; then
        CMD+=" \
      --set $path.tolerations[0].value=\"$TOLERATION_VALUE\""
      fi
      CMD+=" \
      --set $path.tolerations[0].effect=\"$TOLERATION_EFFECT\""
    done
  fi
fi

# Append nodeSelector only if set
if [[ -n "$NODE_SELECTOR_KEY" && -n "$NODE_SELECTOR_VALUE" ]]; then
  for path in \
    prometheus-opencost-exporter.opencost \
    prometheus.server \
    onelens-agent.cronJob \
    prometheus.prometheus-pushgateway \
    prometheus.kube-state-metrics; do
    CMD+=" --set $path.nodeSelector.$NODE_SELECTOR_KEY=\"$NODE_SELECTOR_VALUE\""
  done
fi

# Append pod labels to all onelens-agent deployments via a temp values file.
# Using a file avoids shell/eval escaping issues with dots and slashes in label keys.
if [[ -n "${DEPLOYMENT_LABELS:-}" ]]; then
  if command -v jq &>/dev/null; then
    echo "Applying podLabels from DEPLOYMENT_LABELS to onelens-agent components..."
    PODLABELS_FILE=$(mktemp)
    echo "$DEPLOYMENT_LABELS" | jq '{
      prometheus: {
        server: { podLabels: . },
        "kube-state-metrics": { podLabels: . },
        "prometheus-pushgateway": { podLabels: . }
      },
      "onelens-agent": {
        cronJob: { podLabels: . }
      },
      "prometheus-opencost-exporter": {
        podLabels: .
      }
    }' > "$PODLABELS_FILE"
    CMD+=" -f $PODLABELS_FILE"
  else
    echo "Warning: jq not found, skipping podLabels from DEPLOYMENT_LABELS"
  fi
fi

# Append imagePullSecrets only if set
if [[ -n "$IMAGE_PULL_SECRET" ]]; then
  for path in \
    prometheus-opencost-exporter.opencost \
    prometheus.server \
    onelens-agent.cronJob \
    prometheus.prometheus-pushgateway \
    prometheus.kube-state-metrics; do
    CMD+=" --set $path.imagePullSecrets=\"$IMAGE_PULL_SECRET\""
  done
fi

# Append AWS-specific EBS tags only if set and running on AWS
if [[ "$CLOUD_PROVIDER" == "AWS" && "$EBS_TAGS_ENABLED" == "true" && -n "$EBS_TAGS" ]]; then
  echo "Processing EBS tags: $EBS_TAGS"
  # Enable volume tags
  CMD+=" --set onelens-agent.storageClass.volumeTags.enabled=true"

  # Parse comma-separated key=value pairs
  IFS=',' read -ra TAG_PAIRS <<< "$EBS_TAGS"
  for tag_pair in "${TAG_PAIRS[@]}"; do
    # Trim whitespace
    tag_pair=$(echo "$tag_pair" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    # Split on first '=' to handle values that might contain '='
    tag_key=$(echo "$tag_pair" | cut -d'=' -f1)
    tag_value=$(echo "$tag_pair" | cut -d'=' -f2-)

    if [[ -n "$tag_key" && -n "$tag_value" ]]; then
      echo "Adding EBS tag: $tag_key=$tag_value"
      CMD+=" --set onelens-agent.storageClass.volumeTags.tags.$tag_key=\"$tag_value\""
    else
      echo "Warning: Skipping invalid tag format: $tag_pair (expected key=value)"
    fi
  done
fi

# Append AWS-specific encryption only if set and running on AWS
if [[ "$CLOUD_PROVIDER" == "AWS" && "$EBS_ENCRYPTION_ENABLED" == "true" ]]; then
  CMD+=" --set onelens-agent.storageClass.encryption.enabled=true"
  if [[ -n "$EBS_ENCRYPTION_KEY" ]]; then
    CMD+=" --set onelens-agent.storageClass.encryption.kmsKeyId=\"$EBS_ENCRYPTION_KEY\""
  fi
fi

# Append Azure-specific settings
if [[ "$CLOUD_PROVIDER" == "AZURE" ]]; then
  # Append Azure-specific caching mode
  if [[ -n "$AZURE_DISK_CACHING_MODE" ]]; then
    CMD+=" --set onelens-agent.storageClass.azure.cachingMode=\"$AZURE_DISK_CACHING_MODE\""
  fi

  # Append Azure-specific tags only if set
  if [[ "$AZURE_DISK_TAGS_ENABLED" == "true" && -n "$AZURE_DISK_TAGS" ]]; then
    echo "Processing Azure Disk tags: $AZURE_DISK_TAGS"
    CMD+=" --set onelens-agent.storageClass.azure.tags.enabled=true"
    CMD+=" --set onelens-agent.storageClass.azure.tags.value=\"$AZURE_DISK_TAGS\""
  fi

  # Append Azure-specific encryption only if set
  if [[ "$AZURE_DISK_ENCRYPTION_ENABLED" == "true" ]]; then
    CMD+=" --set onelens-agent.storageClass.azure.encryption.enabled=true"
    if [[ -n "$AZURE_DISK_ENCRYPTION_SET_ID" ]]; then
      CMD+=" --set onelens-agent.storageClass.azure.encryption.diskEncryptionSetID=\"$AZURE_DISK_ENCRYPTION_SET_ID\""
    fi
  fi
fi

# Apply same labels to namespace if DEPLOYMENT_LABELS is set (e.g. from globals.labels).
# If the namespace was created by Helm (--create-namespace), it gets these labels; if it already existed, labels are updated.
if [[ -n "${DEPLOYMENT_LABELS:-}" ]] && command -v jq &>/dev/null; then
  echo "Applying labels to namespace onelens-agent from DEPLOYMENT_LABELS..."
  for key in $(echo "$DEPLOYMENT_LABELS" | jq -r 'keys[]'); do
    value=$(echo "$DEPLOYMENT_LABELS" | jq -r --arg k "$key" '.[$k]')
    kubectl label namespace onelens-agent "$key=$value" --overwrite
  done
fi

# Final execution — no --wait. Resources are submitted to the API server and helm
# returns immediately. PV provisioning and pod startup happen asynchronously.
# The patching CronJob (created by helm) handles ongoing pod health and remediation.

# Run helm install
eval "$CMD"
INSTALL_EXIT=$?

if [ $INSTALL_EXIT -ne 0 ]; then
    echo "Helm install failed (exit $INSTALL_EXIT)."
    kubectl get pods -n onelens-agent --no-headers 2>/dev/null || true
    kubectl get events -n onelens-agent --sort-by='.lastTimestamp' --no-headers 2>/dev/null | tail -5 || true
    exit 1
fi

echo ""
echo "Helm install succeeded. Resources submitted to cluster."

# Wait for Prometheus PVC to be bound — proves the PV was provisioned by the CSI driver.
# This is the only hard dependency: without a bound PV, Prometheus can't start and
# patching.sh can't do usage-based sizing. All other pod issues are self-healing.
if [ "$PVC_ENABLED" = "true" ]; then
    echo "Waiting for Prometheus persistent volume to be provisioned..."
    PVC_BOUND=false
    for _pvc_wait in 1 2 3 4 5 6 7 8 9 10 11 12; do
        PVC_STATUS=$(kubectl get pvc onelens-agent-prometheus-server -n onelens-agent \
            -o jsonpath='{.status.phase}' 2>/dev/null || true)
        if [ "$PVC_STATUS" = "Bound" ]; then
            PVC_BOUND=true
            PV_NAME=$(kubectl get pvc onelens-agent-prometheus-server -n onelens-agent \
                -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)
            echo "PVC bound to PV '$PV_NAME' (${_pvc_wait}0s)"
            break
        fi
        echo "  PVC status: ${PVC_STATUS:-not found yet} (attempt $_pvc_wait/12)..."
        sleep 10
    done
    if [ "$PVC_BOUND" != "true" ]; then
        echo "WARNING: PVC not bound after 120s. Prometheus may fail to start."
        echo "Possible causes:"
        echo "  - CSI driver not installed or not running"
        echo "  - StorageClass 'onelens-sc' not created correctly"
        echo "  - Insufficient disk quota in the cloud account"
        echo "The patching job will continue to monitor. Check PVC status with:"
        echo "  kubectl get pvc -n onelens-agent"
    fi
fi
echo ""

# Patch onelens-agent CronJob to add deployment labels to metadata and pod template.
# The private onelens-agent-base chart does not support label injection via values,
# so we patch immediately after Helm install before any scheduled pod runs.
if [[ -n "${DEPLOYMENT_LABELS:-}" ]] && command -v jq &>/dev/null; then
    patch_json=$(echo "$DEPLOYMENT_LABELS" | jq '{
        metadata: {labels: .},
        spec: {jobTemplate: {spec: {template: {metadata: {labels: .}}}}}
    }')
    if kubectl patch cronjob onelens-agent -n onelens-agent --type=merge -p "$patch_json" 2>/dev/null; then
        echo "Patched onelens-agent CronJob with deployment labels."
    fi
fi

# Register cluster as CONNECTED with exponential backoff (up to ~2 min).
# This is a critical signal — without CONNECTED status, the backend won't serve
# patching scripts to the CronJob, leaving the cluster unmanaged.
echo "Registering cluster as connected..."
_connected=false
_backoff=5
for _attempt in 1 2 3 4 5 6; do
    _http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
        -X PUT "$API_BASE_URL/v1/kubernetes/registration" \
        -H "Content-Type: application/json" \
        -d "{
            \"registration_id\": \"$REGISTRATION_ID\",
            \"cluster_token\": \"$CLUSTER_TOKEN\",
            \"status\": \"CONNECTED\"
        }" 2>/dev/null || echo "000")
    if [ "$_http_code" = "200" ] || [ "$_http_code" = "400" ]; then
        # 200 = success, 400 = already CONNECTED (idempotent, fine)
        _connected=true
        echo "Cluster registered (HTTP $_http_code, attempt $_attempt)."
        break
    fi
    echo "  Registration failed (HTTP $_http_code). Retrying in ${_backoff}s (attempt $_attempt/6)..."
    sleep $_backoff
    _backoff=$((_backoff * 2))
done
if [ "$_connected" != "true" ]; then
    echo "WARNING: Could not register cluster as CONNECTED after 6 attempts (~2 min)."
    echo "The patching CronJob exists but the backend may not serve patching scripts."
    echo "Manual fix: re-run install.sh or contact support."
fi

# Quick pod status check — informational only, does not block installation.
echo ""
echo "Checking initial pod status..."
sleep 10
kubectl get pods -n onelens-agent --no-headers 2>/dev/null || true

NOT_READY=$(kubectl get pods -n onelens-agent --no-headers 2>/dev/null \
    | grep -v 'Completed' \
    | awk '{split($2,a,"/"); if (a[1] != a[2] || $3 != "Running") print}' || true)
if [ -z "$NOT_READY" ]; then
    echo ""
    echo "All pods are running and ready."
else
    echo ""
    echo "Some pods are still starting up. This is normal — components like OpenCost"
    echo "depend on Prometheus and may take 1-2 minutes to stabilize."
    echo ""
    echo "The patching job runs every 5 minutes and will automatically:"
    echo "  - Increase memory for any OOMKilled pods"
    echo "  - Restart pods stuck in CrashLoopBackOff"
    echo "  - Right-size all components based on actual cluster usage"
    echo ""
    echo "No manual intervention needed. Check status anytime with:"
    echo "  kubectl get pods -n onelens-agent"
fi

# Phase 9: Finalization and cleanup
echo ""

# Cleanup bootstrap RBAC resources (used only for initial installation)
echo "Cleaning up bootstrap RBAC resources..."
kubectl delete clusterrolebinding onelensdeployer-bootstrap-clusterrolebinding 2>/dev/null || true
kubectl delete clusterrole onelensdeployer-bootstrap-clusterrole 2>/dev/null || true

# Cleanup installation job resources
echo "Cleaning up installation job resources..."
kubectl delete job onelensdeployerjob -n onelens-agent || true
kubectl delete sa onelensdeployerjob-sa -n onelens-agent || true

echo ""
echo "Installation complete. OneLens agent is now active on this cluster."
