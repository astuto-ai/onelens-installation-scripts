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
# Recovery: delete the broken PVC so helm upgrade recreates it using the existing
# StorageClass (onelens-sc), which preserves encryption and KMS settings from install.

echo "Checking Prometheus persistent volume health..."
PROM_PVC_NAME=$(kubectl get pvc -n onelens-agent -l "app.kubernetes.io/name=prometheus,app.kubernetes.io/component=server" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

# Fallback: try common PVC name patterns if label selector found nothing
if [ -z "$PROM_PVC_NAME" ]; then
    PROM_PVC_NAME=$(kubectl get pvc -n onelens-agent -o jsonpath='{.items[?(@.metadata.name=="onelens-agent-prometheus-server")].metadata.name}' 2>/dev/null || true)
fi
if [ -z "$PROM_PVC_NAME" ]; then
    PROM_PVC_NAME=$(kubectl get pvc -n onelens-agent --no-headers 2>/dev/null | awk '/prometheus-server/{print $1; exit}' || true)
fi

PV_RECOVERY_DONE=false
RECOVERED_PVC_SIZE=""
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

                # Verify StorageClass exists (helm upgrade will recreate if missing, but good to log)
                SC_EXISTS=$(kubectl get storageclass onelens-sc --no-headers 2>/dev/null || true)
                if [ -n "$SC_EXISTS" ]; then
                    echo "StorageClass 'onelens-sc' exists — new PVC will use same encryption/provisioner settings."
                else
                    echo "StorageClass 'onelens-sc' not found — helm upgrade will recreate it from release values."
                fi

                echo "Deleting broken PVC '$PROM_PVC_NAME' to allow volume recreation..."
                # Remove the helm resource-policy annotation so kubectl delete works
                kubectl annotate pvc "$PROM_PVC_NAME" -n onelens-agent helm.sh/resource-policy- 2>/dev/null || true
                kubectl delete pvc "$PROM_PVC_NAME" -n onelens-agent --wait=false 2>/dev/null || true

                # Wait briefly for PVC deletion to propagate
                sleep 5
                PVC_STILL_EXISTS=$(kubectl get pvc "$PROM_PVC_NAME" -n onelens-agent --no-headers 2>/dev/null || true)
                if [ -z "$PVC_STILL_EXISTS" ]; then
                    echo "PVC deleted successfully. Helm upgrade will create a new PVC and volume."
                    RECOVERED_PVC_SIZE="$OLD_PVC_SIZE"
                    PV_RECOVERY_DONE=true
                else
                    echo "WARNING: PVC still exists after delete attempt. It may have finalizers. Helm upgrade will proceed anyway."
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
                    echo "Deleting broken PV and PVC..."

                    SC_EXISTS=$(kubectl get storageclass onelens-sc --no-headers 2>/dev/null || true)
                    if [ -n "$SC_EXISTS" ]; then
                        echo "StorageClass 'onelens-sc' exists — new PVC will use same encryption/provisioner settings."
                    else
                        echo "StorageClass 'onelens-sc' not found — helm upgrade will recreate it from release values."
                    fi

                    kubectl annotate pvc "$PROM_PVC_NAME" -n onelens-agent helm.sh/resource-policy- 2>/dev/null || true
                    kubectl delete pvc "$PROM_PVC_NAME" -n onelens-agent --wait=false 2>/dev/null || true
                    kubectl delete pv "$BOUND_PV" --wait=false 2>/dev/null || true
                    sleep 5
                    echo "Broken PV and PVC deleted. Helm upgrade will create fresh volume."
                    RECOVERED_PVC_SIZE="$OLD_PVC_SIZE"
                    PV_RECOVERY_DONE=true
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

                    SC_EXISTS=$(kubectl get storageclass onelens-sc --no-headers 2>/dev/null || true)
                    if [ -n "$SC_EXISTS" ]; then
                        echo "StorageClass 'onelens-sc' exists — new PVC will use same encryption/provisioner settings."
                    else
                        echo "StorageClass 'onelens-sc' not found — helm upgrade will recreate it from release values."
                    fi

                    echo "Deleting broken PV and PVC..."
                    kubectl annotate pvc "$PROM_PVC_NAME" -n onelens-agent helm.sh/resource-policy- 2>/dev/null || true
                    kubectl delete pvc "$PROM_PVC_NAME" -n onelens-agent --wait=false 2>/dev/null || true
                    kubectl delete pv "$BOUND_PV" --wait=false 2>/dev/null || true
                    sleep 5
                    echo "Broken PV and PVC deleted. Helm upgrade will create fresh volume."
                    RECOVERED_PVC_SIZE="$OLD_PVC_SIZE"
                    PV_RECOVERY_DONE=true
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

helm repo add onelens https://astuto-ai.github.io/onelens-installation-scripts >/dev/null 2>&1
helm repo update >/dev/null 2>&1

# Build PV recovery override if volume was recreated
# This ensures the new PVC gets the actual size from the cluster, not just the helm release value,
# in case the customer resized the volume outside of helm.
PV_SIZE_OVERRIDE=""
if [ "$PV_RECOVERY_DONE" = "true" ] && [ -n "$RECOVERED_PVC_SIZE" ]; then
    echo "Overriding PVC size to match previous volume: $RECOVERED_PVC_SIZE"
    PV_SIZE_OVERRIDE="--set-string prometheus.server.persistentVolume.size=$RECOVERED_PVC_SIZE"
fi

# Perform the upgrade with dynamically calculated resource values
# shellcheck disable=SC2086
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
  $PV_SIZE_OVERRIDE

if [ $? -ne 0 ]; then
    echo "Upgrade failed and was automatically rolled back by --atomic flag"
    echo "--- Pod Status After Rollback ---"
    kubectl get pods -n onelens-agent -o wide --no-headers 2>/dev/null || true
    echo "--- Events After Rollback ---"
    kubectl get events -n onelens-agent --sort-by='.lastTimestamp' --no-headers 2>/dev/null | tail -10 || true
    exit 1
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

echo ""
echo "========== POST-PATCH STATE =========="

if [ "$PV_RECOVERY_DONE" = "true" ]; then
    echo "--- PV Recovery ---"
    echo "Prometheus volume was recreated. Historical TSDB data was lost."
    NEW_PVC_NAME=$(kubectl get pvc -n onelens-agent --no-headers 2>/dev/null | awk '/prometheus-server/{print $1; exit}' || true)
    if [ -n "$NEW_PVC_NAME" ]; then
        NEW_PVC_SIZE=$(kubectl get pvc "$NEW_PVC_NAME" -n onelens-agent -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null || true)
        NEW_PVC_SC=$(kubectl get pvc "$NEW_PVC_NAME" -n onelens-agent -o jsonpath='{.spec.storageClassName}' 2>/dev/null || true)
        NEW_PVC_STATUS=$(kubectl get pvc "$NEW_PVC_NAME" -n onelens-agent -o jsonpath='{.status.phase}' 2>/dev/null || true)
        echo "New PVC: name=$NEW_PVC_NAME size=$NEW_PVC_SIZE storageClass=$NEW_PVC_SC status=$NEW_PVC_STATUS"
    else
        echo "WARNING: No new Prometheus PVC found after recovery."
    fi
fi

echo "--- Applied Resource Configuration ---"
echo "Tier: $TIER | Pods: $TOTAL_PODS | Label multiplier: ${LABEL_MULTIPLIER}x"
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
echo "Image tag: $CURRENT_IMAGE_TAG"

echo "--- Pod Status After Upgrade ---"
kubectl get pods -n onelens-agent -o wide --no-headers 2>/dev/null || echo "(kubectl get pods failed)"

echo "--- Helm Release After Upgrade ---"
helm list -n onelens-agent --no-headers 2>/dev/null || true

echo "========== END POST-PATCH STATE =========="
echo ""
echo "Patching complete. Chart: $CURRENT_CHART_VERSION | Pods: $TOTAL_PODS | Tier: $TIER"