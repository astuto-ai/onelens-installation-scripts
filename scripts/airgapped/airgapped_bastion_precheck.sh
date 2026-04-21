#!/bin/bash
#
# airgapped_bastion_precheck.sh — Verify the bastion machine has all tools and
# network access required to run the air-gapped migration script.
#
# Usage:
#   curl -fsSL https://astuto-ai.github.io/onelens-installation-scripts/scripts/airgapped/airgapped_bastion_precheck.sh | bash
#
# No parameters required.
#
set -uo pipefail

PASS=0
FAIL=0
WARN=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
warn() { echo "  WARN: $1"; WARN=$((WARN + 1)); }

_TMPDIR=$(mktemp -d)
trap 'rm -rf "$_TMPDIR"' EXIT

echo "=== OneLens Air-Gapped Bastion Pre-Check ==="
echo ""

# -------------------------------------------------------------------
# 1. Required tools (fast — no network, runs sequentially)
# -------------------------------------------------------------------
echo "1. Required Tools"

get_version() {
    case "$1" in
        curl)    curl --version 2>/dev/null | head -1 | cut -d' ' -f2 || echo "unknown" ;;
        aws)     aws --version 2>&1 | cut -d' ' -f1 | cut -d/ -f2 || echo "unknown" ;;
        docker)  docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',' || echo "unknown" ;;
        helm)    helm version --short 2>/dev/null | tr -d 'v' || echo "unknown" ;;
        jq)      jq --version 2>/dev/null || echo "unknown" ;;
        kubectl)
            if command -v jq &>/dev/null; then
                kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion' 2>/dev/null || echo "unknown"
            else
                echo "unknown"
            fi
            ;;
    esac
}

major_version() {
    echo "$1" | tr -d 'v' | cut -d. -f1 | tr -dc '0-9'
}

check_tool() {
    local tool="$1" min_ver="$2" reason="$3"
    if ! command -v "$tool" &>/dev/null; then
        if [ "$min_ver" = "any" ]; then
            fail "$tool — not found in PATH"
        else
            fail "$tool — not found in PATH (required: $min_ver)"
        fi
        return
    fi
    local ver major
    ver=$(get_version "$tool")
    major=$(major_version "$ver")
    if [ "$min_ver" = "any" ]; then
        pass "$tool — found: $ver"
    elif [ "$major" -ge "$(major_version "$min_ver")" ] 2>/dev/null; then
        pass "$tool — found: $ver (required: $min_ver)"
    else
        fail "$tool — found: $ver, required: $min_ver ($reason)"
    fi
}

check_tool "curl"    "any"  ""
check_tool "aws"     "v2+"  "v1 does not support ecr get-login-password"
check_tool "docker"  "any"  ""
check_tool "helm"    "v3+"  "v2 has incompatible commands"
check_tool "jq"      "any"  ""
check_tool "kubectl" "any"  ""

if command -v docker &>/dev/null; then
    if docker buildx version &>/dev/null; then
        pass "docker buildx available"
    else
        fail "docker buildx not available (required for multi-arch image mirroring)"
    fi
else
    echo "  (skipped — docker not installed)"
fi

# -------------------------------------------------------------------
# 2-6: Network and service checks — all launched in parallel
# -------------------------------------------------------------------

# Helper: probe a URL, write PASS/FAIL to a temp file
probe_url() {
    local key="$1" url="$2"
    if curl -sL --max-time 5 "$url" -o /dev/null 2>/dev/null; then
        echo "PASS" > "$_TMPDIR/$key"
    else
        echo "FAIL" > "$_TMPDIR/$key"
    fi
}

# Helper: check docker daemon, write result
check_docker_bg() {
    if docker info &>/dev/null; then
        echo "PASS" > "$_TMPDIR/docker_daemon"
    else
        echo "FAIL" > "$_TMPDIR/docker_daemon"
    fi
}

# Helper: check AWS credentials, write result
check_aws_bg() {
    local sts
    sts=$(aws sts get-caller-identity --cli-read-timeout 5 --cli-connect-timeout 3 2>/dev/null) || sts=""
    if [ -n "$sts" ]; then
        local account
        account=$(echo "$sts" | jq -r '.Account' 2>/dev/null || echo "unknown")
        echo "PASS|$account" > "$_TMPDIR/aws_creds"
    else
        echo "FAIL" > "$_TMPDIR/aws_creds"
    fi
}

# Helper: check kubectl cluster access, write result
check_kubectl_bg() {
    if kubectl cluster-info --request-timeout=5s &>/dev/null; then
        local ctx
        ctx=$(kubectl config current-context 2>/dev/null || echo "unknown")
        echo "PASS|$ctx" > "$_TMPDIR/kubectl_access"
    else
        echo "FAIL" > "$_TMPDIR/kubectl_access"
    fi
}

# Launch all network/service checks in parallel
_BG_PIDS=""

probe_url "reg_ecr"      "https://public.ecr.aws/"    & _BG_PIDS="$_BG_PIDS $!"
probe_url "reg_quay"     "https://quay.io/"            & _BG_PIDS="$_BG_PIDS $!"
probe_url "reg_ghcr"     "https://ghcr.io/"            & _BG_PIDS="$_BG_PIDS $!"
probe_url "reg_k8s"      "https://registry.k8s.io/"    & _BG_PIDS="$_BG_PIDS $!"
probe_url "reg_nvcr"     "https://nvcr.io/"            & _BG_PIDS="$_BG_PIDS $!"
probe_url "gh_pages"     "https://astuto-ai.github.io/onelens-installation-scripts/" & _BG_PIDS="$_BG_PIDS $!"

if command -v docker &>/dev/null; then
    check_docker_bg & _BG_PIDS="$_BG_PIDS $!"
fi

if command -v aws &>/dev/null; then
    check_aws_bg & _BG_PIDS="$_BG_PIDS $!"
fi

if command -v kubectl &>/dev/null; then
    check_kubectl_bg & _BG_PIDS="$_BG_PIDS $!"
fi

# Wait with progress indicator
_TOTAL_BG=$(echo "$_BG_PIDS" | wc -w | tr -d ' ')
_CHECKS="registries, GitHub Pages, Docker, AWS credentials, cluster access"
echo ""
printf "  Checking %s ..." "$_CHECKS"
while true; do
    _done=0
    for _pid in $_BG_PIDS; do
        kill -0 "$_pid" 2>/dev/null || _done=$((_done + 1))
    done
    if [ "$_done" -ge "$_TOTAL_BG" ]; then
        break
    fi
    printf "."
    sleep 0.3
done
printf " done (%s/%s)\n" "$_done" "$_TOTAL_BG"

# -------------------------------------------------------------------
# Collect results: registries
# -------------------------------------------------------------------
echo ""
echo "2. Network Access (container registries)"

collect_registry() {
    local key="$1" domain="$2" purpose="$3"
    local result
    result=$(cat "$_TMPDIR/$key" 2>/dev/null || echo "FAIL")
    if [ "$result" = "PASS" ]; then
        pass "$domain — $purpose"
    else
        fail "$domain — $purpose"
    fi
}

collect_registry "reg_ecr"  "public.ecr.aws"    "OneLens agent and deployer images"
collect_registry "reg_quay" "quay.io"            "Prometheus, pushgateway, kube-rbac-proxy images"
collect_registry "reg_ghcr" "ghcr.io"            "OpenCost image"
collect_registry "reg_k8s"  "registry.k8s.io"    "Kube-State-Metrics image"
collect_registry "reg_nvcr" "nvcr.io"            "DCGM Exporter image (GPU clusters)"

# -------------------------------------------------------------------
# Collect results: GitHub Pages
# -------------------------------------------------------------------
echo ""
echo "3. Network Access (GitHub Pages)"
gh_result=$(cat "$_TMPDIR/gh_pages" 2>/dev/null || echo "FAIL")
if [ "$gh_result" = "PASS" ]; then
    pass "astuto-ai.github.io — Helm charts, migration scripts, versioned config"
else
    fail "astuto-ai.github.io — cannot reach GitHub Pages"
fi

# -------------------------------------------------------------------
# Collect results: Docker daemon
# -------------------------------------------------------------------
echo ""
echo "4. Docker Daemon"
if command -v docker &>/dev/null; then
    docker_result=$(cat "$_TMPDIR/docker_daemon" 2>/dev/null || echo "FAIL")
    if [ "$docker_result" = "PASS" ]; then
        pass "Docker daemon running"
    else
        fail "Docker installed but daemon not running (start with: sudo systemctl start docker)"
    fi
else
    echo "  (skipped — docker not installed)"
fi

# -------------------------------------------------------------------
# Collect results: AWS credentials
# -------------------------------------------------------------------
echo ""
echo "5. AWS Credentials"
if command -v aws &>/dev/null; then
    aws_result=$(cat "$_TMPDIR/aws_creds" 2>/dev/null || echo "FAIL")
    if [ "${aws_result%%|*}" = "PASS" ]; then
        _account="${aws_result#PASS|}"
        pass "AWS credentials configured (account: $_account)"
    else
        fail "AWS CLI found but no valid credentials (run: aws configure, or aws sso login for SSO)"
    fi
else
    echo "  (skipped — aws not installed)"
fi

# -------------------------------------------------------------------
# Collect results: kubectl cluster access
# -------------------------------------------------------------------
echo ""
echo "6. Kubectl Cluster Access"
if command -v kubectl &>/dev/null; then
    kube_result=$(cat "$_TMPDIR/kubectl_access" 2>/dev/null || echo "FAIL")
    if [ "${kube_result%%|*}" = "PASS" ]; then
        _ctx="${kube_result#PASS|}"
        pass "kubectl connected to cluster (context: $_ctx)"
    else
        warn "kubectl found but no cluster access — needed to create ConfigMap during migration"
    fi
else
    echo "  (skipped — kubectl not installed)"
fi

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------
echo ""
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "  Warnings: $WARN"

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "Fix the FAIL items above before running airgapped_migrate_images.sh."
    exit 1
elif [ "$WARN" -gt 0 ]; then
    echo ""
    echo "All critical checks passed. Review WARN items — they may be needed depending on your setup."
    exit 0
else
    echo ""
    echo "All checks passed. Bastion is ready to run the migration script."
    exit 0
fi
