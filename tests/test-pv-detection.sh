#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
set_test_file "test-pv-detection.sh"
ROOT=$(repo_root)

PATCHING="$ROOT/src/patching.sh"

###############################################################################
# Test 1: PV check captures stderr (2>&1) instead of discarding it
###############################################################################
# The old bug: `kubectl get pv ... 2>/dev/null` silently discarded RBAC errors,
# making every PV look "gone" on clusters with broken ClusterRoleBindings.
pv_check_captures_stderr=$(grep -c 'kubectl get pv.*2>&1' "$PATCHING" || true)
pv_check_discards_stderr=$(grep 'PV_CHECK_RESULT=.*kubectl get pv' "$PATCHING" | grep -c '2>/dev/null' || true)
assert_gt "$pv_check_captures_stderr" "0" "PV existence check captures stderr (2>&1)"
assert_eq "$pv_check_discards_stderr" "0" "PV existence check does NOT discard stderr on the initial PV lookup"

###############################################################################
# Test 2: RBAC errors are detected and skip PV health check
###############################################################################
rbac_check=$(grep -c 'forbidden|unauthorized' "$PATCHING" || true)
assert_gt "$rbac_check" "0" "PV check tests for forbidden/unauthorized in kubectl output"

rbac_skip_msg=$(grep -c 'Skipping PV health check.*RBAC' "$PATCHING" || true)
assert_gt "$rbac_skip_msg" "0" "RBAC detection logs skip message"

###############################################################################
# Test 3: RBAC branch comes BEFORE the "PV gone" branch
###############################################################################
# The if/elif structure must check RBAC first, then not-found, then PV exists.
# Extract the line numbers to verify ordering.
rbac_line=$(grep -n 'forbidden|unauthorized' "$PATCHING" | head -1 | cut -d: -f1)
notfound_line=$(grep -n 'not found|error' "$PATCHING" | head -1 | cut -d: -f1)
if [ -n "$rbac_line" ] && [ -n "$notfound_line" ]; then
    assert_gt "$notfound_line" "$rbac_line" "RBAC check (line $rbac_line) comes before not-found check (line $notfound_line)"
fi

###############################################################################
# Test 4: "PV gone" branch checks for empty result OR "not found"
###############################################################################
# Must handle both: empty output (timeout) and explicit "not found" error.
pv_gone_empty=$(grep -c '\-z "\$PV_CHECK_RESULT"' "$PATCHING" || true)
assert_gt "$pv_gone_empty" "0" "PV gone branch checks for empty result"

pv_gone_notfound=$(grep -c 'not found|error from server' "$PATCHING" || true)
assert_gt "$pv_gone_notfound" "0" "PV gone branch checks for 'not found' or 'error from server' in output"

###############################################################################
# Test 5: Pod age dedup guard exists before restart
###############################################################################
# The restart-on-cached-VFS path must check pod age before deleting the pod.
age_check=$(grep -c 'startTime' "$PATCHING" || true)
assert_gt "$age_check" "0" "Pod age check reads startTime before restart"

age_threshold=$(grep -c '600' "$PATCHING" || true)
assert_gt "$age_threshold" "0" "Pod age threshold (600s) is used"

skip_restart_msg=$(grep -c 'Skipping PV restart.*already validated' "$PATCHING" || true)
assert_gt "$skip_restart_msg" "0" "Age dedup guard logs skip message"

###############################################################################
# Test 6: Pod age check uses portable date command
###############################################################################
# Must work on GNU (Linux, where patching runs) and BSD (macOS, for testing).
# Pattern: try `date -d` first (GNU), fall back to `date -j -f` (BSD).
gnu_date=$(grep -c 'date -d' "$PATCHING" || true)
bsd_date=$(grep -c 'date.*-j.*-f' "$PATCHING" || true)
assert_gt "$gnu_date" "0" "Pod age uses GNU date -d for Linux"
assert_gt "$bsd_date" "0" "Pod age falls back to BSD date -j -f for macOS"

###############################################################################
# Test 7: Pod name and status extracted from single kubectl call
###############################################################################
# The old bug: two separate `kubectl get pods` calls could return data from
# different pod generations if a pod restarted between calls.
# After the restart+sleep block, there must be exactly ONE kubectl get pods call
# that feeds both name and status extraction.

# Extract the PV restart validation block specifically (between "surface volume failure"
# and "No prometheus-server pod found after restart") — avoid matching the earlier
# pod restart block at ~line 472 which is unrelated.
restart_block=$(sed -n '/surface volume failure/,/No prometheus-server pod found after restart/p' "$PATCHING")

# Count kubectl get pods calls in that block (should be 1: the single-call pattern)
kubectl_calls=$(echo "$restart_block" | grep -c 'kubectl get pods' || true)
assert_eq "$kubectl_calls" "1" "Post-restart validation uses single kubectl get pods call"

# Verify the single call stores the full line, then extracts name and status
pod_line_var=$(echo "$restart_block" | grep -c '_pod_line=' || true)
assert_gt "$pod_line_var" "0" "Single kubectl output stored in _pod_line variable"

name_from_line=$(echo "$restart_block" | grep -c '_new_pod_name=.*_pod_line' || true)
status_from_line=$(echo "$restart_block" | grep -c '_new_pod_status=.*_pod_line' || true)
assert_gt "$name_from_line" "0" "Pod name extracted from _pod_line"
assert_gt "$status_from_line" "0" "Pod status extracted from _pod_line"

###############################################################################
# Test 8: Pod restart is gated behind skip_restart flag
###############################################################################
# The actual `kubectl delete pod` must only run when _skip_restart is false.
skip_flag_check=$(grep -c '_skip_restart.*false' "$PATCHING" || true)
assert_gt "$skip_flag_check" "0" "_skip_restart flag controls pod restart"

# The delete pod command must be inside the skip_restart=false guard.
# Extract lines between the guard check and the end of the restart block.
guard_block=$(sed -n '/skip_restart.*=.*"false"/,/No prometheus-server pod found after restart/p' "$PATCHING")
delete_in_block=$(echo "$guard_block" | grep -c 'kubectl delete pod' || true)
assert_gt "$delete_in_block" "0" "kubectl delete pod is inside the _skip_restart=false guard"

###############################################################################
# Test 9: PV_CHECK_RESULT variable is used (not old PV_EXISTS for initial check)
###############################################################################
# The initial kubectl get pv must go into PV_CHECK_RESULT, not PV_EXISTS.
check_result_var=$(grep 'kubectl get pv.*--no-headers.*2>&1' "$PATCHING" | grep -c 'PV_CHECK_RESULT=' || true)
assert_gt "$check_result_var" "0" "kubectl get pv output goes to PV_CHECK_RESULT (not PV_EXISTS)"

###############################################################################
# Test 10: Awk extracts full line (not just $1) in single-call pattern
###############################################################################
# The awk in the single kubectl call must print the full line, not a single field.
# The awk feeding _pod_line must use {print; exit} (full line), not {print $1; exit} (field only).
# The assignment spans two lines (kubectl \ | awk), so grep the awk line after _pod_line=.
awk_full_line=$(echo "$restart_block" | grep -A1 '_pod_line=.*kubectl' | grep -c '{print; exit}' || true)
assert_gt "$awk_full_line" "0" "Awk prints full line (not just \$1) for atomic extraction"

###############################################################################
# Test 11: Post-restart auto-recovers when PV is gone (no "skipping" message)
###############################################################################
# The old behavior said "may be slow startup, skipping auto-recovery" when pod
# was not Running but no FailedMount events existed. The fix: since PV is
# confirmed gone, auto-recover regardless of mount events.
skip_msg=$(grep -c 'may be slow startup.*Skipping auto-recovery' "$PATCHING" || true)
assert_eq "$skip_msg" "0" "No 'slow startup skipping' message — auto-recovery proceeds when PV is gone"

pv_confirmed_msg=$(grep -c 'PV is confirmed missing and pod did not recover' "$PATCHING" || true)
assert_gt "$pv_confirmed_msg" "0" "Auto-recovery proceeds when PV confirmed missing and pod not Running"

# Verify the auto-recovery call exists in both the mount-events path AND the no-events path
recover_block=$(sed -n '/Volume mount failure confirmed/,/No prometheus-server pod found/p' "$PATCHING")
recover_calls=$(echo "$recover_block" | grep -c '_auto_recover_pvc' || true)
assert_eq "$recover_calls" "2" "Auto-recovery called in both mount-events and no-events paths"

###############################################################################
# Test 12: Syntax check — src/patching.sh has valid bash syntax
###############################################################################
syntax_check=$(bash -n "$PATCHING" 2>&1); syntax_rc=$?
assert_eq "$syntax_rc" "0" "src/patching.sh has valid bash syntax after PV detection changes"

###############################################################################
test_summary
