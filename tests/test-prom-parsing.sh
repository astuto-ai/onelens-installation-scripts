#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
source "$(lib_dir)/resource-sizing.sh"
set_test_file "test-prom-parsing.sh"

FIXTURES="$(fixtures_dir)"

###############################################################################
# parse_prom_result
###############################################################################

# Normal memory response — 4 containers
RESULT=$(parse_prom_result "$(cat "$FIXTURES/prom-memory-72h.json")")
assert_contains "$RESULT" "prometheus-server" "parse memory 72h: has prometheus-server"
assert_contains "$RESULT" "kube-state-metrics" "parse memory 72h: has kube-state-metrics"
assert_contains "$RESULT" "onelens-agent-prometheus-opencost-exporter" "parse memory 72h: has opencost"
assert_contains "$RESULT" "prometheus-pushgateway" "parse memory 72h: has pushgateway"
assert_contains "$RESULT" "314572800" "parse memory 72h: prometheus-server value = 314572800 bytes"

# Normal CPU response
RESULT=$(parse_prom_result "$(cat "$FIXTURES/prom-cpu-72h.json")")
assert_contains "$RESULT" "prometheus-server 0.085" "parse CPU 72h: prometheus-server = 0.085 cores"
assert_contains "$RESULT" "kube-state-metrics 0.012" "parse CPU 72h: kube-state-metrics = 0.012 cores"

# Empty response
RESULT=$(parse_prom_result "$(cat "$FIXTURES/prom-empty-response.json")")
assert_eq "$RESULT" "" "parse empty response: returns empty"

# Error response
RESULT=$(parse_prom_result "$(cat "$FIXTURES/prom-error-response.json")")
assert_eq "$RESULT" "" "parse error response: returns empty"

# Empty input
RESULT=$(parse_prom_result "")
assert_eq "$RESULT" "" "parse empty input: returns empty"

###############################################################################
# parse_prom_oom_count
###############################################################################

# OOM detected for prometheus-server
RESULT=$(parse_prom_oom_count "$(cat "$FIXTURES/prom-oom-detected.json")")
assert_contains "$RESULT" "prometheus-server" "parse OOM detected: has prometheus-server"
assert_contains "$RESULT" "1" "parse OOM detected: count = 1"

# No OOM
RESULT=$(parse_prom_oom_count "$(cat "$FIXTURES/prom-oom-none.json")")
assert_eq "$RESULT" "" "parse OOM none: empty (no results)"

###############################################################################
# has_sufficient_data
###############################################################################

assert_exit_code 0 "has_sufficient_data: 72h >= 72h" has_sufficient_data 72 72
assert_exit_code 0 "has_sufficient_data: 100h >= 72h" has_sufficient_data 100 72
assert_exit_code 1 "has_sufficient_data: 48h < 72h" has_sufficient_data 48 72
assert_exit_code 1 "has_sufficient_data: empty" has_sufficient_data "" 72

###############################################################################
test_summary
exit $?
