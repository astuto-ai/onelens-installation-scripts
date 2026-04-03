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
        # Truncate to 100000 chars (keep tail — most recent diagnostics are at the end)
        if [ ${#log_content} -gt 100000 ]; then
            log_content="[truncated]...${log_content: -99900}"
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

# Bootstrap credentials from environment early so milestone reporting works from the start.
# CronJob template injects REGISTRATION_ID and CLUSTER_TOKEN from onelens-agent-secrets.
# These may be overwritten later by helm get values, but env vars are available immediately.
REGISTRATION_ID="${REGISTRATION_ID:-}"
CLUSTER_TOKEN="${CLUSTER_TOKEN:-}"

# Milestone reporting: send partial patching_logs to the API mid-run.
# If the run OOMs or times out, we can see in the DB how far it got.
# Each call is a single curl (~100ms) — negligible on a 5+ min run.
_report_milestone() {
    if [ -z "$REGISTRATION_ID" ] || [ -z "$CLUSTER_TOKEN" ]; then return; fi
    local log_content
    log_content=$(cat "$_PATCH_LOG_FILE" 2>/dev/null || true)
    if [ ${#log_content} -gt 100000 ]; then
        log_content="[truncated]...${log_content: -99900}"
    fi
    local payload
    payload=$(jq -n \
        --arg reg_id "$REGISTRATION_ID" \
        --arg token "$CLUSTER_TOKEN" \
        --arg plogs "$log_content" \
        '{registration_id: $reg_id, cluster_token: $token, update_data: {patching_logs: $plogs}}' 2>/dev/null)
    if [ -n "$payload" ]; then
        curl -s --max-time 5 --location --request PUT \
            "https://api-in.onelens.cloud/v1/kubernetes/cluster-version" \
            --header 'Content-Type: application/json' \
            --data "$payload" >/dev/null 2>&1 || true
    fi
}

# Phase 1: Prerequisite Checks
echo "Checking prerequisites..."
_report_milestone  # M1: script-started — proves download + credentials work

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
_report_milestone  # M2: tools-ready — helm/kubectl installed

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
    kubectl patch cronjob onelensupdater -n onelens-agent -p "$PATCH_JSON" --field-manager='Helm' 2>/dev/null && \
        echo "CronJob patched successfully" || \
        echo "WARNING: Failed to patch CronJob (RBAC?)"
fi

# Ensure CronJob Job TTL is long enough for OOM detection on the next run.
# Old deployer charts set ttlSecondsAfterFinished=120 (2 min), which deletes the
# failed pod before the next run can check its termination reason.
# Raise to 86400 (24h). The history limits (successfulJobsHistoryLimit=1,
# failedJobsHistoryLimit=1) still do the real cleanup — only 2 pods at any time.
CURRENT_TTL=$(kubectl get cronjob onelensupdater -n onelens-agent \
    -o jsonpath='{.spec.jobTemplate.spec.ttlSecondsAfterFinished}' 2>/dev/null || true)
if [ -n "$CURRENT_TTL" ] && [ "$CURRENT_TTL" -lt 86400 ] 2>/dev/null; then
    kubectl patch cronjob onelensupdater -n onelens-agent --type='merge' --field-manager='Helm' -p='{
      "spec":{"jobTemplate":{"spec":{"ttlSecondsAfterFinished":86400}}}
    }' 2>/dev/null && echo "CronJob Job TTL raised to 24h (was ${CURRENT_TTL}s)" || true
fi

# Check if the previous updater run was OOMKilled.
# The cgroup memory limit (256Mi) counts RSS + kernel page cache. On large clusters,
# helm/kubectl binaries (~50MB each) plus accumulated page cache exceed 256Mi during
# helm upgrade. If OOM detected, bump CronJob memory to 512Mi (takes effect next run).
_UPDATER_OOM=false
LAST_UPDATER_POD=$(kubectl get pods -n onelens-agent --no-headers 2>/dev/null \
    | grep 'onelensupdater' | grep -vE 'Running|ContainerCreating' \
    | tail -1 | awk '{print $1}')
if [ -n "$LAST_UPDATER_POD" ]; then
    LAST_TERM_REASON=$(kubectl get pod "$LAST_UPDATER_POD" -n onelens-agent \
        -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}' 2>/dev/null || true)
    if [ "$LAST_TERM_REASON" = "OOMKilled" ]; then
        _UPDATER_OOM=true
        echo "Previous updater pod $LAST_UPDATER_POD was OOMKilled."
    fi
fi

# Set CronJob resources: 200m CPU. Memory depends on OOM state.
# Note: _cpu_to_millicores is not available yet (library embedded below), so parse manually.
TARGET_CPU_MILLICORES=200
CURRENT_CPU=$(kubectl get cronjob onelensupdater -n onelens-agent -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null || true)
CURRENT_MEM=$(kubectl get cronjob onelensupdater -n onelens-agent -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].resources.requests.memory}' 2>/dev/null || true)

# Parse current memory to Mi for comparison
CURRENT_MEM_MI=""
if [ -n "$CURRENT_MEM" ]; then
    if echo "$CURRENT_MEM" | grep -q 'Gi$'; then
        CURRENT_MEM_MI=$(echo "$CURRENT_MEM" | sed 's/Gi$//' | awk '{printf "%.0f", $1 * 1024}')
    else
        CURRENT_MEM_MI=$(echo "$CURRENT_MEM" | sed 's/Mi$//')
    fi
fi

if [ "$_UPDATER_OOM" = "true" ]; then
    TARGET_MEMORY_MI=512
    echo "Bumping CronJob memory to 512Mi (OOM recovery). Takes effect next run."
elif [ "$CURRENT_MEM_MI" = "512" ]; then
    # Previously bumped for OOM — keep 512Mi, don't downsize back to 256Mi.
    # The cluster needs 512Mi for helm/kubectl page cache during upgrades.
    TARGET_MEMORY_MI=512
    echo "CronJob memory at 512Mi (previous OOM bump) — keeping."
else
    TARGET_MEMORY_MI=256
fi

NEED_CPU_PATCH=false
NEED_MEM_PATCH=false

if [ -n "$CURRENT_CPU" ]; then
    if echo "$CURRENT_CPU" | grep -q 'm$'; then
        CURRENT_CPU_MILLICORES=$(echo "$CURRENT_CPU" | sed 's/m$//')
    else
        CURRENT_CPU_MILLICORES=$(echo "$CURRENT_CPU" | awk '{printf "%.0f", $1 * 1000}')
    fi
    if [ "$CURRENT_CPU_MILLICORES" -ne "$TARGET_CPU_MILLICORES" ] 2>/dev/null; then
        NEED_CPU_PATCH=true
    fi
fi

if [ -n "$CURRENT_MEM_MI" ]; then
    if [ "$CURRENT_MEM_MI" -ne "$TARGET_MEMORY_MI" ] 2>/dev/null; then
        NEED_MEM_PATCH=true
    fi
fi

if [ "$NEED_CPU_PATCH" = "true" ] || [ "$NEED_MEM_PATCH" = "true" ]; then
    echo "Updating CronJob resources (cpu=${CURRENT_CPU:-?}→${TARGET_CPU_MILLICORES}m, mem=${CURRENT_MEM:-?}→${TARGET_MEMORY_MI}Mi)..."
    kubectl patch cronjob onelensupdater -n onelens-agent --type='merge' --field-manager='Helm' -p="{
      \"spec\":{\"jobTemplate\":{\"spec\":{\"template\":{\"spec\":{\"containers\":[{
        \"name\":\"onelensupdater\",
        \"resources\":{
          \"requests\":{\"cpu\":\"${TARGET_CPU_MILLICORES}m\",\"memory\":\"${TARGET_MEMORY_MI}Mi\"},
          \"limits\":{\"cpu\":\"${TARGET_CPU_MILLICORES}m\",\"memory\":\"${TARGET_MEMORY_MI}Mi\"}
        }
      }]}}}}}
    }" 2>/dev/null && \
        echo "CronJob resources reset successfully" || \
        echo "WARNING: Failed to reset CronJob resources"
else
    echo "CronJob resources already at target (${CURRENT_CPU}, ${CURRENT_MEM})"
fi

# Ensure deployer CronJob has backoffLimit=0 (no internal retries).
# The 5-min CronJob schedule is the retry mechanism. Internal retries just burn time
# in exponential backoff (10s, 20s, 40s...) while concurrencyPolicy: Forbid blocks new runs.
# Old deployer charts (<=2.1.21) didn't set this, so Kubernetes defaults to 6.
# Only patch backoffLimit if it's explicitly set to a non-zero value in the spec.
# If empty (not in spec), Kubernetes defaults to 6 — but patching it would steal
# field ownership from helm, causing conflicts on next helm upgrade.
# The chart (>=2.1.22) already sets backoffLimit=0. For old charts, the first
# helm upgrade will set it. Don't kubectl-patch unless it's explicitly wrong.
CURRENT_BACKOFF=$(kubectl get cronjob onelensupdater -n onelens-agent \
    -o jsonpath='{.spec.jobTemplate.spec.backoffLimit}' 2>/dev/null || true)
if [ -n "$CURRENT_BACKOFF" ] && [ "$CURRENT_BACKOFF" != "0" ] 2>/dev/null; then
    echo "Updating CronJob backoffLimit from $CURRENT_BACKOFF to 0..."
    kubectl patch cronjob onelensupdater -n onelens-agent --type='merge' --field-manager='Helm' -p='
      {"spec":{"jobTemplate":{"spec":{"backoffLimit":0}}}}
    ' 2>/dev/null && \
        echo "CronJob backoffLimit patched successfully" || \
        echo "WARNING: Failed to patch CronJob backoffLimit"
fi

# Detect deployer chart version — used for dormant cluster warning and final API report.
# Old deployers (<=2.1.18) set patching_enabled=false after patching.sh exits, causing
# the cluster to go dormant. We can't prevent this from patching.sh (the old entrypoint
# runs AFTER this script and overwrites the flag). Log a warning so it appears in logs.
DEPLOYER_VERSION=""
DEPLOYER_CHART_RAW=$(helm list -n onelens-agent -f '^onelensdeployer$' -o json 2>/dev/null \
    | jq -r '.[0].chart // empty' 2>/dev/null || true)
if [ -n "$DEPLOYER_CHART_RAW" ]; then
    DEPLOYER_VERSION=$(echo "$DEPLOYER_CHART_RAW" | sed 's/onelensdeployer-//')
    DEPLOYER_MAJOR=$(echo "$DEPLOYER_VERSION" | cut -d. -f1)
    DEPLOYER_MINOR=$(echo "$DEPLOYER_VERSION" | cut -d. -f2)
    DEPLOYER_PATCH=$(echo "$DEPLOYER_VERSION" | cut -d. -f3)
    # Proper semver <=2.1.18 check: major < 2, or (major == 2 and minor < 1), or (2.1.x and patch <= 18)
    _deployer_is_old=false
    if [ "$DEPLOYER_MAJOR" -lt 2 ] 2>/dev/null; then _deployer_is_old=true
    elif [ "$DEPLOYER_MAJOR" -eq 2 ] 2>/dev/null && [ "$DEPLOYER_MINOR" -lt 1 ] 2>/dev/null; then _deployer_is_old=true
    elif [ "$DEPLOYER_MAJOR" -eq 2 ] 2>/dev/null && [ "$DEPLOYER_MINOR" -eq 1 ] 2>/dev/null && [ "$DEPLOYER_PATCH" -le 18 ] 2>/dev/null; then _deployer_is_old=true
    fi
    if [ "$_deployer_is_old" = "true" ]; then
        echo "WARNING: Deployer chart $DEPLOYER_VERSION (<=2.1.18) will set patching_enabled=false after this script exits."
        echo "This cluster will go dormant until the deployer chart is manually upgraded by a cluster admin."
    fi
fi

# Phase 4: Cluster Pod Count and Resource Allocation

# BEGIN_EMBED lib/resource-sizing.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/resource-sizing.sh"
# END_EMBED

# --- Pod count: count running + pending pods across all namespaces ---
echo "Calculating cluster pod count..."
_report_milestone  # M4: pod-counting-start

# Count active pods (Running, Pending, ContainerCreating) using server-side field-selector.
# Single kubectl call with --chunk-size=500 keeps memory bounded (~500 pods of JSON at a time)
# regardless of cluster size. Excludes completed/failed job pods.
NUM_PODS=$(kubectl get pods --all-namespaces --no-headers --chunk-size=500 \
    --field-selector='status.phase!=Succeeded,status.phase!=Failed' \
    2>/dev/null | wc -l | tr -d '[:space:]')
TOTAL_PODS=$(( NUM_PODS * 130 / 100 ))  # 30% buffer

NUM_NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')

if [ "$TOTAL_PODS" -le 0 ]; then
    echo "WARNING: No active pods found. Using minimum tier."
    TOTAL_PODS=1
fi

echo "Cluster pod count: $NUM_PODS active pods"
echo "Adjusted pod count (with 30% buffer): $TOTAL_PODS"

# --- Label density ---
# Hardcoded to 6 (multiplier 1.0x) — no runtime measurement needed.
# Removes the kubectl call that could require large memory on 500+ pod clusters.
# If pods OOM due to high label cardinality, bump memory manually.
AVG_LABELS=6
LABEL_MULTIPLIER=$(get_label_multiplier "$AVG_LABELS")
echo "Label density: $AVG_LABELS (default), multiplier: ${LABEL_MULTIPLIER}x"

# --- GPU node detection ---
GPU_NODE_COUNT=0
TOTAL_GPU_COUNT=0
gpu_capacities=$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.capacity.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null || true)
if [ -n "$gpu_capacities" ]; then
    GPU_NODE_COUNT=$(echo "$gpu_capacities" | awk '$1+0 > 0 {c++} END {print c+0}')
    TOTAL_GPU_COUNT=$(echo "$gpu_capacities" | awk '{s+=$1} END {print s+0}')
fi
if [ "$GPU_NODE_COUNT" -gt 0 ]; then
    echo "GPU nodes: $GPU_NODE_COUNT nodes, $TOTAL_GPU_COUNT GPUs total"
    dcgm_pods=$(kubectl get pods --all-namespaces -l app=nvidia-dcgm-exporter --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
    if [ "$dcgm_pods" -eq 0 ] 2>/dev/null; then
        echo "WARNING: GPU nodes found but NVIDIA DCGM exporter not detected — GPU utilization metrics unavailable"
    else
        echo "NVIDIA DCGM exporter running ($dcgm_pods pods)"
    fi
fi

# --- Resource tier selection ---
select_resource_tier "$TOTAL_PODS"
echo "Setting resources for $TIER cluster ($TOTAL_PODS pods)"
_report_milestone  # M5: pod-counting-done — survived namespace scan, tier selected

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
  REGISTRY_URL=$(_get '.["onelens-agent"].env.REGISTRY_URL')
  # Note: Can't use _get for booleans — jq's `false // empty` returns empty since false is falsy
  PVC_ENABLED=$(echo "$CURRENT_VALUES" | jq -r '.prometheus.server.persistentVolume.enabled // "true"')

  # Detect cloud provider from existing StorageClass provisioner
  SC_PROVISIONER=$(_get '.["onelens-agent"].storageClass.provisioner')

  echo "  Cluster: $CLUSTER_NAME | Cloud: $SC_PROVISIONER | PVC: $PVC_ENABLED"
  if [ -n "$REGISTRY_URL" ]; then
      echo "  Air-gapped mode: REGISTRY_URL=$REGISTRY_URL"
  fi

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
  # Preserve CLUSTER_TOKEN and REGISTRATION_ID from environment (injected by deployer CronJob
  # from onelens-agent-secrets). Don't blank them — they're our fallback when helm get values
  # fails due to RBAC. Helm upgrade will be skipped but API reporting and diagnostics continue.
  CLUSTER_TOKEN="${CLUSTER_TOKEN:-}"
  REGISTRATION_ID="${REGISTRATION_ID:-}"
  DEFAULT_CLUSTER_ID=""
  REGISTRY_URL=""
  PVC_ENABLED="true"
  SC_PROVISIONER=""
  CUSTOMER_VALUES_FILE=""
  EXISTING_PVC_SIZE=""
fi

# Validate required identity values
SKIP_HELM_UPGRADE=false
if [ -z "$CLUSTER_TOKEN" ] || [ -z "$REGISTRATION_ID" ]; then
    echo "ERROR: Could not read CLUSTER_TOKEN or REGISTRATION_ID from helm release or environment."
    echo "These are required for helm upgrade. Check if onelens-agent is installed."
    echo "Skipping helm upgrade — continuing with diagnostics only."
    SKIP_HELM_UPGRADE=true
fi

_report_milestone  # M3: credentials-ready — identity extracted, about to diagnose

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
echo "Sizing: nodes=$NUM_NODES pods=$TOTAL_PODS (active=$NUM_PODS) labels=$AVG_LABELS mult=${LABEL_MULTIPLIER}x tier=$TIER gpuNodes=$GPU_NODE_COUNT gpus=$TOTAL_GPU_COUNT"

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
_report_milestone  # M6: prometheus-health — values set, checking usage data

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

# ═══════════════════════════════════════════════════════════════════════════
# Usage-based right-sizing — query Prometheus and evaluate resource limits
# ═══════════════════════════════════════════════════════════════════════════
# Queries actual usage data from Prometheus (72h window), reads OOM events,
# manages ConfigMap state, and calls the evaluation engine to determine
# optimal resource limits. Falls back to tier-based sizing if unavailable.

USAGE_BASED_APPLIED=false

if [ -n "$PROM_SVC" ]; then
    PROM_QUERY_URL="http://${PROM_SVC}.onelens-agent.svc.cluster.local:80/api/v1/query"
    _prom_query_raw() {
        curl -s -G --max-time 15 "$PROM_QUERY_URL" --data-urlencode "query=$1" 2>/dev/null || true
    }

    # Query 72h max memory and CPU for sizing decisions
    MEM_72H_RAW=$(_prom_query_raw 'max by (container) (max_over_time(container_memory_working_set_bytes{namespace="onelens-agent",container!="",container!="POD"}[72h]))')
    CPU_72H_RAW=$(_prom_query_raw 'max by (container) (max_over_time(rate(container_cpu_usage_seconds_total{namespace="onelens-agent",container!="",container!="POD"}[5m])[72h:5m]))')

    # Query current usage for logging (1h window)
    MEM_NOW_RAW=$(_prom_query_raw 'sum by (container) (container_memory_working_set_bytes{namespace="onelens-agent",container!="",container!="POD"})')
    MEM_1H_RAW=$(_prom_query_raw 'max by (container) (max_over_time(container_memory_working_set_bytes{namespace="onelens-agent",container!="",container!="POD"}[1h]))')
    CPU_NOW_RAW=$(_prom_query_raw 'sum by (container) (rate(container_cpu_usage_seconds_total{namespace="onelens-agent",container!="",container!="POD"}[5m]))')

    # Parse results
    MEM_72H=$(parse_prom_result "$MEM_72H_RAW")
    CPU_72H=$(parse_prom_result "$CPU_72H_RAW")
    MEM_NOW=$(parse_prom_result "$MEM_NOW_RAW")
    MEM_1H=$(parse_prom_result "$MEM_1H_RAW")
    CPU_NOW=$(parse_prom_result "$CPU_NOW_RAW")

    # Log current usage (observability)
    if [ -n "$MEM_NOW" ]; then
        echo "Actual usage (now | max 1h | max 72h):"
        (
            echo "$MEM_NOW" | while read c v; do echo "mem_now $c $v"; done
            echo "$MEM_1H" | while read c v; do echo "mem_1h $c $v"; done
            echo "$MEM_72H" | while read c v; do echo "mem_72h $c $v"; done
            echo "$CPU_NOW" | while read c v; do echo "cpu_now $c $v"; done
        ) | awk '
        {
            type=$1; container=$2; val=$3
            if (type == "mem_now") mem_now[container] = val
            if (type == "mem_1h") mem_1h[container] = val
            if (type == "mem_72h") mem_72h[container] = val
            if (type == "cpu_now") cpu_now[container] = val
        }
        END {
            for (c in mem_now) {
                mn = int(mem_now[c] / 1048576)
                m1 = int(mem_1h[c] / 1048576)
                m72 = int(mem_72h[c] / 1048576)
                cpu = cpu_now[c] + 0
                printf "  %s: mem=%dMi|%dMi|%dMi cpu=%dm\n", c, mn, m1, m72, int(cpu * 1000)
            }
        }' | sort
    fi

    # Query OOM events from Prometheus (KSM metric)
    OOM_PROM_RAW=$(_prom_query_raw 'kube_pod_container_status_last_terminated_reason{namespace="onelens-agent",reason="OOMKilled"}')
    OOM_PROM=$(parse_prom_oom_count "$OOM_PROM_RAW")

    # Kubectl fallback for OOM detection + Pending pod warning
    OOM_KUBECTL=""
    if [ -z "$OOM_PROM" ]; then
        # Fetch pod JSON once for both OOM detection and Pending check
        _pods_json=$(kubectl get pods -n onelens-agent -o json 2>/dev/null || true)

        # Detect OOM from: (1) lastState.terminated.reason == OOMKilled, or
        # (2) CrashLoopBackOff with restartCount >= 3 (pod keeps crashing, likely OOM —
        #     kernel doesn't always label it OOMKilled, e.g. during WAL replay)
        if [ -n "$_pods_json" ]; then
            OOM_KUBECTL=$(echo "$_pods_json" | jq -r '
                .items[].status.containerStatuses[]? |
                select(
                    .lastState.terminated.reason == "OOMKilled" or
                    (.state.waiting.reason == "CrashLoopBackOff" and .restartCount >= 3)
                ) | .name
            ' 2>/dev/null || true)
            if [ -n "$OOM_KUBECTL" ]; then
                echo "OOM detected via kubectl fallback (Prometheus unavailable for KSM metric):"
                echo "$OOM_KUBECTL" | while read -r _oname; do echo "  $_oname"; done
            fi

            # Warn on pods Pending for >30 minutes (possible node resource exhaustion — don't bump)
            _pending_warn=$(echo "$_pods_json" | jq -r '
                .items[] | select(.status.phase == "Pending") |
                select(now - (.metadata.creationTimestamp | fromdateiso8601) > 1800) |
                .metadata.name
            ' 2>/dev/null || true)
            if [ -n "$_pending_warn" ]; then
                echo "WARNING: pods Pending for >30 minutes (possible node resource exhaustion):"
                echo "$_pending_warn" | while read -r _pname; do echo "  $_pname"; done
            fi
        fi
    fi

    # Read ConfigMap state
    IS_FIRST_RUN=false
    CM_JSON=$(kubectl get configmap onelens-agent-sizing-state -n onelens-agent -o json 2>/dev/null || true)
    if [ -z "$CM_JSON" ] || ! echo "$CM_JSON" | jq -e '.data' >/dev/null 2>&1; then
        # First run: create ConfigMap with last_full_evaluation=now
        IS_FIRST_RUN=true
        NOW_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        kubectl create configmap onelens-agent-sizing-state -n onelens-agent \
            --from-literal=last_full_evaluation="$NOW_TS" \
            --from-literal=prometheus-server.last_oom_at="" \
            --from-literal=kube-state-metrics.last_oom_at="" \
            --from-literal=opencost.last_oom_at="" \
            --from-literal=pushgateway.last_oom_at="" 2>/dev/null || true
        echo "Created sizing state ConfigMap (first run, downsize deferred 72h)"
        STATE_LAST_FULL_EVAL="$NOW_TS"
        STATE_LAST_OOM_prometheus_server=""
        STATE_LAST_OOM_kube_state_metrics=""
        STATE_LAST_OOM_opencost=""
        STATE_LAST_OOM_pushgateway=""
    else
        parse_sizing_state "$CM_JSON"
    fi

    # Determine if 72h full evaluation is due
    FULL_EVAL_DUE=false
    if is_full_eval_due "$STATE_LAST_FULL_EVAL" 72; then
        FULL_EVAL_DUE=true
        echo "72h full evaluation due (last: $STATE_LAST_FULL_EVAL)"
    fi

    # Only proceed with usage-based if we have 72h data
    if [ -n "$MEM_72H" ]; then
        echo "Usage-based sizing: evaluating..."
        USAGE_BASED_APPLIED=true

        # Helper: extract value for a container from parsed Prometheus output
        _get_container_val() {
            local data="$1" container="$2"
            echo "$data" | awk -v c="$container" '$1 == c {print $2; exit}'
        }

        # Helper: check if container has OOM
        _has_oom() {
            local container="$1"
            # Check Prometheus metric
            if echo "$OOM_PROM" | grep -q "^${container} "; then return 0; fi
            # Check kubectl fallback
            if echo "$OOM_KUBECTL" | grep -qF "$container"; then return 0; fi
            return 1
        }

        # Helper: get OOM-recent state variable for a container
        _get_oom_recent() {
            local container="$1"
            case "$container" in
                prometheus-server) is_oom_recent "$STATE_LAST_OOM_prometheus_server" 7 && echo "true" || echo "false" ;;
                kube-state-metrics) is_oom_recent "$STATE_LAST_OOM_kube_state_metrics" 7 && echo "true" || echo "false" ;;
                *opencost*) is_oom_recent "$STATE_LAST_OOM_opencost" 7 && echo "true" || echo "false" ;;
                *) echo "false" ;;
            esac
        }

        # Track OOM updates for ConfigMap
        NEW_PROM_OOM="$STATE_LAST_OOM_prometheus_server"
        NEW_KSM_OOM="$STATE_LAST_OOM_kube_state_metrics"
        NEW_OC_OOM="$STATE_LAST_OOM_opencost"
        NEW_PGW_OOM="$STATE_LAST_OOM_pushgateway"
        SIZING_CHANGES=0

        # _evaluate_and_log "$label" "$container_name" "$current_mem" "$current_cpu" \
        #   "$mem_floor" "$mem_cap" "$oom_state_var"
        # Evaluates one component with full diagnostic logging.
        # Sets: _OUT_MEM, _OUT_CPU, increments SIZING_CHANGES if changed.
        _evaluate_and_log() {
            local label="$1" container="$2" cur_mem="$3" cur_cpu="$4"
            local mem_floor="$5" mem_cap="$6" oom_state_var="$7"

            local mem_bytes cpu_cores oom_now oom_recent
            mem_bytes=$(_get_container_val "$MEM_72H" "$container")
            cpu_cores=$(_get_container_val "$CPU_72H" "$container")

            # OOM detection (record timestamp on first run too — activates 7-day hold)
            oom_now=false
            if _has_oom "$container"; then
                oom_now=true
                eval "$oom_state_var=\"\$(date -u +\"%Y-%m-%dT%H:%M:%SZ\")\""
                if [ "$IS_FIRST_RUN" = "true" ]; then
                    echo "  $label: OOM detected on first run — recording for 7-day hold (no resize)"
                else
                    echo "  $label: OOM detected — bumping memory from $cur_mem"
                fi
            fi

            oom_recent=$(_get_oom_recent "$container")
            if [ "$oom_recent" = "true" ]; then
                echo "  $label: OOM hold active (7-day window), no downsize"
            fi

            local result new_mem new_cpu
            result=$(evaluate_container_sizing "$container" \
                "$cur_mem" "$cur_cpu" "$mem_bytes" "$cpu_cores" \
                "$oom_now" "$oom_recent" "$FULL_EVAL_DUE" "$IS_FIRST_RUN" \
                1.35 1.25 "$mem_floor" "$mem_cap" "$_USAGE_FLOOR_CPU" "$_USAGE_CAP_CPU")
            new_mem=$(echo "$result" | grep '^MEM=' | cut -d= -f2)
            new_cpu=$(echo "$result" | grep '^CPU=' | cut -d= -f2)

            if [ "$new_mem" != "$cur_mem" ] || [ "$new_cpu" != "$cur_cpu" ]; then
                echo "  $label: mem ${cur_mem}→${new_mem} cpu ${cur_cpu}→${new_cpu}"
                SIZING_CHANGES=$((SIZING_CHANGES + 1))
                # Check if safety guard would have blocked a larger downsize
                if [ "$FULL_EVAL_DUE" = "true" ] && [ -n "$mem_bytes" ] && [ "$mem_bytes" != "0" ]; then
                    local proposed
                    proposed=$(calculate_usage_memory "$mem_bytes" 1.35 "$mem_floor" "$mem_cap")
                    if [ -n "$proposed" ] && ! is_safe_downsize "$proposed" "$cur_mem"; then
                        echo "  $label: safety guard limited downsize (target was $proposed, >50% reduction)"
                    fi
                fi
            else
                echo "  $label: no change (mem=$cur_mem cpu=$cur_cpu)"
            fi

            _OUT_MEM="$new_mem"
            _OUT_CPU="$new_cpu"
        }

        # Before usage-based evaluation, ensure tier values don't drop below helm-current.
        # Without this, OOM doubling starts from the tier base (e.g., 1600Mi for extra-large)
        # instead of the actual running value (e.g., 4800Mi), causing a downsize.
        if [[ -n "$CURRENT_VALUES" ]] && command -v jq &>/dev/null; then
            _upguard_mem() {
                local path="$1" var="$2"
                local existing
                existing=$(echo "$CURRENT_VALUES" | jq -r "$path // empty")
                if [ -n "$existing" ]; then
                    local kept
                    kept=$(_max_memory "$existing" "${!var}")
                    if [ "$kept" != "${!var}" ]; then
                        echo "  $(echo "$var" | tr '_' ' '): preserving helm-current $existing (tier was ${!var})"
                    fi
                    eval "$var=\"$kept\""
                fi
            }
            _upguard_cpu() {
                local path="$1" var="$2"
                local existing
                existing=$(echo "$CURRENT_VALUES" | jq -r "$path // empty")
                if [ -n "$existing" ]; then
                    local kept
                    kept=$(_max_cpu "$existing" "${!var}")
                    if [ "$kept" != "${!var}" ]; then
                        echo "  $(echo "$var" | tr '_' ' '): preserving helm-current $existing (tier was ${!var})"
                    fi
                    eval "$var=\"$kept\""
                fi
            }
            _upguard_mem '.prometheus.server.resources.limits.memory' PROMETHEUS_MEMORY_LIMIT
            _upguard_mem '.prometheus.server.resources.requests.memory' PROMETHEUS_MEMORY_REQUEST
            _upguard_cpu '.prometheus.server.resources.limits.cpu' PROMETHEUS_CPU_LIMIT
            _upguard_cpu '.prometheus.server.resources.requests.cpu' PROMETHEUS_CPU_REQUEST
            _upguard_mem '.prometheus["kube-state-metrics"].resources.limits.memory' KSM_MEMORY_LIMIT
            _upguard_mem '.prometheus["kube-state-metrics"].resources.requests.memory' KSM_MEMORY_REQUEST
            _upguard_cpu '.prometheus["kube-state-metrics"].resources.limits.cpu' KSM_CPU_LIMIT
            _upguard_cpu '.prometheus["kube-state-metrics"].resources.requests.cpu' KSM_CPU_REQUEST
            _upguard_mem '.["prometheus-opencost-exporter"].opencost.exporter.resources.limits.memory' OPENCOST_MEMORY_LIMIT
            _upguard_mem '.["prometheus-opencost-exporter"].opencost.exporter.resources.requests.memory' OPENCOST_MEMORY_REQUEST
            _upguard_cpu '.["prometheus-opencost-exporter"].opencost.exporter.resources.limits.cpu' OPENCOST_CPU_LIMIT
            _upguard_cpu '.["prometheus-opencost-exporter"].opencost.exporter.resources.requests.cpu' OPENCOST_CPU_REQUEST
        fi

        # Evaluate: Prometheus
        _evaluate_and_log "prometheus-server" "prometheus-server" \
            "$PROMETHEUS_MEMORY_LIMIT" "$PROMETHEUS_CPU_LIMIT" \
            "$_USAGE_FLOOR_PROM_MEM" "$_USAGE_CAP_PROM_MEM" "NEW_PROM_OOM"
        PROMETHEUS_MEMORY_REQUEST="$_OUT_MEM"; PROMETHEUS_MEMORY_LIMIT="$_OUT_MEM"
        PROMETHEUS_CPU_REQUEST="$_OUT_CPU"; PROMETHEUS_CPU_LIMIT="$_OUT_CPU"

        # Evaluate: KSM
        _evaluate_and_log "kube-state-metrics" "kube-state-metrics" \
            "$KSM_MEMORY_LIMIT" "$KSM_CPU_LIMIT" \
            "$_USAGE_FLOOR_KSM_MEM" "$_USAGE_CAP_KSM_MEM" "NEW_KSM_OOM"
        KSM_MEMORY_REQUEST="$_OUT_MEM"; KSM_MEMORY_LIMIT="$_OUT_MEM"
        KSM_CPU_REQUEST="$_OUT_CPU"; KSM_CPU_LIMIT="$_OUT_CPU"

        # Evaluate: OpenCost
        _evaluate_and_log "opencost" "onelens-agent-prometheus-opencost-exporter" \
            "$OPENCOST_MEMORY_LIMIT" "$OPENCOST_CPU_LIMIT" \
            "$_USAGE_FLOOR_OPENCOST_MEM" "$_USAGE_CAP_OPENCOST_MEM" "NEW_OC_OOM"
        OPENCOST_MEMORY_REQUEST="$_OUT_MEM"; OPENCOST_MEMORY_LIMIT="$_OUT_MEM"
        OPENCOST_CPU_REQUEST="$_OUT_CPU"; OPENCOST_CPU_LIMIT="$_OUT_CPU"

        # Evaluate: Pushgateway (fixed, OOM → 1.25x)
        PGW_OOM_NOW=false
        if _has_oom "prometheus-pushgateway"; then
            PGW_OOM_NOW=true
            NEW_PGW_OOM=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
            echo "  pushgateway: OOM detected — bumping 1.25x"
        fi
        PGW_RESULT=$(evaluate_fixed_container_sizing "pushgateway" "$PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT" "$PGW_OOM_NOW")
        NEW_PGW_MEM=$(echo "$PGW_RESULT" | grep '^MEM=' | cut -d= -f2)
        if [ "$NEW_PGW_MEM" != "$PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT" ]; then
            echo "  pushgateway: mem ${PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT}→${NEW_PGW_MEM}"
            SIZING_CHANGES=$((SIZING_CHANGES + 1))
        else
            echo "  pushgateway: no change (mem=$PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT)"
        fi
        PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST="$NEW_PGW_MEM"
        PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT="$NEW_PGW_MEM"

        # Summary
        if [ "$SIZING_CHANGES" -gt 0 ]; then
            echo "Usage-based sizing: $SIZING_CHANGES component(s) adjusted"
        else
            echo "Usage-based sizing: no changes needed"
        fi

        # Update ConfigMap with new state
        NEW_EVAL_TS="$STATE_LAST_FULL_EVAL"
        if [ "$FULL_EVAL_DUE" = "true" ]; then
            NEW_EVAL_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        fi
        PATCH_JSON=$(build_sizing_state_patch "$NEW_EVAL_TS" "$NEW_PROM_OOM" "$NEW_KSM_OOM" "$NEW_OC_OOM" "$NEW_PGW_OOM")
        kubectl patch configmap onelens-agent-sizing-state -n onelens-agent --type merge -p "$PATCH_JSON" 2>/dev/null || true
    else
        echo "Usage-based sizing: no Prometheus data available, keeping tier-based limits"
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

# _auto_recover_pvc "$pvc_name" "$old_size"
# Auto-recover when PV object is gone (deleted from K8s). We have namespace-scoped
# CRUD on PVCs, so we can: remove finalizers → delete PVC → let helm recreate it.
# Returns 0 on success, 1 on failure (falls back to manual steps).
_auto_recover_pvc() {
    local pvc_name="$1" old_size="$2"

    echo "PV is gone from Kubernetes. Auto-recovering PVC '$pvc_name'..."

    # Step 1: Remove PVC finalizers (kubernetes.io/pv-protection prevents deletion while PV is bound)
    if kubectl patch pvc "$pvc_name" -n onelens-agent -p '{"metadata":{"finalizers":null}}' 2>/dev/null; then
        echo "  Removed PVC finalizers."
    else
        echo "  WARNING: Failed to remove PVC finalizers — falling back to manual recovery."
        _do_pv_recovery "$pvc_name" "" "$old_size"
        return 1
    fi

    # Step 2: Delete the ghost PVC (use --wait to ensure it's fully gone before helm runs)
    if kubectl delete pvc "$pvc_name" -n onelens-agent --timeout=30s 2>/dev/null; then
        echo "  Deleted PVC '$pvc_name' (was bound to non-existent PV)."
    else
        echo "  WARNING: Failed to delete PVC — falling back to manual recovery."
        _do_pv_recovery "$pvc_name" "" "$old_size"
        return 1
    fi

    # Step 3: Clear EXISTING_CLAIM_FLAG so helm creates a new PVC instead of binding to the deleted name
    EXISTING_CLAIM_FLAG=""

    if [ -n "$old_size" ]; then
        echo "  Previous PVC size was $old_size. Helm upgrade will create a new PVC via onelens-sc StorageClass."
    else
        echo "  Helm upgrade will create a new PVC via onelens-sc StorageClass."
    fi
    return 0
}

# _do_pv_recovery "$pvc_name" "$pv_name" "$old_size"
# Logs PV recovery error with manual remediation steps.
# Used when the PV object still exists but is broken (Failed/Released state) —
# we can't delete cluster-scoped PVs (intentional security restriction).
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
        # Capture stderr to distinguish RBAC errors from genuine "not found".
        # On clusters with broken ClusterRoleBindings, `kubectl get pv` returns Forbidden
        # which was previously swallowed by 2>/dev/null, causing false "PV gone" detection.
        PV_CHECK_RESULT=$(kubectl get pv "$BOUND_PV" --no-headers 2>&1) || true

        if echo "$PV_CHECK_RESULT" | grep -qiE 'forbidden|unauthorized'; then
            echo "WARNING: Cannot verify PV '$BOUND_PV' (RBAC: $(echo "$PV_CHECK_RESULT" | head -1))."
            echo "Skipping PV health check — RBAC prevents reading cluster-scoped PersistentVolumes."
        elif [ -z "$PV_CHECK_RESULT" ] || echo "$PV_CHECK_RESULT" | grep -qiE 'not found|error from server'; then
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

                _auto_recover_pvc "$PROM_PVC_NAME" "$OLD_PVC_SIZE" || _PV_NEEDS_MANUAL_FIX=true
            elif [ "$POD_STATUS" = "Running" ]; then
                # PV is gone but pod is still Running on cached kernel VFS mount.
                # Data persistence is broken — writes may silently fail or the pod
                # will crash on next restart. Proactively restart to surface the issue.
                echo "WARNING: PV '$BOUND_PV' is gone but pod is still Running on cached VFS."

                # Dedup guard: skip restart if pod started recently (< 10 min ago).
                # A previous patching run may have already restarted and validated this pod.
                _skip_restart=false
                _pod_start=$(kubectl get pod "$PROM_POD" -n onelens-agent -o jsonpath='{.status.startTime}' 2>/dev/null || true)
                if [ -n "$_pod_start" ]; then
                    _pod_start_epoch=$(date -d "$_pod_start" "+%s" 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$_pod_start" "+%s" 2>/dev/null || true)
                    _now_epoch=$(date -u "+%s")
                    if [ -n "$_pod_start_epoch" ] && [ $((_now_epoch - _pod_start_epoch)) -lt 600 ]; then
                        echo "Pod '$PROM_POD' started $((_now_epoch - _pod_start_epoch))s ago (< 600s). Skipping PV restart — likely already validated by a recent run."
                        _skip_restart=true
                    fi
                fi

                if [ "$_skip_restart" = "false" ]; then
                    echo "Data persistence is broken — restarting pod to surface volume failure."
                    kubectl delete pod "$PROM_POD" -n onelens-agent --grace-period=10 2>/dev/null || true

                    echo "Waiting for pod restart..."
                    sleep 45
                    # Re-check: new pod should fail to mount the volume.
                    # Look for FailedMount/FailedAttachVolume events to distinguish from slow image pulls.
                    # Single kubectl call to avoid race condition between name and status extraction.
                    _pod_line=$(kubectl get pods -n onelens-agent --no-headers 2>/dev/null \
                        | awk '/prometheus-server/ && !/Terminating/{print; exit}' || true)
                    _new_pod_name=$(echo "$_pod_line" | awk '{print $1}')
                    _new_pod_status=$(echo "$_pod_line" | awk '{print $3}')
                    echo "Pod status after restart: ${_new_pod_status:-unknown}"

                    if [ "$_new_pod_status" = "Running" ]; then
                        echo "Pod restarted and remounted successfully — volume was not actually gone."
                    elif [ -n "$_new_pod_name" ]; then
                        # Confirm it's a volume issue, not a slow image pull or scheduling delay
                        _mount_events=$(kubectl get events -n onelens-agent \
                            --field-selector "involvedObject.name=$_new_pod_name" --no-headers 2>/dev/null \
                            | grep -iE 'FailedAttachVolume|FailedMount|AttachVolume.Attach failed' || true)
                        if [ -n "$_mount_events" ]; then
                            echo "Volume mount failure confirmed. Auto-recovering PVC..."
                            _auto_recover_pvc "$PROM_PVC_NAME" "$OLD_PVC_SIZE" || _PV_NEEDS_MANUAL_FIX=true
                        else
                            # PV is confirmed gone and pod is not Running after restart.
                            # Even without explicit FailedMount events (may have expired),
                            # a missing PV + non-Running pod is sufficient for recovery.
                            echo "PV is confirmed missing and pod did not recover after restart. Auto-recovering PVC..."
                            _auto_recover_pvc "$PROM_PVC_NAME" "$OLD_PVC_SIZE" || _PV_NEEDS_MANUAL_FIX=true
                        fi
                    else
                        echo "No prometheus-server pod found after restart. Skipping auto-recovery."
                    fi
                fi
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

# ═══════════════════════════════════════════════════════════════════════════
# FailedAttachVolume Remediation — delete pods stuck in ContainerCreating
# ═══════════════════════════════════════════════════════════════════════════
# If a pod is stuck in ContainerCreating/Pending with FailedAttachVolume or
# FailedMount events for >5min, delete it so K8s reschedules with a new volume.
# 30-minute cooldown per component prevents delete-looping.

_remediate_stuck_volume_pod() {
    local component="$1"
    local pod_name pod_status pod_age_secs pod_events last_delete_at

    # Find pod matching component in stuck state
    pod_name=$(kubectl get pods -n onelens-agent --no-headers 2>/dev/null \
        | awk -v c="$component" '$1 ~ c && ($3 == "ContainerCreating" || $3 == "Pending") {print $1; exit}' || true)
    if [ -z "$pod_name" ]; then return 0; fi

    # Check pod age > 5 minutes
    local pod_start
    pod_start=$(kubectl get pod "$pod_name" -n onelens-agent -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || true)
    if [ -z "$pod_start" ]; then return 0; fi
    pod_age_secs=$(seconds_since "$pod_start")
    if [ -z "$pod_age_secs" ] || [ "$pod_age_secs" -lt 300 ] 2>/dev/null; then return 0; fi

    # Check events for FailedAttachVolume/FailedMount (not image pull issues)
    pod_events=$(kubectl get events -n onelens-agent --field-selector "involvedObject.name=$pod_name" --no-headers 2>/dev/null \
        | grep -iE 'FailedAttachVolume|FailedMount|AttachVolume.Attach failed' || true)
    if [ -z "$pod_events" ]; then return 0; fi

    # Cooldown: check ConfigMap for last deletion timestamp
    local cm_key="${component}.last_volume_delete_at"
    last_delete_at=$(kubectl get configmap onelens-agent-sizing-state -n onelens-agent \
        -o jsonpath="{.data['${cm_key}']}" 2>/dev/null || true)
    if [ -n "$last_delete_at" ]; then
        local secs_since_delete
        secs_since_delete=$(seconds_since "$last_delete_at")
        if [ -n "$secs_since_delete" ] && [ "$secs_since_delete" -lt 1800 ] 2>/dev/null; then
            echo "Volume remediation: $component pod '$pod_name' still stuck but was deleted ${secs_since_delete}s ago. Requires customer action."
            return 0
        fi
    fi

    # Delete the stuck pod
    echo "Volume remediation: deleting $component pod '$pod_name' stuck for $((pod_age_secs / 60))m with FailedAttachVolume"
    kubectl delete pod "$pod_name" -n onelens-agent --grace-period=0 2>/dev/null || true

    # Record deletion timestamp in ConfigMap
    local now_ts
    now_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    kubectl patch configmap onelens-agent-sizing-state -n onelens-agent --type merge \
        -p "{\"data\":{\"${cm_key}\":\"${now_ts}\"}}" 2>/dev/null || true

    # Wait briefly for reschedule
    sleep 30
    local new_status
    new_status=$(kubectl get pods -n onelens-agent --no-headers 2>/dev/null \
        | awk -v c="$component" '$1 ~ c && $3 != "Terminating" {print $1, $3; exit}' || true)
    echo "Volume remediation: $component post-delete status: $new_status"
}

# Remediate stuck volume pods for all onelens components
for _vol_component in prometheus-server kube-state-metrics opencost prometheus-pushgateway; do
    _remediate_stuck_volume_pod "$_vol_component"
done

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

# Memory guard: usage-based sizing (above) replaces the old "never downsize" guard.
# If usage-based was applied, limits are already set from actual Prometheus data.
# If not (Prometheus unavailable), fall back to the old guard to prevent OOM.
if [ "$USAGE_BASED_APPLIED" != "true" ] && [[ -n "$CURRENT_VALUES" ]] && command -v jq &>/dev/null; then
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

    echo "Fallback: usage-based unavailable, applying legacy memory guard..."
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

# --- Chart version (computed early — needed by both chart source and helm upgrade) ---
# PATCHING_VERSION is exported by entrypoint.sh from the API response.
# normalize_chart_version strips v/release/ prefix to get a clean semver for --version.
CHART_VERSION=""
if [ -n "${PATCHING_VERSION:-}" ]; then
    CHART_VERSION=$(normalize_chart_version "$PATCHING_VERSION" 2>/dev/null || echo "")
fi

# --- Chart source ---
if [ -n "$REGISTRY_URL" ]; then
    # Air-gapped: chart is pre-loaded as a ConfigMap by the migration script.
    # No registry auth needed — the ConfigMap was created on a machine with access.
    echo "Air-gapped mode: reading chart from ConfigMap onelens-agent-chart"
    _cm_err=$(kubectl get configmap onelens-agent-chart -n onelens-agent -o name 2>&1) || {
        if echo "$_cm_err" | grep -qi "forbidden\|unauthorized"; then
            echo "ERROR: Permission denied reading ConfigMap onelens-agent-chart."
            echo "  Cause: The deployer pod's service account cannot read configmaps in namespace onelens-agent."
            echo "  Fix:   Ensure the onelensdeployer Role grants get/list on configmaps (this is included by default)."
            echo "         If you customized RBAC, add: resources: [\"configmaps\"] verbs: [\"get\",\"list\"]"
            echo "  Detail: $_cm_err"
        else
            echo "ERROR: ConfigMap onelens-agent-chart not found in namespace onelens-agent."
            echo "  Cause: The migration script was not run, or was run against a different cluster."
            echo "  Fix:   Run the migration script with kubectl access to this cluster:"
            echo "         bash airgapped_migrate_images.sh --registry <your-registry-url>"
        fi
        exit 1
    }
    kubectl get configmap onelens-agent-chart -n onelens-agent \
        -o go-template='{{index .binaryData "chart.tgz"}}' | base64 -d > /tmp/onelens-agent-chart.tgz
    if [ ! -s /tmp/onelens-agent-chart.tgz ]; then
        echo "ERROR: Failed to extract chart from ConfigMap onelens-agent-chart."
        echo "  The ConfigMap exists but extraction produced an empty file."
        echo "  Fix: Re-run the migration script to recreate the ConfigMap."
        exit 1
    fi
    _CHART_CM_VERSION=$(tar xzf /tmp/onelens-agent-chart.tgz -O onelens-agent/Chart.yaml 2>/dev/null | grep '^version:' | awk '{print $2}')
    echo "Chart from ConfigMap: version $_CHART_CM_VERSION ($(du -h /tmp/onelens-agent-chart.tgz | awk '{print $1}'))"
    if [ -n "$CHART_VERSION" ] && [ "$CHART_VERSION" != "$_CHART_CM_VERSION" ]; then
        echo "Skipping helm upgrade — ConfigMap has chart version $_CHART_CM_VERSION but target is $CHART_VERSION"
        echo "  The target version is not available in the cluster. To upgrade:"
        echo "  1. Re-run the migration script with --version $CHART_VERSION (or latest)"
        echo "  2. The next patching run will pick up the new chart automatically"
        echo "  All other remediation (pod health, OOM recovery, resource sizing) will still run."
        SKIP_HELM_UPGRADE=true
    fi
    CHART_SOURCE="/tmp/onelens-agent-chart.tgz"
else
    helm repo add onelens https://astuto-ai.github.io/onelens-installation-scripts >/dev/null 2>&1
    helm repo update >/dev/null 2>&1
    CHART_SOURCE="onelens/onelens-agent"
fi

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
# Note: SKIP_HELM_UPGRADE may already be true (set earlier if identity values are missing).
# Don't reset it here — only set to true, never back to false.
if [ "$RELEASE_STATUS" = "pending-upgrade" ] || [ "$RELEASE_STATUS" = "pending-rollback" ] || [ "$RELEASE_STATUS" = "pending-install" ]; then
    echo "Helm release stuck in '$RELEASE_STATUS' — rolling back to last successful revision..."
    LAST_GOOD_REV=$(helm history onelens-agent -n onelens-agent -o json 2>/dev/null \
        | jq -r '[.[] | select(.status == "deployed" or .status == "superseded")] | last | .revision' || true)
    if [ -n "$LAST_GOOD_REV" ] && [ "$LAST_GOOD_REV" != "null" ]; then
        _rollback_err=$(helm rollback onelens-agent "$LAST_GOOD_REV" -n onelens-agent --timeout=3m 2>&1)
        _rollback_exit=$?
        if [ $_rollback_exit -eq 0 ]; then
            echo "Rolled back to revision $LAST_GOOD_REV"
        else
            echo "WARNING: Rollback failed (exit $_rollback_exit): $_rollback_err"
            # If rollback failed due to RBAC (forbidden), skip helm upgrade entirely.
            # The deployer SA can't write to the namespace — helm upgrade will also fail.
            # Continue to healthcheck/diagnostics so we still get patching_logs.
            if echo "$_rollback_err" | grep -qiE 'forbidden|cannot .* resource'; then
                echo "RBAC ERROR: Deployer SA cannot write to onelens-agent namespace."
                echo "The RoleBinding may be broken (common on clusters upgraded from v1.x deployer)."
                echo "Fix: customer must upgrade the deployer chart as cluster admin to restore RBAC permissions."
                echo "Skipping helm upgrade — continuing with diagnostics only."
                SKIP_HELM_UPGRADE=true
            fi
        fi
    else
        echo "WARNING: No previous successful revision found — attempting upgrade anyway"
    fi
fi

# Skip helm upgrade if RBAC is broken — apply resources via kubectl instead
if [ "$SKIP_HELM_UPGRADE" = "true" ]; then
    echo "Helm blocked — applying resource right-sizing via kubectl patch..."
    _kubectl_set_resources() {
        local deploy="$1" container="$2" cpu_req="$3" mem_req="$4" cpu_lim="$5" mem_lim="$6"
        if ! kubectl get deployment "$deploy" -n onelens-agent >/dev/null 2>&1; then
            return
        fi
        # Discover actual container name — chart versions use different naming conventions.
        local actual_container="$container"
        local containers
        containers=$(kubectl get deployment "$deploy" -n onelens-agent \
            -o jsonpath='{.spec.template.spec.containers[*].name}' 2>/dev/null || true)
        if [ -n "$containers" ] && ! echo " $containers " | grep -q " $container "; then
            for c in $containers; do
                case "$c" in
                    *configmap-reload*|*sidecar*) continue ;;
                    *) actual_container="$c"; break ;;
                esac
            done
            echo "  Container '$container' not found in $deploy, using '$actual_container'"
        fi
        kubectl set resources deployment "$deploy" -n onelens-agent \
            -c "$actual_container" \
            --requests="cpu=${cpu_req},memory=${mem_req}" \
            --limits="cpu=${cpu_lim},memory=${mem_lim}" \
            2>&1 || echo "  WARNING: failed to patch $deploy"
    }
    _kubectl_set_resources "onelens-agent-prometheus-server" "prometheus-server" \
        "$PROMETHEUS_CPU_REQUEST" "$PROMETHEUS_MEMORY_REQUEST" "$PROMETHEUS_CPU_LIMIT" "$PROMETHEUS_MEMORY_LIMIT"
    _kubectl_set_resources "onelens-agent-kube-state-metrics" "kube-state-metrics" \
        "$KSM_CPU_REQUEST" "$KSM_MEMORY_REQUEST" "$KSM_CPU_LIMIT" "$KSM_MEMORY_LIMIT"
    _kubectl_set_resources "onelens-agent-prometheus-opencost-exporter" "opencost" \
        "$OPENCOST_CPU_REQUEST" "$OPENCOST_MEMORY_REQUEST" "$OPENCOST_CPU_LIMIT" "$OPENCOST_MEMORY_LIMIT"
    _kubectl_set_resources "onelens-agent-prometheus-pushgateway" "prometheus-pushgateway" \
        "$PROMETHEUS_PUSHGATEWAY_CPU_REQUEST" "$PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST" \
        "$PROMETHEUS_PUSHGATEWAY_CPU_LIMIT" "$PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT"
    echo "kubectl resource patching complete."
    UPGRADE_FAILED=true
    WAL_OOM_APPLIED=false
else
# Build helm upgrade command
# Key design: NO --reuse-values
#   - globalvalues.yaml provides chart defaults (images, configs, scrape jobs)
#   - Customer values file preserves tolerations, nodeSelector, podLabels
#   - --set overrides for identity, resources, retention, PVC
#   - --version pins to the target version from PATCHING_VERSION (set by entrypoint.sh)
#     Without --version, helm would pick latest from repo — uncontrolled upgrades.
#     If PATCHING_VERSION is not set (old entrypoint), omit --version (backward compat).
# Note: CHART_VERSION is computed earlier (before chart source block) so air-gapped
# helm pull can use --version to pin the correct chart version.
HELM_CMD="helm upgrade onelens-agent $CHART_SOURCE \
  -f /globalvalues.yaml \
  --history-max 5 \
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

# Air-gapped: override all image sources to private registry and persist REGISTRY_URL.
# Charts that use "{repository}:{tag}" get repository=$REGISTRY_URL/<name>.
# Charts that use "{registry}/{repository}:{tag}" get registry=$REGISTRY_URL + repository=<name>
# to produce the flat path $REGISTRY_URL/<name>:{tag} matching what the migration script pushes.
if [ -n "$REGISTRY_URL" ]; then
    echo "Applying air-gapped image overrides for registry: $REGISTRY_URL"
    HELM_CMD="$HELM_CMD \
      --set onelens-agent.image.repository=$REGISTRY_URL/onelens-agent \
      --set prometheus.server.image.repository=$REGISTRY_URL/prometheus \
      --set prometheus.configmapReload.prometheus.image.repository=$REGISTRY_URL/prometheus-config-reloader \
      --set prometheus-opencost-exporter.opencost.exporter.image.registry=$REGISTRY_URL \
      --set prometheus-opencost-exporter.opencost.exporter.image.repository=opencost \
      --set prometheus.kube-state-metrics.image.registry=$REGISTRY_URL \
      --set prometheus.kube-state-metrics.image.repository=kube-state-metrics \
      --set prometheus.prometheus-pushgateway.image.repository=$REGISTRY_URL/pushgateway \
      --set prometheus.kube-state-metrics.kubeRBACProxy.image.registry=$REGISTRY_URL \
      --set prometheus.kube-state-metrics.kubeRBACProxy.image.repository=kube-rbac-proxy \
      --set onelens-agent.env.REGISTRY_URL=$REGISTRY_URL"
fi

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

# ═══════════════════════════════════════════════════════════════════════════
# Helm upgrade with pod failure retry loop
# ═══════════════════════════════════════════════════════════════════════════
# If any pod OOMs after upgrade, bump that component's memory and retry
# immediately instead of waiting for the next 5-min CronJob cycle.

# _detect_pod_failure — check if any onelens pod is failing after upgrade.
# Scans all pods. Returns 0 (true) if a failing pod is found.
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

    # Check Prometheus readiness first — OpenCost depends on it
    local _prom_ready=false
    local _prom_pod_check
    _prom_pod_check=$(kubectl get pods -n onelens-agent --no-headers 2>/dev/null \
        | awk '/prometheus-server/{print $2, $3; exit}' || true)
    if echo "$_prom_pod_check" | grep -q 'Running' && echo "$_prom_pod_check" | grep -qE '^2/2|^1/1'; then
        _prom_ready=true
    fi

    # Check each component in dependency order
    local component
    for component in prometheus-server kube-state-metrics prometheus-opencost-exporter prometheus-pushgateway; do
        # Skip OpenCost if Prometheus is not ready — OpenCost depends on Prometheus
        if [ "$component" = "prometheus-opencost-exporter" ] && [ "$_prom_ready" != "true" ]; then
            continue
        fi

        local pod_name pod_status container_name restart_count term_reason pod_logs events

        pod_name=$(echo "$pods_raw" | awk -v p="$component" '$1 ~ p {print $1; exit}' || true)
        if [ -z "$pod_name" ]; then continue; fi

        pod_status=$(kubectl get pod "$pod_name" -n onelens-agent \
            -o jsonpath='{.status.phase}' 2>/dev/null || true)
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
        if echo "$events" | grep -qiE 'FailedScheduling.*PersistentVolume.*node affinity'; then
            _FAIL_REASON="other"
            _FAIL_DIAG="pod=$pod_name component=$component reason=PV_AZ_MISMATCH (PV is AZ-locked but no nodes available in that AZ. Customer must ensure node capacity in the PV's availability zone, or reinstall with multi-AZ storage: EFS for AWS, Azure Files for Azure)"
        elif echo "$events" | grep -qiE 'FailedScheduling.*Insufficient'; then
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

# _bump_component_memory — bump memory for a failing component.
# Prometheus/KSM/OpenCost: 1.5x (heavy workloads). Pushgateway: 1.25x (lightweight).
# Returns "old_mem new_mem --set flags" for helm retry.
_bump_component_memory() {
    local component="$1"
    local old_mem new_mem cap set_flags=""

    case "$component" in
        prometheus-server)
            old_mem="$PROMETHEUS_MEMORY_LIMIT"
            cap="$_USAGE_CAP_PROM_MEM"
            new_mem=$(calculate_wal_oom_memory "$old_mem" "$cap")  # 1.5x
            PROMETHEUS_MEMORY_REQUEST="$new_mem"; PROMETHEUS_MEMORY_LIMIT="$new_mem"
            set_flags="--set prometheus.server.resources.requests.memory=\"$new_mem\" --set prometheus.server.resources.limits.memory=\"$new_mem\""
            ;;
        kube-state-metrics)
            old_mem="$KSM_MEMORY_LIMIT"
            cap="$_USAGE_CAP_KSM_MEM"
            new_mem=$(calculate_wal_oom_memory "$old_mem" "$cap")  # 1.5x
            KSM_MEMORY_REQUEST="$new_mem"; KSM_MEMORY_LIMIT="$new_mem"
            set_flags="--set prometheus.kube-state-metrics.resources.requests.memory=\"$new_mem\" --set prometheus.kube-state-metrics.resources.limits.memory=\"$new_mem\""
            ;;
        prometheus-opencost-exporter)
            old_mem="$OPENCOST_MEMORY_LIMIT"
            cap="$_USAGE_CAP_OPENCOST_MEM"
            new_mem=$(calculate_wal_oom_memory "$old_mem" "$cap")  # 1.5x
            OPENCOST_MEMORY_REQUEST="$new_mem"; OPENCOST_MEMORY_LIMIT="$new_mem"
            set_flags="--set prometheus-opencost-exporter.opencost.exporter.resources.requests.memory=\"$new_mem\" --set prometheus-opencost-exporter.opencost.exporter.resources.limits.memory=\"$new_mem\""
            ;;
        prometheus-pushgateway)
            old_mem="$PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT"
            new_mem=$(apply_memory_multiplier "$old_mem" 1.25)  # 1.25x — lightweight
            local new_mi=$(_memory_to_mi "$new_mem")
            if [ "$new_mi" -gt 256 ] 2>/dev/null; then new_mem="256Mi"; fi
            PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST="$new_mem"; PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT="$new_mem"
            set_flags="--set prometheus.prometheus-pushgateway.resources.requests.memory=\"$new_mem\" --set prometheus.prometheus-pushgateway.resources.limits.memory=\"$new_mem\""
            ;;
    esac

    echo "$old_mem $new_mem $set_flags"
}

# ═══════════════════════════════════════════════════════════════════════════
# Pod Remediation Module (v2.1.33+)
# ═══════════════════════════════════════════════════════════════════════════
# Intelligently remediate stuck OneLens pods: OOMKilled, transient crashes,
# scheduling failures. Prevents infinite loops with 30-min cooldown per pod.
# All actions logged to stdout (visible to customer via patching_logs).

# --- STATE TRACKING (ConfigMap-based) ---
# Prevents infinite remediation loops by tracking last remediation time per pod

_get_remediation_state() {
    local pod_name="$1"
    local state_key="${pod_name}.last_remediation_at"

    kubectl get configmap onelens-agent-remediation-state -n onelens-agent \
        -o jsonpath="{.data['${state_key}']}" 2>/dev/null || echo ""
}

_set_remediation_state() {
    local pod_name="$1"
    local state_key="${pod_name}.last_remediation_at"
    local now_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Ensure ConfigMap exists
    kubectl get configmap onelens-agent-remediation-state -n onelens-agent >/dev/null 2>&1 || \
        kubectl create configmap onelens-agent-remediation-state -n onelens-agent 2>/dev/null || true

    # Update timestamp
    kubectl patch configmap onelens-agent-remediation-state -n onelens-agent --type merge \
        -p "{\"data\":{\"${state_key}\":\"${now_ts}\"}}" 2>/dev/null || true
}

_can_remediate() {
    local pod_name="$1"
    local cooldown_mins="${2:-30}"  # Default 30 min cooldown

    local last_remediation=$(_get_remediation_state "$pod_name")
    if [ -z "$last_remediation" ]; then
        return 0  # Never remediated, can try
    fi

    # Check if cooldown passed (portable date command with fallbacks for GNU and BSD)
    local last_secs=$(
        date -d "$last_remediation" +%s 2>/dev/null || \
        date -juf "%Y-%m-%dT%H:%M:%SZ" "$last_remediation" +%s 2>/dev/null || \
        echo 0
    )
    local now_secs=$(date +%s)
    local secs_since=$((now_secs - last_secs))
    local cooldown_secs=$((cooldown_mins * 60))

    if [ $secs_since -ge $cooldown_secs ]; then
        return 0  # Cooldown passed
    fi

    return 1  # Still in cooldown
}

# --- POD FAILURE CLASSIFICATION ---

_get_pod_failure_reason() {
    local pod_name="$1"

    # Check container status first (more reliable)
    local status=$(kubectl get pod "$pod_name" -n onelens-agent \
        -o jsonpath='{.status.containerStatuses[0].state}' 2>/dev/null)

    if echo "$status" | grep -q "waiting"; then
        echo "$status" | jq -r '.waiting.reason' 2>/dev/null
    elif echo "$status" | grep -q "terminated"; then
        local reason=$(echo "$status" | jq -r '.terminated.reason' 2>/dev/null)
        if [ "$reason" = "OOMKilled" ]; then
            echo "OOMKilled"
        else
            echo "Terminated"
        fi
    else
        # Fallback: check pod conditions
        kubectl get pod "$pod_name" -n onelens-agent \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || echo "Unknown"
    fi
}

# --- INTELLIGENT REMEDIATION HANDLERS ---

_remediate_oomkilled_pod() {
    local pod_name="$1"
    local component="$2"
    local current_memory

    echo ""
    echo "🔧 Attempting remediation: OOMKilled pod $pod_name"

    # Get current memory limit
    current_memory=$(kubectl get pod "$pod_name" -n onelens-agent \
        -o jsonpath='{.spec.containers[0].resources.limits.memory}' 2>/dev/null)

    if [ -z "$current_memory" ]; then
        echo "⚠️  Cannot determine current memory limit for $pod_name"
        return 1
    fi

    # Convert to bytes for calculation (pure bash, no bc dependency)
    local mem_mi="${current_memory%Mi}"  # Remove "Mi" suffix
    if ! [[ "$mem_mi" =~ ^[0-9]+$ ]]; then
        echo "⚠️  Cannot parse memory value: $current_memory"
        return 1
    fi
    local mem_bytes=$((mem_mi * 1024 * 1024))

    # Increase by 1.5x
    local new_bytes=$((mem_bytes * 150 / 100))
    local new_memory_mi=$((new_bytes / 1024 / 1024))

    echo "  Current memory: $current_memory → Increasing to ${new_memory_mi}Mi (1.5x)"

    # Update deployment resource limit
    if kubectl set resources deployment "$component" -n onelens-agent \
        --limits=memory="${new_memory_mi}Mi" 2>/dev/null; then

        echo "  ✅ Memory limit increased to ${new_memory_mi}Mi"
        echo "  Deleting $pod_name to restart with new limits..."

        # Delete pod to trigger restart with new limits
        if kubectl delete pod "$pod_name" -n onelens-agent --grace-period=5 2>/dev/null; then
            echo "  ✅ Pod deleted, will restart with increased memory"
            _set_remediation_state "$pod_name"
            return 0
        else
            echo "  ❌ Failed to delete pod $pod_name"
            return 1
        fi
    else
        echo "  ❌ Failed to update memory limit for $component"
        return 1
    fi
}

_remediate_transient_crash() {
    local pod_name="$1"
    local reason="$2"

    echo ""
    echo "🔧 Attempting remediation: Transient error in $pod_name"
    echo "  Reason: $reason"
    echo "  Deleting pod for retry..."

    if kubectl delete pod "$pod_name" -n onelens-agent --grace-period=5 2>/dev/null; then
        echo "  ✅ Pod deleted, will retry automatically"
        _set_remediation_state "$pod_name"
        return 0
    else
        echo "  ❌ Failed to delete pod $pod_name"
        return 1
    fi
}

_remediate_scheduling_failure() {
    local pod_name="$1"
    local pod_memory

    echo ""
    echo "🔧 Attempting remediation: FailedScheduling pod $pod_name"

    # Get pod memory request
    pod_memory=$(kubectl get pod "$pod_name" -n onelens-agent \
        -o jsonpath='{.spec.containers[0].resources.requests.memory}' 2>/dev/null)

    if [ -z "$pod_memory" ]; then
        echo "  ⚠️  Cannot determine memory request"
        return 1
    fi

    echo "  Pod memory requirement: $pod_memory"
    echo "  Checking node capacity..."

    # Get allocatable memory across all nodes (single fast jq call, not per-node kubectl top)
    # kubectl top is 30-60s per node (too slow); instead check if ANY node has allocatable memory
    local nodes_with_capacity
    nodes_with_capacity=$(kubectl get nodes -o json 2>/dev/null | jq -r '
        .items[] |
        select(.status.allocatable.memory != null) |
        .metadata.name
    ' 2>/dev/null | head -1)

    if [ -n "$nodes_with_capacity" ]; then
        echo "  ✅ Found node with capacity: $nodes_with_capacity"
        echo "  Deleting pod for reschedule..."

        if kubectl delete pod "$pod_name" -n onelens-agent --grace-period=5 2>/dev/null; then
            echo "  ✅ Pod deleted, will reschedule to node with capacity"
            _set_remediation_state "$pod_name"
            return 0
        else
            echo "  ❌ Failed to delete pod"
            return 1
        fi
    else
        echo "  ❌ No nodes have sufficient capacity"
        echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  🚨 ALERT: NODE CAPACITY EXHAUSTED"
        echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Pod $pod_name cannot be scheduled due to insufficient node memory"
        echo "  "
        echo "  ACTION REQUIRED (Customer):"
        echo "    1. Scale up node group (add more nodes)"
        echo "    2. Increase node instance size"
        echo "    3. Scale down non-OneLens workloads"
        echo "  "
        echo "  Patching will retry once node capacity becomes available."
        echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        return 1
    fi
}

_alert_image_build_failed() {
    local pod_name="$1"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🚨 CRITICAL: IMAGE BUILD FAILED"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Pod: $pod_name (Status: ImagePullBackOff)"
    echo ""
    echo "ACTION REQUIRED (OneLens Team):"
    echo "  1. Check image build logs in CI/CD"
    echo "  2. Verify image exists in registry: docker://..."
    echo "  3. Check image pull secrets in cluster"
    echo "  4. If build failed, fix and redeploy"
    echo ""
    echo "Patching will NOT retry this automatically until image is fixed."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

_alert_code_bug() {
    local pod_name="$1"
    local logs="$2"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🚨 CODE BUG: POD REPEATEDLY CRASHING"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Pod: $pod_name (Status: CrashLoopBackOff)"
    echo ""
    echo "Recent logs:"
    echo "$logs" | head -5 | sed 's/^/  /'
    echo ""
    echo "ACTION REQUIRED (OneLens Team):"
    echo "  1. Debug pod logs: kubectl logs -n onelens-agent $pod_name"
    echo "  2. Fix the underlying code/config issue"
    echo "  3. Deploy v2.1.33+ with fix"
    echo ""
    echo "Patching will continue retrying until fixed."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# --- MAIN POD REMEDIATION FUNCTION ---

_remediate_stuck_pods() {
    local stuck_pods
    local pod_name pod_status failure_reason pod_logs

    echo ""
    echo "=== POD HEALTH CHECK & REMEDIATION (v2.1.33+) ==="

    # Get all unhealthy pods in onelens-agent namespace
    stuck_pods=$(kubectl get pods -n onelens-agent --no-headers 2>/dev/null | \
        awk '$3 !~ /^Running$|^Completed$/ {print $1}' | head -20)

    if [ -z "$stuck_pods" ]; then
        echo "✅ All OneLens pods are healthy"
        echo ""
        return 0
    fi

    # Process each stuck pod
    while IFS= read -r pod_name; do
        [ -z "$pod_name" ] && continue

        # Skip if in cooldown
        if ! _can_remediate "$pod_name"; then
            continue
        fi

        # Get pod status and failure reason
        pod_status=$(kubectl get pod "$pod_name" -n onelens-agent \
            -o jsonpath='{.status.phase}' 2>/dev/null)
        failure_reason=$(_get_pod_failure_reason "$pod_name")

        echo ""
        echo "Pod: $pod_name | Status: $pod_status | Reason: $failure_reason"

        # Route to appropriate handler
        case "$failure_reason" in
            OOMKilled)
                # Check if pod is owned by a Job (CronJob-created agent pods).
                # Agent OOM is handled separately in the Agent CronJob Health section below,
                # which patches the CronJob spec directly. _remediate_oomkilled_pod only works
                # for Deployment-owned pods (prometheus, KSM, opencost).
                local owner_kind=$(kubectl get pod "$pod_name" -n onelens-agent \
                    -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null || true)
                if [ "$owner_kind" = "Job" ]; then
                    echo "  Skipping — agent CronJob pod, handled in Agent CronJob Health section"
                else
                    local component=$(echo "$pod_name" | sed 's/-[a-z0-9]*-[a-z0-9]*$//')
                    _remediate_oomkilled_pod "$pod_name" "$component"
                fi
                ;;

            ConnectionRefused|Timeout|EOF|Failed)
                _remediate_transient_crash "$pod_name" "$failure_reason"
                ;;

            Unschedulable)
                _remediate_scheduling_failure "$pod_name"
                ;;

            ImagePullBackOff|ErrImagePull)
                _alert_image_build_failed "$pod_name"
                # Don't set remediation state - we won't retry this automatically
                ;;

            CrashLoopBackOff)
                # Check logs to distinguish transient vs permanent
                pod_logs=$(kubectl logs "$pod_name" -n onelens-agent --tail=20 2>/dev/null || echo "")

                if echo "$pod_logs" | grep -iq "OOMKilled\|out of memory"; then
                    # Skip CronJob-owned pods (agent OOM handled in Agent CronJob Health section)
                    local owner_kind=$(kubectl get pod "$pod_name" -n onelens-agent \
                        -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null || true)
                    if [ "$owner_kind" = "Job" ]; then
                        echo "  Skipping — agent CronJob pod, handled in Agent CronJob Health section"
                    else
                        local component=$(echo "$pod_name" | sed 's/-[a-z0-9]*-[a-z0-9]*$//')
                        _remediate_oomkilled_pod "$pod_name" "$component"
                    fi
                elif echo "$pod_logs" | grep -iq "connection.*refused\|timeout\|eof"; then
                    _remediate_transient_crash "$pod_name" "transient error"
                else
                    _alert_code_bug "$pod_name" "$pod_logs"
                fi
                ;;

            Pending)
                # Check if pending > 10 min
                local pod_age=$(kubectl get pod "$pod_name" -n onelens-agent \
                    -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)
                # Portable date calculation (GNU and BSD compatible)
                local pod_age_secs=$(
                    date -d "$pod_age" +%s 2>/dev/null || \
                    date -juf "%Y-%m-%dT%H:%M:%SZ" "$pod_age" +%s 2>/dev/null || \
                    echo 0
                )
                local age_secs=$(($(date +%s) - pod_age_secs))

                if [ $age_secs -gt 600 ]; then
                    # Check if it's scheduling issue
                    local events=$(kubectl get events -n onelens-agent \
                        --field-selector involvedObject.name=$pod_name \
                        --no-headers 2>/dev/null | head -1)

                    if echo "$events" | grep -q "FailedScheduling"; then
                        _remediate_scheduling_failure "$pod_name"
                    else
                        echo "  ⚠️  Pod stuck Pending > 10min (no scheduling event found)"
                    fi
                fi
                ;;

            Terminated)
                # Normal for completed/failed Job pods (agent CronJob). The Agent CronJob
                # Health section below handles these (deletes failed jobs, triggers fresh runs).
                # For Deployment-owned pods this shouldn't happen (ReplicaSet replaces immediately).
                local owner_kind=$(kubectl get pod "$pod_name" -n onelens-agent \
                    -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null || true)
                if [ "$owner_kind" = "Job" ]; then
                    echo "  Skipping — terminated agent job pod, handled in Agent CronJob Health section"
                else
                    echo "  ⚠️  Terminated non-job pod (ReplicaSet should have replaced it)"
                fi
                ;;

            *)
                echo "  ⚠️  Unknown failure reason: $failure_reason"
                ;;
        esac

    done <<< "$stuck_pods"

    echo ""
}

WAL_OOM_APPLIED=false
UPGRADE_FAILED=false
_UPGRADE_RETRIES=0
_MAX_UPGRADE_RETRIES=3

# Run pod remediation before helm upgrade (auto-fix stuck pods)
_remediate_stuck_pods || true  # Don't fail patching if remediation fails

# Prune stale helm release secrets to prevent ResourceQuota deadlocks.
# Helm stores each revision as a secret. With 5-min healthcheck upgrades, secrets
# accumulate fast. If a namespace has a ResourceQuota on secrets, helm upgrade fails
# because it can't create the new secret, and it can't prune old ones until after
# a successful upgrade — deadlock. Prune proactively before upgrade.
_HELM_SECRETS=$(kubectl get secrets -n onelens-agent -l owner=helm,name=onelens-agent \
    --sort-by=.metadata.creationTimestamp -o name 2>/dev/null || true)
if [ -n "$_HELM_SECRETS" ]; then
    _HELM_SECRET_COUNT=$(echo "$_HELM_SECRETS" | grep -c '^' 2>/dev/null || echo "0")
else
    _HELM_SECRET_COUNT=0
fi
if [ "$_HELM_SECRET_COUNT" -gt 5 ]; then
    _PRUNE_COUNT=$(( _HELM_SECRET_COUNT - 5 ))
    echo "Helm release secrets: $_HELM_SECRET_COUNT found, pruning $_PRUNE_COUNT (keeping last 5)"
    echo "$_HELM_SECRETS" | head -n "$_PRUNE_COUNT" | while read -r secret; do
        kubectl delete "$secret" -n onelens-agent 2>/dev/null || true
    done
else
    echo "Helm release secrets: $_HELM_SECRET_COUNT found, no pruning needed"
fi

echo "Running helm upgrade (latest chart, fresh values + customer overrides)..."
_report_milestone  # M7: helm-upgrade-start — all sizing done, about to apply
eval "$HELM_CMD"
UPGRADE_EXIT=$?

# Retry loop: if any pod OOMs after upgrade, bump that component and retry immediately
while true; do
    if [ $UPGRADE_EXIT -eq 0 ]; then
        # Poll for pods to stabilize — transient startup failures (OpenCost before
        # Prometheus) resolve in 30-60s. Shorter window than install.sh because
        # patching runs under activeDeadlineSeconds.
        _pods_ok=false
        for _poll in 1 2 3; do
            echo "Checking pod health (attempt $_poll/3)..."
            sleep 30
            if ! _detect_pod_failure; then
                _pods_ok=true
                break
            fi
            echo "  Pods not stable yet: $_FAIL_DIAG"
        done
        if [ "$_pods_ok" = "true" ]; then
            UPGRADE_FAILED=false
            break
        fi
        echo "Pods still failing after 90s: $_FAIL_DIAG"

        # OpenCost transient: crashes with FTL when Prometheus is unreachable during restart.
        # If Prometheus is now healthy, give OpenCost one extra restart cycle to recover.
        if [ "$_FAIL_COMPONENT" = "prometheus-opencost-exporter" ] && [ "$_FAIL_REASON" != "oom" ]; then
            _oc_logs=$(kubectl logs "$_FAIL_POD" -n onelens-agent --tail=10 2>/dev/null || true)
            if echo "$_oc_logs" | grep -qiE 'Failed to create Prometheus data source|connection refused.*prometheus'; then
                _prom_line=$(kubectl get pods -n onelens-agent --no-headers 2>/dev/null \
                    | awk '/prometheus-server/{print; exit}')
                _prom_ready_col=$(echo "$_prom_line" | awk '{print $2}')
                _prom_status_col=$(echo "$_prom_line" | awk '{print $3}')
                if [ "$_prom_status_col" = "Running" ] && echo "$_prom_ready_col" | grep -qE '^2/2$|^1/1$'; then
                    echo "OpenCost failing due to Prometheus dependency (transient). Prometheus is healthy — waiting for OpenCost to recover..."
                    sleep 30
                    if ! _detect_pod_failure; then
                        echo "OpenCost recovered after extended wait."
                        UPGRADE_FAILED=false
                        break
                    fi
                    echo "OpenCost still failing after extended wait: $_FAIL_DIAG"
                else
                    echo "OpenCost cannot start: Prometheus is not ready (${_prom_ready_col:-?} ${_prom_status_col:-unknown})."
                    echo "Root cause is Prometheus, not OpenCost. OpenCost will recover once Prometheus is healthy."
                fi
            fi
        fi
    else
        echo "Helm upgrade failed (exit $UPGRADE_EXIT)."
        if ! _detect_pod_failure; then
            echo "No specific pod failure detected. Pod status:"
            kubectl get pods -n onelens-agent --no-headers 2>/dev/null || true
            kubectl get events -n onelens-agent --sort-by='.lastTimestamp' --no-headers 2>/dev/null | tail -5 || true
            UPGRADE_FAILED=true
            break
        fi
        echo "Pod failure detected: $_FAIL_DIAG"
    fi

    # Only retry for OOM failures
    if [ "$_FAIL_REASON" != "oom" ]; then
        echo "Failure is not memory-related (reason=$_FAIL_REASON). Not retrying."
        if [ -n "$_FAIL_POD" ]; then
            echo "--- Pod logs ---"
            kubectl logs "$_FAIL_POD" -n onelens-agent --previous --tail=20 2>/dev/null || \
                kubectl logs "$_FAIL_POD" -n onelens-agent --tail=20 2>/dev/null || true
            echo "--- Events ---"
            kubectl get events -n onelens-agent --field-selector "involvedObject.name=$_FAIL_POD" --no-headers 2>/dev/null | tail -5 || true
        fi
        UPGRADE_FAILED=true
        break
    fi

    # Check retry limit
    if [ "$_UPGRADE_RETRIES" -ge "$_MAX_UPGRADE_RETRIES" ]; then
        echo "OOM: exhausted $_MAX_UPGRADE_RETRIES retries. Component=$_FAIL_COMPONENT"
        echo "--- Final pod status ---"
        kubectl get pods -n onelens-agent --no-headers 2>/dev/null || true
        UPGRADE_FAILED=true
        break
    fi

    # Bump the failing component's memory
    _bump_result=$(_bump_component_memory "$_FAIL_COMPONENT")
    _old_mem=$(echo "$_bump_result" | awk '{print $1}')
    _new_mem=$(echo "$_bump_result" | awk '{print $2}')
    _set_flags=$(echo "$_bump_result" | cut -d' ' -f3-)

    if [ "$_new_mem" = "$_old_mem" ]; then
        echo "$_FAIL_COMPONENT OOM: at memory cap ($_old_mem). Cannot bump further."
        UPGRADE_FAILED=true
        break
    fi

    _UPGRADE_RETRIES=$((_UPGRADE_RETRIES + 1))
    echo "OOM recovery (retry $_UPGRADE_RETRIES/$_MAX_UPGRADE_RETRIES): $_FAIL_COMPONENT memory $_old_mem -> $_new_mem"
    WAL_OOM_APPLIED=true

    RETRY_CMD="$HELM_CMD --timeout=3m $_set_flags"
    eval "$RETRY_CMD"
    UPGRADE_EXIT=$?
done

fi  # end SKIP_HELM_UPGRADE else block

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

# If the upgrade retry loop flagged failure (e.g., OpenCost transient crash during
# Prometheus restart) but all pods recovered during the stabilization window above,
# reset the failure flag. OpenCost crashes with "connection refused" when Prometheus
# service IP is switching endpoints — this resolves in 30-60s, well within our 60s
# stabilization window. A genuine failure would still be non-Ready here.
if [ "$UPGRADE_FAILED" = "true" ] && [ "$STABLE" = "true" ]; then
    echo "Upgrade was flagged failed but all pods recovered. Resetting upgrade status."
    UPGRADE_FAILED=false
fi

# Deployer chart is NOT self-upgraded here. The deployer SA cannot grant itself
# broader RBAC permissions (Kubernetes escalation prevention), and patching.sh
# is fetched from the API every run so it's always the latest version regardless
# of the deployer image. The CronJob schedule and activeDeadlineSeconds are
# already patched via kubectl at the top of this script (Phase 3).
# If the deployer chart itself needs upgrading (e.g., new entrypoint.sh),
# it must be done by a cluster admin: helm upgrade onelensdeployer ...

# Get the chart version that was actually deployed
DEPLOYED_VERSION=$(helm list -n onelens-agent -o json 2>/dev/null | jq -r '.[0].chart' | sed 's/onelens-agent-//' || echo "unknown")

echo ""
echo "=== POST-PATCH ==="
echo "Chart: $DEPLOYED_VERSION | Tier: $TIER | Pods: $TOTAL_PODS | Labels: ${LABEL_MULTIPLIER}x"
echo "Retention: $PROMETHEUS_RETENTION | Size: $PROMETHEUS_RETENTION_SIZE | PVC: $PROMETHEUS_VOLUME_SIZE"
if [ "$WAL_OOM_APPLIED" = "true" ]; then
    echo "WAL OOM recovery: applied (Prometheus memory bumped 1.5x)"
fi
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

# ═══════════════════════════════════════════════════════════════════════════
# Agent CronJob Health Check — the data pipeline final mile
# ═══════════════════════════════════════════════════════════════════════════
# Without the agent CronJob sending data, Prometheus/KSM/OpenCost are useless.
# Check its health, diagnose failures, and fix what we can.

echo ""
echo "=== AGENT CRONJOB HEALTH ==="

AGENT_CJ_NAME="onelens-agent"
# Agent CronJob pods/jobs have numeric suffixes: onelens-agent-29564100-xxxxx
# Use this pattern to avoid matching deployment pods (onelens-agent-kube-state-metrics-*, etc.)
AGENT_POD_PATTERN="^${AGENT_CJ_NAME}-[0-9]"
AGENT_CJ_EXISTS=$(kubectl get cronjob "$AGENT_CJ_NAME" -n onelens-agent --no-headers 2>/dev/null || true)

if [ -n "$AGENT_CJ_EXISTS" ]; then
    # CronJob state
    AGENT_SUSPENDED=$(kubectl get cronjob "$AGENT_CJ_NAME" -n onelens-agent -o jsonpath='{.spec.suspend}' 2>/dev/null || echo "unknown")
    AGENT_LAST_SCHEDULE=$(kubectl get cronjob "$AGENT_CJ_NAME" -n onelens-agent -o jsonpath='{.status.lastScheduleTime}' 2>/dev/null || true)
    AGENT_BACKOFF=$(kubectl get cronjob "$AGENT_CJ_NAME" -n onelens-agent -o jsonpath='{.spec.jobTemplate.spec.backoffLimit}' 2>/dev/null || true)
    # Read actual container name from CronJob spec (don't assume it matches CronJob name)
    AGENT_CONTAINER_NAME=$(kubectl get cronjob "$AGENT_CJ_NAME" -n onelens-agent \
        -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].name}' 2>/dev/null || echo "$AGENT_CJ_NAME")

    echo "CronJob: schedule=$(kubectl get cronjob "$AGENT_CJ_NAME" -n onelens-agent -o jsonpath='{.spec.schedule}' 2>/dev/null) suspend=$AGENT_SUSPENDED lastSchedule=$AGENT_LAST_SCHEDULE backoffLimit=${AGENT_BACKOFF:-default} container=$AGENT_CONTAINER_NAME"

    # Fix: unsuspend if suspended
    if [ "$AGENT_SUSPENDED" = "true" ]; then
        echo "WARNING: Agent CronJob is suspended. Unsuspending..."
        kubectl patch cronjob "$AGENT_CJ_NAME" -n onelens-agent --type='merge' --field-manager='Helm' -p='{"spec":{"suspend":false}}' 2>/dev/null && \
            echo "Agent CronJob unsuspended" || echo "WARNING: Failed to unsuspend agent CronJob"
    fi

    # Fix: patch backoffLimit to 0 only if explicitly set to non-zero.
    # Don't patch if empty (not in spec) — avoids stealing field ownership from helm.
    if [ -n "$AGENT_BACKOFF" ] && [ "$AGENT_BACKOFF" != "0" ] 2>/dev/null; then
        echo "Patching agent CronJob backoffLimit from $AGENT_BACKOFF to 0..."
        kubectl patch cronjob "$AGENT_CJ_NAME" -n onelens-agent --type='merge' --field-manager='Helm' -p='{"spec":{"jobTemplate":{"spec":{"backoffLimit":0}}}}' 2>/dev/null && \
            echo "Agent CronJob backoffLimit patched" || echo "WARNING: Failed to patch agent backoffLimit"
    fi

    # Check for agent pods stuck in Pending/ContainerCreating (volume attach, image pull, scheduling)
    AGENT_STUCK_POD=$(kubectl get pods -n onelens-agent --no-headers 2>/dev/null \
        | grep -E "$AGENT_POD_PATTERN" \
        | awk '$3 == "Pending" || $3 == "ContainerCreating" {print $1; exit}' || true)
    if [ -n "$AGENT_STUCK_POD" ]; then
        AGENT_STUCK_AGE=$(kubectl get pod "$AGENT_STUCK_POD" -n onelens-agent \
            -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || true)
        AGENT_STUCK_SECS=""
        if [ -n "$AGENT_STUCK_AGE" ]; then
            AGENT_STUCK_SECS=$(seconds_since "$AGENT_STUCK_AGE")
        fi
        AGENT_STUCK_EVENTS=$(kubectl get events -n onelens-agent --field-selector "involvedObject.name=$AGENT_STUCK_POD" --no-headers 2>/dev/null | tail -5 || true)
        echo "WARNING: Agent pod stuck: $AGENT_STUCK_POD (${AGENT_STUCK_SECS:-?}s)"
        if [ -n "$AGENT_STUCK_EVENTS" ]; then
            echo "--- Agent stuck pod events ---"
            echo "$AGENT_STUCK_EVENTS"
            echo "--- end ---"
        fi
        # Delete if stuck > 10 min (hourly CronJob, can't afford to wait)
        if [ -n "$AGENT_STUCK_SECS" ] && [ "$AGENT_STUCK_SECS" -gt 600 ] 2>/dev/null; then
            echo "Agent pod stuck > 10 min — deleting to unblock CronJob"
            kubectl delete pod "$AGENT_STUCK_POD" -n onelens-agent --grace-period=0 2>/dev/null || true
        fi
    fi

    # Check recent agent Job pods (last 3 jobs)
    AGENT_JOBS=$(kubectl get jobs -n onelens-agent --no-headers 2>/dev/null \
        | grep -E "$AGENT_POD_PATTERN" | tail -3 || true)
    if [ -n "$AGENT_JOBS" ]; then
        echo "Recent agent jobs:"
        echo "$AGENT_JOBS" | awk '{printf "  %s %s\n", $1, $2}'

        # Find failed agent pods
        AGENT_FAILED_PODS=$(kubectl get pods -n onelens-agent --no-headers 2>/dev/null \
            | grep -E "$AGENT_POD_PATTERN" | grep -E 'Error|OOMKilled|CrashLoopBackOff' | tail -3 || true)

        if [ -n "$AGENT_FAILED_PODS" ]; then
            echo "Failed agent pods:"
            echo "$AGENT_FAILED_PODS" | awk '{printf "  %s %s restarts=%s\n", $1, $3, $4}'

            # Diagnose the most recent failed pod
            AGENT_FAIL_POD=$(echo "$AGENT_FAILED_PODS" | tail -1 | awk '{print $1}')
            if [ -n "$AGENT_FAIL_POD" ]; then
                # Get termination reason and exit code (check current state first, fall back to lastState)
                AGENT_TERM_REASON=$(kubectl get pod "$AGENT_FAIL_POD" -n onelens-agent \
                    -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}' 2>/dev/null || true)
                if [ -z "$AGENT_TERM_REASON" ]; then
                    AGENT_TERM_REASON=$(kubectl get pod "$AGENT_FAIL_POD" -n onelens-agent \
                        -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}' 2>/dev/null || true)
                fi
                AGENT_EXIT_CODE=$(kubectl get pod "$AGENT_FAIL_POD" -n onelens-agent \
                    -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || true)
                if [ -z "$AGENT_EXIT_CODE" ]; then
                    AGENT_EXIT_CODE=$(kubectl get pod "$AGENT_FAIL_POD" -n onelens-agent \
                        -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}' 2>/dev/null || true)
                fi
                AGENT_MEM_LIMIT=$(kubectl get pod "$AGENT_FAIL_POD" -n onelens-agent \
                    -o jsonpath='{.spec.containers[0].resources.limits.memory}' 2>/dev/null || true)

                echo "Diagnosis: pod=$AGENT_FAIL_POD reason=$AGENT_TERM_REASON exitCode=$AGENT_EXIT_CODE memLimit=$AGENT_MEM_LIMIT"

                # Get events for the failed pod (FailedScheduling, ImagePull, etc.)
                AGENT_FAIL_EVENTS=$(kubectl get events -n onelens-agent --field-selector "involvedObject.name=$AGENT_FAIL_POD" --no-headers 2>/dev/null \
                    | grep -iE 'Failed|Error|OOM|Back' | tail -5 || true)
                if [ -n "$AGENT_FAIL_EVENTS" ]; then
                    echo "--- Agent pod events ---"
                    echo "$AGENT_FAIL_EVENTS"
                    echo "--- end ---"
                fi

                # Get last log lines from the failed pod
                AGENT_FAIL_LOGS=$(kubectl logs "$AGENT_FAIL_POD" -n onelens-agent --tail=15 2>/dev/null || \
                    kubectl logs "$AGENT_FAIL_POD" -n onelens-agent --previous --tail=15 2>/dev/null || true)
                if [ -n "$AGENT_FAIL_LOGS" ]; then
                    echo "--- Agent pod logs (last 15 lines) ---"
                    echo "$AGENT_FAIL_LOGS"
                    echo "--- end ---"
                else
                    echo "WARNING: No logs available for agent pod $AGENT_FAIL_POD (pod may have been cleaned up)"
                fi

                # Fix: if cgroup CPU error, round CPU to next 100m via kubectl patch
                if [ "$AGENT_EXIT_CODE" = "128" ] && echo "$AGENT_FAIL_EVENTS" | grep -qiE 'cgroup.*cpu|cpu.*cgroup|cfs_quota' 2>/dev/null; then
                    AGENT_CPU_LIMIT=$(kubectl get pod "$AGENT_FAIL_POD" -n onelens-agent \
                        -o jsonpath='{.spec.containers[0].resources.limits.cpu}' 2>/dev/null || true)
                    AGENT_CPU_MC=$(_cpu_to_millicores "${AGENT_CPU_LIMIT:-400m}")
                    if [ "$AGENT_CPU_MC" -ge "$_USAGE_CAP_CPU" ] 2>/dev/null; then
                        echo "Agent cgroup CPU error but already at cap (${AGENT_CPU_LIMIT}). Manual investigation needed."
                    else
                        # Round up to next 100m
                        AGENT_NEW_CPU=$(( ((AGENT_CPU_MC + 99) / 100) * 100 ))
                        if [ "$AGENT_NEW_CPU" -eq "$AGENT_CPU_MC" ]; then
                            AGENT_NEW_CPU=$((AGENT_CPU_MC + 100))
                        fi
                        # Cap at _USAGE_CAP_CPU
                        if [ "$AGENT_NEW_CPU" -gt "$_USAGE_CAP_CPU" ] 2>/dev/null; then
                            AGENT_NEW_CPU="$_USAGE_CAP_CPU"
                        fi
                        echo "Agent cgroup CPU error — patching CronJob CPU ${AGENT_CPU_LIMIT} -> ${AGENT_NEW_CPU}m"
                        _agent_cpu_patch_err=$(kubectl patch cronjob "$AGENT_CJ_NAME" -n onelens-agent --type='merge' --field-manager='Helm' -p="{
                          \"spec\":{\"jobTemplate\":{\"spec\":{\"template\":{\"spec\":{\"containers\":[{
                            \"name\":\"$AGENT_CONTAINER_NAME\",
                            \"resources\":{\"requests\":{\"cpu\":\"${AGENT_NEW_CPU}m\"},\"limits\":{\"cpu\":\"${AGENT_NEW_CPU}m\"}}
                          }]}}}}}
                        }" 2>&1) && \
                            echo "Agent CronJob CPU patched to ${AGENT_NEW_CPU}m" || \
                            echo "WARNING: Failed to patch agent CronJob CPU: $_agent_cpu_patch_err"
                    fi
                fi

                # Fix: if OOMKilled, bump agent CronJob memory 1.25x via kubectl patch
                if [ "$AGENT_TERM_REASON" = "OOMKilled" ] || [ "$AGENT_EXIT_CODE" = "137" ] || echo "$AGENT_FAIL_LOGS" | grep -qiE 'out of memory|cannot allocate memory|MemoryError' 2>/dev/null; then
                    AGENT_CUR_MI=$(_memory_to_mi "${AGENT_MEM_LIMIT:-384Mi}")
                    if [ "$AGENT_CUR_MI" -ge "$_USAGE_CAP_AGENT_MEM" ] 2>/dev/null; then
                        echo "Agent OOMKilled but already at memory cap (${AGENT_MEM_LIMIT}). Manual investigation needed."
                    else
                        AGENT_NEW_MEM=$(calculate_wal_oom_memory "${AGENT_MEM_LIMIT:-384Mi}" "$_USAGE_CAP_AGENT_MEM")
                        # Cap at _USAGE_CAP_AGENT_MEM
                        AGENT_NEW_MI=$(_memory_to_mi "$AGENT_NEW_MEM")
                        if [ "$AGENT_NEW_MI" -gt "$_USAGE_CAP_AGENT_MEM" ] 2>/dev/null; then
                            AGENT_NEW_MEM="${_USAGE_CAP_AGENT_MEM}Mi"
                        fi
                        echo "Agent OOMKilled — patching CronJob memory ${AGENT_MEM_LIMIT:-384Mi} -> $AGENT_NEW_MEM"
                        _agent_mem_patch_err=$(kubectl patch cronjob "$AGENT_CJ_NAME" -n onelens-agent --type='merge' --field-manager='Helm' -p="{
                          \"spec\":{\"jobTemplate\":{\"spec\":{\"template\":{\"spec\":{\"containers\":[{
                            \"name\":\"$AGENT_CONTAINER_NAME\",
                            \"resources\":{\"requests\":{\"memory\":\"$AGENT_NEW_MEM\"},\"limits\":{\"memory\":\"$AGENT_NEW_MEM\"}}
                          }]}}}}}
                        }" 2>&1) && \
                            echo "Agent CronJob memory patched to $AGENT_NEW_MEM" || \
                            echo "WARNING: Failed to patch agent CronJob memory: $_agent_mem_patch_err"
                    fi
                fi
            fi
        else
            # Check if recent jobs all completed successfully
            AGENT_COMPLETED=$(echo "$AGENT_JOBS" | grep -c 'Complete' || true)
            AGENT_TOTAL=$(echo "$AGENT_JOBS" | wc -l | tr -d '[:space:]')
            echo "Agent jobs: $AGENT_COMPLETED/$AGENT_TOTAL completed successfully"

            # Check last completed pod for signs of empty/failed data export
            AGENT_LAST_POD=$(kubectl get pods -n onelens-agent --no-headers 2>/dev/null \
                | grep -E "$AGENT_POD_PATTERN" | grep 'Completed' | tail -1 | awk '{print $1}' || true)
            if [ -n "$AGENT_LAST_POD" ]; then
                AGENT_LAST_LOGS=$(kubectl logs "$AGENT_LAST_POD" -n onelens-agent --tail=5 2>/dev/null || true)
                if echo "$AGENT_LAST_LOGS" | grep -qiE 'failed|error|exception|0 processed' 2>/dev/null; then
                    echo "WARNING: Last completed agent pod may have issues:"
                    echo "$AGENT_LAST_LOGS"
                fi
            fi
        fi
    else
        echo "WARNING: No agent jobs found — CronJob may not be firing"
        # Check if CronJob has lastScheduleTime to distinguish "never fired" from "all cleaned up"
        if [ -z "$AGENT_LAST_SCHEDULE" ]; then
            echo "Agent CronJob has never been scheduled"
        else
            echo "Last scheduled: $AGENT_LAST_SCHEDULE — jobs may have been cleaned up by historyLimit"
        fi
    fi

    # Data staleness: check last successful agent pod completion
    AGENT_LAST_SUCCESS=$(kubectl get jobs -n onelens-agent --no-headers 2>/dev/null \
        | grep -E "$AGENT_POD_PATTERN" | grep 'Complete' | tail -1 | awk '{print $4}' || true)
    if [ -n "$AGENT_LAST_SUCCESS" ]; then
        echo "Last successful agent job: ${AGENT_LAST_SUCCESS} ago"
    else
        echo "WARNING: No completed agent jobs found — data pipeline may be down"
    fi

    # Trigger immediate agent run if data is stale and dependencies are healthy.
    # The agent CronJob runs hourly. If the last run failed, data is stale until
    # the next hourly trigger. Instead of waiting, create a one-off Job now.
    # Only trigger if:
    #   - Agent had failures (failed pods found) or no successful run recently
    #   - Prometheus and OpenCost are Running+Ready (agent needs both)
    #   - No agent Job is currently active (avoid duplicates)
    _should_trigger=false
    if [ -n "$AGENT_FAILED_PODS" ]; then
        _should_trigger=true
    elif [ -z "$AGENT_LAST_SUCCESS" ]; then
        _should_trigger=true
    fi

    if [ "$_should_trigger" = "true" ]; then
        # Check if Prometheus and OpenCost are healthy
        _prom_ok=$(kubectl get pods -n onelens-agent --no-headers 2>/dev/null \
            | awk '/prometheus-server/{split($2,a,"/"); if(a[1]==a[2] && $3=="Running") print "yes"; exit}' || true)
        _oc_ok=$(kubectl get pods -n onelens-agent --no-headers 2>/dev/null \
            | awk '/opencost/{split($2,a,"/"); if(a[1]==a[2] && $3=="Running") print "yes"; exit}' || true)

        # Check no active agent Job running (includes scheduled and manually triggered jobs)
        _agent_active=$(kubectl get jobs -n onelens-agent --no-headers 2>/dev/null \
            | grep -E "^${AGENT_CJ_NAME}-" | grep -v 'Complete\|Failed' | head -1 || true)

        if [ "$_prom_ok" = "yes" ] && [ "$_oc_ok" = "yes" ] && [ -z "$_agent_active" ]; then
            # Clean up completed/failed manual jobs (not managed by CronJob historyLimit)
            kubectl delete jobs -n onelens-agent -l created-by=patching-manual-trigger 2>/dev/null || true

            echo "Triggering immediate agent run (last run failed/stale, dependencies healthy)..."
            _trigger_job="onelens-agent-manual-$(date +%s)"
            if kubectl create job "$_trigger_job" --from=cronjob/"$AGENT_CJ_NAME" -n onelens-agent 2>/dev/null; then
                kubectl label job "$_trigger_job" -n onelens-agent created-by=patching-manual-trigger 2>/dev/null || true
                echo "Agent job '$_trigger_job' created"
            else
                echo "WARNING: Failed to create manual agent job"
            fi
        elif [ -n "$_agent_active" ]; then
            echo "Agent job already active — skipping manual trigger"
        else
            echo "Skipping agent trigger — dependencies not ready (prom=$_prom_ok opencost=$_oc_ok)"
        fi
    fi
else
    echo "WARNING: Agent CronJob '$AGENT_CJ_NAME' not found"
fi

# Report final state via API — deployer version for fleet tracking, healthcheck status.
# For clusters already on v2.1.55+, patching_mode is managed via DB and should not be
# overwritten (e.g., customer may set a custom mode like "2AMUTC" for tracking).
# For older clusters (first time running v2.1.55+ patching.sh), set patching_mode to
# "healthcheck" so entrypoint.sh uses the lightweight healthcheck-first path.
echo "Reporting patching result..."
FINAL_DEPLOYER_VERSION="${DEPLOYER_VERSION:-unknown}"
current_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
_deployed_minor=$(echo "$DEPLOYED_VERSION" | sed 's|^release/||; s/^v//; s/-.*//' | awk -F. '{print $3+0}' 2>/dev/null || echo "0")
if [ "$UPGRADE_FAILED" = "true" ]; then
    if [ "$_deployed_minor" -lt 55 ] 2>/dev/null || [ -z "$_deployed_minor" ]; then
        hc_payload=$(jq -n \
            --arg reg_id "$REGISTRATION_ID" \
            --arg token "$CLUSTER_TOKEN" \
            --arg dv "${FINAL_DEPLOYER_VERSION:-unknown}" \
            '{registration_id: $reg_id, cluster_token: $token, update_data: {patching_enabled: true, deployer_version: $dv, patching_mode: "healthcheck"}}')
    else
        hc_payload=$(jq -n \
            --arg reg_id "$REGISTRATION_ID" \
            --arg token "$CLUSTER_TOKEN" \
            --arg dv "${FINAL_DEPLOYER_VERSION:-unknown}" \
            '{registration_id: $reg_id, cluster_token: $token, update_data: {patching_enabled: true, deployer_version: $dv}}')
    fi
else
    if [ "$_deployed_minor" -lt 55 ] 2>/dev/null || [ -z "$_deployed_minor" ]; then
        hc_payload=$(jq -n \
            --arg reg_id "$REGISTRATION_ID" \
            --arg token "$CLUSTER_TOKEN" \
            --arg dv "${FINAL_DEPLOYER_VERSION:-unknown}" \
            --arg ts "$current_timestamp" \
            '{registration_id: $reg_id, cluster_token: $token, update_data: {patching_enabled: true, deployer_version: $dv, healthcheck_failures: 0, last_healthy_at: $ts, patching_mode: "healthcheck"}}')
    else
        hc_payload=$(jq -n \
            --arg reg_id "$REGISTRATION_ID" \
            --arg token "$CLUSTER_TOKEN" \
            --arg dv "${FINAL_DEPLOYER_VERSION:-unknown}" \
            --arg ts "$current_timestamp" \
            '{registration_id: $reg_id, cluster_token: $token, update_data: {patching_enabled: true, deployer_version: $dv, healthcheck_failures: 0, last_healthy_at: $ts}}')
    fi
fi
curl -s --max-time 10 --location --request PUT \
    "${API_BASE_URL:-https://api-in.onelens.cloud}/v1/kubernetes/cluster-version" \
    --header 'Content-Type: application/json' \
    --data "$hc_payload" >/dev/null 2>&1 && \
    echo "Patching result reported (deployer: ${FINAL_DEPLOYER_VERSION:-unknown})" || \
    echo "WARNING: Failed to report patching result (API call failed)"

echo ""
if [ "$UPGRADE_FAILED" = "true" ]; then
    echo "Patching incomplete (upgrade failed). Chart: $DEPLOYED_VERSION | Pods: $TOTAL_PODS | Tier: $TIER"
    echo "5-min schedule set. Next healthcheck will retry."
    exit 1
fi
echo "Patching complete. Chart: $DEPLOYED_VERSION | Pods: $TOTAL_PODS | Tier: $TIER"