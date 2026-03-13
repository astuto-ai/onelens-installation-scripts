#!/bin/bash

# Global API endpoint
API_ENDPOINT="https://api-in.onelens.cloud"

# Function to update cluster version logs
update_cluster_logs() {
    local message="$1"
    # Truncate to 10000 chars to stay within DB column limits
    if [ ${#message} -gt 10000 ]; then
        message="[truncated]...${message: -9900}"
    fi
    # Use jq to safely escape the message for JSON (handles newlines, quotes, etc.)
    local payload
    payload=$(jq -n \
        --arg reg_id "$REGISTRATION_ID" \
        --arg token "$CLUSTER_TOKEN" \
        --arg logs "$message" \
        '{registration_id: $reg_id, cluster_token: $token, update_data: {logs: $logs}}')
    curl -s --location --request PUT "${API_ENDPOINT}/v1/kubernetes/cluster-version" \
        --header 'Content-Type: application/json' \
        --data "$payload" >/dev/null
}

echo "deployment_type: $deployment_type"

# Check the deployment_type environment variables
if [ "$deployment_type" = "job" ]; then
  SCRIPT_NAME="install.sh"
  # For job deployment, use the script available in the image
  if [ -f "./$SCRIPT_NAME" ]; then
    echo "Using local $SCRIPT_NAME from image"
    chmod +x "./$SCRIPT_NAME"
    if  "./$SCRIPT_NAME"; then
      echo "Script executed successfully"
      exit 0
    else
      echo "Script execution failed"
      exit 1
    fi

  else
    echo "Error: Local $SCRIPT_NAME not found in image"
    exit 1
  fi
elif [ "$deployment_type" = "cronjob" ]; then
  SCRIPT_NAME="patching.sh"

  # Check cluster version and patching status from API
  API_RESPONSE=$(curl -s --location --request POST "${API_ENDPOINT}/v1/kubernetes/cluster-version" \
    --header 'Content-Type: application/json' \
    --data '{
      "registration_id": "'"$REGISTRATION_ID"'",
      "cluster_token": "'"$CLUSTER_TOKEN"'"
    }')

  if [ $? -ne 0 ] || [ -z "$API_RESPONSE" ]; then
    echo "Error: Failed to reach cluster-version API"
    update_cluster_logs "Failed to fetch cluster version from API"
    exit 1
  fi

  patching_enabled=$(echo "$API_RESPONSE" | jq -r '.data.patching_enabled')
  current_version=$(echo "$API_RESPONSE" | jq -r '.data.current_version')
  patching_version=$(echo "$API_RESPONSE" | jq -r '.data.patching_version')
  patching_mode=$(echo "$API_RESPONSE" | jq -r '.data.patching_mode // empty')
  healthcheck_failures=$(echo "$API_RESPONSE" | jq -r '.data.healthcheck_failures // "0"')

  echo "Cluster version: $current_version, patching version: $patching_version, enabled: $patching_enabled, mode: ${patching_mode:-oneshot}"

  # ─── Mode routing ───────────────────────────────────────────────────
  # STRICT: only literal "healthcheck" activates new mode.
  # Any other value (null, empty, "oneshot", garbage) → current oneshot behavior.
  # This ensures safe backward compatibility before backend deploys the column.

  if [ "$patching_mode" = "healthcheck" ]; then
    # ═══════════════════════════════════════════════════════════════════
    # HEALTHCHECK MODE — lightweight local check, remediate only if needed
    # ═══════════════════════════════════════════════════════════════════
    echo "Running healthcheck..."

    # Wait briefly for K8s API and DNS to be ready (pod just started)
    sleep 5

    UNHEALTHY_REASONS=""

    # Check 1: All pods Running and Ready
    NOT_READY=$(kubectl get pods -n onelens-agent --no-headers 2>/dev/null \
        | grep -v 'Completed' \
        | awk '{split($2,a,"/"); if (a[1] != a[2] || $3 != "Running") print $1 " (" $3 ")"}' || true)
    if [ -n "$NOT_READY" ]; then
        UNHEALTHY_REASONS="${UNHEALTHY_REASONS}Pods not ready: ${NOT_READY}\n"
    fi

    # Check 2: Prometheus healthy
    PROM_SVC=$(kubectl get svc -n onelens-agent --no-headers 2>/dev/null \
        | awk '/prometheus-server/{print $1; exit}' || true)
    if [ -n "$PROM_SVC" ]; then
        PROM_HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://${PROM_SVC}.onelens-agent.svc.cluster.local:80/-/healthy" 2>/dev/null || echo "000")
        if [ "$PROM_HTTP_CODE" != "200" ]; then
            UNHEALTHY_REASONS="${UNHEALTHY_REASONS}Prometheus unhealthy (HTTP ${PROM_HTTP_CODE})\n"
        fi
    else
        UNHEALTHY_REASONS="${UNHEALTHY_REASONS}Prometheus service not found\n"
    fi

    # Check 3: OpenCost healthy (older versions return "ok" body, newer return empty body with HTTP 200)
    OPENCOST_HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://onelens-agent-prometheus-opencost-exporter.onelens-agent.svc.cluster.local:9003/healthz" 2>/dev/null || echo "000")
    if [ "$OPENCOST_HTTP_CODE" != "200" ]; then
        UNHEALTHY_REASONS="${UNHEALTHY_REASONS}OpenCost unhealthy (HTTP ${OPENCOST_HTTP_CODE})\n"
    fi

    # Check 4: Pushgateway healthy (returns "OK" body, not "healthy")
    PGW_HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://onelens-agent-prometheus-pushgateway.onelens-agent.svc.cluster.local:9091/-/healthy" 2>/dev/null || echo "000")
    if [ "$PGW_HTTP_CODE" != "200" ]; then
        UNHEALTHY_REASONS="${UNHEALTHY_REASONS}Pushgateway unhealthy (HTTP ${PGW_HTTP_CODE})\n"
    fi

    # Check 5: Version match
    if [ -n "$patching_version" ] && [ "$patching_version" != "null" ]; then
        if [ "$current_version" != "$patching_version" ]; then
            UNHEALTHY_REASONS="${UNHEALTHY_REASONS}Version mismatch: current=$current_version target=$patching_version\n"
        fi
    fi

    # ─── Routing: healthy vs unhealthy ────────────────────────────────
    if [ -z "$UNHEALTHY_REASONS" ]; then
        # ALL HEALTHY — decide whether to send heartbeat or exit silently
        echo "All healthchecks passed"

        # PUT heartbeat every run — we're already POSTing every 5 min anyway,
        # so the extra write is negligible. Keeps last_healthy_at fresh for
        # stale-cluster detection (if last_healthy_at > 10 min old → cluster is dead).
        current_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        payload=$(jq -n \
            --arg reg_id "$REGISTRATION_ID" \
            --arg token "$CLUSTER_TOKEN" \
            --arg ts "$current_timestamp" \
            '{registration_id: $reg_id, cluster_token: $token, update_data: {logs: "healthy", last_healthy_at: $ts, healthcheck_failures: 0}}')
        curl -s --max-time 10 --location --request PUT "${API_ENDPOINT}/v1/kubernetes/cluster-version" \
            --header 'Content-Type: application/json' \
            --data "$payload" >/dev/null 2>&1 || true

        exit 0
    fi

    # UNHEALTHY — log reasons and proceed to fetch patching.sh for remediation
    echo "Healthcheck FAILED:"
    printf "  %b" "$UNHEALTHY_REASONS"
    echo "Triggering remediation..."

    # Fetch the patching script from API
    echo "Fetching patching script..."
    API_RESPONSE_SCRIPT=$(curl -s --location --request POST "${API_ENDPOINT}/v1/kubernetes/patching-script" \
      --header 'Content-Type: application/json' \
      --data '{
        "registration_id": "'"$REGISTRATION_ID"'",
        "cluster_token": "'"$CLUSTER_TOKEN"'"
      }')

    echo "$API_RESPONSE_SCRIPT" | jq -e -r '.data.script_content' > "./$SCRIPT_NAME" 2>/dev/null

    if [ $? -ne 0 ] || [ ! -s "./$SCRIPT_NAME" ]; then
      echo "Error: Failed to extract patching script from API response"
      update_cluster_logs "Healthcheck failed but could not fetch patching script"
      exit 1
    fi

    echo "Patching script downloaded, executing for remediation..."
    chmod +x "./$SCRIPT_NAME"

    # Execute the patching script and capture output
    PATCH_LOG_FILE=$(mktemp)
    ./"$SCRIPT_NAME" 2>&1 | tee "$PATCH_LOG_FILE"
    PATCH_EXIT=${PIPESTATUS[0]}
    PATCH_OUTPUT=$(cat "$PATCH_LOG_FILE")
    rm -f "$PATCH_LOG_FILE"

    # Truncate detailed logs to 10000 chars if needed
    if [ ${#PATCH_OUTPUT} -gt 10000 ]; then
        PATCH_OUTPUT="[truncated]...${PATCH_OUTPUT: -9900}"
    fi

    PATCH_SUMMARY=$(echo "$PATCH_OUTPUT" | grep '^Patching complete\.' | tail -1)
    UNHEALTHY_SUMMARY=$(printf "%b" "$UNHEALTHY_REASONS" | tr '\n' '; ')

    if [ "$PATCH_EXIT" -eq 0 ]; then
        current_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        SUMMARY_LOG="REMEDIATED: ${UNHEALTHY_SUMMARY} ${PATCH_SUMMARY:-Patching completed successfully}"
        # CRITICAL: healthcheck mode NEVER sets patching_enabled=false
        payload=$(jq -n \
            --arg reg_id "$REGISTRATION_ID" \
            --arg token "$CLUSTER_TOKEN" \
            --arg logs "$SUMMARY_LOG" \
            --arg patching_logs "$PATCH_OUTPUT" \
            --arg prev "$current_version" \
            --arg curr "$patching_version" \
            --arg ts "$current_timestamp" \
            '{registration_id: $reg_id, cluster_token: $token, update_data: {logs: $logs, patching_logs: $patching_logs, prev_version: $prev, current_version: $curr, patch_status: "SUCCESS", last_patched: $ts, last_healthy_at: $ts, healthcheck_failures: 0}}')
        curl -s --location --request PUT "${API_ENDPOINT}/v1/kubernetes/cluster-version" \
            --header 'Content-Type: application/json' \
            --data "$payload" >/dev/null
        exit 0
    else
        FAIL_LOG="REMEDIATION FAILED (exit $PATCH_EXIT): ${UNHEALTHY_SUMMARY} ${PATCH_SUMMARY:-Patching failed}"
        # Increment healthcheck_failures for consecutive failure tracking
        NEW_FAILURES=$(( ${healthcheck_failures:-0} + 1 ))
        payload=$(jq -n \
            --arg reg_id "$REGISTRATION_ID" \
            --arg token "$CLUSTER_TOKEN" \
            --arg logs "$FAIL_LOG" \
            --arg patching_logs "$PATCH_OUTPUT" \
            --argjson hcf "$NEW_FAILURES" \
            '{registration_id: $reg_id, cluster_token: $token, update_data: {logs: $logs, patching_logs: $patching_logs, healthcheck_failures: $hcf}}')
        curl -s --location --request PUT "${API_ENDPOINT}/v1/kubernetes/cluster-version" \
            --header 'Content-Type: application/json' \
            --data "$payload" >/dev/null
        exit 1
    fi

  else
    # ═══════════════════════════════════════════════════════════════════
    # ONESHOT MODE — current behavior, 100% backwards compatible
    # ═══════════════════════════════════════════════════════════════════

    if [ "$patching_enabled" != "true" ]; then
      echo "Patching is disabled for this cluster"
      update_cluster_logs "Patching is disabled for this cluster"
      exit 0
    fi

    # Fetch the patching script from API
    echo "Fetching patching script..."
    API_RESPONSE_SCRIPT=$(curl -s --location --request POST "${API_ENDPOINT}/v1/kubernetes/patching-script" \
      --header 'Content-Type: application/json' \
      --data '{
        "registration_id": "'"$REGISTRATION_ID"'",
        "cluster_token": "'"$CLUSTER_TOKEN"'"
      }')

    echo "$API_RESPONSE_SCRIPT" | jq -e -r '.data.script_content' > "./$SCRIPT_NAME" 2>/dev/null

    if [ $? -ne 0 ] || [ ! -s "./$SCRIPT_NAME" ]; then
      echo "Error: Failed to extract patching script from API response"
      update_cluster_logs "Failed to extract patching script content from API response"
      exit 1
    fi

    echo "Patching script downloaded, executing..."
    chmod +x "./$SCRIPT_NAME"

    # Execute the patching script and capture full output for diagnostics
    PATCH_LOG_FILE=$(mktemp)
    ./"$SCRIPT_NAME" 2>&1 | tee "$PATCH_LOG_FILE"
    PATCH_EXIT=${PIPESTATUS[0]}
    PATCH_OUTPUT=$(cat "$PATCH_LOG_FILE")
    rm -f "$PATCH_LOG_FILE"

    # Truncate detailed logs to 10000 chars if needed
    if [ ${#PATCH_OUTPUT} -gt 10000 ]; then
        PATCH_OUTPUT="[truncated]...${PATCH_OUTPUT: -9900}"
    fi

    # Extract the summary line from patching output (last "Patching complete." line)
    PATCH_SUMMARY=$(echo "$PATCH_OUTPUT" | grep '^Patching complete\.' | tail -1)

    if [ "$PATCH_EXIT" -eq 0 ]; then
        # logs: high-level summary for quick view
        # patching_logs: full detailed output for debugging
        current_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        SUMMARY_LOG="SUCCESS: ${PATCH_SUMMARY:-Patching completed successfully}"
        payload=$(jq -n \
            --arg reg_id "$REGISTRATION_ID" \
            --arg token "$CLUSTER_TOKEN" \
            --arg logs "$SUMMARY_LOG" \
            --arg patching_logs "$PATCH_OUTPUT" \
            --arg prev "$current_version" \
            --arg curr "$patching_version" \
            --arg ts "$current_timestamp" \
            '{registration_id: $reg_id, cluster_token: $token, update_data: {logs: $logs, patching_logs: $patching_logs, patching_enabled: false, prev_version: $prev, current_version: $curr, patch_status: "SUCCESS", last_patched: $ts}}')
        curl -s --location --request PUT "${API_ENDPOINT}/v1/kubernetes/cluster-version" \
            --header 'Content-Type: application/json' \
            --data "$payload" >/dev/null
        exit 0
    else
        # logs: high-level failure message
        # patching_logs: full output for remote debugging
        FAIL_LOG="FAILED (exit $PATCH_EXIT): ${PATCH_SUMMARY:-Patching failed}"
        payload=$(jq -n \
            --arg reg_id "$REGISTRATION_ID" \
            --arg token "$CLUSTER_TOKEN" \
            --arg logs "$FAIL_LOG" \
            --arg patching_logs "$PATCH_OUTPUT" \
            '{registration_id: $reg_id, cluster_token: $token, update_data: {logs: $logs, patching_logs: $patching_logs}}')
        curl -s --location --request PUT "${API_ENDPOINT}/v1/kubernetes/cluster-version" \
            --header 'Content-Type: application/json' \
            --data "$payload" >/dev/null
        exit 1
    fi
  fi
else
  echo "Error: Unrecognized deployment_type: $deployment_type"
  echo "Valid values are 'job' or 'cronjob'"
  exit 1
fi
