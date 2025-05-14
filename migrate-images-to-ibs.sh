#!/bin/bash
set -euo pipefail

# Helper functions
error_exit() {
  echo -e "\n❌ ERROR: $1"
  exit 1
}

check_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    error_exit "'$1' command not found. Please install $1 and try again."
  fi
}

# Function to prompt for user input with default value
prompt_with_default() {
  local prompt="$1"
  local default="$2"
  local input

  read -p "$prompt [$default]: " input
  echo "${input:-$default}"
}

# Get default values from AWS configuration
get_aws_default_region() {
  local default_region
  default_region=$(aws configure get region 2>/dev/null || echo "us-east-1")
  echo "$default_region"
}

# Check if AWS CLI is installed
check_command aws
check_command docker
command -v jq >/dev/null 2>&1 || echo "⚠️ Warning: 'jq' not found. JSON output will not be formatted."

# Get default region from AWS configuration
DEFAULT_AWS_REGION=$(get_aws_default_region)
MAX_RETRIES=3

# Ask user for AWS account ID or use default
echo "===== AWS ECR Image Setup Tool ====="
echo ""
echo "This script will pull, tag, and push container images to your ECR repositories."
echo ""

# Check if AWS CLI is configured
echo "🔍 Checking if AWS CLI is properly configured..."
if aws sts get-caller-identity > /dev/null 2>&1; then
  DETECTED_ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
  echo "✅ AWS CLI is configured. Detected account ID: $DETECTED_ACCOUNT_ID"

  # Ask if user wants to use detected account
  read -p "Would you like to use this AWS account? (Y/n): " use_detected
  # Convert to lowercase using tr for better compatibility
  use_detected=$(echo "$use_detected" | tr '[:upper:]' '[:lower:]')
  if [[ -z "$use_detected" || "$use_detected" == "y" || "$use_detected" == "yes" ]]; then
    AWS_ACCOUNT_ID="$DETECTED_ACCOUNT_ID"
  else
    AWS_ACCOUNT_ID=$(prompt_with_default "Enter your AWS Account ID" "$DETECTED_ACCOUNT_ID")
  fi
else
  echo "⚠️ AWS CLI is not configured or credentials are invalid."
  echo "Please run 'aws configure' first to set up your AWS credentials."
  exit 1
fi

# Ask for AWS region
AWS_REGION=$(prompt_with_default "Enter your AWS Region" "$DEFAULT_AWS_REGION")

# Set ECR URL
ECR_URL="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# Check prerequisites
echo "🔍 Checking prerequisites..."
check_command aws
check_command docker
command -v jq >/dev/null 2>&1 || echo "⚠️ Warning: 'jq' not found. JSON output will not be formatted."

# Validate the provided credentials
echo "🔑 Validating AWS credentials for account $AWS_ACCOUNT_ID in region $AWS_REGION..."
if ! aws sts get-caller-identity --region "$AWS_REGION" >/dev/null 2>&1; then
  error_exit "AWS credentials are not valid. Please run 'aws configure' and ensure IAM permissions are correct."
fi

USER_ARN=$(aws sts get-caller-identity --query 'Arn' --output text --region "$AWS_REGION")
echo "✅ Authenticated as: $USER_ARN"
echo "🌐 Using AWS Account: $AWS_ACCOUNT_ID in region: $AWS_REGION"

# Set ECR URL
ECR_URL="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# Authenticate Docker with ECR
echo "🔄 Logging in to Amazon ECR..."
if ! aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_URL"; then
  error_exit "Docker login to Amazon ECR failed. Check your IAM permissions and network access."
fi

# Image mapping using arrays instead of associative array
# Format: "source|target"
IMAGES=(
  "public.ecr.aws/w7k6q5m9/onelens-deployer:latest|onelens-deployer:latest"
  "public.ecr.aws/w7k6q5m9/onelens-agent:v0.1.1-beta.2|onelens-agent:v0.1.1-beta.2"
  "quay.io/prometheus/prometheus:v3.1.0|prometheus:v3.1.0"
  "quay.io/kubecost1/kubecost-cost-model:1.108.0|kubecost-cost-model:v1.108.0"
  "quay.io/prometheus-operator/prometheus-config-reloader:v0.79.2|prometheus-config-reloader:v0.79.2"
  "registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.10.1|kube-state-metrics:v2.10.1"
  "quay.io/prometheus/pushgateway:v1.11.0|pushgateway:v1.11.0"
)

# Main processing loop
echo -e "\n📋 Starting image processing (total: ${#IMAGES[@]} images)"
for IMAGE_PAIR in "${IMAGES[@]}"; do
  # Split the image pair into source and target
  SOURCE=$(echo "${IMAGE_PAIR}" | cut -d'|' -f1)
  TARGET=$(echo "${IMAGE_PAIR}" | cut -d'|' -f2)

  ECR_IMAGE="${ECR_URL}/${TARGET}"
  REPO_NAME=$(echo "${TARGET}" | cut -d':' -f1)

  echo -e "\n📦 Processing image: $SOURCE"
  echo "⬇️ Pulling image from source..."
  retry_count=0
  while [ $retry_count -lt $MAX_RETRIES ]; do
    if docker pull "$SOURCE"; then
      echo "✅ Successfully pulled: $SOURCE"
      break
    else
      retry_count=$((retry_count+1))
      if [ $retry_count -lt $MAX_RETRIES ]; then
        echo "⚠️ Pull failed. Retrying ($retry_count/$MAX_RETRIES)..."
        sleep 5
      else
        echo "❌ Failed to pull image after $MAX_RETRIES attempts. Skipping."
        continue 2 # Continue with the next image
      fi
    fi
  done

  echo "🏷️ Tagging image for ECR as: $ECR_IMAGE"
  if ! docker tag "$SOURCE" "$ECR_IMAGE"; then
    error_exit "Failed to tag image: $SOURCE. Verify Docker tag format and disk space."
  fi

  echo "🔍 Checking if ECR repository exists: $REPO_NAME"
  if ! aws ecr describe-repositories --repository-names "$REPO_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "🆕 Repository '$REPO_NAME' not found. Creating..."
    if ! aws ecr create-repository --repository-name "$REPO_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
      error_exit "Failed to create ECR repository: $REPO_NAME. Verify IAM permissions."
    fi
  fi

  echo "⬆️ Pushing image to ECR..."
  retry_count=0
  while [ $retry_count -lt $MAX_RETRIES ]; do
    # Renew ECR authentication token before each push attempt to ensure it's fresh
    aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_URL" > /dev/null 2>&1

    if docker push "$ECR_IMAGE"; then
      echo "✅ Successfully pushed: $ECR_IMAGE"
      break
    else
      retry_count=$((retry_count+1))
      if [ $retry_count -lt $MAX_RETRIES ]; then
        echo "⚠️ Push failed. Retrying ($retry_count/$MAX_RETRIES)..."
        sleep 10 # Longer sleep before retry for push operations
      else
        echo "❌ Failed to push image after $MAX_RETRIES attempts. Skipping."
        continue 2 # Continue with the next image
      fi
    fi
  done
done

echo -e "\n🎉 All available images have been processed. Check output for details on successful operations."
echo "📊 Summary: Images processed and pushed to $ECR_URL"
