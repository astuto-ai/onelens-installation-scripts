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
# retention_size_for_volume / keep_retention_size
###############################################################################
echo ""
echo "--- retention_size_for_volume: same pairs as select_retention_tier ---"
for pods in 1 49 50 99 100 499 500 999 1000 1499 1500 5000; do
    select_retention_tier "$pods"
    assert_eq "$(retention_size_for_volume "$PROMETHEUS_VOLUME_SIZE")" "$PROMETHEUS_RETENTION_SIZE" \
        "retention_size_for_volume $PROMETHEUS_VOLUME_SIZE = tier retentionSize at $pods pods"
done
assert_eq "$(retention_size_for_volume 15Gi)" "6GB" "retention_size_for_volume: 15Gi (between tiers) → 6GB"
assert_eq "$(retention_size_for_volume 100Gi)" "35GB" "retention_size_for_volume: 100Gi → 35GB"
assert_eq "$(retention_size_for_volume 5Gi)" "" "retention_size_for_volume: below 8Gi → empty"
assert_eq "$(retention_size_for_volume 21474836480)" "" "retention_size_for_volume: non-Gi → empty"
assert_eq "$(retention_size_for_volume "")" "" "retention_size_for_volume: empty → empty"

echo ""
echo "--- keep_retention_size ---"
# _ret <pods> <current retentionSize> <volume> — retentionSize patching.sh would set
_ret() {
    ( select_retention_tier "$1"; keep_retention_size "$2" "$3" >/dev/null; echo "$PROMETHEUS_RETENTION_SIZE" )
}
# Reported case: 38-39 active pods (49-50 with the buffer) flipped 4GB/6GB every run
assert_eq "$(_ret 49 6GB 10Gi)" "6GB" "below a boundary on a 10Gi PVC: 6GB kept (was lowered to 4GB)"
assert_eq "$(_ret 50 6GB 10Gi)" "6GB" "above it: 6GB unchanged"
assert_eq "$(_ret 50 4GB 8Gi)" "4GB" "8Gi PVC: not raised to 6GB, which the tiers pair with 10Gi (was raised)"
assert_eq "$(_ret 49 4GB 8Gi)" "4GB" "8Gi PVC below the boundary: 4GB unchanged"
assert_eq "$(_ret 50 4GB 10Gi)" "6GB" "10Gi PVC, pods cross the boundary upward: raised to 6GB, as before"
assert_eq "$(_ret 100 6GB 10Gi)" "6GB" "100 pods on a reused 10Gi PVC: 12GB doesn't fit, 6GB kept (was 12GB)"
assert_eq "$(_ret 500 4GB 20Gi)" "12GB" "500 pods on a 20Gi PVC: raised only to 12GB, what 20Gi holds (was 20GB)"
assert_eq "$(_ret 120 35GB 50Gi)" "35GB" "cluster shrank: 35GB kept, never lowered"
assert_eq "$(_ret 30 9GB 20Gi)" "9GB" "custom 9GB above the tier: kept"
assert_eq "$(_ret 30 4GB 20Gi)" "4GB" "current equals tier: unchanged"
assert_eq "$(_ret 600 12GB "")" "20GB" "volume unknown: raised to the tier, as before"
assert_eq "$(_ret 30 12GB "")" "12GB" "volume unknown: still never lowered"
assert_eq "$(_ret 600 "" 20Gi)" "20GB" "no current retentionSize: tier value, as before"
assert_eq "$(_ret 30 500MB 20Gi)" "4GB" "non-GB current retentionSize: tier value, as before"
assert_eq "$(_ret 30 6GB 21474836480)" "6GB" "non-Gi volume: never lowered"
# Every tier x current size x volume: never lowered, and changed only where the old code (which
# always set the tier value) changed it too, so it adds no Prometheus restart
bad=""
for pods in 30 60 200 700 1200 2000; do
    select_retention_tier "$pods"; tier="$PROMETHEUS_RETENTION_SIZE"
    for cur in 4GB 6GB 12GB 20GB 30GB 35GB; do
        for vol in 8Gi 10Gi 20Gi 30Gi 40Gi 50Gi; do
            got=$(_ret "$pods" "$cur" "$vol")
            [ "${got%GB}" -ge "${cur%GB}" ] || bad="$bad lowered:$pods/$cur/$vol=$got"
            [ "$got" = "$cur" ] || [ "$tier" != "$cur" ] || bad="$bad extra-restart:$pods/$cur/$vol=$got"
        done
    done
done
assert_eq "$bad" "" "216 combinations: never lowered, changed only where the old code changed it too"

# patching.sh: applied after the PVC size is settled, before the helm command is built
PATCHING="$(repo_root)/src/patching.sh"
keep_line=$(grep -n '^keep_retention_size ' "$PATCHING" | cut -d: -f1)
pvc_line=$(grep -n 'Keeping existing size."' "$PATCHING" | head -1 | cut -d: -f1)
helm_line=$(grep -n 'prometheus.server.retentionSize=' "$PATCHING" | cut -d: -f1)
assert_eq "$([ -n "$keep_line" ] && [ -n "$pvc_line" ] && [ -n "$helm_line" ] && [ "$pvc_line" -lt "$keep_line" ] && [ "$keep_line" -lt "$helm_line" ] && echo yes || echo no)" "yes" \
    "patching.sh keeps retentionSize after the PVC size step and before helm"
assert_eq "$(grep -A1 '^keep_retention_size ' "$PATCHING" | grep -c '_prom_pvc_size:-\$PROMETHEUS_VOLUME_SIZE')" "1" \
    "patching.sh sizes retention to the live PVC, else the volume helm creates"
assert_eq "$(grep -B2 '^keep_retention_size ' "$PATCHING" | grep -c '^_prom_pvc_size=\$(kubectl get pvc onelens-agent-prometheus-server ')" "1" \
    "patching.sh reads the live PVC, not EXISTING_PVC_SIZE (the helm value when there is no PVC)"
# No PVC yet: helm creates it at PROMETHEUS_VOLUME_SIZE, at least the tier volume, so the tier
# value fits and the next run (reading the new PVC) has nothing to raise
for pods in 30 60 200 700 1200 2000; do
    select_retention_tier "$pods"; tier="$PROMETHEUS_RETENTION_SIZE"; vol="$PROMETHEUS_VOLUME_SIZE"
    assert_eq "$(_ret "$pods" 4GB "$vol")" "$tier" "no PVC at $pods pods: 4GB raised to the tier ($tier) in one run"
done

###############################################################################
# Summary
###############################################################################

test_summary
exit $?
