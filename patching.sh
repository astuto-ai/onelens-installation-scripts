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
TOTAL_PODS=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | wc -l)

echo "Total number of pods in the cluster: $TOTAL_PODS"

if [ "$TOTAL_PODS" -lt 50 ]; then
    echo "Setting resources for tiny cluster (<50 pods)"
    # Prometheus resources
    PROMETHEUS_CPU_REQUEST="270m"
    PROMETHEUS_MEMORY_REQUEST="1425Mi"
    PROMETHEUS_CPU_LIMIT="270m"
    PROMETHEUS_MEMORY_LIMIT="1425Mi"

    # OpenCost resources
    OPENCOST_CPU_REQUEST="180m"
    OPENCOST_MEMORY_REQUEST="240Mi"
    OPENCOST_CPU_LIMIT="180m"
    OPENCOST_MEMORY_LIMIT="240Mi"

    # OneLens Agent resources
    ONELENS_CPU_REQUEST="100m"
    ONELENS_MEMORY_REQUEST="256Mi"
    ONELENS_CPU_LIMIT="300m"
    ONELENS_MEMORY_LIMIT="384Mi"

    # KSM resources
    KSM_CPU_REQUEST="100m"
    KSM_MEMORY_REQUEST="128Mi"
    KSM_CPU_LIMIT="100m"
    KSM_MEMORY_LIMIT="128Mi"

    # Pushgateway resources
    PROMETHEUS_PUSHGATEWAY_CPU_REQUEST="50m"
    PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST="64Mi"
    PROMETHEUS_PUSHGATEWAY_CPU_LIMIT="50m"
    PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT="64Mi"

elif [ "$TOTAL_PODS" -lt 100 ]; then
    echo "Setting resources for small cluster (50-99 pods)"
    # Prometheus resources
    PROMETHEUS_CPU_REQUEST="360m"
    PROMETHEUS_MEMORY_REQUEST="1901Mi"
    PROMETHEUS_CPU_LIMIT="360m"
    PROMETHEUS_MEMORY_LIMIT="1901Mi"

    # OpenCost resources
    OPENCOST_CPU_REQUEST="240m"
    OPENCOST_MEMORY_REQUEST="320Mi"
    OPENCOST_CPU_LIMIT="240m"
    OPENCOST_MEMORY_LIMIT="320Mi"

    # OneLens Agent resources
    ONELENS_CPU_REQUEST="125m"
    ONELENS_MEMORY_REQUEST="320Mi"
    ONELENS_CPU_LIMIT="375m"
    ONELENS_MEMORY_LIMIT="480Mi"

    # KSM resources
    KSM_CPU_REQUEST="120m"
    KSM_MEMORY_REQUEST="160Mi"
    KSM_CPU_LIMIT="120m"
    KSM_MEMORY_LIMIT="160Mi"

    # Pushgateway resources
    PROMETHEUS_PUSHGATEWAY_CPU_REQUEST="100m"
    PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST="100Mi"
    PROMETHEUS_PUSHGATEWAY_CPU_LIMIT="100m"
    PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT="100Mi"

elif [ "$TOTAL_PODS" -lt 500 ]; then
    echo "Setting resources for medium cluster (100-499 pods)"
    # Prometheus resources
    PROMETHEUS_CPU_REQUEST="420m"
    PROMETHEUS_MEMORY_REQUEST="2834Mi"
    PROMETHEUS_CPU_LIMIT="420m"
    PROMETHEUS_MEMORY_LIMIT="2834Mi"

    # OpenCost resources
    OPENCOST_CPU_REQUEST="240m"
    OPENCOST_MEMORY_REQUEST="400Mi"
    OPENCOST_CPU_LIMIT="240m"
    OPENCOST_MEMORY_LIMIT="400Mi"

    # OneLens Agent resources
    ONELENS_CPU_REQUEST="125m"
    ONELENS_MEMORY_REQUEST="480Mi"
    ONELENS_CPU_LIMIT="375m"
    ONELENS_MEMORY_LIMIT="640Mi"

    # KSM resources
    KSM_CPU_REQUEST="120m"
    KSM_MEMORY_REQUEST="160Mi"
    KSM_CPU_LIMIT="120m"
    KSM_MEMORY_LIMIT="160Mi"

    # Pushgateway resources
    PROMETHEUS_PUSHGATEWAY_CPU_REQUEST="100m"
    PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST="100Mi"
    PROMETHEUS_PUSHGATEWAY_CPU_LIMIT="100m"
    PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT="100Mi"

elif [ "$TOTAL_PODS" -lt 1000 ]; then
    echo "Setting resources for large cluster (500-999 pods)"
    # Prometheus resources
    PROMETHEUS_CPU_REQUEST="1200m"
    PROMETHEUS_MEMORY_REQUEST="5653Mi"
    PROMETHEUS_CPU_LIMIT="1200m"
    PROMETHEUS_MEMORY_LIMIT="5653Mi"

    # OpenCost resources
    OPENCOST_CPU_REQUEST="300m"
    OPENCOST_MEMORY_REQUEST="576Mi"
    OPENCOST_CPU_LIMIT="300m"
    OPENCOST_MEMORY_LIMIT="576Mi"

    # OneLens Agent resources
    ONELENS_CPU_REQUEST="125m"
    ONELENS_MEMORY_REQUEST="640Mi"
    ONELENS_CPU_LIMIT="440m"
    ONELENS_MEMORY_LIMIT="800Mi"

    # KSM resources
    KSM_CPU_REQUEST="120m"
    KSM_MEMORY_REQUEST="160Mi"
    KSM_CPU_LIMIT="120m"
    KSM_MEMORY_LIMIT="160Mi"

    # Pushgateway resources
    PROMETHEUS_PUSHGATEWAY_CPU_REQUEST="100m"
    PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST="100Mi"
    PROMETHEUS_PUSHGATEWAY_CPU_LIMIT="100m"
    PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT="100Mi"

elif [ "$TOTAL_PODS" -lt 1500 ]; then
    echo "Setting resources for extra large cluster (1000-1499 pods)"
    # Prometheus resources
    PROMETHEUS_CPU_REQUEST="1380m"
    PROMETHEUS_MEMORY_REQUEST="8640Mi"
    PROMETHEUS_CPU_LIMIT="1380m"
    PROMETHEUS_MEMORY_LIMIT="8640Mi"

    # OpenCost resources
    OPENCOST_CPU_REQUEST="300m"
    OPENCOST_MEMORY_REQUEST="720Mi"
    OPENCOST_CPU_LIMIT="300m"
    OPENCOST_MEMORY_LIMIT="720Mi"

    # OneLens Agent resources
    ONELENS_CPU_REQUEST="125m"
    ONELENS_MEMORY_REQUEST="800Mi"
    ONELENS_CPU_LIMIT="500m"
    ONELENS_MEMORY_LIMIT="960Mi"

    # KSM resources
    KSM_CPU_REQUEST="300m"
    KSM_MEMORY_REQUEST="640Mi"
    KSM_CPU_LIMIT="300m"
    KSM_MEMORY_LIMIT="640Mi"

    # Pushgateway resources
    PROMETHEUS_PUSHGATEWAY_CPU_REQUEST="250m"
    PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST="400Mi"
    PROMETHEUS_PUSHGATEWAY_CPU_LIMIT="250m"
    PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT="400Mi"

else
    echo "Setting resources for very large cluster (1500+ pods)"
    # Prometheus resources
    PROMETHEUS_CPU_REQUEST="1800m"
    PROMETHEUS_MEMORY_REQUEST="11306Mi"
    PROMETHEUS_CPU_LIMIT="1800m"
    PROMETHEUS_MEMORY_LIMIT="11306Mi"

    # OpenCost resources
    OPENCOST_CPU_REQUEST="360m"
    OPENCOST_MEMORY_REQUEST="960Mi"
    OPENCOST_CPU_LIMIT="360m"
    OPENCOST_MEMORY_LIMIT="960Mi"

    # OneLens Agent resources
    ONELENS_CPU_REQUEST="190m"
    ONELENS_MEMORY_REQUEST="960Mi"
    ONELENS_CPU_LIMIT="565m"
    ONELENS_MEMORY_LIMIT="1280Mi"

    # KSM resources
    KSM_CPU_REQUEST="300m"
    KSM_MEMORY_REQUEST="640Mi"
    KSM_CPU_LIMIT="300m"
    KSM_MEMORY_LIMIT="640Mi"

    # Pushgateway resources
    PROMETHEUS_PUSHGATEWAY_CPU_REQUEST="250m"
    PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST="400Mi"
    PROMETHEUS_PUSHGATEWAY_CPU_LIMIT="250m"
    PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT="400Mi"
fi

## Other component resources
PROMETHEUS_CONFIGMAP_RELOAD_MEMORY_LIMIT="100Mi"
PROMETHEUS_CONFIGMAP_RELOAD_MEMORY_REQUEST="100Mi"
PROMETHEUS_CONFIGMAP_RELOAD_CPU_LIMIT="100m"
PROMETHEUS_CONFIGMAP_RELOAD_CPU_REQUEST="100m"

# Phase 4.5: Use higher of (patching value, existing value) for each resource
# If existing in K8s is higher → keep that value (no decrease).
# If existing in K8s is lower than patching → use patching value (increase to patching level).
# If no existing value (e.g. first run) or helm/jq unavailable, use patching values as-is.
_cpu_to_millicores() {
  local v="$1"
  if [[ -z "$v" ]]; then echo "0"; return; fi
  if [[ "$v" =~ ^([0-9]+)m$ ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "$(awk "BEGIN { printf \"%.0f\", $v * 1000 }")"
  else
    echo "0"
  fi
}
_memory_to_mi() {
  local v="$1"
  if [[ -z "$v" ]]; then echo "0"; return; fi
  if [[ "$v" =~ ^([0-9]+)Mi$ ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$v" =~ ^([0-9]+)Gi$ ]]; then
    echo "$(( ${BASH_REMATCH[1]} * 1024 ))"
  elif [[ "$v" =~ ^([0-9]+)Ki$ ]]; then
    echo "$(( ${BASH_REMATCH[1]} / 1024 ))"
  else
    echo "0"
  fi
}
# Returns the larger of two CPU quantities (as string); if either empty, returns the non-empty one.
_max_cpu() {
  local a="$1" b="$2"
  if [[ -z "$a" && -z "$b" ]]; then echo ""; return; fi
  if [[ -z "$a" ]]; then echo "$b"; return; fi
  if [[ -z "$b" ]]; then echo "$a"; return; fi
  local ma=$(_cpu_to_millicores "$a") mb=$(_cpu_to_millicores "$b")
  if [[ "$ma" -ge "$mb" ]]; then echo "$a"; else echo "$b"; fi
}
_max_memory() {
  local a="$1" b="$2"
  if [[ -z "$a" && -z "$b" ]]; then echo ""; return; fi
  if [[ -z "$a" ]]; then echo "$b"; return; fi
  if [[ -z "$b" ]]; then echo "$a"; return; fi
  local ma=$(_memory_to_mi "$a") mb=$(_memory_to_mi "$b")
  if [[ "$ma" -ge "$mb" ]]; then echo "$a"; else echo "$b"; fi
}

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
  PROMETHEUS_CONFIGMAP_RELOAD_CPU_REQUEST=$(_max_cpu "$PROMETHEUS_CONFIGMAP_RELOAD_CPU_REQUEST" "$(_get '.prometheus.configmapReload.prometheus.resources.requests.cpu')")
  PROMETHEUS_CONFIGMAP_RELOAD_MEMORY_REQUEST=$(_max_memory "$PROMETHEUS_CONFIGMAP_RELOAD_MEMORY_REQUEST" "$(_get '.prometheus.configmapReload.prometheus.resources.requests.memory')")
  PROMETHEUS_CONFIGMAP_RELOAD_CPU_LIMIT=$(_max_cpu "$PROMETHEUS_CONFIGMAP_RELOAD_CPU_LIMIT" "$(_get '.prometheus.configmapReload.prometheus.resources.limits.cpu')")
  PROMETHEUS_CONFIGMAP_RELOAD_MEMORY_LIMIT=$(_max_memory "$PROMETHEUS_CONFIGMAP_RELOAD_MEMORY_LIMIT" "$(_get '.prometheus.configmapReload.prometheus.resources.limits.memory')")
else
  echo "Using patching values as-is (no existing release values or jq not available)."
fi

# Phase 5: Helm Upgrade with Dynamic Resource Allocation
echo "helm repo add onelens https://astuto-ai.github.io/onelens-installation-scripts"
echo "helm repo update"
echo "helm upgrade onelens-agent onelens/onelens-agent with dynamic resource allocation"

helm repo add onelens https://astuto-ai.github.io/onelens-installation-scripts
helm repo update

# Perform the upgrade with dynamically calculated resource values
helm upgrade onelens-agent onelens/onelens-agent \
  --version=1.7.0 \
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
  --set onelens-agent.image.tag="v1.7.0" \
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