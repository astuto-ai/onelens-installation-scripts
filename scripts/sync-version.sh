#!/usr/bin/env bash
# ==================================================================================
# sync-version.sh — Propagate version from VERSION file to all locations
#
# Reads the version from the VERSION file at the repo root and updates:
#   - charts/onelens-agent/Chart.yaml (version, appVersion, dependency version)
#   - charts/onelensdeployer/Chart.yaml (version, appVersion)
#   - globalvalues.yaml (onelens-agent.image.tag)
#   - install.sh (RELEASE_VERSION defaults)
#
# Usage: ./scripts/sync-version.sh
# ==================================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="${REPO_ROOT}/VERSION"

if [[ ! -f "$VERSION_FILE" ]]; then
    echo "ERROR: VERSION file not found at $VERSION_FILE" >&2
    exit 1
fi

VERSION=$(tr -d '[:space:]' < "$VERSION_FILE")

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: Invalid version '$VERSION' in VERSION file. Expected X.Y.Z" >&2
    exit 1
fi

echo "Syncing version $VERSION across all files..."

# Platform-safe sed in-place
if [[ "$(uname)" == "Darwin" ]]; then
    sedi() { sed -i '' "$@"; }
else
    sedi() { sed -i "$@"; }
fi

# --- charts/onelens-agent/Chart.yaml ---
AGENT_CHART="${REPO_ROOT}/charts/onelens-agent/Chart.yaml"
if [[ -f "$AGENT_CHART" ]]; then
    # version: X.Y.Z (top-level, not indented)
    sedi "s/^version: .*/version: ${VERSION}/" "$AGENT_CHART"
    sedi "s/^appVersion: .*/appVersion: ${VERSION}/" "$AGENT_CHART"
    # dependency version (indented, under dependencies)
    sedi "s/^    version: [0-9][0-9.]*/    version: ${VERSION}/" "$AGENT_CHART"
    echo "  Updated $AGENT_CHART"
fi

# --- charts/onelensdeployer/Chart.yaml ---
DEPLOYER_CHART="${REPO_ROOT}/charts/onelensdeployer/Chart.yaml"
if [[ -f "$DEPLOYER_CHART" ]]; then
    sedi "s/^version: .*/version: ${VERSION}/" "$DEPLOYER_CHART"
    sedi "s/^appVersion: .*/appVersion: ${VERSION}/" "$DEPLOYER_CHART"
    echo "  Updated $DEPLOYER_CHART"
fi

# --- globalvalues.yaml (only the onelens-agent image tag, not third-party images) ---
GLOBALVALUES="${REPO_ROOT}/globalvalues.yaml"
if [[ -f "$GLOBALVALUES" ]]; then
    # Match: line with onelens-agent repo, then update the next line's tag
    sedi '/public\.ecr\.aws\/w7k6q5m9\/onelens-agent/{n;s/tag: v[0-9][0-9.]*/tag: v'"${VERSION}"'/;}' "$GLOBALVALUES"
    echo "  Updated $GLOBALVALUES"
fi

# --- install.sh (RELEASE_VERSION defaults) ---
INSTALL_SH="${REPO_ROOT}/install.sh"
if [[ -f "$INSTALL_SH" ]]; then
    sedi "s/\${RELEASE_VERSION:=[0-9][0-9.]*}/\${RELEASE_VERSION:=${VERSION}}/g" "$INSTALL_SH"
    echo "  Updated $INSTALL_SH"
fi

echo "Version sync complete: $VERSION"
