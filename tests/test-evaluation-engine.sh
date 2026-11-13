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
# 400MB * 1.35 = 515Mi raw → rounded to 600Mi, current = 420Mi → upsize to 600Mi
assert_eq "$(_eval_mem "prom" "420Mi" "150m" "400000000" "0.08" "false" "false" "false" "false" 1.35 1.25 150 4800 50 1200)" \
    "600Mi" "5-min: upsize needed (600Mi > 420Mi)"

# Downsize blocked on 5-min
# 100MB * 1.35 = 129Mi → below floor 150 → 150Mi, current = 420Mi → no change
assert_eq "$(_eval_mem "prom" "420Mi" "150m" "100000000" "0.08" "false" "false" "false" "false" 1.35 1.25 150 4800 50 1200)" \
    "420Mi" "5-min: downsize blocked (150Mi < 420Mi)"

# CPU upsize
# 0.15 cores * 1.25 = 188m raw → rounded to 200m, current = 150m → upsize
assert_eq "$(_eval_cpu "prom" "420Mi" "150m" "200000000" "0.15" "false" "false" "false" "false" 1.35 1.25 150 4800 50 1200)" \
    "200m" "5-min: CPU upsize (200m > 150m)"

# CPU no change
# 0.08 cores * 1.25 = 100m, current = 150m → no change
assert_eq "$(_eval_cpu "prom" "420Mi" "150m" "200000000" "0.08" "false" "false" "false" "false" 1.35 1.25 150 4800 50 1200)" \
    "150m" "5-min: CPU no change (100m < 150m)"

###############################################################################
# 72h full evaluation (can downsize)
###############################################################################

# Downsize: gross over-provisioning override (v2.1.69)
# 200MB * 1.35 = 258Mi, current = 1771Mi. 1771/258 = 6.9x → exceeds 3x threshold.
# Override fires: proposed 258 < 50% of 1771 (886) → cut to 50% = 886 → rounded to 900Mi.
# Before v2.1.69 this was blocked ("keep current"), now it forces a 50% step-down per cycle.
assert_eq "$(_eval_mem "prom" "1771Mi" "150m" "200000000" "0.08" "false" "false" "true" "false" 1.35 1.25 150 4800 50 1200)" \
    "900Mi" "gross over-provision: 1771Mi → 900Mi (50% cut, 6.9x over actual usage)"

# Moderate downsize allowed: within 50% safety guard
# 400MB * 1.35 = 515Mi raw → rounded to 600Mi, current = 720Mi. 600Mi >= 360Mi (50% of 720) → allowed
assert_eq "$(_eval_mem "prom" "720Mi" "150m" "400000000" "0.08" "false" "false" "true" "false" 1.35 1.25 150 4800 50 1200)" \
    "600Mi" "72h eval: moderate downsize allowed (600Mi >= 50% of 720Mi)"

# Upsize on 72h eval
# 1.5GB * 1.35 = 1932Mi raw → rounded to 2000Mi, current = 720Mi → upsize
assert_eq "$(_eval_mem "prom" "720Mi" "150m" "1500000000" "0.08" "false" "false" "true" "false" 1.35 1.25 150 4800 50 1200)" \
    "2000Mi" "72h eval: upsize (2000Mi from 720Mi)"

# Safety guard: refuse if new < 50% of current (NOT gross — 400/150 = 2.7x < 3x threshold)
# 50MB * 1.35 = 65Mi → below floor 150Mi. 150Mi < 50% of 400Mi (200Mi) → blocked
# Gross override doesn't fire (2.7x < 3x) → normal full-eval safety guard blocks.
assert_eq "$(_eval_mem "prom" "400Mi" "150m" "50000000" "0.08" "false" "false" "true" "false" 1.35 1.25 150 4800 50 1200)" \
    "400Mi" "72h eval: safety guard blocks (150Mi < 200Mi = 50% of 400Mi, 2.7x < 3x)"

# Gross over-provisioning on 5-min check (NOT full eval): forces downsize
# 84MB * 1.35 = 108Mi → floor 384Mi. Current 8192Mi / 384Mi = 21x → override fires.
# 384 < 50% of 8192 (4096) → cut to 50% = 4096 → rounded to 4100Mi.
assert_eq "$(_eval_mem "test" "8192Mi" "600m" "88080384" "0.1" "false" "false" "false" "false" 1.35 1.25 384 8192 50 1200)" \
    "4100Mi" "5-min gross override: 8192Mi → 4100Mi (50% cut, 21x over usage)"

# Not grossly over-provisioned on 5-min (2x): normal upsize-only → no change
# 400MB * 1.35 = 515Mi → floor stays at 515Mi. Current 800Mi / 515Mi = 1.6x < 3x → no override.
assert_eq "$(_eval_mem "test" "800Mi" "200m" "419430400" "0.1" "false" "false" "false" "false" 1.35 1.25 384 8192 50 1200)" \
    "800Mi" "5-min no override: 800Mi stays (1.6x < 3x threshold)"

# CPU downsize on 72h eval
# 0.04 cores * 1.25 = 50m, current = 150m → downsize to 50m
assert_eq "$(_eval_cpu "prom" "420Mi" "150m" "200000000" "0.04" "false" "false" "true" "false" 1.35 1.25 150 4800 50 1200)" \
    "50m" "72h eval: CPU downsize (50m from 150m)"

###############################################################################
# OOM detection
###############################################################################

# OOM just detected: double memory
assert_eq "$(_eval_mem "prom" "384Mi" "150m" "200000000" "0.08" "true" "false" "false" "false" 1.35 1.25 150 4800 50 1200)" \
    "800Mi" "OOM now: double (384Mi → 800Mi, 768 rounded to 100)"

# OOM at cap
assert_eq "$(_eval_mem "prom" "2400Mi" "150m" "200000000" "0.08" "true" "false" "false" "false" 1.35 1.25 150 4800 50 1200)" \
    "4800Mi" "OOM now: double at cap (2400Mi → 4800Mi)"

# OOM CPU unchanged on OOM (only memory doubles)
assert_eq "$(_eval_cpu "prom" "384Mi" "150m" "200000000" "0.08" "true" "false" "false" "false" 1.35 1.25 150 4800 50 1200)" \
    "150m" "OOM now: CPU unchanged"

# KSM OOM: 1.5x (not 2x). 384Mi * 1.5 = 576Mi → rounded to 600Mi
assert_eq "$(_eval_mem "kube-state-metrics" "384Mi" "150m" "200000000" "0.08" "true" "false" "false" "false" 1.35 1.25 64 4800 50 1200)" \
    "600Mi" "OOM now KSM: 1.5x (384Mi → 600Mi)"

# OpenCost OOM: 1.5x. 768Mi * 1.5 = 1152Mi → rounded to 1200Mi
assert_eq "$(_eval_mem "opencost" "768Mi" "150m" "200000000" "0.08" "true" "false" "false" "false" 1.35 1.25 192 4800 50 1200)" \
    "1200Mi" "OOM now OpenCost: 1.5x (768Mi → 1200Mi)"

# KSM OOM at cap: 3600Mi * 1.5 = 5400Mi → capped at 4800Mi
assert_eq "$(_eval_mem "kube-state-metrics" "3600Mi" "150m" "200000000" "0.08" "true" "false" "false" "false" 1.35 1.25 64 4800 50 1200)" \
    "4800Mi" "OOM now KSM: 1.5x capped (3600Mi → 4800Mi)"

# OOM recent (hold period): no downsize, upsize allowed
assert_eq "$(_eval_mem "prom" "768Mi" "150m" "200000000" "0.08" "false" "true" "false" "false" 1.35 1.25 150 4800 50 1200)" \
    "768Mi" "OOM recent: hold (300Mi < 768Mi, no downsize)"

# OOM recent + upsize needed
# 600MB * 1.35 = 773Mi raw → rounded to 800Mi, current = 768Mi → upsize
assert_eq "$(_eval_mem "prom" "768Mi" "150m" "600000000" "0.08" "false" "true" "false" "false" 1.35 1.25 150 4800 50 1200)" \
    "800Mi" "OOM recent: upsize allowed (800Mi > 768Mi)"

###############################################################################
# First run
###############################################################################

# First run: hold, no OOM reaction, no downsize
assert_eq "$(_eval_mem "prom" "420Mi" "150m" "200000000" "0.08" "true" "false" "false" "true" 1.35 1.25 150 4800 50 1200)" \
    "420Mi" "First run: OOM ignored, hold current"

# First run: upsize still allowed
# 400MB * 1.35 = 515Mi raw → rounded to 600Mi > 420Mi → upsize
assert_eq "$(_eval_mem "prom" "420Mi" "150m" "400000000" "0.08" "false" "false" "false" "true" 1.35 1.25 150 4800 50 1200)" \
    "600Mi" "First run: upsize allowed (600Mi > 420Mi)"

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
    "500Mi" "Fixed: OOM → 1.25x (384Mi → 500Mi, 480 rounded to 100)"

###############################################################################
# calculate_wal_oom_memory
###############################################################################
echo ""
echo "--- calculate_wal_oom_memory ---"

# 1.5x normal: 400Mi → 600Mi
assert_eq "$(calculate_wal_oom_memory "400Mi" 4800)" "600Mi" "WAL OOM: 400Mi × 1.5 = 600Mi"

# At cap boundary: 3600Mi → 4800Mi (capped)
assert_eq "$(calculate_wal_oom_memory "3600Mi" 4800)" "4800Mi" "WAL OOM: 3600Mi × 1.5 = 5400Mi → capped at 4800Mi"

# Already at cap: 4800Mi → 4800Mi (no change)
assert_eq "$(calculate_wal_oom_memory "4800Mi" 4800)" "4800Mi" "WAL OOM: already at cap (4800Mi → 4800Mi)"

# Small value: 150Mi → 225Mi
assert_eq "$(calculate_wal_oom_memory "150Mi" 4800)" "225Mi" "WAL OOM: 150Mi × 1.5 = 225Mi"

# Convergence chain: 600→900
assert_eq "$(calculate_wal_oom_memory "600Mi" 4800)" "900Mi" "WAL OOM chain: 600Mi → 900Mi"

# Convergence chain: 900→1350
assert_eq "$(calculate_wal_oom_memory "900Mi" 4800)" "1350Mi" "WAL OOM chain: 900Mi → 1350Mi"

# Already above the cap: kept, not cut to the cap
assert_eq "$(calculate_wal_oom_memory "16384Mi" 8192)" "16384Mi" "WAL OOM: 16384Mi above an 8192Mi cap stays 16384Mi"

###############################################################################
# Memory already above the cap (raised by hand) is never lowered by a bump
###############################################################################
echo ""
echo "--- above the cap ---"

# A 16Gi Prometheus with the 8Gi cap, peaking at 16017Mi: both bump paths used to return the cap
# (8192Mi), halving it and putting it back into an OOM loop.
assert_eq "$(_eval_mem "prometheus-server" "16384Mi" "2000m" "$((16017*1048576))" "1.5" "true" "false" "false" "false" 1.3 1.3 420 8192 50 1200)" \
    "16384Mi" "OOM now, 16384Mi above an 8192Mi cap: kept"
assert_eq "$(_eval_mem "prometheus-server" "16384Mi" "2000m" "$((16017*1048576))" "1.5" "false" "false" "false" "false" 1.3 1.3 420 8192 50 1200 "$((16017*1048576))")" \
    "16384Mi" "usage at 98% of 16384Mi above an 8192Mi cap: kept"
assert_eq "$(_eval_mem "opencost" "6000Mi" "350m" "$((5900*1048576))" "0.3" "true" "false" "false" "false" 1.3 1.3 192 4800 100 1200)" \
    "6000Mi" "OpenCost OOM at 6000Mi above a 4800Mi cap: kept"

# Full evaluation used to propose the cap and cut memory above it: a Prometheus raised to 12Gi
# went back to 8Gi and OOM-looped again. Usage needing more than the cap now keeps current.
assert_eq "$(_eval_mem "prometheus-server" "20480Mi" "2000m" "$((24310*1048576))" "1.5" "false" "false" "true" "false" 1.35 1.25 150 12288 50 1200)" \
    "20480Mi" "full eval, 20480Mi above a 12288Mi cap, usage needs 32819Mi: kept"
assert_eq "$(_eval_mem "prometheus-server" "20480Mi" "2000m" "$((11100*1048576))" "1.5" "false" "false" "true" "false" 1.35 1.25 150 12288 50 1200)" \
    "15000Mi" "full eval, 20480Mi above a 12288Mi cap, usage needs 15000Mi: lowered to the need, not the cap"

###############################################################################
# 12288Mi cap: Prometheus held at 8192Mi can now be raised
###############################################################################
echo ""
echo "--- 12288Mi cap ---"

# 8Gi Prometheus peaking at 8182Mi (7.99GiB): 8182 × 1.35 = 11046 → 11100Mi on a 5-min check
assert_eq "$(_eval_mem "prometheus-server" "8192Mi" "600m" "$((8182*1048576))" "0.5" "false" "false" "false" "false" 1.35 1.25 150 "$_USAGE_CAP_PROM_MEM" 50 1200)" \
    "11100Mi" "5-min: 8192Mi peaking at 8182Mi → 11100Mi"
# OOM now: 2x, capped at 12288Mi
assert_eq "$(_eval_mem "prometheus-server" "8192Mi" "600m" "" "" "true" "false" "false" "false" 1.35 1.25 150 "$_USAGE_CAP_PROM_MEM" 50 1200)" \
    "12288Mi" "OOM now: 8192Mi → 12288Mi (2x, capped)"
# Crash-loop retry after the upgrade: 1.5x, capped at 12288Mi
assert_eq "$(calculate_wal_oom_memory "8192Mi" "$_USAGE_CAP_PROM_MEM")" "12288Mi" \
    "WAL OOM retry: 8192Mi → 12288Mi"

###############################################################################
# Node fit lowers the cap for raises, never cuts current memory
###############################################################################
echo ""
echo "--- node fit ---"

# 8GiB nodes: node fit 5907Mi. An OOM bump from 4096Mi stops there instead of an unschedulable 8192Mi.
_fit_cap=$(fit_cap_to_node "$_USAGE_CAP_PROM_MEM" 5907)
assert_eq "$(_eval_mem "prometheus-server" "4096Mi" "600m" "" "" "true" "false" "false" "false" 1.35 1.25 150 "$_fit_cap" 50 1200)" \
    "5907Mi" "OOM now on 8GiB nodes: 4096Mi → 5907Mi (node fit)"
# Already above the node fit: an OOM bump keeps it
assert_eq "$(_eval_mem "prometheus-server" "8192Mi" "600m" "" "" "true" "false" "false" "false" 1.35 1.25 150 "$_fit_cap" 50 1200)" \
    "8192Mi" "OOM now, 8192Mi above a 5907Mi node fit: kept"
# Already above the node fit, full eval with usage needing more: kept
assert_eq "$(_eval_mem "prometheus-server" "8192Mi" "600m" "$((8182*1048576))" "0.5" "false" "false" "true" "false" 1.35 1.25 150 "$_fit_cap" 50 1200)" \
    "8192Mi" "full eval, 8192Mi above a 5907Mi node fit, usage needs 11046Mi: kept"

# patching.sh: the node fit is read once, before any raise, and every memory raise uses it
PATCHING="$(repo_root)/src/patching.sh"
fit_line=$(grep -n '^NODE_FIT_MEM_MI=\$(node_fit_memory_mi' "$PATCHING" | cut -d: -f1)
first_use=$(grep -n 'fit_cap_to_node .*\$NODE_FIT_MEM_MI' "$PATCHING" | head -1 | cut -d: -f1)
assert_eq "$([ -n "$fit_line" ] && [ -n "$first_use" ] && [ "$fit_line" -lt "$first_use" ] && echo yes || echo no)" "yes" \
    "patching.sh reads the node fit before its first use"
assert_eq "$(grep -c 'mem_cap=\$(fit_cap_to_node "\$mem_cap" "\$NODE_FIT_MEM_MI")' "$PATCHING")" "1" \
    "usage-based sizing (all components) caps raises at the node fit"
assert_eq "$(grep -c '_agent_cap=\$(fit_cap_to_node "\$_USAGE_CAP_AGENT_MEM" "\$NODE_FIT_MEM_MI")' "$PATCHING")" "1" \
    "agent OOM bump caps at the node fit"
assert_eq "$(grep -c 'cap=\$(fit_cap_to_node "\$_USAGE_CAP_\(PROM\|KSM\|OPENCOST\)_MEM" "\$NODE_FIT_MEM_MI")' "$PATCHING")" "4" \
    "post-upgrade retry bumps (Prometheus, VictoriaMetrics, KSM, OpenCost) cap at the node fit"
assert_eq "$(grep -cE 'cap="\$_USAGE_CAP_[A-Z]+_MEM"' "$PATCHING")" "0" \
    "no memory bump uses a cap without the node fit"

###############################################################################
test_summary
exit $?
