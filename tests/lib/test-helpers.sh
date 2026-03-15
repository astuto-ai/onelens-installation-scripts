#!/bin/bash
# tests/lib/test-helpers.sh — Lightweight test assertions for bash
# Source this at the top of every test file.

# Counters
_TESTS_PASSED=0
_TESTS_FAILED=0
_TESTS_TOTAL=0
_CURRENT_TEST_FILE=""

# Colors (only if terminal supports it)
if [ -t 1 ]; then
    _GREEN='\033[0;32m'
    _RED='\033[0;31m'
    _YELLOW='\033[0;33m'
    _NC='\033[0m'
else
    _GREEN=''
    _RED=''
    _YELLOW=''
    _NC=''
fi

# Set the test file name for reporting
set_test_file() {
    _CURRENT_TEST_FILE="$1"
    echo ""
    echo "=== ${_CURRENT_TEST_FILE} ==="
}

# Core assert: compare actual vs expected
# Usage: assert_eq "$actual" "$expected" "test description"
assert_eq() {
    local actual="$1"
    local expected="$2"
    local desc="$3"
    _TESTS_TOTAL=$((_TESTS_TOTAL + 1))
    if [ "$actual" = "$expected" ]; then
        _TESTS_PASSED=$((_TESTS_PASSED + 1))
        printf "  ${_GREEN}PASS${_NC}: %s\n" "$desc"
    else
        _TESTS_FAILED=$((_TESTS_FAILED + 1))
        printf "  ${_RED}FAIL${_NC}: %s\n" "$desc"
        printf "         expected: '%s'\n" "$expected"
        printf "         actual:   '%s'\n" "$actual"
    fi
}

# Assert not equal
assert_ne() {
    local actual="$1"
    local not_expected="$2"
    local desc="$3"
    _TESTS_TOTAL=$((_TESTS_TOTAL + 1))
    if [ "$actual" != "$not_expected" ]; then
        _TESTS_PASSED=$((_TESTS_PASSED + 1))
        printf "  ${_GREEN}PASS${_NC}: %s\n" "$desc"
    else
        _TESTS_FAILED=$((_TESTS_FAILED + 1))
        printf "  ${_RED}FAIL${_NC}: %s\n" "$desc"
        printf "         should not be: '%s'\n" "$not_expected"
        printf "         actual:        '%s'\n" "$actual"
    fi
}

# Assert numeric greater than
assert_gt() {
    local actual="$1"
    local threshold="$2"
    local desc="$3"
    _TESTS_TOTAL=$((_TESTS_TOTAL + 1))
    if [ "$actual" -gt "$threshold" ] 2>/dev/null; then
        _TESTS_PASSED=$((_TESTS_PASSED + 1))
        printf "  ${_GREEN}PASS${_NC}: %s\n" "$desc"
    else
        _TESTS_FAILED=$((_TESTS_FAILED + 1))
        printf "  ${_RED}FAIL${_NC}: %s\n" "$desc"
        printf "         expected > %s, got: '%s'\n" "$threshold" "$actual"
    fi
}

# Assert numeric greater than or equal
assert_ge() {
    local actual="$1"
    local threshold="$2"
    local desc="$3"
    _TESTS_TOTAL=$((_TESTS_TOTAL + 1))
    if [ "$actual" -ge "$threshold" ] 2>/dev/null; then
        _TESTS_PASSED=$((_TESTS_PASSED + 1))
        printf "  ${_GREEN}PASS${_NC}: %s\n" "$desc"
    else
        _TESTS_FAILED=$((_TESTS_FAILED + 1))
        printf "  ${_RED}FAIL${_NC}: %s\n" "$desc"
        printf "         expected >= %s, got: '%s'\n" "$threshold" "$actual"
    fi
}

# Assert numeric less than
assert_lt() {
    local actual="$1"
    local threshold="$2"
    local desc="$3"
    _TESTS_TOTAL=$((_TESTS_TOTAL + 1))
    if [ "$actual" -lt "$threshold" ] 2>/dev/null; then
        _TESTS_PASSED=$((_TESTS_PASSED + 1))
        printf "  ${_GREEN}PASS${_NC}: %s\n" "$desc"
    else
        _TESTS_FAILED=$((_TESTS_FAILED + 1))
        printf "  ${_RED}FAIL${_NC}: %s\n" "$desc"
        printf "         expected < %s, got: '%s'\n" "$threshold" "$actual"
    fi
}

# Assert numeric less than or equal
assert_le() {
    local actual="$1"
    local threshold="$2"
    local desc="$3"
    _TESTS_TOTAL=$((_TESTS_TOTAL + 1))
    if [ "$actual" -le "$threshold" ] 2>/dev/null; then
        _TESTS_PASSED=$((_TESTS_PASSED + 1))
        printf "  ${_GREEN}PASS${_NC}: %s\n" "$desc"
    else
        _TESTS_FAILED=$((_TESTS_FAILED + 1))
        printf "  ${_RED}FAIL${_NC}: %s\n" "$desc"
        printf "         expected <= %s, got: '%s'\n" "$threshold" "$actual"
    fi
}

# Assert string contains substring
assert_contains() {
    local haystack="$1"
    local needle="$2"
    local desc="$3"
    _TESTS_TOTAL=$((_TESTS_TOTAL + 1))
    if echo "$haystack" | grep -qF "$needle"; then
        _TESTS_PASSED=$((_TESTS_PASSED + 1))
        printf "  ${_GREEN}PASS${_NC}: %s\n" "$desc"
    else
        _TESTS_FAILED=$((_TESTS_FAILED + 1))
        printf "  ${_RED}FAIL${_NC}: %s\n" "$desc"
        printf "         expected to contain: '%s'\n" "$needle"
        printf "         actual: '%s'\n" "$haystack"
    fi
}

# Assert command exits with expected code
# Usage: assert_exit_code 0 "description" command arg1 arg2
assert_exit_code() {
    local expected_code="$1"
    local desc="$2"
    shift 2
    local actual_code
    if "$@" >/dev/null 2>&1; then
        actual_code=0
    else
        actual_code=$?
    fi
    _TESTS_TOTAL=$((_TESTS_TOTAL + 1))
    if [ "$actual_code" -eq "$expected_code" ]; then
        _TESTS_PASSED=$((_TESTS_PASSED + 1))
        printf "  ${_GREEN}PASS${_NC}: %s\n" "$desc"
    else
        _TESTS_FAILED=$((_TESTS_FAILED + 1))
        printf "  ${_RED}FAIL${_NC}: %s\n" "$desc"
        printf "         expected exit code: %s\n" "$expected_code"
        printf "         actual exit code:   %s\n" "$actual_code"
    fi
}

# Assert a file exists
assert_file_exists() {
    local filepath="$1"
    local desc="$2"
    _TESTS_TOTAL=$((_TESTS_TOTAL + 1))
    if [ -f "$filepath" ]; then
        _TESTS_PASSED=$((_TESTS_PASSED + 1))
        printf "  ${_GREEN}PASS${_NC}: %s\n" "$desc"
    else
        _TESTS_FAILED=$((_TESTS_FAILED + 1))
        printf "  ${_RED}FAIL${_NC}: %s\n" "$desc"
        printf "         file not found: '%s'\n" "$filepath"
    fi
}

# Print test summary and return appropriate exit code
test_summary() {
    echo ""
    echo "─────────────────────────────────"
    if [ "$_TESTS_FAILED" -eq 0 ]; then
        printf "${_GREEN}All %d tests passed${_NC}\n" "$_TESTS_TOTAL"
    else
        printf "${_RED}%d of %d tests failed${_NC}\n" "$_TESTS_FAILED" "$_TESTS_TOTAL"
    fi
    echo "  Passed: $_TESTS_PASSED"
    echo "  Failed: $_TESTS_FAILED"
    echo "─────────────────────────────────"
    if [ "$_TESTS_FAILED" -gt 0 ]; then return 1; else return 0; fi
}

# Helper: resolve path relative to the repo root
repo_root() {
    local dir
    dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    echo "$dir"
}

# Helper: path to fixtures directory
fixtures_dir() {
    echo "$(repo_root)/tests/fixtures"
}

# Helper: path to lib directory
lib_dir() {
    echo "$(repo_root)/lib"
}
