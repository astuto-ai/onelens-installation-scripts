#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
set_test_file "test-build.sh"
ROOT=$(repo_root)

BUILD_SCRIPT="$ROOT/scripts/build-patching.sh"
SRC_FILE="$ROOT/src/patching.sh"
OUT_FILE="$ROOT/patching.sh"

###############################################################################
# Prerequisites: src/patching.sh must have BEGIN_EMBED/END_EMBED markers
###############################################################################
if [ ! -f "$SRC_FILE" ]; then
    echo "SKIP: src/patching.sh does not exist yet"
    exit 0
fi
if ! grep -q 'BEGIN_EMBED' "$SRC_FILE"; then
    echo "SKIP: src/patching.sh does not have BEGIN_EMBED markers yet"
    exit 0
fi

###############################################################################
# Test 1: Build script exists and is executable
###############################################################################
assert_file_exists "$BUILD_SCRIPT" "build-patching.sh exists"

###############################################################################
# Test 2: Build script runs successfully
###############################################################################
# Save existing root patching.sh (if any) so we can restore after test
BACKUP=""
if [ -f "$OUT_FILE" ]; then
    BACKUP=$(mktemp)
    cp "$OUT_FILE" "$BACKUP"
fi

build_output=$(bash "$BUILD_SCRIPT" 2>&1); build_rc=$?
assert_eq "$build_rc" "0" "build-patching.sh exits 0"

###############################################################################
# Test 3: Output file exists at repo root
###############################################################################
assert_file_exists "$OUT_FILE" "patching.sh was created at repo root"

###############################################################################
# Test 4: Output has valid bash syntax
###############################################################################
syntax_check=$(bash -n "$OUT_FILE" 2>&1); syntax_rc=$?
assert_eq "$syntax_rc" "0" "patching.sh has valid bash syntax"

###############################################################################
# Test 5: Expected functions are present in output
###############################################################################
for fn in apply_memory_multiplier _cpu_to_millicores _memory_to_mi _max_cpu _max_memory \
          count_deploy_pods count_sts_pods count_ds_pods calculate_total_pods \
          calculate_avg_labels get_label_multiplier normalize_chart_version \
          select_resource_tier select_retention_tier; do
    fn_count=$(grep -c "^${fn}()" "$OUT_FILE" 2>/dev/null || grep -c "^${fn} ()" "$OUT_FILE" 2>/dev/null || true)
    assert_gt "$fn_count" "0" "function $fn present in built patching.sh"
done

###############################################################################
# Test 6: No active source line for resource-sizing.sh
###############################################################################
active_source=$(grep -v '^#' "$OUT_FILE" | grep -c 'source.*resource-sizing' || true)
assert_eq "$active_source" "0" "no active source line for resource-sizing.sh in built output"

###############################################################################
# Test 7: BEGIN_EMBED/END_EMBED markers are present (as comments)
###############################################################################
begin_count=$(grep -c 'BEGIN_EMBED' "$OUT_FILE" || true)
end_count=$(grep -c 'END_EMBED' "$OUT_FILE" || true)
assert_eq "$begin_count" "1" "BEGIN_EMBED marker present"
assert_eq "$end_count" "1" "END_EMBED marker present"

###############################################################################
# Test 8: Embedded content includes library header
###############################################################################
embed_header=$(grep -c 'Embedded from lib/resource-sizing.sh' "$OUT_FILE" || true)
assert_gt "$embed_header" "0" "embedded content header present"

###############################################################################
# Test 9: Output file is executable
###############################################################################
if [ -x "$OUT_FILE" ]; then
    _TESTS_TOTAL=$((_TESTS_TOTAL + 1))
    _TESTS_PASSED=$((_TESTS_PASSED + 1))
    printf "  ${_GREEN}PASS${_NC}: %s\n" "built patching.sh is executable"
else
    _TESTS_TOTAL=$((_TESTS_TOTAL + 1))
    _TESTS_FAILED=$((_TESTS_FAILED + 1))
    printf "  ${_RED}FAIL${_NC}: %s\n" "built patching.sh is executable"
fi

###############################################################################
# Test 10: Output is self-contained (no source commands for local files)
###############################################################################
local_sources=$(grep -E '^\s*(source|\.) ' "$OUT_FILE" | grep -v '/dev/' | grep -v '/etc/' || true)
local_source_count=$(echo "$local_sources" | grep -c 'resource-sizing\|lib/' || true)
assert_eq "$local_source_count" "0" "no local source dependencies in built output"

# Restore previous patching.sh if it existed
if [ -n "$BACKUP" ]; then
    mv "$BACKUP" "$OUT_FILE"
else
    rm -f "$OUT_FILE"
fi

test_summary
exit $?
