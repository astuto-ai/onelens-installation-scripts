#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
set_test_file "test-entrypoint.sh"
ROOT=$(repo_root)

ENTRYPOINT="$ROOT/entrypoint.sh"

###############################################################################
# Test 1: entrypoint.sh exists and has valid syntax
###############################################################################
assert_file_exists "$ENTRYPOINT" "entrypoint.sh exists"
syntax_check=$(bash -n "$ENTRYPOINT" 2>&1); syntax_rc=$?
assert_eq "$syntax_rc" "0" "entrypoint.sh has valid bash syntax"

###############################################################################
# Test 2: Healthcheck mode is gated by strict string comparison
###############################################################################
# The script must only activate healthcheck mode for literal "healthcheck"
hc_guard=$(grep -c 'patching_mode" = "healthcheck"' "$ENTRYPOINT" || true)
assert_gt "$hc_guard" "0" "healthcheck mode uses strict string comparison"

###############################################################################
# Test 3: Oneshot mode is the fallback (else branch)
###############################################################################
# The else branch should handle all non-healthcheck cases
else_branch=$(grep -c 'ONESHOT MODE' "$ENTRYPOINT" || true)
assert_gt "$else_branch" "0" "oneshot mode exists as fallback"

###############################################################################
# Test 4: Healthcheck mode NEVER sets patching_enabled=false
###############################################################################
# Extract the healthcheck block (between HEALTHCHECK MODE and ONESHOT MODE markers)
hc_block=$(sed -n '/HEALTHCHECK MODE/,/ONESHOT MODE/p' "$ENTRYPOINT")
hc_disable_count=$(echo "$hc_block" | grep -v '^[[:space:]]*#' | grep -c 'patching_enabled.*false' || true)
assert_eq "$hc_disable_count" "0" "healthcheck mode never sets patching_enabled=false"

###############################################################################
# Test 5: Oneshot mode DOES set patching_enabled=false on success
###############################################################################
oneshot_block=$(sed -n '/ONESHOT MODE/,$ p' "$ENTRYPOINT")
oneshot_disable_count=$(echo "$oneshot_block" | grep -c 'patching_enabled.*false' || true)
assert_gt "$oneshot_disable_count" "0" "oneshot mode sets patching_enabled=false on success"

###############################################################################
# Test 6: Healthcheck parses patching_mode from API response
###############################################################################
parse_mode=$(grep -c 'patching_mode.*API_RESPONSE.*jq' "$ENTRYPOINT" || true)
assert_gt "$parse_mode" "0" "patching_mode is parsed from API response"

###############################################################################
# Test 7: Healthcheck parses healthcheck_failures from API response
###############################################################################
parse_hcf=$(grep -c 'healthcheck_failures.*API_RESPONSE.*jq' "$ENTRYPOINT" || true)
assert_gt "$parse_hcf" "0" "healthcheck_failures is parsed from API response"

###############################################################################
# Test 8: Healthcheck checks pod readiness
###############################################################################
pod_check=$(grep -c 'kubectl get pods -n onelens-agent' "$ENTRYPOINT" || true)
assert_gt "$pod_check" "0" "healthcheck uses kubectl get pods"

###############################################################################
# Test 9: Healthcheck checks Prometheus health
###############################################################################
prom_check=$(grep -c 'prometheus.*healthy' "$ENTRYPOINT" || true)
assert_gt "$prom_check" "0" "healthcheck checks Prometheus health endpoint"

###############################################################################
# Test 10: Healthcheck checks OpenCost health
###############################################################################
oc_check=$(grep -c 'opencost.*healthz' "$ENTRYPOINT" || true)
assert_gt "$oc_check" "0" "healthcheck checks OpenCost healthz endpoint"

###############################################################################
# Test 11: Healthcheck checks Pushgateway health
###############################################################################
pgw_check=$(grep -c 'pushgateway.*healthy' "$ENTRYPOINT" || true)
assert_gt "$pgw_check" "0" "healthcheck checks Pushgateway health endpoint"

###############################################################################
# Test 12: Healthcheck checks version mismatch
###############################################################################
ver_check=$(grep -c 'current_version.*patching_version' "$ENTRYPOINT" || true)
assert_gt "$ver_check" "0" "healthcheck checks version mismatch"

###############################################################################
# Test 13: Heartbeat PUT runs every 5 min (no throttling)
###############################################################################
heartbeat_put=$(grep -c 'last_healthy_at.*ts' "$ENTRYPOINT" || true)
assert_gt "$heartbeat_put" "0" "heartbeat PUT includes last_healthy_at"

###############################################################################
# Test 15: Healthcheck sends healthcheck_failures=0 on success
###############################################################################
reset_failures=$(grep -c 'healthcheck_failures.*0' "$ENTRYPOINT" || true)
assert_gt "$reset_failures" "0" "healthcheck resets healthcheck_failures on success"

###############################################################################
# Test 15b: Healthcheck increments healthcheck_failures on failure
###############################################################################
inc_failures=$(grep -c 'NEW_FAILURES' "$ENTRYPOINT" || true)
assert_gt "$inc_failures" "0" "healthcheck increments failure counter on remediation failure"


###############################################################################
# Test 16: Backwards compatibility — job mode is unchanged
###############################################################################
job_mode=$(grep -c 'deployment_type.*=.*job' "$ENTRYPOINT" || true)
assert_gt "$job_mode" "0" "job deployment type still exists"

###############################################################################
# Test 17: curl uses --max-time for health checks (no hanging)
###############################################################################
max_time_count=$(grep -c 'max-time' "$ENTRYPOINT" || true)
assert_gt "$max_time_count" "0" "health curls use --max-time to prevent hanging"

###############################################################################
# Summary
###############################################################################
test_summary
exit $?
