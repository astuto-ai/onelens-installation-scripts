#!/bin/bash
# VictoriaMetrics chart rendering: scrape size limit and optional-exporter scrape jobs.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
set_test_file "test-vm-chart.sh"
ROOT=$(repo_root)

if ! command -v helm &>/dev/null; then
    echo "SKIP: helm not found, skipping VictoriaMetrics chart tests"
    exit 0
fi

render() {
    helm template t "$ROOT/charts/onelens-agent" -f "$ROOT/globalvalues.yaml" "$@" 2>/dev/null
}
render_vm() {
    render --set onelens-agent.metricsBackend=victoriametrics "$@"
}
# One rendered document, selected by its template file
doc() {
    awk -v src="$1" '$0 ~ "^# Source: .*" src {f=1; next} /^---/ {f=0} f'
}
jobs() {
    grep -oE "job_name: '?[a-z0-9-]+'?" | sed -E "s/job_name: '?([a-z0-9-]+)'?/\1/" | sort | tr '\n' ' ' | sed 's/ $//'
}

BASE_JOBS="kubernetes-nodes kubernetes-nodes-cadvisor kubernetes-service-endpoints opencost prometheus prometheus-pushgateway"

# ---------------------------------------------------------------------------
# Test 1: scrape size limit raised from VictoriaMetrics' 16MB default
# ---------------------------------------------------------------------------
dep=$(render_vm | doc victoriametrics-deployment.yaml)
assert_contains "$dep" '"-promscrape.maxScrapeSize=128MiB"' "VM deployment raises -promscrape.maxScrapeSize to 128MiB"
dep=$(render_vm --set onelens-agent.victoriaMetrics.maxScrapeSize=256MiB | doc victoriametrics-deployment.yaml)
assert_contains "$dep" '"-promscrape.maxScrapeSize=256MiB"' "maxScrapeSize can be overridden"

# ---------------------------------------------------------------------------
# Test 1b: label limit above real series widths (VM drops a whole series over it),
#          and the scrape config is re-read when its ConfigMap changes
# ---------------------------------------------------------------------------
dep=$(render_vm | doc victoriametrics-deployment.yaml)
assert_contains "$dep" '"-maxLabelsPerTimeseries=200"' "VM deployment raises -maxLabelsPerTimeseries to 200"
assert_contains "$dep" '"-promscrape.configCheckInterval=1m"' "VM re-reads its scrape config every minute"
dep=$(render_vm --set onelens-agent.victoriaMetrics.configCheckInterval=0 | doc victoriametrics-deployment.yaml)
assert_contains "$dep" '"-promscrape.configCheckInterval=0"' "configCheckInterval=0 is kept (read config only at startup)"

# ---------------------------------------------------------------------------
# Test 2: optional exporters are scraped only when deployed
# ---------------------------------------------------------------------------
assert_eq "$(render_vm | doc victoriametrics-configmap.yaml | jobs)" "$BASE_JOBS" \
    "default: no node-exporter, dcgm or network-costs job"
assert_eq "$(render_vm --set-string onelens-agent.env.NODE_EXPORTER_ENABLED=true | doc victoriametrics-configmap.yaml | jobs)" \
    "$(echo "$BASE_JOBS node-exporter" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')" \
    "node-exporter opted in: node-exporter job added"
assert_eq "$(render_vm --set onelens-agent.gpu.enabled=true | doc victoriametrics-configmap.yaml | jobs)" \
    "$(echo "$BASE_JOBS dcgm-gpu-metrics" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')" \
    "gpu.enabled=true: dcgm job added"
assert_eq "$(render_vm --set-string onelens-agent.gpu.enabled=false | doc victoriametrics-configmap.yaml | jobs)" "$BASE_JOBS" \
    "gpu.enabled=\"false\" (string): no dcgm job"
assert_eq "$(render_vm --set onelens-agent.networkCosts.enabled=true | doc victoriametrics-configmap.yaml | jobs)" \
    "$(echo "$BASE_JOBS network-costs" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')" \
    "networkCosts.enabled=true: network-costs job added"

# ---------------------------------------------------------------------------
# Test 3: all enabled together, every job name is unique
# ---------------------------------------------------------------------------
all=$(render_vm --set-string onelens-agent.env.NODE_EXPORTER_ENABLED=true --set onelens-agent.gpu.enabled=true \
    --set onelens-agent.networkCosts.enabled=true | doc victoriametrics-configmap.yaml | jobs)
assert_eq "$(echo "$all" | tr ' ' '\n' | sort | uniq -d | tr -d '\n')" "" "no duplicate job names with every exporter enabled"
assert_eq "$(echo "$all" | wc -w | tr -d ' ')" "9" "all 9 jobs rendered with every exporter enabled"

# ---------------------------------------------------------------------------
# Test 4: Prometheus backend unchanged (no VM objects, its jobs still present)
# ---------------------------------------------------------------------------
prom=$(render)
assert_eq "$(echo "$prom" | grep -c 'victoriametrics-configmap.yaml' || true)" "0" "Prometheus backend renders no VM config"
assert_eq "$(echo "$prom" | grep -c 'maxScrapeSize' || true)" "0" "Prometheus backend has no maxScrapeSize flag"
for job in node-exporter dcgm-gpu-metrics network-costs; do
    assert_gt "$(echo "$prom" | grep -cE "job_name: '?$job'?" || true)" "0" "Prometheus config still has the $job job"
done

test_summary
