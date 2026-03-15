#!/bin/bash

# --- Log capture & reporting ---
# Captures all script output and sends it to the API as patching_logs on exit.
# Works regardless of which entrypoint.sh version is running this script.
_PATCH_LOG_FILE=$(mktemp 2>/dev/null || echo "/tmp/_patching_log_$$")
exec > >(tee -a "$_PATCH_LOG_FILE") 2>&1

_send_patching_logs() {
    local exit_code=$?
    # Close stdout/stderr to flush the tee subprocess before reading the log file
    exec 1>&- 2>&-
    sleep 1
    # Only send if we have credentials (extracted later in script from helm release)
    if [ -n "$REGISTRATION_ID" ] && [ -n "$CLUSTER_TOKEN" ]; then
        local log_content
        log_content=$(cat "$_PATCH_LOG_FILE" 2>/dev/null || true)
        # Truncate to 10000 chars
        if [ ${#log_content} -gt 10000 ]; then
            log_content="[truncated]...${log_content: -9900}"
        fi
        # Send only patching_logs — don't overwrite logs/patch_status/patching_enabled
        # (entrypoint.sh handles those fields separately)
        local payload
        payload=$(jq -n \
            --arg reg_id "$REGISTRATION_ID" \
            --arg token "$CLUSTER_TOKEN" \
            --arg plogs "$log_content" \
            '{registration_id: $reg_id, cluster_token: $token, update_data: {patching_logs: $plogs}}' 2>/dev/null)
        if [ -n "$payload" ]; then
            curl -s --max-time 10 --location --request PUT \
                "https://api-in.onelens.cloud/v1/kubernetes/cluster-version" \
                --header 'Content-Type: application/json' \
                --data "$payload" >/dev/null 2>&1 || true
        fi
    fi
    rm -f "$_PATCH_LOG_FILE"
    exit $exit_code
}
trap _send_patching_logs EXIT

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

# Immediately set 5-min schedule and raise activeDeadlineSeconds — ensures retries
# even if anything below fails, and prevents pod kill during 10m helm timeout.
# Without this, a daily-schedule cluster waits 24 hours on any failure, and an old
# deployer with low activeDeadlineSeconds kills the pod mid-helm-upgrade.
TARGET_SCHEDULE="*/5 * * * *"
TARGET_DEADLINE=900
CURRENT_SCHEDULE=$(kubectl get cronjob onelensupdater -n onelens-agent -o jsonpath='{.spec.schedule}' 2>/dev/null || true)
CURRENT_DEADLINE=$(kubectl get cronjob onelensupdater -n onelens-agent -o jsonpath='{.spec.activeDeadlineSeconds}' 2>/dev/null || true)

PATCH_JSON=""
if [ -n "$CURRENT_SCHEDULE" ] && [ "$CURRENT_SCHEDULE" != "$TARGET_SCHEDULE" ]; then
    PATCH_JSON="{\"spec\":{\"schedule\":\"$TARGET_SCHEDULE\""
    echo "Updating CronJob schedule from '$CURRENT_SCHEDULE' to every 5 min..."
fi
if [ -n "$CURRENT_DEADLINE" ] && [ "$CURRENT_DEADLINE" -lt "$TARGET_DEADLINE" ] 2>/dev/null; then
    if [ -n "$PATCH_JSON" ]; then
        PATCH_JSON="${PATCH_JSON},\"jobTemplate\":{\"spec\":{\"activeDeadlineSeconds\":$TARGET_DEADLINE}}"
    else
        PATCH_JSON="{\"spec\":{\"jobTemplate\":{\"spec\":{\"activeDeadlineSeconds\":$TARGET_DEADLINE}}"
    fi
    echo "Raising activeDeadlineSeconds from $CURRENT_DEADLINE to $TARGET_DEADLINE..."
fi
if [ -n "$PATCH_JSON" ]; then
    PATCH_JSON="${PATCH_JSON}}}"
    kubectl patch cronjob onelensupdater -n onelens-agent -p "$PATCH_JSON" 2>/dev/null && \
        echo "CronJob patched successfully" || \
        echo "WARNING: Failed to patch CronJob (RBAC?)"
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
# Sets TIER variable with the tier name. Must be called without $() subshell.
select_resource_tier() {
    local total_pods="$1"

    if [ "$total_pods" -lt 50 ]; then
        # ── Tiny ──
        PROMETHEUS_CPU_REQUEST="100m"
        PROMETHEUS_MEMORY_REQUEST="150Mi"
        PROMETHEUS_CPU_LIMIT="100m"
        PROMETHEUS_MEMORY_LIMIT="150Mi"

        OPENCOST_CPU_REQUEST="100m"
        OPENCOST_MEMORY_REQUEST="128Mi"
        OPENCOST_CPU_LIMIT="100m"
        OPENCOST_MEMORY_LIMIT="128Mi"

        ONELENS_CPU_REQUEST="100m"
        ONELENS_MEMORY_REQUEST="256Mi"
        ONELENS_CPU_LIMIT="300m"
        ONELENS_MEMORY_LIMIT="384Mi"

        KSM_CPU_REQUEST="50m"
        KSM_MEMORY_REQUEST="64Mi"
        KSM_CPU_LIMIT="50m"
        KSM_MEMORY_LIMIT="64Mi"

        PROMETHEUS_PUSHGATEWAY_CPU_REQUEST="25m"
        PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST="64Mi"
        PROMETHEUS_PUSHGATEWAY_CPU_LIMIT="25m"
        PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT="64Mi"

        TIER="tiny"

    elif [ "$total_pods" -lt 100 ]; then
        # ── Small ──
        PROMETHEUS_CPU_REQUEST="100m"
        PROMETHEUS_MEMORY_REQUEST="275Mi"
        PROMETHEUS_CPU_LIMIT="100m"
        PROMETHEUS_MEMORY_LIMIT="275Mi"

        OPENCOST_CPU_REQUEST="100m"
        OPENCOST_MEMORY_REQUEST="192Mi"
        OPENCOST_CPU_LIMIT="100m"
        OPENCOST_MEMORY_LIMIT="192Mi"

        ONELENS_CPU_REQUEST="125m"
        ONELENS_MEMORY_REQUEST="320Mi"
        ONELENS_CPU_LIMIT="375m"
        ONELENS_MEMORY_LIMIT="480Mi"

        KSM_CPU_REQUEST="50m"
        KSM_MEMORY_REQUEST="128Mi"
        KSM_CPU_LIMIT="50m"
        KSM_MEMORY_LIMIT="128Mi"

        PROMETHEUS_PUSHGATEWAY_CPU_REQUEST="25m"
        PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST="64Mi"
        PROMETHEUS_PUSHGATEWAY_CPU_LIMIT="25m"
        PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT="64Mi"

        TIER="small"

    elif [ "$total_pods" -lt 500 ]; then
        # ── Medium ──
        PROMETHEUS_CPU_REQUEST="150m"
        PROMETHEUS_MEMORY_REQUEST="420Mi"
        PROMETHEUS_CPU_LIMIT="150m"
        PROMETHEUS_MEMORY_LIMIT="420Mi"

        OPENCOST_CPU_REQUEST="100m"
        OPENCOST_MEMORY_REQUEST="256Mi"
        OPENCOST_CPU_LIMIT="100m"
        OPENCOST_MEMORY_LIMIT="256Mi"

        ONELENS_CPU_REQUEST="125m"
        ONELENS_MEMORY_REQUEST="480Mi"
        ONELENS_CPU_LIMIT="375m"
        ONELENS_MEMORY_LIMIT="640Mi"

        KSM_CPU_REQUEST="50m"
        KSM_MEMORY_REQUEST="192Mi"
        KSM_CPU_LIMIT="50m"
        KSM_MEMORY_LIMIT="192Mi"

        PROMETHEUS_PUSHGATEWAY_CPU_REQUEST="50m"
        PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST="100Mi"
        PROMETHEUS_PUSHGATEWAY_CPU_LIMIT="50m"
        PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT="100Mi"

        TIER="medium"

    elif [ "$total_pods" -lt 1000 ]; then
        # ── Large ──
        PROMETHEUS_CPU_REQUEST="250m"
        PROMETHEUS_MEMORY_REQUEST="720Mi"
        PROMETHEUS_CPU_LIMIT="250m"
        PROMETHEUS_MEMORY_LIMIT="720Mi"

        OPENCOST_CPU_REQUEST="150m"
        OPENCOST_MEMORY_REQUEST="384Mi"
        OPENCOST_CPU_LIMIT="150m"
        OPENCOST_MEMORY_LIMIT="384Mi"

        ONELENS_CPU_REQUEST="125m"
        ONELENS_MEMORY_REQUEST="640Mi"
        ONELENS_CPU_LIMIT="440m"
        ONELENS_MEMORY_LIMIT="800Mi"

        KSM_CPU_REQUEST="50m"
        KSM_MEMORY_REQUEST="256Mi"
        KSM_CPU_LIMIT="50m"
        KSM_MEMORY_LIMIT="256Mi"

        PROMETHEUS_PUSHGATEWAY_CPU_REQUEST="50m"
        PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST="100Mi"
        PROMETHEUS_PUSHGATEWAY_CPU_LIMIT="50m"
        PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT="100Mi"

        TIER="large"

    elif [ "$total_pods" -lt 1500 ]; then
        # ── Extra Large ──
        PROMETHEUS_CPU_REQUEST="400m"
        PROMETHEUS_MEMORY_REQUEST="1600Mi"
        PROMETHEUS_CPU_LIMIT="400m"
        PROMETHEUS_MEMORY_LIMIT="1600Mi"

        OPENCOST_CPU_REQUEST="150m"
        OPENCOST_MEMORY_REQUEST="512Mi"
        OPENCOST_CPU_LIMIT="150m"
        OPENCOST_MEMORY_LIMIT="512Mi"

        ONELENS_CPU_REQUEST="125m"
        ONELENS_MEMORY_REQUEST="800Mi"
        ONELENS_CPU_LIMIT="500m"
        ONELENS_MEMORY_LIMIT="960Mi"

        KSM_CPU_REQUEST="100m"
        KSM_MEMORY_REQUEST="384Mi"
        KSM_CPU_LIMIT="100m"
        KSM_MEMORY_LIMIT="384Mi"

        PROMETHEUS_PUSHGATEWAY_CPU_REQUEST="50m"
        PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST="128Mi"
        PROMETHEUS_PUSHGATEWAY_CPU_LIMIT="50m"
        PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT="128Mi"

        TIER="extra-large"

    else
        # ── Very Large (1500+) ──
        PROMETHEUS_CPU_REQUEST="600m"
        PROMETHEUS_MEMORY_REQUEST="2400Mi"
        PROMETHEUS_CPU_LIMIT="600m"
        PROMETHEUS_MEMORY_LIMIT="2400Mi"

        OPENCOST_CPU_REQUEST="200m"
        OPENCOST_MEMORY_REQUEST="768Mi"
        OPENCOST_CPU_LIMIT="200m"
        OPENCOST_MEMORY_LIMIT="768Mi"

        ONELENS_CPU_REQUEST="190m"
        ONELENS_MEMORY_REQUEST="960Mi"
        ONELENS_CPU_LIMIT="565m"
        ONELENS_MEMORY_LIMIT="1280Mi"

        KSM_CPU_REQUEST="100m"
        KSM_MEMORY_REQUEST="512Mi"
        KSM_CPU_LIMIT="100m"
        KSM_MEMORY_LIMIT="512Mi"

        PROMETHEUS_PUSHGATEWAY_CPU_REQUEST="50m"
        PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST="128Mi"
        PROMETHEUS_PUSHGATEWAY_CPU_LIMIT="50m"
        PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT="128Mi"

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
  # Note: Can't use _get for booleans — jq's `false // empty` returns empty since false is falsy
  PVC_ENABLED=$(echo "$CURRENT_VALUES" | jq -r '.prometheus.server.persistentVolume.enabled // "true"')

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
      }
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

# Phase 5: Capture pre-patch state (compact — fits in 10K log limit for large clusters)

echo ""
echo "=== PRE-PATCH ==="

# Helm releases (1 line each)
helm list -n onelens-agent --no-headers 2>/dev/null | awk '{printf "%s %s %s %s\n", $1, $7, $9, $4}' || true

# OneLens pod health (compact: only name, ready, status — no IPs/nodes)
echo "Pods:"
kubectl get pods -n onelens-agent --no-headers 2>/dev/null \
    | grep -vE 'Completed|Error|Terminating' \
    | awk '{printf "  %s %s %s\n", $1, $2, $3}' || true
NOT_HEALTHY=$(kubectl get pods -n onelens-agent --no-headers 2>/dev/null \
    | grep -vE 'Completed|Error|Terminating' \
    | awk '{split($2,a,"/"); if (a[1] != a[2] || $3 != "Running") print $1, $3}' || true)
if [ -n "$NOT_HEALTHY" ]; then
    echo "WARNING: unhealthy pods: $NOT_HEALTHY"
fi

# Cluster sizing inputs (the numbers that drive resource allocation)
echo "Sizing: nodes=$NUM_NODES pods=$TOTAL_PODS (deploy=$DEPLOY_PODS sts=$STS_PODS ds=$DS_PODS) labels=$AVG_LABELS mult=${LABEL_MULTIPLIER}x tier=$TIER"

# Current resources (compact: cpu/memory limits per component)
if [[ -n "$CURRENT_VALUES" ]] && command -v jq &>/dev/null; then
    echo "Current limits:"
    echo "  prom: cpu=$(_get '.prometheus.server.resources.limits.cpu') mem=$(_get '.prometheus.server.resources.limits.memory')"
    echo "  ksm: cpu=$(_get '.prometheus["kube-state-metrics"].resources.limits.cpu') mem=$(_get '.prometheus["kube-state-metrics"].resources.limits.memory')"
    echo "  opencost: cpu=$(_get '.["prometheus-opencost-exporter"].opencost.exporter.resources.limits.cpu') mem=$(_get '.["prometheus-opencost-exporter"].opencost.exporter.resources.limits.memory')"
    echo "  agent: cpu=$(_get '.["onelens-agent"].resources.limits.cpu') mem=$(_get '.["onelens-agent"].resources.limits.memory')"
fi

# Warning events only (OOMKilled, CrashLoopBackOff, FailedScheduling)
WARN_EVENTS=$(kubectl get events -n onelens-agent --no-headers 2>/dev/null \
    | grep -iE 'OOMKill|CrashLoop|FailedSchedul|FailedMount|BackOff' | tail -3 || true)
if [ -n "$WARN_EVENTS" ]; then
    echo "Warning events:"
    echo "$WARN_EVENTS"
fi
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

# Capture actual resource usage from Prometheus (non-fatal — skip if unavailable).
# Logs current + max-over-1h memory and CPU for each onelens pod.
# This data is critical for right-sizing validation: limits vs actual usage.
if [ -n "$PROM_SVC" ]; then
    PROM_QUERY_URL="http://${PROM_SVC}.onelens-agent.svc.cluster.local:80/api/v1/query"
    _prom_query() {
        curl -s -G --max-time 5 "$PROM_QUERY_URL" --data-urlencode "query=$1" 2>/dev/null \
            | jq -r '.data.result[] | "\(.metric.container) \(.value[1])"' 2>/dev/null || true
    }

    # Memory: current working set
    MEM_NOW=$(_prom_query 'sum by (container) (container_memory_working_set_bytes{namespace="onelens-agent",container!="",container!="POD"})')
    # Memory: max over last 1h
    MEM_MAX=$(_prom_query 'max by (container) (max_over_time(container_memory_working_set_bytes{namespace="onelens-agent",container!="",container!="POD"}[1h]))')
    # CPU: current rate in cores
    CPU_NOW=$(_prom_query 'sum by (container) (rate(container_cpu_usage_seconds_total{namespace="onelens-agent",container!="",container!="POD"}[5m]))')

    if [ -n "$MEM_NOW" ]; then
        echo "Actual usage (now | max 1h):"
        # Merge all three into a single per-container output
        # Format: container current_mem max_mem current_cpu
        (
            echo "$MEM_NOW" | while read c v; do echo "mem_now $c $v"; done
            echo "$MEM_MAX" | while read c v; do echo "mem_max $c $v"; done
            echo "$CPU_NOW" | while read c v; do echo "cpu_now $c $v"; done
        ) | awk '
        {
            type=$1; container=$2; val=$3
            if (type == "mem_now") mem_now[container] = val
            if (type == "mem_max") mem_max[container] = val
            if (type == "cpu_now") cpu_now[container] = val
        }
        END {
            for (c in mem_now) {
                mn = int(mem_now[c] / 1048576)
                mx = int(mem_max[c] / 1048576)
                cpu = cpu_now[c] + 0
                printf "  %s: mem=%dMi|%dMi cpu=%dm\n", c, mn, mx, int(cpu * 1000)
            }
        }' | sort
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

# Never downsize memory limits — prevents OOM during Prometheus WAL replay and
# KSM/agent startup when upgrading from older versions with higher allocations.
# The metric filtering in globalvalues.yaml reduces long-term memory needs, but
# the first startup after upgrade replays old (larger) WAL data.
# Uses _max_memory from lib/resource-sizing.sh to compare and keep the larger value.
if [[ -n "$CURRENT_VALUES" ]] && command -v jq &>/dev/null; then
    _existing() { echo "$CURRENT_VALUES" | jq -r "$1 // empty"; }

    _guard_memory() {
        local component="$1" path="$2" current_var="$3"
        local existing
        existing=$(_existing "$path")
        if [ -n "$existing" ]; then
            local kept
            kept=$(_max_memory "$existing" "${!current_var}")
            if [ "$kept" != "${!current_var}" ]; then
                echo "  $component: keeping existing $existing (tier calculated ${!current_var})"
                eval "$current_var=\"$kept\""
            fi
        fi
    }

    echo "Checking for memory downsizes (never downsize on upgrade)..."
    _guard_memory "Prometheus request" '.prometheus.server.resources.requests.memory' PROMETHEUS_MEMORY_REQUEST
    _guard_memory "Prometheus limit" '.prometheus.server.resources.limits.memory' PROMETHEUS_MEMORY_LIMIT
    _guard_memory "KSM request" '.prometheus["kube-state-metrics"].resources.requests.memory' KSM_MEMORY_REQUEST
    _guard_memory "KSM limit" '.prometheus["kube-state-metrics"].resources.limits.memory' KSM_MEMORY_LIMIT
    _guard_memory "OpenCost request" '.["prometheus-opencost-exporter"].opencost.exporter.resources.requests.memory' OPENCOST_MEMORY_REQUEST
    _guard_memory "OpenCost limit" '.["prometheus-opencost-exporter"].opencost.exporter.resources.limits.memory' OPENCOST_MEMORY_LIMIT
    _guard_memory "Agent request" '.["onelens-agent"].resources.requests.memory' ONELENS_MEMORY_REQUEST
    _guard_memory "Agent limit" '.["onelens-agent"].resources.limits.memory' ONELENS_MEMORY_LIMIT
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

# Phase 5.9: Recover stuck helm release
# If a previous run was killed mid-upgrade (pod OOM, activeDeadlineSeconds, etc.),
# the release gets stuck in pending-upgrade or pending-rollback. Subsequent helm
# upgrade calls fail with "another operation (install/upgrade/rollback) is in progress".
# Fix: rollback to the last successful revision before attempting upgrade.
RELEASE_STATUS=$(helm status onelens-agent -n onelens-agent -o json 2>/dev/null | jq -r '.info.status' || true)
if [ "$RELEASE_STATUS" = "pending-upgrade" ] || [ "$RELEASE_STATUS" = "pending-rollback" ] || [ "$RELEASE_STATUS" = "pending-install" ]; then
    echo "Helm release stuck in '$RELEASE_STATUS' — rolling back to last successful revision..."
    LAST_GOOD_REV=$(helm history onelens-agent -n onelens-agent -o json 2>/dev/null \
        | jq -r '[.[] | select(.status == "deployed" or .status == "superseded")] | last | .revision' || true)
    if [ -n "$LAST_GOOD_REV" ] && [ "$LAST_GOOD_REV" != "null" ]; then
        helm rollback onelens-agent "$LAST_GOOD_REV" -n onelens-agent --timeout=3m 2>&1 && \
            echo "Rolled back to revision $LAST_GOOD_REV" || \
            echo "WARNING: Rollback failed — helm upgrade may also fail"
    else
        echo "WARNING: No previous successful revision found — attempting upgrade anyway"
    fi
fi

# Build helm upgrade command
# Key design: NO --reuse-values
#   - globalvalues.yaml provides chart defaults (images, configs, scrape jobs)
#   - Customer values file preserves tolerations, nodeSelector, podLabels
#   - --set overrides for identity, resources, retention, PVC
#   - --version pins to the target version from PATCHING_VERSION (set by entrypoint.sh)
#     Without --version, helm would pick latest from repo — uncontrolled upgrades.
#     If PATCHING_VERSION is not set (old entrypoint), omit --version (backward compat).
CHART_VERSION=""
if [ -n "$PATCHING_VERSION" ]; then
    CHART_VERSION=$(normalize_chart_version "$PATCHING_VERSION" 2>/dev/null || echo "")
fi
HELM_CMD="helm upgrade onelens-agent onelens/onelens-agent \
  -f /globalvalues.yaml \
  --history-max 200 \
  --wait \
  --timeout=10m \
  --namespace onelens-agent"
if [ -n "$CHART_VERSION" ]; then
    HELM_CMD="$HELM_CMD --version $CHART_VERSION"
    echo "Pinning chart version to $CHART_VERSION (from PATCHING_VERSION=$PATCHING_VERSION)"
fi

# Apply customer values (tolerations, nodeSelector, podLabels)
if [ -n "$CUSTOMER_VALUES_FILE" ] && [ -f "$CUSTOMER_VALUES_FILE" ]; then
    HELM_CMD="$HELM_CMD -f $CUSTOMER_VALUES_FILE"
fi

# Identity values (preserved from existing release)
HELM_CMD="$HELM_CMD \
  --set onelens-agent.env.CLUSTER_NAME=\"$CLUSTER_NAME\" \
  --set-string onelens-agent.env.ACCOUNT_ID=\"$ACCOUNT_ID\" \
  --set onelens-agent.secrets.API_BASE_URL=\"$API_BASE_URL\" \
  --set onelens-agent.secrets.CLUSTER_TOKEN=\"$CLUSTER_TOKEN\" \
  --set onelens-agent.secrets.REGISTRATION_ID=\"$REGISTRATION_ID\""

# OpenCost cluster ID — only set if extracted value is non-empty.
# Empty --set would override the globalvalues.yaml default ('default-cluster'),
# which breaks OpenCost's idle cost allocation (shareIdle=true → 500 error).
if [ -n "$DEFAULT_CLUSTER_ID" ]; then
    HELM_CMD="$HELM_CMD --set prometheus-opencost-exporter.opencost.exporter.defaultClusterId=\"$DEFAULT_CLUSTER_ID\""
fi

# PVC settings
HELM_CMD="$HELM_CMD \
  --set prometheus.server.persistentVolume.enabled=$PVC_ENABLED \
  $EXISTING_CLAIM_FLAG \
  --set-string prometheus.server.persistentVolume.size=\"$PROMETHEUS_VOLUME_SIZE\""

# StorageClass: disable on upgrade. The SC was created at install time and must not
# be touched — provisioner is immutable in K8s, and there's no reason to change
# volume type, size, encryption, or labels on an upgrade.
HELM_CMD="$HELM_CMD --set onelens-agent.storageClass.enabled=false"

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

# Force-delete pods stuck in Terminating for >10 min before helm upgrade.
# Pods on dead/unreachable nodes stay Terminating forever because kubelet can't
# acknowledge the deletion. Helm sees them as part of the release and times out
# waiting for the rollout. Force-delete clears the API objects so helm proceeds.
TERMINATING_PODS=$(kubectl get pods -n onelens-agent --no-headers 2>/dev/null \
    | awk '$3 == "Terminating" {print $1}' || true)
if [ -n "$TERMINATING_PODS" ]; then
    NOW=$(date +%s)
    for pod in $TERMINATING_PODS; do
        DEL_TS=$(kubectl get pod "$pod" -n onelens-agent \
            -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || true)
        if [ -n "$DEL_TS" ]; then
            DEL_EPOCH=$(date -d "$DEL_TS" +%s 2>/dev/null || echo "0")
            STUCK_SECS=$(( NOW - DEL_EPOCH ))
            if [ "$STUCK_SECS" -gt 600 ]; then
                echo "Force-deleting pod stuck Terminating for $((STUCK_SECS / 60))m: $pod"
                kubectl delete pod "$pod" -n onelens-agent --force --grace-period=0 2>/dev/null || true
            fi
        fi
    done
fi

echo "Running helm upgrade (latest chart, fresh values + customer overrides)..."
eval "$HELM_CMD"

UPGRADE_EXIT=$?
if [ $UPGRADE_EXIT -ne 0 ]; then
    echo "WARNING: helm upgrade failed (exit $UPGRADE_EXIT) but NOT rolling back."
    echo "Old pods remain running. Deployer upgrade + 5-min schedule will proceed"
    echo "so the next healthcheck can retry or allow quick analysis."
    echo "--- Pod Status After Failed Upgrade ---"
    kubectl get pods -n onelens-agent -o wide --no-headers 2>/dev/null || true
    echo "--- Events After Failed Upgrade ---"
    kubectl get events -n onelens-agent --sort-by='.lastTimestamp' --no-headers 2>/dev/null | tail -10 || true
    UPGRADE_FAILED=true
else
    UPGRADE_FAILED=false
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
        | grep -vE 'Completed|Error|Terminating' \
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

# Deployer self-upgrade — upgrade the deployer chart itself to get new entrypoint.sh
# This is the key enabler: once the deployer chart is upgraded, the new entrypoint.sh
# with healthcheck mode will run on the next CronJob execution.
# NO --reuse-values: image tag comes from chart AppVersion (new chart = new image).
# Only customer-specific values (tolerations, nodeSelector) are extracted and re-applied.
echo "Checking deployer chart version..."
DEPLOYER_RELEASE_JSON=$(helm list -n onelens-agent -o json 2>/dev/null || echo "[]")
DEPLOYER_VERSION=$(echo "$DEPLOYER_RELEASE_JSON" | jq -r '.[] | select(.name=="onelensdeployer") | .chart' | sed 's/onelensdeployer-//' || true)
DEPLOYER_STATUS=$(echo "$DEPLOYER_RELEASE_JSON" | jq -r '.[] | select(.name=="onelensdeployer") | .status' || true)
# Pin deployer target to CHART_VERSION (from PATCHING_VERSION) if available.
# Fall back to latest from repo for backward compat (old entrypoint without PATCHING_VERSION).
if [ -n "$CHART_VERSION" ]; then
    TARGET_DEPLOYER="$CHART_VERSION"
else
    TARGET_DEPLOYER=$(helm search repo onelens/onelensdeployer -o json 2>/dev/null \
        | jq -r '.[0].version' || true)
fi

DEPLOYER_NEEDS_UPGRADE=false
if [ -n "$DEPLOYER_VERSION" ] && [ -n "$TARGET_DEPLOYER" ]; then
    if [ "$DEPLOYER_VERSION" != "$TARGET_DEPLOYER" ]; then
        DEPLOYER_NEEDS_UPGRADE=true
    elif [ "$DEPLOYER_STATUS" = "failed" ]; then
        echo "Deployer release is in 'failed' state — retrying upgrade..."
        DEPLOYER_NEEDS_UPGRADE=true
    fi
fi
if [ "$DEPLOYER_NEEDS_UPGRADE" = "true" ]; then
    echo "Upgrading deployer from $DEPLOYER_VERSION ($DEPLOYER_STATUS) to $TARGET_DEPLOYER..."

    # Extract customer-specific values from existing deployer release
    DEPLOYER_VALUES=$(helm get values onelensdeployer -n onelens-agent -a -o json 2>/dev/null || true)
    DEPLOYER_CUSTOMER_FILE=""
    if [ -n "$DEPLOYER_VALUES" ] && command -v jq &>/dev/null; then
        DEPLOYER_CUSTOMER_FILE=$(mktemp)
        echo "$DEPLOYER_VALUES" | jq '{
            cronjob: {
                tolerations: (.cronjob.tolerations // []),
                nodeSelector: (.cronjob.nodeSelector // {})
            }
        }' > "$DEPLOYER_CUSTOMER_FILE" 2>/dev/null || true
    fi

    # Bootstrap RBAC is guarded by .Release.IsInstall in the chart templates,
    # so it never renders on upgrade. Job is disabled — only CronJob runs post-install.
    DEPLOYER_CMD="helm upgrade onelensdeployer onelens/onelensdeployer -n onelens-agent \
        --set cronjob.schedule=\"$TARGET_SCHEDULE\" \
        --set cronjob.backoffLimit=0 \
        --set cronjob.activeDeadlineSeconds=900 \
        --set cronjob.env.deployment_type=cronjob \
        --set job.enabled=false \
        --version $TARGET_DEPLOYER \
        --timeout=3m"

    # Preserve old RBAC resource names if upgrading from v1.x deployer.
    # The ClusterRole/ClusterRoleBinding were renamed from onelensupdater-* to
    # onelensdeployer-* in the v2.x chart. Helm treats renamed resources as new
    # and tries to CREATE them — but the CronJob SA can't create ClusterRoles
    # at cluster scope (by design). Passing the old names makes helm UPDATE the
    # existing resources instead.
    if kubectl get clusterrole onelensupdater-clusterrole &>/dev/null; then
        echo "Detected old RBAC names (v1.x deployer) — preserving to avoid cluster-scope create"
        DEPLOYER_CMD="$DEPLOYER_CMD \
            --set rbac.clusterRole.name=onelensupdater-clusterrole \
            --set rbac.clusterRoleBinding.name=onelensupdater-clusterrolebinding"
    fi

    if [ -n "$DEPLOYER_CUSTOMER_FILE" ] && [ -f "$DEPLOYER_CUSTOMER_FILE" ]; then
        DEPLOYER_CMD="$DEPLOYER_CMD -f $DEPLOYER_CUSTOMER_FILE"
    fi

    eval "$DEPLOYER_CMD" 2>&1 && \
        echo "Deployer upgraded to $TARGET_DEPLOYER" || \
        echo "WARNING: Deployer upgrade failed (non-fatal, will retry next run)"

    [ -n "$DEPLOYER_CUSTOMER_FILE" ] && rm -f "$DEPLOYER_CUSTOMER_FILE"
else
    echo "Deployer chart: current=${DEPLOYER_VERSION:-unknown} target=${TARGET_DEPLOYER:-unknown} (no upgrade needed)"
fi

# Get the chart version that was actually deployed
DEPLOYED_VERSION=$(helm list -n onelens-agent -o json 2>/dev/null | jq -r '.[0].chart' | sed 's/onelens-agent-//' || echo "unknown")

echo ""
echo "=== POST-PATCH ==="
echo "Chart: $DEPLOYED_VERSION | Tier: $TIER | Pods: $TOTAL_PODS | Labels: ${LABEL_MULTIPLIER}x"
echo "Retention: $PROMETHEUS_RETENTION | Size: $PROMETHEUS_RETENTION_SIZE | PVC: $PROMETHEUS_VOLUME_SIZE"
echo "Applied limits:"
echo "  prom: cpu=$PROMETHEUS_CPU_LIMIT mem=$PROMETHEUS_MEMORY_LIMIT"
echo "  ksm: cpu=$KSM_CPU_LIMIT mem=$KSM_MEMORY_LIMIT"
echo "  opencost: cpu=$OPENCOST_CPU_LIMIT mem=$OPENCOST_MEMORY_LIMIT"
echo "  agent: cpu=$ONELENS_CPU_LIMIT mem=$ONELENS_MEMORY_LIMIT"

# Pod health after upgrade (compact)
POST_NOT_HEALTHY=$(kubectl get pods -n onelens-agent --no-headers 2>/dev/null \
    | grep -vE 'Completed|Error|Terminating' \
    | awk '{split($2,a,"/"); if (a[1] != a[2] || $3 != "Running") print $1, $3}' || true)
if [ -n "$POST_NOT_HEALTHY" ]; then
    echo "WARNING: pods not ready after upgrade: $POST_NOT_HEALTHY"
else
    echo "All pods healthy"
fi

# Activate healthcheck mode via API — tells backend this cluster is ready for
# self-healing. Also reports deployer_version so we can track fleet state.
echo "Activating healthcheck mode..."
FINAL_DEPLOYER_VERSION=$(helm list -n onelens-agent -o json 2>/dev/null \
    | jq -r '.[] | select(.name=="onelensdeployer") | .chart' \
    | sed 's/onelensdeployer-//' || true)
current_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
if [ "$UPGRADE_FAILED" = "true" ]; then
    # Upgrade failed — activate healthcheck + deployer version but don't claim healthy
    hc_payload=$(jq -n \
        --arg reg_id "$REGISTRATION_ID" \
        --arg token "$CLUSTER_TOKEN" \
        --arg dv "${FINAL_DEPLOYER_VERSION:-unknown}" \
        '{registration_id: $reg_id, cluster_token: $token, update_data: {patching_mode: "healthcheck", patching_enabled: true, deployer_version: $dv}}')
else
    hc_payload=$(jq -n \
        --arg reg_id "$REGISTRATION_ID" \
        --arg token "$CLUSTER_TOKEN" \
        --arg dv "${FINAL_DEPLOYER_VERSION:-unknown}" \
        --arg ts "$current_timestamp" \
        '{registration_id: $reg_id, cluster_token: $token, update_data: {patching_mode: "healthcheck", patching_enabled: true, deployer_version: $dv, healthcheck_failures: 0, last_healthy_at: $ts}}')
fi
curl -s --max-time 10 --location --request PUT \
    "${API_BASE_URL:-https://api-in.onelens.cloud}/v1/kubernetes/cluster-version" \
    --header 'Content-Type: application/json' \
    --data "$hc_payload" >/dev/null 2>&1 && \
    echo "Healthcheck mode activated (deployer: ${FINAL_DEPLOYER_VERSION:-unknown})" || \
    echo "WARNING: Failed to activate healthcheck mode (API call failed)"

echo ""
if [ "$UPGRADE_FAILED" = "true" ]; then
    echo "Patching incomplete (upgrade failed). Chart: $DEPLOYED_VERSION | Pods: $TOTAL_PODS | Tier: $TIER"
    echo "Deployer upgraded + 5-min schedule set. Next healthcheck will retry."
    exit 1
fi
echo "Patching complete. Chart: $DEPLOYED_VERSION | Pods: $TOTAL_PODS | Tier: $TIER"
