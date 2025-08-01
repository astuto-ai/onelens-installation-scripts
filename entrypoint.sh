#!/bin/bash

# Check the deployment_type environment variables
if [ "$deployment_type" = "job" ]; then
  SCRIPT_NAME="install.sh"
elif [ "$deployment_type" = "cronjob" ]; then
  SCRIPT_NAME="patching.sh"
else
  echo "Error: Unrecognized deployment_type: $deployment_type"
  echo "Valid values are 'job' or 'cronjob'"
  exit 1
fi

## Define the URL of the new scripts
rm -rf "/$SCRIPT_NAME"
SCRIPT_URL="https://raw.githubusercontent.com/astuto-ai/onelens-installation-scripts/refs/heads/dev/$SCRIPT_NAME"
##
echo "$SCRIPT_URL"
# Download the new script
curl -H 'Cache-Control: no-cache' -fsSL "$SCRIPT_URL" -o "/$SCRIPT_NAME"

# Make the script executable
chmod +x "/$SCRIPT_NAME"
# Run the new script
exec "/$SCRIPT_NAME"
