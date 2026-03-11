#!/bin/bash
# tests/run-all.sh — Run all test suites and report results
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0
RESULTS=()

run_test() {
    local test_file="$1"
    local name
    name=$(basename "$test_file")

    printf "\n━━━ Running %s ━━━\n" "$name"

    output=$(bash "$test_file" 2>&1)
    rc=$?

    echo "$output"

    # Check for SKIP
    if echo "$output" | grep -q '^SKIP:'; then
        TOTAL_SKIP=$((TOTAL_SKIP + 1))
        RESULTS+=("SKIP  $name")
        return
    fi

    # Extract pass/fail counts from test_summary output
    passed=$(echo "$output" | grep 'Passed:' | tail -1 | awk '{print $2}')
    failed=$(echo "$output" | grep 'Failed:' | tail -1 | awk '{print $2}')

    passed=${passed:-0}
    failed=${failed:-0}

    TOTAL_PASS=$((TOTAL_PASS + passed))
    TOTAL_FAIL=$((TOTAL_FAIL + failed))

    if [ "$failed" -gt 0 ] || [ "$rc" -ne 0 ]; then
        RESULTS+=("FAIL  $name  (passed: $passed, failed: $failed)")
    else
        RESULTS+=("PASS  $name  (passed: $passed)")
    fi
}

# Pre-warm helm repo if available (avoid races between test files)
if command -v helm &>/dev/null; then
    helm repo add onelens https://astuto-ai.github.io/onelens-installation-scripts 2>/dev/null || true
    helm repo update onelens 2>/dev/null || true
fi

# Discover and run all test files
echo "========================================"
echo "  OneLens Installation Scripts — Tests"
echo "========================================"

for test_file in "$SCRIPT_DIR"/test-*.sh; do
    [ -f "$test_file" ] || continue
    run_test "$test_file"
done

# Summary
echo ""
echo "========================================"
echo "  Summary"
echo "========================================"
for result in "${RESULTS[@]}"; do
    echo "  $result"
done
echo ""
echo "  Total passed: $TOTAL_PASS"
echo "  Total failed: $TOTAL_FAIL"
echo "  Total skipped: $TOTAL_SKIP"
echo "========================================"

if [ "$TOTAL_FAIL" -gt 0 ]; then
    echo "RESULT: FAILED"
    exit 1
else
    echo "RESULT: PASSED"
    exit 0
fi
