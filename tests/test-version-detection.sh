#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
source "$(lib_dir)/resource-sizing.sh"
set_test_file "test-version-detection.sh"

###############################################################################
# normalize_chart_version — valid versions (exit 0)
###############################################################################

result=$(normalize_chart_version "2.1.3"); rc=$?
assert_eq "$rc" "0" "2.1.3 → exit code 0"
assert_eq "$result" "2.1.3" "2.1.3 → cleaned to 2.1.3"

result=$(normalize_chart_version "v2.1.3"); rc=$?
assert_eq "$rc" "0" "v2.1.3 → exit code 0"
assert_eq "$result" "2.1.3" "v2.1.3 → cleaned to 2.1.3"

result=$(normalize_chart_version "release/v1.7.0"); rc=$?
assert_eq "$rc" "0" "release/v1.7.0 → exit code 0"
assert_eq "$result" "1.7.0" "release/v1.7.0 → cleaned to 1.7.0"

result=$(normalize_chart_version "release/1.7.0"); rc=$?
assert_eq "$rc" "0" "release/1.7.0 → exit code 0"
assert_eq "$result" "1.7.0" "release/1.7.0 → cleaned to 1.7.0"

result=$(normalize_chart_version "v1.0.0"); rc=$?
assert_eq "$rc" "0" "v1.0.0 → exit code 0"
assert_eq "$result" "1.0.0" "v1.0.0 → cleaned to 1.0.0"

result=$(normalize_chart_version "0.0.1"); rc=$?
assert_eq "$rc" "0" "0.0.1 → exit code 0"
assert_eq "$result" "0.0.1" "0.0.1 → cleaned to 0.0.1"

###############################################################################
# normalize_chart_version — invalid versions (exit 1)
###############################################################################

# For invalid versions: use if/else to avoid set -e killing the script
if result=$(normalize_chart_version "abc"); then rc=0; else rc=$?; fi
assert_eq "$rc" "1" "abc → exit code 1"

if result=$(normalize_chart_version "1.7"); then rc=0; else rc=$?; fi
assert_eq "$rc" "1" "1.7 → exit code 1 (not X.Y.Z)"

if result=$(normalize_chart_version ""); then rc=0; else rc=$?; fi
assert_eq "$rc" "1" "empty string → exit code 1"

if result=$(normalize_chart_version "v"); then rc=0; else rc=$?; fi
assert_eq "$rc" "1" "v → exit code 1"

if result=$(normalize_chart_version "release/"); then rc=0; else rc=$?; fi
assert_eq "$rc" "1" "release/ → exit code 1"

if result=$(normalize_chart_version "1.2.3.4"); then rc=0; else rc=$?; fi
assert_eq "$rc" "1" "1.2.3.4 → exit code 1 (too many parts)"

if result=$(normalize_chart_version "onelens-agent-2.1.3"); then rc=0; else rc=$?; fi
assert_eq "$rc" "1" "onelens-agent-2.1.3 → exit code 1 (extra prefix)"

###############################################################################
# Real-world version strings from production (cluster_versions DB)
###############################################################################

result=$(normalize_chart_version "release/v1.7.0"); rc=$?
assert_eq "$rc" "0" "production: release/v1.7.0 → exit code 0"
assert_eq "$result" "1.7.0" "production: release/v1.7.0 → 1.7.0 (10 clusters)"

result=$(normalize_chart_version "1.7.0"); rc=$?
assert_eq "$rc" "0" "production: 1.7.0 → exit code 0"
assert_eq "$result" "1.7.0" "production: 1.7.0 → 1.7.0 (5 clusters)"

result=$(normalize_chart_version "1.8.0"); rc=$?
assert_eq "$rc" "0" "production: 1.8.0 → exit code 0"
assert_eq "$result" "1.8.0" "production: 1.8.0 → 1.8.0 (4 clusters)"

result=$(normalize_chart_version "1.9.0"); rc=$?
assert_eq "$rc" "0" "production: 1.9.0 → exit code 0"
assert_eq "$result" "1.9.0" "production: 1.9.0 → 1.9.0 (40+ clusters)"

result=$(normalize_chart_version "2.0.1"); rc=$?
assert_eq "$rc" "0" "production: 2.0.1 → exit code 0"
assert_eq "$result" "2.0.1" "production: 2.0.1 → 2.0.1 (6 clusters)"

result=$(normalize_chart_version "2.1.2"); rc=$?
assert_eq "$rc" "0" "production: 2.1.2 → exit code 0"
assert_eq "$result" "2.1.2" "production: 2.1.2 → 2.1.2 (2 clusters)"

result=$(normalize_chart_version "2.1.3"); rc=$?
assert_eq "$rc" "0" "production: 2.1.3 → exit code 0"
assert_eq "$result" "2.1.3" "production: 2.1.3 → 2.1.3 (1 cluster)"

test_summary; exit $?
