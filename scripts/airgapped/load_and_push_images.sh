#!/bin/bash
#
# load_and_push_images.sh — Load downloaded image tar files and push to a private registry.
#
# Usage:
#   bash load_and_push_images.sh --registry <your-registry-url>/<prefix>
#
# This script auto-detects image versions from tar filenames in the same directory.
# It handles multi-arch (amd64 + arm64) manifest creation automatically.
#
# Prerequisites: docker, aws cli v2, helm v3, kubectl
#
set -euo pipefail

REGISTRY=""

while [ $# -gt 0 ]; do
    case "$1" in
        --registry) REGISTRY="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: bash $0 --registry <ecr-registry-url>"
            echo ""
            echo "Loads image tar files from this directory and pushes them to your private ECR registry"
            echo "as multi-arch images (Image Index with amd64 + arm64)."
            exit 0
            ;;
        *) echo "Unknown flag: $1"; exit 1 ;;
    esac
done

if [ -z "$REGISTRY" ]; then
    echo "ERROR: --registry is required."
    echo "Usage: bash $0 --registry <ecr-registry-url>"
    exit 1
fi

REGISTRY=$(echo "$REGISTRY" | sed 's|/$||')
ECR_DOMAIN=$(echo "$REGISTRY" | sed 's|/.*||')
ECR_PREFIX=""
if echo "$REGISTRY" | grep -q '/'; then
    ECR_PREFIX=$(echo "$REGISTRY" | sed "s|^${ECR_DOMAIN}/||")
fi
ECR_REGION=$(echo "$ECR_DOMAIN" | sed 's/.*\.ecr\.\(.*\)\.amazonaws\.com/\1/')
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Auto-detect images from tar files ---
# Expected naming: <image-name>-<tag>-<arch>.tar
# e.g., onelens-deployer-v2.1.84-amd64.tar, prometheus-v3.1.0-arm64.tar
_IMAGES=()
for f in "$SCRIPT_DIR"/*-amd64.tar "$SCRIPT_DIR"/*-arm64.tar; do
    [ -f "$f" ] || continue
    _base=$(basename "$f")
    # Strip -amd64.tar or -arm64.tar to get <image-name>-<tag>
    _name_tag=$(echo "$_base" | sed 's/-amd64\.tar$//' | sed 's/-arm64\.tar$//')
    # Extract image name and tag: everything up to last dash-v or last dash-digit is the name
    # e.g., onelens-deployer-v2.1.84 -> name=onelens-deployer, tag=v2.1.84
    #        dcgm-exporter-3.3.9-3.6.1-ubuntu22.04 -> name=dcgm-exporter, tag=3.3.9-3.6.1-ubuntu22.04
    # We use the pattern: split on the first -v followed by digits, or use known image names
    _found=false
    for _img in "${_IMAGES[@]:-}"; do
        if [ "$_img" = "$_name_tag" ]; then _found=true; break; fi
    done
    if ! $_found; then
        _IMAGES+=("$_name_tag")
    fi
done

if [ ${#_IMAGES[@]} -eq 0 ]; then
    echo "ERROR: No image tar files found in $SCRIPT_DIR"
    echo "Expected files like: onelens-deployer-v2.1.84-amd64.tar"
    exit 1
fi

echo "=== OneLens Image Load & Push ==="
echo "Registry: $REGISTRY"
echo "Source:   $SCRIPT_DIR"
echo "Images detected: ${#_IMAGES[@]}"
echo ""

# Authenticate to ECR
echo "Authenticating to ECR..."
aws ecr get-login-password --region "$ECR_REGION" | docker login --username AWS --password-stdin "$ECR_DOMAIN"
echo ""

_PUSHED_IMAGES=()

for _name_tag in "${_IMAGES[@]}"; do
    # Extract image name and tag
    # Match known image names first, then fall back to splitting on last -v
    _image_name=""
    _image_tag=""

    # Known multi-hyphen image names
    for _known in onelens-deployer onelens-agent onelens-network-costs prometheus-config-reloader kube-state-metrics kube-rbac-proxy dcgm-exporter; do
        if [[ "$_name_tag" == "${_known}-"* ]]; then
            _image_name="$_known"
            _image_tag="${_name_tag#${_known}-}"
            break
        fi
    done

    # Fallback: single-word names like prometheus, opencost, pushgateway
    if [ -z "$_image_name" ]; then
        # Split on first hyphen followed by v and digit, or first hyphen followed by digit
        if [[ "$_name_tag" =~ ^([a-z]+)-(v?[0-9].*)$ ]]; then
            _image_name="${BASH_REMATCH[1]}"
            _image_tag="${BASH_REMATCH[2]}"
        else
            echo "WARNING: Could not parse image name/tag from: $_name_tag — skipping"
            continue
        fi
    fi

    echo "--- ${_image_name}:${_image_tag} ---"

    # Create ECR repo if needed
    _ecr_repo="${ECR_PREFIX:+${ECR_PREFIX}/}${_image_name}"
    aws ecr describe-repositories --repository-names "$_ecr_repo" --region "$ECR_REGION" >/dev/null 2>&1 || \
        aws ecr create-repository --repository-name "$_ecr_repo" --region "$ECR_REGION" \
            --image-scanning-configuration scanOnPush=false >/dev/null 2>&1

    _HAS_AMD64=false
    _HAS_ARM64=false

    if [ -f "$SCRIPT_DIR/${_name_tag}-amd64.tar" ]; then
        echo "  Loading amd64..."
        docker load -i "$SCRIPT_DIR/${_name_tag}-amd64.tar" > /dev/null
        docker tag "${_image_name}:${_image_tag}-amd64" "$REGISTRY/${_image_name}:${_image_tag}-amd64"
        echo "  Pushing amd64..."
        docker push "$REGISTRY/${_image_name}:${_image_tag}-amd64" > /dev/null
        _HAS_AMD64=true
    fi

    if [ -f "$SCRIPT_DIR/${_name_tag}-arm64.tar" ]; then
        echo "  Loading arm64..."
        docker load -i "$SCRIPT_DIR/${_name_tag}-arm64.tar" > /dev/null
        docker tag "${_image_name}:${_image_tag}-arm64" "$REGISTRY/${_image_name}:${_image_tag}-arm64"
        echo "  Pushing arm64..."
        docker push "$REGISTRY/${_image_name}:${_image_tag}-arm64" > /dev/null
        _HAS_ARM64=true
    fi

    if $_HAS_AMD64 && $_HAS_ARM64; then
        echo "  Creating multi-arch manifest..."
        docker manifest create "$REGISTRY/${_image_name}:${_image_tag}" \
            "$REGISTRY/${_image_name}:${_image_tag}-amd64" \
            "$REGISTRY/${_image_name}:${_image_tag}-arm64" 2>/dev/null || \
        docker manifest create --amend "$REGISTRY/${_image_name}:${_image_tag}" \
            "$REGISTRY/${_image_name}:${_image_tag}-amd64" \
            "$REGISTRY/${_image_name}:${_image_tag}-arm64"
        docker manifest push "$REGISTRY/${_image_name}:${_image_tag}"
        echo "  OK: ${_image_name}:${_image_tag} (multi-arch)"
    elif $_HAS_AMD64; then
        docker tag "$REGISTRY/${_image_name}:${_image_tag}-amd64" "$REGISTRY/${_image_name}:${_image_tag}"
        docker push "$REGISTRY/${_image_name}:${_image_tag}" > /dev/null
        echo "  OK: ${_image_name}:${_image_tag} (amd64 only)"
    elif $_HAS_ARM64; then
        docker tag "$REGISTRY/${_image_name}:${_image_tag}-arm64" "$REGISTRY/${_image_name}:${_image_tag}"
        docker push "$REGISTRY/${_image_name}:${_image_tag}" > /dev/null
        echo "  OK: ${_image_name}:${_image_tag} (arm64 only)"
    else
        echo "  SKIPPED: no tar files found for ${_image_name}:${_image_tag}"
    fi
    _PUSHED_IMAGES+=("$REGISTRY/${_image_name}:${_image_tag}")
    echo ""
done

# --- Helm charts ---
echo "=== Pushing Helm charts ==="

_DEPLOYER_TGZ=$(ls "$SCRIPT_DIR"/onelensdeployer-*.tgz 2>/dev/null | head -1)
if [ -z "$_DEPLOYER_TGZ" ]; then
    echo "WARNING: onelensdeployer chart tarball not found — skipping chart push"
else
    _VERSION=$(basename "$_DEPLOYER_TGZ" | sed 's/onelensdeployer-//' | sed 's/.tgz//')

    echo "Rewriting deployer chart for registry: $REGISTRY"
    _CHART_TMPDIR=$(mktemp -d)
    tar -xzf "$_DEPLOYER_TGZ" -C "$_CHART_TMPDIR"
    sed "s|public.ecr.aws/w7k6q5m9/onelens-deployer|${REGISTRY}/onelens-deployer|g" \
        "$_CHART_TMPDIR/onelensdeployer/values.yaml" > "$_CHART_TMPDIR/onelensdeployer/values.yaml.tmp"
    mv "$_CHART_TMPDIR/onelensdeployer/values.yaml.tmp" "$_CHART_TMPDIR/onelensdeployer/values.yaml"
    helm package "$_CHART_TMPDIR/onelensdeployer" -d "$_CHART_TMPDIR" > /dev/null

    _ecr_charts="${ECR_PREFIX:+${ECR_PREFIX}/}charts/onelensdeployer"
    aws ecr describe-repositories --repository-names "$_ecr_charts" --region "$ECR_REGION" >/dev/null 2>&1 || \
        aws ecr create-repository --repository-name "$_ecr_charts" --region "$ECR_REGION" \
            --image-scanning-configuration scanOnPush=false >/dev/null 2>&1

    helm push "$_CHART_TMPDIR/onelensdeployer-${_VERSION}.tgz" "oci://$REGISTRY/charts/"
    echo "OK: charts/onelensdeployer:$_VERSION"
    rm -rf "$_CHART_TMPDIR"
fi

# --- Kubernetes setup ---
echo ""
echo "=== Setting up Kubernetes resources ==="

_AGENT_TGZ=$(ls "$SCRIPT_DIR"/onelens-agent-*.tgz 2>/dev/null | head -1)
if [ -z "$_AGENT_TGZ" ]; then
    echo "WARNING: onelens-agent chart tarball not found — skipping ConfigMap update"
else
    echo "Ensuring namespace onelens-agent exists..."
    kubectl create namespace onelens-agent --dry-run=client -o yaml | kubectl apply -f -

    echo "Updating ConfigMap onelens-agent-chart..."
    kubectl create configmap onelens-agent-chart -n onelens-agent \
        --from-file=chart.tgz="$_AGENT_TGZ" \
        --dry-run=client -o yaml | kubectl apply -f -
    echo "OK: ConfigMap onelens-agent-chart"
fi

# --- Summary ---
echo ""
echo "=== Update complete ==="
echo "Registry: $REGISTRY"
echo ""
echo "Images pushed:"
for _img in "${_PUSHED_IMAGES[@]}"; do
    echo "  $_img"
done
if [ -n "${_VERSION:-}" ]; then
    echo ""
    echo "Charts pushed:"
    echo "  oci://$REGISTRY/charts/onelensdeployer:$_VERSION"
    echo ""
    echo "Kubernetes resources updated:"
    echo "  ConfigMap onelens-agent-chart (agent chart v$_VERSION)"
fi
echo ""
echo "The updater cronjob will automatically upgrade onelens-agent"
echo "on the next scheduled run. To force an immediate update:"
echo "  kubectl create job --from=cronjob/onelensupdater manual-update -n onelens-agent"
