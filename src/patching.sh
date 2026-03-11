#!/bin/bash
# Phase 1: Prerequisite Checks
echo "Step 0: Checking prerequisites..."

# Define versions
HELM_VERSION="v3.13.2"
KUBECTL_VERSION="v1.28.2"

# # Detect architecture
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

# Phase 2: Install Helm
echo "Installing Helm for $ARCH_TYPE..."
curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH_TYPE}.tar.gz" -o helm.tar.gz && \
    tar -xzvf helm.tar.gz && \
    mv linux-${ARCH_TYPE}/helm /usr/local/bin/helm && \
    rm -rf linux-${ARCH_TYPE} helm.tar.gz

helm version

# Phase 3: Install kubectl
echo "Installing kubectl for $ARCH_TYPE..."
curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH_TYPE}/kubectl" && \
    chmod +x kubectl && \
    mv kubectl /usr/local/bin/kubectl

kubectl version --client

if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl not found. Please install kubectl."
    exit 1
fi

# Phase 4: Cluster Pod Count and Resource Allocation

# BEGIN_EMBED lib/resource-sizing.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/resource-sizing.sh"
# END_EMBED

# --- Pod count: use desired/max replicas from workload controllers ---
echo "Calculating cluster pod capacity from workload controllers..."

# Collect cluster data (kubectl calls stay here; logic is in the library)
HPA_JSON=$(kubectl get hpa --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')
DEPLOY_JSON=$(kubectl get deployments --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')
STS_JSON=$(kubectl get statefulsets --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')
NUM_NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
NUM_DAEMONSETS=$(kubectl get daemonsets --all-namespaces --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')

# Calculate pod counts using library functions
DEPLOY_PODS=$(count_deploy_pods "$DEPLOY_JSON" "$HPA_JSON")
STS_PODS=$(count_sts_pods "$STS_JSON" "$HPA_JSON")
DS_PODS=$(count_ds_pods "$NUM_NODES" "$NUM_DAEMONSETS")
DESIRED_PODS=$((DEPLOY_PODS + STS_PODS + DS_PODS))
TOTAL_PODS=$(calculate_total_pods "$DEPLOY_PODS" "$STS_PODS" "$DS_PODS")

# Fallback: if desired pods calculation returned 0 or failed, use running pod count
if [ "$TOTAL_PODS" -le 0 ]; then
    echo "WARNING: Could not calculate desired pods from workload controllers. Falling back to running pod count."
    NUM_RUNNING=$(kubectl get pods --field-selector=status.phase=Running --all-namespaces --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
    NUM_PENDING=$(kubectl get pods --field-selector=status.phase=Pending --all-namespaces --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
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

# --- Resource tier selection ---
TIER=$(select_resource_tier "$TOTAL_PODS")
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
# Enforce desired state every run to correct any manual or chart-default drift.
PROMETHEUS_CONFIGMAP_RELOAD_CPU_REQUEST="10m"
PROMETHEUS_CONFIGMAP_RELOAD_MEMORY_REQUEST="32Mi"
PROMETHEUS_CONFIGMAP_RELOAD_CPU_LIMIT="10m"
PROMETHEUS_CONFIGMAP_RELOAD_MEMORY_LIMIT="32Mi"

# Phase 4.5: Use higher of (patching value, existing value) for each resource
# If existing in K8s is higher → keep that value (no decrease).
# If existing in K8s is lower than patching → use patching value (increase to patching level).
# If no existing value (e.g. first run) or helm/jq unavailable, use patching values as-is.
# Note: _max_cpu, _max_memory, _cpu_to_millicores, _memory_to_mi are provided by the library.

CURRENT_VALUES=$(helm get values onelens-agent -n onelens-agent -a -o json 2>/dev/null || true)

if [[ -n "$CURRENT_VALUES" ]] && command -v jq &>/dev/null; then
  echo "Comparing patching values with existing release; will use the higher value for each resource (keep higher existing, or use patching if existing is lower)."
  _get() { echo "$CURRENT_VALUES" | jq -r "$1 // empty"; }
  PROMETHEUS_CPU_REQUEST=$(_max_cpu "$PROMETHEUS_CPU_REQUEST" "$(_get '.prometheus.server.resources.requests.cpu')")
  PROMETHEUS_MEMORY_REQUEST=$(_max_memory "$PROMETHEUS_MEMORY_REQUEST" "$(_get '.prometheus.server.resources.requests.memory')")
  PROMETHEUS_CPU_LIMIT=$(_max_cpu "$PROMETHEUS_CPU_LIMIT" "$(_get '.prometheus.server.resources.limits.cpu')")
  PROMETHEUS_MEMORY_LIMIT=$(_max_memory "$PROMETHEUS_MEMORY_LIMIT" "$(_get '.prometheus.server.resources.limits.memory')")
  OPENCOST_CPU_REQUEST=$(_max_cpu "$OPENCOST_CPU_REQUEST" "$(_get '.prometheus-opencost-exporter.opencost.exporter.resources.requests.cpu')")
  OPENCOST_MEMORY_REQUEST=$(_max_memory "$OPENCOST_MEMORY_REQUEST" "$(_get '.prometheus-opencost-exporter.opencost.exporter.resources.requests.memory')")
  OPENCOST_CPU_LIMIT=$(_max_cpu "$OPENCOST_CPU_LIMIT" "$(_get '.prometheus-opencost-exporter.opencost.exporter.resources.limits.cpu')")
  OPENCOST_MEMORY_LIMIT=$(_max_memory "$OPENCOST_MEMORY_LIMIT" "$(_get '.prometheus-opencost-exporter.opencost.exporter.resources.limits.memory')")
  ONELENS_CPU_REQUEST=$(_max_cpu "$ONELENS_CPU_REQUEST" "$(_get '.onelens-agent.resources.requests.cpu')")
  ONELENS_MEMORY_REQUEST=$(_max_memory "$ONELENS_MEMORY_REQUEST" "$(_get '.onelens-agent.resources.requests.memory')")
  ONELENS_CPU_LIMIT=$(_max_cpu "$ONELENS_CPU_LIMIT" "$(_get '.onelens-agent.resources.limits.cpu')")
  ONELENS_MEMORY_LIMIT=$(_max_memory "$ONELENS_MEMORY_LIMIT" "$(_get '.onelens-agent.resources.limits.memory')")
  PROMETHEUS_PUSHGATEWAY_CPU_REQUEST=$(_max_cpu "$PROMETHEUS_PUSHGATEWAY_CPU_REQUEST" "$(_get '.prometheus["prometheus-pushgateway"].resources.requests.cpu')")
  PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST=$(_max_memory "$PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST" "$(_get '.prometheus["prometheus-pushgateway"].resources.requests.memory')")
  PROMETHEUS_PUSHGATEWAY_CPU_LIMIT=$(_max_cpu "$PROMETHEUS_PUSHGATEWAY_CPU_LIMIT" "$(_get '.prometheus["prometheus-pushgateway"].resources.limits.cpu')")
  PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT=$(_max_memory "$PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT" "$(_get '.prometheus["prometheus-pushgateway"].resources.limits.memory')")
  KSM_CPU_REQUEST=$(_max_cpu "$KSM_CPU_REQUEST" "$(_get '.prometheus["kube-state-metrics"].resources.requests.cpu')")
  KSM_MEMORY_REQUEST=$(_max_memory "$KSM_MEMORY_REQUEST" "$(_get '.prometheus["kube-state-metrics"].resources.requests.memory')")
  KSM_CPU_LIMIT=$(_max_cpu "$KSM_CPU_LIMIT" "$(_get '.prometheus["kube-state-metrics"].resources.limits.cpu')")
  KSM_MEMORY_LIMIT=$(_max_memory "$KSM_MEMORY_LIMIT" "$(_get '.prometheus["kube-state-metrics"].resources.limits.memory')")
else
  echo "Using patching values as-is (no existing release values or jq not available)."
fi

# Phase 5: Helm Upgrade with Dynamic Resource Allocation

# Resolve chart version and image tag from the currently deployed release
CURRENT_CHART_VERSION=$(helm list -n onelens-agent -o json 2>/dev/null | jq -r '.[0].chart' | sed 's/onelens-agent-//')
if [ -z "$CURRENT_CHART_VERSION" ] || [ "$CURRENT_CHART_VERSION" = "null" ]; then
    echo "ERROR: Could not determine current chart version from helm release."
    exit 1
fi

# Normalize and validate version using library function
if ! CURRENT_CHART_VERSION=$(normalize_chart_version "$CURRENT_CHART_VERSION"); then
    echo "ERROR: Chart version '$CURRENT_CHART_VERSION' is not a valid semver. Skipping patching."
    exit 1
fi

CURRENT_IMAGE_TAG="v${CURRENT_CHART_VERSION}"
echo "Current chart version: $CURRENT_CHART_VERSION, image tag: $CURRENT_IMAGE_TAG"

helm repo add onelens https://astuto-ai.github.io/onelens-installation-scripts
helm repo update

# Perform the upgrade with dynamically calculated resource values
helm upgrade onelens-agent onelens/onelens-agent \
  --version="$CURRENT_CHART_VERSION" \
  --reuse-values \
  --history-max 200 \
  --atomic \
  --timeout=5m \
  --namespace onelens-agent \
  --set prometheus.server.resources.requests.cpu="$PROMETHEUS_CPU_REQUEST" \
  --set prometheus.server.resources.requests.memory="$PROMETHEUS_MEMORY_REQUEST" \
  --set prometheus.server.resources.limits.cpu="$PROMETHEUS_CPU_LIMIT" \
  --set prometheus.server.resources.limits.memory="$PROMETHEUS_MEMORY_LIMIT" \
  --set prometheus-opencost-exporter.opencost.exporter.resources.requests.cpu="$OPENCOST_CPU_REQUEST" \
  --set prometheus-opencost-exporter.opencost.exporter.resources.requests.memory="$OPENCOST_MEMORY_REQUEST" \
  --set prometheus-opencost-exporter.opencost.exporter.resources.limits.cpu="$OPENCOST_CPU_LIMIT" \
  --set prometheus-opencost-exporter.opencost.exporter.resources.limits.memory="$OPENCOST_MEMORY_LIMIT" \
  --set onelens-agent.resources.requests.cpu="$ONELENS_CPU_REQUEST" \
  --set onelens-agent.resources.requests.memory="$ONELENS_MEMORY_REQUEST" \
  --set onelens-agent.resources.limits.cpu="$ONELENS_CPU_LIMIT" \
  --set onelens-agent.resources.limits.memory="$ONELENS_MEMORY_LIMIT" \
  --set onelens-agent.image.tag="$CURRENT_IMAGE_TAG" \
  --set onelens-agent.secrets.API_BASE_URL="https://api-in.onelens.cloud" \
  --set prometheus.prometheus-pushgateway.resources.requests.cpu="$PROMETHEUS_PUSHGATEWAY_CPU_REQUEST" \
  --set prometheus.prometheus-pushgateway.resources.requests.memory="$PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST" \
  --set prometheus.prometheus-pushgateway.resources.limits.cpu="$PROMETHEUS_PUSHGATEWAY_CPU_LIMIT" \
  --set prometheus.prometheus-pushgateway.resources.limits.memory="$PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT" \
  --set prometheus.kube-state-metrics.resources.requests.cpu="$KSM_CPU_REQUEST" \
  --set prometheus.kube-state-metrics.resources.requests.memory="$KSM_MEMORY_REQUEST" \
  --set prometheus.kube-state-metrics.resources.limits.cpu="$KSM_CPU_LIMIT" \
  --set prometheus.kube-state-metrics.resources.limits.memory="$KSM_MEMORY_LIMIT" \
  --set prometheus.configmapReload.prometheus.resources.requests.cpu="$PROMETHEUS_CONFIGMAP_RELOAD_CPU_REQUEST" \
  --set prometheus.configmapReload.prometheus.resources.requests.memory="$PROMETHEUS_CONFIGMAP_RELOAD_MEMORY_REQUEST" \
  --set prometheus.configmapReload.prometheus.resources.limits.cpu="$PROMETHEUS_CONFIGMAP_RELOAD_CPU_LIMIT" \
  --set prometheus.configmapReload.prometheus.resources.limits.memory="$PROMETHEUS_CONFIGMAP_RELOAD_MEMORY_LIMIT" \

if [ $? -eq 0 ]; then
    echo "Upgrade completed successfully with dynamic resource allocation based on $TOTAL_PODS pods."
else
    echo "Upgrade failed and was automatically rolled back by --atomic flag"
    exit 1
fi

echo "Patching complete with dynamic resource allocation based on $TOTAL_PODS pods."