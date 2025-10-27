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
    PROMETHEUS_CPU_REQUEST="116m"
    PROMETHEUS_MEMORY_REQUEST="1188Mi"
    PROMETHEUS_CPU_LIMIT="864m"
    PROMETHEUS_MEMORY_LIMIT="4000Mi"
    
    # OpenCost resources
    OPENCOST_CPU_REQUEST="17m"
    OPENCOST_MEMORY_REQUEST="63Mi"
    OPENCOST_CPU_LIMIT="105m"
    OPENCOST_MEMORY_LIMIT="276Mi"
    
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

# Phase 5: Helm Upgrade with Dynamic Resource Allocation
echo "helm repo add onelens https://astuto-ai.github.io/onelens-installation-scripts"
echo "helm repo update"
echo "helm upgrade onelens-agent onelens/onelens-agent with dynamic resource allocation"

helm repo add onelens https://astuto-ai.github.io/onelens-installation-scripts
helm repo update
# REVISION=$(helm history onelens-agent -n onelens-agent | grep -v '02:00' | tail -1 | awk '{print $1}')
# echo $REVISION
# helm rollback onelens-agent $REVISION -n onelens-agent

# # Perform the upgrade with dynamically calculated resource values
# helm upgrade onelens-agent onelens/onelens-agent \
#   --version=0.1.1-beta.4 \
#   --namespace onelens-agent \
#   --history-max 200 \
#   --set prometheus.server.resources.requests.cpu="$PROMETHEUS_CPU_REQUEST" \
#   --set prometheus.server.resources.requests.memory="$PROMETHEUS_MEMORY_REQUEST" \
#   --set prometheus.server.resources.limits.cpu="$PROMETHEUS_CPU_LIMIT" \
#   --set prometheus.server.resources.limits.memory="$PROMETHEUS_MEMORY_LIMIT" \
#   --set prometheus-opencost-exporter.opencost.exporter.resources.requests.cpu="$OPENCOST_CPU_REQUEST" \
#   --set prometheus-opencost-exporter.opencost.exporter.resources.requests.memory="$OPENCOST_MEMORY_REQUEST" \
#   --set prometheus-opencost-exporter.opencost.exporter.resources.limits.cpu="$OPENCOST_CPU_LIMIT" \
#   --set prometheus-opencost-exporter.opencost.exporter.resources.limits.memory="$OPENCOST_MEMORY_LIMIT" \
#   --set onelens-agent.resources.requests.cpu="$ONELENS_CPU_REQUEST" \
#   --set onelens-agent.resources.requests.memory="$ONELENS_MEMORY_REQUEST" \
#   --set onelens-agent.resources.limits.cpu="$ONELENS_CPU_LIMIT" \
#   --set onelens-agent.resources.limits.memory="$ONELENS_MEMORY_LIMIT"

# echo "Patching complete with dynamic resource allocation based on $TOTAL_PODS pods."
