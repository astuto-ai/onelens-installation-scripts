#!/bin/bash
# lib/resource-sizing.sh — Shared resource sizing functions
# Sourced by install.sh. Embedded into patching.sh at build time.
# Do NOT add kubectl/helm calls here — this must be testable without a cluster.

###############################################################################
# Pure math functions
###############################################################################

# apply_memory_multiplier "$mem_str" "$multiplier"
# Multiply a memory string (e.g. "384Mi") by a float multiplier, rounding up.
# Example: "384Mi" x 1.3 → "500Mi"
apply_memory_multiplier() {
    local mem_str="$1"
    local multiplier="$2"
    local mem_val="${mem_str%Mi}"
    local result=$(echo "$mem_val $multiplier" | awk '{printf "%d", int($1 * $2 + 0.99)}')
    echo "${result}Mi"
}

# _cpu_to_millicores "$value"
# Convert a CPU string to integer millicores.
# "100m"→100, "1"→1000, "1.5"→1500, ""→0
_cpu_to_millicores() {
  local v="$1"
  if [[ -z "$v" ]]; then echo "0"; return; fi
  if [[ "$v" =~ ^([0-9]+)m$ ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "$(awk "BEGIN { printf \"%.0f\", $v * 1000 }")"
  else
    echo "0"
  fi
}

# _memory_to_mi "$value"
# Convert a memory string to integer MiB.
# "128Mi"→128, "1Gi"→1024, "512Ki"→0 (integer division)
_memory_to_mi() {
  local v="$1"
  if [[ -z "$v" ]]; then echo "0"; return; fi
  if [[ "$v" =~ ^([0-9]+)Mi$ ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$v" =~ ^([0-9]+)Gi$ ]]; then
    echo "$(( ${BASH_REMATCH[1]} * 1024 ))"
  elif [[ "$v" =~ ^([0-9]+)Ki$ ]]; then
    echo "$(( ${BASH_REMATCH[1]} / 1024 ))"
  else
    echo "0"
  fi
}

# _max_cpu "$a" "$b"
# Return the larger of two CPU strings (preserving original format).
_max_cpu() {
  local a="$1" b="$2"
  if [[ -z "$a" && -z "$b" ]]; then echo ""; return; fi
  if [[ -z "$a" ]]; then echo "$b"; return; fi
  if [[ -z "$b" ]]; then echo "$a"; return; fi
  local ma=$(_cpu_to_millicores "$a") mb=$(_cpu_to_millicores "$b")
  if [[ "$ma" -ge "$mb" ]]; then echo "$a"; else echo "$b"; fi
}

# _max_memory "$a" "$b"
# Return the larger of two memory strings (preserving original format).
_max_memory() {
  local a="$1" b="$2"
  if [[ -z "$a" && -z "$b" ]]; then echo ""; return; fi
  if [[ -z "$a" ]]; then echo "$b"; return; fi
  if [[ -z "$b" ]]; then echo "$a"; return; fi
  local ma=$(_memory_to_mi "$a") mb=$(_memory_to_mi "$b")
  if [[ "$ma" -ge "$mb" ]]; then echo "$a"; else echo "$b"; fi
}

###############################################################################
# Usage-based sizing — pure math (no I/O)
###############################################################################

# Floor/cap constants for usage-based sizing.
# Floor: tier-tiny minimums. Cap: 2x very-large maximums.
# These prevent usage-based from going absurdly low (zero usage) or high (runaway OOM doubling).
_USAGE_FLOOR_PROM_MEM=150   # tiny tier Prometheus memory (Mi)
_USAGE_FLOOR_KSM_MEM=64     # tiny tier KSM memory (Mi)
_USAGE_FLOOR_OPENCOST_MEM=128 # tiny tier OpenCost memory (Mi)
_USAGE_FLOOR_AGENT_MEM=384  # tiny tier Agent memory (Mi)
_USAGE_FLOOR_CPU=50          # tiny tier minimum CPU (millicores)
_USAGE_CAP_PROM_MEM=4800    # 2x very-large Prometheus memory (Mi)
_USAGE_CAP_KSM_MEM=1024     # 2x very-large KSM memory (Mi)
_USAGE_CAP_OPENCOST_MEM=1536 # 2x very-large OpenCost memory (Mi)
_USAGE_CAP_AGENT_MEM=2560   # 2x very-large Agent memory (Mi)
_USAGE_CAP_CPU=1200          # 2x very-large maximum CPU (millicores)

# apply_cpu_multiplier "$cpu_str" "$multiplier"
# Multiply a CPU string by a float multiplier, returning millicores format.
# Examples: "100m" x 1.25 → "125m", "1" x 1.25 → "1250m", "0.5" x 1.25 → "625m"
apply_cpu_multiplier() {
    local cpu_str="$1" multiplier="$2"
    local mc=$(_cpu_to_millicores "$cpu_str")
    local result=$(echo "$mc $multiplier" | awk '{printf "%d", int($1 * $2 + 0.99)}')
    echo "${result}m"
}

# _clamp_resource "$value" "$floor" "$cap"
# Clamp an integer between floor and cap. Returns clamped integer.
_clamp_resource() {
    local val="$1" floor="$2" cap="$3"
    if [ "$val" -lt "$floor" ] 2>/dev/null; then echo "$floor"; return; fi
    if [ "$val" -gt "$cap" ] 2>/dev/null; then echo "$cap"; return; fi
    echo "$val"
}

# calculate_usage_memory "$max_72h_bytes" "$buffer" "$floor" "$cap"
# Convert max bytes from Prometheus to Mi with buffer, clamped to floor/cap.
# Returns Mi string (e.g. "258Mi"). Returns empty if input is empty/zero.
calculate_usage_memory() {
    local bytes="$1" buffer="$2" floor="$3" cap="$4"
    if [ -z "$bytes" ] || [ "$bytes" = "0" ]; then echo ""; return; fi
    local mi=$(echo "$bytes $buffer" | awk '{printf "%d", int($1 / 1048576 * $2 + 0.99)}')
    mi=$(_clamp_resource "$mi" "$floor" "$cap")
    echo "${mi}Mi"
}

# calculate_usage_cpu "$max_72h_cores" "$buffer" "$floor" "$cap"
# Convert max cores from Prometheus to millicores with buffer, clamped.
# Returns millicores string (e.g. "125m"). Returns empty if input is empty/zero.
calculate_usage_cpu() {
    local cores="$1" buffer="$2" floor="$3" cap="$4"
    if [ -z "$cores" ] || [ "$cores" = "0" ]; then echo ""; return; fi
    local mc=$(echo "$cores $buffer" | awk '{printf "%d", int($1 * 1000 * $2 + 0.99)}')
    mc=$(_clamp_resource "$mc" "$floor" "$cap")
    echo "${mc}m"
}

# should_upsize "$proposed_str" "$current_str" "$unit"
# Returns 0 (true) if proposed > current. Unit is "memory" or "cpu".
# Used by 5-min checks to enforce upsize-only.
should_upsize() {
    local proposed="$1" current="$2" unit="$3"
    if [ -z "$proposed" ] || [ -z "$current" ]; then return 1; fi
    if [ "$unit" = "memory" ]; then
        local p=$(_memory_to_mi "$proposed") c=$(_memory_to_mi "$current")
    else
        local p=$(_cpu_to_millicores "$proposed") c=$(_cpu_to_millicores "$current")
    fi
    [ "$p" -gt "$c" ]
}

# is_safe_downsize "$proposed_str" "$current_str"
# Returns 0 (true) if proposed >= 50% of current. Safety guard against catastrophic downsize.
# A legitimate right-sizing should never halve memory in one step.
is_safe_downsize() {
    local proposed="$1" current="$2"
    if [ -z "$proposed" ] || [ -z "$current" ]; then return 1; fi
    local p=$(_memory_to_mi "$proposed") c=$(_memory_to_mi "$current")
    local half=$(( c / 2 ))
    [ "$p" -ge "$half" ]
}

# calculate_oom_response_memory "$current_mem_str" "$cap"
# Double current memory, capped at $cap Mi. Returns Mi string.
calculate_oom_response_memory() {
    local current="$1" cap="$2"
    local c=$(_memory_to_mi "$current")
    local doubled=$(( c * 2 ))
    doubled=$(_clamp_resource "$doubled" "$c" "$cap")
    echo "${doubled}Mi"
}

###############################################################################
# Pod counting functions (accept JSON strings as arguments)
###############################################################################

# count_deploy_pods "$deployments_json" "$hpa_json"
# Count expected pods from Deployments, using HPA maxReplicas where available.
# Falls back to deployment's .spec.replicas when no HPA targets it.
count_deploy_pods() {
    local deploy_json="$1"
    local hpa_json="$2"
    echo "$deploy_json" | jq --argjson hpa "$hpa_json" '
        [.items[] | . as $dep |
            ([($hpa.items[] |
                select(.metadata.namespace == $dep.metadata.namespace and
                       .spec.scaleTargetRef.kind == "Deployment" and
                       .spec.scaleTargetRef.name == $dep.metadata.name) |
                .spec.maxReplicas)] | max) // ($dep.spec.replicas // 0)
        ] | add // 0
    ' 2>/dev/null || echo "0"
}

# count_sts_pods "$statefulsets_json" "$hpa_json"
# Count expected pods from StatefulSets, using HPA maxReplicas where available.
# Falls back to statefulset's .spec.replicas when no HPA targets it.
count_sts_pods() {
    local sts_json="$1"
    local hpa_json="$2"
    echo "$sts_json" | jq --argjson hpa "$hpa_json" '
        [.items[] | . as $sts |
            ([($hpa.items[] |
                select(.metadata.namespace == $sts.metadata.namespace and
                       .spec.scaleTargetRef.kind == "StatefulSet" and
                       .spec.scaleTargetRef.name == $sts.metadata.name) |
                .spec.maxReplicas)] | max) // ($sts.spec.replicas // 0)
        ] | add // 0
    ' 2>/dev/null || echo "0"
}

# count_ds_pods "$num_nodes" "$num_daemonsets"
# Estimate DaemonSet pod count: nodes * daemonsets.
count_ds_pods() {
    echo "$(( $1 * $2 ))"
}

# calculate_total_pods "$deploy_pods" "$sts_pods" "$ds_pods"
# Sum all pod counts and add a 25% buffer (rounded up).
calculate_total_pods() {
    local desired=$(( $1 + $2 + $3 ))
    echo "$desired" | awk '{printf "%d", int($1 * 1.25 + 0.99)}'
}

###############################################################################
# Label density functions
###############################################################################

# calculate_avg_labels "$pods_json"
# Return the average number of labels per pod (integer, floored).
calculate_avg_labels() {
    echo "$1" | jq '[.items[].metadata.labels | length] | add / length | floor' 2>/dev/null || echo "0"
}

# get_label_multiplier "$avg_labels"
# Map average label count to a memory multiplier.
# <=0 (measurement failed) → 1.3, <=7 → 1.0, <=12 → 1.3, <=17 → 1.6, else → 2.0
get_label_multiplier() {
    local avg="$1"
    if [ "$avg" -le 0 ] 2>/dev/null; then
        echo "1.3"  # default when measurement fails
    elif [ "$avg" -le 7 ]; then
        echo "1.0"
    elif [ "$avg" -le 12 ]; then
        echo "1.3"
    elif [ "$avg" -le 17 ]; then
        echo "1.6"
    else
        echo "2.0"
    fi
}

###############################################################################
# Version handling
###############################################################################

# normalize_chart_version "$raw_version"
# Strip release/ and v prefixes, validate semver format.
# Echoes the cleaned version. Returns 1 if not valid semver.
normalize_chart_version() {
    local ver="$1"
    ver=$(echo "$ver" | sed 's|^release/||' | sed 's|^v||')
    if echo "$ver" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
        echo "$ver"
        return 0
    else
        echo "$ver"
        return 1
    fi
}

###############################################################################
# Tier selection — resource sizing
###############################################################################

# select_resource_tier "$total_pods"
# Set ALL global resource variables based on pod-count thresholds.
# Sets TIER variable with the tier name. Must be called without $() subshell.
select_resource_tier() {
    local total_pods="$1"

    if [ "$total_pods" -lt 50 ]; then
        # ── Tiny ──
        PROMETHEUS_CPU_REQUEST="100m"
        PROMETHEUS_MEMORY_REQUEST="150Mi"
        PROMETHEUS_CPU_LIMIT="100m"
        PROMETHEUS_MEMORY_LIMIT="150Mi"

        OPENCOST_CPU_REQUEST="100m"
        OPENCOST_MEMORY_REQUEST="128Mi"
        OPENCOST_CPU_LIMIT="100m"
        OPENCOST_MEMORY_LIMIT="128Mi"

        ONELENS_CPU_REQUEST="100m"
        ONELENS_MEMORY_REQUEST="256Mi"
        ONELENS_CPU_LIMIT="300m"
        ONELENS_MEMORY_LIMIT="384Mi"

        KSM_CPU_REQUEST="50m"
        KSM_MEMORY_REQUEST="64Mi"
        KSM_CPU_LIMIT="50m"
        KSM_MEMORY_LIMIT="64Mi"

        PROMETHEUS_PUSHGATEWAY_CPU_REQUEST="25m"
        PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST="64Mi"
        PROMETHEUS_PUSHGATEWAY_CPU_LIMIT="25m"
        PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT="64Mi"

        TIER="tiny"

    elif [ "$total_pods" -lt 100 ]; then
        # ── Small ──
        PROMETHEUS_CPU_REQUEST="100m"
        PROMETHEUS_MEMORY_REQUEST="275Mi"
        PROMETHEUS_CPU_LIMIT="100m"
        PROMETHEUS_MEMORY_LIMIT="275Mi"

        OPENCOST_CPU_REQUEST="100m"
        OPENCOST_MEMORY_REQUEST="192Mi"
        OPENCOST_CPU_LIMIT="100m"
        OPENCOST_MEMORY_LIMIT="192Mi"

        ONELENS_CPU_REQUEST="125m"
        ONELENS_MEMORY_REQUEST="320Mi"
        ONELENS_CPU_LIMIT="375m"
        ONELENS_MEMORY_LIMIT="480Mi"

        KSM_CPU_REQUEST="50m"
        KSM_MEMORY_REQUEST="128Mi"
        KSM_CPU_LIMIT="50m"
        KSM_MEMORY_LIMIT="128Mi"

        PROMETHEUS_PUSHGATEWAY_CPU_REQUEST="25m"
        PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST="64Mi"
        PROMETHEUS_PUSHGATEWAY_CPU_LIMIT="25m"
        PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT="64Mi"

        TIER="small"

    elif [ "$total_pods" -lt 500 ]; then
        # ── Medium ──
        PROMETHEUS_CPU_REQUEST="150m"
        PROMETHEUS_MEMORY_REQUEST="420Mi"
        PROMETHEUS_CPU_LIMIT="150m"
        PROMETHEUS_MEMORY_LIMIT="420Mi"

        OPENCOST_CPU_REQUEST="100m"
        OPENCOST_MEMORY_REQUEST="256Mi"
        OPENCOST_CPU_LIMIT="100m"
        OPENCOST_MEMORY_LIMIT="256Mi"

        ONELENS_CPU_REQUEST="125m"
        ONELENS_MEMORY_REQUEST="480Mi"
        ONELENS_CPU_LIMIT="375m"
        ONELENS_MEMORY_LIMIT="640Mi"

        KSM_CPU_REQUEST="50m"
        KSM_MEMORY_REQUEST="192Mi"
        KSM_CPU_LIMIT="50m"
        KSM_MEMORY_LIMIT="192Mi"

        PROMETHEUS_PUSHGATEWAY_CPU_REQUEST="50m"
        PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST="100Mi"
        PROMETHEUS_PUSHGATEWAY_CPU_LIMIT="50m"
        PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT="100Mi"

        TIER="medium"

    elif [ "$total_pods" -lt 1000 ]; then
        # ── Large ──
        PROMETHEUS_CPU_REQUEST="250m"
        PROMETHEUS_MEMORY_REQUEST="720Mi"
        PROMETHEUS_CPU_LIMIT="250m"
        PROMETHEUS_MEMORY_LIMIT="720Mi"

        OPENCOST_CPU_REQUEST="150m"
        OPENCOST_MEMORY_REQUEST="384Mi"
        OPENCOST_CPU_LIMIT="150m"
        OPENCOST_MEMORY_LIMIT="384Mi"

        ONELENS_CPU_REQUEST="125m"
        ONELENS_MEMORY_REQUEST="640Mi"
        ONELENS_CPU_LIMIT="440m"
        ONELENS_MEMORY_LIMIT="800Mi"

        KSM_CPU_REQUEST="50m"
        KSM_MEMORY_REQUEST="256Mi"
        KSM_CPU_LIMIT="50m"
        KSM_MEMORY_LIMIT="256Mi"

        PROMETHEUS_PUSHGATEWAY_CPU_REQUEST="50m"
        PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST="100Mi"
        PROMETHEUS_PUSHGATEWAY_CPU_LIMIT="50m"
        PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT="100Mi"

        TIER="large"

    elif [ "$total_pods" -lt 1500 ]; then
        # ── Extra Large ──
        PROMETHEUS_CPU_REQUEST="400m"
        PROMETHEUS_MEMORY_REQUEST="1600Mi"
        PROMETHEUS_CPU_LIMIT="400m"
        PROMETHEUS_MEMORY_LIMIT="1600Mi"

        OPENCOST_CPU_REQUEST="150m"
        OPENCOST_MEMORY_REQUEST="512Mi"
        OPENCOST_CPU_LIMIT="150m"
        OPENCOST_MEMORY_LIMIT="512Mi"

        ONELENS_CPU_REQUEST="125m"
        ONELENS_MEMORY_REQUEST="800Mi"
        ONELENS_CPU_LIMIT="500m"
        ONELENS_MEMORY_LIMIT="960Mi"

        KSM_CPU_REQUEST="100m"
        KSM_MEMORY_REQUEST="384Mi"
        KSM_CPU_LIMIT="100m"
        KSM_MEMORY_LIMIT="384Mi"

        PROMETHEUS_PUSHGATEWAY_CPU_REQUEST="50m"
        PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST="128Mi"
        PROMETHEUS_PUSHGATEWAY_CPU_LIMIT="50m"
        PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT="128Mi"

        TIER="extra-large"

    else
        # ── Very Large (1500+) ──
        PROMETHEUS_CPU_REQUEST="600m"
        PROMETHEUS_MEMORY_REQUEST="2400Mi"
        PROMETHEUS_CPU_LIMIT="600m"
        PROMETHEUS_MEMORY_LIMIT="2400Mi"

        OPENCOST_CPU_REQUEST="200m"
        OPENCOST_MEMORY_REQUEST="768Mi"
        OPENCOST_CPU_LIMIT="200m"
        OPENCOST_MEMORY_LIMIT="768Mi"

        ONELENS_CPU_REQUEST="190m"
        ONELENS_MEMORY_REQUEST="960Mi"
        ONELENS_CPU_LIMIT="565m"
        ONELENS_MEMORY_LIMIT="1280Mi"

        KSM_CPU_REQUEST="100m"
        KSM_MEMORY_REQUEST="512Mi"
        KSM_CPU_LIMIT="100m"
        KSM_MEMORY_LIMIT="512Mi"

        PROMETHEUS_PUSHGATEWAY_CPU_REQUEST="50m"
        PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST="128Mi"
        PROMETHEUS_PUSHGATEWAY_CPU_LIMIT="50m"
        PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT="128Mi"

        TIER="very-large"
    fi
}

###############################################################################
# Tier selection — retention & volume sizing
###############################################################################

# select_retention_tier "$total_pods"
# Set PROMETHEUS_RETENTION, PROMETHEUS_RETENTION_SIZE, and
# PROMETHEUS_VOLUME_SIZE based on pod-count thresholds.
select_retention_tier() {
    local total_pods="$1"

    PROMETHEUS_RETENTION="10d"

    if [ "$total_pods" -lt 50 ]; then
        PROMETHEUS_RETENTION_SIZE="4GB"
        PROMETHEUS_VOLUME_SIZE="8Gi"
    elif [ "$total_pods" -lt 100 ]; then
        PROMETHEUS_RETENTION_SIZE="6GB"
        PROMETHEUS_VOLUME_SIZE="10Gi"
    elif [ "$total_pods" -lt 500 ]; then
        PROMETHEUS_RETENTION_SIZE="12GB"
        PROMETHEUS_VOLUME_SIZE="20Gi"
    elif [ "$total_pods" -lt 1000 ]; then
        PROMETHEUS_RETENTION_SIZE="20GB"
        PROMETHEUS_VOLUME_SIZE="30Gi"
    elif [ "$total_pods" -lt 1500 ]; then
        PROMETHEUS_RETENTION_SIZE="30GB"
        PROMETHEUS_VOLUME_SIZE="40Gi"
    else
        PROMETHEUS_RETENTION_SIZE="35GB"
        PROMETHEUS_VOLUME_SIZE="50Gi"
    fi
}
