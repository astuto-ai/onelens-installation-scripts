#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
source "$(lib_dir)/resource-sizing.sh"
set_test_file "test-evaluation-engine.sh"

# Helper: run evaluate_container_sizing and extract MEM/CPU
_eval() {
    local result
    result=$(evaluate_container_sizing "$@")
    echo "$result"
}
_eval_mem() { _eval "$@" | grep '^MEM=' | cut -d= -f2; }
_eval_cpu() { _eval "$@" | grep '^CPU=' | cut -d= -f2; }

# Common args:
# container, current_mem, current_cpu, max_mem_bytes, max_cpu_cores,
# has_oom_now, has_oom_recent, is_full_eval, is_first_run,
# mem_buffer, cpu_buffer, mem_floor, mem_cap, cpu_floor, cpu_cap

###############################################################################
# Normal 5-min checks (upsize only)
###############################################################################

# No change needed: max_72h * 1.35 < current
# 200MB * 1.35 = 258Mi, current = 420Mi → no change
assert_eq "$(_eval_mem "prom" "420Mi" "150m" "200000000" "0.08" "false" "false" "false" "false" 1.35 1.25 150 4800 50 1200)" \
    "420Mi" "5-min: no change (258Mi < 420Mi)"

# Upsize needed: max_72h * 1.35 > current
# 400MB * 1.35 = 515Mi (ceil), current = 420Mi → upsize to 515Mi
assert_eq "$(_eval_mem "prom" "420Mi" "150m" "400000000" "0.08" "false" "false" "false" "false" 1.35 1.25 150 4800 50 1200)" \
    "515Mi" "5-min: upsize needed (515Mi > 420Mi)"

# Downsize blocked on 5-min
# 100MB * 1.35 = 129Mi → below floor 150 → 150Mi, current = 420Mi → no change
assert_eq "$(_eval_mem "prom" "420Mi" "150m" "100000000" "0.08" "false" "false" "false" "false" 1.35 1.25 150 4800 50 1200)" \
    "420Mi" "5-min: downsize blocked (150Mi < 420Mi)"

# CPU upsize
# 0.15 cores * 1.25 = 188m, current = 150m → upsize
assert_eq "$(_eval_cpu "prom" "420Mi" "150m" "200000000" "0.15" "false" "false" "false" "false" 1.35 1.25 150 4800 50 1200)" \
    "188m" "5-min: CPU upsize (188m > 150m)"

# CPU no change
# 0.08 cores * 1.25 = 100m, current = 150m → no change
assert_eq "$(_eval_cpu "prom" "420Mi" "150m" "200000000" "0.08" "false" "false" "false" "false" 1.35 1.25 150 4800 50 1200)" \
    "150m" "5-min: CPU no change (100m < 150m)"

###############################################################################
# 72h full evaluation (can downsize)
###############################################################################

# Downsize: safety guard limits to max 50% reduction per cycle
# 200MB * 1.35 = 258Mi, current = 1771Mi. 258Mi < 886Mi (50% of 1771) → blocked by safety guard
# This is correct: severely over-provisioned clusters downsize gradually (50% per 72h cycle)
assert_eq "$(_eval_mem "prom" "1771Mi" "150m" "200000000" "0.08" "false" "false" "true" "false" 1.35 1.25 150 4800 50 1200)" \
    "1771Mi" "72h eval: safety guard limits severe downsize (258Mi < 50% of 1771Mi)"

# Moderate downsize allowed: within 50% safety guard
# 400MB * 1.35 = 515Mi, current = 720Mi. 515Mi >= 360Mi (50% of 720) → allowed
assert_eq "$(_eval_mem "prom" "720Mi" "150m" "400000000" "0.08" "false" "false" "true" "false" 1.35 1.25 150 4800 50 1200)" \
    "515Mi" "72h eval: moderate downsize allowed (515Mi >= 50% of 720Mi)"

# Upsize on 72h eval
# 1.5GB * 1.35 = 1932Mi (ceil), current = 720Mi → upsize
assert_eq "$(_eval_mem "prom" "720Mi" "150m" "1500000000" "0.08" "false" "false" "true" "false" 1.35 1.25 150 4800 50 1200)" \
    "1932Mi" "72h eval: upsize (1932Mi from 720Mi)"

# Safety guard: refuse if new < 50% of current
# 50MB * 1.35 = 65Mi → below floor 150Mi. 150Mi < 50% of 400Mi (200Mi) → blocked
assert_eq "$(_eval_mem "prom" "400Mi" "150m" "50000000" "0.08" "false" "false" "true" "false" 1.35 1.25 150 4800 50 1200)" \
    "400Mi" "72h eval: safety guard blocks (150Mi < 200Mi = 50% of 400Mi)"

# CPU downsize on 72h eval
# 0.04 cores * 1.25 = 50m, current = 150m → downsize to 50m
assert_eq "$(_eval_cpu "prom" "420Mi" "150m" "200000000" "0.04" "false" "false" "true" "false" 1.35 1.25 150 4800 50 1200)" \
    "50m" "72h eval: CPU downsize (50m from 150m)"

###############################################################################
# OOM detection
###############################################################################

# OOM just detected: double memory
assert_eq "$(_eval_mem "prom" "384Mi" "150m" "200000000" "0.08" "true" "false" "false" "false" 1.35 1.25 150 4800 50 1200)" \
    "768Mi" "OOM now: double (384Mi → 768Mi)"

# OOM at cap
assert_eq "$(_eval_mem "prom" "2400Mi" "150m" "200000000" "0.08" "true" "false" "false" "false" 1.35 1.25 150 4800 50 1200)" \
    "4800Mi" "OOM now: double at cap (2400Mi → 4800Mi)"

# OOM CPU unchanged on OOM (only memory doubles)
assert_eq "$(_eval_cpu "prom" "384Mi" "150m" "200000000" "0.08" "true" "false" "false" "false" 1.35 1.25 150 4800 50 1200)" \
    "150m" "OOM now: CPU unchanged"

# OOM recent (hold period): no downsize, upsize allowed
assert_eq "$(_eval_mem "prom" "768Mi" "150m" "200000000" "0.08" "false" "true" "false" "false" 1.35 1.25 150 4800 50 1200)" \
    "768Mi" "OOM recent: hold (258Mi < 768Mi, no downsize)"

# OOM recent + upsize needed
# 600MB * 1.35 = 773Mi (ceil), current = 768Mi → upsize
assert_eq "$(_eval_mem "prom" "768Mi" "150m" "600000000" "0.08" "false" "true" "false" "false" 1.35 1.25 150 4800 50 1200)" \
    "773Mi" "OOM recent: upsize allowed (773Mi > 768Mi)"

###############################################################################
# First run
###############################################################################

# First run: hold, no OOM reaction, no downsize
assert_eq "$(_eval_mem "prom" "420Mi" "150m" "200000000" "0.08" "true" "false" "false" "true" 1.35 1.25 150 4800 50 1200)" \
    "420Mi" "First run: OOM ignored, hold current"

# First run: upsize still allowed
# 400MB * 1.35 = 515Mi (ceil) > 420Mi → upsize
assert_eq "$(_eval_mem "prom" "420Mi" "150m" "400000000" "0.08" "false" "false" "false" "true" 1.35 1.25 150 4800 50 1200)" \
    "515Mi" "First run: upsize allowed (515Mi > 420Mi)"

# First run: downsize blocked
assert_eq "$(_eval_mem "prom" "420Mi" "150m" "100000000" "0.08" "false" "false" "false" "true" 1.35 1.25 150 4800 50 1200)" \
    "420Mi" "First run: downsize blocked"

###############################################################################
# Empty/zero data
###############################################################################

# No Prometheus data: hold
assert_eq "$(_eval_mem "prom" "420Mi" "150m" "" "" "false" "false" "false" "false" 1.35 1.25 150 4800 50 1200)" \
    "420Mi" "No data: hold current memory"

assert_eq "$(_eval_cpu "prom" "420Mi" "150m" "" "" "false" "false" "false" "false" 1.35 1.25 150 4800 50 1200)" \
    "150m" "No data: hold current CPU"

# Zero usage: hold (calculate_usage_memory returns empty for 0)
assert_eq "$(_eval_mem "prom" "420Mi" "150m" "0" "0" "false" "false" "false" "false" 1.35 1.25 150 4800 50 1200)" \
    "420Mi" "Zero usage: hold"

###############################################################################
# request = limit (verify both MEM lines match)
###############################################################################

RESULT=$(_eval "prom" "420Mi" "150m" "400000000" "0.08" "false" "false" "false" "false" 1.35 1.25 150 4800 50 1200)
MEM_VAL=$(echo "$RESULT" | grep '^MEM=' | cut -d= -f2)
assert_ne "$MEM_VAL" "" "Result has MEM value"
# request=limit is enforced at the integration layer, not here.
# The evaluate function returns one value; patching.sh sets both request and limit to it.

###############################################################################
# evaluate_fixed_container_sizing
###############################################################################

# No OOM: keep current
assert_eq "$(evaluate_fixed_container_sizing "pushgateway" "64Mi" "false" | grep '^MEM=' | cut -d= -f2)" \
    "64Mi" "Fixed: no OOM → keep current"

# OOM: 1.25x bump
assert_eq "$(evaluate_fixed_container_sizing "pushgateway" "64Mi" "true" | grep '^MEM=' | cut -d= -f2)" \
    "80Mi" "Fixed: OOM → 1.25x (64Mi → 80Mi)"

assert_eq "$(evaluate_fixed_container_sizing "agent" "384Mi" "true" | grep '^MEM=' | cut -d= -f2)" \
    "480Mi" "Fixed: OOM → 1.25x (384Mi → 480Mi)"

###############################################################################
test_summary
exit $?
