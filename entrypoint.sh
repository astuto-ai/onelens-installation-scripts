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
    curl --location --request PUT "${API_ENDPOINT}/v1/kubernetes/cluster-version" \
        --header 'Content-Type: application/json' \
        --data "$payload"
}

echo "REGISTRATION_ID: $REGISTRATION_ID"
echo "CLUSTER_TOKEN: $CLUSTER_TOKEN"
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

  ## check if patching is enabled 

  # For cronjob deployment, call the API to get the patching script
  echo "Fetching $SCRIPT_NAME from OneLens API..."
  
  # Call the API to get the patching script
  API_RESPONSE=$(curl --location --request POST "${API_ENDPOINT}/v1/kubernetes/cluster-version" \
    --header 'Content-Type: application/json' \
    --data '{
      "registration_id": "'"$REGISTRATION_ID"'",
      "cluster_token": "'"$CLUSTER_TOKEN"'"
    }')

  echo "API_RESPONSE: $API_RESPONSE"

  if [ $? -eq 0 ]; then
    # first check {"data":{"patching_enabled":true
    patching_enabled=$(echo "$API_RESPONSE" | jq -r '.data.patching_enabled')
    current_version=$(echo "$API_RESPONSE" | jq -r '.data.current_version')
    patching_version=$(echo "$API_RESPONSE" | jq -r '.data.patching_version')

    echo "current_version: $current_version"
    echo "patching_version: $patching_version"

    echo "Patching enabled: $patching_enabled"
    if [ "$patching_enabled" == "true" ]; then
      echo "Patching is enabled"
    else
      echo "Patching is disabled"
      # Report patching disabled status
      update_cluster_logs "Patching is disabled for this cluster"
      exit 0
    fi

    API_RESPONSE_SCRIPT=$(curl --location --request POST "${API_ENDPOINT}/v1/kubernetes/patching-script" \
    --header 'Content-Type: application/json' \
    --data '{
      "registration_id": "'"$REGISTRATION_ID"'",
      "cluster_token": "'"$CLUSTER_TOKEN"'"
    }')

    echo "API_RESPONSE_SCRIPT: $API_RESPONSE_SCRIPT"
    # Extract script content from API response and save to file
    echo "$API_RESPONSE_SCRIPT" | jq -e -r '.data.script_content' > "./$SCRIPT_NAME"
    
    if [ $? -eq 0 ]; then
      echo "Successfully downloaded $SCRIPT_NAME from API"
      chmod +x "./$SCRIPT_NAME"
      
      # Execute the patching script and capture full output for diagnostics
      PATCH_LOG_FILE=$(mktemp)
      ./"$SCRIPT_NAME" 2>&1 | tee "$PATCH_LOG_FILE"
      PATCH_EXIT=${PIPESTATUS[0]}
      PATCH_OUTPUT=$(cat "$PATCH_LOG_FILE")
      rm -f "$PATCH_LOG_FILE"

      # Truncate log to 4000 chars if needed
      if [ ${#PATCH_OUTPUT} -gt 4000 ]; then
          PATCH_OUTPUT="[truncated]...${PATCH_OUTPUT: -3900}"
      fi

      if [ "$PATCH_EXIT" -eq 0 ]; then
          # Report successful patching with full log
          current_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
          payload=$(jq -n \
              --arg reg_id "$REGISTRATION_ID" \
              --arg token "$CLUSTER_TOKEN" \
              --arg logs "$PATCH_OUTPUT" \
              --arg prev "$current_version" \
              --arg curr "$patching_version" \
              --arg ts "$current_timestamp" \
              '{registration_id: $reg_id, cluster_token: $token, update_data: {logs: $logs, patching_enabled: false, prev_version: $prev, current_version: $curr, patch_status: "SUCCESS", last_patched: $ts}}')
          curl --location --request PUT "${API_ENDPOINT}/v1/kubernetes/cluster-version" \
              --header 'Content-Type: application/json' \
              --data "$payload"
          exit 0
      else
          # Report failed patching with full log for remote debugging
          update_cluster_logs "Patching failed (exit code $PATCH_EXIT). Output: $PATCH_OUTPUT"
          exit 1
      fi
    else
      echo "Error: Failed to extract script content from API response"
      # Report script extraction failure
      update_cluster_logs "Failed to extract patching script content from API response"
      exit 1
    fi
  else
    echo "Error: Failed to fetch $SCRIPT_NAME from API"
    # Report API fetch failure
    update_cluster_logs "Failed to fetch patching script from API"
    exit 1
  fi
else
  echo "Error: Unrecognized deployment_type: $deployment_type"
  echo "Valid values are 'job' or 'cronjob'"
  exit 1
fi
