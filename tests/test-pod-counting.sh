#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
source "$(lib_dir)/resource-sizing.sh"
set_test_file "test-pod-counting.sh"

###############################################################################
# count_deploy_pods
###############################################################################
echo ""
echo "--- count_deploy_pods ---"

# 1. Empty deployments + empty HPA → 0
DEPLOY_EMPTY=$(cat "$(fixtures_dir)/deployments-empty.json")
HPA_EMPTY=$(cat "$(fixtures_dir)/hpa-empty.json")
result=$(count_deploy_pods "$DEPLOY_EMPTY" "$HPA_EMPTY")
assert_eq "$result" "0" "empty deployments → 0 pods"

# 2. deployments-no-hpa.json + hpa-empty.json → sum of spec.replicas = 2+3+5 = 10
DEPLOY_NO_HPA=$(cat "$(fixtures_dir)/deployments-no-hpa.json")
result=$(count_deploy_pods "$DEPLOY_NO_HPA" "$HPA_EMPTY")
assert_eq "$result" "10" "no HPA → sum of replicas (2+3+5=10)"

# 3. deployments-with-hpa.json + hpa-single.json → HPA maxReplicas for web (20) + api replicas (2) = 22
DEPLOY_WITH_HPA=$(cat "$(fixtures_dir)/deployments-with-hpa.json")
HPA_SINGLE=$(cat "$(fixtures_dir)/hpa-single.json")
result=$(count_deploy_pods "$DEPLOY_WITH_HPA" "$HPA_SINGLE")
assert_eq "$result" "22" "single HPA → maxReplicas for targeted (20) + replicas for non-targeted (2) = 22"

# 4. deployments-dual-hpa.json + hpa-dual.json → max(10,20) = 20 (not sum!)
DEPLOY_DUAL_HPA=$(cat "$(fixtures_dir)/deployments-dual-hpa.json")
HPA_DUAL=$(cat "$(fixtures_dir)/hpa-dual.json")
result=$(count_deploy_pods "$DEPLOY_DUAL_HPA" "$HPA_DUAL")
assert_eq "$result" "20" "dual HPA bug fix → max(maxReplicas) not sum: max(10,20) = 20"

# 5. deployments-missing-replicas.json + hpa-empty.json → 0 (missing replicas defaults to 0)
DEPLOY_MISSING=$(cat "$(fixtures_dir)/deployments-missing-replicas.json")
result=$(count_deploy_pods "$DEPLOY_MISSING" "$HPA_EMPTY")
assert_eq "$result" "0" "missing replicas field → defaults to 0"

###############################################################################
# count_sts_pods
###############################################################################
echo ""
echo "--- count_sts_pods ---"

# 1. Empty statefulsets → 0
STS_EMPTY='{"items": []}'
result=$(count_sts_pods "$STS_EMPTY" "$HPA_EMPTY")
assert_eq "$result" "0" "empty statefulsets → 0 pods"

# 2. statefulsets-no-hpa.json + hpa-empty.json → sum of replicas = 3+2 = 5
STS_NO_HPA=$(cat "$(fixtures_dir)/statefulsets-no-hpa.json")
result=$(count_sts_pods "$STS_NO_HPA" "$HPA_EMPTY")
assert_eq "$result" "5" "no HPA → sum of replicas (3+2=5)"

# 3. statefulsets-with-hpa.json + hpa-statefulset.json → HPA maxReplicas = 15
STS_WITH_HPA=$(cat "$(fixtures_dir)/statefulsets-with-hpa.json")
HPA_STS=$(cat "$(fixtures_dir)/hpa-statefulset.json")
result=$(count_sts_pods "$STS_WITH_HPA" "$HPA_STS")
assert_eq "$result" "15" "StatefulSet with HPA → maxReplicas = 15"

###############################################################################
# count_ds_pods
###############################################################################
echo ""
echo "--- count_ds_pods ---"

result=$(count_ds_pods 0 0)
assert_eq "$result" "0" "0 nodes, 0 daemonsets → 0"

result=$(count_ds_pods 3 5)
assert_eq "$result" "15" "3 nodes, 5 daemonsets → 15"

result=$(count_ds_pods 10 0)
assert_eq "$result" "0" "10 nodes, 0 daemonsets → 0"

result=$(count_ds_pods 1 1)
assert_eq "$result" "1" "1 node, 1 daemonset → 1"

###############################################################################
# calculate_total_pods
###############################################################################
echo ""
echo "--- calculate_total_pods ---"

result=$(calculate_total_pods 0 0 0)
assert_eq "$result" "0" "0+0+0 → 0 (0 * 1.25 = 0)"

result=$(calculate_total_pods 100 0 0)
assert_eq "$result" "125" "100+0+0 → 125 (100 * 1.25)"

result=$(calculate_total_pods 80 10 10)
assert_eq "$result" "125" "80+10+10 → 125 (100 * 1.25)"

result=$(calculate_total_pods 1 0 0)
assert_eq "$result" "2" "1+0+0 → 2 (1 * 1.25 + 0.99 = 2.24, int = 2)"

result=$(calculate_total_pods 1000 200 300)
assert_eq "$result" "1875" "1000+200+300 → 1875 (1500 * 1.25)"

###############################################################################
# Mixed cluster integration test
###############################################################################
echo ""
echo "--- mixed cluster integration ---"

MIXED_DEPLOY=$(cat "$(fixtures_dir)/mixed-cluster/mixed-deployments.json")
MIXED_STS=$(cat "$(fixtures_dir)/mixed-cluster/mixed-statefulsets.json")
MIXED_HPA=$(cat "$(fixtures_dir)/mixed-cluster/mixed-hpas.json")
MIXED_PODS=$(cat "$(fixtures_dir)/mixed-cluster/mixed-pods.json")

# Deploy pods: frontend→30(HPA), backend→50(HPA), gateway→10(HPA), cron-runner→1, monitoring→1 = 92
deploy_pods=$(count_deploy_pods "$MIXED_DEPLOY" "$MIXED_HPA")
assert_eq "$deploy_pods" "92" "mixed deploy pods: 3 HPA-targeted (30+50+10) + 2 plain (1+1) = 92"

# STS pods: redis→9(HPA targets StatefulSet redis), kafka→5(no HPA) = 14
sts_pods=$(count_sts_pods "$MIXED_STS" "$MIXED_HPA")
assert_eq "$sts_pods" "14" "mixed sts pods: redis→9 (HPA) + kafka→5 = 14"

# DS pods: assume 5 nodes, 3 daemonsets = 15
ds_pods=$(count_ds_pods 5 3)
assert_eq "$ds_pods" "15" "mixed ds pods: 5 nodes * 3 daemonsets = 15"

# Total: (92 + 14 + 15) * 1.25 + 0.99 = 121 * 1.25 + 0.99 = 152.24 → 152
total=$(calculate_total_pods "$deploy_pods" "$sts_pods" "$ds_pods")
assert_eq "$total" "152" "mixed total: (92+14+15) * 1.25 = 152 (with ceiling)"

###############################################################################
# Summary
###############################################################################
test_summary
exit $?
