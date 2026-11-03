#!/bin/bash
# Customer overrides (deployer chart agentOverrides → ConfigMap onelens-agent-overrides):
# patching.sh must apply them exactly and leave them alone afterwards, change nothing
# when there are none, and entrypoint.sh must trigger one patching run per change.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
source "$(lib_dir)/resource-sizing.sh"
set_test_file "test-overrides.sh"
ROOT=$(repo_root)
PATCHING="$ROOT/src/patching.sh"
ENTRYPOINT="$ROOT/entrypoint.sh"
CHART="$ROOT/charts/onelensdeployer"

fn_block=$(sed -n '/^# --- Customer overrides (deployer chart value agentOverrides) ---$/,/^# A transient read error must not be treated/p' "$PATCHING" | sed '$d')
read_block=$(sed -n '/^# A transient read error must not be treated/,/^apply_customer_overrides "\$OVERRIDES_DATA"$/p' "$PATCHING")
assert_ne "$fn_block" "" "override functions found in patching.sh"
assert_ne "$read_block" "" "override read block found in patching.sh"
eval "$fn_block"

# Tier-like starting values, as sizing would leave them
_sizing_defaults() {
    PROMETHEUS_CPU_REQUEST=600m; PROMETHEUS_CPU_LIMIT=600m; PROMETHEUS_MEMORY_REQUEST=2400Mi; PROMETHEUS_MEMORY_LIMIT=2400Mi
    ONELENS_CPU_REQUEST=200m; ONELENS_CPU_LIMIT=600m; ONELENS_MEMORY_REQUEST=1280Mi; ONELENS_MEMORY_LIMIT=1280Mi
    OPENCOST_CPU_REQUEST=200m; OPENCOST_CPU_LIMIT=200m; OPENCOST_MEMORY_REQUEST=768Mi; OPENCOST_MEMORY_LIMIT=768Mi
    KSM_CPU_REQUEST=100m; KSM_CPU_LIMIT=100m; KSM_MEMORY_REQUEST=512Mi; KSM_MEMORY_LIMIT=512Mi
    PROMETHEUS_PUSHGATEWAY_CPU_REQUEST=50m; PROMETHEUS_PUSHGATEWAY_CPU_LIMIT=50m
    PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST=128Mi; PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT=128Mi
}
_all_vars() {
    local v
    for v in PROMETHEUS ONELENS OPENCOST KSM PROMETHEUS_PUSHGATEWAY; do
        eval "printf '%s ' \"\${${v}_CPU_REQUEST}/\${${v}_CPU_LIMIT}/\${${v}_MEMORY_REQUEST}/\${${v}_MEMORY_LIMIT}\""
    done
}
# _apply "$json" "$expr" — apply overrides to the defaults, then print $expr
_apply() {
    ( _sizing_defaults; apply_customer_overrides "$1" >/dev/null; eval "echo \"$2\"" )
}

###############################################################################
# Test 1: quantity parsing
###############################################################################
assert_eq "$(_override_quantity 24Gi memory)" "25769803776" "24Gi in bytes"
assert_eq "$(_override_quantity 1.5Gi memory)" "1610612736" "1.5Gi in bytes"
assert_eq "$(_override_quantity 512Mi memory)" "536870912" "512Mi in bytes"
assert_eq "$(_override_quantity 1G memory)" "1000000000" "1G (decimal) in bytes"
assert_eq "$(_override_quantity 500m cpu)" "500" "500m in millicores"
assert_eq "$(_override_quantity 2 cpu)" "2000" "2 cores in millicores"
assert_eq "$(_override_quantity 0.5 cpu)" "500" "0.5 cores in millicores"
for bad in 24GB 0 -1 "" 10x 1e3 "24 Gi"; do
    assert_eq "$(_override_quantity "$bad" memory)" "" "invalid memory '$bad' rejected"
done
assert_eq "$(_override_quantity 0.5m cpu)" "" "below 1 millicore rejected"
assert_eq "$(_override_quantity 2Gi cpu)" "" "memory unit on a cpu value rejected"

###############################################################################
# Test 2: entry validation
###############################################################################
assert_eq "$(_override_check images.prometheus us-docker.pkg.dev/p/mirror/prometheus)" "" "mirrored image repository accepted"
assert_eq "$(_override_check images.agent registry.local:5000/onelens-agent)" "" "registry with a port accepted"
assert_eq "$(_override_check images.victoriaMetrics victoriametrics/victoria-metrics)" "" "Docker Hub user/repo accepted"
assert_contains "$(_override_check images.prometheus quay.io/prometheus/prometheus:v3.5.4)" "without a tag" "image with a tag rejected"
assert_contains "$(_override_check images.prometheus quay.io/prometheus/prometheus@sha256:abc)" "without a tag" "image with a digest rejected"
assert_contains "$(_override_check images.prometheus prometheus)" "without a tag" "bare name without a registry rejected"
assert_contains "$(_override_check images.grafana a.io/grafana)" "unknown image" "unknown image name rejected"
assert_eq "$(_override_check resources.prometheus.limits.memory 24Gi)" "" "memory limit accepted"
assert_eq "$(_override_check resources.kubeStateMetrics.requests.cpu 250m)" "" "KSM cpu request accepted"
assert_contains "$(_override_check resources.prometheus.limits.memroy 24Gi)" "unknown setting" "misspelled resource rejected"
assert_contains "$(_override_check resources.grafana.limits.memory 1Gi)" "unknown setting" "unknown component rejected"
assert_contains "$(_override_check resources.prometheus.limits.memory 24GB)" "not a memory quantity" "24GB rejected"
assert_contains "$(_override_check resources.agent.limits.cpu 2Gi)" "not a CPU quantity" "memory unit on cpu rejected"
assert_contains "$(_override_check retention.days 30)" "unknown setting" "unsupported setting rejected"

###############################################################################
# Test 3: no overrides changes nothing
###############################################################################
_sizing_defaults; before=$(_all_vars)
for empty in "" "{}" "null"; do
    out=$( _sizing_defaults; apply_customer_overrides "$empty"; echo "VARS=$(_all_vars)|FLAGS=$OVERRIDE_IMAGE_FLAGS|ACC=$OVERRIDES_ACCEPTED" )
    assert_eq "$out" "VARS=$before|FLAGS=|ACC={}" "'$empty' overrides: no output, no variable or helm flag changed"
done

###############################################################################
# Test 4: a large-cluster request (mirrored quay.io images, 20/24Gi, agent 4/6Gi, OpenCost limit 8Gi)
###############################################################################
HL='{"images.configReloader":"us-docker.pkg.dev/p/mirror/prometheus-config-reloader","images.prometheus":"us-docker.pkg.dev/p/mirror/prometheus","images.pushgateway":"us-docker.pkg.dev/p/mirror/pushgateway","resources.agent.limits.memory":"6Gi","resources.agent.requests.memory":"4Gi","resources.opencost.limits.memory":"8Gi","resources.prometheus.limits.memory":"24Gi","resources.prometheus.requests.memory":"20Gi"}'
assert_eq "$(_apply "$HL" '$PROMETHEUS_MEMORY_REQUEST/$PROMETHEUS_MEMORY_LIMIT')" "20Gi/24Gi" "Prometheus memory request below its limit, as given"
assert_eq "$(_apply "$HL" '$ONELENS_MEMORY_REQUEST/$ONELENS_MEMORY_LIMIT')" "4Gi/6Gi" "agent memory as given"
assert_eq "$(_apply "$HL" '$OPENCOST_MEMORY_REQUEST/$OPENCOST_MEMORY_LIMIT')" "8Gi/8Gi" "OpenCost limit only: request matches it, as in Kubernetes"
assert_eq "$(_apply "$HL" '$PROMETHEUS_CPU_REQUEST/$PROMETHEUS_CPU_LIMIT/$KSM_MEMORY_LIMIT')" "600m/600m/512Mi" "settings not overridden keep sizing's values"
flags=$(_apply "$HL" '$OVERRIDE_IMAGE_FLAGS')
assert_contains "$flags" " --set prometheus.server.image.repository=us-docker.pkg.dev/p/mirror/prometheus" "Prometheus image flag"
assert_contains "$flags" " --set prometheus.configmapReload.prometheus.image.repository=us-docker.pkg.dev/p/mirror/prometheus-config-reloader" "config-reloader image flag"
assert_contains "$flags" " --set prometheus.prometheus-pushgateway.image.repository=us-docker.pkg.dev/p/mirror/pushgateway" "Pushgateway image flag"
assert_eq "$(echo "$flags" | grep -c 'tag=' || true)" "0" "no tag flags: OneLens keeps supplying tags"
report=$( _sizing_defaults; apply_customer_overrides "$HL" )
assert_contains "$report" "=== CUSTOMER OVERRIDES (onelens-agent-overrides) ===" "report header printed"
assert_contains "$report" "Applied: prometheus memory: request 20Gi, limit 24Gi (sizing would have set 2400Mi / 2400Mi)" "report shows what sizing would have set"

###############################################################################
# Test 5: one side given, and a request above its limit
###############################################################################
assert_eq "$(_apply '{"resources.prometheus.requests.memory":"4Gi"}' '$PROMETHEUS_MEMORY_REQUEST/$PROMETHEUS_MEMORY_LIMIT')" "4Gi/4Gi" "request above OneLens's limit raises the limit to it"
assert_eq "$(_apply '{"resources.prometheus.requests.memory":"1Gi"}' '$PROMETHEUS_MEMORY_REQUEST/$PROMETHEUS_MEMORY_LIMIT')" "1Gi/2400Mi" "request below OneLens's limit keeps the limit"
assert_eq "$(_apply '{"resources.prometheus.limits.memory":"1Gi"}' '$PROMETHEUS_MEMORY_REQUEST/$PROMETHEUS_MEMORY_LIMIT')" "1Gi/1Gi" "limit only: request matches it, whatever sizing had"
assert_eq "$(_apply '{"resources.agent.limits.cpu":"2"}' '$ONELENS_CPU_REQUEST/$ONELENS_CPU_LIMIT')" "2/2" "cpu limit only: request matches it"
bad_pair='{"resources.prometheus.requests.memory":"30Gi","resources.prometheus.limits.memory":"24Gi"}'
assert_eq "$(_apply "$bad_pair" '$PROMETHEUS_MEMORY_REQUEST/$PROMETHEUS_MEMORY_LIMIT')" "2400Mi/2400Mi" "request above limit: both rejected, sizing kept"
assert_contains "$(_apply "$bad_pair" '$OVERRIDES_REJECTED')" "the request is above the limit" "request above limit reported"
assert_eq "$(_apply "$bad_pair" '$OVERRIDES_ACCEPTED')" "{}" "rejected pair not left in the accepted set"

###############################################################################
# Test 6: invalid entries skipped, valid ones still applied
###############################################################################
mixed='{"resources.prometheus.limits.memory":"24GB","resources.agent.limits.memory":"6Gi","images.prometheus":"quay.io/prometheus/prometheus:v3"}'
assert_eq "$(_apply "$mixed" '$PROMETHEUS_MEMORY_LIMIT/$ONELENS_MEMORY_LIMIT/$OVERRIDE_IMAGE_FLAGS')" "2400Mi/6Gi/" "valid entry applied, invalid ones skipped"
rejected=$(_apply "$mixed" '$OVERRIDES_REJECTED')
assert_contains "$rejected" "resources.prometheus.limits.memory=24GB: not a memory quantity" "bad quantity reported"
assert_contains "$rejected" "images.prometheus=quay.io/prometheus/prometheus:v3: not an image repository" "image with tag reported"

###############################################################################
# Test 7: registry/repository split for charts that use both
###############################################################################
split='{"images.kubeStateMetrics":"us-docker.pkg.dev/p/mirror/kube-state-metrics","images.opencost":"us-docker.pkg.dev/p/mirror/opencost"}'
flags=$(_apply "$split" '$OVERRIDE_IMAGE_FLAGS')
assert_contains "$flags" " --set prometheus.kube-state-metrics.image.registry=us-docker.pkg.dev/p/mirror --set prometheus.kube-state-metrics.image.repository=kube-state-metrics" "KSM registry and repository"
assert_contains "$flags" " --set prometheus-opencost-exporter.opencost.exporter.image.registry=us-docker.pkg.dev/p/mirror --set prometheus-opencost-exporter.opencost.exporter.image.repository=opencost" "OpenCost registry and repository"

###############################################################################
# Test 8: _override_holds maps every name the remediation paths use
###############################################################################
_holds() { ( OVERRIDES_ACCEPTED="$1"; _override_holds "$2" "$3" && echo yes || echo no ); }
mem_prom='{"resources.prometheus.limits.memory":"24Gi"}'
assert_eq "$(_holds "$mem_prom" prometheus-server memory)" "yes" "retry-loop name prometheus-server"
assert_eq "$(_holds "$mem_prom" victoriametrics memory)" "yes" "VictoriaMetrics uses the prometheus override"
assert_eq "$(_holds "$mem_prom" onelens-agent-prometheus-server memory)" "yes" "deployment name onelens-agent-prometheus-server"
assert_eq "$(_holds "$mem_prom" prometheus-server cpu)" "no" "memory override doesn't hold cpu"
assert_eq "$(_holds '{"resources.opencost.requests.cpu":"500m"}' onelens-agent-prometheus-opencost-exporter cpu)" "yes" "OpenCost deployment, request only"
assert_eq "$(_holds '{"resources.kubeStateMetrics.limits.memory":"1Gi"}' kube-state-metrics memory)" "yes" "KSM"
assert_eq "$(_holds '{"resources.pushgateway.limits.memory":"256Mi"}' prometheus-pushgateway memory)" "yes" "Pushgateway"
assert_eq "$(_holds '{"resources.agent.limits.cpu":"2"}' onelens-agent cpu)" "yes" "agent CronJob"
assert_eq "$(_holds '{}' prometheus-server memory)" "no" "no overrides holds nothing"
assert_eq "$(_holds "$mem_prom" something-else memory)" "no" "unknown name holds nothing"

###############################################################################
# Test 9: reading the ConfigMap (not found, found, other error)
###############################################################################
_read() {
    local kubectl_out="$1" kubectl_rc="$2"
    (
        kubectl() { echo "$kubectl_out"; return "$kubectl_rc"; }
        _sizing_defaults
        eval "$read_block" >/dev/null
        echo "$OVERRIDES_DATA|$PROMETHEUS_MEMORY_LIMIT"
    )
}
assert_eq "$(_read 'Error from server (NotFound): configmaps "onelens-agent-overrides" not found' 1)" "{}|2400Mi" "no ConfigMap: no overrides, run continues"
assert_eq "$(_read '{"data":{"resources.prometheus.limits.memory":"24Gi"}}' 0)" '{"resources.prometheus.limits.memory":"24Gi"}|24Gi' "ConfigMap read and applied"
assert_eq "$(_read '{"metadata":{}}' 0)" "{}|2400Mi" "ConfigMap without data: no overrides"
set +e
err_out=$( kubectl() { echo 'Unable to connect to the server: dial tcp 10.0.0.1:443: i/o timeout'; return 1; }; eval "$read_block" 2>&1 )
err_rc=$?
set -e
assert_eq "$err_rc" "1" "transient read error stops the run instead of undoing overrides"
assert_contains "$err_out" "Stopping before helm upgrade" "read error explained"
forbidden=$(_read 'Error from server (Forbidden): configmaps "onelens-agent-overrides" is forbidden' 1)
assert_eq "$forbidden" "{}|2400Mi" "Forbidden (broken RBAC): run continues without overrides instead of failing forever"

###############################################################################
# Test 10: entrypoint.sh triggers one run per overrides change
###############################################################################
check6=$(sed -n '/^    # Check 6: customer overrides changed/,/^    # ─── Routing: healthy vs unhealthy/p' "$ENTRYPOINT" | sed '$d')
assert_ne "$check6" "" "Check 6 found in entrypoint.sh"
# _check6 "$cm_out" "$cm_rc" "$status_out" "$status_rc" → "<reasons>|<changed>|<hash>"
_check6() {
    (
        export STUB_CM_OUT="$1" STUB_CM_RC="$2" STUB_ST_OUT="$3" STUB_ST_RC="$4"
        kubectl() {
            case "$*" in
                *onelens-agent-overrides-status*) echo "$STUB_ST_OUT"; return "$STUB_ST_RC" ;;
                *onelens-agent-overrides*) echo "$STUB_CM_OUT"; return "$STUB_CM_RC" ;;
            esac
        }
        UNHEALTHY_REASONS=""
        eval "$check6"
        printf '%s|%s|%s' "$(printf '%b' "$UNHEALTHY_REASONS" | tr -d '\n')" "$_OVERRIDES_CHANGED" "${OVERRIDES_HASH:-}"
    )
}
NF_CM='Error from server (NotFound): configmaps "onelens-agent-overrides" not found'
NF_ST='Error from server (NotFound): configmaps "onelens-agent-overrides-status" not found'
CM='{"data":{"resources.prometheus.limits.memory":"24Gi","images.prometheus":"a.io/p/prometheus"}}'
r=$(_check6 "$NF_CM" 1 "$NF_ST" 1)
assert_eq "$r" "|false|" "no overrides ever: healthy, no run"
r=$(_check6 "$CM" 0 "$NF_ST" 1)
assert_eq "${r%|*}" "Overrides changed (onelens-agent-overrides)|true" "new overrides trigger a run"
hash="${r##*|}"
# The hash must be the one patching.sh records for the same ConfigMap
p_hash=$( kubectl() { echo "$CM"; return 0; }; _sizing_defaults; eval "$read_block" >/dev/null; echo "$OVERRIDES_HASH" )
assert_eq "$hash" "$p_hash" "entrypoint.sh and patching.sh hash the same ConfigMap identically"
assert_eq "$(_check6 "$CM" 0 "$hash" 0)" "|false|$hash" "already requested: no repeat run"
r=$(_check6 "$NF_CM" 1 "$hash" 0)
assert_eq "${r%|*}" "Overrides changed (onelens-agent-overrides)|true" "overrides removed: one run puts OneLens values back"
empty_hash=$(printf '%s' '{}' | sha256sum | awk '{print $1}')
assert_eq "$(_check6 "$NF_CM" 1 "$empty_hash" 0)" "|false|$empty_hash" "removal already requested: no repeat run"
assert_eq "$(_check6 'Error from server (Forbidden): forbidden' 1 "$NF_ST" 1)" "|false|" "overrides unreadable: check skipped"
assert_eq "$(_check6 "$CM" 0 'Unable to connect to the server' 1)" "|false|" "status unreadable: check skipped"
assert_contains "$(sed -n '/Patching script downloaded, executing for remediation/,/export PATCHING_VERSION/p' "$ENTRYPOINT")" 'requested_hash' "requested_hash recorded before patching.sh runs"
assert_contains "$(grep '_non_version_reasons=' "$ENTRYPOINT")" 'grep -v "Overrides changed"' "a pending overrides change alone doesn't count as unhealthy when the script fetch fails"

###############################################################################
# Test 11: remediation and the retry loop leave overrides alone
###############################################################################
oom_fn=$(sed -n '/^_remediate_oomkilled_pod() {/,/^}/p' "$PATCHING")
calls=$(mktemp)
(
    kubectl() { echo "$*" >> "$calls"; echo "prometheus-server"; }
    OVERRIDES_ACCEPTED='{"resources.prometheus.limits.memory":"24Gi"}'
    eval "$oom_fn"
    _remediate_oomkilled_pod onelens-agent-prometheus-server-abc-123 onelens-agent-prometheus-server >/dev/null || true
)
assert_eq "$(grep -c 'set resources\|delete pod' "$calls" || true)" "0" "OOM remediation doesn't touch an overridden component"
rm -f "$calls"
retry_guard=$(grep -n '_override_holds "\$_FAIL_COMPONENT" "\$_ovr_res"' "$PATCHING" | cut -d: -f1)
bump_line=$(grep -n '_bump_result=\$(_bump_component_memory "\$_FAIL_COMPONENT")' "$PATCHING" | cut -d: -f1)
assert_ne "$retry_guard" "" "retry loop checks overrides"
assert_lt "$retry_guard" "$bump_line" "retry loop checks overrides before bumping"
assert_contains "$(sed -n '/^_remediate_cpu_starved_pod() {/,/^}/p' "$PATCHING")" '_override_holds "$deploy_name" cpu' "OpenCost CPU remediation checks overrides"
assert_contains "$(grep -A1 'AGENT_CPU_MC=\$(_cpu_to_millicores' "$PATCHING")" '_override_holds onelens-agent cpu' "agent CronJob CPU patch checks overrides"

###############################################################################
# Test 12: helm command order and placement after sizing
###############################################################################
apply_line=$(grep -n '^apply_customer_overrides "\$OVERRIDES_DATA"$' "$PATCHING" | cut -d: -f1)
guard_line=$(grep -n '_guard_memory "Agent limit"' "$PATCHING" | cut -d: -f1)
agent_bump_line=$(grep -n '^# Apply the bump (Strategy 1 only' "$PATCHING" | cut -d: -f1)
kubectl_path_line=$(grep -n '^if \[ "\$SKIP_HELM_UPGRADE" = "true" \]; then$' "$PATCHING" | tail -1 | cut -d: -f1)
airgap_line=$(grep -n 'Applying air-gapped image overrides for registry' "$PATCHING" | cut -d: -f1)
image_flags_line=$(grep -n 'HELM_CMD="\$HELM_CMD \$OVERRIDE_IMAGE_FLAGS"' "$PATCHING" | cut -d: -f1)
assert_gt "$apply_line" "$guard_line" "overrides applied after the no-data memory guard"
assert_gt "$apply_line" "$agent_bump_line" "overrides applied after the agent OOM bump"
assert_lt "$apply_line" "$kubectl_path_line" "overrides applied before the kubectl (helm-blocked) path"
assert_gt "$image_flags_line" "$airgap_line" "image overrides come after the air-gapped registry settings"

###############################################################################
# Test 13: status ConfigMap
###############################################################################
status_block=$(sed -n "/^# Report the customer overrides' outcome/,/^    echo \"Customer overrides: \\\$_ovr_result\"\$/p" "$PATCHING"; echo "fi")
_status() {
    local data="$1" skip="$2" failed="$3" status_exists="$4" calls
    calls=$(mktemp)
    (
        kubectl() {
            echo "$*" >> "$calls"
            case "$*" in
                "get configmap onelens-agent-overrides-status"*) [ "$status_exists" = yes ] ;;
                *) return 0 ;;
            esac
        }
        OVERRIDES_DATA="$data" SKIP_HELM_UPGRADE="$skip" UPGRADE_FAILED="$failed"
        OVERRIDES_REPORT="prometheus memory: request 20Gi, limit 24Gi" OVERRIDES_REJECTED="" OVERRIDES_HASH="h"
        eval "$status_block" >/dev/null
    )
    grep '^patch configmap onelens-agent-overrides-status' "$calls" | grep -o '"result":"[^"]*"' || echo "no-write"
    rm -f "$calls"
}
assert_eq "$(_status '{"a":"b"}' false false no)" '"result":"applied"' "applied after a successful upgrade"
assert_eq "$(_status '{"a":"b"}' false true no)" '"result":"helm upgrade failed; see patching logs"' "failed upgrade reported"
assert_contains "$(_status '{"a":"b"}' true true no)" "helm upgrade was skipped" "kubectl-only run reported as not applied"
assert_eq "$(_status '{}' false false no)" "no-write" "no overrides and no status ConfigMap: nothing written"
assert_eq "$(_status '{}' false false yes)" '"result":"no overrides; OneLens manages all settings"' "overrides removed: status says so"

###############################################################################
# Test 14: deployer chart, schema, and the key lists staying in sync
###############################################################################
if ! command -v helm &>/dev/null; then
    echo "  (helm not found: chart tests skipped)"
else
    assert_eq "$(helm template t "$CHART" 2>&1 | grep -c 'name: onelens-agent-overrides' || true)" "0" "no overrides: no ConfigMap rendered"
    rendered=$(helm template t "$CHART" --show-only templates/agent-overrides-configmap.yaml \
        --set agentOverrides.images.prometheus=us-docker.pkg.dev/p/mirror/prometheus \
        --set agentOverrides.resources.prometheus.requests.memory=20Gi \
        --set agentOverrides.resources.prometheus.limits.memory=24Gi \
        --set agentOverrides.resources.agent.limits.cpu=2 2>&1)
    assert_contains "$rendered" 'images.prometheus: "us-docker.pkg.dev/p/mirror/prometheus"' "image key rendered"
    assert_contains "$rendered" 'resources.prometheus.limits.memory: "24Gi"' "memory key rendered"
    assert_contains "$rendered" 'resources.agent.limits.cpu: "2"' "numeric cpu rendered as a string"
    # What the chart renders must pass patching.sh's own validation
    rendered_json=$(echo "$rendered" | yq -o=json '.data' 2>/dev/null || true)
    if [ -n "$rendered_json" ]; then
        assert_eq "$(_apply "$rendered_json" '$OVERRIDES_REJECTED')" "" "rendered ConfigMap passes patching.sh validation"
    fi
    _schema_rejects() { helm template t "$CHART" "$@" >/dev/null 2>&1 && echo accepted || echo rejected; }
    assert_eq "$(_schema_rejects --set agentOverrides.resources.prometheus.limits.memroy=24Gi)" "rejected" "schema rejects a misspelled key"
    assert_eq "$(_schema_rejects --set agentOverrides.resources.prometheus.limits.memory=24GB)" "rejected" "schema rejects 24GB"
    assert_eq "$(_schema_rejects --set agentOverrides.images.prometheus=quay.io/prometheus/prometheus:v3)" "rejected" "schema rejects an image with a tag"
    assert_eq "$(_schema_rejects --set agentOverrides.images.grafana=a.io/grafana)" "rejected" "schema rejects an unknown image"
    assert_eq "$(_schema_rejects --set job.env.CLUSTER_NAME=c --set job.env.REGION=r --set-string job.env.ACCOUNT=0123 \
        --set job.env.REGISTRATION_TOKEN=x --set 'job.tolerations[0].key=a' --set podCountOverride=5000 \
        --set proxy.httpProxy=http://p:8080 --set globals.labels.team=x --set cronjob.suspend=true)" "accepted" "schema accepts existing install options"
    if command -v yq &>/dev/null; then
        assert_eq "$(yq '.agentOverrides.images | keys | join(" ")' "$CHART/values.yaml")" \
            "$(echo $OVERRIDE_IMAGE_NAMES)" "values.yaml image names match patching.sh"
        assert_eq "$(yq '.agentOverrides.resources | keys | join(" ")' "$CHART/values.yaml")" \
            "$(echo $OVERRIDE_RESOURCE_COMPONENTS)" "values.yaml components match patching.sh"
        assert_eq "$(jq -r '.properties.agentOverrides.properties.images.properties | keys_unsorted | join(" ")' "$CHART/values.schema.json")" \
            "$(echo $OVERRIDE_IMAGE_NAMES)" "schema image names match patching.sh"
        assert_eq "$(jq -r '.properties.agentOverrides.properties.resources.properties | keys_unsorted | join(" ")' "$CHART/values.schema.json")" \
            "$(echo $OVERRIDE_RESOURCE_COMPONENTS)" "schema components match patching.sh"
    fi
fi

test_summary
