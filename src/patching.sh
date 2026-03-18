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

# Ensure deployer CronJob has enough CPU for large clusters (kubectl + jq + helm on 1000+ pods)
# Only patch UP — never downgrade a customer who set a higher value explicitly.
# Note: _cpu_to_millicores is not available yet (library embedded below), so parse manually.
MIN_CPU_MILLICORES=200
CURRENT_CPU=$(kubectl get cronjob onelensupdater -n onelens-agent -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null || true)
if [ -n "$CURRENT_CPU" ]; then
    # Convert to millicores: "50m" → 50, "0.2" → 200
    if echo "$CURRENT_CPU" | grep -q 'm$'; then
        CURRENT_CPU_MILLICORES=$(echo "$CURRENT_CPU" | sed 's/m$//')
    else
        CURRENT_CPU_MILLICORES=$(echo "$CURRENT_CPU" | awk '{printf "%.0f", $1 * 1000}')
    fi
    if [ "$CURRENT_CPU_MILLICORES" -lt "$MIN_CPU_MILLICORES" ] 2>/dev/null; then
        echo "Updating CronJob CPU from ${CURRENT_CPU} to ${MIN_CPU_MILLICORES}m..."
        kubectl patch cronjob onelensupdater -n onelens-agent --type='json' -p='[
          {"op": "replace", "path": "/spec/jobTemplate/spec/template/spec/containers/0/resources/requests/cpu", "value": "'"${MIN_CPU_MILLICORES}m"'"},
          {"op": "replace", "path": "/spec/jobTemplate/spec/template/spec/containers/0/resources/limits/cpu", "value": "'"${MIN_CPU_MILLICORES}m"'"}
        ]' 2>/dev/null && \
            echo "CronJob CPU patched successfully" || \
            echo "WARNING: Failed to patch CronJob CPU"
    else
        echo "CronJob CPU already sufficient (${CURRENT_CPU})"
    fi
fi

# Ensure deployer CronJob has backoffLimit=0 (no internal retries).
# The 5-min CronJob schedule is the retry mechanism. Internal retries just burn time
# in exponential backoff (10s, 20s, 40s...) while concurrencyPolicy: Forbid blocks new runs.
# Old deployer charts (<=2.1.21) didn't set this, so Kubernetes defaults to 6.
CURRENT_BACKOFF=$(kubectl get cronjob onelensupdater -n onelens-agent \
    -o jsonpath='{.spec.jobTemplate.spec.backoffLimit}' 2>/dev/null || true)
# Empty means Kubernetes default (6). Only skip if explicitly set to 0.
if [ "$CURRENT_BACKOFF" != "0" ]; then
    echo "Updating CronJob backoffLimit from ${CURRENT_BACKOFF:-6 (default)} to 0..."
    # Use strategic merge patch — works whether field exists or not (replace op fails on missing path)
    kubectl patch cronjob onelensupdater -n onelens-agent --type='merge' -p='
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
DEPLOYER_CHART_RAW=$(helm list -n onelens-agent -o json 2>/dev/null \
    | jq -r '.[] | select(.name=="onelensdeployer") | .chart' 2>/dev/null || true)
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

# --- Pod count: use desired/max replicas from workload controllers ---
echo "Calculating cluster pod capacity from workload controllers..."

# Collect cluster data (kubectl calls stay here; logic is in the library)
HPA_JSON=$(kubectl get hpa --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')
DEPLOY_JSON=$(kubectl get deployments --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')
STS_JSON=$(kubectl get statefulsets --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')
DS_JSON=$(kubectl get daemonsets --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')
NUM_NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')

# Calculate pod counts using library functions
DEPLOY_PODS=$(count_deploy_pods "$DEPLOY_JSON" "$HPA_JSON")
STS_PODS=$(count_sts_pods "$STS_JSON" "$HPA_JSON")
DS_PODS=$(count_ds_pods "$DS_JSON")
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

    # Kubectl fallback for OOM detection
    OOM_KUBECTL=""
    if [ -z "$OOM_PROM" ]; then
        OOM_KUBECTL=$(kubectl get pods -n onelens-agent -o json 2>/dev/null \
            | jq -r '.items[].status.containerStatuses[]? | select(.lastState.terminated.reason == "OOMKilled") | .name' 2>/dev/null || true)
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
            --from-literal=opencost.last_oom_at="" 2>/dev/null || true
        echo "Created sizing state ConfigMap (first run, downsize deferred 72h)"
        STATE_LAST_FULL_EVAL="$NOW_TS"
        STATE_LAST_OOM_prometheus_server=""
        STATE_LAST_OOM_kube_state_metrics=""
        STATE_LAST_OOM_opencost=""
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

            # OOM detection (skip on first run — historical events predate our tracking)
            oom_now=false
            if [ "$IS_FIRST_RUN" = "false" ] && _has_oom "$container"; then
                oom_now=true
                eval "$oom_state_var=\"\$(date -u +\"%Y-%m-%dT%H:%M:%SZ\")\""
                echo "  $label: OOM detected — doubling memory from $cur_mem"
            elif [ "$IS_FIRST_RUN" = "true" ] && _has_oom "$container"; then
                echo "  $label: historical OOM found, skipping (first run)"
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
        if [ "$IS_FIRST_RUN" = "false" ] && _has_oom "prometheus-pushgateway"; then
            PGW_OOM_NOW=true
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
        PATCH_JSON=$(build_sizing_state_patch "$NEW_EVAL_TS" "$NEW_PROM_OOM" "$NEW_KSM_OOM" "$NEW_OC_OOM")
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

# ═══════════════════════════════════════════════════════════════════════════
# Helm upgrade with WAL OOM retry loop
# ═══════════════════════════════════════════════════════════════════════════
# If Prometheus OOMs during WAL replay after upgrade, bump memory and retry
# immediately instead of waiting for the next 5-min CronJob cycle.

# _detect_prom_startup_failure — check if Prometheus is repeatedly failing to start.
# Returns 0 (true) if Prometheus is crash-looping/erroring and memory bump may help.
# Sets _PROM_FAIL_DIAG with details and _PROM_FAIL_REASON with category:
#   "oom"     — OOMKilled or memory allocation failure, bump will likely help
#   "other"   — config error, image issue, etc. bump won't help
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

    # Pod must be failing: restartCount >= 2 or not Running
    if [ "$restart_count" -lt 2 ] 2>/dev/null && [ "$pod_status" = "Running" ]; then
        return 1
    fi

    # Gather evidence from logs and events
    prom_logs=$(kubectl logs "$prom_pod" -n onelens-agent -c prometheus-server --previous --tail=50 2>/dev/null || true)
    local events
    events=$(kubectl get events -n onelens-agent --field-selector "involvedObject.name=$prom_pod" --no-headers 2>/dev/null | tail -10 || true)

    # Check for FailedScheduling — bumping memory won't help if nodes can't fit the request
    if echo "$events" | grep -qiE 'FailedScheduling.*Insufficient memory'; then
        _PROM_FAIL_REASON="other"
        _PROM_FAIL_DIAG="pod=$prom_pod status=$pod_status reason=FailedScheduling_insufficient_memory (requested=$PROMETHEUS_MEMORY_LIMIT, node can't fit)"
        return 0
    fi

    # Classify the failure
    if [ "$term_reason" = "OOMKilled" ]; then
        _PROM_FAIL_REASON="oom"
        _PROM_FAIL_DIAG="pod=$prom_pod status=$pod_status restarts=$restart_count reason=OOMKilled"
    elif echo "$prom_logs" | grep -qiE 'out of memory|cannot allocate|mmap.*enomem'; then
        _PROM_FAIL_REASON="oom"
        _PROM_FAIL_DIAG="pod=$prom_pod status=$pod_status restarts=$restart_count reason=memory_allocation_failure"
    elif echo "$prom_logs" | grep -qiE 'wal|replay|checkpoint' && [ "$restart_count" -ge 2 ] 2>/dev/null; then
        # Crash during WAL replay without explicit OOM — likely memory-related
        _PROM_FAIL_REASON="oom"
        _PROM_FAIL_DIAG="pod=$prom_pod status=$pod_status restarts=$restart_count reason=crash_during_wal_replay"
    else
        # Not memory-related: config error, image pull, permission issue, etc.
        _PROM_FAIL_REASON="other"
        local snippet
        snippet=$(echo "$prom_logs" | tail -5 | tr '\n' ' ' | cut -c1-200)
        _PROM_FAIL_DIAG="pod=$prom_pod status=$pod_status restarts=$restart_count reason=$term_reason logs=$snippet"
    fi

    # Append WAL evidence if present
    if echo "$prom_logs" | grep -qiE 'wal|replay|checkpoint'; then
        _PROM_FAIL_DIAG="$_PROM_FAIL_DIAG [WAL replay in logs]"
    fi

    return 0
}

WAL_OOM_APPLIED=false
UPGRADE_FAILED=false
_PROM_RETRIES=0
_MAX_PROM_RETRIES=3

echo "Running helm upgrade (latest chart, fresh values + customer overrides)..."
eval "$HELM_CMD"
UPGRADE_EXIT=$?

# Retry loop: if Prometheus is crash-looping due to OOM/WAL, bump memory and retry immediately
while true; do
    if [ $UPGRADE_EXIT -eq 0 ]; then
        # Upgrade succeeded, but Prometheus might still be crash-looping.
        # Wait for pods to attempt startup before checking.
        sleep 15
        if ! _detect_prom_startup_failure; then
            UPGRADE_FAILED=false
            break
        fi
        echo "Helm upgrade succeeded but Prometheus is failing: $_PROM_FAIL_DIAG"
    else
        echo "Helm upgrade failed (exit $UPGRADE_EXIT)."
        if ! _detect_prom_startup_failure; then
            echo "Prometheus pod not found or not failing. Other issue:"
            kubectl get pods -n onelens-agent --no-headers 2>/dev/null || true
            kubectl get events -n onelens-agent --sort-by='.lastTimestamp' --no-headers 2>/dev/null | tail -5 || true
            UPGRADE_FAILED=true
            break
        fi
        echo "Prometheus startup failure detected: $_PROM_FAIL_DIAG"
    fi

    # Only retry for memory-related failures. Config errors, image pull, etc. won't be fixed by bumping memory.
    if [ "$_PROM_FAIL_REASON" != "oom" ]; then
        echo "Prometheus failure is not memory-related (reason=$_PROM_FAIL_REASON). Not retrying."
        _fail_pod=$(kubectl get pods -n onelens-agent --no-headers 2>/dev/null \
            | awk '/prometheus-server/{print $1; exit}' || true)
        if [ -n "$_fail_pod" ]; then
            echo "--- Prometheus logs (last 20 lines) ---"
            kubectl logs "$_fail_pod" -n onelens-agent -c prometheus-server --previous --tail=20 2>/dev/null || true
            echo "--- Events ---"
            kubectl get events -n onelens-agent --field-selector "involvedObject.name=$_fail_pod" --no-headers 2>/dev/null | tail -5 || true
        fi
        UPGRADE_FAILED=true
        break
    fi

    # Check retry limit
    if [ "$_PROM_RETRIES" -ge "$_MAX_PROM_RETRIES" ]; then
        echo "Prometheus OOM: exhausted $_MAX_PROM_RETRIES retries at $PROMETHEUS_MEMORY_LIMIT."
        _CAP_MI=$(_memory_to_mi "${_USAGE_CAP_PROM_MEM}Mi")
        _CUR_MI=$(_memory_to_mi "$PROMETHEUS_MEMORY_LIMIT")
        if [ "$_CUR_MI" -ge "$_CAP_MI" ] 2>/dev/null; then
            echo "At memory cap (${_USAGE_CAP_PROM_MEM}Mi). Manual action: kubectl delete pvc onelens-agent-prometheus-server -n onelens-agent"
        fi
        echo "--- Final pod status ---"
        kubectl get pods -n onelens-agent --no-headers 2>/dev/null | grep prometheus-server || true
        _fail_pod=$(kubectl get pods -n onelens-agent --no-headers 2>/dev/null \
            | awk '/prometheus-server/{print $1; exit}' || true)
        if [ -n "$_fail_pod" ]; then
            echo "--- Prometheus logs (last 20 lines) ---"
            kubectl logs "$_fail_pod" -n onelens-agent -c prometheus-server --previous --tail=20 2>/dev/null || true
        fi
        UPGRADE_FAILED=true
        break
    fi

    # Bump Prometheus memory 1.5x and retry
    _OLD_MEM="$PROMETHEUS_MEMORY_LIMIT"
    PROMETHEUS_MEMORY_LIMIT=$(calculate_wal_oom_memory "$PROMETHEUS_MEMORY_LIMIT" "$_USAGE_CAP_PROM_MEM")
    PROMETHEUS_MEMORY_REQUEST="$PROMETHEUS_MEMORY_LIMIT"
    _PROM_RETRIES=$((_PROM_RETRIES + 1))

    if [ "$PROMETHEUS_MEMORY_LIMIT" = "$_OLD_MEM" ]; then
        echo "Prometheus OOM: at memory cap ($PROMETHEUS_MEMORY_LIMIT). Manual action: kubectl delete pvc onelens-agent-prometheus-server -n onelens-agent"
        UPGRADE_FAILED=true
        break
    fi

    echo "Prometheus OOM recovery (retry $_PROM_RETRIES/$_MAX_PROM_RETRIES): bumping memory $_OLD_MEM -> $PROMETHEUS_MEMORY_LIMIT"
    WAL_OOM_APPLIED=true

    # Re-run helm upgrade with bumped memory (last --set wins, overrides earlier values)
    # Use shorter timeout for retries — only Prometheus is restarting, not full rollout
    WAL_RETRY_CMD="$HELM_CMD \
      --timeout=3m \
      --set prometheus.server.resources.requests.memory=\"$PROMETHEUS_MEMORY_REQUEST\" \
      --set prometheus.server.resources.limits.memory=\"$PROMETHEUS_MEMORY_LIMIT\""
    eval "$WAL_RETRY_CMD"
    UPGRADE_EXIT=$?
done

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
AGENT_CJ_EXISTS=$(kubectl get cronjob "$AGENT_CJ_NAME" -n onelens-agent --no-headers 2>/dev/null || true)

if [ -n "$AGENT_CJ_EXISTS" ]; then
    # CronJob state
    AGENT_SUSPENDED=$(kubectl get cronjob "$AGENT_CJ_NAME" -n onelens-agent -o jsonpath='{.spec.suspend}' 2>/dev/null || echo "unknown")
    AGENT_LAST_SCHEDULE=$(kubectl get cronjob "$AGENT_CJ_NAME" -n onelens-agent -o jsonpath='{.status.lastScheduleTime}' 2>/dev/null || true)
    AGENT_BACKOFF=$(kubectl get cronjob "$AGENT_CJ_NAME" -n onelens-agent -o jsonpath='{.spec.jobTemplate.spec.backoffLimit}' 2>/dev/null || true)

    echo "CronJob: schedule=$(kubectl get cronjob "$AGENT_CJ_NAME" -n onelens-agent -o jsonpath='{.spec.schedule}' 2>/dev/null) suspend=$AGENT_SUSPENDED lastSchedule=$AGENT_LAST_SCHEDULE backoffLimit=${AGENT_BACKOFF:-default}"

    # Fix: unsuspend if suspended
    if [ "$AGENT_SUSPENDED" = "true" ]; then
        echo "WARNING: Agent CronJob is suspended. Unsuspending..."
        kubectl patch cronjob "$AGENT_CJ_NAME" -n onelens-agent --type='merge' -p='{"spec":{"suspend":false}}' 2>/dev/null && \
            echo "Agent CronJob unsuspended" || echo "WARNING: Failed to unsuspend agent CronJob"
    fi

    # Fix: patch backoffLimit to 0 (same rationale as deployer)
    if [ "$AGENT_BACKOFF" != "0" ]; then
        echo "Patching agent CronJob backoffLimit from ${AGENT_BACKOFF:-default} to 0..."
        kubectl patch cronjob "$AGENT_CJ_NAME" -n onelens-agent --type='merge' -p='{"spec":{"jobTemplate":{"spec":{"backoffLimit":0}}}}' 2>/dev/null && \
            echo "Agent CronJob backoffLimit patched" || echo "WARNING: Failed to patch agent backoffLimit"
    fi

    # Check recent agent Job pods (last 3 jobs)
    AGENT_JOBS=$(kubectl get jobs -n onelens-agent --no-headers 2>/dev/null \
        | grep "^${AGENT_CJ_NAME}-" | grep -v "^onelensupdater" | tail -3 || true)
    if [ -n "$AGENT_JOBS" ]; then
        echo "Recent agent jobs:"
        echo "$AGENT_JOBS" | awk '{printf "  %s %s\n", $1, $2}'

        # Find failed agent pods
        AGENT_FAILED_PODS=$(kubectl get pods -n onelens-agent --no-headers 2>/dev/null \
            | grep "^${AGENT_CJ_NAME}-" | grep -v "^onelensupdater" | grep -E 'Error|OOMKilled|CrashLoopBackOff' | tail -3 || true)

        if [ -n "$AGENT_FAILED_PODS" ]; then
            echo "Failed agent pods:"
            echo "$AGENT_FAILED_PODS" | awk '{printf "  %s %s restarts=%s\n", $1, $3, $4}'

            # Diagnose the most recent failed pod
            AGENT_FAIL_POD=$(echo "$AGENT_FAILED_PODS" | tail -1 | awk '{print $1}')
            if [ -n "$AGENT_FAIL_POD" ]; then
                # Get termination reason and exit code
                AGENT_TERM_REASON=$(kubectl get pod "$AGENT_FAIL_POD" -n onelens-agent \
                    -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}{.status.containerStatuses[0].lastState.terminated.reason}' 2>/dev/null || true)
                AGENT_EXIT_CODE=$(kubectl get pod "$AGENT_FAIL_POD" -n onelens-agent \
                    -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}{.status.containerStatuses[0].lastState.terminated.exitCode}' 2>/dev/null || true)
                AGENT_MEM_LIMIT=$(kubectl get pod "$AGENT_FAIL_POD" -n onelens-agent \
                    -o jsonpath='{.spec.containers[0].resources.limits.memory}' 2>/dev/null || true)

                echo "Diagnosis: pod=$AGENT_FAIL_POD reason=$AGENT_TERM_REASON exitCode=$AGENT_EXIT_CODE memLimit=$AGENT_MEM_LIMIT"

                # Get last log lines from the failed pod
                AGENT_FAIL_LOGS=$(kubectl logs "$AGENT_FAIL_POD" -n onelens-agent --tail=15 2>/dev/null || \
                    kubectl logs "$AGENT_FAIL_POD" -n onelens-agent --previous --tail=15 2>/dev/null || true)
                if [ -n "$AGENT_FAIL_LOGS" ]; then
                    echo "--- Agent pod logs (last 15 lines) ---"
                    echo "$AGENT_FAIL_LOGS"
                    echo "--- end ---"
                fi

                # Fix: if OOMKilled, bump agent CronJob memory 1.25x via kubectl patch (takes effect on next agent run)
                if [ "$AGENT_TERM_REASON" = "OOMKilled" ] || echo "$AGENT_FAIL_LOGS" | grep -qiE 'out of memory|cannot allocate|MemoryError|killed' 2>/dev/null; then
                    AGENT_NEW_MEM=$(apply_memory_multiplier "${AGENT_MEM_LIMIT:-384Mi}" 1.25)
                    echo "Agent OOMKilled — patching CronJob memory ${AGENT_MEM_LIMIT:-384Mi} -> $AGENT_NEW_MEM"
                    kubectl patch cronjob "$AGENT_CJ_NAME" -n onelens-agent --type='merge' -p="{
                      \"spec\":{\"jobTemplate\":{\"spec\":{\"template\":{\"spec\":{\"containers\":[{
                        \"name\":\"$AGENT_CJ_NAME\",
                        \"resources\":{\"requests\":{\"memory\":\"$AGENT_NEW_MEM\"},\"limits\":{\"memory\":\"$AGENT_NEW_MEM\"}}
                      }]}}}}}
                    }" 2>/dev/null && \
                        echo "Agent CronJob memory patched to $AGENT_NEW_MEM" || \
                        echo "WARNING: Failed to patch agent CronJob memory"
                fi
            fi
        else
            # Check if recent jobs all completed successfully
            AGENT_COMPLETED=$(echo "$AGENT_JOBS" | grep -c 'Complete' || true)
            AGENT_TOTAL=$(echo "$AGENT_JOBS" | wc -l | tr -d '[:space:]')
            echo "Agent jobs: $AGENT_COMPLETED/$AGENT_TOTAL completed successfully"
        fi
    else
        echo "WARNING: No agent jobs found — CronJob may not be firing"
    fi

    # Data staleness: check last successful agent pod completion
    AGENT_LAST_SUCCESS=$(kubectl get jobs -n onelens-agent --no-headers 2>/dev/null \
        | grep "^${AGENT_CJ_NAME}-" | grep -v "^onelensupdater" | grep 'Complete' | tail -1 | awk '{print $4}' || true)
    if [ -n "$AGENT_LAST_SUCCESS" ]; then
        echo "Last successful agent job: ${AGENT_LAST_SUCCESS} ago"
    fi
else
    echo "WARNING: Agent CronJob '$AGENT_CJ_NAME' not found"
fi

# Activate healthcheck mode via API — tells backend this cluster is ready for
# self-healing. Also reports deployer_version so we can track fleet state.
echo "Activating healthcheck mode..."
FINAL_DEPLOYER_VERSION="${DEPLOYER_VERSION:-unknown}"
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
    echo "5-min schedule set. Next healthcheck will retry."
    exit 1
fi
echo "Patching complete. Chart: $DEPLOYED_VERSION | Pods: $TOTAL_PODS | Tier: $TIER"