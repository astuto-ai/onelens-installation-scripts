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
    echo "Sending logs to API..."
    echo "***********************************************************************************************"
    sleep 0.1
    cat "$LOG_FILE"

    # Escape double quotes in the log file to ensure valid JSON
    logs=$(sed 's/"/\\"/g' "$LOG_FILE")

    curl -X POST "$API_BASE_URL/v1/kubernetes/registration" \
        -H "Content-Type: application/json" \
        -d "{
            \"registration_id\": \"$REGISTRATION_ID\",
            \"cluster_token\": \"$CLUSTER_TOKEN\",
            \"status\": \"FAILED\",
            \"logs\": \"$logs\"
        }"
}

# Ensure we send logs on error, and preserve the original exit code
trap 'code=$?; if [ $code -ne 0 ]; then send_logs; fi; exit $code' EXIT

# Phase 2: Environment Variable Setup
: "${RELEASE_VERSION:=2.1.33}"
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

    while [ $count -le $retries ]; do
        echo "Checking if EBS CSI driver is installed (Attempt $((count+1))/$((retries+1)))..."

        if kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver --ignore-not-found | grep -q "ebs-csi"; then
            echo "EBS CSI driver is installed."
            return 0
        fi

        if [ $count -eq 0 ]; then
            echo "EBS CSI driver is not installed. Installing..."
            helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver
            helm install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver --namespace kube-system --set controller.serviceAccount.create=true
        fi

        if [ $count -lt $retries ]; then
            echo "Retrying in 10 seconds..."
            sleep 10
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

# --- Pod count: use desired/max replicas from workload controllers ---
echo "Calculating cluster pod capacity from workload controllers..."

# Wait for RBAC to propagate — the ClusterRoleBinding granting cluster-wide read
# may not be cached by the API server yet (created moments ago by helm install).
# Without this, kubectl get deployments --all-namespaces returns 403 silently,
# causing 0 deploy/0 sts counts and wrong tier selection.
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
    echo "This means pod counting will be wrong and resource sizing will be incorrect."
    echo "Possible causes:"
    echo "  - ClusterRoleBinding not yet propagated (retry install)"
    echo "  - ClusterRole missing required permissions (check deployer RBAC)"
    echo "  - Kubernetes API server RBAC cache delay (wait and retry)"
    echo "Aborting install to prevent incorrect resource allocation."
    exit 1
fi

# Collect cluster data using text output (--no-headers) — zero JSON buffering.
# jsonpath truncates on large clusters (1200+ deployments returns only 304).
# Text output with awk is reliable at any scale and uses minimal memory.

# HPAs: extract to temp file for join (needed by both deploy and sts counts)
_HPA_TMP=$(mktemp 2>/dev/null || echo "/tmp/_hpa_$$")
kubectl get hpa --all-namespaces --no-headers 2>/dev/null \
    | awk '{split($3,ref,"/"); print $1 "\t" ref[1] "\t" ref[2] "\t" $(NF-2)}' > "$_HPA_TMP"

# Deployments: HPA-aware count (use maxReplicas if HPA targets it, else desired from READY column)
DEPLOY_PODS=$(kubectl get deployments --all-namespaces --no-headers 2>/dev/null \
    | awk '{split($3,a,"/"); print $1 "\t" $2 "\t" a[2]}' \
    | awk -v kind="Deployment" '
BEGIN { while ((getline line < "'"$_HPA_TMP"'") > 0) { split(line,f,"\t"); if(f[2]==kind) hpa[f[1] "\t" f[3]]=f[4] } }
{ key=$1 "\t" $2; if(key in hpa) total+=hpa[key]; else total+=($3+0) }
END { print total+0 }')

# StatefulSets: HPA-aware count (same logic)
STS_PODS=$(kubectl get statefulsets --all-namespaces --no-headers 2>/dev/null \
    | awk '{split($3,a,"/"); print $1 "\t" $2 "\t" a[2]}' \
    | awk -v kind="StatefulSet" '
BEGIN { while ((getline line < "'"$_HPA_TMP"'") > 0) { split(line,f,"\t"); if(f[2]==kind) hpa[f[1] "\t" f[3]]=f[4] } }
{ key=$1 "\t" $2; if(key in hpa) total+=hpa[key]; else total+=($3+0) }
END { print total+0 }')

rm -f "$_HPA_TMP"

# DaemonSets: sum DESIRED column (col 3 in text output)
DS_PODS=$(kubectl get daemonsets --all-namespaces --no-headers 2>/dev/null \
    | awk '{total+=$3} END{print total+0}')

# Pod counts calculated above via text+awk (no library functions needed)
DESIRED_PODS=$((DEPLOY_PODS + STS_PODS + DS_PODS))
TOTAL_PODS=$(calculate_total_pods "$DEPLOY_PODS" "$STS_PODS" "$DS_PODS")

# Fallback: if desired pods calculation returned 0 or failed, use running pod count
if [ "$TOTAL_PODS" -le 0 ]; then
    echo "WARNING: Could not calculate desired pods from workload controllers. Falling back to running pod count."
    NUM_RUNNING=$(kubectl get pods --field-selector=status.phase=Running --all-namespaces --no-headers | wc -l | tr -d '[:space:]')
    NUM_PENDING=$(kubectl get pods --field-selector=status.phase=Pending --all-namespaces --no-headers | wc -l | tr -d '[:space:]')
    TOTAL_PODS=$((NUM_RUNNING + NUM_PENDING))
fi

echo "Cluster pod capacity: $DESIRED_PODS desired (Deployments: $DEPLOY_PODS, StatefulSets: $STS_PODS, DaemonSets: $DS_PODS)"
echo "Adjusted pod count (with 25% buffer): $TOTAL_PODS"

# --- Label density measurement ---
# Use custom-columns to avoid fetching full pod JSON (which OOMs kubectl on 1200+ pod clusters).
# custom-columns streams labels only. Sample 100 pods — gives same average without memory cost.
echo "Measuring label density across pods..."
AVG_LABELS=$(kubectl get pods --all-namespaces --no-headers -o custom-columns='LABELS:.metadata.labels' 2>/dev/null \
    | grep -v '<none>' \
    | head -100 \
    | sed 's/^map\[//; s/\]$//' \
    | awk '{s+=NF; n++} END{if(n>0) printf "%d", s/n; else print 0}')
if [ -z "$AVG_LABELS" ] || [ "$AVG_LABELS" -le 0 ] 2>/dev/null; then
    AVG_LABELS="0"
fi
LABEL_MULTIPLIER=$(get_label_multiplier "$AVG_LABELS")

echo "Average labels per pod: $AVG_LABELS, Label memory multiplier: ${LABEL_MULTIPLIER}x"

helm repo add onelens https://astuto-ai.github.io/onelens-installation-scripts && helm repo update

# --- Resource tier selection ---
select_resource_tier "$TOTAL_PODS"
echo "Setting resources for $TIER cluster ($TOTAL_PODS pods)"

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

CMD="helm upgrade --install onelens-agent -n onelens-agent $CREATE_NS_FLAG onelens/onelens-agent \
    --version \"\${RELEASE_VERSION:=2.1.33}\" \
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

# Add cloud-specific storage class parameters
if [ "$CLOUD_PROVIDER" = "AWS" ]; then
    CMD+=" --set onelens-agent.storageClass.volumeType=\"$STORAGE_CLASS_VOLUME_TYPE\""
elif [ "$CLOUD_PROVIDER" = "AZURE" ]; then
    CMD+=" --set onelens-agent.storageClass.azure.skuName=\"$STORAGE_CLASS_SKU\""
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

# Final execution
CMD+=" --wait --timeout=10m"

# _detect_pod_failure — check if any onelens pod is failing after install.
# Scans all non-Completed pods. Returns 0 (true) if a failing pod is found.
# Sets: _FAIL_POD, _FAIL_COMPONENT, _FAIL_REASON ("oom" or "other"), _FAIL_DIAG
_detect_pod_failure() {
    _FAIL_POD=""
    _FAIL_COMPONENT=""
    _FAIL_REASON=""
    _FAIL_DIAG=""

    local pods_raw
    pods_raw=$(kubectl get pods -n onelens-agent --no-headers 2>/dev/null \
        | grep -vE 'Completed|Running' || true)
    # Also check Running pods with high restart count that are NOT fully Ready.
    # A Running+Ready pod with restarts has recovered from a transient issue — skip it.
    # A Running but not Ready pod with restarts is still crash-looping.
    pods_raw="$pods_raw
$(kubectl get pods -n onelens-agent --no-headers 2>/dev/null \
    | awk '$4+0 >= 2 {split($2,a,"/"); if(a[1]!=a[2]) print}' || true)"

    if [ -z "$(echo "$pods_raw" | tr -d '[:space:]')" ]; then return 1; fi

    # Check each known component in dependency order.
    # Prometheus must be checked first — OpenCost depends on Prometheus.
    # If Prometheus is not Running+Ready, skip OpenCost (it will fail regardless).
    local _prom_ready=false
    local _prom_pod_check
    _prom_pod_check=$(kubectl get pods -n onelens-agent --no-headers 2>/dev/null \
        | awk '/prometheus-server/{print $2, $3; exit}' || true)
    if echo "$_prom_pod_check" | grep -q 'Running' && echo "$_prom_pod_check" | grep -qE '^2/2|^1/1'; then
        _prom_ready=true
    fi

    local component pod_pattern container_name
    for component in prometheus-server kube-state-metrics prometheus-opencost-exporter prometheus-pushgateway; do
        # Skip OpenCost check if Prometheus is not ready — OpenCost depends on Prometheus
        if [ "$component" = "prometheus-opencost-exporter" ] && [ "$_prom_ready" != "true" ]; then
            continue
        fi

        local pod_name pod_status restart_count term_reason pod_logs events

        pod_name=$(echo "$pods_raw" | awk -v p="$component" '$1 ~ p {print $1; exit}' || true)
        if [ -z "$pod_name" ]; then continue; fi

        pod_status=$(kubectl get pod "$pod_name" -n onelens-agent \
            -o jsonpath='{.status.phase}' 2>/dev/null || true)

        # Get the main container name (may differ from pod pattern)
        container_name=$(kubectl get pod "$pod_name" -n onelens-agent \
            -o jsonpath='{.spec.containers[0].name}' 2>/dev/null || echo "$component")
        restart_count=$(kubectl get pod "$pod_name" -n onelens-agent \
            -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
        term_reason=$(kubectl get pod "$pod_name" -n onelens-agent \
            -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}' 2>/dev/null || true)
        if [ -z "$term_reason" ]; then
            term_reason=$(kubectl get pod "$pod_name" -n onelens-agent \
                -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}' 2>/dev/null || true)
        fi

        # Skip pods that are Running with low restarts (healthy)
        if [ "$pod_status" = "Running" ] && [ "$restart_count" -lt 2 ] 2>/dev/null; then continue; fi

        events=$(kubectl get events -n onelens-agent --field-selector "involvedObject.name=$pod_name" --no-headers 2>/dev/null | tail -5 || true)
        pod_logs=$(kubectl logs "$pod_name" -n onelens-agent -c "$container_name" --previous --tail=30 2>/dev/null || \
            kubectl logs "$pod_name" -n onelens-agent -c "$container_name" --tail=30 2>/dev/null || true)

        _FAIL_POD="$pod_name"
        _FAIL_COMPONENT="$component"

        # Classify failure
        if echo "$events" | grep -qiE 'FailedScheduling.*Insufficient'; then
            _FAIL_REASON="other"
            _FAIL_DIAG="pod=$pod_name component=$component reason=FailedScheduling (node can't fit resource request)"
        elif [ "$term_reason" = "OOMKilled" ] || echo "$pod_logs" | grep -qiE 'out of memory|cannot allocate memory|MemoryError' 2>/dev/null; then
            _FAIL_REASON="oom"
            _FAIL_DIAG="pod=$pod_name component=$component restarts=$restart_count reason=OOMKilled"
        elif echo "$pod_logs" | grep -qiE 'wal|replay|checkpoint' 2>/dev/null && [ "$restart_count" -ge 2 ] 2>/dev/null; then
            _FAIL_REASON="oom"
            _FAIL_DIAG="pod=$pod_name component=$component restarts=$restart_count reason=crash_during_wal_replay"
        else
            _FAIL_REASON="other"
            local snippet
            snippet=$(echo "$pod_logs" | tail -3 | tr '\n' ' ' | cut -c1-150)
            _FAIL_DIAG="pod=$pod_name component=$component restarts=$restart_count reason=$term_reason logs=$snippet"
        fi

        return 0  # Found a failing pod
    done

    return 1  # No failing pods
}

# _bump_component_memory — bump the memory variable for a component by multiplier.
# Sets the request and limit variables. Returns the --set flags for helm retry.
_bump_component_memory() {
    local component="$1"
    local old_mem new_mem cap set_flags=""

    case "$component" in
        prometheus-server)
            old_mem="$PROMETHEUS_MEMORY_LIMIT"
            cap="$_USAGE_CAP_PROM_MEM"
            new_mem=$(calculate_wal_oom_memory "$old_mem" "$cap")  # 1.5x for WAL
            PROMETHEUS_MEMORY_REQUEST="$new_mem"
            PROMETHEUS_MEMORY_LIMIT="$new_mem"
            set_flags="--set prometheus.server.resources.requests.memory=\"$new_mem\" --set prometheus.server.resources.limits.memory=\"$new_mem\""
            ;;
        kube-state-metrics)
            old_mem="$KSM_MEMORY_LIMIT"
            cap="$_USAGE_CAP_KSM_MEM"
            new_mem=$(calculate_wal_oom_memory "$old_mem" "$cap")  # 1.5x
            KSM_MEMORY_REQUEST="$new_mem"
            KSM_MEMORY_LIMIT="$new_mem"
            set_flags="--set prometheus.kube-state-metrics.resources.requests.memory=\"$new_mem\" --set prometheus.kube-state-metrics.resources.limits.memory=\"$new_mem\""
            ;;
        prometheus-opencost-exporter)
            old_mem="$OPENCOST_MEMORY_LIMIT"
            cap="$_USAGE_CAP_OPENCOST_MEM"
            new_mem=$(calculate_wal_oom_memory "$old_mem" "$cap")  # 1.5x
            OPENCOST_MEMORY_REQUEST="$new_mem"
            OPENCOST_MEMORY_LIMIT="$new_mem"
            set_flags="--set prometheus-opencost-exporter.opencost.exporter.resources.requests.memory=\"$new_mem\" --set prometheus-opencost-exporter.opencost.exporter.resources.limits.memory=\"$new_mem\""
            ;;
        prometheus-pushgateway)
            old_mem="$PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT"
            new_mem=$(apply_memory_multiplier "$old_mem" 1.25)
            # Pushgateway cap is small — 256Mi is more than enough
            local new_mi=$(_memory_to_mi "$new_mem")
            if [ "$new_mi" -gt 256 ] 2>/dev/null; then new_mem="256Mi"; fi
            PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST="$new_mem"
            PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT="$new_mem"
            set_flags="--set prometheus.prometheus-pushgateway.resources.requests.memory=\"$new_mem\" --set prometheus.prometheus-pushgateway.resources.limits.memory=\"$new_mem\""
            ;;
    esac

    echo "$old_mem $new_mem $set_flags"
}

# Run helm install with pod failure retry loop.
# If any pod OOMs after install, bump that component's memory and retry.
# Handles all components (Prometheus, KSM, OpenCost, Pushgateway), not just Prometheus.
_INSTALL_RETRIES=0
_MAX_INSTALL_RETRIES=3

eval "$CMD"
INSTALL_EXIT=$?

while true; do
    if [ $INSTALL_EXIT -eq 0 ]; then
        # Install succeeded — poll for pods to stabilize before declaring failure.
        # OpenCost crashes on startup (Prometheus not ready yet) and recovers in 30-60s.
        # A genuine OOM will still be failing after 5 minutes.
        _pods_ok=false
        for _poll in 1 2 3 4 5; do
            echo "Checking pod health (attempt $_poll/5)..."
            sleep 60
            if ! _detect_pod_failure; then
                _pods_ok=true
                break
            fi
            echo "  Pods not stable yet: $_FAIL_DIAG"
        done
        if [ "$_pods_ok" = "true" ]; then
            break  # All pods healthy
        fi
        echo "Pods still failing after 5 min: $_FAIL_DIAG"
    else
        echo "Helm install failed (exit $INSTALL_EXIT)."
        if ! _detect_pod_failure; then
            echo "No specific pod failure detected. Pod status:"
            kubectl get pods -n onelens-agent --no-headers 2>/dev/null || true
            kubectl get events -n onelens-agent --sort-by='.lastTimestamp' --no-headers 2>/dev/null | tail -5 || true
            exit 1
        fi
        echo "Pod failure detected: $_FAIL_DIAG"
    fi

    # Only retry for OOM. Config errors, FailedScheduling, image pull won't be fixed by bumping memory.
    if [ "$_FAIL_REASON" != "oom" ]; then
        echo "Failure is not memory-related (reason=$_FAIL_REASON). Not retrying."
        if [ -n "$_FAIL_POD" ]; then
            echo "--- Pod logs ---"
            kubectl logs "$_FAIL_POD" -n onelens-agent --previous --tail=20 2>/dev/null || \
                kubectl logs "$_FAIL_POD" -n onelens-agent --tail=20 2>/dev/null || true
            echo "--- Events ---"
            kubectl get events -n onelens-agent --field-selector "involvedObject.name=$_FAIL_POD" --no-headers 2>/dev/null | tail -5 || true
        fi
        exit 1
    fi

    # Check retry limit
    if [ "$_INSTALL_RETRIES" -ge "$_MAX_INSTALL_RETRIES" ]; then
        echo "OOM: exhausted $_MAX_INSTALL_RETRIES retries. Component=$_FAIL_COMPONENT"
        echo "--- Final pod status ---"
        kubectl get pods -n onelens-agent --no-headers 2>/dev/null || true
        exit 1
    fi

    # Bump the failing component's memory
    _bump_result=$(_bump_component_memory "$_FAIL_COMPONENT")
    _old_mem=$(echo "$_bump_result" | awk '{print $1}')
    _new_mem=$(echo "$_bump_result" | awk '{print $2}')
    _set_flags=$(echo "$_bump_result" | cut -d' ' -f3-)

    if [ "$_new_mem" = "$_old_mem" ]; then
        echo "$_FAIL_COMPONENT OOM: at memory cap ($_old_mem). Cannot bump further."
        exit 1
    fi

    _INSTALL_RETRIES=$((_INSTALL_RETRIES + 1))
    echo "OOM recovery (retry $_INSTALL_RETRIES/$_MAX_INSTALL_RETRIES): $_FAIL_COMPONENT memory $_old_mem -> $_new_mem"

    RETRY_CMD="$CMD --timeout=3m $_set_flags"
    eval "$RETRY_CMD"
    INSTALL_EXIT=$?
done

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
    else
        echo "Warning: Could not patch onelens-agent CronJob labels (resource may not exist yet)."
    fi
fi

kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=prometheus-opencost-exporter -n onelens-agent --timeout=800s || {
    echo "Error: Pods failed to become ready."
    echo "Installation Failed."
    false
}

# Verify all pods in the namespace are running and ready
echo "Verifying all pods in onelens-agent namespace..."
STABLE=false
for i in 1 2 3 4 5 6; do
    sleep 10
    NOT_READY=$(kubectl get pods -n onelens-agent --no-headers 2>/dev/null \
        | grep -v 'Completed' \
        | awk '{split($2,a,"/"); if (a[1] != a[2] || $3 != "Running") print}' || true)
    if [ -z "$NOT_READY" ]; then
        STABLE=true
        echo "All pods stable after $((i * 10))s"
        break
    fi
    echo "Check $i/6: some pods not ready yet..."
done
if [ "$STABLE" != "true" ]; then
    echo "WARNING: Not all pods stabilized within 60s. Current status:"
    kubectl get pods -n onelens-agent --no-headers 2>/dev/null || true
fi

# Phase 9: Finalization
echo "Deployment complete."

curl -X PUT "$API_BASE_URL/v1/kubernetes/registration" \
    -H "Content-Type: application/json" \
    -d "{
        \"registration_id\": \"$REGISTRATION_ID\",
        \"cluster_token\": \"$CLUSTER_TOKEN\",
        \"status\": \"CONNECTED\"
    }"
sleep 60

echo "To verify deployment: kubectl get pods -n onelens-agent"

# Cleanup bootstrap RBAC resources (used only for initial installation)
echo "Cleaning up bootstrap RBAC resources..."
kubectl delete clusterrolebinding onelensdeployer-bootstrap-clusterrolebinding 2>/dev/null || true
kubectl delete clusterrole onelensdeployer-bootstrap-clusterrole 2>/dev/null || true

# Cleanup installation job resources
echo "Cleaning up installation job resources..."
kubectl delete job onelensdeployerjob -n onelens-agent || true
kubectl delete sa onelensdeployerjob-sa -n onelens-agent || true

echo "Cleanup complete. Ongoing RBAC resources retained for cronjob updates."
