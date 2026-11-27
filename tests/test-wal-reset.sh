#!/bin/bash
# A Prometheus OOM-killed at its memory cap while replaying its WAL can never start again,
# and no memory raise is left. patching.sh then deletes the WAL (not the blocks) once a day
# at most. Also: without usage data the metrics backend keeps its CPU instead of dropping
# to the tier value, since every change restarts it.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
source "$(lib_dir)/resource-sizing.sh"
set_test_file "test-wal-reset.sh"
ROOT=$(repo_root)
PATCHING="$ROOT/src/patching.sh"
DEPLOY_FIXTURE="$(fixtures_dir)/prometheus-server-deployment.json"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fn_block=$(sed -n '/^# prometheus_died_in_wal_replay /,/^if \[ "\${_OOM_LOOP_AT_CAP:-false}" = "true" \]/p' "$PATCHING" | sed '$d')
decision_block=$(sed -n '/^if \[ "\${_OOM_LOOP_AT_CAP:-false}" = "true" \]/,/^fi$/p' "$PATCHING")
guard_block=$(sed -n '/^# Memory guard: usage-based sizing/,/^# OOM-looping metrics backend:/p' "$PATCHING" | sed '$d')
eval "$fn_block"

###############################################################################
# Test 1: placement
###############################################################################
reset_line=$(grep -n '^# --- Prometheus WAL reset ---' "$PATCHING" | cut -d: -f1)
raise_line=$(grep -n '^# OOM-looping metrics backend:' "$PATCHING" | cut -d: -f1)
override_line=$(grep -n '^# --- Customer overrides' "$PATCHING" | cut -d: -f1)
helm_line=$(grep -n '^HELM_CMD="helm upgrade onelens-agent' "$PATCHING" | head -1 | cut -d: -f1)
elapsed_def=$(grep -n '^_job_elapsed() {' "$PATCHING" | cut -d: -f1)
assert_gt "$reset_line" "$raise_line" "WAL reset comes after the OOM-loop raise (only when no raise is left)"
assert_lt "$reset_line" "$override_line" "WAL reset comes before customer overrides"
assert_lt "$reset_line" "$helm_line" "WAL reset runs before the helm upgrade"
assert_lt "$elapsed_def" "$reset_line" "_job_elapsed is defined before the WAL reset uses it"
assert_eq "$(grep -c '^_job_elapsed() {' "$PATCHING")" "1" "_job_elapsed defined once"
assert_contains "$(sed -n '/^# OOM-looping metrics backend:/,/^# --- Prometheus WAL reset ---/p' "$PATCHING")" "_OOM_LOOP_AT_CAP=true" "the at-cap branch of the raise flags the reset"

###############################################################################
# Test 2: did it die replaying the WAL? (Prometheus 3 slog and Prometheus 2 logfmt lines)
###############################################################################
L3_START='time=2026-11-26T09:10:01.100Z level=INFO source=main.go:1189 msg="Starting TSDB ..."'
L3_MMAP='time=2026-11-26T09:10:01.300Z level=INFO source=head.go:628 msg="Replaying on-disk memory mappable chunks if any" component=tsdb'
L3_MMAP_DONE='time=2026-11-26T09:10:09.900Z level=INFO source=head.go:715 msg="On-disk memory mappable chunks replay completed" component=tsdb duration=8.6s'
L3_WAL='time=2026-11-26T09:10:09.901Z level=INFO source=head.go:723 msg="Replaying WAL, this may take a while" component=tsdb'
L3_SEG='time=2026-11-26T09:10:31.000Z level=INFO source=head.go:801 msg="WAL segment loaded" component=tsdb segment=41 maxSegment=187 duration=1.1s'
L3_DONE='time=2026-11-26T09:12:00.000Z level=INFO source=head.go:838 msg="WAL replay completed" component=tsdb total_replay_duration=1m58s'
L3_TSDB='time=2026-11-26T09:12:00.100Z level=INFO source=main.go:1241 msg="TSDB started"'
L3_READY='time=2026-11-26T09:12:00.300Z level=INFO source=main.go:1482 msg="Server is ready to receive web requests."'
L3_COMPACT='time=2026-11-26T11:00:03.000Z level=INFO source=compact.go:584 msg="write block" component=tsdb mint=1795683600000 maxt=1795685400000'
L2_SEG='ts=2026-11-26T09:10:31.000Z caller=head.go:801 level=info component=tsdb msg="WAL segment loaded" segment=41 maxSegment=187'

died() { if prometheus_died_in_wal_replay "$1"; then echo yes; else echo no; fi; }
assert_eq "$(died "$(printf '%s\n' "$L3_START" "$L3_MMAP" "$L3_MMAP_DONE" "$L3_WAL" "$L3_SEG")")" "yes" "killed between WAL segments -> died replaying"
assert_eq "$(died "$(printf '%s\n' "$L3_START" "$L3_MMAP")")" "yes" "killed replaying the head chunks -> died replaying"
assert_eq "$(died "$(printf '%s\n' "$L3_SEG" "$L3_SEG" "$L3_SEG")")" "yes" "tail holds only segment lines (start cut off) -> died replaying"
assert_eq "$(died "$L2_SEG")" "yes" "Prometheus 2 logfmt line recognised"
assert_eq "$(died "$(printf '%s\n' "$L3_WAL" "$L3_SEG" "$L3_DONE" "$L3_TSDB" "$L3_READY")")" "no" "replay completed and ready -> not a replay death"
assert_eq "$(died "$(printf '%s\n' "$L3_WAL" "$L3_SEG" "$L3_DONE")")" "no" "killed after the replay completed -> not a replay death"
assert_eq "$(died "$(printf '%s\n' "$L3_READY" "$L3_COMPACT" "$L3_COMPACT")")" "no" "killed while running -> not a replay death"
assert_eq "$(died "")" "no" "no previous log -> no reset"

###############################################################################
# Test 3: the reset pod, built from the chart's real Prometheus deployment
###############################################################################
dep=$(cat "$DEPLOY_FIXTURE")
spec=$(prometheus_wal_reset_pod "$dep")
assert_ne "$spec" "" "reset pod built from the rendered chart deployment"
assert_eq "$(echo "$spec" | jq -r '.spec.volumes[0].persistentVolumeClaim.claimName')" "onelens-agent-prometheus-server" "mounts the server's PVC"
assert_eq "$(echo "$spec" | jq -c '.spec.containers[0].volumeMounts')" '[{"name":"storage-volume","mountPath":"/data","subPath":""}]' "same mount path and subPath as the server"
assert_eq "$(echo "$spec" | jq -r '.spec.containers[0].env[0].value')" "/data" "TSDB path from --storage.tsdb.path"
assert_eq "$(echo "$spec" | jq -r '.spec.containers[0].image')" "$(echo "$dep" | jq -r '.spec.template.spec.containers[] | select(.name == "prometheus-server") | .image')" "uses the server's own image (already pulled, air-gapped safe)"
assert_eq "$(echo "$spec" | jq -c '.spec.securityContext')" '{"fsGroup":65534,"runAsGroup":65534,"runAsNonRoot":true,"runAsUser":65534}' "runs as the server's user"
assert_eq "$(echo "$spec" | jq -r '.spec.restartPolicy')" "Never" "runs once"
assert_eq "$(echo "$spec" | jq -r '.spec | has("nodeSelector") or has("tolerations")')" "false" "no placement keys when the server has none"
assert_eq "$(echo "$spec" | jq -r '.metadata | has("namespace")')" "false" "namespace comes from kubectl -n"

placed=$(echo "$dep" | jq '.spec.template.spec.nodeSelector = {"karpenter.sh/nodepool": "pool-a"}
    | .spec.template.spec.tolerations = [{"key": "dedicated", "operator": "Equal", "value": "onelens", "effect": "NoSchedule"}]
    | .spec.template.spec.imagePullSecrets = [{"name": "regcred"}]
    | (.spec.template.spec.containers[] | select(.name == "prometheus-server")).securityContext = {"readOnlyRootFilesystem": true}')
pspec=$(prometheus_wal_reset_pod "$placed")
assert_eq "$(echo "$pspec" | jq -c '[.spec.nodeSelector, .spec.tolerations[0].key, (.spec | has("imagePullSecrets"))]')" '[{"karpenter.sh/nodepool":"pool-a"},"dedicated",false]' "copies nodeSelector and tolerations (customer-pinned pools), never pull secrets"
assert_eq "$(echo "$pspec" | jq -c '.spec.containers[0].securityContext')" '{"readOnlyRootFilesystem":true}' "copies the container securityContext"

custom=$(echo "$dep" | jq '(.spec.template.spec.containers[] | select(.name == "prometheus-server")) |= (.args = (.args | map(if startswith("--storage.tsdb.path=") then "--storage.tsdb.path=/prometheus/" else . end)) | .volumeMounts = [{"name": "storage-volume", "mountPath": "/prometheus", "subPath": "tsdb"}])')
cspec=$(prometheus_wal_reset_pod "$custom")
assert_eq "$(echo "$cspec" | jq -c '[.spec.containers[0].env[0].value, .spec.containers[0].volumeMounts[0].subPath]')" '["/prometheus/","tsdb"]' "custom TSDB path and subPath followed"

noargs=$(echo "$dep" | jq '(.spec.template.spec.containers[] | select(.name == "prometheus-server")).args = []')
assert_eq "$(prometheus_wal_reset_pod "$noargs" | jq -r '.spec.containers[0].env[0].value')" "/data" "no --storage.tsdb.path -> /data"
emptydir=$(echo "$dep" | jq '.spec.template.spec.volumes = [.spec.template.spec.volumes[] | if .name == "storage-volume" then {"name": "storage-volume", "emptyDir": {}} else . end]')
assert_eq "$(prometheus_wal_reset_pod "$emptydir")" "" "no PVC (emptyDir: a pod restart already clears it) -> no reset pod"
assert_eq "$(prometheus_wal_reset_pod '{}')" "" "unreadable deployment -> no reset pod"

# The pod's command, run on a fake TSDB: removes the WAL and head chunks, keeps blocks
cmd=$(echo "$spec" | jq -r '.spec.containers[0].command[2]')
mkdir -p "$TMP/tsdb/wal" "$TMP/tsdb/chunks_head" "$TMP/tsdb/01JDXKQ6B2E8Z0V4P8Y7S1T3AB/chunks"
echo x > "$TMP/tsdb/wal/00000041"; echo x > "$TMP/tsdb/chunks_head/000001"; echo x > "$TMP/tsdb/queries.active"
out=$(TSDB="$TMP/tsdb" sh -c "$cmd")
assert_contains "$out" "WAL_RESET_DONE" "reset command reports success"
assert_eq "$(ls "$TMP/tsdb" | tr '\n' ' ')" "01JDXKQ6B2E8Z0V4P8Y7S1T3AB queries.active " "wal/ and chunks_head/ removed, blocks kept"
out=$(TSDB="$TMP/missing" sh -c "$cmd" 2>/dev/null || true)
assert_eq "$(echo "$out" | grep -c WAL_RESET_DONE || true)" "0" "missing TSDB path -> no success marker"

###############################################################################
# Test 4: reset_prometheus_wal against a fake kubectl
###############################################################################
# _reset <server-pod polls before gone (99 = never)> <reset pod phase> <reset pod logs> [create rc] [budget_end] [elapsed]
# (names start with _t_: the fake kubectl runs inside reset_prometheus_wal, whose locals
# phase/logs would shadow ours)
_reset() {
    local _t_polls="$1" _t_phase="$2" _t_logs="$3" _t_create_rc="${4:-0}" _t_budget="${5:-}" _t_elapsed="${6:-100}"
    (
        cd "$TMP"; : > calls; echo "$_t_polls" > polls; rm -f created.json
        sleep() { :; }
        _job_elapsed() { echo "$_t_elapsed"; }
        kubectl() {
            case "$*" in
                "get deployment onelens-agent-prometheus-server -n onelens-agent -o json") cat "$DEPLOY_FIXTURE" ;;
                "scale deployment onelens-agent-prometheus-server -n onelens-agent --replicas="*) local _r="${@: -1}"; echo "scale ${_r#--replicas=}" >> calls ;;
                "get pods -n onelens-agent -l "*" -o name")
                    local n; n=$(cat polls)
                    if [ "$n" -gt 0 ]; then echo "pod/onelens-agent-prometheus-server-x"; [ "$n" -lt 99 ] && echo $((n - 1)) > polls; fi ;;
                "delete pods -n onelens-agent -l "*" --grace-period=5 --wait=false") echo "delete server pods" >> calls ;;
                "get pods -n onelens-agent -l "*" -o json")
                    echo '{"items":[{"metadata":{"name":"onelens-agent-prometheus-server-x","deletionTimestamp":"2026-11-27T12:36:50Z","deletionGracePeriodSeconds":300},"spec":{"nodeName":"node-a"},"status":{"containerStatuses":[{"name":"prometheus-server","state":{"running":{}}},{"name":"prometheus-server-configmap-reload","state":{"terminated":{}}}]}}]}' ;;
                "delete pod onelens-agent-prometheus-wal-reset"*) echo "delete reset pod" >> calls ;;
                "create -n onelens-agent -f -") cat > created.json; echo "create" >> calls; return "$_t_create_rc" ;;
                "get pod onelens-agent-prometheus-wal-reset -n onelens-agent -o jsonpath={.status.phase}") echo "$_t_phase" ;;
                "logs onelens-agent-prometheus-wal-reset -n onelens-agent") printf '%s\n' "$_t_logs" ;;
                *) echo "unexpected: $*" >> calls ;;
            esac
        }
        if reset_prometheus_wal "$_t_budget" > out; then echo "rc=0"; else echo "rc=1"; fi
        tr '\n' ',' < calls; echo
        cat out
    )
}
r=$(_reset 2 Succeeded "$(printf '4821304\twal\n91233\tchunks_head\nWAL_RESET_DONE')")
assert_contains "$r" "rc=0" "reset succeeds"
assert_contains "$r" "delete server pods,scale 0,delete server pods,delete reset pod,create,delete reset pod,scale 1," "cuts the grace period, then scales to 0 (and cuts any replacement's), waits, runs the pod, removes it, scales back"
assert_contains "$r" "removed (KiB): 4821304	wal" "logs what it removed"
assert_eq "$(jq -r '.spec.volumes[0].persistentVolumeClaim.claimName' "$TMP/created.json")" "onelens-agent-prometheus-server" "created pod mounts the PVC"

r=$(_reset 99 "" "")
assert_contains "$r" "rc=1" "server pod never goes away -> no reset"
assert_contains "$r" "delete server pods,scale 0,delete server pods,scale 1," "...and the replicas are restored, the reset pod never created"
assert_contains "$r" "still present after 180s:" "...and says why"
assert_contains "$r" "onelens-agent-prometheus-server-x node=node-a deleting=2026-11-27T12:36:50Z grace=300s containers=prometheus-server:running,prometheus-server-configmap-reload:terminated" "...with the stuck pod's node, deletion grace and container states"

r=$(_reset 0 Failed "sh: can't cd")
assert_contains "$r" "rc=1" "reset pod failed -> reported as failed"
assert_contains "$r" "scale 1," "...replicas restored"
assert_contains "$r" "ended 'Failed'" "...with the pod's outcome"

r=$(_reset 0 Pending "")
assert_contains "$r" "rc=1" "reset pod never ran (4 min) -> failed"
assert_contains "$r" "delete reset pod,scale 1," "...pod removed and replicas restored"

r=$(_reset 0 Succeeded "something else")
assert_contains "$r" "rc=1" "pod succeeded without the marker -> not counted as a reset"

r=$(_reset 0 "" "" 1)
assert_contains "$r" "rc=1" "pod create refused -> failed"
assert_contains "$r" "delete server pods,scale 0,delete server pods,delete reset pod,create,scale 1," "...replicas restored"

# Time budget: the waits end when the Job reaches budget_end
r=$(_reset 99 "" "" 0 660 700)
assert_contains "$r" "still present after 0s:" "server pod still there, Job past its budget -> gives up at once"
assert_contains "$r" "delete server pods,scale 0,delete server pods,scale 1," "...replicas restored"
r=$(_reset 0 Pending "" 0 660 700)
assert_contains "$r" "rc=1" "reset pod still pending, Job past its budget -> failed"
assert_contains "$r" "delete reset pod,create,delete reset pod,scale 1," "...pod removed and replicas restored"
r=$(_reset 2 Succeeded "$(printf '10\twal\nWAL_RESET_DONE')" 0 660 300)
assert_contains "$r" "rc=0" "within the budget -> reset as usual"

###############################################################################
# Test 5: when the reset runs
###############################################################################
ago() { jq -nr --argjson s "$1" 'now - $s | floor | todate'; }
OOM_POD_JSON='{"items":[{"metadata":{"name":"onelens-agent-prometheus-server-6cd79d8854-h9zbf"},"status":{"containerStatuses":[
  {"name":"prometheus-server-configmap-reload","lastState":{}},
  {"name":"prometheus-server","restartCount":3,"state":{"waiting":{"reason":"CrashLoopBackOff"}},"lastState":{"terminated":{"reason":"OOMKilled","exitCode":137}}}]}},
  {"metadata":{"name":"onelens-agent-kube-state-metrics-1"},"status":{"containerStatuses":[{"name":"kube-state-metrics","lastState":{}}]}}]}'
REPLAY_LOG=$(printf '%s\n' "$L3_START" "$L3_WAL" "$L3_SEG")
# _decide <at_cap> <backend> <last reset ts> <previous log> [elapsed] [deadline]
_decide() {
    local at_cap="$1" backend="$2" last="$3" log="$4" elapsed="${5:-120}" deadline="${6-900}"
    (
        cd "$TMP"; : > dcalls
        _OOM_LOOP_AT_CAP="$at_cap"; METRICS_BACKEND="$backend"; JOB_DEADLINE="$deadline"
        _job_elapsed() { echo "$elapsed"; }
        reset_prometheus_wal() { echo "RESET $1" >> dcalls; return 0; }
        kubectl() {
            case "$*" in
                "get configmap onelens-agent-sizing-state -n onelens-agent -o json")
                    jq -n --arg t "$last" '{data: ({"prometheus-server.last_oom_at": ""} + (if $t == "" then {} else {"prometheus-server.last_wal_reset_at": $t} end))}' ;;
                "get pods -n onelens-agent -o json") echo "$OOM_POD_JSON" ;;
                "logs onelens-agent-prometheus-server-6cd79d8854-h9zbf -n onelens-agent -c prometheus-server --previous --tail=200") printf '%s\n' "$log" ;;
                "patch configmap onelens-agent-sizing-state"*) echo "PATCH ${*: -1}" >> dcalls ;;
                *) echo "unexpected: $*" >> dcalls ;;
            esac
        }
        eval "$decision_block"
        echo "--"; cat dcalls
    )
}
r=$(_decide true prometheus "" "$REPLAY_LOG")
assert_contains "$r" "while replaying its WAL (died after segment=41 maxSegment=187)" "replay death at the cap -> logged with how far it got"
assert_contains "$r" "RESET" "replay death at the cap -> reset"
assert_contains "$r" 'PATCH {"data":{"prometheus-server.last_wal_reset_at":"20' "successful reset recorded in the sizing state"
assert_contains "$r" "Prometheus WAL reset: done" "success logged"

r=$(_decide true prometheus "$(ago 7200)" "$REPLAY_LOG")
assert_contains "$r" "skipped, the last one was 2h ago" "reset 2h ago -> skipped"
assert_eq "$(echo "$r" | grep -c RESET || true)" "0" "...no second reset"
r=$(_decide true prometheus "$(ago 90000)" "$REPLAY_LOG")
assert_contains "$r" "RESET" "last reset 25h ago -> reset again"
r=$(_decide true prometheus "not-a-date" "$REPLAY_LOG")
assert_contains "$r" "RESET" "unreadable last-reset value -> treated as none"

r=$(_decide true prometheus "" "$(printf '%s\n' "$L3_READY" "$L3_COMPACT")")
assert_contains "$r" "not needed" "OOM while running -> no reset"
assert_contains "$r" 'msg="write block"' "...and the last log lines are printed for diagnosis"
assert_eq "$(echo "$r" | grep -c RESET || true)" "0" "...reset not called"
r=$(_decide true prometheus "" "")
assert_contains "$r" "not needed" "no previous log -> no reset"

r=$(_decide true prometheus "" "$REPLAY_LOG" 361 900)
assert_contains "$r" "no time left in this Job" "361s used of 900 (under 300s for the reset) -> next run"
assert_eq "$(echo "$r" | grep -c RESET || true)" "0" "...reset not called"
r=$(_decide true prometheus "" "$REPLAY_LOG" 360 900)
assert_contains "$r" "RESET 660" "360s used of 900 -> reset, with the budget ending 240s before the deadline"
r=$(_decide true prometheus "" "$REPLAY_LOG" 500 "")
assert_contains "$r" "RESET " "unknown Job deadline -> not blocked"
assert_eq "$(echo "$r" | grep -c 'RESET [0-9]' || true)" "0" "...and no budget passed"

r=$(_decide false prometheus "" "$REPLAY_LOG")
assert_eq "$r" "--" "memory could still be raised -> nothing (the raise goes first)"
r=$(_decide true victoriametrics "" "$REPLAY_LOG")
assert_eq "$r" "--" "VictoriaMetrics -> nothing (no WAL replay)"

_decide_failed_reset() {
    (
        _OOM_LOOP_AT_CAP=true METRICS_BACKEND=prometheus JOB_DEADLINE=900
        _job_elapsed() { echo 100; }
        reset_prometheus_wal() { return 1; }
        kubectl() {
            case "$*" in
                "get pods -n onelens-agent -o json") echo "$OOM_POD_JSON" ;;
                logs*) printf '%s\n' "$REPLAY_LOG" ;;
                patch*) echo PATCHED ;;
                *) echo '{}' ;;
            esac
        }
        eval "$decision_block"
    )
}
r=$(_decide_failed_reset)
assert_contains "$r" "failed; the next run retries" "failed reset -> retried next run"
assert_eq "$(echo "$r" | grep -c PATCHED || true)" "0" "...and not recorded (no once-a-day hold)"

###############################################################################
# Test 6: without usage data the metrics backend keeps its CPU
###############################################################################
# _guard <helm cpu request> <helm cpu limit> <tier cpu> [usage_applied] [resources path]
_guard() {
    local req="$1" lim="$2" tier="$3" usage="${4:-false}" path="${5:-.prometheus.server.resources}"
    (
        USAGE_BASED_APPLIED="$usage" METRICS_LABEL=Prometheus METRICS_RESOURCES_PATH="$path"
        CURRENT_VALUES=$(jq -n --arg r "$req" --arg l "$lim" '{prometheus: {server: {resources: {requests: {cpu: $r, memory: "12288Mi"}, limits: {cpu: $l, memory: "12288Mi"}}}},
            "onelens-agent": {victoriaMetrics: {resources: {requests: {cpu: $r}, limits: {cpu: $l}}}}}')
        PROMETHEUS_CPU_REQUEST="$tier" PROMETHEUS_CPU_LIMIT="$tier"
        PROMETHEUS_MEMORY_REQUEST=2400Mi PROMETHEUS_MEMORY_LIMIT=2400Mi
        KSM_MEMORY_REQUEST=512Mi KSM_MEMORY_LIMIT=512Mi OPENCOST_MEMORY_REQUEST=768Mi OPENCOST_MEMORY_LIMIT=768Mi
        ONELENS_MEMORY_REQUEST=960Mi ONELENS_MEMORY_LIMIT=1280Mi
        eval "$guard_block" >/dev/null
        echo "$PROMETHEUS_CPU_REQUEST/$PROMETHEUS_CPU_LIMIT mem=$PROMETHEUS_MEMORY_LIMIT"
    )
}
assert_eq "$(_guard 0.8 0.8 600m)" "0.8/0.8 mem=12288Mi" "no usage data: 800m kept instead of the 600m tier (no restart)"
assert_eq "$(_guard 750m 750m 600m)" "750m/750m mem=12288Mi" "millicore strings kept as written"
assert_eq "$(_guard 400m 400m 600m)" "600m/600m mem=12288Mi" "tier above the current CPU -> tier (raise only)"
assert_eq "$(_guard 0.6 0.6 600m)" "0.6/0.6 mem=12288Mi" "same CPU in another notation -> existing string kept (no manifest change)"
assert_eq "$(_guard 0.8 0.8 600m true)" "600m/600m mem=2400Mi" "usage data available -> guard not applied"
assert_eq "$(_guard 0.9 1 600m false '.["onelens-agent"].victoriaMetrics.resources')" "0.9/1 mem=2400Mi" "VictoriaMetrics CPU kept the same way"
msg=$(USAGE_BASED_APPLIED=false METRICS_LABEL=Prometheus METRICS_RESOURCES_PATH=.prometheus.server.resources \
    CURRENT_VALUES='{"prometheus":{"server":{"resources":{"requests":{"cpu":"0.8"},"limits":{"cpu":"0.8"}}}}}' \
    PROMETHEUS_CPU_REQUEST=600m PROMETHEUS_CPU_LIMIT=600m bash -c "source '$(lib_dir)/resource-sizing.sh'; $guard_block")
assert_contains "$msg" "Prometheus CPU limit: keeping existing 0.8 (tier calculated 600m)" "kept CPU is logged"

test_summary
exit $?
