#!/bin/bash
#
# airgapped_migrate_images.sh — Mirror OneLens images and charts to a private ECR registry.
#
# Usage:
#   bash airgapped_migrate_images.sh --version 2.1.58 --registry 123456789.dkr.ecr.ap-south-2.amazonaws.com
#
# Prerequisites: aws cli v2, docker (with buildx), helm v3, jq
#
set -euo pipefail

# --- Argument parsing ---
VERSION=""
REGISTRY=""

while [ $# -gt 0 ]; do
    case "$1" in
        --version)  VERSION="$2";   shift 2 ;;
        --registry) REGISTRY="$2";  shift 2 ;;
        -h|--help)
            echo "Usage: bash $0 --version <version> --registry <ecr-registry-url>"
            echo ""
            echo "Mirrors all OneLens container images and Helm charts to your private ECR registry."
            echo ""
            echo "Flags:"
            echo "  --version   OneLens version to mirror (e.g. 2.1.58)"
            echo "  --registry  Your private ECR registry URL (e.g. 123456789.dkr.ecr.ap-south-2.amazonaws.com)"
            exit 0
            ;;
        *) echo "Unknown flag: $1"; exit 1 ;;
    esac
done

if [ -z "$VERSION" ] || [ -z "$REGISTRY" ]; then
    echo "ERROR: --version and --registry are required."
    echo "Usage: bash $0 --version <version> --registry <ecr-registry-url>"
    exit 1
fi

# Strip trailing slash from registry URL
REGISTRY=$(echo "$REGISTRY" | sed 's|/$||')

# --- Prerequisite checks ---
for tool in aws docker helm jq; do
    if ! command -v "$tool" &>/dev/null; then
        echo "ERROR: $tool is required but not found in PATH."
        exit 1
    fi
done

# --- Extract ECR account and region from registry URL ---
# Format: <account-id>.dkr.ecr.<region>.amazonaws.com
ECR_ACCOUNT=$(echo "$REGISTRY" | cut -d'.' -f1)
ECR_REGION=$(echo "$REGISTRY" | sed 's/.*\.ecr\.\(.*\)\.amazonaws\.com/\1/')

if [ -z "$ECR_ACCOUNT" ] || [ -z "$ECR_REGION" ]; then
    echo "ERROR: Could not parse account/region from registry URL: $REGISTRY"
    echo "Expected format: <account-id>.dkr.ecr.<region>.amazonaws.com"
    exit 1
fi

echo "=== OneLens Air-Gapped Migration ==="
echo "Version:  $VERSION"
echo "Registry: $REGISTRY"
echo "Account:  $ECR_ACCOUNT"
echo "Region:   $ECR_REGION"
echo ""

# --- Authenticate to ECR ---
echo "Authenticating to ECR..."
aws ecr get-login-password --region "$ECR_REGION" | docker login --username AWS --password-stdin "$REGISTRY"
echo ""

# --- Add OneLens Helm repo ---
echo "Adding OneLens Helm repository..."
helm repo add onelens https://astuto-ai.github.io/onelens-installation-scripts/ 2>/dev/null || true
helm repo update >/dev/null 2>&1

# --- Fetch globalvalues.yaml for the target version ---
echo "Fetching image list for version $VERSION..."
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

helm show values onelens/onelens-agent --version "$VERSION" > "$TMPDIR/values.yaml" 2>/dev/null

if [ ! -s "$TMPDIR/values.yaml" ]; then
    echo "ERROR: Could not fetch chart values for version $VERSION."
    echo "Ensure the version exists: helm search repo onelens/onelens-agent --versions"
    exit 1
fi

# --- Parse images from values.yaml ---
# Each image is: source_image -> target_repo:tag
# We build an array of "SOURCE_IMAGE TARGET_REPO" pairs.

parse_image() {
    local repo="$1" tag="$2" target_name="$3"
    if [ -z "$tag" ]; then
        echo "WARNING: Empty tag for $repo — skipping (chart uses appVersion default)." >&2
        return
    fi
    echo "${repo}:${tag} ${target_name}:${tag}"
}

IMAGES=""

# onelens-agent
_repo=$(grep -A2 '^onelens-agent:' "$TMPDIR/values.yaml" | grep 'repository:' | head -1 | awk '{print $2}')
_tag=$(grep -A3 '^onelens-agent:' "$TMPDIR/values.yaml" | grep 'tag:' | head -1 | awk '{print $2}')
if [ -n "$_repo" ] && [ -n "$_tag" ]; then
    IMAGES="$IMAGES
${_repo}:${_tag} onelens-agent:${_tag}"
fi

# onelens-deployer (same ECR, tag = v$VERSION)
IMAGES="$IMAGES
public.ecr.aws/w7k6q5m9/onelens-deployer:v${VERSION} onelens-deployer:v${VERSION}"

# prometheus
_repo=$(awk '/^  server:/,/^  [a-zA-Z]/' "$TMPDIR/values.yaml" | grep 'repository:' | head -1 | awk '{print $2}')
_tag=$(awk '/^  server:/,/^  [a-zA-Z]/' "$TMPDIR/values.yaml" | grep 'tag:' | head -1 | awk '{print $2}' | tr -d '"')
if [ -n "$_repo" ] && [ -n "$_tag" ]; then
    IMAGES="$IMAGES
${_repo}:${_tag} prometheus:${_tag}"
fi

# prometheus-config-reloader
_repo=$(awk '/configmapReload:/,/^[^ ]/' "$TMPDIR/values.yaml" | grep 'repository:' | head -1 | awk '{print $2}')
_tag=$(awk '/configmapReload:/,/^[^ ]/' "$TMPDIR/values.yaml" | grep 'tag:' | head -1 | awk '{print $2}')
if [ -n "$_repo" ] && [ -n "$_tag" ]; then
    IMAGES="$IMAGES
${_repo}:${_tag} prometheus-config-reloader:${_tag}"
fi

# opencost
_oc_registry=$(awk '/opencost:/,/exporter:/' "$TMPDIR/values.yaml" | grep 'registry:' | head -1 | awk '{print $2}')
_oc_repo=$(awk '/opencost:/,/exporter:/' "$TMPDIR/values.yaml" | grep 'repository:' | head -1 | awk '{print $2}')
_oc_tag=$(awk '/opencost:/,/exporter:/' "$TMPDIR/values.yaml" | grep 'tag:' | head -1 | awk '{print $2}' | tr -d '"')
if [ -n "$_oc_repo" ] && [ -n "$_oc_tag" ]; then
    _oc_source="${_oc_repo}:${_oc_tag}"
    if [ -n "$_oc_registry" ]; then
        _oc_source="${_oc_registry}/${_oc_repo}:${_oc_tag}"
    fi
    # Target name is last part of the repo path (e.g. opencost/opencost -> opencost)
    _oc_target=$(echo "$_oc_repo" | awk -F/ '{print $NF}')
    IMAGES="$IMAGES
${_oc_source} ${_oc_target}:${_oc_tag}"
fi

# kube-state-metrics
_ksm_registry=$(awk '/kube-state-metrics:/,/^[^ ]/' "$TMPDIR/values.yaml" | grep 'registry:' | head -1 | awk '{print $2}')
_ksm_repo=$(awk '/kube-state-metrics:/,/^[^ ]/' "$TMPDIR/values.yaml" | grep 'repository:' | head -1 | awk '{print $2}')
_ksm_tag=$(awk '/kube-state-metrics:/,/^[^ ]/' "$TMPDIR/values.yaml" | grep 'tag:' | head -1 | awk '{print $2}' | tr -d '"')
if [ -n "$_ksm_repo" ]; then
    # KSM tag may be empty — get from chart appVersion
    if [ -z "$_ksm_tag" ]; then
        _ksm_tag=$(helm show chart onelens/onelens-agent --version "$VERSION" 2>/dev/null \
            | awk '/dependencies:/,/^[^ ]/' | awk '/name:.*kube-state-metrics/,/version:/' \
            | grep 'version:' | awk '{print "v"$2}')
        if [ -z "$_ksm_tag" ]; then
            echo "WARNING: Could not determine kube-state-metrics tag. Trying chart appVersion..."
            _ksm_tag=$(helm show chart "onelens/onelens-agent" --version "$VERSION" 2>/dev/null | grep appVersion | awk '{print $2}')
        fi
    fi
    if [ -n "$_ksm_tag" ]; then
        _ksm_name=$(echo "$_ksm_repo" | awk -F/ '{print $NF}')
        _ksm_source="${_ksm_repo}:${_ksm_tag}"
        if [ -n "$_ksm_registry" ]; then
            _ksm_source="${_ksm_registry}/${_ksm_repo}:${_ksm_tag}"
        fi
        IMAGES="$IMAGES
${_ksm_source} ${_ksm_name}:${_ksm_tag}"
    else
        echo "WARNING: Skipping kube-state-metrics — could not determine tag."
    fi
fi

# kube-rbac-proxy
_rbac_registry=$(awk '/kube-rbac-proxy:/,/^[^ ]/' "$TMPDIR/values.yaml" | grep 'registry:' | head -1 | awk '{print $2}')
_rbac_repo=$(awk '/kube-rbac-proxy:/,/^[^ ]/' "$TMPDIR/values.yaml" | grep 'repository:' | head -1 | awk '{print $2}')
_rbac_tag=$(awk '/kube-rbac-proxy:/,/^[^ ]/' "$TMPDIR/values.yaml" | grep 'tag:' | head -1 | awk '{print $2}')
if [ -n "$_rbac_repo" ] && [ -n "$_rbac_tag" ]; then
    _rbac_source="${_rbac_repo}:${_rbac_tag}"
    if [ -n "$_rbac_registry" ]; then
        _rbac_source="${_rbac_registry}/${_rbac_repo}:${_rbac_tag}"
    fi
    _rbac_name=$(echo "$_rbac_repo" | awk -F/ '{print $NF}')
    IMAGES="$IMAGES
${_rbac_source} ${_rbac_name}:${_rbac_tag}"
fi

# pushgateway
_pg_repo=$(awk '/prometheus-pushgateway:/,/^[^ ]/' "$TMPDIR/values.yaml" | grep 'repository:' | head -1 | awk '{print $2}')
_pg_tag=$(awk '/prometheus-pushgateway:/,/^[^ ]/' "$TMPDIR/values.yaml" | grep 'tag:' | head -1 | awk '{print $2}' | tr -d '"')
if [ -n "$_pg_repo" ]; then
    # Pushgateway tag may be empty — use hardcoded fallback from chart
    if [ -z "$_pg_tag" ]; then
        _pg_tag=$(helm show chart "onelens/onelens-agent" --version "$VERSION" 2>/dev/null \
            | awk '/dependencies:/,/^[^ ]/' | awk '/name:.*pushgateway/,/version:/' \
            | grep 'version:' | awk '{print "v"$2}')
    fi
    if [ -n "$_pg_tag" ]; then
        _pg_name=$(echo "$_pg_repo" | awk -F/ '{print $NF}')
        IMAGES="$IMAGES
${_pg_repo}:${_pg_tag} ${_pg_name}:${_pg_tag}"
    else
        echo "WARNING: Skipping pushgateway — could not determine tag."
    fi
fi

# --- Mirror images ---
echo ""
echo "=== Mirroring images ==="

# Remove leading blank line
IMAGES=$(echo "$IMAGES" | sed '/^$/d')

_FAIL_COUNT=0

echo "$IMAGES" | while IFS=' ' read -r source target; do
    [ -z "$source" ] && continue

    target_repo=$(echo "$target" | cut -d: -f1)
    target_tag=$(echo "$target" | cut -d: -f2)

    echo ""
    echo "--- $source -> $REGISTRY/$target ---"

    # Create ECR repository if it doesn't exist
    aws ecr describe-repositories --repository-names "$target_repo" --region "$ECR_REGION" >/dev/null 2>&1 || \
        aws ecr create-repository --repository-name "$target_repo" --region "$ECR_REGION" \
            --image-scanning-configuration scanOnPush=false >/dev/null 2>&1

    # Mirror multi-arch using docker buildx imagetools (no local pull needed)
    if docker buildx imagetools create --tag "$REGISTRY/${target}" "$source" 2>/dev/null; then
        echo "OK: $target"
    else
        # Fallback: pull + tag + push (single arch)
        echo "Multi-arch mirror failed. Falling back to single-arch pull+push..."
        if docker pull "$source" && \
           docker tag "$source" "$REGISTRY/${target}" && \
           docker push "$REGISTRY/${target}"; then
            echo "OK (single-arch): $target"
        else
            echo "FAILED: $target"
            _FAIL_COUNT=$((_FAIL_COUNT + 1))
        fi
    fi
done

# --- Mirror Helm charts ---
echo ""
echo "=== Mirroring Helm charts ==="

# 1. onelens-agent chart — push as-is
echo ""
echo "--- onelens-agent chart (version $VERSION) ---"
helm pull onelens/onelens-agent --version "$VERSION" -d "$TMPDIR"

# Create charts ECR repository
aws ecr describe-repositories --repository-names "charts/onelens-agent" --region "$ECR_REGION" >/dev/null 2>&1 || \
    aws ecr create-repository --repository-name "charts/onelens-agent" --region "$ECR_REGION" \
        --image-scanning-configuration scanOnPush=false >/dev/null 2>&1

helm push "$TMPDIR/onelens-agent-${VERSION}.tgz" "oci://$REGISTRY/charts/"
echo "OK: charts/onelens-agent:$VERSION"

# 2. onelensdeployer chart — rewrite deployer image, then push
echo ""
echo "--- onelensdeployer chart (version $VERSION) ---"
helm pull onelens/onelensdeployer --version "$VERSION" -d "$TMPDIR" --untar --untardir "$TMPDIR"

# Rewrite deployer image to point to private registry
# Cross-platform sed -i: BSD (macOS) requires -i '', GNU (Linux) requires -i'' or -i
# Use a temp file to avoid the incompatibility.
_VALUES_FILE="$TMPDIR/onelensdeployer/values.yaml"
sed "s|public.ecr.aws/w7k6q5m9/onelens-deployer|${REGISTRY}/onelens-deployer|g" "$_VALUES_FILE" > "${_VALUES_FILE}.tmp"
mv "${_VALUES_FILE}.tmp" "$_VALUES_FILE"

echo "Rewrote deployer image: public.ecr.aws/w7k6q5m9/onelens-deployer -> $REGISTRY/onelens-deployer"

helm package "$TMPDIR/onelensdeployer" -d "$TMPDIR" >/dev/null

# Create charts ECR repository
aws ecr describe-repositories --repository-names "charts/onelensdeployer" --region "$ECR_REGION" >/dev/null 2>&1 || \
    aws ecr create-repository --repository-name "charts/onelensdeployer" --region "$ECR_REGION" \
        --image-scanning-configuration scanOnPush=false >/dev/null 2>&1

helm push "$TMPDIR/onelensdeployer-${VERSION}.tgz" "oci://$REGISTRY/charts/"
echo "OK: charts/onelensdeployer:$VERSION"

# --- Summary ---
echo ""
echo "=== Migration complete ==="
echo "Version: $VERSION"
echo "Registry: $REGISTRY"
echo ""
echo "Images mirrored:"
echo "$IMAGES" | while IFS=' ' read -r source target; do
    [ -z "$source" ] && continue
    echo "  $REGISTRY/$target"
done
echo ""
echo "Charts pushed:"
echo "  oci://$REGISTRY/charts/onelens-agent:$VERSION"
echo "  oci://$REGISTRY/charts/onelensdeployer:$VERSION"
echo ""
echo "Next step: Install OneLens on each cluster:"
echo "  helm upgrade --install onelensdeployer oci://$REGISTRY/charts/onelensdeployer \\"
echo "    -n onelens-agent --create-namespace \\"
echo "    --set job.env.CLUSTER_NAME=<cluster-name> \\"
echo "    --set job.env.REGION=<region> \\"
echo "    --set-string job.env.ACCOUNT=<account-id> \\"
echo "    --set job.env.REGISTRATION_TOKEN=<token>"
