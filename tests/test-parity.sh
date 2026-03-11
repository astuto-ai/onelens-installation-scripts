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
# Test 3: Both scripts call the same pod counting functions
# ---------------------------------------------------------------------------
for fn in count_deploy_pods count_sts_pods count_ds_pods calculate_total_pods; do
    install_has=$(grep -c "$fn" "$ROOT/install.sh" || true)
    patching_has=$(grep -c "$fn" "$ROOT/src/patching.sh" || true)
    assert_gt "$install_has" "0" "install.sh calls $fn"
    assert_gt "$patching_has" "0" "patching.sh calls $fn"
done

# ---------------------------------------------------------------------------
# Test 4: Both scripts call label density library functions
# ---------------------------------------------------------------------------
for fn in calculate_avg_labels get_label_multiplier; do
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
# Test 7: install.sh calls select_retention_tier, patching.sh does NOT
# ---------------------------------------------------------------------------
install_retention=$(grep -c 'select_retention_tier' "$ROOT/install.sh" || true)
assert_gt "$install_retention" "0" "install.sh calls select_retention_tier"

patching_retention=$(grep -c 'select_retention_tier' "$ROOT/src/patching.sh" || true)
assert_eq "$patching_retention" "0" "patching.sh does NOT call select_retention_tier (relies on --reuse-values)"

# ---------------------------------------------------------------------------
# Test 8: Helm --set resource paths in patching.sh are a subset of install.sh
# ---------------------------------------------------------------------------
install_resource_sets=$(grep -oE '\-\-set [a-zA-Z][-a-zA-Z0-9._\[\]]*\.resources\.[a-z.]*' "$ROOT/install.sh" 2>/dev/null | sed 's/--set //' | sort -u || true)
patching_resource_sets=$(grep -oE '\-\-set [a-zA-Z][-a-zA-Z0-9._\[\]]*\.resources\.[a-z.]*' "$ROOT/src/patching.sh" 2>/dev/null | sed 's/--set //' | sort -u || true)

# Fallback to broader regex if needed
if [ -z "$install_resource_sets" ]; then
    install_resource_sets=$(grep 'resources\.' "$ROOT/install.sh" | grep -oE '[a-zA-Z][-a-zA-Z0-9._]*\.resources\.(requests|limits)\.(cpu|memory)' | sort -u || true)
fi
if [ -z "$patching_resource_sets" ]; then
    patching_resource_sets=$(grep 'resources\.' "$ROOT/src/patching.sh" | grep -oE '[a-zA-Z][-a-zA-Z0-9._]*\.resources\.(requests|limits)\.(cpu|memory)' | sort -u || true)
fi

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
# Test 10: Patching.sh uses normalize_chart_version from library
# ---------------------------------------------------------------------------
patching_ncv=$(grep -c 'normalize_chart_version' "$ROOT/src/patching.sh" || true)
assert_gt "$patching_ncv" "0" "patching.sh uses normalize_chart_version from library"

# ---------------------------------------------------------------------------
# Test 11: Patching.sh has --reuse-values flag
# ---------------------------------------------------------------------------
reuse_count=$(grep -c -- '--reuse-values' "$ROOT/src/patching.sh" || true)
assert_gt "$reuse_count" "0" "patching uses --reuse-values"

# ---------------------------------------------------------------------------
# Test 12: Patching.sh does NOT have --create-namespace
# ---------------------------------------------------------------------------
patching_create_ns=$(grep -c -- '--create-namespace' "$ROOT/src/patching.sh" || true)
assert_eq "$patching_create_ns" "0" "patching does not use --create-namespace"

# ---------------------------------------------------------------------------
# Test 13: Patching.sh has --atomic flag
# ---------------------------------------------------------------------------
atomic_count=$(grep -c -- '--atomic' "$ROOT/src/patching.sh" || true)
assert_gt "$atomic_count" "0" "patching uses --atomic for safe rollback"

# ---------------------------------------------------------------------------
# Test 14: Label multiplier application code matches between scripts
# ---------------------------------------------------------------------------
# The if block that applies multiplier to PROMETHEUS/KSM/ONELENS memory should match
install_label_apply=$(sed -n '/Apply label density multiplier/,/^fi$/p' "$ROOT/install.sh" | sed 's/^[[:space:]]*//')
patching_label_apply=$(sed -n '/Apply label density multiplier/,/^fi$/p' "$ROOT/src/patching.sh" | sed 's/^[[:space:]]*//')
assert_ne "$install_label_apply" "" "install.sh has label multiplier application block"
assert_eq "$install_label_apply" "$patching_label_apply" "label multiplier application code matches"

test_summary
exit $?
