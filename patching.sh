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
# --- Embedded from lib/resource-sizing.sh ---
# lib/resource-sizing.sh — Shared resource sizing functions
# Sourced by install.sh. Embedded into patching.sh at build time.
# Do NOT add kubectl/helm calls here — this must be testable without a cluster.

###############################################################################
# Pure math functions
###############################################################################

# apply_memory_multiplier "$mem_str" "$multiplier"
# Multiply a memory string (e.g. "384Mi") by a float multiplier, rounding up.
# Example: "384Mi" x 1.3 → "500Mi"
apply_memory_multiplier() {
    local mem_str="$1"
    local multiplier="$2"
    local mem_val="${mem_str%Mi}"
    local result=$(echo "$mem_val $multiplier" | awk '{printf "%d", int($1 * $2 + 0.99)}')
    echo "${result}Mi"
}

# _cpu_to_millicores "$value"
# Convert a CPU string to integer millicores.
# "100m"→100, "1"→1000, "1.5"→1500, ""→0
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

# _memory_to_mi "$value"
# Convert a memory string to integer MiB.
# "128Mi"→128, "1Gi"→1024, "512Ki"→0 (integer division)
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

# _max_cpu "$a" "$b"
# Return the larger of two CPU strings (preserving original format).
_max_cpu() {
  local a="$1" b="$2"
  if [[ -z "$a" && -z "$b" ]]; then echo ""; return; fi
  if [[ -z "$a" ]]; then echo "$b"; return; fi
  if [[ -z "$b" ]]; then echo "$a"; return; fi
  local ma=$(_cpu_to_millicores "$a") mb=$(_cpu_to_millicores "$b")
  if [[ "$ma" -ge "$mb" ]]; then echo "$a"; else echo "$b"; fi
}

# _max_memory "$a" "$b"
# Return the larger of two memory strings (preserving original format).
_max_memory() {
  local a="$1" b="$2"
  if [[ -z "$a" && -z "$b" ]]; then echo ""; return; fi
  if [[ -z "$a" ]]; then echo "$b"; return; fi
  if [[ -z "$b" ]]; then echo "$a"; return; fi
  local ma=$(_memory_to_mi "$a") mb=$(_memory_to_mi "$b")
  if [[ "$ma" -ge "$mb" ]]; then echo "$a"; else echo "$b"; fi
}

###############################################################################
# Pod counting functions (accept JSON strings as arguments)
###############################################################################

# count_deploy_pods "$deployments_json" "$hpa_json"
# Count expected pods from Deployments, using HPA maxReplicas where available.
# Falls back to deployment's .spec.replicas when no HPA targets it.
count_deploy_pods() {
    local deploy_json="$1"
    local hpa_json="$2"
    echo "$deploy_json" | jq --argjson hpa "$hpa_json" '
        [.items[] | . as $dep |
            ([($hpa.items[] |
                select(.metadata.namespace == $dep.metadata.namespace and
                       .spec.scaleTargetRef.kind == "Deployment" and
                       .spec.scaleTargetRef.name == $dep.metadata.name) |
                .spec.maxReplicas)] | max) // ($dep.spec.replicas // 0)
        ] | add // 0
    ' 2>/dev/null || echo "0"
}

# count_sts_pods "$statefulsets_json" "$hpa_json"
# Count expected pods from StatefulSets, using HPA maxReplicas where available.
# Falls back to statefulset's .spec.replicas when no HPA targets it.
count_sts_pods() {
    local sts_json="$1"
    local hpa_json="$2"
    echo "$sts_json" | jq --argjson hpa "$hpa_json" '
        [.items[] | . as $sts |
            ([($hpa.items[] |
                select(.metadata.namespace == $sts.metadata.namespace and
                       .spec.scaleTargetRef.kind == "StatefulSet" and
                       .spec.scaleTargetRef.name == $sts.metadata.name) |
                .spec.maxReplicas)] | max) // ($sts.spec.replicas // 0)
        ] | add // 0
    ' 2>/dev/null || echo "0"
}

# count_ds_pods "$num_nodes" "$num_daemonsets"
# Estimate DaemonSet pod count: nodes * daemonsets.
count_ds_pods() {
    echo "$(( $1 * $2 ))"
}

# calculate_total_pods "$deploy_pods" "$sts_pods" "$ds_pods"
# Sum all pod counts and add a 25% buffer (rounded up).
calculate_total_pods() {
    local desired=$(( $1 + $2 + $3 ))
    echo "$desired" | awk '{printf "%d", int($1 * 1.25 + 0.99)}'
}

###############################################################################
# Label density functions
###############################################################################

# calculate_avg_labels "$pods_json"
# Return the average number of labels per pod (integer, floored).
calculate_avg_labels() {
    echo "$1" | jq '[.items[].metadata.labels | length] | add / length | floor' 2>/dev/null || echo "0"
}

# get_label_multiplier "$avg_labels"
# Map average label count to a memory multiplier.
# <=0 (measurement failed) → 1.3, <=7 → 1.0, <=12 → 1.3, <=17 → 1.6, else → 2.0
get_label_multiplier() {
    local avg="$1"
    if [ "$avg" -le 0 ] 2>/dev/null; then
        echo "1.3"  # default when measurement fails
    elif [ "$avg" -le 7 ]; then
        echo "1.0"
    elif [ "$avg" -le 12 ]; then
        echo "1.3"
    elif [ "$avg" -le 17 ]; then
        echo "1.6"
    else
        echo "2.0"
    fi
}

###############################################################################
# Version handling
###############################################################################

# normalize_chart_version "$raw_version"
# Strip release/ and v prefixes, validate semver format.
# Echoes the cleaned version. Returns 1 if not valid semver.
normalize_chart_version() {
    local ver="$1"
    ver=$(echo "$ver" | sed 's|^release/||' | sed 's|^v||')
    if echo "$ver" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
        echo "$ver"
        return 0
    else
        echo "$ver"
        return 1
    fi
}

###############################################################################
# Tier selection — resource sizing
###############################################################################

# select_resource_tier "$total_pods"
# Set ALL global resource variables based on pod-count thresholds.
# Echoes the tier name for logging.
select_resource_tier() {
    local total_pods="$1"

    if [ "$total_pods" -lt 50 ]; then
        # ── Tiny ──
        PROMETHEUS_CPU_REQUEST="270m"
        PROMETHEUS_MEMORY_REQUEST="1425Mi"
        PROMETHEUS_CPU_LIMIT="270m"
        PROMETHEUS_MEMORY_LIMIT="1425Mi"

        OPENCOST_CPU_REQUEST="180m"
        OPENCOST_MEMORY_REQUEST="240Mi"
        OPENCOST_CPU_LIMIT="180m"
        OPENCOST_MEMORY_LIMIT="240Mi"

        ONELENS_CPU_REQUEST="100m"
        ONELENS_MEMORY_REQUEST="256Mi"
        ONELENS_CPU_LIMIT="300m"
        ONELENS_MEMORY_LIMIT="384Mi"

        KSM_CPU_REQUEST="100m"
        KSM_MEMORY_REQUEST="128Mi"
        KSM_CPU_LIMIT="100m"
        KSM_MEMORY_LIMIT="128Mi"

        PROMETHEUS_PUSHGATEWAY_CPU_REQUEST="50m"
        PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST="64Mi"
        PROMETHEUS_PUSHGATEWAY_CPU_LIMIT="50m"
        PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT="64Mi"

        echo "tiny"

    elif [ "$total_pods" -lt 100 ]; then
        # ── Small ──
        PROMETHEUS_CPU_REQUEST="360m"
        PROMETHEUS_MEMORY_REQUEST="1901Mi"
        PROMETHEUS_CPU_LIMIT="360m"
        PROMETHEUS_MEMORY_LIMIT="1901Mi"

        OPENCOST_CPU_REQUEST="240m"
        OPENCOST_MEMORY_REQUEST="320Mi"
        OPENCOST_CPU_LIMIT="240m"
        OPENCOST_MEMORY_LIMIT="320Mi"

        ONELENS_CPU_REQUEST="125m"
        ONELENS_MEMORY_REQUEST="320Mi"
        ONELENS_CPU_LIMIT="375m"
        ONELENS_MEMORY_LIMIT="480Mi"

        KSM_CPU_REQUEST="120m"
        KSM_MEMORY_REQUEST="160Mi"
        KSM_CPU_LIMIT="120m"
        KSM_MEMORY_LIMIT="160Mi"

        PROMETHEUS_PUSHGATEWAY_CPU_REQUEST="100m"
        PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST="100Mi"
        PROMETHEUS_PUSHGATEWAY_CPU_LIMIT="100m"
        PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT="100Mi"

        echo "small"

    elif [ "$total_pods" -lt 500 ]; then
        # ── Medium ──
        PROMETHEUS_CPU_REQUEST="420m"
        PROMETHEUS_MEMORY_REQUEST="2834Mi"
        PROMETHEUS_CPU_LIMIT="420m"
        PROMETHEUS_MEMORY_LIMIT="2834Mi"

        OPENCOST_CPU_REQUEST="240m"
        OPENCOST_MEMORY_REQUEST="400Mi"
        OPENCOST_CPU_LIMIT="240m"
        OPENCOST_MEMORY_LIMIT="400Mi"

        ONELENS_CPU_REQUEST="125m"
        ONELENS_MEMORY_REQUEST="480Mi"
        ONELENS_CPU_LIMIT="375m"
        ONELENS_MEMORY_LIMIT="640Mi"

        KSM_CPU_REQUEST="120m"
        KSM_MEMORY_REQUEST="256Mi"
        KSM_CPU_LIMIT="120m"
        KSM_MEMORY_LIMIT="256Mi"

        PROMETHEUS_PUSHGATEWAY_CPU_REQUEST="100m"
        PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST="100Mi"
        PROMETHEUS_PUSHGATEWAY_CPU_LIMIT="100m"
        PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT="100Mi"

        echo "medium"

    elif [ "$total_pods" -lt 1000 ]; then
        # ── Large ──
        PROMETHEUS_CPU_REQUEST="1200m"
        PROMETHEUS_MEMORY_REQUEST="5653Mi"
        PROMETHEUS_CPU_LIMIT="1200m"
        PROMETHEUS_MEMORY_LIMIT="5653Mi"

        OPENCOST_CPU_REQUEST="300m"
        OPENCOST_MEMORY_REQUEST="576Mi"
        OPENCOST_CPU_LIMIT="300m"
        OPENCOST_MEMORY_LIMIT="576Mi"

        ONELENS_CPU_REQUEST="125m"
        ONELENS_MEMORY_REQUEST="640Mi"
        ONELENS_CPU_LIMIT="440m"
        ONELENS_MEMORY_LIMIT="800Mi"

        KSM_CPU_REQUEST="120m"
        KSM_MEMORY_REQUEST="384Mi"
        KSM_CPU_LIMIT="120m"
        KSM_MEMORY_LIMIT="384Mi"

        PROMETHEUS_PUSHGATEWAY_CPU_REQUEST="100m"
        PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST="100Mi"
        PROMETHEUS_PUSHGATEWAY_CPU_LIMIT="100m"
        PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT="100Mi"

        echo "large"

    elif [ "$total_pods" -lt 1500 ]; then
        # ── Extra Large ──
        PROMETHEUS_CPU_REQUEST="1380m"
        PROMETHEUS_MEMORY_REQUEST="8640Mi"
        PROMETHEUS_CPU_LIMIT="1380m"
        PROMETHEUS_MEMORY_LIMIT="8640Mi"

        OPENCOST_CPU_REQUEST="300m"
        OPENCOST_MEMORY_REQUEST="720Mi"
        OPENCOST_CPU_LIMIT="300m"
        OPENCOST_MEMORY_LIMIT="720Mi"

        ONELENS_CPU_REQUEST="125m"
        ONELENS_MEMORY_REQUEST="800Mi"
        ONELENS_CPU_LIMIT="500m"
        ONELENS_MEMORY_LIMIT="960Mi"

        KSM_CPU_REQUEST="300m"
        KSM_MEMORY_REQUEST="640Mi"
        KSM_CPU_LIMIT="300m"
        KSM_MEMORY_LIMIT="640Mi"

        PROMETHEUS_PUSHGATEWAY_CPU_REQUEST="250m"
        PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST="400Mi"
        PROMETHEUS_PUSHGATEWAY_CPU_LIMIT="250m"
        PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT="400Mi"

        echo "extra-large"

    else
        # ── Very Large (1500+) ──
        PROMETHEUS_CPU_REQUEST="1800m"
        PROMETHEUS_MEMORY_REQUEST="11306Mi"
        PROMETHEUS_CPU_LIMIT="1800m"
        PROMETHEUS_MEMORY_LIMIT="11306Mi"

        OPENCOST_CPU_REQUEST="360m"
        OPENCOST_MEMORY_REQUEST="960Mi"
        OPENCOST_CPU_LIMIT="360m"
        OPENCOST_MEMORY_LIMIT="960Mi"

        ONELENS_CPU_REQUEST="190m"
        ONELENS_MEMORY_REQUEST="960Mi"
        ONELENS_CPU_LIMIT="565m"
        ONELENS_MEMORY_LIMIT="1280Mi"

        KSM_CPU_REQUEST="300m"
        KSM_MEMORY_REQUEST="640Mi"
        KSM_CPU_LIMIT="300m"
        KSM_MEMORY_LIMIT="640Mi"

        PROMETHEUS_PUSHGATEWAY_CPU_REQUEST="250m"
        PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST="400Mi"
        PROMETHEUS_PUSHGATEWAY_CPU_LIMIT="250m"
        PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT="400Mi"

        echo "very-large"
    fi
}

###############################################################################
# Tier selection — retention & volume sizing
###############################################################################

# select_retention_tier "$total_pods"
# Set PROMETHEUS_RETENTION, PROMETHEUS_RETENTION_SIZE, and
# PROMETHEUS_VOLUME_SIZE based on pod-count thresholds.
select_retention_tier() {
    local total_pods="$1"

    PROMETHEUS_RETENTION="10d"

    if [ "$total_pods" -lt 50 ]; then
        PROMETHEUS_RETENTION_SIZE="4GB"
        PROMETHEUS_VOLUME_SIZE="8Gi"
    elif [ "$total_pods" -lt 100 ]; then
        PROMETHEUS_RETENTION_SIZE="6GB"
        PROMETHEUS_VOLUME_SIZE="10Gi"
    elif [ "$total_pods" -lt 500 ]; then
        PROMETHEUS_RETENTION_SIZE="12GB"
        PROMETHEUS_VOLUME_SIZE="20Gi"
    elif [ "$total_pods" -lt 1000 ]; then
        PROMETHEUS_RETENTION_SIZE="20GB"
        PROMETHEUS_VOLUME_SIZE="30Gi"
    elif [ "$total_pods" -lt 1500 ]; then
        PROMETHEUS_RETENTION_SIZE="30GB"
        PROMETHEUS_VOLUME_SIZE="40Gi"
    else
        PROMETHEUS_RETENTION_SIZE="35GB"
        PROMETHEUS_VOLUME_SIZE="50Gi"
    fi
}
# --- End embedded content ---
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
  OPENCOST_CPU_REQUEST=$(_max_cpu "$OPENCOST_CPU_REQUEST" "$(_get '.["prometheus-opencost-exporter"].opencost.exporter.resources.requests.cpu')")
  OPENCOST_MEMORY_REQUEST=$(_max_memory "$OPENCOST_MEMORY_REQUEST" "$(_get '.["prometheus-opencost-exporter"].opencost.exporter.resources.requests.memory')")
  OPENCOST_CPU_LIMIT=$(_max_cpu "$OPENCOST_CPU_LIMIT" "$(_get '.["prometheus-opencost-exporter"].opencost.exporter.resources.limits.cpu')")
  OPENCOST_MEMORY_LIMIT=$(_max_memory "$OPENCOST_MEMORY_LIMIT" "$(_get '.["prometheus-opencost-exporter"].opencost.exporter.resources.limits.memory')")
  ONELENS_CPU_REQUEST=$(_max_cpu "$ONELENS_CPU_REQUEST" "$(_get '.["onelens-agent"].resources.requests.cpu')")
  ONELENS_MEMORY_REQUEST=$(_max_memory "$ONELENS_MEMORY_REQUEST" "$(_get '.["onelens-agent"].resources.requests.memory')")
  ONELENS_CPU_LIMIT=$(_max_cpu "$ONELENS_CPU_LIMIT" "$(_get '.["onelens-agent"].resources.limits.cpu')")
  ONELENS_MEMORY_LIMIT=$(_max_memory "$ONELENS_MEMORY_LIMIT" "$(_get '.["onelens-agent"].resources.limits.memory')")
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
