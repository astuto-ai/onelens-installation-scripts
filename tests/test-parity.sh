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
# Test 3: Both scripts call calculate_total_pods
# ---------------------------------------------------------------------------
# count_deploy_pods/count_sts_pods/count_ds_pods not called directly —
# pod counts calculated via text output (--no-headers) + awk for memory efficiency
for fn in calculate_total_pods; do
    install_has=$(grep -c "$fn" "$ROOT/install.sh" || true)
    patching_has=$(grep -c "$fn" "$ROOT/src/patching.sh" || true)
    assert_gt "$install_has" "0" "install.sh calls $fn"
    assert_gt "$patching_has" "0" "patching.sh calls $fn"
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
# Test 14a: Label density counting awk logic matches between scripts
# ---------------------------------------------------------------------------
# The kubectl + awk pipeline that counts labels should be identical in both scripts.
# Extract the full label measurement block (from "Label density measurement" to the AVG_LABELS fallback).
install_label_measure=$(sed -n '/--- Label density measurement ---/,/LABEL_MULTIPLIER=/p' "$ROOT/install.sh" | sed 's/^[[:space:]]*//')
patching_label_measure=$(sed -n '/--- Label density measurement ---/,/LABEL_MULTIPLIER=/p' "$ROOT/src/patching.sh" | sed 's/^[[:space:]]*//')
assert_ne "$install_label_measure" "" "install.sh has label density measurement block"
assert_eq "$install_label_measure" "$patching_label_measure" "label density measurement code matches (kubectl + awk pipeline)"

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
# Test 22: Both scripts handle OpenCost transient Prometheus-dependency crash
# ---------------------------------------------------------------------------
# After the pod health poll loop, both scripts must detect OpenCost failures
# caused by Prometheus being temporarily unreachable and wait for recovery.
install_oc_transient=$(grep -c 'OpenCost failing due to Prometheus dependency' "$ROOT/install.sh" || true)
patching_oc_transient=$(grep -c 'OpenCost failing due to Prometheus dependency' "$ROOT/src/patching.sh" || true)
assert_gt "$install_oc_transient" "0" "install.sh handles OpenCost Prometheus-dependency transient crash"
assert_gt "$patching_oc_transient" "0" "patching.sh handles OpenCost Prometheus-dependency transient crash"

# Both scripts must check Prometheus readiness before waiting for OpenCost
install_prom_check=$(grep -c 'OpenCost cannot start: Prometheus is not ready' "$ROOT/install.sh" || true)
patching_prom_check=$(grep -c 'OpenCost cannot start: Prometheus is not ready' "$ROOT/src/patching.sh" || true)
assert_gt "$install_prom_check" "0" "install.sh logs root cause when Prometheus is not ready"
assert_gt "$patching_prom_check" "0" "patching.sh logs root cause when Prometheus is not ready"

# Both scripts must check OpenCost logs for Prometheus connection errors
install_oc_logs=$(grep -c 'Failed to create Prometheus data source' "$ROOT/install.sh" || true)
patching_oc_logs=$(grep -c 'Failed to create Prometheus data source' "$ROOT/src/patching.sh" || true)
assert_gt "$install_oc_logs" "0" "install.sh checks OpenCost logs for Prometheus data source error"
assert_gt "$patching_oc_logs" "0" "patching.sh checks OpenCost logs for Prometheus data source error"

test_summary
exit $?
