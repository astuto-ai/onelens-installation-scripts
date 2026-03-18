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
: "${RELEASE_VERSION:=2.1.24}"
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

# Collect cluster data (kubectl calls stay here; logic is in the library)
HPA_JSON=$(kubectl get hpa --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')
DEPLOY_JSON=$(kubectl get deployments --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')
STS_JSON=$(kubectl get statefulsets --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')
DS_JSON=$(kubectl get daemonsets --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')

# Calculate pod counts using library functions
DEPLOY_PODS=$(count_deploy_pods "$DEPLOY_JSON" "$HPA_JSON")
STS_PODS=$(count_sts_pods "$STS_JSON" "$HPA_JSON")
DS_PODS=$(count_ds_pods "$DS_JSON")
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
echo "Measuring label density across pods..."
PODS_JSON=$(kubectl get pods --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')
AVG_LABELS=$(calculate_avg_labels "$PODS_JSON")
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
    --version \"\${RELEASE_VERSION:=2.1.24}\" \
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

# _detect_prom_startup_failure — check if Prometheus is repeatedly failing to start.
# Returns 0 (true) if Prometheus is crash-looping/erroring.
# Sets _PROM_FAIL_DIAG with details and _PROM_FAIL_REASON:
#   "oom"   — OOMKilled or memory allocation failure, bump will likely help
#   "other" — config error, image issue, etc. bump won't help
_detect_prom_startup_failure() {
    _PROM_FAIL_DIAG=""
    _PROM_FAIL_REASON=""
    local prom_pod pod_status restart_count term_reason prom_logs

    prom_pod=$(kubectl get pods -n onelens-agent --no-headers 2>/dev/null \
        | awk '/prometheus-server/{print $1; exit}' || true)
    if [ -z "$prom_pod" ]; then return 1; fi

    pod_status=$(kubectl get pod "$prom_pod" -n onelens-agent \
        -o jsonpath='{.status.phase}' 2>/dev/null || true)
    restart_count=$(kubectl get pod "$prom_pod" -n onelens-agent \
        -o jsonpath='{.status.containerStatuses[?(@.name=="prometheus-server")].restartCount}' 2>/dev/null || echo "0")
    term_reason=$(kubectl get pod "$prom_pod" -n onelens-agent \
        -o jsonpath='{.status.containerStatuses[?(@.name=="prometheus-server")].lastState.terminated.reason}' 2>/dev/null || true)

    if [ "$restart_count" -lt 2 ] 2>/dev/null && [ "$pod_status" = "Running" ]; then
        return 1
    fi

    prom_logs=$(kubectl logs "$prom_pod" -n onelens-agent -c prometheus-server --previous --tail=50 2>/dev/null || true)
    local events
    events=$(kubectl get events -n onelens-agent --field-selector "involvedObject.name=$prom_pod" --no-headers 2>/dev/null | tail -10 || true)

    # Check for FailedScheduling — bumping memory won't help if nodes can't fit the request
    if echo "$events" | grep -qiE 'FailedScheduling.*Insufficient memory'; then
        _PROM_FAIL_REASON="other"
        _PROM_FAIL_DIAG="pod=$prom_pod status=$pod_status reason=FailedScheduling_insufficient_memory (requested=$PROMETHEUS_MEMORY_LIMIT, node can't fit)"
        return 0
    fi

    if [ "$term_reason" = "OOMKilled" ]; then
        _PROM_FAIL_REASON="oom"
        _PROM_FAIL_DIAG="pod=$prom_pod status=$pod_status restarts=$restart_count reason=OOMKilled"
    elif echo "$prom_logs" | grep -qiE 'out of memory|cannot allocate|mmap.*enomem'; then
        _PROM_FAIL_REASON="oom"
        _PROM_FAIL_DIAG="pod=$prom_pod status=$pod_status restarts=$restart_count reason=memory_allocation_failure"
    elif echo "$prom_logs" | grep -qiE 'wal|replay|checkpoint' && [ "$restart_count" -ge 2 ] 2>/dev/null; then
        _PROM_FAIL_REASON="oom"
        _PROM_FAIL_DIAG="pod=$prom_pod status=$pod_status restarts=$restart_count reason=crash_during_wal_replay"
    else
        _PROM_FAIL_REASON="other"
        local snippet
        snippet=$(echo "$prom_logs" | tail -5 | tr '\n' ' ' | cut -c1-200)
        _PROM_FAIL_DIAG="pod=$prom_pod status=$pod_status restarts=$restart_count reason=$term_reason logs=$snippet"
    fi

    if echo "$prom_logs" | grep -qiE 'wal|replay|checkpoint'; then
        _PROM_FAIL_DIAG="$_PROM_FAIL_DIAG [WAL replay in logs]"
    fi

    return 0
}

# Run helm install with Prometheus startup failure retry loop
_PROM_RETRIES=0
_MAX_PROM_RETRIES=3

eval "$CMD"
INSTALL_EXIT=$?

while true; do
    if [ $INSTALL_EXIT -eq 0 ]; then
        sleep 15
        if ! _detect_prom_startup_failure; then
            break
        fi
        echo "Helm install succeeded but Prometheus is failing: $_PROM_FAIL_DIAG"
    else
        echo "Helm install failed (exit $INSTALL_EXIT)."
        if ! _detect_prom_startup_failure; then
            echo "Prometheus not failing. Other issue:"
            kubectl get pods -n onelens-agent --no-headers 2>/dev/null || true
            kubectl get events -n onelens-agent --sort-by='.lastTimestamp' --no-headers 2>/dev/null | tail -5 || true
            exit 1
        fi
        echo "Prometheus startup failure: $_PROM_FAIL_DIAG"
    fi

    if [ "$_PROM_FAIL_REASON" != "oom" ]; then
        echo "Prometheus failure is not memory-related (reason=$_PROM_FAIL_REASON). Not retrying."
        _fail_pod=$(kubectl get pods -n onelens-agent --no-headers 2>/dev/null \
            | awk '/prometheus-server/{print $1; exit}' || true)
        if [ -n "$_fail_pod" ]; then
            echo "--- Prometheus logs ---"
            kubectl logs "$_fail_pod" -n onelens-agent -c prometheus-server --previous --tail=20 2>/dev/null || true
            echo "--- Events ---"
            kubectl get events -n onelens-agent --field-selector "involvedObject.name=$_fail_pod" --no-headers 2>/dev/null | tail -5 || true
        fi
        exit 1
    fi

    if [ "$_PROM_RETRIES" -ge "$_MAX_PROM_RETRIES" ]; then
        echo "Prometheus OOM: exhausted $_MAX_PROM_RETRIES retries at $PROMETHEUS_MEMORY_LIMIT."
        echo "Manual action: delete PVC and retry install."
        echo "--- Final pod status ---"
        kubectl get pods -n onelens-agent --no-headers 2>/dev/null | grep prometheus-server || true
        _fail_pod=$(kubectl get pods -n onelens-agent --no-headers 2>/dev/null \
            | awk '/prometheus-server/{print $1; exit}' || true)
        if [ -n "$_fail_pod" ]; then
            echo "--- Prometheus logs ---"
            kubectl logs "$_fail_pod" -n onelens-agent -c prometheus-server --previous --tail=20 2>/dev/null || true
        fi
        exit 1
    fi

    _OLD_MEM="$PROMETHEUS_MEMORY_LIMIT"
    PROMETHEUS_MEMORY_LIMIT=$(calculate_wal_oom_memory "$PROMETHEUS_MEMORY_LIMIT" "$_USAGE_CAP_PROM_MEM")
    PROMETHEUS_MEMORY_REQUEST="$PROMETHEUS_MEMORY_LIMIT"
    _PROM_RETRIES=$((_PROM_RETRIES + 1))

    if [ "$PROMETHEUS_MEMORY_LIMIT" = "$_OLD_MEM" ]; then
        echo "Prometheus OOM: at memory cap. Manual action: delete PVC and retry install."
        exit 1
    fi

    echo "Prometheus OOM recovery (retry $_PROM_RETRIES/$_MAX_PROM_RETRIES): bumping memory $_OLD_MEM -> $PROMETHEUS_MEMORY_LIMIT"

    RETRY_CMD="$CMD \
      --timeout=3m \
      --set prometheus.server.resources.requests.memory=\"$PROMETHEUS_MEMORY_REQUEST\" \
      --set prometheus.server.resources.limits.memory=\"$PROMETHEUS_MEMORY_LIMIT\""
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
