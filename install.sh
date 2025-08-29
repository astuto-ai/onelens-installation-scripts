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
            \"registration_id\": \"$registration_id\",
            \"cluster_token\": \"$cluster_token\",
            \"status\": \"FAILED\",
            \"logs\": \"$logs\"
        }"
}

# Ensure we send logs on error, and preserve the original exit code
trap 'code=$?; if [ $code -ne 0 ]; then send_logs; fi; exit $code' EXIT

# Phase 2: Environment Variable Setup
: "${RELEASE_VERSION:=1.4.0}"
: "${IMAGE_TAG:=v$RELEASE_VERSION}"
: "${API_BASE_URL:=https://api-in.onelens.cloud}"
: "${PVC_ENABLED:=true}"

# Export the variables so they are available in the environment
export RELEASE_VERSION IMAGE_TAG API_BASE_URL TOKEN PVC_ENABLED
if [ -z "${REGISTRATION_TOKEN:-}" ]; then
    echo "Error: REGISTRATION_TOKEN is not set"
    exit 1
else
    echo "REGISTRATION_TOKEN is set"
fi

# Phase 3: API Registration
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

# Phase 4: Prerequisite Checks
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

# Phase 5: Install Helm
echo "Installing Helm for $ARCH_TYPE..."
curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH_TYPE}.tar.gz" -o helm.tar.gz && \
    tar -xzvf helm.tar.gz && \
    mv linux-${ARCH_TYPE}/helm /usr/local/bin/helm && \
    rm -rf linux-${ARCH_TYPE} helm.tar.gz

helm version

# Phase 6: Install kubectl
echo "Installing kubectl for $ARCH_TYPE..."
curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH_TYPE}/kubectl" && \
    chmod +x kubectl && \
    mv kubectl /usr/local/bin/kubectl

kubectl version --client

if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl not found. Please install kubectl."
    exit 1
fi

# Phase 7: Namespace Validation
if kubectl get namespace onelens-agent &> /dev/null; then
    echo "Warning: Namespace 'onelens-agent' already exists."
else
    echo "Creating namespace 'onelens-agent'..."
    kubectl create namespace onelens-agent || { echo "Error: Failed to create namespace 'onelens-agent'."; exit 1; }
fi

# Phase 8: EBS CSI Driver Check and Installation
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

check_ebs_driver 

echo "Persistent storage for Prometheus is ENABLED."

# Phase 9: Cluster Pod Count and Resource Allocation
NUM_RUNNING=$(kubectl get pods --field-selector=status.phase=Running --all-namespaces | wc -l | tr -d '[:space:]')
NUM_PENDING=$(kubectl get pods --field-selector=status.phase=Pending --all-namespaces | wc -l | tr -d '[:space:]')
TOTAL_PODS=$((NUM_RUNNING + NUM_PENDING))

echo "Total number of pods in the cluster: $TOTAL_PODS"

if [ $? -ne 0 ]; then
    echo "Error: Failed to fetch pod details. Please check if Kubernetes is running and kubectl is configured correctly." >&2
    exit 1
fi

echo "Total number of pods in the cluster: $TOTAL_PODS"

helm repo add onelens https://astuto-ai.github.io/onelens-installation-scripts && helm repo update

if [ "$TOTAL_PODS" -lt 100 ]; then
    echo "Setting resources for small cluster (<100 pods)"
    # Prometheus resources
    PROMETHEUS_CPU_REQUEST="116m"
    PROMETHEUS_MEMORY_REQUEST="900Mi"
    PROMETHEUS_CPU_LIMIT="864m"
    PROMETHEUS_MEMORY_LIMIT="4000Mi"
    
    # OpenCost resources
    OPENCOST_CPU_REQUEST="100m"
    OPENCOST_MEMORY_REQUEST="63Mi"
    OPENCOST_CPU_LIMIT="200m"
    OPENCOST_MEMORY_LIMIT="400Mi"
    
    # OneLens Agent resources
    ONELENS_CPU_REQUEST="104m"
    ONELENS_MEMORY_REQUEST="115Mi"
    ONELENS_CPU_LIMIT="414m"
    ONELENS_MEMORY_LIMIT="450Mi"
    
elif [ "$TOTAL_PODS" -lt 500 ]; then
    echo "Setting resources for medium cluster (100-499 pods)"
    # Prometheus resources
    PROMETHEUS_CPU_REQUEST="230m"
    PROMETHEUS_MEMORY_REQUEST="1771Mi"
    PROMETHEUS_CPU_LIMIT="1035m"
    PROMETHEUS_MEMORY_LIMIT="7000Mi"
    
    # OpenCost resources
    OPENCOST_CPU_REQUEST="29m"
    OPENCOST_MEMORY_REQUEST="69Mi"
    OPENCOST_CPU_LIMIT="138m"
    OPENCOST_MEMORY_LIMIT="345Mi"
    
    # OneLens Agent resources
    ONELENS_CPU_REQUEST="127m"
    ONELENS_MEMORY_REQUEST="127Mi"
    ONELENS_CPU_LIMIT="552m"
    ONELENS_MEMORY_LIMIT="483Mi"
    
elif [ "$TOTAL_PODS" -lt 1000 ]; then
    echo "Setting resources for large cluster (500-999 pods)"
    # Prometheus resources
    PROMETHEUS_CPU_REQUEST="288m"
    PROMETHEUS_MEMORY_REQUEST="3533Mi"
    PROMETHEUS_CPU_LIMIT="1551m"
    PROMETHEUS_MEMORY_LIMIT="12000Mi"
    
    # OpenCost resources
    OPENCOST_CPU_REQUEST="69m"
    OPENCOST_MEMORY_REQUEST="115Mi"
    OPENCOST_CPU_LIMIT="414m"
    OPENCOST_MEMORY_LIMIT="759Mi"
    
    # OneLens Agent resources
    ONELENS_CPU_REQUEST="230m"
    ONELENS_MEMORY_REQUEST="138Mi"
    ONELENS_CPU_LIMIT="966m"
    ONELENS_MEMORY_LIMIT="588Mi"
    
elif [ "$TOTAL_PODS" -lt 1500 ]; then
    echo "Setting resources for extra large cluster (1000-1499 pods)"
    # Prometheus resources
    PROMETHEUS_CPU_REQUEST="316m"
    PROMETHEUS_MEMORY_REQUEST="5294Mi"
    PROMETHEUS_CPU_LIMIT="1809m"
    PROMETHEUS_MEMORY_LIMIT="15000Mi"
    
    # OpenCost resources
    OPENCOST_CPU_REQUEST="92m"
    OPENCOST_MEMORY_REQUEST="161Mi"
    OPENCOST_CPU_LIMIT="483m"
    OPENCOST_MEMORY_LIMIT="897Mi"
    
    # OneLens Agent resources
    ONELENS_CPU_REQUEST="288m"
    ONELENS_MEMORY_REQUEST="150Mi"
    ONELENS_CPU_LIMIT="1173m"
    ONELENS_MEMORY_LIMIT="621Mi"
    
else
    echo "Setting resources for very large cluster (1500+ pods)"
    # Prometheus resources
    PROMETHEUS_CPU_REQUEST="345m"
    PROMETHEUS_MEMORY_REQUEST="7066Mi"
    PROMETHEUS_CPU_LIMIT="2070m"
    PROMETHEUS_MEMORY_LIMIT="18000Mi"
    
    # OpenCost resources
    OPENCOST_CPU_REQUEST="115m"
    OPENCOST_MEMORY_REQUEST="196Mi"
    OPENCOST_CPU_LIMIT="552m"
    OPENCOST_MEMORY_LIMIT="1035Mi"
    
    # OneLens Agent resources
    ONELENS_CPU_REQUEST="345m"
    ONELENS_MEMORY_REQUEST="161Mi"
    ONELENS_CPU_LIMIT="1380m"
    ONELENS_MEMORY_LIMIT="690Mi"
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

# Phase 10: Helm Deployment
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

## EBS Driver custom tag and custom encryption
export EBS_TAGS_ENABLED="${EBS_TAGS_ENABLED:=false}"
export EBS_TAGS="${EBS_TAGS:=}"
export EBS_ENCRYPTION_ENABLED="${EBS_ENCRYPTION_ENABLED:=false}"
export EBS_ENCRYPTION_KEY="${EBS_ENCRYPTION_KEY:=}"

FILE="globalvalues.yaml"

echo "using $FILE"

if [ -f "$FILE" ]; then
    echo "File $FILE exists"
else
    echo "File $FILE does not exist"
    exit 1
fi

CMD="helm upgrade --install onelens-agent -n onelens-agent --create-namespace onelens/onelens-agent \
    --version \"\${RELEASE_VERSION:=1.4.0}\" \
    -f $FILE \
    --set onelens-agent.env.CLUSTER_NAME=\"$CLUSTER_NAME\" \
    --set-string onelens-agent.env.ACCOUNT_ID=\"$ACCOUNT\" \
    --set onelens-agent.secrets.API_BASE_URL=\"$API_BASE_URL\" \
    --set onelens-agent.secrets.CLUSTER_TOKEN=\"$CLUSTER_TOKEN\" \
    --set onelens-agent.secrets.REGISTRATION_ID=\"$REGISTRATION_ID\" \
    --set prometheus-opencost-exporter.opencost.exporter.defaultClusterId=\"$CLUSTER_NAME\" \
    --set onelens-agent.image.tag=\"$IMAGE_TAG\" \
    --set prometheus.server.persistentVolume.enabled=\"$PVC_ENABLED\" \
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
    --set-string prometheus.server.retention=\"$PROMETHEUS_RETENTION\" \
    --set-string prometheus.server.retentionSize=\"$PROMETHEUS_RETENTION_SIZE\" \
    --set-string prometheus.server.persistentVolume.size=\"$PROMETHEUS_VOLUME_SIZE\""

# Append tolerations only if set
if [[ -n "$TOLERATION_KEY" && -n "$TOLERATION_VALUE" && -n "$TOLERATION_OPERATOR" && -n "$TOLERATION_EFFECT" ]]; then
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

# Append custom EBS tags only if set
if [[ "$EBS_TAGS_ENABLED" == "true" && -n "$EBS_TAGS" ]]; then
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

# Append encryption only if set
if [[ "$EBS_ENCRYPTION_ENABLED" == "true" ]]; then
  CMD+=" --set onelens-agent.storageClass.encryption.enabled=true"
  if [[ -n "$EBS_ENCRYPTION_KEY" ]]; then
    CMD+=" --set onelens-agent.storageClass.encryption.kmsKeyId=\"$EBS_ENCRYPTION_KEY\""
  fi
fi

# Final execution
CMD+=" --wait || { echo \"Error: Helm deployment failed.\"; exit 1; }"

# Run it
eval "$CMD"

kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=prometheus-opencost-exporter -n onelens-agent --timeout=800s || {
    echo "Error: Pods failed to become ready."
    echo "Installation Failed."
    false
}

# Phase 11: Finalization
echo "Installation complete."

echo " Printing $REGISTRATION_ID"
echo "Printing $CLUSTER_TOKEN"
curl -X PUT "$API_BASE_URL/v1/kubernetes/registration" \
    -H "Content-Type: application/json" \
    -d "{
        \"registration_id\": \"$REGISTRATION_ID\",
        \"cluster_token\": \"$CLUSTER_TOKEN\",
        \"status\": \"CONNECTED\"
    }"
echo "To verify deployment: kubectl get pods -n onelens-agent"
sleep 60
kubectl delete job onelensdeployerjob -n onelens-agent || true
kubectl delete clusterrole onelensdeployerjob-clusterrole || true
kubectl delete clusterrolebinding onelensdeployerjob-clusterrolebinding || true
kubectl delete sa onelensdeployerjob-sa -n onelens-agent || true

