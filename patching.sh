#!/bin/bash
# Phase 1: Prerequisite Checks
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

if [ $? -ne 0 ]; then
    echo "Error: Failed to fetch pod details. Please check if Kubernetes is running and kubectl is configured correctly." >&2
    exit 1
fi

echo "Total number of pods in the cluster: $TOTAL_PODS"

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
    
elif [ "$TOTAL_PODS" -lt 1500 ]; then
    echo "Setting resources for extra large cluster (1000-1499 pods)"
    # Prometheus resources
    PROMETHEUS_CPU_REQUEST="1150m"
    PROMETHEUS_MEMORY_REQUEST="5294Mi"
    PROMETHEUS_CPU_LIMIT="316m"
    PROMETHEUS_MEMORY_LIMIT="1150Mi"
    
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
fi

## Other component resources
PROMETHEUS_CONFIGMAP_RELOAD_MEMORY_LIMIT="100Mi"
PROMETHEUS_CONFIGMAP_RELOAD_MEMORY_REQUEST="100Mi"
PROMETHEUS_CONFIGMAP_RELOAD_CPU_LIMIT="100m"
PROMETHEUS_CONFIGMAP_RELOAD_CPU_REQUEST="100m"

PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT="100Mi"
PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST="100Mi"
PROMETHEUS_PUSHGATEWAY_CPU_LIMIT="100m"
PROMETHEUS_PUSHGATEWAY_CPU_REQUEST="100m"

KSM_MEMORY_LIMIT=100Mi""
KSM_MEMORY_REQUEST="100Mi"
KSM_CPU_LIMIT="100m"
KSM_CPU_REQUEST="100m"


# Phase 5: Helm Upgrade with Dynamic Resource Allocation
echo "helm repo add onelens https://astuto-ai.github.io/onelens-installation-scripts"
echo "helm repo update"
echo "helm upgrade onelens-agent onelens/onelens-agent with dynamic resource allocation"

helm repo add onelens https://astuto-ai.github.io/onelens-installation-scripts
helm repo update

# Perform the upgrade with dynamically calculated resource values
helm upgrade onelens-agent onelens/onelens-agent \
  --version=1.6.0 \
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