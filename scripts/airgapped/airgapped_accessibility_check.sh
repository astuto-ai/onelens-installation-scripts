#!/bin/bash
#
# airgapped_accessibility_check.sh — Verify network connectivity for OneLens air-gapped deployment.
#
# Usage:
#   curl -fsSL https://astuto-ai.github.io/onelens-installation-scripts/scripts/airgapped/airgapped_accessibility_check.sh | bash
#
# No parameters required. Tests connectivity to OneLens API and upload gateway.
#
set -euo pipefail

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

# Test 1: API reachability (GET-safe endpoint, no side-effects)
echo "1. OneLens API ($API_URL)"
if curl -fsSL --max-time 10 "$API_URL/v1/kubernetes/cluster-version" -o /dev/null 2>/dev/null; then
    check "API reachable" "ok"
else
    # curl -f exits non-zero on HTTP errors; retry without -f to distinguish network vs HTTP failure
    if curl -sL --max-time 10 "$API_URL/v1/kubernetes/cluster-version" -o /dev/null 2>/dev/null; then
        check "API reachable" "ok"
    else
        check "API reachable" "connection failed"
    fi
fi

# Test 2: Upload gateway reachability
echo ""
echo "2. Upload Gateway ($UPLOAD_URL)"
if curl -sL --max-time 10 "$UPLOAD_URL" -o /dev/null 2>/dev/null; then
    check "Upload gateway reachable" "ok"
else
    check "Upload gateway reachable" "connection failed"
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
