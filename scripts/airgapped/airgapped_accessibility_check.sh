#!/bin/bash
#
# airgapped_accessibility_check.sh — Verify network connectivity for OneLens air-gapped deployment.
#
# Usage:
#   bash airgapped_accessibility_check.sh \
#     --registration-token <token> --cluster-name <name> --account <id> --region <region>
#
set -euo pipefail

REGISTRATION_TOKEN=""
CLUSTER_NAME=""
ACCOUNT=""
REGION=""

while [ $# -gt 0 ]; do
    case "$1" in
        --registration-token) REGISTRATION_TOKEN="$2"; shift 2 ;;
        --cluster-name)       CLUSTER_NAME="$2";       shift 2 ;;
        --account)            ACCOUNT="$2";             shift 2 ;;
        --region)             REGION="$2";              shift 2 ;;
        -h|--help)
            echo "Usage: bash $0 --registration-token <token> --cluster-name <name> --account <id> --region <region>"
            echo ""
            echo "Tests network connectivity required for OneLens air-gapped deployment."
            exit 0
            ;;
        *) echo "Unknown flag: $1"; exit 1 ;;
    esac
done

if [ -z "$REGISTRATION_TOKEN" ] || [ -z "$CLUSTER_NAME" ] || [ -z "$ACCOUNT" ] || [ -z "$REGION" ]; then
    echo "ERROR: All flags are required: --registration-token, --cluster-name, --account, --region"
    exit 1
fi

API_URL="https://api-in.onelens.cloud"
UPLOAD_URL="https://api-in-fileupload.onelens.cloud"
PASS=0
FAIL=0

check() {
    local name="$1" result="$2"
    if [ "$result" = "ok" ]; then
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name — $result"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== OneLens Air-Gapped Connectivity Check ==="
echo ""

# Test 1: API reachability
echo "1. OneLens API ($API_URL)"
_api_http=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    -X POST "$API_URL/v1/kubernetes/registration" \
    -H "Content-Type: application/json" \
    -d "{
        \"registration_token\": \"$REGISTRATION_TOKEN\",
        \"cluster_name\": \"connectivity-check-$(date +%s)\",
        \"account_id\": \"$ACCOUNT\",
        \"region\": \"$REGION\",
        \"agent_version\": \"0.0.0\"
    }" 2>/dev/null || echo "000")

if [ "$_api_http" = "200" ] || [ "$_api_http" = "400" ] || [ "$_api_http" = "422" ]; then
    check "Registration endpoint reachable" "ok"
else
    check "Registration endpoint reachable" "HTTP $_api_http (expected 200/400/422)"
fi

# Test 2: Upload gateway reachability
echo ""
echo "2. Upload Gateway ($UPLOAD_URL)"
_upload_http=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$UPLOAD_URL" 2>/dev/null || echo "000")

if [ "$_upload_http" != "000" ]; then
    check "Upload gateway reachable" "ok"
else
    check "Upload gateway reachable" "Connection failed (DNS or network issue)"
fi

# Test 3: DNS resolution
echo ""
echo "3. DNS Resolution"
if nslookup api-in.onelens.cloud >/dev/null 2>&1; then
    check "api-in.onelens.cloud resolves" "ok"
else
    check "api-in.onelens.cloud resolves" "DNS lookup failed"
fi

if nslookup api-in-fileupload.onelens.cloud >/dev/null 2>&1; then
    check "api-in-fileupload.onelens.cloud resolves" "ok"
else
    check "api-in-fileupload.onelens.cloud resolves" "DNS lookup failed"
fi

# Summary
echo ""
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "Some checks failed. Ensure the following domains are accessible from cluster nodes:"
    echo "  - *.onelens.cloud (API and upload gateway)"
    echo "  - Your private registry endpoint"
    exit 1
else
    echo ""
    echo "All checks passed. Cluster nodes can reach the required OneLens services."
fi
