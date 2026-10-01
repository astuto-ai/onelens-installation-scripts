#!/bin/bash
# VictoriaMetrics sizing + remediation: the metrics backend must be sized, guarded and
# OOM-bumped through VM's own container/helm paths, not the (scaled-to-0) Prometheus server.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
source "$(lib_dir)/resource-sizing.sh"
set_test_file "test-vm-sizing.sh"
ROOT=$(repo_root)
PATCHING="$ROOT/src/patching.sh"

###############################################################################
# Test 1: apply_vm_memory_floor
###############################################################################
_floor() {
    local backend="$1" req="$2" lim="$3"
    (
        METRICS_BACKEND="$backend" PROMETHEUS_MEMORY_REQUEST="$req" PROMETHEUS_MEMORY_LIMIT="$lim"
        apply_vm_memory_floor
        echo "$PROMETHEUS_MEMORY_REQUEST/$PROMETHEUS_MEMORY_LIMIT"
    )
}
assert_eq "$(_floor victoriametrics 150Mi 150Mi)" "512Mi/512Mi" "VM tiny tier raised to 512Mi floor"
assert_eq "$(_floor victoriametrics 1600Mi 1600Mi)" "1600Mi/1600Mi" "VM above floor left unchanged"
assert_eq "$(_floor prometheus 150Mi 150Mi)" "150Mi/150Mi" "Prometheus tiny tier untouched by VM floor"
assert_eq "$(_floor "" 150Mi 150Mi)" "150Mi/150Mi" "unset backend treated as Prometheus"

###############################################################################
# Test 2: patching.sh metrics backend identity block
###############################################################################
identity_block=$(sed -n '/^# Metrics backend identity for sizing/,/^apply_vm_memory_floor$/p' "$PATCHING")
assert_ne "$identity_block" "" "patching.sh has metrics backend identity block"

_identity() {
    local backend="$1"
    (
        METRICS_BACKEND="$backend" PROMETHEUS_MEMORY_REQUEST=150Mi PROMETHEUS_MEMORY_LIMIT=150Mi
        eval "$identity_block"
        echo "$METRICS_COMPONENT|$METRICS_DEPLOYMENT|$METRICS_RESOURCES_PATH|$METRICS_MEM_FLOOR|$PROMETHEUS_MEMORY_LIMIT"
    )
}
assert_eq "$(_identity victoriametrics)" \
    'victoriametrics|onelens-agent-victoriametrics|.["onelens-agent"].victoriaMetrics.resources|512|512Mi' \
    "VM backend targets the VictoriaMetrics container, deployment, helm path and floor"
assert_eq "$(_identity prometheus)" \
    'prometheus-server|onelens-agent-prometheus-server|.prometheus.server.resources|150|150Mi' \
    "Prometheus backend keeps the Prometheus server targets"

# Resource paths must resolve against real helm values
vals='{"onelens-agent":{"victoriaMetrics":{"resources":{"limits":{"memory":"768Mi"}}}},"prometheus":{"server":{"resources":{"limits":{"memory":"1300Mi"}}}}}'
vm_path=$(METRICS_BACKEND=victoriametrics PROMETHEUS_MEMORY_REQUEST=150Mi PROMETHEUS_MEMORY_LIMIT=150Mi; eval "$identity_block"; echo "$METRICS_RESOURCES_PATH")
prom_path=$(METRICS_BACKEND=prometheus PROMETHEUS_MEMORY_REQUEST=150Mi PROMETHEUS_MEMORY_LIMIT=150Mi; eval "$identity_block"; echo "$METRICS_RESOURCES_PATH")
assert_eq "$(echo "$vals" | jq -r "${vm_path}.limits.memory")" "768Mi" "VM resources path reads VM helm value"
assert_eq "$(echo "$vals" | jq -r "${prom_path}.limits.memory")" "1300Mi" "Prometheus resources path reads Prometheus helm value"

###############################################################################
# Test 3: OOM bump targets VictoriaMetrics helm values
###############################################################################
bump_fn=$(sed -n '/^_bump_component_memory() {/,/^}/p' "$PATCHING")
assert_ne "$bump_fn" "" "patching.sh has _bump_component_memory"
eval "$bump_fn"

PROMETHEUS_MEMORY_LIMIT="512Mi"; PROMETHEUS_MEMORY_REQUEST="512Mi"
vm_bump=$(_bump_component_memory victoriametrics)
assert_eq "$(echo "$vm_bump" | awk '{print $1, $2}')" "512Mi 768Mi" "VM OOM bump is 1.5x (512Mi -> 768Mi)"
assert_contains "$vm_bump" 'onelens-agent.victoriaMetrics.resources.limits.memory="768Mi"' "VM bump sets VM limit"
assert_contains "$vm_bump" 'onelens-agent.victoriaMetrics.resources.requests.memory="768Mi"' "VM bump sets VM request"
vm_prom_flags=$(echo "$vm_bump" | grep -c 'prometheus.server.resources' || true)
assert_eq "$vm_prom_flags" "0" "VM bump does not touch Prometheus server values"

PROMETHEUS_MEMORY_LIMIT="1300Mi"; PROMETHEUS_MEMORY_REQUEST="1300Mi"
prom_bump=$(_bump_component_memory prometheus-server)
assert_contains "$prom_bump" 'prometheus.server.resources.limits.memory="1950Mi"' "Prometheus bump unchanged (1.5x on server values)"

###############################################################################
# Test 4: sizing and remediation look up the metrics pod via METRICS_COMPONENT
###############################################################################
eval_site=$(grep -c '_evaluate_and_log "\$METRICS_COMPONENT" "\$METRICS_COMPONENT"' "$PATCHING" || true)
assert_eq "$eval_site" "1" "usage-based sizing evaluates the metrics backend container"

mem_now_site=$(grep -c '_get_container_val "\$MEM_NOW" "\$METRICS_COMPONENT"' "$PATCHING" || true)
assert_eq "$mem_now_site" "1" "usage-based sizing reads current usage of the metrics backend container"

floor_site=$(grep -c '"\$METRICS_MEM_FLOOR" "\$_USAGE_CAP_PROM_MEM"' "$PATCHING" || true)
assert_eq "$floor_site" "1" "usage-based sizing uses the backend-specific memory floor"

oom_state=$(grep -c 'prometheus-server|victoriametrics) is_oom_recent' "$PATCHING" || true)
assert_eq "$oom_state" "1" "VM OOMs share the metrics-backend 7-day OOM hold"

upguard=$(grep -c '_upguard_mem "\${METRICS_RESOURCES_PATH}' "$PATCHING" || true)
assert_eq "$upguard" "2" "never-downsize guard reads current metrics backend memory"

legacy_guard=$(grep -c '_guard_memory "\$METRICS_LABEL' "$PATCHING" || true)
assert_eq "$legacy_guard" "2" "legacy memory guard reads current metrics backend memory"

scan_loop=$(grep -c 'for component in "\$METRICS_COMPONENT" kube-state-metrics' "$PATCHING" || true)
assert_eq "$scan_loop" "1" "failing-pod scan includes the metrics backend pod"

ready_checks=$(grep -c 'awk -v p="\$METRICS_COMPONENT"' "$PATCHING" || true)
assert_eq "$ready_checks" "3" "metrics readiness checks (scan, OpenCost dependency, agent trigger) use METRICS_COMPONENT"

kubectl_fallback=$(grep -c '_kubectl_set_resources "\$METRICS_DEPLOYMENT" "\$METRICS_COMPONENT"' "$PATCHING" || true)
assert_eq "$kubectl_fallback" "1" "kubectl resource fallback patches the metrics backend deployment"

###############################################################################
# Test 5: readiness match picks the VM pod when Prometheus server is scaled to 0
###############################################################################
pods='onelens-agent-kube-state-metrics-6b9cd9779-gjpmf   1/1   Running   0   2d
onelens-agent-victoriametrics-7fd687d66-9lmtp      1/1   Running   0   20h'
vm_ready=$(echo "$pods" | awk -v p="victoriametrics" '$1 ~ p {split($2,a,"/"); if(a[1]==a[2] && $3=="Running") print "yes"; exit}')
assert_eq "$vm_ready" "yes" "VM pod counts as a ready metrics backend"
prom_ready=$(echo "$pods" | awk -v p="prometheus-server" '$1 ~ p {split($2,a,"/"); if(a[1]==a[2] && $3=="Running") print "yes"; exit}')
assert_eq "$prom_ready" "" "Prometheus pattern finds nothing on a VM cluster (the old bug)"

###############################################################################
# Test 6: usage data for the VM container parses like any other container
###############################################################################
vm_usage='{"status":"success","data":{"result":[{"metric":{"container":"victoriametrics"},"value":[1,"485490688"]},{"metric":{"container":"kube-state-metrics"},"value":[1,"45088768"]}]}}'
parsed=$(parse_prom_result "$vm_usage")
assert_contains "$parsed" "victoriametrics 485490688" "VM container usage is parsed for sizing"

###############################################################################
# Test 7: install.sh applies the VM floor after tier sizing
###############################################################################
install_floor=$(sed -n '/^select_resource_tier "\$TOTAL_PODS"/,$p' "$ROOT/install.sh" | grep -c '^apply_vm_memory_floor$' || true)
assert_eq "$install_floor" "1" "install.sh applies the VM memory floor after tier selection"

###############################################################################
# Test 8: crash-looping OOM is classified as OOMKilled, not a code bug
###############################################################################
# Kernel OOM kills leave waiting=CrashLoopBackOff with OOMKilled only in lastState;
# classifying it as plain CrashLoopBackOff routed it to the "code bug" alert.
reason_fn=$(sed -n '/^_get_pod_failure_reason() {/,/^}/p' "$PATCHING")
assert_ne "$reason_fn" "" "patching.sh has _get_pod_failure_reason"
eval "$reason_fn"

_reason() {
    local term="$1" wait="$2" clb_last="$3" backend="${4:-victoriametrics}"
    (
        METRICS_BACKEND="$backend"
        kubectl() {
            case "$*" in
                *'waiting.reason=="CrashLoopBackOff"'*) echo "$clb_last" ;;
                *'?(@.state.terminated)]'*) echo "$term" ;;
                *'?(@.state.waiting)]'*) echo "$wait" ;;
                *) echo "" ;;
            esac
        }
        _get_pod_failure_reason "pod-x"
    )
}
assert_eq "$(_reason "" CrashLoopBackOff OOMKilled)" "OOMKilled" "CrashLoopBackOff with lastState OOMKilled -> OOMKilled"
assert_eq "$(_reason "" CrashLoopBackOff Error)" "CrashLoopBackOff" "CrashLoopBackOff from a non-OOM exit stays CrashLoopBackOff"
assert_eq "$(_reason OOMKilled "" "")" "OOMKilled" "currently terminated OOMKilled still OOMKilled"
assert_eq "$(_reason "" ImagePullBackOff "")" "ImagePullBackOff" "other waiting reasons unchanged"
# Prometheus clusters: classification must be exactly as before (no OOM re-routing,
# which would add kubectl bump+restart cycles = extra WAL replays)
assert_eq "$(_reason "" CrashLoopBackOff OOMKilled prometheus)" "CrashLoopBackOff" "Prometheus: crash-loop OOM classification unchanged"
assert_eq "$(_reason OOMKilled "" "" prometheus)" "OOMKilled" "Prometheus: terminated OOMKilled unchanged"
_calls() {
    local f; f=$(mktemp)
    (METRICS_BACKEND="$1"; kubectl() { echo call >> "$f"; echo Error; }; _get_pod_failure_reason "pod-x" >/dev/null)
    wc -l < "$f" | tr -d ' '; rm -f "$f"
}
assert_eq "$(_calls prometheus)" "2" "Prometheus: classifier makes the same 2 kubectl calls as before"
assert_eq "$(_calls victoriametrics)" "3" "VictoriaMetrics: classifier adds the lastState lookup"

###############################################################################
# Test 9: OOMs are recorded for the 7-day hold even without usage data
###############################################################################
# When the metrics backend is OOM-looping it serves no usage data, so the usage-based
# path (the only place OOMs were recorded) never ran.
record_block=$(sed -n '/# The metrics backend may have no data/,/Recorded OOM for 7-day/p' "$PATCHING"; echo "fi")
assert_ne "$(echo "$record_block" | grep -c 'build_sizing_state_patch')" "0" "no-data path records OOMs in sizing state"

_record() {
    local oom_list="$1" component="$2"
    (
        kubectl() { for a in "$@"; do case "$a" in '{'*) echo "$a" | jq -c . ;; esac; done; }
        OOM_KUBECTL="$oom_list" METRICS_COMPONENT="$component" METRICS_BACKEND="${3:-victoriametrics}"
        STATE_LAST_FULL_EVAL="2026-09-29T16:35:53Z"
        STATE_LAST_OOM_prometheus_server="" STATE_LAST_OOM_kube_state_metrics="2026-09-30T00:00:00Z"
        STATE_LAST_OOM_opencost="" STATE_LAST_OOM_pushgateway=""
        eval "$record_block" | grep '^{"data"'
    )
}
vm_rec=$(_record "victoriametrics" victoriametrics)
assert_ne "$(echo "$vm_rec" | jq -r '.data["prometheus-server.last_oom_at"]')" "" "VM OOM recorded in the metrics-backend OOM slot"
assert_eq "$(echo "$vm_rec" | jq -r '.data["kube-state-metrics.last_oom_at"]')" "2026-09-30T00:00:00Z" "other components' OOM state preserved"
assert_eq "$(echo "$vm_rec" | jq -r '.data.last_full_evaluation')" "2026-09-29T16:35:53Z" "last_full_evaluation preserved"
pgw_rec=$(_record "pushgateway" victoriametrics)
assert_ne "$(echo "$pgw_rec" | jq -r '.data["pushgateway.last_oom_at"]')" "" "pushgateway OOM recorded (container is named 'pushgateway')"
assert_eq "$(echo "$pgw_rec" | jq -r '.data["prometheus-server.last_oom_at"]')" "" "pushgateway OOM does not mark the metrics backend"
assert_eq "$(_record "" victoriametrics)" "" "nothing written when no OOMs detected"
assert_eq "$(_record "prometheus-server" prometheus-server prometheus)" "" "Prometheus: no-data OOM recording not applied (behavior unchanged)"

test_summary
exit $?
