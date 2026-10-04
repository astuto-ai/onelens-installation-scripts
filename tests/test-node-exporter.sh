#!/bin/bash
# Node exporter is opt-in: nothing reads its metrics yet, and air-gapped registries
# don't carry its image (a missing image left its DaemonSet in ImagePullBackOff and the
# updater in a patch loop). install.sh and patching.sh must agree on the decision.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
set_test_file "test-node-exporter.sh"
ROOT=$(repo_root)
INSTALL="$ROOT/install.sh"
PATCHING="$ROOT/src/patching.sh"

###############################################################################
# Test 1: decision block (same logic in both scripts)
###############################################################################
install_block=$(sed -n '/^# --- Node Exporter: opt-in/,/^fi$/p' "$INSTALL")
patching_block=$(sed -n '/^# --- Node Exporter: opt-in/,/^fi$/p' "$PATCHING")
assert_ne "$install_block" "" "install.sh has the node-exporter opt-in block"
assert_ne "$patching_block" "" "patching.sh has the node-exporter opt-in block"

# _decide <script> <opt-in value> <our release's prometheus-node-exporter.enabled> <DaemonSets JSON>
#   -> "<enabled> <kubectl calls>"
# Release values come from `helm get values` (install.sh) / CURRENT_VALUES (patching.sh).
_decide() {
    local script="$1" opt_in="$2" in_release="$3" ds_json="$4" calls values=""
    calls=$(mktemp)
    [ -n "$in_release" ] && values="{\"prometheus\":{\"prometheus-node-exporter\":{\"enabled\":$in_release}}}"
    (
        kubectl() { echo call >> "$calls"; echo "$ds_json"; }
        helm() { [ -n "$values" ] && echo "$values"; }
        if [ "$script" = install ]; then
            NODE_EXPORTER_ENABLED="$opt_in"
            eval "$install_block" >/dev/null
        else
            NODE_EXPORTER_OPT_IN="$opt_in"
            CURRENT_VALUES="$values"
            eval "$patching_block" >/dev/null
        fi
        echo "$NODE_EXPORTER_ENABLED $(wc -l < "$calls" | tr -d ' ')"
    )
    rm -f "$calls"
}
NONE='{"items":[]}'
THEIRS='{"items":[{"metadata":{"name":"prometheus-operator-prometheus-node-exporter","namespace":"monitoring"}}]}'
OURS='{"items":[{"metadata":{"name":"onelens-agent-prometheus-node-exporter","namespace":"onelens-agent"}}]}'

for s in install patching; do
    # New installs / releases without ours: off by default
    assert_eq "$(_decide $s "" "" "$NONE")" "false 0" "$s: fresh install, not opted in -> not deployed, no cluster lookup"
    assert_eq "$(_decide $s "" false "$NONE")" "false 0" "$s: release without ours, not opted in -> stays off"
    assert_eq "$(_decide $s false "" "$NONE")" "false 0" "$s: opted out -> not deployed"
    assert_eq "$(_decide $s TRUE "" "$NONE")" "false 0" "$s: only the exact value 'true' opts in"
    # Opt-in
    assert_eq "$(_decide $s true "" "$NONE")" "true 1" "$s: opted in, none in cluster -> deployed"
    assert_eq "$(_decide $s true "" "$THEIRS")" "false 1" "$s: opted in, customer already runs one -> not deployed"
    # Already deployed by our release: left as it is (same as before 2.1.120)
    assert_eq "$(_decide $s "" true "$OURS")" "true 1" "$s: release already deploys ours -> kept"
    assert_eq "$(_decide $s "" true "$NONE")" "true 1" "$s: release already deploys ours (DaemonSet missing) -> kept"
    assert_eq "$(_decide $s "" true "$THEIRS")" "false 1" "$s: release has ours but customer runs one -> not deployed (unchanged since 2.1.113)"
done

###############################################################################
# Test 2: the opt-in is persisted (as a string) so patching keeps it
###############################################################################
install_persist=$(grep -c -- '--set-string onelens-agent.env.NODE_EXPORTER_ENABLED=true' "$INSTALL" || true)
patching_persist=$(grep -c -- '--set-string onelens-agent.env.NODE_EXPORTER_ENABLED=true' "$PATCHING" || true)
assert_eq "$install_persist" "1" "install.sh persists the opt-in with --set-string"
assert_eq "$patching_persist" "1" "patching.sh re-persists the opt-in with --set-string"

reads_opt_in=$(grep -c "NODE_EXPORTER_OPT_IN=\$(_get '.\[\"onelens-agent\"\].env.NODE_EXPORTER_ENABLED')" "$PATCHING" || true)
assert_eq "$reads_opt_in" "1" "patching.sh reads the persisted opt-in from the release values"

# Persisted only when opted in: the --set-string line sits inside an opt-in guard
for f in "$INSTALL" "$PATCHING"; do
    guard=$(grep -B2 -- '--set-string onelens-agent.env.NODE_EXPORTER_ENABLED=true' "$f" | grep -cE 'NODE_EXPORTER_OPT_IN(:-)?\}?" = "true"' || true)
    assert_eq "$guard" "1" "$(basename "$f"): opt-in persisted only when opted in"
done

###############################################################################
# Test 3: chart still renders the decision (enabled flag passed every run)
###############################################################################
for f in "$INSTALL" "$PATCHING"; do
    flag=$(grep -c 'prometheus.prometheus-node-exporter.enabled=\$NODE_EXPORTER_ENABLED' "$f" || true)
    assert_eq "$flag" "1" "$(basename "$f"): passes prometheus-node-exporter.enabled every run"
done

###############################################################################
# Test 4: migration script mirrors node-exporter for clusters that opt in
###############################################################################
# install.sh/patching.sh point an opted-in node-exporter at $REGISTRY_URL/node-exporter
# (sub-chart tag v<appVersion>), so the mirror must produce exactly that target.
MIGRATE="$ROOT/scripts/airgapped/airgapped_migrate_images.sh"
ne_block=$(awk '/^# node-exporter \(deployed only/{f=1} f{print} f && /Skipping node-exporter/{getline; print; exit}' "$MIGRATE")
assert_ne "$ne_block" "" "migration script has the node-exporter block"

_mirror() {
    local app_version="$1" dir
    dir=$(mktemp -d)
    if [ -n "$app_version" ]; then
        mkdir -p "$dir/onelens-agent/charts/prometheus/charts/prometheus-node-exporter"
        printf 'name: prometheus-node-exporter\nappVersion: %s\n' "$app_version" \
            > "$dir/onelens-agent/charts/prometheus/charts/prometheus-node-exporter/Chart.yaml"
    fi
    ( TMPDIR="$dir"; IMAGES=""; eval "$ne_block" >/dev/null; echo "$IMAGES" | sed '/^$/d' )
    rm -rf "$dir"
}
assert_eq "$(_mirror 1.8.2)" "quay.io/prometheus/node-exporter:v1.8.2 node-exporter:v1.8.2" "node-exporter mirrored to <registry>/node-exporter:v<appVersion>"
assert_eq "$(_mirror '"1.9.0"')" "quay.io/prometheus/node-exporter:v1.9.0 node-exporter:v1.9.0" "double-quoted appVersion handled"
assert_eq "$(_mirror "'1.9.0'")" "quay.io/prometheus/node-exporter:v1.9.0 node-exporter:v1.9.0" "single-quoted appVersion handled"
assert_eq "$(_mirror "")" "" "no sub-chart -> skipped with a warning, not a broken entry"

test_summary
