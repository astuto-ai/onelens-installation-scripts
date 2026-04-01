#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
set_test_file "test-upgrade-path.sh"
ROOT=$(repo_root)

# ---------------------------------------------------------------------------
# Test 1: install.sh has IS_UPGRADE detection variable
# ---------------------------------------------------------------------------
upgrade_var=$(grep -c 'IS_UPGRADE=false' "$ROOT/install.sh" || true)
assert_gt "$upgrade_var" "0" "install.sh initializes IS_UPGRADE=false"

# ---------------------------------------------------------------------------
# Test 2: install.sh reads credentials from onelens-agent-secrets
# ---------------------------------------------------------------------------
secret_read=$(grep -c 'onelens-agent-secrets' "$ROOT/install.sh" || true)
assert_gt "$secret_read" "0" "install.sh references onelens-agent-secrets for existing install detection"

# ---------------------------------------------------------------------------
# Test 3: install.sh decodes REGISTRATION_ID from secret
# ---------------------------------------------------------------------------
reg_decode=$(grep 'REGISTRATION_ID' "$ROOT/install.sh" | grep -c 'base64' || true)
assert_gt "$reg_decode" "0" "install.sh decodes REGISTRATION_ID from base64 secret"

# ---------------------------------------------------------------------------
# Test 4: install.sh decodes CLUSTER_TOKEN from secret
# ---------------------------------------------------------------------------
token_decode=$(grep 'CLUSTER_TOKEN' "$ROOT/install.sh" | grep -c 'base64' || true)
assert_gt "$token_decode" "0" "install.sh decodes CLUSTER_TOKEN from base64 secret"

# ---------------------------------------------------------------------------
# Test 5: Registration API call is conditional on IS_UPGRADE
# ---------------------------------------------------------------------------
conditional_reg=$(grep -c 'IS_UPGRADE.*!=.*true' "$ROOT/install.sh" || true)
assert_gt "$conditional_reg" "0" "install.sh conditionally skips registration when already installed"

# ---------------------------------------------------------------------------
# Test 6: REGISTRATION_TOKEN validation is inside the fresh-install block
# ---------------------------------------------------------------------------
token_line=$(grep -n 'REGISTRATION_TOKEN' "$ROOT/install.sh" | grep 'is not set' | head -1 | cut -d: -f1)
upgrade_line=$(grep -n 'IS_UPGRADE.*!=.*true' "$ROOT/install.sh" | head -1 | cut -d: -f1)
if [ -n "$token_line" ] && [ -n "$upgrade_line" ] && [ "$token_line" -gt "$upgrade_line" ]; then
    assert_eq "1" "1" "REGISTRATION_TOKEN validation is after existing install detection"
else
    assert_eq "0" "1" "REGISTRATION_TOKEN validation is after existing install detection"
fi

# ---------------------------------------------------------------------------
# Test 7: kubectl is installed BEFORE existing install detection
# ---------------------------------------------------------------------------
kubectl_install_line=$(grep -n 'Installing kubectl' "$ROOT/install.sh" | head -1 | cut -d: -f1)
upgrade_detect_line=$(grep -n 'Detect existing installation' "$ROOT/install.sh" | head -1 | cut -d: -f1)
if [ -n "$kubectl_install_line" ] && [ -n "$upgrade_detect_line" ] && [ "$kubectl_install_line" -lt "$upgrade_detect_line" ]; then
    assert_eq "1" "1" "kubectl is installed before existing install detection"
else
    assert_eq "0" "1" "kubectl is installed before existing install detection"
fi

# ---------------------------------------------------------------------------
# Test 8: helm is installed BEFORE existing install detection
# ---------------------------------------------------------------------------
helm_install_line=$(grep -n 'Installing Helm' "$ROOT/install.sh" | head -1 | cut -d: -f1)
if [ -n "$helm_install_line" ] && [ -n "$upgrade_detect_line" ] && [ "$helm_install_line" -lt "$upgrade_detect_line" ]; then
    assert_eq "1" "1" "helm is installed before existing install detection"
else
    assert_eq "0" "1" "helm is installed before existing install detection"
fi

# ---------------------------------------------------------------------------
# Test 9: Finalization is unified (no separate install vs upgrade paths)
# ---------------------------------------------------------------------------
deploy_complete=$(grep -c 'Installation complete' "$ROOT/install.sh" || true)
assert_gt "$deploy_complete" "0" "install.sh has unified finalization message"

# PUT CONNECTED always runs (idempotent, confirms cluster is connected)
put_connected=$(grep -c 'CONNECTED' "$ROOT/install.sh" || true)
assert_gt "$put_connected" "0" "PUT CONNECTED status always runs"

# ---------------------------------------------------------------------------
# Test 10: check_var still validates CLUSTER_TOKEN and REGISTRATION_ID
# ---------------------------------------------------------------------------
check_token=$(grep -c 'check_var CLUSTER_TOKEN' "$ROOT/install.sh" || true)
check_reg=$(grep -c 'check_var REGISTRATION_ID' "$ROOT/install.sh" || true)
assert_gt "$check_token" "0" "install.sh validates CLUSTER_TOKEN before helm deploy"
assert_gt "$check_reg" "0" "install.sh validates REGISTRATION_ID before helm deploy"

# ---------------------------------------------------------------------------
# Test 11: Detection guards against incomplete credentials
# ---------------------------------------------------------------------------
incomplete_guard=$(grep -c 'credentials are incomplete' "$ROOT/install.sh" || true)
assert_gt "$incomplete_guard" "0" "install.sh handles incomplete secret credentials"

# ---------------------------------------------------------------------------
# Test 12: Bootstrap RBAC cleanup uses stderr suppression
# ---------------------------------------------------------------------------
cleanup_safe=$(grep 'bootstrap-clusterrolebinding' "$ROOT/install.sh" | grep -c '2>/dev/null || true' || true)
assert_gt "$cleanup_safe" "0" "bootstrap RBAC cleanup suppresses errors for already-deleted resources"

# ---------------------------------------------------------------------------
# Test 13: helm upgrade --install is used (works for both install and upgrade)
# ---------------------------------------------------------------------------
upgrade_install=$(grep -c 'helm upgrade --install' "$ROOT/install.sh" || true)
assert_gt "$upgrade_install" "0" "install.sh uses 'helm upgrade --install' (handles both cases)"

# ---------------------------------------------------------------------------
# Test 14: install.sh registers CONNECTED and delegates pod health to patching CronJob
# ---------------------------------------------------------------------------
# install.sh does a quick informational pod check but does not block on stabilization.
# The patching CronJob handles OOM remediation, pod restarts, and right-sizing.
connected_early=$(grep -c 'CONNECTED' "$ROOT/install.sh" || true)
assert_gt "$connected_early" "0" "install.sh registers CONNECTED after helm install"

patching_delegation=$(grep -c 'patching job will' "$ROOT/install.sh" || true)
assert_gt "$patching_delegation" "0" "install.sh informs user that patching job handles pod health"

# ---------------------------------------------------------------------------
# Test 15: Secret read is guarded with || true to prevent set -e exit
# ---------------------------------------------------------------------------
secret_guard=$(grep 'kubectl get secret onelens-agent-secrets' "$ROOT/install.sh" | grep -c '|| true' || true)
assert_gt "$secret_guard" "0" "kubectl get secret is guarded with || true"

# ---------------------------------------------------------------------------
# Test 16: base64 decode is guarded with || true
# ---------------------------------------------------------------------------
b64_guard_reg=$(grep 'base64' "$ROOT/install.sh" | grep 'REGISTRATION_ID' | grep -c '|| true' || true)
b64_guard_tok=$(grep 'base64' "$ROOT/install.sh" | grep 'CLUSTER_TOKEN' | grep -c '|| true' || true)
assert_gt "$b64_guard_reg" "0" "base64 decode of REGISTRATION_ID is guarded with || true"
assert_gt "$b64_guard_tok" "0" "base64 decode of CLUSTER_TOKEN is guarded with || true"

# ---------------------------------------------------------------------------
# Test 17: send_logs trap uses uppercase variable names matching main code
# ---------------------------------------------------------------------------
trap_reg=$(sed -n '/send_logs/,/^}/p' "$ROOT/install.sh" | grep -c 'REGISTRATION_ID' || true)
trap_tok=$(sed -n '/send_logs/,/^}/p' "$ROOT/install.sh" | grep -c 'CLUSTER_TOKEN' || true)
assert_gt "$trap_reg" "0" "send_logs uses REGISTRATION_ID (uppercase, matches main code)"
assert_gt "$trap_tok" "0" "send_logs uses CLUSTER_TOKEN (uppercase, matches main code)"

# ---------------------------------------------------------------------------
# Test 18: EXISTING_SECRET_JSON is cleaned up after extraction
# ---------------------------------------------------------------------------
unset_secret=$(grep -c 'unset EXISTING_SECRET_JSON' "$ROOT/install.sh" || true)
assert_gt "$unset_secret" "0" "EXISTING_SECRET_JSON is unset after credential extraction"

test_summary
exit $?
