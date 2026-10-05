#!/bin/bash
# A re-install records the installed version as the cluster's target version (new clusters
# get it at registration). The target is only raised, never lowered, and the step can
# never fail the install.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
set_test_file "test-target-version.sh"
ROOT=$(repo_root)
INSTALL="$ROOT/install.sh"

lt_fn=$(sed -n '/^_version_lt() {/,/^}/p' "$INSTALL")
sync_fn=$(sed -n '/^_sync_target_version() {/,/^}/p' "$INSTALL")
assert_ne "$lt_fn" "" "install.sh has _version_lt"
assert_ne "$sync_fn" "" "install.sh has _sync_target_version"
eval "$lt_fn"
eval "$sync_fn"

###############################################################################
# Test 1: version ordering (numeric, not text)
###############################################################################
_lt() { if _version_lt "$1" "$2"; then echo yes; else echo no; fi; }
assert_eq "$(_lt v2.1.99 v2.1.120)" "yes" "2.1.99 < 2.1.120 (numeric, not text order)"
assert_eq "$(_lt v2.1.120 v2.1.99)" "no" "2.1.120 is not < 2.1.99"
assert_eq "$(_lt v2.1.120 v2.1.120)" "no" "equal is not lower"
assert_eq "$(_lt release/v2.1.110 v2.1.121)" "yes" "release/ prefix ignored"
assert_eq "$(_lt 2.1.120 v2.1.121)" "yes" "missing v prefix ignored"
assert_eq "$(_lt v2.1 v2.1.0)" "no" "2.1 == 2.1.0"
assert_eq "$(_lt v2.2.0 v2.1.999)" "no" "minor beats patch"
assert_eq "$(_lt latest v2.1.121)" "no" "unparseable target is never lower (left alone)"
assert_eq "$(_lt "" v2.1.121)" "no" "empty is handled by the caller, not here"

###############################################################################
# Test 2: what the install sends to the API
###############################################################################
# _sync <is_upgrade> <POST response JSON or ""> [PUT http code] [release version]
#   -> "<calls>|<update_data JSON or ->|after"
_sync() {
    local is_upgrade="$1" post_resp="$2" put_code="${3:-200}" release="${4:-2.1.121}" log
    log=$(mktemp)
    (
        set -e
        IS_UPGRADE="$is_upgrade" RELEASE_VERSION="$release" API_BASE_URL="https://api.example"
        REGISTRATION_ID="reg-1" CLUSTER_TOKEN="tok-1"
        curl() {
            local method="" data="" prev=""
            for a in "$@"; do
                [ "$prev" = "-X" ] && method="$a"
                [ "$prev" = "-d" ] && data="$a"
                prev="$a"
            done
            echo "$method" >> "$log"
            if [ "$method" = "POST" ]; then
                [ -n "$post_resp" ] && echo "$post_resp" || return 7
            else
                echo "$data" | jq -c '.update_data' >> "$log.put"
                echo "$put_code"
            fi
        }
        _sync_target_version >/dev/null
        echo "after"   # set -e: the step must never abort the install
    ) > "$log.out"
    printf '%s|%s|%s' "$(tr '\n' ',' < "$log")" "$(cat "$log.put" 2>/dev/null || echo -)" "$(cat "$log.out")"
    rm -f "$log" "$log.put" "$log.out"
}
resp() { jq -nc --arg c "$1" --arg p "$2" '{data: {current_version: (if $c == "" then null else $c end), patching_version: (if $p == "" then null else $p end)}}'; }

assert_eq "$(_sync false "$(resp v2.1.110 v2.1.110)")" "|-|after" "new install (registration ran): no API calls"
assert_eq "$(_sync true "$(resp v2.1.110 v2.1.110)")" \
    'POST,PUT,|{"patching_version":"v2.1.121","current_version":"v2.1.121","prev_version":"v2.1.110"}|after' \
    "re-install over an older target: raised, current/prev recorded"
assert_eq "$(_sync true "$(resp v2.1.99 v2.1.99)")" \
    'POST,PUT,|{"patching_version":"v2.1.121","current_version":"v2.1.121","prev_version":"v2.1.99"}|after' \
    "2.1.99 target raised (numeric compare)"
assert_eq "$(_sync true "$(resp "" "")")" \
    'POST,PUT,|{"patching_version":"v2.1.121","current_version":"v2.1.121"}|after' \
    "no target / no current: both set, no prev_version"
assert_eq "$(_sync true "$(resp v2.1.121 v2.1.121)")" "POST,|-|after" "already at the installed version: nothing written"
assert_eq "$(_sync true "$(resp v2.1.121 v2.1.130)")" "POST,|-|after" "newer target set in OneLens: left as it is"
assert_eq "$(_sync true "$(resp v2.1.120 v2.1.130)")" \
    'POST,PUT,|{"current_version":"v2.1.121","prev_version":"v2.1.120"}|after' \
    "newer target kept; only current/prev recorded"
assert_eq "$(_sync true "$(resp v2.1.110 latest)")" \
    'POST,PUT,|{"current_version":"v2.1.121","prev_version":"v2.1.110"}|after' \
    "unparseable target left as it is"
assert_eq "$(_sync true "")" "POST,|-|after" "API unreachable: nothing written, install continues"
assert_eq "$(_sync true '{"error":"Invalid cluster token"}')" "POST,|-|after" "API error body: nothing written, install continues"
assert_eq "$(_sync true "$(resp v2.1.110 v2.1.110)" 500)" \
    'POST,PUT,|{"patching_version":"v2.1.121","current_version":"v2.1.121","prev_version":"v2.1.110"}|after' \
    "PUT fails: install continues"
assert_eq "$(_sync true "$(resp v2.1.110 v2.1.110)" 200 v2.1.121)" \
    'POST,PUT,|{"patching_version":"v2.1.121","current_version":"v2.1.121","prev_version":"v2.1.110"}|after' \
    "RELEASE_VERSION given with a v: no double prefix"

###############################################################################
# Test 3: wiring
###############################################################################
call_line=$(grep -n '^_sync_target_version || true$' "$INSTALL" | cut -d: -f1)
connected_line=$(grep -n 'Registering cluster as connected' "$INSTALL" | cut -d: -f1)
assert_ne "$call_line" "" "install.sh calls _sync_target_version (guarded with || true)"
if [ -n "$call_line" ] && [ -n "$connected_line" ]; then
    assert_gt "$call_line" "$connected_line" "target version is recorded after the cluster is marked CONNECTED"
fi
token_echo=$(echo "$sync_fn" | grep -E 'echo .*(CLUSTER_TOKEN|payload)' | grep -vc 'jq' || true)
assert_eq "$token_echo" "0" "the cluster token is never echoed"

test_summary
