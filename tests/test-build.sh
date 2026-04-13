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

###############################################################################
# Test 11: src/patching.sh must not use --force-conflicts with kubectl patch
# --force-conflicts is only valid for "kubectl apply --server-side", not
# "kubectl patch". On kubectl v1.28 (which patching.sh installs) it errors
# with "unknown flag: --force-conflicts", silently breaking CronJob patches.
###############################################################################
force_conflicts_count=$(grep -c '\-\-force-conflicts' "$SRC_FILE" || true)
assert_eq "$force_conflicts_count" "0" "src/patching.sh has no --force-conflicts (invalid for kubectl patch)"

###############################################################################
# Test 12: OOM remediation skips CronJob-owned (Job-owned) pods
# _remediate_oomkilled_pod uses "kubectl set resources deployment" which only
# works for Deployment-owned pods. Agent pods are CronJob-created (owned by
# Job), so the OOMKilled and CrashLoopBackOff→OOM branches must check
# ownerReferences before calling _remediate_oomkilled_pod.
###############################################################################
# Count ownerReferences checks near the OOM remediation routing logic
owner_checks=$(grep -c 'ownerReferences.*kind' "$SRC_FILE" || true)
assert_ge "$owner_checks" "3" "src/patching.sh checks ownerReferences for Job-owned pods (OOMKilled + CrashLoopBackOff + Terminated)"

###############################################################################
# Test 13: Terminated pods have an explicit case branch (not wildcard)
# Without this, terminated agent job pods log "Unknown failure reason" which
# makes patching_logs look broken when it's a normal completed/failed job.
###############################################################################
terminated_case=$(grep -c 'Terminated)' "$SRC_FILE" || true)
assert_ge "$terminated_case" "1" "src/patching.sh has explicit Terminated case in pod remediation"

###############################################################################
# Test 14: Pod counting uses raw API pagination (not per-namespace loop)
# kubectl get --all-namespaces buffers ALL objects in Go heap regardless of
# --chunk-size. Raw API with limit=100 keeps memory bounded at ~43MB.
###############################################################################
raw_api=$(grep -c 'get --raw' "$SRC_FILE" || true)
assert_ge "$raw_api" "1" "src/patching.sh uses kubectl get --raw for memory-bounded pod counting"

per_ns_loop=$(grep -c 'kubectl get deployments -n' "$SRC_FILE" || true)
assert_eq "$per_ns_loop" "0" "src/patching.sh has no per-namespace deployment counting"

# patching_mode is only set for clusters older than v2.1.55 (onboarding).
# Clusters on v2.1.55+ keep their DB-managed patching_mode value.
patching_mode_guarded=$(grep -c '_deployed_minor.*55' "$SRC_FILE" || true)
assert_ge "$patching_mode_guarded" "1" "src/patching.sh guards patching_mode behind version check"

###############################################################################
# Test 15: CronJob OOM self-healing — TTL patch + OOM detection
# If the previous updater pod was OOMKilled, patching.sh bumps CronJob memory
# to 512Mi. Requires ttlSecondsAfterFinished to be long enough for the pod to
# survive until the next run checks it.
###############################################################################
ttl_patch=$(grep -c 'ttlSecondsAfterFinished.*86400' "$SRC_FILE" || true)
assert_ge "$ttl_patch" "1" "src/patching.sh patches CronJob TTL to 86400 for OOM detection"

oom_detection=$(grep -c 'OOMKilled.*_UPDATER_OOM\|_UPDATER_OOM.*true' "$SRC_FILE" || true)
assert_ge "$oom_detection" "1" "src/patching.sh detects OOMKilled updater pods"

oom_bump=$(grep -c 'TARGET_MEMORY_MI=512' "$SRC_FILE" || true)
assert_ge "$oom_bump" "1" "src/patching.sh bumps CronJob memory to 512Mi on OOM"

###############################################################################
# Test 16: CronJob kubectl patches include image field
# Kubernetes strategic merge patch on container arrays requires the image field.
# Without it, kubectl returns "image: Required value" and the patch silently fails.
###############################################################################
updater_image_patch=$(grep -c 'UPDATER_IMAGE.*kubectl get cronjob onelensupdater' "$SRC_FILE" || true)
assert_ge "$updater_image_patch" "1" "src/patching.sh reads image before updater CronJob patch"

agent_cpu_image_patch=$(grep -c 'AGENT_IMAGE.*kubectl get cronjob.*AGENT_CJ_NAME' "$SRC_FILE" || true)
assert_ge "$agent_cpu_image_patch" "1" "src/patching.sh reads image before agent CronJob CPU patch"

###############################################################################
# Test 17: Updater CronJob never downsizes resources
# Customer-set values (e.g., 1Gi memory) must not be reset to 256Mi.
###############################################################################
never_downsize=$(grep -c 'CURRENT_MEM_MI.*-lt.*TARGET_MEMORY_MI' "$SRC_FILE" || true)
assert_ge "$never_downsize" "1" "src/patching.sh only patches updater CronJob memory upward"

no_hardcoded_256=$(grep -c 'TARGET_MEMORY_MI=256' "$SRC_FILE" || true)
assert_eq "$no_hardcoded_256" "0" "src/patching.sh has no hardcoded TARGET_MEMORY_MI=256 (never downsize)"

###############################################################################
# Test 18: Agent OOM memory bump handled via helm values (not kubectl patch)
# kubectl patches get overwritten by the next helm upgrade (~5 min).
# Agent OOM must bump ONELENS_MEMORY_LIMIT before the helm upgrade section.
###############################################################################
agent_oom_prehlem=$(grep -c '_AGENT_OOM_BUMPED=true' "$SRC_FILE" || true)
assert_ge "$agent_oom_prehlem" "1" "src/patching.sh bumps agent memory via helm values (pre-helm section)"

agent_mem_kubectl=$(grep -c 'kubectl patch.*AGENT_CJ_NAME.*memory' "$SRC_FILE" || true)
assert_eq "$agent_mem_kubectl" "0" "src/patching.sh does NOT kubectl patch agent CronJob memory (uses helm instead)"

###############################################################################
# Test 19: CronJob image reads use name-selector, not containers[0]
# v2.1.65 regression: sidecar injectors (Dynatrace, Istio) can insert containers
# at index 0, causing containers[0].image to return the sidecar's image. The
# strategic-merge patch would then rewrite the targeted container's image with
# the sidecar's image, silently breaking the CronJob. v2.1.66 fixes this by
# reading the image via jsonpath name-selector.
###############################################################################
# Positive: name-selector is used for image reads
updater_image_name_selector=$(grep -c 'containers\[?(@.name=="onelensupdater")\].image' "$SRC_FILE" || true)
assert_ge "$updater_image_name_selector" "1" "src/patching.sh reads updater image via name-selector (not containers[0])"

agent_image_name_selector=$(grep -c 'containers\[?(@.name==\\"\$AGENT_CONTAINER_NAME\\")\].image' "$SRC_FILE" || true)
assert_ge "$agent_image_name_selector" "1" "src/patching.sh reads agent image via name-selector (not containers[0])"

# Negative: image-reads that feed into kubectl-patch must not use containers[0]
updater_image_bad_index=$(grep -c 'UPDATER_IMAGE=.*kubectl get cronjob.*containers\[0\]\.image' "$SRC_FILE" || true)
assert_eq "$updater_image_bad_index" "0" "src/patching.sh updater image-read does not use containers[0] (sidecar safety)"

agent_image_bad_index=$(grep -c 'AGENT_IMAGE=.*kubectl get cronjob.*containers\[0\]\.image' "$SRC_FILE" || true)
assert_eq "$agent_image_bad_index" "0" "src/patching.sh agent image-read does not use containers[0] (sidecar safety)"

###############################################################################
# Test 20: CronJob resource reads (CPU/mem) also use name-selector
# Reads feed into patch-or-skip decisions — if a sidecar's resources are read
# instead, the script may wrongly decide "already at target" and skip bumping.
###############################################################################
updater_cpu_name_selector=$(grep -c 'containers\[?(@.name=="onelensupdater")\].resources.requests.cpu' "$SRC_FILE" || true)
assert_ge "$updater_cpu_name_selector" "1" "src/patching.sh reads updater CPU via name-selector"

updater_mem_name_selector=$(grep -c 'containers\[?(@.name=="onelensupdater")\].resources.requests.memory' "$SRC_FILE" || true)
assert_ge "$updater_mem_name_selector" "1" "src/patching.sh reads updater memory via name-selector"

###############################################################################
# Test 21: Sanity guards refuse to patch if image is unexpectedly not deployer/agent
# If v2.1.65 corrupted a CronJob's image (e.g., dynatrace/oneagent), v2.1.66 must
# NOT re-apply that corrupted image. Guard greps for expected product name in image.
###############################################################################
updater_image_sanity=$(grep -c "UPDATER_IMAGE\".*grep.*'onelens-deployer'" "$SRC_FILE" || true)
assert_ge "$updater_image_sanity" "1" "src/patching.sh sanity-guards updater image (refuses patch if not onelens-deployer)"

agent_image_sanity=$(grep -c "AGENT_IMAGE\".*grep.*'onelens-agent'" "$SRC_FILE" || true)
assert_ge "$agent_image_sanity" "1" "src/patching.sh sanity-guards agent image (refuses patch if not onelens-agent)"

test_summary
exit $?
