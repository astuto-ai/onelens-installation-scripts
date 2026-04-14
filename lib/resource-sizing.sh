#!/bin/bash
# lib/resource-sizing.sh — Shared resource sizing functions
# Sourced by install.sh. Embedded into patching.sh at build time.
# Do NOT add kubectl/helm calls here — this must be testable without a cluster.

###############################################################################
# Pure math functions
###############################################################################

# apply_memory_multiplier "$mem_str" "$multiplier"
# Multiply a memory string (e.g. "384Mi") by a float multiplier, rounded to clean multiples.
# Values <100Mi round up to nearest 10. Values >=100Mi round up to nearest 100.
# Avoids odd values (768Mi, 1536Mi) that can cause Kubernetes scheduling issues.
# Example: "384Mi" x 1.5 → "600Mi", "64Mi" x 1.25 → "80Mi"
apply_memory_multiplier() {
    local mem_str="$1"
    local multiplier="$2"
    local mem_val="${mem_str%Mi}"
    local result=$(echo "$mem_val $multiplier" | awk '{
        raw = int($1 * $2 + 0.99)
        if (raw < 100) { result = int((raw + 9) / 10) * 10 }
        else           { result = int((raw + 99) / 100) * 100 }
        printf "%d", result
    }')
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
# Floor: tier-tiny minimums. Cap: hard maximums for mega clusters.
# These prevent usage-based from going absurdly low (zero usage) or high (runaway OOM doubling).
_USAGE_FLOOR_PROM_MEM=150   # tiny tier Prometheus memory (Mi)
_USAGE_FLOOR_KSM_MEM=64     # tiny tier KSM memory (Mi)
_USAGE_FLOOR_OPENCOST_MEM=192 # tiny tier OpenCost memory (Mi)
_USAGE_FLOOR_AGENT_MEM=384  # tiny tier Agent memory (Mi)
_USAGE_FLOOR_CPU=50          # tiny tier minimum CPU (millicores)
_USAGE_CAP_PROM_MEM=8192    # max Prometheus memory for mega clusters (Mi)
_USAGE_CAP_KSM_MEM=4800     # max KSM memory for mega clusters (Mi)
_USAGE_CAP_OPENCOST_MEM=4800 # max OpenCost memory for mega clusters (Mi)
_USAGE_CAP_AGENT_MEM=8192   # max agent memory (raised 4096→8192 in v2.1.66; agent mem scales with metric cardinality/cost data volume, not just pod count — 5 customer clusters hit the 4GB cap)
_USAGE_CAP_CPU=1200          # 2x very-large maximum CPU (millicores)

# apply_cpu_multiplier "$cpu_str" "$multiplier"
# Multiply a CPU string by a float multiplier, rounded up to nearest 50m (cgroup-safe).
# Examples: "100m" x 1.25 → "150m", "200m" x 1.5 → "300m"
apply_cpu_multiplier() {
    local cpu_str="$1" multiplier="$2"
    local mc=$(_cpu_to_millicores "$cpu_str")
    local result=$(echo "$mc $multiplier" | awk '{
        raw = int($1 * $2 + 0.99)
        result = int((raw + 49) / 50) * 50
        printf "%d", result
    }')
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
    local mi=$(echo "$bytes $buffer" | awk '{
        raw = int($1 / 1048576 * $2 + 0.99)
        if (raw < 100) { result = int((raw + 9) / 10) * 10 }
        else           { result = int((raw + 99) / 100) * 100 }
        printf "%d", result
    }')
    mi=$(_clamp_resource "$mi" "$floor" "$cap")
    echo "${mi}Mi"
}

# calculate_usage_cpu "$max_72h_cores" "$buffer" "$floor" "$cap"
# Convert max cores from Prometheus to millicores with buffer, clamped.
# Rounded up to nearest 50m (cgroup-safe).
# Returns millicores string (e.g. "150m"). Returns empty if input is empty/zero.
calculate_usage_cpu() {
    local cores="$1" buffer="$2" floor="$3" cap="$4"
    if [ -z "$cores" ] || [ "$cores" = "0" ]; then echo ""; return; fi
    local mc=$(echo "$cores $buffer" | awk '{
        raw = int($1 * 1000 * $2 + 0.99)
        result = int((raw + 49) / 50) * 50
        printf "%d", result
    }')
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

# calculate_oom_response_memory "$current_mem_str" "$cap" ["$multiplier_num" "$multiplier_den"]
# Bump current memory by multiplier (default 2x), capped at $cap Mi, rounded to clean multiples.
# Multiplier is expressed as numerator/denominator for integer math (e.g., 3 2 = 1.5x).
# Returns Mi string.
calculate_oom_response_memory() {
    local current="$1" cap="$2"
    local mul_num="${3:-2}" mul_den="${4:-1}"
    local c=$(_memory_to_mi "$current")
    local bumped=$(( c * mul_num / mul_den ))
    # Round to clean multiples: <100 → nearest 10, >=100 → nearest 100
    if [ "$bumped" -lt 100 ]; then
        bumped=$(( (bumped + 9) / 10 * 10 ))
    else
        bumped=$(( (bumped + 99) / 100 * 100 ))
    fi
    bumped=$(_clamp_resource "$bumped" "$c" "$cap")
    echo "${bumped}Mi"
}

# calculate_wal_oom_memory "$current_mem_str" "$cap"
# Bump current memory by 1.5x (for WAL replay OOM recovery), capped at $cap Mi.
# Returns Mi string. Uses a gentler multiplier than the 2x OOM response.
calculate_wal_oom_memory() {
    local current="$1" cap="$2"
    local c=$(_memory_to_mi "$current")
    local bumped=$(( c * 3 / 2 ))
    bumped=$(_clamp_resource "$bumped" "$c" "$cap")
    echo "${bumped}Mi"
}

###############################################################################
# Usage-based sizing — ConfigMap state parsing (Phase 2)
###############################################################################

# seconds_since "$iso_timestamp"
# Returns seconds since the given ISO 8601 timestamp. Portable (GNU + BSD).
# Returns empty if timestamp is empty or invalid.
seconds_since() {
    local ts="$1"
    if [ -z "$ts" ]; then echo ""; return; fi
    local epoch_then epoch_now
    # Try GNU date (-d), then BSD date (-juf for UTC), then awk mktime
    epoch_then=$(date -d "$ts" +%s 2>/dev/null) || \
        epoch_then=$(date -juf "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null) || \
        epoch_then=$(echo "$ts" | awk -F'[-T:Z]' 'BEGIN{ENVIRON["TZ"]="UTC"}{printf "%d", mktime($1" "$2" "$3" "$4" "$5" "int($6))}' 2>/dev/null) || \
        { echo ""; return; }
    epoch_now=$(date +%s)
    echo $(( epoch_now - epoch_then ))
}

# is_oom_recent "$last_oom_timestamp" "$window_days"
# Returns 0 (true) if the OOM happened within $window_days of now.
is_oom_recent() {
    local ts="$1" window_days="$2"
    if [ -z "$ts" ]; then return 1; fi
    local secs
    secs=$(seconds_since "$ts")
    if [ -z "$secs" ]; then return 1; fi
    local window_secs=$(( window_days * 86400 ))
    [ "$secs" -le "$window_secs" ]
}

# is_full_eval_due "$last_full_eval_timestamp" "$interval_hours"
# Returns 0 (true) if $interval_hours have passed since last eval.
# Empty timestamp is NOT treated as due (first run creates ConfigMap with now).
is_full_eval_due() {
    local ts="$1" interval_hours="$2"
    if [ -z "$ts" ]; then return 1; fi
    local secs
    secs=$(seconds_since "$ts")
    if [ -z "$secs" ]; then return 1; fi
    local interval_secs=$(( interval_hours * 3600 ))
    [ "$secs" -ge "$interval_secs" ]
}

# parse_sizing_state "$configmap_json"
# Parse ConfigMap JSON into shell variables. Sets:
#   STATE_LAST_FULL_EVAL, STATE_LAST_OOM_prometheus_server,
#   STATE_LAST_OOM_kube_state_metrics, STATE_LAST_OOM_opencost,
#   STATE_LAST_OOM_pushgateway
# Returns 1 if JSON is empty/invalid.
parse_sizing_state() {
    local json="$1"
    if [ -z "$json" ] || ! echo "$json" | jq -e '.data' >/dev/null 2>&1; then
        STATE_LAST_FULL_EVAL=""
        STATE_LAST_OOM_prometheus_server=""
        STATE_LAST_OOM_kube_state_metrics=""
        STATE_LAST_OOM_opencost=""
        STATE_LAST_OOM_pushgateway=""
        return 1
    fi
    STATE_LAST_FULL_EVAL=$(echo "$json" | jq -r '.data.last_full_evaluation // empty' 2>/dev/null || true)
    STATE_LAST_OOM_prometheus_server=$(echo "$json" | jq -r '.data["prometheus-server.last_oom_at"] // empty' 2>/dev/null || true)
    STATE_LAST_OOM_kube_state_metrics=$(echo "$json" | jq -r '.data["kube-state-metrics.last_oom_at"] // empty' 2>/dev/null || true)
    STATE_LAST_OOM_opencost=$(echo "$json" | jq -r '.data["opencost.last_oom_at"] // empty' 2>/dev/null || true)
    STATE_LAST_OOM_pushgateway=$(echo "$json" | jq -r '.data["pushgateway.last_oom_at"] // empty' 2>/dev/null || true)
    return 0
}

# build_sizing_state_patch "$last_full_eval" "$prom_oom" "$ksm_oom" "$opencost_oom" "$pgw_oom"
# Generate JSON string for kubectl patch. All args are ISO timestamps or empty.
build_sizing_state_patch() {
    local eval_ts="$1" prom_oom="$2" ksm_oom="$3" opencost_oom="$4" pgw_oom="$5"
    jq -n \
        --arg eval "$eval_ts" \
        --arg prom "$prom_oom" \
        --arg ksm "$ksm_oom" \
        --arg oc "$opencost_oom" \
        --arg pgw "$pgw_oom" \
        '{data: {
            last_full_evaluation: $eval,
            "prometheus-server.last_oom_at": $prom,
            "kube-state-metrics.last_oom_at": $ksm,
            "opencost.last_oom_at": $oc,
            "pushgateway.last_oom_at": $pgw
        }}'
}

###############################################################################
# Usage-based sizing — Prometheus response parsing (Phase 3)
###############################################################################

# parse_prom_result "$response_json"
# Parse Prometheus instant query JSON response.
# Returns one line per result: "container_name value"
# Returns empty if response is error or has no results.
parse_prom_result() {
    local json="$1"
    if [ -z "$json" ]; then return 0; fi
    echo "$json" | jq -r '
        if .status == "success" and (.data.result | length) > 0 then
            .data.result[] | "\(.metric.container) \(.value[1])"
        else empty end
    ' 2>/dev/null || true
}

# parse_prom_oom_count "$response_json"
# Parse kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} response.
# Returns one line per container: "container_name count"
# count is the metric value (1 = OOM happened, 0 = no OOM).
parse_prom_oom_count() {
    local json="$1"
    if [ -z "$json" ]; then return 0; fi
    echo "$json" | jq -r '
        if .status == "success" and (.data.result | length) > 0 then
            .data.result[] | "\(.metric.container) \(.value[1])"
        else empty end
    ' 2>/dev/null || true
}

# has_sufficient_data "$data_age_hours" "$min_hours"
# Returns 0 if at least $min_hours of data is available.
has_sufficient_data() {
    local age="$1" min="$2"
    if [ -z "$age" ] || [ "$age" -lt "$min" ] 2>/dev/null; then return 1; fi
    return 0
}

###############################################################################
# Usage-based sizing — Evaluation Engine (Phase 4)
###############################################################################

# evaluate_container_sizing \
#   "$container" "$current_mem" "$current_cpu" \
#   "$max_72h_mem_bytes" "$max_72h_cpu_cores" \
#   "$has_oom_now" "$has_oom_recent" "$is_full_eval" "$is_first_run" \
#   "$mem_buffer" "$cpu_buffer" "$mem_floor" "$mem_cap" "$cpu_floor" "$cpu_cap"
#
# The master decision function for Prometheus, KSM, OpenCost.
# Prints two lines: MEM=<value> and CPU=<value>
# Logic:
#   - OOM now + not first run: bump memory (2x prom, 1.5x others), capped
#   - OOM recent (7d hold): HOLD, upsize allowed
#   - First run: HOLD (no downsize, no OOM reaction)
#   - Empty Prometheus data: HOLD, upsize allowed
#   - Full eval (72h): set to usage × buffer (can downsize, with 50% safety guard)
#   - Normal 5-min: set to usage × buffer, UPSIZE ONLY
evaluate_container_sizing() {
    local container="$1" current_mem="$2" current_cpu="$3"
    local max_mem_bytes="$4" max_cpu_cores="$5"
    local has_oom_now="$6" has_oom_recent="$7" is_full_eval="$8" is_first_run="$9"
    local mem_buffer="${10}" cpu_buffer="${11}"
    local mem_floor="${12}" mem_cap="${13}" cpu_floor="${14}" cpu_cap="${15}"

    local new_mem="$current_mem"
    local new_cpu="$current_cpu"

    # First run: hold everything. Don't react to historical OOM or usage.
    if [ "$is_first_run" = "true" ]; then
        # Exception: upsize if usage data suggests buffer is thin
        if [ -n "$max_mem_bytes" ] && [ "$max_mem_bytes" != "0" ]; then
            local proposed_mem
            proposed_mem=$(calculate_usage_memory "$max_mem_bytes" "$mem_buffer" "$mem_floor" "$mem_cap")
            if [ -n "$proposed_mem" ] && should_upsize "$proposed_mem" "$current_mem" "memory"; then
                new_mem="$proposed_mem"
            fi
        fi
        if [ -n "$max_cpu_cores" ] && [ "$max_cpu_cores" != "0" ]; then
            local proposed_cpu
            proposed_cpu=$(calculate_usage_cpu "$max_cpu_cores" "$cpu_buffer" "$cpu_floor" "$cpu_cap")
            if [ -n "$proposed_cpu" ] && should_upsize "$proposed_cpu" "$current_cpu" "cpu"; then
                new_cpu="$proposed_cpu"
            fi
        fi
        echo "MEM=$new_mem"
        echo "CPU=$new_cpu"
        return 0
    fi

    # OOM just detected: bump memory (capped). Prom gets 2x, KSM/OpenCost get 1.5x.
    if [ "$has_oom_now" = "true" ]; then
        case "$container" in
            prom*) new_mem=$(calculate_oom_response_memory "$current_mem" "$mem_cap" 2 1) ;;
            *)     new_mem=$(calculate_oom_response_memory "$current_mem" "$mem_cap" 3 2) ;;
        esac
        echo "MEM=$new_mem"
        echo "CPU=$new_cpu"
        return 0
    fi

    # OOM recent (within 7-day hold): HOLD, but allow upsize
    if [ "$has_oom_recent" = "true" ]; then
        if [ -n "$max_mem_bytes" ] && [ "$max_mem_bytes" != "0" ]; then
            local proposed_mem
            proposed_mem=$(calculate_usage_memory "$max_mem_bytes" "$mem_buffer" "$mem_floor" "$mem_cap")
            if [ -n "$proposed_mem" ] && should_upsize "$proposed_mem" "$current_mem" "memory"; then
                new_mem="$proposed_mem"
            fi
        fi
        if [ -n "$max_cpu_cores" ] && [ "$max_cpu_cores" != "0" ]; then
            local proposed_cpu
            proposed_cpu=$(calculate_usage_cpu "$max_cpu_cores" "$cpu_buffer" "$cpu_floor" "$cpu_cap")
            if [ -n "$proposed_cpu" ] && should_upsize "$proposed_cpu" "$current_cpu" "cpu"; then
                new_cpu="$proposed_cpu"
            fi
        fi
        echo "MEM=$new_mem"
        echo "CPU=$new_cpu"
        return 0
    fi

    # No Prometheus data: HOLD, upsize allowed
    if [ -z "$max_mem_bytes" ] || [ "$max_mem_bytes" = "0" ]; then
        echo "MEM=$new_mem"
        echo "CPU=$new_cpu"
        return 0
    fi

    # Calculate proposed values from usage
    local proposed_mem proposed_cpu
    proposed_mem=$(calculate_usage_memory "$max_mem_bytes" "$mem_buffer" "$mem_floor" "$mem_cap")
    proposed_cpu=$(calculate_usage_cpu "$max_cpu_cores" "$cpu_buffer" "$cpu_floor" "$cpu_cap")

    # Gross over-provisioning override: if current memory is more than 3x what
    # Prometheus data suggests (with buffer), force a downsize even on 5-min
    # checks — don't wait for the 72h full-eval cycle. This catches components
    # that were false-bumped or newly added to the evaluation engine. The 50%
    # safe-downsize guard still applies: if proposed < 50% of current, cut to
    # 50% of current (rounded to nearest 100Mi). Multiple cycles converge.
    if [ -n "$proposed_mem" ]; then
        local _gop_cur_mi _gop_prop_mi
        _gop_cur_mi=$(_memory_to_mi "$current_mem")
        _gop_prop_mi=$(_memory_to_mi "$proposed_mem")
        if [ "$_gop_cur_mi" -gt 0 ] && [ "$_gop_prop_mi" -gt 0 ] && \
           [ "$_gop_cur_mi" -gt $((_gop_prop_mi * 3)) ] 2>/dev/null; then
            if is_safe_downsize "$proposed_mem" "$current_mem"; then
                new_mem="$proposed_mem"
            else
                # Proposed is < 50% of current. Cut to 50% (rounded to 100Mi).
                local _half_mi=$(( (_gop_cur_mi / 2 + 99) / 100 * 100 ))
                new_mem="${_half_mi}Mi"
            fi
            # CPU: also allow adjustment on gross override
            if [ -n "$proposed_cpu" ]; then
                new_cpu="$proposed_cpu"
            fi
            echo "MEM=$new_mem"
            echo "CPU=$new_cpu"
            return 0
        fi
    fi

    if [ "$is_full_eval" = "true" ]; then
        # Full 72h evaluation: can go up OR down
        if [ -n "$proposed_mem" ]; then
            # Safety guard: refuse if new < 50% of current
            if is_safe_downsize "$proposed_mem" "$current_mem"; then
                new_mem="$proposed_mem"
            fi
            # else: keep current (unsafe downsize blocked)
        fi
        if [ -n "$proposed_cpu" ]; then
            new_cpu="$proposed_cpu"
        fi
    else
        # Normal 5-min check: UPSIZE ONLY
        if [ -n "$proposed_mem" ] && should_upsize "$proposed_mem" "$current_mem" "memory"; then
            new_mem="$proposed_mem"
        fi
        if [ -n "$proposed_cpu" ] && should_upsize "$proposed_cpu" "$current_cpu" "cpu"; then
            new_cpu="$proposed_cpu"
        fi
    fi

    echo "MEM=$new_mem"
    echo "CPU=$new_cpu"
    return 0
}

# evaluate_fixed_container_sizing "$container" "$current_mem" "$has_oom_now"
# For pushgateway and agent CronJob: fixed tier sizing, OOM → 1.25x bump.
# Prints: MEM=<value>
evaluate_fixed_container_sizing() {
    local container="$1" current_mem="$2" has_oom_now="$3"
    if [ "$has_oom_now" = "true" ]; then
        local new_mem
        new_mem=$(apply_memory_multiplier "$current_mem" 1.25)
        echo "MEM=$new_mem"
    else
        echo "MEM=$current_mem"
    fi
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

# count_ds_pods "$daemonsets_json"
# Count expected DaemonSet pods from status.desiredNumberScheduled.
# Accepts the full `kubectl get daemonsets -o json` output.
count_ds_pods() {
    local ds_json="$1"
    echo "$ds_json" | jq '[.items[].status.desiredNumberScheduled // 0] | add // 0' 2>/dev/null || echo "0"
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

    # CPU values are rounded to cgroup-safe values (multiples of 50m or 100m).
    # Odd values like 125m, 375m, 440m, 565m can cause "invalid argument" errors
    # on nodes with older kernels or cgroup v1 configurations.

    if [ "$total_pods" -lt 50 ]; then
        # ── Tiny ──
        PROMETHEUS_CPU_REQUEST="100m"
        PROMETHEUS_MEMORY_REQUEST="150Mi"
        PROMETHEUS_CPU_LIMIT="100m"
        PROMETHEUS_MEMORY_LIMIT="150Mi"

        OPENCOST_CPU_REQUEST="100m"
        OPENCOST_MEMORY_REQUEST="192Mi"
        OPENCOST_CPU_LIMIT="100m"
        OPENCOST_MEMORY_LIMIT="192Mi"

        ONELENS_CPU_REQUEST="100m"
        ONELENS_MEMORY_REQUEST="256Mi"
        ONELENS_CPU_LIMIT="300m"
        ONELENS_MEMORY_LIMIT="384Mi"

        KSM_CPU_REQUEST="50m"
        KSM_MEMORY_REQUEST="64Mi"
        KSM_CPU_LIMIT="50m"
        KSM_MEMORY_LIMIT="64Mi"

        PROMETHEUS_PUSHGATEWAY_CPU_REQUEST="50m"
        PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST="64Mi"
        PROMETHEUS_PUSHGATEWAY_CPU_LIMIT="50m"
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

        ONELENS_CPU_REQUEST="150m"
        ONELENS_MEMORY_REQUEST="320Mi"
        ONELENS_CPU_LIMIT="400m"
        ONELENS_MEMORY_LIMIT="480Mi"

        KSM_CPU_REQUEST="50m"
        KSM_MEMORY_REQUEST="128Mi"
        KSM_CPU_LIMIT="50m"
        KSM_MEMORY_LIMIT="128Mi"

        PROMETHEUS_PUSHGATEWAY_CPU_REQUEST="50m"
        PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST="64Mi"
        PROMETHEUS_PUSHGATEWAY_CPU_LIMIT="50m"
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

        ONELENS_CPU_REQUEST="150m"
        ONELENS_MEMORY_REQUEST="480Mi"
        ONELENS_CPU_LIMIT="400m"
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

        ONELENS_CPU_REQUEST="150m"
        ONELENS_MEMORY_REQUEST="640Mi"
        ONELENS_CPU_LIMIT="500m"
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

        ONELENS_CPU_REQUEST="150m"
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

        ONELENS_CPU_REQUEST="200m"
        ONELENS_MEMORY_REQUEST="960Mi"
        ONELENS_CPU_LIMIT="600m"
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
