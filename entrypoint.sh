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

  # If secret doesn't exist (install not completed), exit gracefully
  if [ -z "${REGISTRATION_ID:-}" ] || [ -z "${CLUSTER_TOKEN:-}" ]; then
      echo "Credentials not available — install has not completed yet."
      echo "The deployer job must finish successfully before the updater can run."
      exit 0
  fi

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

  # Detect deployer chart version from CronJob image tag (helm not available in this image)
  DEPLOYER_VERSION=$(kubectl get cronjob onelensupdater -n onelens-agent \
      -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[?(@.name=="onelensupdater")].image}' \
      2>/dev/null | sed 's/.*://' | sed 's/^v//')
  DEPLOYER_VERSION="${DEPLOYER_VERSION:-unknown}"

  echo "Cluster version: $current_version, patching version: $patching_version, enabled: $patching_enabled, mode: ${patching_mode:-oneshot}, deployer: $DEPLOYER_VERSION"

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
    # Filter out terminal job/cronjob pods (Completed, Error) and DCGM exporter pods.
    # DCGM is a monitoring sidecar — its failures (PSA, image pull) should not
    # trigger full patching.sh remediation for core components.
    NOT_READY=$(kubectl get pods -n onelens-agent --no-headers 2>/dev/null \
        | grep -vE 'Completed|Error|Terminating|nvidia-dcgm-exporter' \
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

    # Check 5: Version match (normalize: strip leading v and release/ prefix)
    if [ -n "$patching_version" ] && [ "$patching_version" != "null" ]; then
        _norm_current=$(echo "$current_version" | sed 's|^release/||' | sed 's|^v||')
        _norm_patching=$(echo "$patching_version" | sed 's|^release/||' | sed 's|^v||')
        if [ "$_norm_current" != "$_norm_patching" ]; then
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
            --arg dv "$DEPLOYER_VERSION" \
            '{registration_id: $reg_id, cluster_token: $token, update_data: {logs: "healthy", last_healthy_at: $ts, healthcheck_failures: 0, deployer_version: $dv}}')
        curl -s --max-time 10 --location --request PUT "${API_ENDPOINT}/v1/kubernetes/cluster-version" \
            --header 'Content-Type: application/json' \
            --data "$payload" >/dev/null 2>&1 || true

        # --- GPU: DCGM exporter lifecycle (runs every healthcheck cycle) ---
        # Ensures DCGM DaemonSet exists when GPU nodes are present. Once deployed,
        # the DaemonSet controller handles spot/scale churn automatically.
        # Non-fatal — failures don't affect healthcheck result.
        _gpu_caps=$(kubectl get nodes --chunk-size=100 -o custom-columns='GPU:.status.capacity.nvidia\.com/gpu' --no-headers 2>/dev/null || true)
        _gpu_node_count=0
        if [ -n "$_gpu_caps" ]; then
            _gpu_node_count=$(echo "$_gpu_caps" | awk '$1 != "<none>" && $1+0 > 0 {c++} END {print c+0}')
        fi
        if [ "$_gpu_node_count" -gt 0 ]; then
            # Discover GPU node label for DaemonSet scheduling
            _gpu_label_key=""
            _gpu_node_name=$(kubectl get nodes --chunk-size=100 -o custom-columns='NAME:.metadata.name,GPU:.status.capacity.nvidia\.com/gpu' --no-headers 2>/dev/null | awk '$2 != "<none>" && $2+0 > 0 {print $1; exit}' || true)
            if [ -n "$_gpu_node_name" ]; then
                _gpu_node_json=$(kubectl get node "$_gpu_node_name" -o json 2>/dev/null || true)
                # Search for any label starting with nvidia.com/gpu (covers all NVIDIA conventions)
                _gpu_label_key=$(echo "$_gpu_node_json" | jq -r '.metadata.labels | keys[] | select(startswith("nvidia.com/gpu"))' 2>/dev/null | head -1 || true)
                # Fallback: cloud-specific labels
                if [ -z "$_gpu_label_key" ]; then
                    for _label in "feature.node.kubernetes.io/pci-10de.present" "cloud.google.com/gke-accelerator"; do
                        _val=$(echo "$_gpu_node_json" | jq -r --arg l "$_label" '.metadata.labels[$l] // empty' 2>/dev/null || true)
                        if [ -n "$_val" ]; then
                            _gpu_label_key="$_label"
                            break
                        fi
                    done
                fi
            fi

            # Check for customer-managed DCGM (standalone + GPU Operator labels)
            _dcgm_by_app=$(kubectl get pods --all-namespaces -l app=nvidia-dcgm-exporter --no-headers 2>/dev/null | grep -v "^onelens-agent " | wc -l | tr -d '[:space:]')
            _dcgm_by_operator=$(kubectl get pods --all-namespaces -l app.kubernetes.io/component=dcgm-exporter --no-headers 2>/dev/null | grep -v "^onelens-agent " | wc -l | tr -d '[:space:]')
            _dcgm_other=$(( _dcgm_by_app > _dcgm_by_operator ? _dcgm_by_app : _dcgm_by_operator ))
            if [ "$_dcgm_other" -eq 0 ] && [ -n "$_gpu_label_key" ]; then
                # No customer DCGM + known label found — ensure ours exists
                if ! kubectl get ds nvidia-dcgm-exporter -n onelens-agent --no-headers 2>/dev/null | grep -q .; then
                    _registry_url=$(kubectl get cm onelens-agent-env -n onelens-agent -o jsonpath='{.data.REGISTRY_URL}' 2>/dev/null || true)
                    _dcgm_image="nvcr.io/nvidia/k8s/dcgm-exporter:3.3.9-3.6.1-ubuntu22.04"
                    if [ -n "$_registry_url" ]; then
                        _dcgm_image="$_registry_url/dcgm-exporter:3.3.9-3.6.1-ubuntu22.04"
                    fi
                    echo "GPU: deploying DCGM exporter ($_gpu_node_count GPU nodes, label: $_gpu_label_key)"
                    kubectl apply -n onelens-agent -f - <<DCGM_EOF 2>&1 || echo "  WARNING: DCGM deploy failed (non-fatal)"
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nvidia-dcgm-exporter
  namespace: onelens-agent
  labels:
    app: nvidia-dcgm-exporter
    managed-by: onelens
spec:
  selector:
    matchLabels:
      app: nvidia-dcgm-exporter
  template:
    metadata:
      labels:
        app: nvidia-dcgm-exporter
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: $_gpu_label_key
                    operator: Exists
      tolerations:
        - operator: Exists
      containers:
        - name: dcgm-exporter
          image: $_dcgm_image
          args: ["-f", "/etc/dcgm-exporter/dcp-metrics-included.csv"]
          ports:
            - name: metrics
              containerPort: 9400
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 200m
              memory: 2Gi
          securityContext:
            capabilities:
              add: ["SYS_ADMIN"]
          env:
            - name: DCGM_EXPORTER_KUBERNETES
              value: "true"
            - name: DCGM_EXPORTER_LISTEN
              value: ":9400"
          volumeMounts:
            - name: pod-resources
              mountPath: /var/lib/kubelet/pod-resources
              readOnly: true
      volumes:
        - name: pod-resources
          hostPath:
            path: /var/lib/kubelet/pod-resources
---
apiVersion: v1
kind: Service
metadata:
  name: nvidia-dcgm-exporter
  namespace: onelens-agent
  labels:
    app: nvidia-dcgm-exporter
    managed-by: onelens
spec:
  selector:
    app: nvidia-dcgm-exporter
  ports:
    - name: gpu-metrics
      port: 9400
      targetPort: 9400
DCGM_EOF
                fi
            fi
        else
            # No GPU nodes — clean up our DCGM if it exists
            if kubectl get ds nvidia-dcgm-exporter -n onelens-agent -l managed-by=onelens --no-headers 2>/dev/null | grep -q .; then
                echo "GPU: cleaning up DCGM exporter (no GPU nodes)"
                kubectl delete ds nvidia-dcgm-exporter -n onelens-agent 2>/dev/null || true
                kubectl delete svc nvidia-dcgm-exporter -n onelens-agent 2>/dev/null || true
            fi
        fi

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
      echo "Could not fetch patching script for version $patching_version"
      # Determine if the cluster is operationally healthy (only version mismatch)
      # or genuinely unhealthy (pods down, services failing)
      _non_version_reasons=$(printf "%b" "$UNHEALTHY_REASONS" | grep -v "Version mismatch" || true)
      if [ -z "$_non_version_reasons" ]; then
          # Only version mismatch — pods and services are healthy
          echo "  Cluster is operationally healthy on $current_version. Version upgrade will retry on next run."
          current_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
          payload=$(jq -n \
              --arg reg_id "$REGISTRATION_ID" \
              --arg token "$CLUSTER_TOKEN" \
              --arg ts "$current_timestamp" \
              --arg dv "$DEPLOYER_VERSION" \
              --arg logs "Script fetch failed for $patching_version (cluster healthy on $current_version)" \
              '{registration_id: $reg_id, cluster_token: $token, update_data: {logs: $logs, last_healthy_at: $ts, deployer_version: $dv}}')
          curl -s --max-time 10 --location --request PUT "${API_ENDPOINT}/v1/kubernetes/cluster-version" \
              --header 'Content-Type: application/json' \
              --data "$payload" >/dev/null 2>&1 || true
          exit 0
      else
          # Cluster has real health issues AND script fetch failed — cannot remediate
          echo "  Cluster has health issues that cannot be remediated (script fetch failed):"
          printf "  %b" "$UNHEALTHY_REASONS"
          UNHEALTHY_SUMMARY=$(printf "%b" "$UNHEALTHY_REASONS" | tr '\n' '; ')
          NEW_FAILURES=$(( ${healthcheck_failures:-0} + 1 ))
          FAIL_MSG="Script fetch failed for $patching_version AND cluster unhealthy: ${UNHEALTHY_SUMMARY}"
          payload=$(jq -n \
              --arg reg_id "$REGISTRATION_ID" \
              --arg token "$CLUSTER_TOKEN" \
              --arg logs "$FAIL_MSG" \
              --argjson hcf "$NEW_FAILURES" \
              '{registration_id: $reg_id, cluster_token: $token, update_data: {logs: $logs, healthcheck_failures: $hcf}}')
          curl -s --max-time 10 --location --request PUT "${API_ENDPOINT}/v1/kubernetes/cluster-version" \
              --header 'Content-Type: application/json' \
              --data "$payload" >/dev/null 2>&1 || true
          exit 1
      fi
    fi

    echo "Patching script downloaded, executing for remediation..."
    chmod +x "./$SCRIPT_NAME"

    # Export patching_version so patching.sh can pin chart version (not latest)
    export PATCHING_VERSION="$patching_version"

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
        # Only update prev_version/current_version when there's an actual version change.
        # If current == patching, this is a re-remediation (pod crash, OOM, etc.) —
        # overwriting prev_version would lose the original pre-upgrade version.
        if [ "$current_version" != "$patching_version" ]; then
            payload=$(jq -n \
                --arg reg_id "$REGISTRATION_ID" \
                --arg token "$CLUSTER_TOKEN" \
                --arg logs "$SUMMARY_LOG" \
                --arg patching_logs "$PATCH_OUTPUT" \
                --arg prev "$current_version" \
                --arg curr "$patching_version" \
                --arg ts "$current_timestamp" \
                '{registration_id: $reg_id, cluster_token: $token, update_data: {logs: $logs, patching_logs: $patching_logs, prev_version: $prev, current_version: $curr, patch_status: "SUCCESS", last_patched: $ts, last_healthy_at: $ts, healthcheck_failures: 0}}')
        else
            payload=$(jq -n \
                --arg reg_id "$REGISTRATION_ID" \
                --arg token "$CLUSTER_TOKEN" \
                --arg logs "$SUMMARY_LOG" \
                --arg patching_logs "$PATCH_OUTPUT" \
                --arg ts "$current_timestamp" \
                '{registration_id: $reg_id, cluster_token: $token, update_data: {logs: $logs, patching_logs: $patching_logs, patch_status: "SUCCESS", last_patched: $ts, last_healthy_at: $ts, healthcheck_failures: 0}}')
        fi
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
      echo "Error: Failed to fetch patching script for version $patching_version"
      update_cluster_logs "Script fetch failed for $patching_version"
      exit 1
    fi

    echo "Patching script downloaded, executing..."
    chmod +x "./$SCRIPT_NAME"

    # Export patching_version so patching.sh can pin chart version (not latest)
    export PATCHING_VERSION="$patching_version"

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
        # Only update prev_version/current_version when there's an actual version change
        if [ "$current_version" != "$patching_version" ]; then
            payload=$(jq -n \
                --arg reg_id "$REGISTRATION_ID" \
                --arg token "$CLUSTER_TOKEN" \
                --arg logs "$SUMMARY_LOG" \
                --arg patching_logs "$PATCH_OUTPUT" \
                --arg prev "$current_version" \
                --arg curr "$patching_version" \
                --arg ts "$current_timestamp" \
                '{registration_id: $reg_id, cluster_token: $token, update_data: {logs: $logs, patching_logs: $patching_logs, patching_enabled: false, prev_version: $prev, current_version: $curr, patch_status: "SUCCESS", last_patched: $ts}}')
        else
            payload=$(jq -n \
                --arg reg_id "$REGISTRATION_ID" \
                --arg token "$CLUSTER_TOKEN" \
                --arg logs "$SUMMARY_LOG" \
                --arg patching_logs "$PATCH_OUTPUT" \
                --arg ts "$current_timestamp" \
                '{registration_id: $reg_id, cluster_token: $token, update_data: {logs: $logs, patching_logs: $patching_logs, patching_enabled: false, patch_status: "SUCCESS", last_patched: $ts}}')
        fi
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
