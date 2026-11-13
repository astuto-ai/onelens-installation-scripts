#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
source "$(lib_dir)/resource-sizing.sh"
set_test_file "test-usage-math.sh"

###############################################################################
# apply_cpu_multiplier
###############################################################################

assert_eq "$(apply_cpu_multiplier "100m" 1.25)" "150m" \
    "apply_cpu_multiplier 100m x 1.25 = 150m (rounded to 50m)"

assert_eq "$(apply_cpu_multiplier "1" 1.25)" "1250m" \
    "apply_cpu_multiplier 1 core x 1.25 = 1250m"

assert_eq "$(apply_cpu_multiplier "0.5" 1.25)" "650m" \
    "apply_cpu_multiplier 0.5 core x 1.25 = 650m (rounded to 50m)"

assert_eq "$(apply_cpu_multiplier "0m" 1.25)" "0m" \
    "apply_cpu_multiplier 0m x 1.25 = 0m"

assert_eq "$(apply_cpu_multiplier "200m" 1.35)" "300m" \
    "apply_cpu_multiplier 200m x 1.35 = 300m (rounded to 50m)"

###############################################################################
# _clamp_resource
###############################################################################

assert_eq "$(_clamp_resource 50 100 2000)" "100" \
    "_clamp_resource below floor: 50 → 100"

assert_eq "$(_clamp_resource 3000 100 2000)" "2000" \
    "_clamp_resource above cap: 3000 → 2000"

assert_eq "$(_clamp_resource 500 100 2000)" "500" \
    "_clamp_resource in range: 500 stays 500"

assert_eq "$(_clamp_resource 100 100 2000)" "100" \
    "_clamp_resource at floor: 100 stays 100"

assert_eq "$(_clamp_resource 2000 100 2000)" "2000" \
    "_clamp_resource at cap: 2000 stays 2000"

###############################################################################
# calculate_usage_memory
###############################################################################

# 200MB * 1.35 = 270MB → 258Mi raw → rounded to 300Mi
assert_eq "$(calculate_usage_memory 200000000 1.35 150 4800)" "300Mi" \
    "calculate_usage_memory normal: 200MB * 1.35 = 300Mi (rounded to 100)"

# 10MB * 1.35 = 13.5Mi → below floor 150 → 150Mi
assert_eq "$(calculate_usage_memory 10000000 1.35 150 4800)" "150Mi" \
    "calculate_usage_memory below floor: clamped to 150Mi"

# 5GB * 1.35 = 6440Mi → above cap 4800 → 4800Mi
assert_eq "$(calculate_usage_memory 5000000000 1.35 150 4800)" "4800Mi" \
    "calculate_usage_memory above cap: clamped to 4800Mi"

# Empty input → empty output
assert_eq "$(calculate_usage_memory "" 1.35 150 4800)" "" \
    "calculate_usage_memory empty input: returns empty"

# Zero input → empty output
assert_eq "$(calculate_usage_memory 0 1.35 150 4800)" "" \
    "calculate_usage_memory zero input: returns empty"

# 1GB * 1.35 = 1383Mi raw → rounded to 1400Mi
assert_eq "$(calculate_usage_memory 1073741824 1.35 150 4800)" "1400Mi" \
    "calculate_usage_memory 1GB * 1.35 = 1400Mi (rounded to 100)"

###############################################################################
# calculate_usage_cpu
###############################################################################

# 0.08 cores * 1.25 = 0.1 → 100m
assert_eq "$(calculate_usage_cpu 0.08 1.25 50 1200)" "100m" \
    "calculate_usage_cpu normal: 0.08 cores * 1.25 = 100m"

# 0.001 cores * 1.25 = 1.25m → 2m (ceil) → below floor 50 → 50m
assert_eq "$(calculate_usage_cpu 0.001 1.25 50 1200)" "50m" \
    "calculate_usage_cpu below floor: clamped to 50m"

# Empty input → empty output
assert_eq "$(calculate_usage_cpu "" 1.25 50 1200)" "" \
    "calculate_usage_cpu empty input: returns empty"

# Zero → empty
assert_eq "$(calculate_usage_cpu 0 1.25 50 1200)" "" \
    "calculate_usage_cpu zero input: returns empty"

###############################################################################
# should_upsize
###############################################################################

should_upsize "500Mi" "384Mi" "memory"
assert_eq "$?" "0" "should_upsize: 500Mi > 384Mi = true"

! should_upsize "384Mi" "384Mi" "memory"
assert_eq "$?" "0" "should_upsize: 384Mi == 384Mi = false"

! should_upsize "300Mi" "384Mi" "memory"
assert_eq "$?" "0" "should_upsize: 300Mi < 384Mi = false"

should_upsize "200m" "100m" "cpu"
assert_eq "$?" "0" "should_upsize CPU: 200m > 100m = true"

! should_upsize "100m" "200m" "cpu"
assert_eq "$?" "0" "should_upsize CPU: 100m < 200m = false"

! should_upsize "" "384Mi" "memory"
assert_eq "$?" "0" "should_upsize: empty proposed = false"

###############################################################################
# is_safe_downsize
###############################################################################

is_safe_downsize "300Mi" "400Mi"
assert_eq "$?" "0" "is_safe_downsize: 300Mi >= 200Mi (50% of 400Mi) = safe"

! is_safe_downsize "100Mi" "400Mi"
assert_eq "$?" "0" "is_safe_downsize: 100Mi < 200Mi (50% of 400Mi) = unsafe"

is_safe_downsize "200Mi" "400Mi"
assert_eq "$?" "0" "is_safe_downsize: 200Mi == 200Mi (50% of 400Mi) = safe (boundary)"

is_safe_downsize "500Mi" "400Mi"
assert_eq "$?" "0" "is_safe_downsize: 500Mi > 400Mi = safe (upsize is always safe)"

###############################################################################
# calculate_oom_response_memory
###############################################################################

assert_eq "$(calculate_oom_response_memory "384Mi" 4800)" "800Mi" \
    "calculate_oom_response_memory: 384Mi → 800Mi (768 rounded to 100)"

assert_eq "$(calculate_oom_response_memory "2400Mi" 4800)" "4800Mi" \
    "calculate_oom_response_memory: 2400Mi → 4800Mi (at cap)"

assert_eq "$(calculate_oom_response_memory "3000Mi" 4800)" "4800Mi" \
    "calculate_oom_response_memory: 3000Mi → 4800Mi (capped, not 6000)"

assert_eq "$(calculate_oom_response_memory "150Mi" 4800)" "300Mi" \
    "calculate_oom_response_memory: 150Mi → 300Mi"

# 1.5x multiplier (KSM/OpenCost OOM). 384Mi * 1.5 = 576Mi → rounded to 600Mi
assert_eq "$(calculate_oom_response_memory "384Mi" 4800 3 2)" "600Mi" \
    "calculate_oom_response_memory 1.5x: 384Mi → 600Mi"

# 1.5x at cap: 3600Mi * 1.5 = 5400Mi → capped at 4800Mi
assert_eq "$(calculate_oom_response_memory "3600Mi" 4800 3 2)" "4800Mi" \
    "calculate_oom_response_memory 1.5x: 3600Mi → 4800Mi (capped)"

# 1.5x small value: 64Mi * 1.5 = 96Mi → rounded to 100Mi
assert_eq "$(calculate_oom_response_memory "64Mi" 4800 3 2)" "100Mi" \
    "calculate_oom_response_memory 1.5x: 64Mi → 100Mi"

# Default (no multiplier args) still gives 2x
assert_eq "$(calculate_oom_response_memory "400Mi" 4800)" "800Mi" \
    "calculate_oom_response_memory default: 400Mi → 800Mi (2x)"

# Already above the cap (raised by hand): the bump keeps it instead of cutting it to the cap.
# A 16Gi Prometheus with the 8Gi cap was cut to 8Gi, which put it back into an OOM loop.
assert_eq "$(calculate_oom_response_memory "16384Mi" 8192)" "16384Mi" \
    "calculate_oom_response_memory: 16384Mi above an 8192Mi cap stays 16384Mi"
assert_eq "$(calculate_oom_response_memory "6000Mi" 4800 3 2)" "6000Mi" \
    "calculate_oom_response_memory 1.5x: 6000Mi above a 4800Mi cap stays 6000Mi"

###############################################################################
# v2.1.66: agent memory cap raised to 8192Mi
# Previous cap (4096Mi) was insufficient — 5 customer clusters were OOMing at
# the cap. Agent memory scales with metric cardinality/cost data volume, not
# just pod count. Raised to match Prometheus server cap.
###############################################################################
assert_eq "$_USAGE_CAP_AGENT_MEM" "8192" \
    "_USAGE_CAP_AGENT_MEM raised to 8192 (from 4096) in v2.1.66"

###############################################################################
# Prometheus/VictoriaMetrics memory cap raised to 12288Mi
# Clusters of ~4,000 pods peaked at the 8192Mi cap and OOM-looped; the updater
# could not raise them, and cut hand-raised memory back to the cap.
###############################################################################
assert_eq "$_USAGE_CAP_PROM_MEM" "12288" \
    "_USAGE_CAP_PROM_MEM raised to 12288 (from 8192)"

###############################################################################
# calculate_usage_memory with current memory: the cap stops raises, never cuts
###############################################################################

# Usage needs 32819Mi (24310Mi × 1.35). Without current: clamped to the cap, as before.
assert_eq "$(calculate_usage_memory "$((24310*1048576))" 1.35 150 12288)" "12288Mi" \
    "calculate_usage_memory: need above the cap, no current → cap"
# Current 20480Mi is above the cap and below the need → kept
assert_eq "$(calculate_usage_memory "$((24310*1048576))" 1.35 150 12288 "20480Mi")" "20480Mi" \
    "calculate_usage_memory: need above the cap, current 20480Mi above the cap → current kept"
# Current 20Gi written in Gi → same
assert_eq "$(calculate_usage_memory "$((24310*1048576))" 1.35 150 12288 "20Gi")" "20480Mi" \
    "calculate_usage_memory: current given as 20Gi → kept as 20480Mi"
# Current below the cap → raise stops at the cap
assert_eq "$(calculate_usage_memory "$((24310*1048576))" 1.35 150 12288 "8192Mi")" "12288Mi" \
    "calculate_usage_memory: need above the cap, current 8192Mi → cap 12288Mi"
# Need 15000Mi (11100Mi × 1.35) is above the cap but below current → the need, not the cap
assert_eq "$(calculate_usage_memory "$((11100*1048576))" 1.35 150 12288 "20480Mi")" "15000Mi" \
    "calculate_usage_memory: need 15000Mi between the cap and current 20480Mi → 15000Mi"
# Need 6800Mi (5000Mi × 1.35) is below the cap → the need, whatever current is
assert_eq "$(calculate_usage_memory "$((5000*1048576))" 1.35 150 12288 "20480Mi")" "6800Mi" \
    "calculate_usage_memory: need below the cap → need (6800Mi)"

###############################################################################
# node_fit_memory_mi / fit_cap_to_node
###############################################################################

# 15291092Ki = 14932Mi (16GiB node); 85% = 12692Mi. 7116788Ki = 6949Mi (8GiB node); 85% = 5907Mi.
assert_eq "$(node_fit_memory_mi "$(printf '7116788Ki   <none>\n15291092Ki   <none>')")" "12692" \
    "node_fit_memory_mi: largest node wins (85% of 15291092Ki = 12692Mi)"
assert_eq "$(node_fit_memory_mi "$(printf '7116788Ki   <none>\n15291092Ki   true')")" "5907" \
    "node_fit_memory_mi: cordoned node ignored (85% of 7116788Ki = 5907Mi)"
assert_eq "$(node_fit_memory_mi "16Gi   <none>")" "13926" \
    "node_fit_memory_mi: 16Gi → 13926Mi"
assert_eq "$(node_fit_memory_mi "17179869184   <none>")" "13926" \
    "node_fit_memory_mi: 17179869184 bytes → 13926Mi"
assert_eq "$(node_fit_memory_mi "")" "" \
    "node_fit_memory_mi: no nodes → empty"
assert_eq "$(node_fit_memory_mi "15291092Ki   true")" "" \
    "node_fit_memory_mi: every node cordoned → empty"
assert_eq "$(node_fit_memory_mi "<none>   <none>")" "" \
    "node_fit_memory_mi: no allocatable memory reported → empty"

assert_eq "$(fit_cap_to_node 12288 12692)" "12288" \
    "fit_cap_to_node: node fit above the cap → cap"
assert_eq "$(fit_cap_to_node 12288 5907)" "5907" \
    "fit_cap_to_node: node fit below the cap → node fit"
assert_eq "$(fit_cap_to_node 12288 "")" "12288" \
    "fit_cap_to_node: nodes unreadable → cap"
assert_eq "$(fit_cap_to_node 12288 0)" "12288" \
    "fit_cap_to_node: zero node fit → cap, never a 0Mi cap"
assert_eq "$(node_fit_memory_mi "1Mi   <none>")" "0" \
    "node_fit_memory_mi: a 1Mi node truncates to 0 (fit_cap_to_node ignores it)"

###############################################################################
# evaluate_container_sizing — usage-at-limit detection (param 16: mem_now_bytes)
###############################################################################

# Usage at 95% of limit → preemptive 1.5x bump (non-prom container like opencost)
# 800Mi limit, mem_now = 798Mi (95% = 760Mi threshold), 72h max = 579Mi
# Should bump: 800Mi * 1.5 = 1200Mi
_ual_result=$(evaluate_container_sizing "opencost" "800Mi" "100m" \
    607000000 0.05 false false false false \
    1.35 1.25 192 4800 50 1200 \
    836763238)
_ual_mem=$(echo "$_ual_result" | grep '^MEM=' | cut -d= -f2)
assert_eq "$_ual_mem" "1200Mi" \
    "usage-at-limit: 95% of 800Mi limit → 1.5x bump to 1200Mi (non-prom)"

# Usage at 95% of limit → preemptive 2x bump (prometheus container)
# 800Mi limit, mem_now = 798Mi (95% = 760Mi threshold), 72h max = 579Mi
# Should bump: 800Mi * 2 = 1600Mi
_ual_result=$(evaluate_container_sizing "prometheus-server" "800Mi" "100m" \
    607000000 0.05 false false false false \
    1.35 1.25 150 8192 50 1200 \
    836763238)
_ual_mem=$(echo "$_ual_result" | grep '^MEM=' | cut -d= -f2)
assert_eq "$_ual_mem" "1600Mi" \
    "usage-at-limit: 95% of 800Mi limit → 2x bump to 1600Mi (prometheus)"

# Usage at 80% of limit → no bump (below 90% threshold)
# 800Mi limit, mem_now = 640Mi (80% = below 720Mi threshold), 72h max = 579Mi
_ual_result=$(evaluate_container_sizing "opencost" "800Mi" "100m" \
    607000000 0.05 false false false false \
    1.35 1.25 192 4800 50 1200 \
    671088640)
_ual_mem=$(echo "$_ual_result" | grep '^MEM=' | cut -d= -f2)
assert_eq "$_ual_mem" "800Mi" \
    "usage-at-limit: 80% of 800Mi limit → no bump (below 90% threshold)"

# Usage at limit with empty mem_now_bytes → no bump (no data)
_ual_result=$(evaluate_container_sizing "opencost" "800Mi" "100m" \
    607000000 0.05 false false false false \
    1.35 1.25 192 4800 50 1200 \
    "")
_ual_mem=$(echo "$_ual_result" | grep '^MEM=' | cut -d= -f2)
assert_eq "$_ual_mem" "800Mi" \
    "usage-at-limit: empty mem_now_bytes → no bump"

test_summary
exit $?
