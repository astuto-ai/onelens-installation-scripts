#!/bin/bash
# An OOM-looping metrics backend serves no usage data, and the OOM retry after helm never
# fits in the Job (helm's --wait on the crash loop uses the time up to the deadline), so
# patching.sh must raise it before the upgrade. Also: the force-delete of Terminating pods
# must not treat an unparseable deletionTimestamp as "stuck since 1970".
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
source "$(lib_dir)/resource-sizing.sh"
set_test_file "test-oom-loop-raise.sh"
ROOT=$(repo_root)
PATCHING="$ROOT/src/patching.sh"

###############################################################################
# Test 1: why a raise is needed before helm (the retry has no time left)
###############################################################################
# deployer Job deadline 900s; the first --wait times out at deadline - reserve (or after
# 600s), and the retry needs at least _HELM_WAIT_MIN more. Any run that spent more than a
# minute before helm can't retry.
for used in 60 120 250 400; do
    first=$(helm_wait_seconds 900 "$used")
    after=$(( used + first + 5 ))
    assert_eq "$(helm_wait_seconds 900 "$after")" "" "deadline 900, ${used}s before helm: no time for the OOM retry after a timed-out wait"
done

###############################################################################
# Test 2: the raise block
###############################################################################
raise_block=$(sed -n '/^# OOM-looping metrics backend:/,/^# --- Prometheus WAL reset ---/p' "$PATCHING" | sed '$d')
assert_ne "$(echo "$raise_block" | grep -c 'calculate_wal_oom_memory')" "0" "patching.sh has the OOM-loop raise block"

raise_line=$(grep -n '^# OOM-looping metrics backend:' "$PATCHING" | cut -d: -f1)
guard_line=$(grep -n 'Fallback: usage-based unavailable, applying legacy memory guard' "$PATCHING" | cut -d: -f1)
override_line=$(grep -n '^# --- Customer overrides' "$PATCHING" | cut -d: -f1)
helm_line=$(grep -n '^HELM_CMD="helm upgrade onelens-agent' "$PATCHING" | head -1 | cut -d: -f1)
assert_gt "$raise_line" "$guard_line" "raise runs after the legacy memory guard"
assert_lt "$raise_line" "$override_line" "raise runs before customer overrides, so an override still wins"
assert_lt "$raise_line" "$helm_line" "raise runs before the helm command is built"

# _raise "$oom_list" "$component" "$limit" [usage_applied] [node_fit] [request]
_raise() {
    local oom="$1" comp="$2" lim="$3" usage="${4:-false}" fit="${5:-}" req="${6:-$3}"
    (
        OOM_KUBECTL="$oom" METRICS_COMPONENT="$comp" METRICS_LABEL="Backend"
        USAGE_BASED_APPLIED="$usage" NODE_FIT_MEM_MI="$fit"
        PROMETHEUS_MEMORY_REQUEST="$req" PROMETHEUS_MEMORY_LIMIT="$lim"
        eval "$raise_block" >/dev/null
        echo "$PROMETHEUS_MEMORY_REQUEST/$PROMETHEUS_MEMORY_LIMIT"
    )
}
assert_eq "$(_raise prometheus-server prometheus-server 8192Mi)" "12288Mi/12288Mi" "Prometheus OOM-looping at 8Gi, no usage data -> 12Gi (cap)"
assert_eq "$(_raise prometheus-server prometheus-server 8Gi)" "12288Mi/12288Mi" "Gi units handled"
assert_eq "$(_raise prometheus-server prometheus-server 2400Mi)" "3600Mi/3600Mi" "below the cap -> 1.5x"
assert_eq "$(_raise prometheus-server prometheus-server 8192Mi false "" 6000Mi)" "12288Mi/12288Mi" "request raised with the limit"
assert_eq "$(_raise prometheus-server prometheus-server 8192Mi false 10000)" "10000Mi/10000Mi" "raise stops at the node fit"
assert_eq "$(_raise prometheus-server prometheus-server 12288Mi)" "12288Mi/12288Mi" "already at the cap -> unchanged"
assert_eq "$(_raise prometheus-server prometheus-server 12Gi)" "12Gi/12Gi" "at the cap in Gi -> unchanged string (no needless restart)"
assert_eq "$(_raise prometheus-server prometheus-server 16Gi)" "16Gi/16Gi" "above the cap -> never lowered"
assert_eq "$(_raise prometheus-server prometheus-server 8192Mi true)" "8192Mi/8192Mi" "usage data available -> left to usage-based sizing"
assert_eq "$(_raise "" prometheus-server 8192Mi)" "8192Mi/8192Mi" "no OOM -> unchanged"
assert_eq "$(_raise prometheus-server-configmap-reload prometheus-server 8192Mi)" "8192Mi/8192Mi" "sidecar OOM does not raise the server"
assert_eq "$(_raise kube-state-metrics prometheus-server 8192Mi)" "8192Mi/8192Mi" "another component's OOM does not raise the backend"
assert_eq "$(_raise "$(printf 'kube-state-metrics\nprometheus-server')" prometheus-server 8192Mi)" "12288Mi/12288Mi" "backend found in a multi-line OOM list"
assert_eq "$(_raise victoriametrics victoriametrics 1600Mi)" "2400Mi/2400Mi" "VictoriaMetrics raised the same way"

msg=$(OOM_KUBECTL=prometheus-server METRICS_COMPONENT=prometheus-server METRICS_LABEL=Prometheus \
    USAGE_BASED_APPLIED=false NODE_FIT_MEM_MI="" PROMETHEUS_MEMORY_REQUEST=8192Mi PROMETHEUS_MEMORY_LIMIT=8192Mi \
    bash -c "source '$(lib_dir)/resource-sizing.sh'; $raise_block")
assert_eq "$msg" "Prometheus OOM-killed with no usage data: raising memory 8192Mi -> 12288Mi in this upgrade" "raise is logged"
msg=$(OOM_KUBECTL=prometheus-server METRICS_COMPONENT=prometheus-server METRICS_LABEL=Prometheus \
    USAGE_BASED_APPLIED=false NODE_FIT_MEM_MI="" PROMETHEUS_MEMORY_REQUEST=12288Mi PROMETHEUS_MEMORY_LIMIT=12288Mi \
    bash -c "source '$(lib_dir)/resource-sizing.sh'; $raise_block")
assert_contains "$msg" "already at its memory cap" "at-cap is logged"

###############################################################################
# Test 3: force-delete of Terminating pods
###############################################################################
fd_block=$(sed -n '/^# Force-delete pods stuck in Terminating/,/^fi$/p' "$PATCHING")
assert_ne "$(echo "$fd_block" | grep -c 'fromdateiso8601')" "0" "force-delete reads the deletion age with jq"
assert_eq "$(echo "$fd_block" | grep -v '^\s*#' | grep -c 'date -d' || true)" "0" "force-delete no longer uses date -d"

# _fd "$deletionTimestamp" → names of force-deleted pods
_fd() {
    local ts="$1"
    (
        kubectl() {
            case "$*" in
                "get pods -n onelens-agent --no-headers") echo "onelens-agent-prometheus-server-abc 1/2 Terminating 0 20m" ;;
                "get pod onelens-agent-prometheus-server-abc -n onelens-agent -o json")
                    if [ -n "$ts" ]; then jq -n --arg t "$ts" '{metadata: {deletionTimestamp: $t}}'; else echo '{"metadata":{}}'; fi ;;
                delete*) echo "DELETED $3" ;;
            esac
        }
        eval "$fd_block" | grep '^DELETED' || true
    )
}
ago() { jq -nr --argjson s "$1" 'now - $s | todate'; }
assert_eq "$(_fd "$(ago 900)")" "DELETED onelens-agent-prometheus-server-abc" "Terminating for 15 min -> force-deleted"
assert_eq "$(_fd "$(ago 120)")" "" "Terminating for 2 min -> left alone"
assert_eq "$(_fd "not-a-timestamp")" "" "unparseable deletionTimestamp -> left alone (was: deleted at once)"
assert_eq "$(_fd "")" "" "no deletionTimestamp -> left alone"
assert_eq "$(_fd "$(ago -600)")" "" "deletionTimestamp in the future (clock skew) -> left alone"

test_summary
exit $?
