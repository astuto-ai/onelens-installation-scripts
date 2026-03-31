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

###############################################################################
test_summary
exit $?
