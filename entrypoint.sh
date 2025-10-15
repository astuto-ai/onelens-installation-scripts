#!/bin/bash

# Global API endpoint
API_ENDPOINT="https://api-gp.onelens.cloud"

# Function to update cluster version logs
update_cluster_logs() {
    local message="$1"
    curl --location --request PUT "${API_ENDPOINT}/v1/kubernetes/cluster-version" \
        --header 'Content-Type: application/json' \
        --data '{
            "registration_id": "'"$REGISTRATION_ID"'",
            "cluster_token": "'"$CLUSTER_TOKEN"'",
            "update_data": {
                "logs": "'"$message"'"
            }
        }'
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
      
      # Execute the patching script and capture the result
        if ./"$SCRIPT_NAME"; then
          # Report successful patching
          current_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
          curl --location --request PUT "${API_ENDPOINT}/v1/kubernetes/cluster-version" \
          --header 'Content-Type: application/json' \
          --data '{
              "registration_id": "'"$REGISTRATION_ID"'",
              "cluster_token": "'"$CLUSTER_TOKEN"'",
              "update_data": {
                  "logs": "Patching success",
                  "patching_enabled": false,
                  "prev_version": "'"$current_version"'",
                  "current_version": "'"$patching_version"'",
                  "patch_status": "SUCCESS",
                  "last_patched": "'"$current_timestamp"'"
              }
          }'
          exit 0
      else
        # Report failed patching
        update_cluster_logs "Patching script execution failed"
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
