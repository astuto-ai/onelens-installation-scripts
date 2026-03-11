#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
source "$(lib_dir)/resource-sizing.sh"
set_test_file "test-unit-functions.sh"

###############################################################################
# apply_memory_multiplier
###############################################################################

assert_eq "$(apply_memory_multiplier "384Mi" 1.3)" "500Mi" \
    "apply_memory_multiplier 384Mi x 1.3 = 500Mi"

assert_eq "$(apply_memory_multiplier "100Mi" 1.0)" "100Mi" \
    "apply_memory_multiplier 100Mi x 1.0 = 100Mi"

assert_eq "$(apply_memory_multiplier "0Mi" 1.3)" "0Mi" \
    "apply_memory_multiplier 0Mi x 1.3 = 0Mi"

assert_eq "$(apply_memory_multiplier "1000Mi" 2.0)" "2000Mi" \
    "apply_memory_multiplier 1000Mi x 2.0 = 2000Mi"

assert_eq "$(apply_memory_multiplier "256Mi" 1.6)" "410Mi" \
    "apply_memory_multiplier 256Mi x 1.6 = 410Mi"

###############################################################################
# _cpu_to_millicores
###############################################################################

assert_eq "$(_cpu_to_millicores "100m")" "100" \
    "_cpu_to_millicores 100m = 100"

assert_eq "$(_cpu_to_millicores "1")" "1000" \
    "_cpu_to_millicores 1 = 1000"

assert_eq "$(_cpu_to_millicores "1.5")" "1500" \
    "_cpu_to_millicores 1.5 = 1500"

assert_eq "$(_cpu_to_millicores "250m")" "250" \
    "_cpu_to_millicores 250m = 250"

assert_eq "$(_cpu_to_millicores "")" "0" \
    "_cpu_to_millicores empty = 0"

assert_eq "$(_cpu_to_millicores "garbage")" "0" \
    "_cpu_to_millicores garbage = 0"

assert_eq "$(_cpu_to_millicores "0")" "0" \
    "_cpu_to_millicores 0 = 0"

assert_eq "$(_cpu_to_millicores "0m")" "0" \
    "_cpu_to_millicores 0m = 0"

assert_eq "$(_cpu_to_millicores "0.5")" "500" \
    "_cpu_to_millicores 0.5 = 500 (fractional CPU without m suffix)"

assert_eq "$(_cpu_to_millicores "0.1")" "100" \
    "_cpu_to_millicores 0.1 = 100"

###############################################################################
# _memory_to_mi
###############################################################################

assert_eq "$(_memory_to_mi "128Mi")" "128" \
    "_memory_to_mi 128Mi = 128"

assert_eq "$(_memory_to_mi "1Gi")" "1024" \
    "_memory_to_mi 1Gi = 1024"

assert_eq "$(_memory_to_mi "2Gi")" "2048" \
    "_memory_to_mi 2Gi = 2048"

assert_eq "$(_memory_to_mi "512Ki")" "0" \
    "_memory_to_mi 512Ki = 0 (integer division)"

assert_eq "$(_memory_to_mi "2048Ki")" "2" \
    "_memory_to_mi 2048Ki = 2"

assert_eq "$(_memory_to_mi "")" "0" \
    "_memory_to_mi empty = 0"

assert_eq "$(_memory_to_mi "garbage")" "0" \
    "_memory_to_mi garbage = 0"

assert_eq "$(_memory_to_mi "0Mi")" "0" \
    "_memory_to_mi 0Mi = 0"

###############################################################################
# _max_cpu
###############################################################################

assert_eq "$(_max_cpu "" "")" "" \
    "_max_cpu empty empty = empty"

assert_eq "$(_max_cpu "" "100m")" "100m" \
    "_max_cpu empty 100m = 100m"

assert_eq "$(_max_cpu "100m" "")" "100m" \
    "_max_cpu 100m empty = 100m"

assert_eq "$(_max_cpu "100m" "200m")" "200m" \
    "_max_cpu 100m 200m = 200m"

assert_eq "$(_max_cpu "200m" "100m")" "200m" \
    "_max_cpu 200m 100m = 200m"

assert_eq "$(_max_cpu "1" "500m")" "1" \
    "_max_cpu 1 500m = 1 (1000m > 500m)"

assert_eq "$(_max_cpu "100m" "100m")" "100m" \
    "_max_cpu 100m 100m = 100m (equal returns first)"

assert_eq "$(_max_cpu "1.5" "1200m")" "1.5" \
    "_max_cpu 1.5 1200m = 1.5 (1500m > 1200m)"

###############################################################################
# _max_memory
###############################################################################

assert_eq "$(_max_memory "" "")" "" \
    "_max_memory empty empty = empty"

assert_eq "$(_max_memory "" "128Mi")" "128Mi" \
    "_max_memory empty 128Mi = 128Mi"

assert_eq "$(_max_memory "128Mi" "")" "128Mi" \
    "_max_memory 128Mi empty = 128Mi"

assert_eq "$(_max_memory "256Mi" "128Mi")" "256Mi" \
    "_max_memory 256Mi 128Mi = 256Mi"

assert_eq "$(_max_memory "128Mi" "256Mi")" "256Mi" \
    "_max_memory 128Mi 256Mi = 256Mi"

assert_eq "$(_max_memory "1Gi" "512Mi")" "1Gi" \
    "_max_memory 1Gi 512Mi = 1Gi (1024 > 512)"

assert_eq "$(_max_memory "128Mi" "128Mi")" "128Mi" \
    "_max_memory 128Mi 128Mi = 128Mi (equal)"

###############################################################################
# calculate_avg_labels
###############################################################################

PODS_EMPTY=$(cat "$(fixtures_dir)/pods-empty.json")
PODS_NO_LABELS=$(cat "$(fixtures_dir)/pods-no-labels.json")
PODS_LOW_LABELS=$(cat "$(fixtures_dir)/pods-low-labels.json")
PODS_HIGH_LABELS=$(cat "$(fixtures_dir)/pods-high-labels.json")

assert_eq "$(calculate_avg_labels "$PODS_EMPTY")" "0" \
    "calculate_avg_labels pods-empty.json = 0"

assert_eq "$(calculate_avg_labels "$PODS_NO_LABELS")" "0" \
    "calculate_avg_labels pods-no-labels.json = 0"

assert_eq "$(calculate_avg_labels "$PODS_LOW_LABELS")" "5" \
    "calculate_avg_labels pods-low-labels.json = 5"

assert_eq "$(calculate_avg_labels "$PODS_HIGH_LABELS")" "19" \
    "calculate_avg_labels pods-high-labels.json = 19"

PODS_MEDIUM_LABELS=$(cat "$(fixtures_dir)/pods-medium-labels.json")
assert_eq "$(calculate_avg_labels "$PODS_MEDIUM_LABELS")" "10" \
    "calculate_avg_labels pods-medium-labels.json = 10"

# End-to-end pipeline: calculate_avg_labels → get_label_multiplier
assert_eq "$(get_label_multiplier "$(calculate_avg_labels "$PODS_LOW_LABELS")")" "1.0" \
    "label pipeline: low labels (avg=5) → multiplier 1.0"
assert_eq "$(get_label_multiplier "$(calculate_avg_labels "$PODS_MEDIUM_LABELS")")" "1.3" \
    "label pipeline: medium labels (avg=10) → multiplier 1.3"
assert_eq "$(get_label_multiplier "$(calculate_avg_labels "$PODS_HIGH_LABELS")")" "2.0" \
    "label pipeline: high labels (avg=19) → multiplier 2.0"

###############################################################################
# get_label_multiplier
###############################################################################

assert_eq "$(get_label_multiplier 0)" "1.3" \
    "get_label_multiplier 0 = 1.3 (measurement failed)"

assert_eq "$(get_label_multiplier -1)" "1.3" \
    "get_label_multiplier -1 = 1.3 (measurement failed)"

assert_eq "$(get_label_multiplier 5)" "1.0" \
    "get_label_multiplier 5 = 1.0"

assert_eq "$(get_label_multiplier 7)" "1.0" \
    "get_label_multiplier 7 = 1.0"

assert_eq "$(get_label_multiplier 8)" "1.3" \
    "get_label_multiplier 8 = 1.3"

assert_eq "$(get_label_multiplier 12)" "1.3" \
    "get_label_multiplier 12 = 1.3"

assert_eq "$(get_label_multiplier 13)" "1.6" \
    "get_label_multiplier 13 = 1.6"

assert_eq "$(get_label_multiplier 17)" "1.6" \
    "get_label_multiplier 17 = 1.6"

assert_eq "$(get_label_multiplier 18)" "2.0" \
    "get_label_multiplier 18 = 2.0"

assert_eq "$(get_label_multiplier 25)" "2.0" \
    "get_label_multiplier 25 = 2.0"

###############################################################################
# normalize_chart_version
###############################################################################

assert_eq "$(normalize_chart_version "2.1.3")" "2.1.3" \
    "normalize_chart_version 2.1.3 echoes 2.1.3"
assert_exit_code 0 "normalize_chart_version 2.1.3 exits 0" \
    normalize_chart_version "2.1.3"

assert_eq "$(normalize_chart_version "v2.1.3")" "2.1.3" \
    "normalize_chart_version v2.1.3 echoes 2.1.3"
assert_exit_code 0 "normalize_chart_version v2.1.3 exits 0" \
    normalize_chart_version "v2.1.3"

assert_eq "$(normalize_chart_version "release/v1.7.0")" "1.7.0" \
    "normalize_chart_version release/v1.7.0 echoes 1.7.0"
assert_exit_code 0 "normalize_chart_version release/v1.7.0 exits 0" \
    normalize_chart_version "release/v1.7.0"

assert_eq "$(normalize_chart_version "release/1.7.0")" "1.7.0" \
    "normalize_chart_version release/1.7.0 echoes 1.7.0"
assert_exit_code 0 "normalize_chart_version release/1.7.0 exits 0" \
    normalize_chart_version "release/1.7.0"

assert_exit_code 1 "normalize_chart_version abc exits 1" \
    normalize_chart_version "abc"

assert_exit_code 1 "normalize_chart_version 1.7 exits 1 (not X.Y.Z)" \
    normalize_chart_version "1.7"

assert_exit_code 1 "normalize_chart_version empty exits 1" \
    normalize_chart_version ""

###############################################################################
# Summary
###############################################################################

test_summary
exit $?
