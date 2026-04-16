#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
set_test_file "test-parity.sh"
ROOT=$(repo_root)

# ---------------------------------------------------------------------------
# Test 1: Both scripts source the shared library
# ---------------------------------------------------------------------------
install_sources=$(grep -c 'source.*lib/resource-sizing.sh' "$ROOT/install.sh" || true)
assert_gt "$install_sources" "0" "install.sh sources lib/resource-sizing.sh"

patching_sources=$(grep -c 'source.*lib/resource-sizing.sh' "$ROOT/src/patching.sh" || true)
assert_gt "$patching_sources" "0" "patching.sh sources lib/resource-sizing.sh (will be embedded at build)"

# ---------------------------------------------------------------------------
# Test 2: Both scripts call select_resource_tier
# ---------------------------------------------------------------------------
install_tier=$(grep -c 'select_resource_tier' "$ROOT/install.sh" || true)
patching_tier=$(grep -c 'select_resource_tier' "$ROOT/src/patching.sh" || true)
assert_gt "$install_tier" "0" "install.sh calls select_resource_tier"
assert_gt "$patching_tier" "0" "patching.sh calls select_resource_tier"

# ---------------------------------------------------------------------------
# Test 3: Both scripts use raw API pagination for pod counting
# ---------------------------------------------------------------------------
# kubectl get --raw with limit=100 and fieldSelector URL encoding.
for pattern in 'get --raw' 'fieldSelector=status.phase'; do
    install_has=$(grep -c "$pattern" "$ROOT/install.sh" || true)
    patching_has=$(grep -c "$pattern" "$ROOT/src/patching.sh" || true)
    assert_gt "$install_has" "0" "install.sh uses $pattern"
    assert_gt "$patching_has" "0" "patching.sh uses $pattern"
done

# ---------------------------------------------------------------------------
# Test 4: Both scripts call label density library functions
# ---------------------------------------------------------------------------
# calculate_avg_labels not called directly — labels calculated via piped jq for memory efficiency
for fn in get_label_multiplier; do
    install_has=$(grep -c "$fn" "$ROOT/install.sh" || true)
    patching_has=$(grep -c "$fn" "$ROOT/src/patching.sh" || true)
    assert_gt "$install_has" "0" "install.sh calls $fn"
    assert_gt "$patching_has" "0" "patching.sh calls $fn"
done

# ---------------------------------------------------------------------------
# Test 5: Both scripts call apply_memory_multiplier for label adjustment
# ---------------------------------------------------------------------------
install_amm=$(grep -c 'apply_memory_multiplier' "$ROOT/install.sh" || true)
patching_amm=$(grep -c 'apply_memory_multiplier' "$ROOT/src/patching.sh" || true)
assert_gt "$install_amm" "0" "install.sh calls apply_memory_multiplier"
assert_gt "$patching_amm" "0" "patching.sh calls apply_memory_multiplier"

# ---------------------------------------------------------------------------
# Test 6: Configmap-reload values match between scripts
# ---------------------------------------------------------------------------
install_cmr=$(grep 'CONFIGMAP_RELOAD' "$ROOT/install.sh" | grep -E '(REQUEST|LIMIT)=' | sed 's/^[[:space:]]*//' | sort)
patching_cmr=$(grep 'CONFIGMAP_RELOAD' "$ROOT/src/patching.sh" | grep -E '(REQUEST|LIMIT)=' | sed 's/^[[:space:]]*//' | sort)
assert_eq "$install_cmr" "$patching_cmr" "configmap-reload values match"

# ---------------------------------------------------------------------------
# Test 7: Both scripts call select_retention_tier
# ---------------------------------------------------------------------------
install_retention=$(grep -c 'select_retention_tier' "$ROOT/install.sh" || true)
assert_gt "$install_retention" "0" "install.sh calls select_retention_tier"

patching_retention=$(grep -c 'select_retention_tier' "$ROOT/src/patching.sh" || true)
assert_gt "$patching_retention" "0" "patching.sh calls select_retention_tier"

# ---------------------------------------------------------------------------
# Test 8: Helm --set resource paths in patching.sh are a subset of install.sh
# ---------------------------------------------------------------------------
install_resource_sets=$(grep -- '--set' "$ROOT/install.sh" | grep -oE '[a-zA-Z][-a-zA-Z0-9._]*\.resources\.(requests|limits)\.(cpu|memory)' | sort -u || true)
patching_resource_sets=$(grep -- '--set' "$ROOT/src/patching.sh" | grep -oE '[a-zA-Z][-a-zA-Z0-9._]*\.resources\.(requests|limits)\.(cpu|memory)' | sort -u || true)

if [ -n "$patching_resource_sets" ] && [ -n "$install_resource_sets" ]; then
    missing=$(comm -23 <(echo "$patching_resource_sets") <(echo "$install_resource_sets"))
    assert_eq "$missing" "" "patching resource --set paths are subset of install"
else
    assert_ne "" "" "could not extract resource --set paths from scripts"
fi

# ---------------------------------------------------------------------------
# Test 9: Patching.sh has BEGIN_EMBED marker for build-time embedding
# ---------------------------------------------------------------------------
embed_marker=$(grep -c 'BEGIN_EMBED' "$ROOT/src/patching.sh" || true)
assert_gt "$embed_marker" "0" "patching.sh has BEGIN_EMBED marker for build-time library embedding"

end_marker=$(grep -c 'END_EMBED' "$ROOT/src/patching.sh" || true)
assert_gt "$end_marker" "0" "patching.sh has END_EMBED marker"

# ---------------------------------------------------------------------------
# Test 10: Patching.sh pins chart version from PATCHING_VERSION env var
# Uses normalize_chart_version to strip v/release/ prefix for --version flag.
# Falls back to no --version (latest) if PATCHING_VERSION is not set (old entrypoint).
# ---------------------------------------------------------------------------
patching_ncv=$(grep -c 'normalize_chart_version.*PATCHING_VERSION' "$ROOT/src/patching.sh" || true)
assert_gt "$patching_ncv" "0" "patching.sh pins chart version from PATCHING_VERSION"
patching_version_flag=$(grep -c -- '--version.*CHART_VERSION' "$ROOT/src/patching.sh" || true)
assert_gt "$patching_version_flag" "0" "patching.sh passes --version to helm upgrade"

# ---------------------------------------------------------------------------
# Test 11: Neither agent nor deployer upgrade uses --reuse-values
# All values are explicitly controlled: customer values extracted and re-applied,
# everything else comes from chart defaults or --set overrides.
# ---------------------------------------------------------------------------
reuse_count=$(grep -v '^#' "$ROOT/src/patching.sh" | grep -c -- '--reuse-values' || true)
assert_eq "$reuse_count" "0" "no helm upgrade uses --reuse-values (all values explicitly controlled)"

# ---------------------------------------------------------------------------
# Test 12: Patching.sh does NOT have --create-namespace
# ---------------------------------------------------------------------------
patching_create_ns=$(grep -c -- '--create-namespace' "$ROOT/src/patching.sh" || true)
assert_eq "$patching_create_ns" "0" "patching does not use --create-namespace"

# ---------------------------------------------------------------------------
# Test 13: Patching.sh uses --wait (not --atomic) to avoid full rollback on timeout
# ---------------------------------------------------------------------------
wait_count=$(grep -c -- '--wait' "$ROOT/src/patching.sh" || true)
assert_gt "$wait_count" "0" "patching uses --wait for upgrade monitoring"
atomic_count=$(grep -c -- '--atomic' "$ROOT/src/patching.sh" || true)
assert_eq "$atomic_count" "0" "patching does not use --atomic (continue to deployer upgrade on failure)"

# ---------------------------------------------------------------------------
# Test 14a: Label density hardcoded value matches between scripts
# ---------------------------------------------------------------------------
# Both scripts should hardcode AVG_LABELS=6 (no runtime measurement).
install_label_block=$(sed -n '/--- Label density ---/,/LABEL_MULTIPLIER=/p' "$ROOT/install.sh" | sed 's/^[[:space:]]*//')
patching_label_block=$(sed -n '/--- Label density ---/,/LABEL_MULTIPLIER=/p' "$ROOT/src/patching.sh" | sed 's/^[[:space:]]*//')
assert_ne "$install_label_block" "" "install.sh has label density block"
assert_eq "$install_label_block" "$patching_label_block" "label density code matches (hardcoded AVG_LABELS=6)"

# ---------------------------------------------------------------------------
# Test 14: Label multiplier application code matches between scripts
# ---------------------------------------------------------------------------
# The if block that applies multiplier to PROMETHEUS/KSM/ONELENS memory should match
install_label_apply=$(sed -n '/Apply label density multiplier/,/^fi$/p' "$ROOT/install.sh" | sed 's/^[[:space:]]*//')
patching_label_apply=$(sed -n '/Apply label density multiplier/,/^fi$/p' "$ROOT/src/patching.sh" | sed 's/^[[:space:]]*//')
assert_ne "$install_label_apply" "" "install.sh has label multiplier application block"
assert_eq "$install_label_apply" "$patching_label_apply" "label multiplier application code matches"

# ---------------------------------------------------------------------------
# Test 15: Patching.sh patches activeDeadlineSeconds before helm upgrade
# ---------------------------------------------------------------------------
deadline_patch=$(grep -c 'activeDeadlineSeconds' "$ROOT/src/patching.sh" || true)
assert_gt "$deadline_patch" "0" "patching.sh references activeDeadlineSeconds"
# The deadline patch must appear BEFORE the helm upgrade command
deadline_line=$(grep -n 'CURRENT_DEADLINE' "$ROOT/src/patching.sh" | head -1 | cut -d: -f1)
helm_upgrade_line=$(grep -n 'helm upgrade onelens-agent' "$ROOT/src/patching.sh" | head -1 | cut -d: -f1)
assert_gt "$helm_upgrade_line" "$deadline_line" "activeDeadlineSeconds patched before helm upgrade"

# ---------------------------------------------------------------------------
# Test 16: Patching.sh handles stuck helm release (pending-upgrade/pending-rollback)
# ---------------------------------------------------------------------------
pending_check=$(grep -c 'pending-upgrade\|pending-rollback' "$ROOT/src/patching.sh" || true)
assert_gt "$pending_check" "0" "patching.sh checks for stuck helm release states"
rollback_cmd=$(grep -c 'helm rollback onelens-agent' "$ROOT/src/patching.sh" || true)
assert_gt "$rollback_cmd" "0" "patching.sh can rollback stuck helm releases"

# ---------------------------------------------------------------------------
# Test 17: Deployer self-upgrade removed (deployer SA cannot escalate RBAC)
# ---------------------------------------------------------------------------
deployer_helm_upgrade=$(grep -v '^#' "$ROOT/src/patching.sh" | grep -c 'helm upgrade onelensdeployer' || true)
assert_eq "$deployer_helm_upgrade" "0" "patching.sh does not self-upgrade the deployer chart"

# ---------------------------------------------------------------------------
# Test 18: Usage-based sizing functions exist in lib
# ---------------------------------------------------------------------------
for fn in evaluate_container_sizing evaluate_fixed_container_sizing parse_sizing_state \
    parse_prom_result calculate_usage_memory calculate_oom_response_memory is_safe_downsize; do
    lib_has=$(grep -c "$fn" "$ROOT/lib/resource-sizing.sh" || true)
    assert_gt "$lib_has" "0" "lib/resource-sizing.sh has $fn"
done

# ---------------------------------------------------------------------------
# Test 19: Patching.sh calls evaluate_container_sizing
# ---------------------------------------------------------------------------
patching_eval=$(grep -c 'evaluate_container_sizing' "$ROOT/src/patching.sh" || true)
assert_gt "$patching_eval" "0" "patching.sh calls evaluate_container_sizing"

# ---------------------------------------------------------------------------
# Test 20: Patching.sh manages ConfigMap state
# ---------------------------------------------------------------------------
patching_cm=$(grep -c 'onelens-agent-sizing-state' "$ROOT/src/patching.sh" || true)
assert_gt "$patching_cm" "0" "patching.sh manages onelens-agent-sizing-state ConfigMap"

# ---------------------------------------------------------------------------
# Test 21: Patching.sh has fallback to legacy memory guard
# ---------------------------------------------------------------------------
patching_fallback=$(grep -c 'USAGE_BASED_APPLIED' "$ROOT/src/patching.sh" || true)
assert_gt "$patching_fallback" "0" "patching.sh has USAGE_BASED_APPLIED fallback flag"

# ---------------------------------------------------------------------------
# Test 22: patching.sh handles pod failure detection and remediation
# ---------------------------------------------------------------------------
# install.sh registers CONNECTED immediately after helm install and delegates
# pod health management to the patching CronJob. Only patching.sh needs the
# full pod failure detection, OOM remediation, and OpenCost transient handling.
patching_oc_transient=$(grep -c 'OpenCost failing due to Prometheus dependency' "$ROOT/src/patching.sh" || true)
assert_gt "$patching_oc_transient" "0" "patching.sh handles OpenCost Prometheus-dependency transient crash"

patching_prom_check=$(grep -c 'OpenCost cannot start: Prometheus is not ready' "$ROOT/src/patching.sh" || true)
assert_gt "$patching_prom_check" "0" "patching.sh logs root cause when Prometheus is not ready"

patching_oc_logs=$(grep -c 'Failed to create Prometheus data source' "$ROOT/src/patching.sh" || true)
assert_gt "$patching_oc_logs" "0" "patching.sh checks OpenCost logs for Prometheus data source error"

patching_az=$(grep -c 'PV_AZ_MISMATCH' "$ROOT/src/patching.sh" || true)
assert_gt "$patching_az" "0" "patching.sh detects PV_AZ_MISMATCH"

# ---------------------------------------------------------------------------
# Test 24: Both scripts set --history-max 5 on helm commands
# ---------------------------------------------------------------------------
install_hm=$(grep -c '\-\-history-max 5' "$ROOT/install.sh" || true)
patching_hm=$(grep -c '\-\-history-max 5' "$ROOT/src/patching.sh" || true)
assert_gt "$install_hm" "0" "install.sh sets --history-max 5"
assert_gt "$patching_hm" "0" "patching.sh sets --history-max 5"

# ---------------------------------------------------------------------------
# Test 25: Patching.sh prunes helm release secrets before upgrade
# ---------------------------------------------------------------------------
patching_prune=$(grep -c 'owner=helm,name=onelens-agent' "$ROOT/src/patching.sh" || true)
assert_gt "$patching_prune" "0" "patching.sh prunes helm release secrets before upgrade"

# ---------------------------------------------------------------------------
# Test 26: Air-gapped image override --set keys match between scripts
# The 8 --set flags that redirect images to the private registry must be
# identical in install.sh and src/patching.sh.
# ---------------------------------------------------------------------------
install_airgap_sets=$(grep 'REGISTRY_URL' "$ROOT/install.sh" | grep -oE '\-\-set [a-zA-Z][-a-zA-Z0-9._]*\.(image\.(repository|registry)|env\.REGISTRY_URL)=' | sort)
patching_airgap_sets=$(grep 'REGISTRY_URL' "$ROOT/src/patching.sh" | grep -oE '\-\-set [a-zA-Z][-a-zA-Z0-9._]*\.(image\.(repository|registry)|env\.REGISTRY_URL)=' | sort)
assert_ne "$install_airgap_sets" "" "install.sh has air-gapped image override --set flags"
assert_eq "$install_airgap_sets" "$patching_airgap_sets" "air-gapped image override --set keys match between scripts"

# ---------------------------------------------------------------------------
# Test 27: Both scripts use CHART_SOURCE variable for helm command
# ---------------------------------------------------------------------------
install_chart_source=$(grep -c 'CHART_SOURCE=' "$ROOT/install.sh" || true)
patching_chart_source=$(grep -c 'CHART_SOURCE=' "$ROOT/src/patching.sh" || true)
assert_gt "$install_chart_source" "0" "install.sh sets CHART_SOURCE variable"
assert_gt "$patching_chart_source" "0" "patching.sh sets CHART_SOURCE variable"

install_uses_cs=$(grep -c '\$CHART_SOURCE' "$ROOT/install.sh" || true)
patching_uses_cs=$(grep -c '\$CHART_SOURCE' "$ROOT/src/patching.sh" || true)
assert_gt "$install_uses_cs" "0" "install.sh uses CHART_SOURCE in helm command"
assert_gt "$patching_uses_cs" "0" "patching.sh uses CHART_SOURCE in helm command"

# ---------------------------------------------------------------------------
# Test 28: Air-gapped code is gated behind REGISTRY_URL check
# Both scripts must only apply air-gapped overrides when REGISTRY_URL is set.
# ---------------------------------------------------------------------------
install_gate=$(grep -c '\[ -n "\$REGISTRY_URL" \]' "$ROOT/install.sh" || true)
patching_gate=$(grep -c '\[ -n "\$REGISTRY_URL" \]' "$ROOT/src/patching.sh" || true)
assert_gt "$install_gate" "0" "install.sh gates air-gapped code behind REGISTRY_URL check"
assert_gt "$patching_gate" "0" "patching.sh gates air-gapped code behind REGISTRY_URL check"

# ---------------------------------------------------------------------------
# Test 29: Standard helm repo add preserved for non-air-gapped path
# ---------------------------------------------------------------------------
install_repo_add=$(grep -c 'helm repo add onelens' "$ROOT/install.sh" || true)
patching_repo_add=$(grep -c 'helm repo add onelens' "$ROOT/src/patching.sh" || true)
assert_gt "$install_repo_add" "0" "install.sh still has helm repo add for standard path"
assert_gt "$patching_repo_add" "0" "patching.sh still has helm repo add for standard path"

# ---------------------------------------------------------------------------
# Test 30: Both scripts use --chunk-size for GPU node detection
# ---------------------------------------------------------------------------
install_gpu_chunk=$(grep 'gpu_capacities=' "$ROOT/install.sh" | grep -c 'chunk-size' || true)
patching_gpu_chunk=$(grep 'gpu_capacities=' "$ROOT/src/patching.sh" | grep -c 'chunk-size' || true)
assert_gt "$install_gpu_chunk" "0" "install.sh GPU detection uses --chunk-size"
assert_gt "$patching_gpu_chunk" "0" "patching.sh GPU detection uses --chunk-size"

# ---------------------------------------------------------------------------
# Test 31: Both scripts use custom-columns for GPU detection (not jsonpath)
# ---------------------------------------------------------------------------
install_gpu_cols=$(grep 'gpu_capacities=' "$ROOT/install.sh" | grep -c 'custom-columns' || true)
patching_gpu_cols=$(grep 'gpu_capacities=' "$ROOT/src/patching.sh" | grep -c 'custom-columns' || true)
assert_gt "$install_gpu_cols" "0" "install.sh GPU detection uses custom-columns"
assert_gt "$patching_gpu_cols" "0" "patching.sh GPU detection uses custom-columns"

# ---------------------------------------------------------------------------
# Test 32: Both scripts filter <none> in GPU awk parsing
# ---------------------------------------------------------------------------
install_gpu_none=$(grep -c '"<none>"' "$ROOT/install.sh" || true)
patching_gpu_none=$(grep -c '"<none>"' "$ROOT/src/patching.sh" || true)
assert_gt "$install_gpu_none" "0" "install.sh GPU awk filters <none>"
assert_gt "$patching_gpu_none" "0" "patching.sh GPU awk filters <none>"

# ---------------------------------------------------------------------------
# Test 33: Neither script uses kubectl get nodes -o jsonpath (loads all nodes)
# ---------------------------------------------------------------------------
# All node queries must use --chunk-size or single-node patterns to bound memory.
install_nodes_jsonpath=$(grep 'kubectl get nodes' "$ROOT/install.sh" | grep -v '#' | grep -c '\-o jsonpath' || true)
patching_nodes_jsonpath=$(grep 'kubectl get nodes' "$ROOT/src/patching.sh" | grep -v '#' | grep -c '\-o jsonpath' || true)
assert_eq "$install_nodes_jsonpath" "0" "install.sh has no kubectl get nodes -o jsonpath (OOM risk)"
assert_eq "$patching_nodes_jsonpath" "0" "patching.sh has no kubectl get nodes -o jsonpath (OOM risk)"

# ---------------------------------------------------------------------------
# Test 34: Neither script uses kubectl get nodes -o json (loads all nodes)
# ---------------------------------------------------------------------------
install_nodes_json=$(grep 'kubectl get nodes' "$ROOT/install.sh" | grep -v '#' | grep -c '\-o json ' || true)
patching_nodes_json=$(grep 'kubectl get nodes' "$ROOT/src/patching.sh" | grep -v '#' | grep -c '\-o json ' || true)
assert_eq "$install_nodes_json" "0" "install.sh has no kubectl get nodes -o json (OOM risk)"
assert_eq "$patching_nodes_json" "0" "patching.sh has no kubectl get nodes -o json (OOM risk)"

# ---------------------------------------------------------------------------
# Test 35: Neither script reads container image via containers[0].image
# Both scripts must use jsonpath name-selector to survive sidecar injectors
# (Dynatrace, Istio) that insert containers at index 0. v2.1.65 regression.
# ---------------------------------------------------------------------------
install_image_idx0=$(grep -v '^[[:space:]]*#' "$ROOT/install.sh" | grep -c 'containers\[0\]\.image' || true)
patching_image_idx0=$(grep -v '^[[:space:]]*#' "$ROOT/src/patching.sh" | grep -c 'containers\[0\]\.image' || true)
assert_eq "$install_image_idx0" "0" "install.sh has no containers[0].image reads (sidecar safety)"
assert_eq "$patching_image_idx0" "0" "patching.sh has no containers[0].image reads (sidecar safety)"

# ---------------------------------------------------------------------------
# Test 36: GPU detection Stage 1 code matches between scripts
# Both scripts must initialize the same GPU variables and use the same
# kubectl + awk pipeline for node counting and DCGM pod detection.
# ---------------------------------------------------------------------------
install_gpu_vars=$(grep -E '^(GPU_NODE_COUNT|TOTAL_GPU_COUNT|GPU_MONITORING_STATUS|DCGM_PODS_OURS|DCGM_PODS_OTHER|DCGM_PODS_TOTAL)=' "$ROOT/install.sh" | sed 's/^[[:space:]]*//' | sort)
patching_gpu_vars=$(grep -E '^(GPU_NODE_COUNT|TOTAL_GPU_COUNT|GPU_MONITORING_STATUS|DCGM_PODS_OURS|DCGM_PODS_OTHER|DCGM_PODS_TOTAL)=' "$ROOT/src/patching.sh" | sed 's/^[[:space:]]*//' | sort)
assert_ne "$install_gpu_vars" "" "install.sh initializes GPU detection variables"
assert_eq "$install_gpu_vars" "$patching_gpu_vars" "GPU detection variable initializations match"

# ---------------------------------------------------------------------------
# Test 37: Both scripts detect DCGM pods in onelens-agent namespace
# ---------------------------------------------------------------------------
install_dcgm_ours=$(grep -c 'kubectl get pods -n onelens-agent -l app=nvidia-dcgm-exporter' "$ROOT/install.sh" || true)
patching_dcgm_ours=$(grep -c 'kubectl get pods -n onelens-agent -l app=nvidia-dcgm-exporter' "$ROOT/src/patching.sh" || true)
assert_gt "$install_dcgm_ours" "0" "install.sh checks for DCGM pods in onelens-agent namespace"
assert_gt "$patching_dcgm_ours" "0" "patching.sh checks for DCGM pods in onelens-agent namespace"

# ---------------------------------------------------------------------------
# Test 38: Both scripts detect DCGM pods cluster-wide
# ---------------------------------------------------------------------------
install_dcgm_all=$(grep -c 'kubectl get pods --all-namespaces -l app=nvidia-dcgm-exporter' "$ROOT/install.sh" || true)
patching_dcgm_all=$(grep -c 'kubectl get pods --all-namespaces -l app=nvidia-dcgm-exporter' "$ROOT/src/patching.sh" || true)
assert_gt "$install_dcgm_all" "0" "install.sh checks for DCGM pods cluster-wide"
assert_gt "$patching_dcgm_all" "0" "patching.sh checks for DCGM pods cluster-wide"

# ---------------------------------------------------------------------------
# Test 39: Both scripts emit GPU_MONITORING_STATUS log line
# ---------------------------------------------------------------------------
install_status_log=$(grep -c 'echo "GPU_MONITORING_STATUS=' "$ROOT/install.sh" || true)
patching_status_log=$(grep -c 'echo "GPU_MONITORING_STATUS=' "$ROOT/src/patching.sh" || true)
assert_gt "$install_status_log" "0" "install.sh emits GPU_MONITORING_STATUS log line"
assert_gt "$patching_status_log" "0" "patching.sh emits GPU_MONITORING_STATUS log line"

# ---------------------------------------------------------------------------
# Test 40: Only patching.sh has Prometheus PROF metric check (Stage 2)
# install.sh has no Prometheus at install time — intentional difference.
# ---------------------------------------------------------------------------
patching_prof_check=$(grep -c 'DCGM_FI_PROF_GR_ENGINE_ACTIVE' "$ROOT/src/patching.sh" || true)
install_prof_check=$(grep -c 'DCGM_FI_PROF_GR_ENGINE_ACTIVE' "$ROOT/install.sh" || true)
assert_gt "$patching_prof_check" "0" "patching.sh has Stage 2 Prometheus PROF metric check"
assert_eq "$install_prof_check" "0" "install.sh does NOT have Prometheus PROF check (no Prometheus at install time)"

# ---------------------------------------------------------------------------
# Test 41: Patching.sh Stage 2 guards on PROM_QUERY_URL
# Prometheus may not be available — Stage 2 must not run if PROM_QUERY_URL is empty.
# ---------------------------------------------------------------------------
patching_prom_guard=$(grep 'DCGM_PODS_TOTAL' "$ROOT/src/patching.sh" | grep -c 'PROM_QUERY_URL' || true)
assert_gt "$patching_prom_guard" "0" "patching.sh Stage 2 guards on PROM_QUERY_URL availability"

# ---------------------------------------------------------------------------
# GPU Phase 2: conditional DCGM DaemonSet — parity tests
# ---------------------------------------------------------------------------

# Test 42: Both scripts initialize GPU_ENABLED variable
install_gpu_enabled_init=$(grep -c '^GPU_ENABLED="false"' "$ROOT/install.sh" || true)
patching_gpu_enabled_init=$(grep -c '^GPU_ENABLED="false"' "$ROOT/src/patching.sh" || true)
assert_gt "$install_gpu_enabled_init" "0" "install.sh initializes GPU_ENABLED"
assert_gt "$patching_gpu_enabled_init" "0" "patching.sh initializes GPU_ENABLED"

# Test 43: DCGM is deployed via kubectl apply, NOT via helm --set
# This ensures DCGM failures cannot block helm --wait and cascade to all components
install_dcgm_kubectl=$(grep -c 'kubectl apply.*DCGM_EOF' "$ROOT/install.sh" || true)
patching_dcgm_kubectl=$(grep -c 'kubectl apply.*DCGM_EOF' "$ROOT/src/patching.sh" || true)
assert_gt "$install_dcgm_kubectl" "0" "install.sh deploys DCGM via kubectl apply (not helm)"
assert_gt "$patching_dcgm_kubectl" "0" "patching.sh deploys DCGM via kubectl apply (not helm)"

# Test 44: Neither script passes gpu.enabled to helm (decoupled)
install_gpu_helm=$(grep 'onelens-agent.gpu.enabled' "$ROOT/install.sh" | grep -c '\-\-set' || true)
patching_gpu_helm=$(grep 'onelens-agent.gpu.enabled' "$ROOT/src/patching.sh" | grep -c '\-\-set' || true)
assert_eq "$install_gpu_helm" "0" "install.sh does NOT pass gpu.enabled to helm"
assert_eq "$patching_gpu_helm" "0" "patching.sh does NOT pass gpu.enabled to helm"

# Test 45: Both scripts have DCGM image from nvcr.io (NVIDIA's registry) in kubectl apply block
install_dcgm_img=$(sed -n '/GPU Phase 2: deploy/,/DCGM_EOF/p' "$ROOT/install.sh" | grep -c 'nvcr.io/nvidia' || true)
patching_dcgm_img=$(sed -n '/GPU Phase 2: deploy/,/DCGM_EOF/p' "$ROOT/src/patching.sh" | grep -c 'nvcr.io/nvidia' || true)
assert_gt "$install_dcgm_img" "0" "install.sh DCGM image is from nvcr.io"
assert_gt "$patching_dcgm_img" "0" "patching.sh DCGM image is from nvcr.io"

# Test 46: Both scripts check DCGM_PODS_OTHER in the GPU_ENABLED resolution block
install_pods_other_check=$(sed -n '/GPU Phase 2: resolve gpu.enabled/,/^$/p' "$ROOT/install.sh" | grep -c 'DCGM_PODS_OTHER' || true)
patching_pods_other_check=$(sed -n '/GPU Phase 2: resolve gpu.enabled/,/^$/p' "$ROOT/src/patching.sh" | grep -c 'DCGM_PODS_OTHER' || true)
assert_gt "$install_pods_other_check" "0" "install.sh checks DCGM_PODS_OTHER for GPU_ENABLED resolution"
assert_gt "$patching_pods_other_check" "0" "patching.sh checks DCGM_PODS_OTHER for GPU_ENABLED resolution"

# Test 47: Only patching.sh reads GPU_ENABLED_OVERRIDE from existing release
# install.sh is a fresh install — no existing release to read from
patching_gpu_override=$(grep -c 'GPU_ENABLED_OVERRIDE' "$ROOT/src/patching.sh" || true)
install_gpu_override=$(grep -c 'GPU_ENABLED_OVERRIDE' "$ROOT/install.sh" || true)
assert_gt "$patching_gpu_override" "0" "patching.sh reads GPU_ENABLED_OVERRIDE from existing release"
assert_eq "$install_gpu_override" "0" "install.sh does NOT read GPU_ENABLED_OVERRIDE (fresh install)"

# Test 48: Both scripts detect GPU Operator DCGM (app.kubernetes.io/component label)
install_gpu_operator=$(grep -c 'app.kubernetes.io/component=dcgm-exporter' "$ROOT/install.sh" || true)
patching_gpu_operator=$(grep -c 'app.kubernetes.io/component=dcgm-exporter' "$ROOT/src/patching.sh" || true)
assert_gt "$install_gpu_operator" "0" "install.sh detects GPU Operator-managed DCGM"
assert_gt "$patching_gpu_operator" "0" "patching.sh detects GPU Operator-managed DCGM"

# Test 49: Both scripts have non-fatal DCGM deployment (WARNING on failure, not exit)
install_dcgm_nonfatal=$(sed -n '/GPU Phase 2: deploy/,/^fi$/p' "$ROOT/install.sh" | grep -c 'WARNING.*DCGM.*failed' || true)
patching_dcgm_nonfatal=$(sed -n '/GPU Phase 2: deploy/,/^fi$/p' "$ROOT/src/patching.sh" | grep -c 'WARNING.*DCGM.*failed' || true)
assert_gt "$install_dcgm_nonfatal" "0" "install.sh DCGM failure is non-fatal (WARNING)"
assert_gt "$patching_dcgm_nonfatal" "0" "patching.sh DCGM failure is non-fatal (WARNING)"

# Test 50: Both scripts have air-gapped DCGM image override in kubectl apply block
install_dcgm_airgap=$(sed -n '/GPU Phase 2: deploy/,/DCGM_EOF/p' "$ROOT/install.sh" | grep -c 'REGISTRY_URL' || true)
patching_dcgm_airgap=$(sed -n '/GPU Phase 2: deploy/,/DCGM_EOF/p' "$ROOT/src/patching.sh" | grep -c 'REGISTRY_URL' || true)
assert_gt "$install_dcgm_airgap" "0" "install.sh has air-gapped DCGM image override"
assert_gt "$patching_dcgm_airgap" "0" "patching.sh has air-gapped DCGM image override"

# Test 51: Both scripts discover GPU node label dynamically (not hardcoded nodeSelector)
install_label_discovery=$(grep -c 'GPU_NODE_LABEL_KEY' "$ROOT/install.sh" || true)
patching_label_discovery=$(grep -c 'GPU_NODE_LABEL_KEY' "$ROOT/src/patching.sh" || true)
assert_gt "$install_label_discovery" "0" "install.sh uses dynamic GPU_NODE_LABEL_KEY"
assert_gt "$patching_label_discovery" "0" "patching.sh uses dynamic GPU_NODE_LABEL_KEY"

# Test 52: Both scripts use nodeAffinity (not nodeSelector) in DCGM manifest
install_affinity=$(sed -n '/DCGM_EOF/,/DCGM_EOF/p' "$ROOT/install.sh" | grep -c 'nodeAffinity' || true)
patching_affinity=$(sed -n '/DCGM_EOF/,/DCGM_EOF/p' "$ROOT/src/patching.sh" | grep -c 'nodeAffinity' || true)
assert_gt "$install_affinity" "0" "install.sh DCGM uses nodeAffinity"
assert_gt "$patching_affinity" "0" "patching.sh DCGM uses nodeAffinity"

# Test 53: Both scripts use prefix-based nvidia.com/gpu label search
install_prefix=$(grep -c 'startswith("nvidia.com/gpu")' "$ROOT/install.sh" || true)
patching_prefix=$(grep -c 'startswith("nvidia.com/gpu")' "$ROOT/src/patching.sh" || true)
assert_gt "$install_prefix" "0" "install.sh uses prefix search for nvidia.com/gpu labels"
assert_gt "$patching_prefix" "0" "patching.sh uses prefix search for nvidia.com/gpu labels"

test_summary
exit $?
