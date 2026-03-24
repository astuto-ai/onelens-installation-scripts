#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
source "$(lib_dir)/resource-sizing.sh"
set_test_file "test-sizing-state.sh"

FIXTURES="$(fixtures_dir)"

###############################################################################
# parse_sizing_state
###############################################################################

# Empty ConfigMap
parse_sizing_state "$(cat "$FIXTURES/sizing-state-empty.json")" || true
assert_eq "$STATE_LAST_FULL_EVAL" "" "parse empty ConfigMap: STATE_LAST_FULL_EVAL is empty"
assert_eq "$STATE_LAST_OOM_prometheus_server" "" "parse empty ConfigMap: no OOM for prometheus"
assert_eq "$STATE_LAST_OOM_pushgateway" "" "parse empty ConfigMap: no OOM for pushgateway"

# Normal state (48h ago eval, no OOM)
parse_sizing_state "$(cat "$FIXTURES/sizing-state-normal.json")"
assert_ne "$STATE_LAST_FULL_EVAL" "" "parse normal: STATE_LAST_FULL_EVAL is set"
assert_contains "$STATE_LAST_FULL_EVAL" "2026-03-14" "parse normal: eval date is 2026-03-14"
assert_eq "$STATE_LAST_OOM_prometheus_server" "" "parse normal: no OOM for prometheus"
assert_eq "$STATE_LAST_OOM_pushgateway" "" "parse normal: no OOM for pushgateway"

# OOM recent state
parse_sizing_state "$(cat "$FIXTURES/sizing-state-oom-recent.json")"
assert_ne "$STATE_LAST_OOM_prometheus_server" "" "parse OOM recent: prometheus OOM is set"
assert_contains "$STATE_LAST_OOM_prometheus_server" "2026-03-14" "parse OOM recent: OOM date"
assert_eq "$STATE_LAST_OOM_kube_state_metrics" "" "parse OOM recent: KSM has no OOM"
assert_ne "$STATE_LAST_OOM_pushgateway" "" "parse OOM recent: pushgateway OOM is set"
assert_contains "$STATE_LAST_OOM_pushgateway" "2026-03-14" "parse OOM recent: pushgateway OOM date"

# Invalid JSON
parse_sizing_state "" || true
assert_eq "$STATE_LAST_FULL_EVAL" "" "parse invalid: empty JSON returns empty state"
assert_eq "$STATE_LAST_OOM_pushgateway" "" "parse invalid: pushgateway OOM is empty"

parse_sizing_state "not-json" || true
assert_eq "$STATE_LAST_FULL_EVAL" "" "parse invalid: bad JSON returns empty state"

###############################################################################
# is_oom_recent
###############################################################################

# Recent OOM (use a timestamp from 2 days ago dynamically)
TWO_DAYS_AGO=$(date -u -v-2d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "2 days ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
if [ -n "$TWO_DAYS_AGO" ]; then
    assert_exit_code 0 "is_oom_recent: 2 days ago within 7 day window" is_oom_recent "$TWO_DAYS_AGO" 7
fi

# Stale OOM (10 days ago)
TEN_DAYS_AGO=$(date -u -v-10d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "10 days ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
if [ -n "$TEN_DAYS_AGO" ]; then
    assert_exit_code 1 "is_oom_recent: 10 days ago outside 7 day window" is_oom_recent "$TEN_DAYS_AGO" 7
fi

# Empty timestamp
assert_exit_code 1 "is_oom_recent: empty timestamp = not recent" is_oom_recent "" 7

###############################################################################
# is_full_eval_due
###############################################################################

# 73h ago — should be due
SEVENTY_THREE_H_AGO=$(date -u -v-73H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "73 hours ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
if [ -n "$SEVENTY_THREE_H_AGO" ]; then
    assert_exit_code 0 "is_full_eval_due: 73h ago = due" is_full_eval_due "$SEVENTY_THREE_H_AGO" 72
fi

# 48h ago — not due
FORTY_EIGHT_H_AGO=$(date -u -v-48H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "48 hours ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
if [ -n "$FORTY_EIGHT_H_AGO" ]; then
    assert_exit_code 1 "is_full_eval_due: 48h ago = not due" is_full_eval_due "$FORTY_EIGHT_H_AGO" 72
fi

# Empty timestamp — NOT due (first run, ConfigMap just created with now)
assert_exit_code 1 "is_full_eval_due: empty = not due (first run)" is_full_eval_due "" 72

###############################################################################
# build_sizing_state_patch
###############################################################################

PATCH=$(build_sizing_state_patch "2026-03-15T06:00:00Z" "2026-03-15T04:00:00Z" "" "" "2026-03-15T05:00:00Z")
assert_contains "$PATCH" "last_full_evaluation" "build_sizing_state_patch: has eval key"
assert_contains "$PATCH" "2026-03-15T06:00:00Z" "build_sizing_state_patch: has eval timestamp"
assert_contains "$PATCH" "prometheus-server.last_oom_at" "build_sizing_state_patch: has prom OOM key"
assert_contains "$PATCH" "2026-03-15T04:00:00Z" "build_sizing_state_patch: has prom OOM timestamp"
assert_contains "$PATCH" "pushgateway.last_oom_at" "build_sizing_state_patch: has pushgateway OOM key"
assert_contains "$PATCH" "2026-03-15T05:00:00Z" "build_sizing_state_patch: has pushgateway OOM timestamp"

# Verify it's valid JSON
echo "$PATCH" | jq -e . >/dev/null 2>&1
assert_eq "$?" "0" "build_sizing_state_patch: output is valid JSON"

# Empty pushgateway OOM still produces valid JSON
PATCH_EMPTY_PGW=$(build_sizing_state_patch "2026-03-15T06:00:00Z" "" "" "" "")
echo "$PATCH_EMPTY_PGW" | jq -e . >/dev/null 2>&1
assert_eq "$?" "0" "build_sizing_state_patch: empty pushgateway still valid JSON"
PGW_VAL=$(echo "$PATCH_EMPTY_PGW" | jq -r '.data["pushgateway.last_oom_at"]')
assert_eq "$PGW_VAL" "" "build_sizing_state_patch: empty pushgateway value is empty string"

###############################################################################
# seconds_since
###############################################################################

# Recent timestamp — should be small positive number
# BSD: -v-60S (60 seconds). GNU: -d "60 seconds ago"
ONE_MIN_AGO=$(date -u -v-60S +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "60 seconds ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
if [ -n "$ONE_MIN_AGO" ]; then
    SECS=$(seconds_since "$ONE_MIN_AGO")
    assert_ge "$SECS" 50 "seconds_since: 60s ago >= 50s"
    assert_le "$SECS" 80 "seconds_since: 60s ago <= 80s"
fi

# Empty → empty
assert_eq "$(seconds_since "")" "" "seconds_since: empty input = empty output"

###############################################################################
test_summary
exit $?
