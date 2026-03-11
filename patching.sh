#!/bin/bash
# Phase 1: Prerequisite Checks
echo "Checking prerequisites..."

HELM_VERSION="v3.13.2"
KUBECTL_VERSION="v1.28.2"

ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then
    ARCH_TYPE="amd64"
elif [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
    ARCH_TYPE="arm64"
else
    echo "Unsupported architecture: $ARCH"
    exit 1
fi

# Phase 2: Install Helm and kubectl (quiet)
echo "Installing helm ${HELM_VERSION} and kubectl ${KUBECTL_VERSION} (${ARCH_TYPE})..."
curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH_TYPE}.tar.gz" -o helm.tar.gz && \
    tar -xzf helm.tar.gz && \
    mv linux-${ARCH_TYPE}/helm /usr/local/bin/helm && \
    rm -rf linux-${ARCH_TYPE} helm.tar.gz

curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH_TYPE}/kubectl" -o kubectl && \
    chmod +x kubectl && \
    mv kubectl /usr/local/bin/kubectl

if ! command -v helm &>/dev/null || ! command -v kubectl &>/dev/null; then
    echo "Error: helm or kubectl installation failed."
    exit 1
fi
echo "Tools ready: helm $(helm version --short 2>/dev/null), kubectl $(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion' 2>/dev/null || echo 'unknown')"

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
# Sets TIER variable with the tier name. Must be called without $() subshell.
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

        TIER="tiny"

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

        TIER="small"

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

        TIER="medium"

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

        TIER="large"

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

        TIER="extra-large"

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

        TIER="very-large"
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
# Enforce desired state every run to correct any manual or chart-default drift.
PROMETHEUS_CONFIGMAP_RELOAD_CPU_REQUEST="10m"
PROMETHEUS_CONFIGMAP_RELOAD_MEMORY_REQUEST="32Mi"
PROMETHEUS_CONFIGMAP_RELOAD_CPU_LIMIT="10m"
PROMETHEUS_CONFIGMAP_RELOAD_MEMORY_LIMIT="32Mi"

# Phase 4.5: Read customer-specific values from existing release
# These are values the customer set during install that must be preserved.
# Everything else (images, configs, resources) comes fresh from the chart.

CURRENT_VALUES=$(helm get values onelens-agent -n onelens-agent -a -o json 2>/dev/null || true)

if [[ -n "$CURRENT_VALUES" ]] && command -v jq &>/dev/null; then
  echo "Reading customer-specific values from existing release..."
  _get() { echo "$CURRENT_VALUES" | jq -r "$1 // empty"; }

  # Identity values (set during install, never change)
  CLUSTER_NAME=$(_get '.["onelens-agent"].env.CLUSTER_NAME')
  ACCOUNT_ID=$(_get '.["onelens-agent"].env.ACCOUNT_ID')
  API_BASE_URL=$(_get '.["onelens-agent"].secrets.API_BASE_URL')
  CLUSTER_TOKEN=$(_get '.["onelens-agent"].secrets.CLUSTER_TOKEN')
  REGISTRATION_ID=$(_get '.["onelens-agent"].secrets.REGISTRATION_ID')
  DEFAULT_CLUSTER_ID=$(_get '.["prometheus-opencost-exporter"].opencost.exporter.defaultClusterId')
  PVC_ENABLED=$(_get '.prometheus.server.persistentVolume.enabled')

  # Detect cloud provider from existing StorageClass provisioner
  SC_PROVISIONER=$(_get '.["onelens-agent"].storageClass.provisioner')

  echo "  Cluster: $CLUSTER_NAME | Cloud: $SC_PROVISIONER | PVC: $PVC_ENABLED"

  # Extract complex customer values (tolerations, nodeSelector, podLabels) into temp file
  # These are hard to pass via --set due to arrays and special characters in keys
  CUSTOMER_VALUES_FILE=$(mktemp)
  echo "$CURRENT_VALUES" | jq '{
    prometheus: {
      server: {
        tolerations: (.prometheus.server.tolerations // []),
        nodeSelector: (.prometheus.server.nodeSelector // {}),
        podLabels: (.prometheus.server.podLabels // {})
      },
      "kube-state-metrics": {
        tolerations: (.prometheus["kube-state-metrics"].tolerations // []),
        nodeSelector: (.prometheus["kube-state-metrics"].nodeSelector // {}),
        podLabels: (.prometheus["kube-state-metrics"].podLabels // {})
      },
      "prometheus-pushgateway": {
        tolerations: (.prometheus["prometheus-pushgateway"].tolerations // []),
        nodeSelector: (.prometheus["prometheus-pushgateway"].nodeSelector // {}),
        podLabels: (.prometheus["prometheus-pushgateway"].podLabels // {})
      }
    },
    "prometheus-opencost-exporter": {
      opencost: {
        tolerations: (.["prometheus-opencost-exporter"].opencost.tolerations // []),
        nodeSelector: (.["prometheus-opencost-exporter"].opencost.nodeSelector // {})
      },
      podLabels: (.["prometheus-opencost-exporter"].podLabels // {})
    },
    "onelens-agent": {
      cronJob: {
        tolerations: (.["onelens-agent"].cronJob.tolerations // []),
        nodeSelector: (.["onelens-agent"].cronJob.nodeSelector // {}),
        podLabels: (.["onelens-agent"].cronJob.podLabels // {})
      },
      storageClass: (.["onelens-agent"].storageClass // {})
    }
  }' > "$CUSTOMER_VALUES_FILE" 2>/dev/null || true

  # Read PVC size from existing PVC (not from helm values — PVC may have been resized)
  EXISTING_PVC_SIZE=$(kubectl get pvc onelens-agent-prometheus-server -n onelens-agent \
      -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null || true)
  if [ -z "$EXISTING_PVC_SIZE" ]; then
      EXISTING_PVC_SIZE=$(_get '.prometheus.server.persistentVolume.size')
  fi
else
  echo "WARNING: Could not read existing release values. Using defaults."
  CLUSTER_NAME=""
  ACCOUNT_ID=""
  API_BASE_URL="https://api-in.onelens.cloud"
  CLUSTER_TOKEN=""
  REGISTRATION_ID=""
  DEFAULT_CLUSTER_ID=""
  PVC_ENABLED="true"
  SC_PROVISIONER=""
  CUSTOMER_VALUES_FILE=""
  EXISTING_PVC_SIZE=""
fi

# Validate required identity values
if [ -z "$CLUSTER_TOKEN" ] || [ -z "$REGISTRATION_ID" ]; then
    echo "ERROR: Could not read CLUSTER_TOKEN or REGISTRATION_ID from existing release."
    echo "These are required for helm upgrade. Check if onelens-agent is installed."
    exit 1
fi

# Phase 5: Capture pre-patch state for diagnostics

echo ""
echo "========== PRE-PATCH STATE =========="

# Helm release info
echo "--- Helm Release ---"
helm list -n onelens-agent --no-headers 2>/dev/null || echo "(helm list failed)"

# Pod status in onelens-agent namespace
echo "--- Pod Status (onelens-agent namespace) ---"
kubectl get pods -n onelens-agent -o wide --no-headers 2>/dev/null || echo "(kubectl get pods failed)"

# Node summary
echo "--- Nodes ---"
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
echo "Total nodes: $NODE_COUNT"
kubectl get nodes --no-headers -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[-1].type,VERSION:.status.nodeInfo.kubeletVersion' 2>/dev/null || true

# Current resource configuration from helm values
echo "--- Current Resource Configuration ---"
if [[ -n "$CURRENT_VALUES" ]] && command -v jq &>/dev/null; then
  echo "Prometheus server:"
  echo "  requests: cpu=$(_get '.prometheus.server.resources.requests.cpu') memory=$(_get '.prometheus.server.resources.requests.memory')"
  echo "  limits:   cpu=$(_get '.prometheus.server.resources.limits.cpu') memory=$(_get '.prometheus.server.resources.limits.memory')"
  echo "OpenCost exporter:"
  echo "  requests: cpu=$(_get '.["prometheus-opencost-exporter"].opencost.exporter.resources.requests.cpu') memory=$(_get '.["prometheus-opencost-exporter"].opencost.exporter.resources.requests.memory')"
  echo "  limits:   cpu=$(_get '.["prometheus-opencost-exporter"].opencost.exporter.resources.limits.cpu') memory=$(_get '.["prometheus-opencost-exporter"].opencost.exporter.resources.limits.memory')"
  echo "OneLens Agent:"
  echo "  requests: cpu=$(_get '.["onelens-agent"].resources.requests.cpu') memory=$(_get '.["onelens-agent"].resources.requests.memory')"
  echo "  limits:   cpu=$(_get '.["onelens-agent"].resources.limits.cpu') memory=$(_get '.["onelens-agent"].resources.limits.memory')"
  echo "KSM:"
  echo "  requests: cpu=$(_get '.prometheus["kube-state-metrics"].resources.requests.cpu') memory=$(_get '.prometheus["kube-state-metrics"].resources.requests.memory')"
  echo "  limits:   cpu=$(_get '.prometheus["kube-state-metrics"].resources.limits.cpu') memory=$(_get '.prometheus["kube-state-metrics"].resources.limits.memory')"
  echo "Pushgateway:"
  echo "  requests: cpu=$(_get '.prometheus["prometheus-pushgateway"].resources.requests.cpu') memory=$(_get '.prometheus["prometheus-pushgateway"].resources.requests.memory')"
  echo "  limits:   cpu=$(_get '.prometheus["prometheus-pushgateway"].resources.limits.cpu') memory=$(_get '.prometheus["prometheus-pushgateway"].resources.limits.memory')"
  echo "Configmap-reload:"
  echo "  requests: cpu=$(_get '.prometheus.configmapReload.prometheus.resources.requests.cpu') memory=$(_get '.prometheus.configmapReload.prometheus.resources.requests.memory')"
  echo "  limits:   cpu=$(_get '.prometheus.configmapReload.prometheus.resources.limits.cpu') memory=$(_get '.prometheus.configmapReload.prometheus.resources.limits.memory')"
  echo "Image tags:"
  echo "  onelens-agent: $(_get '.["onelens-agent"].image.tag')"
  echo "  opencost: $(_get '.["prometheus-opencost-exporter"].opencost.exporter.image.tag')"
else
  echo "(helm values not available or jq missing)"
fi

# Events in our namespace (catches OOMKilled, CrashLoopBackOff, etc.)
echo "--- Recent Events (onelens-agent namespace, last 10) ---"
kubectl get events -n onelens-agent --sort-by='.lastTimestamp' --no-headers 2>/dev/null | tail -10 || echo "(no events)"

echo "========== END PRE-PATCH STATE =========="
echo ""

# Phase 5.5: Prometheus PV recovery — detect and fix broken volume
# If the underlying disk (EBS/Azure) was deleted, the PVC stays bound to a ghost PV.
# Prometheus pod gets stuck in ContainerCreating with FailedAttachVolume/FailedMount.
# However, if the pod was already running when the disk was deleted, it keeps running
# (volume is cached in kernel VFS) but TSDB writes fail silently. Data collection breaks
# but kubectl shows the pod as Running and PV/PVC as Bound — no visible error.
# To detect this: query Prometheus health endpoint. If unhealthy and pod is Running,
# restart the pod to surface the FailedMount, then the recovery logic handles it.
# Recovery: delete the broken PVC so helm upgrade recreates it using the existing
# StorageClass (onelens-sc), which preserves encryption and KMS settings from install.

echo "Checking Prometheus health..."

# Get the Prometheus service endpoint
PROM_SVC=$(kubectl get svc -n onelens-agent --no-headers 2>/dev/null | awk '/prometheus-server/{print $1; exit}' || true)
PROM_POD_PRE=$(kubectl get pods -n onelens-agent --no-headers 2>/dev/null | awk '/prometheus-server/{print $1; exit}' || true)
PROM_POD_STATUS_PRE=""
if [ -n "$PROM_POD_PRE" ]; then
    PROM_POD_STATUS_PRE=$(kubectl get pod "$PROM_POD_PRE" -n onelens-agent -o jsonpath='{.status.phase}' 2>/dev/null || true)
fi

if [ -n "$PROM_POD_PRE" ] && [ "$PROM_POD_STATUS_PRE" = "Running" ]; then
    # Pod is Running — check for TSDB I/O errors in logs (indicates underlying disk is gone).
    # The /-/healthy and /-/ready endpoints still return 200 even when disk is deleted,
    # because Prometheus HTTP server runs from memory. Only TSDB logs reveal the truth.
    TSDB_ERRORS=$(kubectl logs "$PROM_POD_PRE" -n onelens-agent -c prometheus-server --tail=50 2>/dev/null \
        | grep -c 'input/output error' || true)
    if [ "$TSDB_ERRORS" -gt 0 ] 2>/dev/null; then
        echo "Prometheus pod is Running but has $TSDB_ERRORS TSDB I/O errors — underlying disk is gone."
        echo "Restarting pod to surface volume mount failure..."
        kubectl delete pod "$PROM_POD_PRE" -n onelens-agent --grace-period=10 2>/dev/null || true

        # Wait for old pod to terminate and new pod to attempt mount
        echo "Waiting for pod restart..."
        for _rw in 1 2 3 4 5 6; do
            sleep 10
            NEW_POD=$(kubectl get pods -n onelens-agent --no-headers 2>/dev/null \
                | grep 'prometheus-server' | grep -v 'Terminating' | awk '{print $1; exit}' || true)
            if [ -n "$NEW_POD" ] && [ "$NEW_POD" != "$PROM_POD_PRE" ]; then
                NEW_POD_STATUS=$(kubectl get pod "$NEW_POD" -n onelens-agent -o jsonpath='{.status.phase}' 2>/dev/null || true)
                echo "New pod '$NEW_POD': status=$NEW_POD_STATUS"
                # If Running, it remounted fine — was a transient issue
                # If Pending/ContainerCreating, volume mount is failing — recovery will handle
                break
            fi
            echo "Waiting for new pod... (attempt $_rw/6)"
        done
    else
        echo "Prometheus TSDB is healthy (no I/O errors)."
    fi
fi

echo "Checking Prometheus persistent volume health..."
PROM_PVC_NAME=$(kubectl get pvc -n onelens-agent -l "app.kubernetes.io/name=prometheus,app.kubernetes.io/component=server" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

# Fallback: try common PVC name patterns if label selector found nothing
if [ -z "$PROM_PVC_NAME" ]; then
    PROM_PVC_NAME=$(kubectl get pvc -n onelens-agent -o jsonpath='{.items[?(@.metadata.name=="onelens-agent-prometheus-server")].metadata.name}' 2>/dev/null || true)
fi
if [ -z "$PROM_PVC_NAME" ]; then
    PROM_PVC_NAME=$(kubectl get pvc -n onelens-agent --no-headers 2>/dev/null | awk '/prometheus-server/{print $1; exit}' || true)
fi


_PV_NEEDS_MANUAL_FIX=false

# _do_pv_recovery "$pvc_name" "$pv_name" "$old_size"
# Logs PV recovery error with manual remediation steps.
# We intentionally do NOT have cluster-scoped delete/patch permissions on PVs
# because that would grant access to ALL PVs in the cluster (security concern).
# PV recovery must be performed manually by the customer or support team.
_do_pv_recovery() {
    local pvc_name="$1" pv_name="$2" old_size="$3"

    echo ""
    echo "ERROR: Prometheus PV recovery required — manual intervention needed."
    echo "The deployer does not have permissions to delete/patch PersistentVolumes (cluster-scoped security restriction)."
    echo ""
    echo "Manual remediation steps:"
    if [ -n "$pv_name" ]; then
        echo "  1. kubectl patch pv $pv_name -p '{\"metadata\":{\"finalizers\":null}}'"
        echo "  2. kubectl delete pv $pv_name"
        echo "  3. kubectl patch pvc $pvc_name -n onelens-agent -p '{\"metadata\":{\"finalizers\":null}}'"
        echo "  4. kubectl delete pvc $pvc_name -n onelens-agent"
    else
        echo "  1. kubectl patch pvc $pvc_name -n onelens-agent -p '{\"metadata\":{\"finalizers\":null}}'"
        echo "  2. kubectl delete pvc $pvc_name -n onelens-agent"
    fi
    echo "  Then re-run patching to apply the upgrade."
    if [ -n "$old_size" ]; then
        echo ""
        echo "Note: Current PVC size is $old_size. Ensure helm values match if PVC was resized outside helm."
    fi
    echo ""
    return 1
}

if [ -n "$PROM_PVC_NAME" ]; then
    # Get the PV name this PVC is bound to
    BOUND_PV=$(kubectl get pvc "$PROM_PVC_NAME" -n onelens-agent -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)

    if [ -n "$BOUND_PV" ]; then
        # Check 1: Does the PV object still exist?
        PV_EXISTS=$(kubectl get pv "$BOUND_PV" --no-headers 2>/dev/null || true)

        if [ -z "$PV_EXISTS" ]; then
            # Log the old PVC details before deleting
            OLD_PVC_SIZE=$(kubectl get pvc "$PROM_PVC_NAME" -n onelens-agent -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null || true)
            OLD_PVC_SC=$(kubectl get pvc "$PROM_PVC_NAME" -n onelens-agent -o jsonpath='{.spec.storageClassName}' 2>/dev/null || true)
            PVC_STATUS=$(kubectl get pvc "$PROM_PVC_NAME" -n onelens-agent -o jsonpath='{.status.phase}' 2>/dev/null || true)
            echo "PV '$BOUND_PV' referenced by PVC '$PROM_PVC_NAME' does not exist."
            echo "Old PVC: size=$OLD_PVC_SIZE storageClass=$OLD_PVC_SC status=$PVC_STATUS"

            # Check 2: Confirm PVC is in Lost state, or pod is not running due to volume issues
            # When PV is deleted, PVC goes to "Lost" and pod gets FailedScheduling (not even FailedMount).
            PROM_POD=$(kubectl get pods -n onelens-agent --no-headers 2>/dev/null | awk '/prometheus-server/{print $1; exit}' || true)
            POD_STATUS=""
            POD_ISSUES=""
            if [ -n "$PROM_POD" ]; then
                POD_STATUS=$(kubectl get pod "$PROM_POD" -n onelens-agent -o jsonpath='{.status.phase}' 2>/dev/null || true)
                POD_ISSUES=$(kubectl describe pod "$PROM_POD" -n onelens-agent 2>/dev/null \
                    | grep -E 'FailedAttachVolume|FailedMount|AttachVolume.Attach failed|FailedScheduling|bound to non-existent' || true)
            fi

            # Recovery if: PVC is Lost, OR pod has volume/scheduling errors, OR pod is not Running
            if [ "$PVC_STATUS" = "Lost" ] || [ -n "$POD_ISSUES" ] || [ "$POD_STATUS" = "Pending" ]; then
                echo "Prometheus pod: status=$POD_STATUS"
                if [ -n "$POD_ISSUES" ]; then
                    echo "Pod issues:"
                    echo "$POD_ISSUES"
                fi

                _do_pv_recovery "$PROM_PVC_NAME" "" "$OLD_PVC_SIZE" || _PV_NEEDS_MANUAL_FIX=true
            else
                echo "PV is missing but PVC is '$PVC_STATUS' and pod is '$POD_STATUS'. Skipping recovery."
            fi
        else
            # PV exists — check if it's in a failed state
            PV_STATUS=$(kubectl get pv "$BOUND_PV" -o jsonpath='{.status.phase}' 2>/dev/null || true)
            if [ "$PV_STATUS" = "Failed" ] || [ "$PV_STATUS" = "Released" ]; then
                OLD_PVC_SIZE=$(kubectl get pvc "$PROM_PVC_NAME" -n onelens-agent -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null || true)
                OLD_PVC_SC=$(kubectl get pvc "$PROM_PVC_NAME" -n onelens-agent -o jsonpath='{.spec.storageClassName}' 2>/dev/null || true)
                echo "PV '$BOUND_PV' exists but is in '$PV_STATUS' state."
                echo "Old PVC: size=$OLD_PVC_SIZE storageClass=$OLD_PVC_SC"

                PROM_POD=$(kubectl get pods -n onelens-agent --no-headers 2>/dev/null | awk '/prometheus-server/{print $1; exit}' || true)
                POD_STATUS=""
                POD_ISSUES=""
                if [ -n "$PROM_POD" ]; then
                    POD_STATUS=$(kubectl get pod "$PROM_POD" -n onelens-agent -o jsonpath='{.status.phase}' 2>/dev/null || true)
                    POD_ISSUES=$(kubectl describe pod "$PROM_POD" -n onelens-agent 2>/dev/null \
                        | grep -E 'FailedAttachVolume|FailedMount|AttachVolume.Attach failed|FailedScheduling|bound to non-existent' || true)
                fi

                if [ -n "$POD_ISSUES" ] || [ "$POD_STATUS" = "Pending" ] || [ "$POD_STATUS" != "Running" ]; then
                    echo "Prometheus pod: status=$POD_STATUS"
                    if [ -n "$POD_ISSUES" ]; then
                        echo "Pod issues:"
                        echo "$POD_ISSUES"
                    fi
                    _do_pv_recovery "$PROM_PVC_NAME" "$BOUND_PV" "$OLD_PVC_SIZE" || _PV_NEEDS_MANUAL_FIX=true
                else
                    echo "PV is in '$PV_STATUS' state but pod is '$POD_STATUS'. Skipping recovery."
                fi
            else
                # PV exists and status looks fine — but underlying disk may be deleted.
                # Check if pod has FailedMount errors (EBS gone but PV/PVC still show Bound).
                PROM_POD=$(kubectl get pods -n onelens-agent --no-headers 2>/dev/null | awk '/prometheus-server/{print $1; exit}' || true)
                POD_STATUS=""
                MOUNT_ERRORS=""
                if [ -n "$PROM_POD" ]; then
                    POD_STATUS=$(kubectl get pod "$PROM_POD" -n onelens-agent -o jsonpath='{.status.phase}' 2>/dev/null || true)
                    MOUNT_ERRORS=$(kubectl describe pod "$PROM_POD" -n onelens-agent 2>/dev/null \
                        | grep -E 'FailedAttachVolume|FailedMount|AttachVolume.Attach failed' || true)
                fi

                if [ -n "$MOUNT_ERRORS" ] && [ "$POD_STATUS" != "Running" ]; then
                    OLD_PVC_SIZE=$(kubectl get pvc "$PROM_PVC_NAME" -n onelens-agent -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null || true)
                    OLD_PVC_SC=$(kubectl get pvc "$PROM_PVC_NAME" -n onelens-agent -o jsonpath='{.spec.storageClassName}' 2>/dev/null || true)
                    echo "PV '$BOUND_PV' exists (status: $PV_STATUS) but underlying disk is gone."
                    echo "Old PVC: size=$OLD_PVC_SIZE storageClass=$OLD_PVC_SC"
                    echo "Prometheus pod: status=$POD_STATUS"
                    echo "Mount errors:"
                    echo "$MOUNT_ERRORS"

                    _do_pv_recovery "$PROM_PVC_NAME" "$BOUND_PV" "$OLD_PVC_SIZE" || _PV_NEEDS_MANUAL_FIX=true
                else
                    CURRENT_PVC_SIZE=$(kubectl get pvc "$PROM_PVC_NAME" -n onelens-agent -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null || true)
                    CURRENT_PVC_SC=$(kubectl get pvc "$PROM_PVC_NAME" -n onelens-agent -o jsonpath='{.spec.storageClassName}' 2>/dev/null || true)
                    echo "Prometheus PV '$BOUND_PV' is healthy (status: $PV_STATUS)."
                    echo "PVC: name=$PROM_PVC_NAME size=$CURRENT_PVC_SIZE storageClass=$CURRENT_PVC_SC"
                fi
            fi
        fi
    else
        echo "PVC '$PROM_PVC_NAME' has no bound PV (may be Pending). Helm upgrade will handle provisioning."
    fi
else
    echo "No Prometheus PVC found in onelens-agent namespace. PV may not be enabled."
fi

# Phase 6: Helm Upgrade with Dynamic Resource Allocation

# Select retention tier based on pod count (sets PROMETHEUS_RETENTION, PROMETHEUS_RETENTION_SIZE, PROMETHEUS_VOLUME_SIZE)
select_retention_tier "$TOTAL_PODS"
echo "Retention tier: retention=$PROMETHEUS_RETENTION retentionSize=$PROMETHEUS_RETENTION_SIZE volumeSize=$PROMETHEUS_VOLUME_SIZE"

# Use existing PVC size if larger than tier default (PVC may have been manually resized)
if [ -n "$EXISTING_PVC_SIZE" ]; then
    EXISTING_SIZE_GI=$(echo "$EXISTING_PVC_SIZE" | sed 's/Gi//')
    TIER_SIZE_GI=$(echo "$PROMETHEUS_VOLUME_SIZE" | sed 's/Gi//')
    if [ "$EXISTING_SIZE_GI" -gt "$TIER_SIZE_GI" ] 2>/dev/null; then
        echo "Existing PVC size ($EXISTING_PVC_SIZE) is larger than tier default ($PROMETHEUS_VOLUME_SIZE). Keeping existing size."
        PROMETHEUS_VOLUME_SIZE="$EXISTING_PVC_SIZE"
    fi
fi

# Check for existing bound PVC to preserve data across upgrades
EXISTING_CLAIM_FLAG=""
PVC_NAME="onelens-agent-prometheus-server"
if kubectl get pvc "$PVC_NAME" -n onelens-agent &>/dev/null; then
    PVC_STATUS=$(kubectl get pvc "$PVC_NAME" -n onelens-agent -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [ "$PVC_STATUS" = "Bound" ]; then
        echo "Found existing Bound PVC '$PVC_NAME' — reusing to preserve prometheus data."
        EXISTING_CLAIM_FLAG="--set prometheus.server.persistentVolume.existingClaim=$PVC_NAME"
    fi
fi

helm repo add onelens https://astuto-ai.github.io/onelens-installation-scripts >/dev/null 2>&1
helm repo update >/dev/null 2>&1

if [ "$_PV_NEEDS_MANUAL_FIX" = "true" ]; then
    echo "Skipping helm upgrade — Prometheus PV requires manual recovery first."
    echo "After manual recovery, re-run patching to apply resource updates."
    exit 1
fi

# Build helm upgrade command
# Key design: NO --reuse-values, NO --version
#   - globalvalues.yaml provides chart defaults (images, configs, scrape jobs)
#   - Customer values file preserves tolerations, nodeSelector, podLabels, storageClass
#   - --set overrides for identity, resources, retention, PVC
#   - Without --version, helm uses latest chart from repo (auto-converge to latest)
HELM_CMD="helm upgrade onelens-agent onelens/onelens-agent \
  -f /globalvalues.yaml \
  --history-max 200 \
  --atomic \
  --timeout=5m \
  --namespace onelens-agent"

# Apply customer values (tolerations, nodeSelector, podLabels, storageClass)
if [ -n "$CUSTOMER_VALUES_FILE" ] && [ -f "$CUSTOMER_VALUES_FILE" ]; then
    HELM_CMD="$HELM_CMD -f $CUSTOMER_VALUES_FILE"
fi

# Identity values (preserved from existing release)
HELM_CMD="$HELM_CMD \
  --set onelens-agent.env.CLUSTER_NAME=\"$CLUSTER_NAME\" \
  --set-string onelens-agent.env.ACCOUNT_ID=\"$ACCOUNT_ID\" \
  --set onelens-agent.secrets.API_BASE_URL=\"$API_BASE_URL\" \
  --set onelens-agent.secrets.CLUSTER_TOKEN=\"$CLUSTER_TOKEN\" \
  --set onelens-agent.secrets.REGISTRATION_ID=\"$REGISTRATION_ID\" \
  --set prometheus-opencost-exporter.opencost.exporter.defaultClusterId=\"$DEFAULT_CLUSTER_ID\""

# PVC settings
HELM_CMD="$HELM_CMD \
  --set prometheus.server.persistentVolume.enabled=\"$PVC_ENABLED\" \
  $EXISTING_CLAIM_FLAG \
  --set-string prometheus.server.persistentVolume.size=\"$PROMETHEUS_VOLUME_SIZE\""

# StorageClass provisioner (preserve cloud provider setting from install)
if [ -n "$SC_PROVISIONER" ]; then
    HELM_CMD="$HELM_CMD --set onelens-agent.storageClass.provisioner=\"$SC_PROVISIONER\""
fi

# Retention settings
HELM_CMD="$HELM_CMD \
  --set-string prometheus.server.retention=\"$PROMETHEUS_RETENTION\" \
  --set-string prometheus.server.retentionSize=\"$PROMETHEUS_RETENTION_SIZE\""

# Resource allocations (dynamically calculated based on cluster size)
HELM_CMD="$HELM_CMD \
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
  --set prometheus.prometheus-pushgateway.resources.requests.cpu=\"$PROMETHEUS_PUSHGATEWAY_CPU_REQUEST\" \
  --set prometheus.prometheus-pushgateway.resources.requests.memory=\"$PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST\" \
  --set prometheus.prometheus-pushgateway.resources.limits.cpu=\"$PROMETHEUS_PUSHGATEWAY_CPU_LIMIT\" \
  --set prometheus.prometheus-pushgateway.resources.limits.memory=\"$PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT\" \
  --set prometheus.kube-state-metrics.resources.requests.cpu=\"$KSM_CPU_REQUEST\" \
  --set prometheus.kube-state-metrics.resources.requests.memory=\"$KSM_MEMORY_REQUEST\" \
  --set prometheus.kube-state-metrics.resources.limits.cpu=\"$KSM_CPU_LIMIT\" \
  --set prometheus.kube-state-metrics.resources.limits.memory=\"$KSM_MEMORY_LIMIT\" \
  --set prometheus.configmapReload.prometheus.resources.requests.cpu=\"$PROMETHEUS_CONFIGMAP_RELOAD_CPU_REQUEST\" \
  --set prometheus.configmapReload.prometheus.resources.requests.memory=\"$PROMETHEUS_CONFIGMAP_RELOAD_MEMORY_REQUEST\" \
  --set prometheus.configmapReload.prometheus.resources.limits.cpu=\"$PROMETHEUS_CONFIGMAP_RELOAD_CPU_LIMIT\" \
  --set prometheus.configmapReload.prometheus.resources.limits.memory=\"$PROMETHEUS_CONFIGMAP_RELOAD_MEMORY_LIMIT\""

echo "Running helm upgrade (latest chart, fresh values + customer overrides)..."
eval "$HELM_CMD"

if [ $? -ne 0 ]; then
    echo "Upgrade failed and was automatically rolled back by --atomic flag"
    echo "--- Pod Status After Rollback ---"
    kubectl get pods -n onelens-agent -o wide --no-headers 2>/dev/null || true
    echo "--- Events After Rollback ---"
    kubectl get events -n onelens-agent --sort-by='.lastTimestamp' --no-headers 2>/dev/null | tail -10 || true
    exit 1
fi

# Clean up temp file
if [ -n "$CUSTOMER_VALUES_FILE" ] && [ -f "$CUSTOMER_VALUES_FILE" ]; then
    rm -f "$CUSTOMER_VALUES_FILE"
fi

# Wait for pods to stabilize after upgrade
echo "Waiting for pods to stabilize..."
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
    echo "WARNING: Pods did not fully stabilize within 60s"
fi

# Get the chart version that was actually deployed
DEPLOYED_VERSION=$(helm list -n onelens-agent -o json 2>/dev/null | jq -r '.[0].chart' | sed 's/onelens-agent-//' || echo "unknown")

echo ""
echo "========== POST-PATCH STATE =========="

echo "--- Applied Configuration ---"
echo "Chart: $DEPLOYED_VERSION | Tier: $TIER | Pods: $TOTAL_PODS | Labels: ${LABEL_MULTIPLIER}x"
echo "Retention: $PROMETHEUS_RETENTION | RetentionSize: $PROMETHEUS_RETENTION_SIZE | VolumeSize: $PROMETHEUS_VOLUME_SIZE"
echo "Prometheus server:"
echo "  requests: cpu=$PROMETHEUS_CPU_REQUEST memory=$PROMETHEUS_MEMORY_REQUEST"
echo "  limits:   cpu=$PROMETHEUS_CPU_LIMIT memory=$PROMETHEUS_MEMORY_LIMIT"
echo "OpenCost exporter:"
echo "  requests: cpu=$OPENCOST_CPU_REQUEST memory=$OPENCOST_MEMORY_REQUEST"
echo "  limits:   cpu=$OPENCOST_CPU_LIMIT memory=$OPENCOST_MEMORY_LIMIT"
echo "OneLens Agent:"
echo "  requests: cpu=$ONELENS_CPU_REQUEST memory=$ONELENS_MEMORY_REQUEST"
echo "  limits:   cpu=$ONELENS_CPU_LIMIT memory=$ONELENS_MEMORY_LIMIT"
echo "KSM:"
echo "  requests: cpu=$KSM_CPU_REQUEST memory=$KSM_MEMORY_REQUEST"
echo "  limits:   cpu=$KSM_CPU_LIMIT memory=$KSM_MEMORY_LIMIT"
echo "Pushgateway:"
echo "  requests: cpu=$PROMETHEUS_PUSHGATEWAY_CPU_REQUEST memory=$PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST"
echo "  limits:   cpu=$PROMETHEUS_PUSHGATEWAY_CPU_LIMIT memory=$PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT"
echo "Configmap-reload:"
echo "  requests: cpu=$PROMETHEUS_CONFIGMAP_RELOAD_CPU_REQUEST memory=$PROMETHEUS_CONFIGMAP_RELOAD_MEMORY_REQUEST"
echo "  limits:   cpu=$PROMETHEUS_CONFIGMAP_RELOAD_CPU_LIMIT memory=$PROMETHEUS_CONFIGMAP_RELOAD_MEMORY_LIMIT"

echo "--- Pod Status After Upgrade ---"
kubectl get pods -n onelens-agent -o wide --no-headers 2>/dev/null || echo "(kubectl get pods failed)"

echo "--- Helm Release After Upgrade ---"
helm list -n onelens-agent --no-headers 2>/dev/null || true

echo "========== END POST-PATCH STATE =========="
echo ""
echo "Patching complete. Chart: $DEPLOYED_VERSION | Pods: $TOTAL_PODS | Tier: $TIER"
