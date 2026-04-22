#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
source "$(lib_dir)/resource-sizing.sh"
set_test_file "test-helm-render.sh"
ROOT=$(repo_root)

###############################################################################
# Prerequisites
###############################################################################

if ! command -v helm &>/dev/null; then
    echo "SKIP: helm not found, skipping helm render tests"
    exit 0
fi

# Add repo if not already present
helm repo add onelens https://astuto-ai.github.io/onelens-installation-scripts 2>/dev/null || true
helm repo update onelens 2>/dev/null || true

# Check if chart is accessible
if ! helm show chart onelens/onelens-agent --version 2.1.3 &>/dev/null; then
    echo "SKIP: onelens-agent chart not accessible, skipping helm render tests"
    exit 0
fi

CHART_VERSION="2.1.3"

# Detect yq for YAML parsing
HAS_YQ=false
if command -v yq &>/dev/null; then
    HAS_YQ=true
fi

###############################################################################
# Helper: render helm template with resource/retention overrides
###############################################################################
render_with_resources() {
    helm template test-release onelens/onelens-agent \
        --version "$CHART_VERSION" \
        --set prometheus.server.persistentVolume.enabled=true \
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
        --set prometheus.kube-state-metrics.resources.requests.cpu="$KSM_CPU_REQUEST" \
        --set prometheus.kube-state-metrics.resources.requests.memory="$KSM_MEMORY_REQUEST" \
        --set prometheus.kube-state-metrics.resources.limits.cpu="$KSM_CPU_LIMIT" \
        --set prometheus.kube-state-metrics.resources.limits.memory="$KSM_MEMORY_LIMIT" \
        --set prometheus.prometheus-pushgateway.resources.requests.cpu="$PROMETHEUS_PUSHGATEWAY_CPU_REQUEST" \
        --set prometheus.prometheus-pushgateway.resources.requests.memory="$PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST" \
        --set prometheus.prometheus-pushgateway.resources.limits.cpu="$PROMETHEUS_PUSHGATEWAY_CPU_LIMIT" \
        --set prometheus.prometheus-pushgateway.resources.limits.memory="$PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT" \
        --set prometheus.configmapReload.prometheus.resources.requests.cpu="10m" \
        --set prometheus.configmapReload.prometheus.resources.requests.memory="32Mi" \
        --set prometheus.configmapReload.prometheus.resources.limits.cpu="10m" \
        --set prometheus.configmapReload.prometheus.resources.limits.memory="32Mi" \
        --set-string prometheus.server.retention="$PROMETHEUS_RETENTION" \
        --set-string prometheus.server.retentionSize="$PROMETHEUS_RETENTION_SIZE" \
        --set-string prometheus.server.persistentVolume.size="$PROMETHEUS_VOLUME_SIZE" \
        2>/dev/null
}

###############################################################################
# Helper: extract a value from rendered YAML for a specific container
# Usage: extract_resource "$rendered" "$container_name" "$resource_path"
# resource_path examples: "requests:" "cpu:" (searched after requests:/limits:)
###############################################################################
extract_container_resource() {
    local rendered="$1"
    local container_name="$2"
    local section="$3"   # "requests" or "limits"
    local field="$4"     # "cpu" or "memory"

    # grep-based extraction: find container by exact name match within containers section.
    # Use word boundary to avoid matching "prometheus-server-configmap-reload" when looking for "prometheus-server"
    local result
    result=$(echo "$rendered" \
        | grep -A 40 "name: ${container_name}$" \
        | grep -A 10 "${section}:" \
        | grep "${field}:" \
        | head -1 \
        | awk '{print $2}' \
        | tr -d '"' 2>/dev/null) || true
    # If exact match fails, try partial match
    if [ -z "$result" ]; then
        result=$(echo "$rendered" \
            | grep -A 40 "name:.*${container_name}" \
            | grep -A 10 "${section}:" \
            | grep "${field}:" \
            | head -1 \
            | awk '{print $2}' \
            | tr -d '"' 2>/dev/null) || true
    fi
    echo "$result"
}

###############################################################################
# Test 1: Render with tiny tier values and verify resources
###############################################################################
echo ""
echo "--- Test 1: Tiny tier resource values in rendered YAML ---"

select_resource_tier 25
select_retention_tier 25

RENDERED=$(render_with_resources)

if [ -z "$RENDERED" ]; then
    echo "  FAIL: helm template returned empty output"
    _TESTS_FAILED=$((_TESTS_FAILED + 1))
    _TESTS_TOTAL=$((_TESTS_TOTAL + 1))
else
    # Save to temp file for reuse
    TMPFILE=$(mktemp)
    echo "$RENDERED" > "$TMPFILE"
    trap 'rm -f "$TMPFILE"' EXIT

    # Prometheus server cpu request
    prom_cpu_req=$(extract_container_resource "$RENDERED" "prometheus-server" "requests" "cpu")
    assert_eq "$prom_cpu_req" "$PROMETHEUS_CPU_REQUEST" "tiny: prometheus server cpu request in rendered YAML"

    # Prometheus server memory request
    prom_mem_req=$(extract_container_resource "$RENDERED" "prometheus-server" "requests" "memory")
    assert_eq "$prom_mem_req" "$PROMETHEUS_MEMORY_REQUEST" "tiny: prometheus server memory request in rendered YAML"

    # Prometheus server cpu limit
    prom_cpu_lim=$(extract_container_resource "$RENDERED" "prometheus-server" "limits" "cpu")
    assert_eq "$prom_cpu_lim" "$PROMETHEUS_CPU_LIMIT" "tiny: prometheus server cpu limit in rendered YAML"

    # Prometheus server memory limit
    prom_mem_lim=$(extract_container_resource "$RENDERED" "prometheus-server" "limits" "memory")
    assert_eq "$prom_mem_lim" "$PROMETHEUS_MEMORY_LIMIT" "tiny: prometheus server memory limit in rendered YAML"

    # OpenCost resources (container name includes release prefix: test-release-prometheus-opencost-exporter)
    oc_cpu_req=$(extract_container_resource "$RENDERED" "opencost-exporter" "requests" "cpu")
    assert_eq "$oc_cpu_req" "$OPENCOST_CPU_REQUEST" "tiny: opencost cpu request in rendered YAML"

    oc_mem_lim=$(extract_container_resource "$RENDERED" "opencost-exporter" "limits" "memory")
    assert_eq "$oc_mem_lim" "$OPENCOST_MEMORY_LIMIT" "tiny: opencost memory limit in rendered YAML"

    # KSM resources
    ksm_cpu_req=$(extract_container_resource "$RENDERED" "kube-state-metrics" "requests" "cpu")
    assert_eq "$ksm_cpu_req" "$KSM_CPU_REQUEST" "tiny: kube-state-metrics cpu request in rendered YAML"

    ksm_mem_lim=$(extract_container_resource "$RENDERED" "kube-state-metrics" "limits" "memory")
    assert_eq "$ksm_mem_lim" "$KSM_MEMORY_LIMIT" "tiny: kube-state-metrics memory limit in rendered YAML"

    rm -f "$TMPFILE"
    trap - EXIT
fi

###############################################################################
# Test 2: Every container has both requests AND limits
###############################################################################
echo ""
echo "--- Test 2: All containers have both requests and limits ---"

if [ -n "$RENDERED" ]; then
    # Verify the key containers have both limits and requests set (non-empty).
    for cname in "prometheus-server" "opencost-exporter" "kube-state-metrics" "pushgateway" "onelens-agent"; do
        lim_val=$(extract_container_resource "$RENDERED" "$cname" "limits" "cpu")
        req_val=$(extract_container_resource "$RENDERED" "$cname" "requests" "cpu")
        assert_ne "$lim_val" "" "container '$cname' has non-empty cpu limits"
        assert_ne "$req_val" "" "container '$cname' has non-empty cpu requests"
    done
fi

###############################################################################
# Test 3: PVC size matches tier
###############################################################################
echo ""
echo "--- Test 3: PVC size matches tiny tier ---"

if [ -n "$RENDERED" ]; then
    # The PVC has: resources: requests: storage: "8Gi"
    pvc_size=$(echo "$RENDERED" | grep -A 20 'PersistentVolumeClaim' | grep -A 3 'requests:' | grep 'storage:' | head -1 | awk '{print $2}' | tr -d '"' || true)
    assert_eq "$pvc_size" "$PROMETHEUS_VOLUME_SIZE" "tiny: PVC storage size matches tier ($PROMETHEUS_VOLUME_SIZE)"
fi

###############################################################################
# Test 4: Retention matches tier
###############################################################################
echo ""
echo "--- Test 4: Prometheus retention matches tiny tier ---"

if [ -n "$RENDERED" ]; then
    # Retention appears in prometheus server args as --storage.tsdb.retention.time=
    # Verify retention appears in prometheus server args, not just anywhere in the output
    prom_args=$(echo "$RENDERED" | grep 'storage.tsdb.retention' || true)
    assert_contains "$prom_args" "retention.time=$PROMETHEUS_RETENTION" "tiny: retention duration in prometheus args"
    assert_contains "$prom_args" "retention.size=$PROMETHEUS_RETENTION_SIZE" "tiny: retention size in prometheus args"
fi

###############################################################################
# Test 5: Configmap-reload sidecar has resources
###############################################################################
echo ""
echo "--- Test 5: Configmap-reload sidecar has resources ---"

if [ -n "$RENDERED" ]; then
    cmr_section=$(echo "$RENDERED" | grep -A 30 'name: prometheus-server-configmap-reload' || true)
    if [ -z "$cmr_section" ]; then
        # Some chart versions use a different container name
        cmr_section=$(echo "$RENDERED" | grep -A 30 'name: configmap-reload' || true)
    fi
    if [ -n "$cmr_section" ]; then
        assert_contains "$cmr_section" "requests:" "configmap-reload sidecar has requests"
        assert_contains "$cmr_section" "limits:" "configmap-reload sidecar has limits"
    else
        echo "  SKIP: configmap-reload container not found in rendered output"
    fi
fi

###############################################################################
# Test 6: Large tier (800 pods) — verify resource scaling
###############################################################################
echo ""
echo "--- Test 6: Large tier resource values in rendered YAML ---"

select_resource_tier 800
select_retention_tier 800

RENDERED_LARGE=$(render_with_resources)

if [ -z "$RENDERED_LARGE" ]; then
    echo "  FAIL: helm template returned empty output for large tier"
    _TESTS_FAILED=$((_TESTS_FAILED + 1))
    _TESTS_TOTAL=$((_TESTS_TOTAL + 1))
else
    # Prometheus server cpu request — large tier
    prom_cpu_req_large=$(extract_container_resource "$RENDERED_LARGE" "prometheus-server" "requests" "cpu")
    assert_eq "$prom_cpu_req_large" "$PROMETHEUS_CPU_REQUEST" "large: prometheus server cpu request in rendered YAML"

    # Prometheus server memory limit — large tier
    prom_mem_lim_large=$(extract_container_resource "$RENDERED_LARGE" "prometheus-server" "limits" "memory")
    assert_eq "$prom_mem_lim_large" "$PROMETHEUS_MEMORY_LIMIT" "large: prometheus server memory limit in rendered YAML"

    # OpenCost cpu request — large tier
    oc_cpu_req_large=$(extract_container_resource "$RENDERED_LARGE" "opencost-exporter" "requests" "cpu")
    assert_eq "$oc_cpu_req_large" "$OPENCOST_CPU_REQUEST" "large: opencost cpu request in rendered YAML"

    # KSM memory limit — large tier
    ksm_mem_lim_large=$(extract_container_resource "$RENDERED_LARGE" "kube-state-metrics" "limits" "memory")
    assert_eq "$ksm_mem_lim_large" "$KSM_MEMORY_LIMIT" "large: kube-state-metrics memory limit in rendered YAML"

    # PVC size — large tier
    pvc_size_large=$(echo "$RENDERED_LARGE" | grep -A 20 'PersistentVolumeClaim' | grep -A 3 'requests:' | grep 'storage:' | head -1 | awk '{print $2}' | tr -d '"' || true)
    assert_eq "$pvc_size_large" "$PROMETHEUS_VOLUME_SIZE" "large: PVC storage size matches tier ($PROMETHEUS_VOLUME_SIZE)"

    # Retention — large tier
    prom_args_large=$(echo "$RENDERED_LARGE" | grep 'storage.tsdb.retention' || true)
    assert_contains "$prom_args_large" "retention.time=$PROMETHEUS_RETENTION" "large: retention duration in prometheus args"
    assert_contains "$prom_args_large" "retention.size=$PROMETHEUS_RETENTION_SIZE" "large: retention size in prometheus args"
fi

###############################################################################
# Test 7: Storage class provisioner (AWS)
###############################################################################
echo ""
echo "--- Test 7: AWS storage class provisioner in rendered output ---"

RENDERED_AWS=$(helm template test-release onelens/onelens-agent \
    --version "$CHART_VERSION" \
    --set onelens-agent.storageClass.provisioner="ebs.csi.aws.com" \
    --set onelens-agent.storageClass.volumeType="gp3" \
    2>/dev/null)

if [ -z "$RENDERED_AWS" ]; then
    echo "  FAIL: helm template returned empty output for AWS provisioner test"
    _TESTS_FAILED=$((_TESTS_FAILED + 1))
    _TESTS_TOTAL=$((_TESTS_TOTAL + 1))
else
    assert_contains "$RENDERED_AWS" "ebs.csi.aws.com" "AWS provisioner in rendered output"
    assert_contains "$RENDERED_AWS" "gp3" "AWS gp3 volume type in rendered output"
fi

###############################################################################
# globalvalues.yaml validation
###############################################################################

GV="$ROOT/globalvalues.yaml"

# globalvalues.yaml must be valid YAML
gv_yaml_check=$(python3 -c "import yaml; yaml.safe_load(open('$GV'))" 2>&1); gv_rc=$?
if [ $gv_rc -eq 0 ]; then
    assert_eq "0" "0" "globalvalues.yaml is valid YAML"
else
    assert_eq "$gv_rc" "0" "globalvalues.yaml is valid YAML: $gv_yaml_check"
fi

# extraScrapeConfigs contains network-costs job
gv_nc_job=$(grep -c 'job_name: network-costs' "$GV" || true)
assert_gt "$gv_nc_job" "0" "globalvalues.yaml has network-costs scrape job"

# network-costs job targets port 3001
gv_nc_port=$(grep -A12 'job_name: network-costs' "$GV" | grep -c '3001' || true)
assert_gt "$gv_nc_port" "0" "network-costs scrape job targets port 3001"

# network-costs job uses correct service name
gv_nc_svc=$(grep -A8 'job_name: network-costs' "$GV" | grep -c 'opencost-network-costs.onelens-agent' || true)
assert_gt "$gv_nc_svc" "0" "network-costs scrape job targets opencost-network-costs.onelens-agent"

###############################################################################
# Deployer chart validation
###############################################################################

DV="$ROOT/charts/onelensdeployer/values.yaml"

# Deployer ClusterRole has coordination.k8s.io/leases
dv_leases=$(grep -c 'coordination.k8s.io' "$DV" || true)
assert_gt "$dv_leases" "0" "deployer ClusterRole includes coordination.k8s.io"

dv_leases_resource=$(grep -A2 'coordination.k8s.io' "$DV" | grep -c 'leases' || true)
assert_gt "$dv_leases_resource" "0" "deployer ClusterRole has leases resource"

# Deployer job.env has NETWORK_COSTS_ENABLED
dv_job_nc=$(sed -n '/^job:/,/^cronjob:/p' "$DV" | grep -c 'NETWORK_COSTS_ENABLED' || true)
assert_gt "$dv_job_nc" "0" "deployer job.env has NETWORK_COSTS_ENABLED"

# Deployer cronjob.env has NETWORK_COSTS_ENABLED
dv_cron_nc=$(sed -n '/^cronjob:/,/^$/p' "$DV" | grep -c 'NETWORK_COSTS_ENABLED' || true)
assert_gt "$dv_cron_nc" "0" "deployer cronjob.env has NETWORK_COSTS_ENABLED"

###############################################################################
# Summary
###############################################################################
test_summary
exit $?
