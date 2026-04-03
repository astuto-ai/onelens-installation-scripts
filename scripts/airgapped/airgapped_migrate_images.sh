#!/bin/bash
#
# airgapped_migrate_images.sh — Mirror OneLens images and charts to a private ECR registry.
#
# Usage:
#   bash airgapped_migrate_images.sh --registry 123456789.dkr.ecr.ap-south-2.amazonaws.com
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
            echo "Usage: bash $0 --registry <ecr-registry-url> [--version <version>]"
            echo ""
            echo "Mirrors all OneLens container images and Helm charts to your private ECR registry."
            echo ""
            echo "Flags:"
            echo "  --registry  (required) Your private ECR registry URL, optionally with a path prefix"
            echo "              e.g. 123456789.dkr.ecr.ap-south-1.amazonaws.com/onelensagent"
            echo "  --version   (optional) OneLens version to mirror. If omitted, uses the latest released version."
            exit 0
            ;;
        *) echo "Unknown flag: $1"; exit 1 ;;
    esac
done

if [ -z "$REGISTRY" ]; then
    echo "ERROR: --registry is required."
    echo "Usage: bash $0 --registry <ecr-registry-url> [--version <version>]"
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

# --- Add OneLens Helm repo (needed for version auto-detect and chart pull) ---
echo "Adding OneLens Helm repository..."
helm repo add onelens https://astuto-ai.github.io/onelens-installation-scripts/ 2>/dev/null || true
helm repo update >/dev/null 2>&1

# --- Auto-detect version if not specified ---
if [ -z "$VERSION" ]; then
    VERSION=$(helm search repo onelens/onelens-agent -o json | jq -r '.[0].version')
    if [ -z "$VERSION" ] || [ "$VERSION" = "null" ]; then
        echo "ERROR: Could not auto-detect latest version from Helm repo."
        exit 1
    fi
    echo "No --version specified. Using latest: $VERSION"
fi

# --- Extract ECR domain, account, and region from registry URL ---
# Supports bare domain and prefixed paths:
#   471112871310.dkr.ecr.ap-south-1.amazonaws.com
#   471112871310.dkr.ecr.ap-south-1.amazonaws.com/onelensagent
# ECR_DOMAIN = bare domain (for docker login and ECR API calls)
# ECR_PREFIX = path after domain (for namespacing ECR repos), empty if bare domain
ECR_DOMAIN=$(echo "$REGISTRY" | sed 's|/.*||')
ECR_PREFIX=""
if echo "$REGISTRY" | grep -q '/'; then
    ECR_PREFIX=$(echo "$REGISTRY" | sed "s|^${ECR_DOMAIN}/||")
fi
ECR_ACCOUNT=$(echo "$ECR_DOMAIN" | cut -d'.' -f1)
ECR_REGION=$(echo "$ECR_DOMAIN" | sed 's/.*\.ecr\.\(.*\)\.amazonaws\.com/\1/')

if [ -z "$ECR_ACCOUNT" ] || [ -z "$ECR_REGION" ]; then
    echo "ERROR: Could not parse account/region from registry URL: $REGISTRY"
    echo "Expected format: <account-id>.dkr.ecr.<region>.amazonaws.com[/<prefix>]"
    exit 1
fi

echo "=== OneLens Air-Gapped Migration ==="
echo "Version:  $VERSION"
echo "Registry: $REGISTRY"
echo "Domain:   $ECR_DOMAIN"
echo "Account:  $ECR_ACCOUNT"
echo "Region:   $ECR_REGION"
if [ -n "$ECR_PREFIX" ]; then
    echo "Prefix:   $ECR_PREFIX"
fi
echo ""

# --- Authenticate to ECR ---
echo "Authenticating to ECR..."
aws ecr get-login-password --region "$ECR_REGION" | docker login --username AWS --password-stdin "$ECR_DOMAIN"
echo ""

# --- Fetch globalvalues.yaml for the target version ---
echo "Fetching image list for version $VERSION..."
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Download globalvalues.yaml from the tagged release on GitHub.
# This is more reliable than helm show values — the chart's packaged values have different
# YAML structure (nested sub-chart keys) that makes grep-based parsing fragile.
_GV_URL="https://raw.githubusercontent.com/astuto-ai/onelens-installation-scripts/v${VERSION}/globalvalues.yaml"
curl -fsSL "$_GV_URL" -o "$TMPDIR/values.yaml"

if [ ! -s "$TMPDIR/values.yaml" ]; then
    echo "ERROR: Could not fetch globalvalues.yaml for version $VERSION."
    echo "URL: $_GV_URL"
    exit 1
fi

echo "Fetched globalvalues.yaml from v${VERSION} tag"

# Also fetch the chart to get image tags for components with empty tags (KSM, pushgateway).
helm pull onelens/onelens-agent --version "$VERSION" -d "$TMPDIR" --untar --untardir "$TMPDIR" 2>/dev/null || true

# --- Parse images from globalvalues.yaml ---
# Uses direct grep for known image repository strings. This is more reliable than
# awk range patterns because globalvalues.yaml has duplicate section names and
# complex nesting that breaks range-based extraction.

IMAGES=""
_V="$TMPDIR/values.yaml"

# Helper: extract tag from the line immediately following a repository match
_get_tag() {
    local file="$1" repo_pattern="$2"
    grep -A1 "repository: ${repo_pattern}" "$file" | grep 'tag:' | head -1 | awk '{print $2}' | tr -d '"'
}

# onelens-agent
_repo="public.ecr.aws/w7k6q5m9/onelens-agent"
_tag=$(_get_tag "$_V" "$_repo")
if [ -n "$_tag" ]; then
    IMAGES="${IMAGES}
${_repo}:${_tag} onelens-agent:${_tag}"
    echo "  onelens-agent: ${_repo}:${_tag}"
fi

# onelens-deployer (not in globalvalues — same ECR, tag = v$VERSION)
IMAGES="${IMAGES}
public.ecr.aws/w7k6q5m9/onelens-deployer:v${VERSION} onelens-deployer:v${VERSION}"
echo "  onelens-deployer: public.ecr.aws/w7k6q5m9/onelens-deployer:v${VERSION}"

# prometheus
_repo="quay.io/prometheus/prometheus"
_tag=$(_get_tag "$_V" "$_repo")
if [ -n "$_tag" ]; then
    IMAGES="${IMAGES}
${_repo}:${_tag} prometheus:${_tag}"
    echo "  prometheus: ${_repo}:${_tag}"
fi

# prometheus-config-reloader
_repo="quay.io/prometheus-operator/prometheus-config-reloader"
_tag=$(_get_tag "$_V" "$_repo")
if [ -n "$_tag" ]; then
    IMAGES="${IMAGES}
${_repo}:${_tag} prometheus-config-reloader:${_tag}"
    echo "  prometheus-config-reloader: ${_repo}:${_tag}"
fi

# opencost (has separate registry field)
_repo="opencost/opencost"
_tag=$(_get_tag "$_V" "$_repo")
if [ -n "$_tag" ]; then
    _source="ghcr.io/${_repo}:${_tag}"
    IMAGES="${IMAGES}
${_source} opencost:${_tag}"
    echo "  opencost: ${_source}"
fi

# kube-state-metrics (tag may be empty — get from sub-chart appVersion)
_repo="kube-state-metrics/kube-state-metrics"
_tag=$(_get_tag "$_V" "$_repo")
if [ -z "$_tag" ] && [ -f "$TMPDIR/onelens-agent/charts/prometheus/charts/kube-state-metrics/Chart.yaml" ]; then
    _tag="v$(grep '^appVersion:' "$TMPDIR/onelens-agent/charts/prometheus/charts/kube-state-metrics/Chart.yaml" | awk '{print $2}')"
fi
if [ -n "$_tag" ]; then
    _source="registry.k8s.io/${_repo}:${_tag}"
    IMAGES="${IMAGES}
${_source} kube-state-metrics:${_tag}"
    echo "  kube-state-metrics: ${_source}"
else
    echo "  WARNING: Skipping kube-state-metrics — could not determine tag."
fi

# kube-rbac-proxy
_repo="brancz/kube-rbac-proxy"
_tag=$(_get_tag "$_V" "$_repo")
if [ -n "$_tag" ]; then
    _source="quay.io/${_repo}:${_tag}"
    IMAGES="${IMAGES}
${_source} kube-rbac-proxy:${_tag}"
    echo "  kube-rbac-proxy: ${_source}"
fi

# pushgateway (tag may be empty — get from sub-chart appVersion)
_repo="quay.io/prometheus/pushgateway"
_tag=$(_get_tag "$_V" "$_repo")
if [ -z "$_tag" ] && [ -f "$TMPDIR/onelens-agent/charts/prometheus/charts/prometheus-pushgateway/Chart.yaml" ]; then
    _tag="$(grep '^appVersion:' "$TMPDIR/onelens-agent/charts/prometheus/charts/prometheus-pushgateway/Chart.yaml" | awk '{print $2}')"
fi
if [ -n "$_tag" ]; then
    IMAGES="${IMAGES}
${_repo}:${_tag} pushgateway:${_tag}"
    echo "  pushgateway: ${_repo}:${_tag}"
else
    echo "  WARNING: Skipping pushgateway — could not determine tag."
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

    # Create ECR repository if it doesn't exist (prefix repo name if set)
    _ecr_repo="${ECR_PREFIX:+${ECR_PREFIX}/}${target_repo}"
    aws ecr describe-repositories --repository-names "$_ecr_repo" --region "$ECR_REGION" >/dev/null 2>&1 || \
        aws ecr create-repository --repository-name "$_ecr_repo" --region "$ECR_REGION" \
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

# Create charts ECR repository (prefix if set)
_ecr_charts_agent="${ECR_PREFIX:+${ECR_PREFIX}/}charts/onelens-agent"
aws ecr describe-repositories --repository-names "$_ecr_charts_agent" --region "$ECR_REGION" >/dev/null 2>&1 || \
    aws ecr create-repository --repository-name "$_ecr_charts_agent" --region "$ECR_REGION" \
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

# Create charts ECR repository (prefix if set)
_ecr_charts_deployer="${ECR_PREFIX:+${ECR_PREFIX}/}charts/onelensdeployer"
aws ecr describe-repositories --repository-names "$_ecr_charts_deployer" --region "$ECR_REGION" >/dev/null 2>&1 || \
    aws ecr create-repository --repository-name "$_ecr_charts_deployer" --region "$ECR_REGION" \
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
