#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
source "$(lib_dir)/resource-sizing.sh"
set_test_file "test-tier-selection.sh"

###############################################################################
# Helper: assert all 20 resource variables for a given tier
###############################################################################
assert_all_resource_vars() {
    local label="$1"
    local prom_cpu_req="$2"   prom_mem_req="$3"   prom_cpu_lim="$4"   prom_mem_lim="$5"
    local oc_cpu_req="$6"     oc_mem_req="$7"     oc_cpu_lim="$8"     oc_mem_lim="$9"
    local ol_cpu_req="${10}"   ol_mem_req="${11}"   ol_cpu_lim="${12}"   ol_mem_lim="${13}"
    local ksm_cpu_req="${14}"  ksm_mem_req="${15}"  ksm_cpu_lim="${16}"  ksm_mem_lim="${17}"
    local pg_cpu_req="${18}"   pg_mem_req="${19}"   pg_cpu_lim="${20}"   pg_mem_lim="${21}"

    assert_eq "$PROMETHEUS_CPU_REQUEST"               "$prom_cpu_req" "$label: PROMETHEUS_CPU_REQUEST"
    assert_eq "$PROMETHEUS_MEMORY_REQUEST"             "$prom_mem_req" "$label: PROMETHEUS_MEMORY_REQUEST"
    assert_eq "$PROMETHEUS_CPU_LIMIT"                  "$prom_cpu_lim" "$label: PROMETHEUS_CPU_LIMIT"
    assert_eq "$PROMETHEUS_MEMORY_LIMIT"               "$prom_mem_lim" "$label: PROMETHEUS_MEMORY_LIMIT"
    assert_eq "$OPENCOST_CPU_REQUEST"                  "$oc_cpu_req"   "$label: OPENCOST_CPU_REQUEST"
    assert_eq "$OPENCOST_MEMORY_REQUEST"               "$oc_mem_req"   "$label: OPENCOST_MEMORY_REQUEST"
    assert_eq "$OPENCOST_CPU_LIMIT"                    "$oc_cpu_lim"   "$label: OPENCOST_CPU_LIMIT"
    assert_eq "$OPENCOST_MEMORY_LIMIT"                 "$oc_mem_lim"   "$label: OPENCOST_MEMORY_LIMIT"
    assert_eq "$ONELENS_CPU_REQUEST"                   "$ol_cpu_req"   "$label: ONELENS_CPU_REQUEST"
    assert_eq "$ONELENS_MEMORY_REQUEST"                "$ol_mem_req"   "$label: ONELENS_MEMORY_REQUEST"
    assert_eq "$ONELENS_CPU_LIMIT"                     "$ol_cpu_lim"   "$label: ONELENS_CPU_LIMIT"
    assert_eq "$ONELENS_MEMORY_LIMIT"                  "$ol_mem_lim"   "$label: ONELENS_MEMORY_LIMIT"
    assert_eq "$KSM_CPU_REQUEST"                       "$ksm_cpu_req"  "$label: KSM_CPU_REQUEST"
    assert_eq "$KSM_MEMORY_REQUEST"                    "$ksm_mem_req"  "$label: KSM_MEMORY_REQUEST"
    assert_eq "$KSM_CPU_LIMIT"                         "$ksm_cpu_lim"  "$label: KSM_CPU_LIMIT"
    assert_eq "$KSM_MEMORY_LIMIT"                      "$ksm_mem_lim"  "$label: KSM_MEMORY_LIMIT"
    assert_eq "$PROMETHEUS_PUSHGATEWAY_CPU_REQUEST"    "$pg_cpu_req"   "$label: PROMETHEUS_PUSHGATEWAY_CPU_REQUEST"
    assert_eq "$PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST" "$pg_mem_req"   "$label: PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST"
    assert_eq "$PROMETHEUS_PUSHGATEWAY_CPU_LIMIT"      "$pg_cpu_lim"   "$label: PROMETHEUS_PUSHGATEWAY_CPU_LIMIT"
    assert_eq "$PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT"   "$pg_mem_lim"   "$label: PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT"
}

###############################################################################
# select_resource_tier — boundary tests with full variable verification
###############################################################################

# Helper: call select_resource_tier (sets TIER global variable)
call_tier() {
    select_resource_tier "$1"
}
get_tier() {
    echo "$TIER"
}

echo ""
echo "--- select_resource_tier: tiny tier (0 pods) — full check ---"
call_tier 0
assert_eq "$(get_tier)" "tiny" "0 pods -> tiny tier"
assert_all_resource_vars "tiny(0)" \
    "100m" "150Mi"  "100m" "150Mi"  \
    "100m" "192Mi"  "100m" "192Mi"  \
    "100m" "256Mi"  "300m" "384Mi"  \
    "50m"  "64Mi"   "50m"  "64Mi"   \
    "50m"  "64Mi"   "50m"  "64Mi"

echo ""
echo "--- select_resource_tier: tiny tier (49 pods) — boundary ---"
call_tier 49
assert_eq "$(get_tier)" "tiny" "49 pods -> tiny tier"

echo ""
echo "--- select_resource_tier: small tier (50 pods) — full check ---"
call_tier 50
assert_eq "$(get_tier)" "small" "50 pods -> small tier"
assert_all_resource_vars "small(50)" \
    "100m" "275Mi"  "100m" "275Mi"  \
    "100m" "192Mi"  "100m" "192Mi"  \
    "150m" "320Mi"  "400m" "480Mi"  \
    "50m"  "128Mi"  "50m"  "128Mi"  \
    "50m"  "64Mi"   "50m"  "64Mi"

echo ""
echo "--- select_resource_tier: small tier (99 pods) — boundary ---"
call_tier 99
assert_eq "$(get_tier)" "small" "99 pods -> small tier"

echo ""
echo "--- select_resource_tier: medium tier (100 pods) — full check ---"
call_tier 100
assert_eq "$(get_tier)" "medium" "100 pods -> medium tier"
assert_all_resource_vars "medium(100)" \
    "150m" "420Mi"  "150m" "420Mi"  \
    "100m" "256Mi"  "100m" "256Mi"  \
    "150m" "480Mi"  "400m" "640Mi"  \
    "50m"  "192Mi"  "50m"  "192Mi"  \
    "50m"  "100Mi"  "50m"  "100Mi"

echo ""
echo "--- select_resource_tier: medium tier (499 pods) — boundary ---"
call_tier 499
assert_eq "$(get_tier)" "medium" "499 pods -> medium tier"

echo ""
echo "--- select_resource_tier: large tier (500 pods) — full check ---"
call_tier 500
assert_eq "$(get_tier)" "large" "500 pods -> large tier"
assert_all_resource_vars "large(500)" \
    "250m"  "720Mi"  "250m"  "720Mi"  \
    "150m"  "384Mi"  "150m"  "384Mi"  \
    "150m"  "640Mi"  "500m"  "800Mi"  \
    "50m"   "256Mi"  "50m"   "256Mi"  \
    "50m"   "100Mi"  "50m"   "100Mi"

echo ""
echo "--- select_resource_tier: large tier (999 pods) — boundary ---"
call_tier 999
assert_eq "$(get_tier)" "large" "999 pods -> large tier"

echo ""
echo "--- select_resource_tier: extra-large tier (1000 pods) — full check ---"
call_tier 1000
assert_eq "$(get_tier)" "extra-large" "1000 pods -> extra-large tier"
assert_all_resource_vars "extra-large(1000)" \
    "400m"  "1600Mi" "400m"  "1600Mi" \
    "150m"  "512Mi"  "150m"  "512Mi"  \
    "150m"  "800Mi"  "500m"  "960Mi"  \
    "100m"  "384Mi"  "100m"  "384Mi"  \
    "50m"   "128Mi"  "50m"   "128Mi"

echo ""
echo "--- select_resource_tier: extra-large tier (1499 pods) — boundary ---"
call_tier 1499
assert_eq "$(get_tier)" "extra-large" "1499 pods -> extra-large tier"

echo ""
echo "--- select_resource_tier: very-large tier (1500 pods) — full check ---"
call_tier 1500
assert_eq "$(get_tier)" "very-large" "1500 pods -> very-large tier"
assert_all_resource_vars "very-large(1500)" \
    "600m"  "2400Mi"  "600m"  "2400Mi"  \
    "200m"  "768Mi"   "200m"  "768Mi"   \
    "200m"  "960Mi"   "600m"  "1280Mi"  \
    "100m"  "512Mi"   "100m"  "512Mi"   \
    "50m"   "128Mi"   "50m"   "128Mi"

echo ""
echo "--- select_resource_tier: very-large tier (5000 pods) — boundary ---"
call_tier 5000
assert_eq "$(get_tier)" "very-large" "5000 pods -> very-large tier"

# Cleanup

###############################################################################
# select_retention_tier — boundary tests
###############################################################################

echo ""
echo "--- select_retention_tier: <50 pods ---"
select_retention_tier 0
assert_eq "$PROMETHEUS_RETENTION"      "10d" "0 pods: retention"
assert_eq "$PROMETHEUS_RETENTION_SIZE" "4GB" "0 pods: retention size"
assert_eq "$PROMETHEUS_VOLUME_SIZE"    "8Gi" "0 pods: volume size"

select_retention_tier 49
assert_eq "$PROMETHEUS_RETENTION"      "10d" "49 pods: retention"
assert_eq "$PROMETHEUS_RETENTION_SIZE" "4GB" "49 pods: retention size"
assert_eq "$PROMETHEUS_VOLUME_SIZE"    "8Gi" "49 pods: volume size"

echo ""
echo "--- select_retention_tier: 50-99 pods ---"
select_retention_tier 50
assert_eq "$PROMETHEUS_RETENTION"      "10d"  "50 pods: retention"
assert_eq "$PROMETHEUS_RETENTION_SIZE" "6GB"  "50 pods: retention size"
assert_eq "$PROMETHEUS_VOLUME_SIZE"    "10Gi" "50 pods: volume size"

select_retention_tier 99
assert_eq "$PROMETHEUS_RETENTION"      "10d"  "99 pods: retention"
assert_eq "$PROMETHEUS_RETENTION_SIZE" "6GB"  "99 pods: retention size"
assert_eq "$PROMETHEUS_VOLUME_SIZE"    "10Gi" "99 pods: volume size"

echo ""
echo "--- select_retention_tier: 100-499 pods ---"
select_retention_tier 100
assert_eq "$PROMETHEUS_RETENTION"      "10d"  "100 pods: retention"
assert_eq "$PROMETHEUS_RETENTION_SIZE" "12GB" "100 pods: retention size"
assert_eq "$PROMETHEUS_VOLUME_SIZE"    "20Gi" "100 pods: volume size"

select_retention_tier 499
assert_eq "$PROMETHEUS_RETENTION"      "10d"  "499 pods: retention"
assert_eq "$PROMETHEUS_RETENTION_SIZE" "12GB" "499 pods: retention size"
assert_eq "$PROMETHEUS_VOLUME_SIZE"    "20Gi" "499 pods: volume size"

echo ""
echo "--- select_retention_tier: 500-999 pods ---"
select_retention_tier 500
assert_eq "$PROMETHEUS_RETENTION"      "10d"  "500 pods: retention"
assert_eq "$PROMETHEUS_RETENTION_SIZE" "20GB" "500 pods: retention size"
assert_eq "$PROMETHEUS_VOLUME_SIZE"    "30Gi" "500 pods: volume size"

select_retention_tier 999
assert_eq "$PROMETHEUS_RETENTION"      "10d"  "999 pods: retention"
assert_eq "$PROMETHEUS_RETENTION_SIZE" "20GB" "999 pods: retention size"
assert_eq "$PROMETHEUS_VOLUME_SIZE"    "30Gi" "999 pods: volume size"

echo ""
echo "--- select_retention_tier: 1000-1499 pods ---"
select_retention_tier 1000
assert_eq "$PROMETHEUS_RETENTION"      "10d"  "1000 pods: retention"
assert_eq "$PROMETHEUS_RETENTION_SIZE" "30GB" "1000 pods: retention size"
assert_eq "$PROMETHEUS_VOLUME_SIZE"    "40Gi" "1000 pods: volume size"

select_retention_tier 1499
assert_eq "$PROMETHEUS_RETENTION"      "10d"  "1499 pods: retention"
assert_eq "$PROMETHEUS_RETENTION_SIZE" "30GB" "1499 pods: retention size"
assert_eq "$PROMETHEUS_VOLUME_SIZE"    "40Gi" "1499 pods: volume size"

echo ""
echo "--- select_retention_tier: 1500+ pods ---"
select_retention_tier 1500
assert_eq "$PROMETHEUS_RETENTION"      "10d"  "1500 pods: retention"
assert_eq "$PROMETHEUS_RETENTION_SIZE" "35GB" "1500 pods: retention size"
assert_eq "$PROMETHEUS_VOLUME_SIZE"    "50Gi" "1500 pods: volume size"

select_retention_tier 5000
assert_eq "$PROMETHEUS_RETENTION"      "10d"  "5000 pods: retention"
assert_eq "$PROMETHEUS_RETENTION_SIZE" "35GB" "5000 pods: retention size"
assert_eq "$PROMETHEUS_VOLUME_SIZE"    "50Gi" "5000 pods: volume size"

###############################################################################
# Summary
###############################################################################

test_summary
exit $?
