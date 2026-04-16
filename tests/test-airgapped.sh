#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
set_test_file "test-airgapped.sh"
ROOT=$(repo_root)

# ---------------------------------------------------------------------------
# Test 1: install.sh self-detection reads pod image via kubectl
# ---------------------------------------------------------------------------
install_hostname=$(grep -c 'kubectl get pod "\$HOSTNAME"' "$ROOT/install.sh" || true)
assert_gt "$install_hostname" "0" "install.sh reads deployer pod image via HOSTNAME"

# ---------------------------------------------------------------------------
# Test 2: install.sh extracts REGISTRY_URL by stripping /onelens-deployer
# ---------------------------------------------------------------------------
install_sed=$(grep -c 'sed.*onelens-deployer' "$ROOT/install.sh" || true)
assert_gt "$install_sed" "0" "install.sh extracts REGISTRY_URL via sed on deployer image"

# ---------------------------------------------------------------------------
# Test 3: install.sh detects air-gapped by checking for public.ecr.aws
# ---------------------------------------------------------------------------
install_detect=$(grep -c 'public.ecr.aws' "$ROOT/install.sh" || true)
assert_gt "$install_detect" "0" "install.sh checks for public.ecr.aws in image path"

# ---------------------------------------------------------------------------
# Test 4: patching.sh reads REGISTRY_URL from helm values
# ---------------------------------------------------------------------------
patching_registry_read=$(grep -c 'REGISTRY_URL.*_get.*onelens-agent.*env.*REGISTRY_URL' "$ROOT/src/patching.sh" || true)
assert_gt "$patching_registry_read" "0" "patching.sh reads REGISTRY_URL from helm values via _get"

# ---------------------------------------------------------------------------
# Test 5: patching.sh initializes REGISTRY_URL to empty in fallback block
# ---------------------------------------------------------------------------
patching_registry_default=$(grep -c 'REGISTRY_URL=""' "$ROOT/src/patching.sh" || true)
assert_gt "$patching_registry_default" "0" "patching.sh defaults REGISTRY_URL to empty"

# ---------------------------------------------------------------------------
# Test 6: Both scripts read chart from ConfigMap when air-gapped
# ---------------------------------------------------------------------------
install_cm=$(grep -c 'onelens-agent-chart' "$ROOT/install.sh" || true)
patching_cm=$(grep -c 'onelens-agent-chart' "$ROOT/src/patching.sh" || true)
assert_gt "$install_cm" "0" "install.sh reads chart from ConfigMap when air-gapped"
assert_gt "$patching_cm" "0" "patching.sh reads chart from ConfigMap when air-gapped"

# ---------------------------------------------------------------------------
# Test 7: Both scripts persist REGISTRY_URL in helm values
# The --set onelens-agent.env.REGISTRY_URL flag stores the registry URL so
# patching.sh can read it back on subsequent runs.
# ---------------------------------------------------------------------------
install_persist=$(grep -c 'onelens-agent.env.REGISTRY_URL=\$REGISTRY_URL' "$ROOT/install.sh" || true)
patching_persist=$(grep -c 'onelens-agent.env.REGISTRY_URL=\$REGISTRY_URL' "$ROOT/src/patching.sh" || true)
assert_gt "$install_persist" "0" "install.sh persists REGISTRY_URL in helm values"
assert_gt "$patching_persist" "0" "patching.sh re-persists REGISTRY_URL in helm values"

# ---------------------------------------------------------------------------
# Test 8: Exactly 11 image override flags per script
# 7 image overrides (some need both registry + repository) + 1 REGISTRY_URL persistence = 11
# DCGM image is NOT in the helm air-gapped section — it's handled separately via kubectl apply.
# Components using {registry}/{repository}:{tag} (KSM, OpenCost, kube-rbac-proxy)
# need both registry and repository overridden to flatten the ECR path.
# Count all --set lines inside the air-gapped if-block (between REGISTRY_URL check and fi).
# ---------------------------------------------------------------------------
install_override_count=$(sed -n '/Air-gapped: override all image/,/^fi$/p' "$ROOT/install.sh" | grep -c '\-\-set ' || true)
patching_override_count=$(sed -n '/Air-gapped: override all image/,/^fi$/p' "$ROOT/src/patching.sh" | grep -c '\-\-set ' || true)
assert_eq "$install_override_count" "11" "install.sh has exactly 11 air-gapped --set flags"
assert_eq "$patching_override_count" "11" "patching.sh has exactly 11 air-gapped --set flags"

# ---------------------------------------------------------------------------
# Test 9: No hardcoded REGISTRY_URL in helm command (parameterized only)
# ---------------------------------------------------------------------------
install_hardcoded=$(grep -v '^#' "$ROOT/install.sh" | grep -v 'REGISTRY_URL' | grep -c 'dkr.ecr.*amazonaws.com' || true)
patching_hardcoded=$(grep -v '^#' "$ROOT/src/patching.sh" | grep -v 'REGISTRY_URL' | grep -c 'dkr.ecr.*amazonaws.com' || true)
assert_eq "$install_hardcoded" "0" "install.sh has no hardcoded ECR registry URLs"
assert_eq "$patching_hardcoded" "0" "patching.sh has no hardcoded ECR registry URLs"

# ---------------------------------------------------------------------------
# Test 10: Standard path is unchanged — helm repo add still present in else branch
# ---------------------------------------------------------------------------
# Both scripts must have the standard GitHub Pages URL in an else branch
install_standard=$(grep -A1 'else' "$ROOT/install.sh" | grep -c 'astuto-ai.github.io' || true)
patching_standard=$(grep -A1 'else' "$ROOT/src/patching.sh" | grep -c 'astuto-ai.github.io' || true)
assert_gt "$install_standard" "0" "install.sh preserves standard helm repo add in else branch"
assert_gt "$patching_standard" "0" "patching.sh preserves standard helm repo add in else branch"

# ---------------------------------------------------------------------------
# Test 11: install.sh does NOT use --reuse-values (even for air-gapped)
# ---------------------------------------------------------------------------
install_reuse=$(grep -v '^#' "$ROOT/install.sh" | grep -c '\-\-reuse-values' || true)
assert_eq "$install_reuse" "0" "install.sh does not use --reuse-values"

# ---------------------------------------------------------------------------
# Test 12: Migration script exists and has required flags
# ---------------------------------------------------------------------------
MIGRATE="$ROOT/scripts/airgapped/airgapped_migrate_images.sh"
assert_file_exists "$MIGRATE" "airgapped_migrate_images.sh exists"

migrate_version=$(grep -c '\-\-version' "$MIGRATE" || true)
migrate_registry=$(grep -c '\-\-registry' "$MIGRATE" || true)
assert_gt "$migrate_version" "0" "migration script accepts --version flag"
assert_gt "$migrate_registry" "0" "migration script accepts --registry flag"

# ---------------------------------------------------------------------------
# Test 13: Migration script has valid bash syntax
# ---------------------------------------------------------------------------
migrate_syntax=$(bash -n "$MIGRATE" 2>&1); migrate_rc=$?
assert_eq "$migrate_rc" "0" "airgapped_migrate_images.sh has valid bash syntax"

# ---------------------------------------------------------------------------
# Test 14: Migration script mirrors deployer chart with image rewrite
# ---------------------------------------------------------------------------
migrate_rewrite=$(grep -c 'sed.*public.ecr.aws.*onelens-deployer' "$MIGRATE" || true)
assert_gt "$migrate_rewrite" "0" "migration script rewrites deployer image in chart values"

# ---------------------------------------------------------------------------
# Test 15: Migration script pushes charts to OCI
# ---------------------------------------------------------------------------
migrate_push=$(grep -c 'helm push' "$MIGRATE" || true)
assert_ge "$migrate_push" "1" "migration script pushes deployer chart to OCI"

# ---------------------------------------------------------------------------
# Test 16: Accessibility check script exists and requires no params
# ---------------------------------------------------------------------------
CHECK="$ROOT/scripts/airgapped/airgapped_accessibility_check.sh"
assert_file_exists "$CHECK" "airgapped_accessibility_check.sh exists"

check_no_token=$(grep -c '\-\-registration-token' "$CHECK" || true)
assert_eq "$check_no_token" "0" "accessibility check does not require --registration-token (zero-param)"
check_api=$(grep -c 'api-in.onelens.cloud' "$CHECK" || true)
assert_gt "$check_api" "0" "accessibility check tests api-in.onelens.cloud"

# ---------------------------------------------------------------------------
# Test 17: Accessibility check has valid bash syntax
# ---------------------------------------------------------------------------
check_syntax=$(bash -n "$CHECK" 2>&1); check_rc=$?
assert_eq "$check_rc" "0" "airgapped_accessibility_check.sh has valid bash syntax"

# ---------------------------------------------------------------------------
# Test 18: Accessibility check tests both API and upload gateway
# ---------------------------------------------------------------------------
check_api=$(grep -c 'api-in.onelens.cloud' "$CHECK" || true)
check_upload=$(grep -c 'api-in-fileupload.onelens.cloud' "$CHECK" || true)
assert_gt "$check_api" "0" "accessibility check tests OneLens API endpoint"
assert_gt "$check_upload" "0" "accessibility check tests upload gateway endpoint"

# ---------------------------------------------------------------------------
# Test 19: Migration script fetches globalvalues.yaml from raw GitHub
# ---------------------------------------------------------------------------
migrate_dynamic=$(grep -c 'raw.githubusercontent.com' "$MIGRATE" || true)
assert_gt "$migrate_dynamic" "0" "migration script fetches globalvalues.yaml from raw GitHub"

# ---------------------------------------------------------------------------
# Test 20: patching.sh helm upgrade line uses $CHART_SOURCE (not hardcoded)
# ---------------------------------------------------------------------------
patching_hardcoded_chart=$(grep 'helm upgrade onelens-agent' "$ROOT/src/patching.sh" | grep -c 'onelens/onelens-agent' || true)
assert_eq "$patching_hardcoded_chart" "0" "patching.sh helm upgrade uses CHART_SOURCE, not hardcoded repo"

# ---------------------------------------------------------------------------
# Test 21: install.sh helm upgrade line uses $CHART_SOURCE (not hardcoded)
# ---------------------------------------------------------------------------
install_hardcoded_chart=$(grep 'helm upgrade --install onelens-agent' "$ROOT/install.sh" | grep -c 'onelens/onelens-agent' || true)
assert_eq "$install_hardcoded_chart" "0" "install.sh helm upgrade uses CHART_SOURCE, not hardcoded repo"

# ---------------------------------------------------------------------------
# Test 22: Migration script extracts ECR_DOMAIN separately from REGISTRY
# ---------------------------------------------------------------------------
migrate_ecr_domain=$(grep -c 'ECR_DOMAIN=' "$MIGRATE" || true)
assert_gt "$migrate_ecr_domain" "0" "migration script has ECR_DOMAIN variable for bare domain extraction"

# ---------------------------------------------------------------------------
# Test 23: Migration script supports ECR_PREFIX for repo namespacing
# ---------------------------------------------------------------------------
migrate_ecr_prefix=$(grep -c 'ECR_PREFIX' "$MIGRATE" || true)
assert_gt "$migrate_ecr_prefix" "0" "migration script has ECR_PREFIX variable for repo namespacing"

# ---------------------------------------------------------------------------
# Test 24: Docker login uses ECR_DOMAIN (bare domain), not REGISTRY (may have prefix)
# ---------------------------------------------------------------------------
migrate_login=$(grep 'docker login' "$MIGRATE" | grep -c 'ECR_DOMAIN' || true)
assert_gt "$migrate_login" "0" "migration script docker login uses ECR_DOMAIN, not REGISTRY"

# ---------------------------------------------------------------------------
# Test 25: ECR repo creation uses prefix when set
# ---------------------------------------------------------------------------
migrate_prefix_repo=$(grep 'ECR_PREFIX' "$MIGRATE" | grep -c 'ecr_repo\|ecr_charts' || true)
assert_gt "$migrate_prefix_repo" "0" "migration script prefixes ECR repo names"

# ---------------------------------------------------------------------------
# Test 26: Neither script uses imagePullSecrets (node IAM role handles image pulls)
# ---------------------------------------------------------------------------
install_ips=$(grep -v '^#' "$ROOT/install.sh" | grep -c 'imagePullSecrets' || true)
patching_ips=$(grep -v '^#' "$ROOT/src/patching.sh" | grep -c 'imagePullSecrets' || true)
assert_eq "$install_ips" "0" "install.sh does not set imagePullSecrets"
assert_eq "$patching_ips" "0" "patching.sh does not set imagePullSecrets"

# ---------------------------------------------------------------------------
# Test 27: Migration script creates ConfigMap for chart delivery
# ---------------------------------------------------------------------------
migrate_configmap=$(grep -c 'configmap onelens-agent-chart' "$MIGRATE" || true)
assert_gt "$migrate_configmap" "0" "migration script creates ConfigMap onelens-agent-chart"

# ---------------------------------------------------------------------------
# Test 28: install.sh MY_IMAGE read uses name-selector, not containers[0]
# v2.1.65 regression carried the same bug to install.sh — sidecar injectors
# (Dynatrace, Istio) may insert at containers[0], causing misdetection of
# air-gapped mode from the sidecar's image path. v2.1.66 reads by name.
# ---------------------------------------------------------------------------
install_image_name_selector=$(grep -c 'containers\[?(@.name=="onelensdeployerjob")\].image' "$ROOT/install.sh" || true)
assert_gt "$install_image_name_selector" "0" "install.sh reads deployer pod image via name-selector (not containers[0])"

install_image_bad_index=$(grep -c 'MY_IMAGE=.*kubectl get pod.*containers\[0\]\.image' "$ROOT/install.sh" || true)
assert_eq "$install_image_bad_index" "0" "install.sh MY_IMAGE read does not use containers[0] (sidecar safety)"

# Fallback: install.sh must filter containers[*].image for onelens-deployer substring
# when the primary name-selector returns empty (covers forks/customizations).
install_image_fallback=$(grep -c "grep 'onelens-deployer'" "$ROOT/install.sh" || true)
assert_gt "$install_image_fallback" "0" "install.sh has substring fallback for MY_IMAGE when name-selector fails"

test_summary
exit $?
