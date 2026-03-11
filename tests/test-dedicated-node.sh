#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
source "$(lib_dir)/resource-sizing.sh"
set_test_file "test-dedicated-node.sh"
ROOT=$(repo_root)

###############################################################################
# Prerequisites
###############################################################################
if ! command -v helm &>/dev/null; then
    echo "SKIP: helm not found"
    exit 0
fi
helm repo add onelens https://astuto-ai.github.io/onelens-installation-scripts 2>/dev/null || true
helm repo update onelens 2>/dev/null || true
if ! helm show chart onelens/onelens-agent --version 2.1.3 &>/dev/null; then
    echo "SKIP: chart not accessible"
    exit 0
fi
CHART_VERSION="2.1.3"

###############################################################################
# Test 1: Render with tolerations — verify they appear on all components
###############################################################################
RENDERED=$(helm template test-release onelens/onelens-agent \
    --version "$CHART_VERSION" \
    --set prometheus-opencost-exporter.opencost.tolerations[0].key="dedicated" \
    --set prometheus-opencost-exporter.opencost.tolerations[0].operator="Equal" \
    --set prometheus-opencost-exporter.opencost.tolerations[0].value="monitoring" \
    --set prometheus-opencost-exporter.opencost.tolerations[0].effect="NoSchedule" \
    --set prometheus.server.tolerations[0].key="dedicated" \
    --set prometheus.server.tolerations[0].operator="Equal" \
    --set prometheus.server.tolerations[0].value="monitoring" \
    --set prometheus.server.tolerations[0].effect="NoSchedule" \
    --set onelens-agent.cronJob.tolerations[0].key="dedicated" \
    --set onelens-agent.cronJob.tolerations[0].operator="Equal" \
    --set onelens-agent.cronJob.tolerations[0].value="monitoring" \
    --set onelens-agent.cronJob.tolerations[0].effect="NoSchedule" \
    --set prometheus.prometheus-pushgateway.tolerations[0].key="dedicated" \
    --set prometheus.prometheus-pushgateway.tolerations[0].operator="Equal" \
    --set prometheus.prometheus-pushgateway.tolerations[0].value="monitoring" \
    --set prometheus.prometheus-pushgateway.tolerations[0].effect="NoSchedule" \
    --set prometheus.kube-state-metrics.tolerations[0].key="dedicated" \
    --set prometheus.kube-state-metrics.tolerations[0].operator="Equal" \
    --set prometheus.kube-state-metrics.tolerations[0].value="monitoring" \
    --set prometheus.kube-state-metrics.tolerations[0].effect="NoSchedule" \
    2>/dev/null)

toleration_count=$(echo "$RENDERED" | grep -c 'key: dedicated' || true)
assert_ge "$toleration_count" "5" "tolerations appear on at least 5 component specs"

###############################################################################
# Test 2: Render with nodeSelector — verify it appears on all components
###############################################################################
RENDERED_NS=$(helm template test-release onelens/onelens-agent \
    --version "$CHART_VERSION" \
    --set prometheus-opencost-exporter.opencost.nodeSelector.node-type="monitoring" \
    --set prometheus.server.nodeSelector.node-type="monitoring" \
    --set onelens-agent.cronJob.nodeSelector.node-type="monitoring" \
    --set prometheus.prometheus-pushgateway.nodeSelector.node-type="monitoring" \
    --set prometheus.kube-state-metrics.nodeSelector.node-type="monitoring" \
    2>/dev/null)

ns_count=$(echo "$RENDERED_NS" | grep -c 'node-type: monitoring' || true)
assert_ge "$ns_count" "5" "nodeSelector appears on at least 5 component specs"

###############################################################################
# Test 3: Render WITHOUT tolerations — verify none in output
###############################################################################
RENDERED_PLAIN=$(helm template test-release onelens/onelens-agent \
    --version "$CHART_VERSION" \
    2>/dev/null)

# There should be zero "key: dedicated" lines
dedicated_count=$(echo "$RENDERED_PLAIN" | grep -c 'key: dedicated' || true)
assert_eq "$dedicated_count" "0" "no tolerations when not configured"

###############################################################################
# Test 4: Toleration with operator=Exists (no value)
###############################################################################
RENDERED_EXISTS=$(helm template test-release onelens/onelens-agent \
    --version "$CHART_VERSION" \
    --set prometheus.server.tolerations[0].key="dedicated" \
    --set prometheus.server.tolerations[0].operator="Exists" \
    --set prometheus.server.tolerations[0].effect="NoSchedule" \
    2>/dev/null)

assert_contains "$RENDERED_EXISTS" "operator: Exists" "Exists operator renders correctly"

###############################################################################
# Test 5: Patching --set paths are all leaf-level (3+ dots)
###############################################################################
# Only check resource-related --set paths (with .resources. in the path)
patching_resource_sets=$(grep -oE '\-\-set [a-zA-Z][-a-zA-Z0-9._]*=' "$ROOT/src/patching.sh" | sed 's/--set //' | sed 's/=//' | grep 'resources' || true)
while IFS= read -r path; do
    [ -z "$path" ] && continue
    dot_count=$(echo "$path" | tr -cd '.' | wc -c | tr -d ' ')
    assert_ge "$dot_count" "3" "patching --set path is leaf-level: $path"
done <<< "$patching_resource_sets"

###############################################################################
# Test 6: Tolerations survive patching-style upgrade (reuse-values + resource --set)
###############################################################################
select_resource_tier 200
RENDERED_BOTH=$(helm template test-release onelens/onelens-agent \
    --version "$CHART_VERSION" \
    --set prometheus.server.tolerations[0].key="dedicated" \
    --set prometheus.server.tolerations[0].operator="Equal" \
    --set prometheus.server.tolerations[0].value="monitoring" \
    --set prometheus.server.tolerations[0].effect="NoSchedule" \
    --set prometheus.server.resources.requests.cpu="$PROMETHEUS_CPU_REQUEST" \
    --set prometheus.server.resources.requests.memory="$PROMETHEUS_MEMORY_REQUEST" \
    --set prometheus.server.resources.limits.cpu="$PROMETHEUS_CPU_LIMIT" \
    --set prometheus.server.resources.limits.memory="$PROMETHEUS_MEMORY_LIMIT" \
    2>/dev/null)

assert_contains "$RENDERED_BOTH" "key: dedicated" "tolerations survive resource --set overrides"
assert_contains "$RENDERED_BOTH" "cpu: $PROMETHEUS_CPU_REQUEST" "resources set alongside tolerations"

###############################################################################
# Summary
###############################################################################
test_summary
exit $?
