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

# Check if docker buildx is installed
check_buildx() {
  if ! docker buildx version >/dev/null 2>&1; then
    echo "⚠️ 'docker buildx' not found. Installing..."
    mkdir -p ~/.docker/cli-plugins
    curl -L https://github.com/docker/buildx/releases/download/v0.12.0/buildx-v0.12.0.$(uname -s | tr '[:upper:]' '[:lower:]')-amd64 \
      -o ~/.docker/cli-plugins/docker-buildx
    chmod +x ~/.docker/cli-plugins/docker-buildx
    if ! docker buildx version >/dev/null 2>&1; then
      error_exit "'docker buildx' installation failed. Please install it manually and try again."
    fi
    echo "✅ 'docker buildx' installed successfully."
  fi
}

# Enable Docker CLI experimental features
export DOCKER_CLI_EXPERIMENTAL=enabled

# Check for docker buildx
check_buildx

# Enable Docker Buildx
echo "🔧 Enabling Docker Buildx..."
docker buildx create --use >/dev/null 2>&1 || true
docker buildx inspect --bootstrap >/dev/null 2>&1 || true

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
    AWS_ACCOUNT_ID=$(prompt_with_default "Enter your AWS Account ID" "")
    if [[ -z "$AWS_ACCOUNT_ID" ]]; then
      error_exit "AWS Account ID cannot be empty. Please provide a valid account ID."
    fi
  fi
else
  echo "⚠️ AWS CLI is not configured or credentials are invalid."
  echo "Please run 'aws configure' first to set up your AWS credentials."
  exit 1
fi

# Ask for AWS region
AWS_REGION=$(prompt_with_default "Enter your AWS Region" "$DEFAULT_AWS_REGION")
if [[ -z "$AWS_REGION" ]]; then
  error_exit "AWS Region cannot be empty. Please provide a valid region."
fi

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

# Function to authenticate Docker with Amazon ECR
ecr_login() {
  echo "🔄 Logging in to Amazon ECR..."
  retry_count=0
  while [ $retry_count -lt $MAX_RETRIES ]; do
    if aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_URL"; then
      echo "✅ Successfully logged in to Amazon ECR for pushing private images"
      return 0
    else
      retry_count=$((retry_count+1))
      if [ $retry_count -lt $MAX_RETRIES ]; then
        echo "⚠️ ECR login failed. Retrying ($retry_count/$MAX_RETRIES)..."
        sleep 5
      else
        error_exit "❌ Failed to log in to Amazon ECR after $MAX_RETRIES attempts."
      fi
    fi
  done
}

# Function to authenticate Docker with Amazon ECR
ecr_login_default() {
  echo "🔄 Logging in to Amazon ECR Public..."
  retry_count=0
  while [ $retry_count -lt $MAX_RETRIES ]; do
    if aws ecr-public get-login-password --region us-east-1 | docker login --username AWS --password-stdin public.ecr.aws; then
      echo "✅ Successfully logged in to Amazon ECR for pulling public images"
      return 0
    else
      retry_count=$((retry_count+1))
      if [ $retry_count -lt $MAX_RETRIES ]; then
        echo "⚠️ ECR login failed. Retrying ($retry_count/$MAX_RETRIES)..."
        sleep 5
      else
        error_exit "❌ Failed to log in to Amazon ECR after $MAX_RETRIES attempts."
      fi
    fi
  done
}

# Function to create ECR repository if it doesn't exist
create_ecr_repo() {
  local repo_name="$1"
  echo "🔍 Checking if ECR repository '$repo_name' exists..."
  if ! aws ecr describe-repositories --repository-names "$repo_name" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "📂 Repository '$repo_name' does not exist. Creating..."
    if aws ecr create-repository --repository-name "$repo_name" --region "$AWS_REGION" >/dev/null 2>&1; then
      echo "✅ Repository '$repo_name' created successfully."
    else
      error_exit "❌ Failed to create repository '$repo_name'. Please check your permissions."
    fi
  else
    echo "✅ Repository '$repo_name' already exists."
  fi
}

# Authenticate Docker with ECR
ecr_login_default

# Image mapping using arrays instead of associative array
# Format: "source|target"
IMAGES=(
  "public.ecr.aws/w7k6q5m9/onelens-agent:v1.7.0|onelens-agent:v1.7.0"
  "quay.io/prometheus/prometheus:v3.1.0|prometheus:v3.1.0"
  "quay.io/kubecost1/kubecost-cost-model:prod-1.108.0|kubecost-cost-model:prod-1.108.0"
  "quay.io/prometheus-operator/prometheus-config-reloader:v0.79.2|prometheus-config-reloader:v0.79.2"
  "registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.14.0|kube-state-metrics:v2.14.0"
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

  # Ensure the ECR repository exists
  create_ecr_repo "$REPO_NAME"

  echo -e "\n📦 Processing image: $SOURCE"
  echo "⬇️ Pulling image using buildx for $SOURCE..."
  retry_count=0
  while [ $retry_count -lt $MAX_RETRIES ]; do
    if docker buildx imagetools inspect "$SOURCE" >/dev/null 2>&1; then
      echo "✅ Successfully pulled: $SOURCE"
      break
    else
      echo "❌ Failed to pull image: $SOURCE. Retrying..."
      retry_count=$((retry_count+1))
      if [ $retry_count -ge $MAX_RETRIES ]; then
        error_exit "Failed to pull image after $MAX_RETRIES attempts. Skipping."
      fi
      sleep 5
    fi
  done

  echo "🔧 Pushing multi-arch image to ECR using buildx..."
  retry_count=0
  while [ $retry_count -lt $MAX_RETRIES ]; do
    # Renew ECR authentication token before each push attempt
    ecr_login

    # Use buildx imagetools to push multi-arch manifest
    if docker buildx imagetools create \
      --tag "$ECR_IMAGE" \
      "$SOURCE"; then
      echo "✅ Successfully pushed multi-arch image: $ECR_IMAGE"
      break
    else
      retry_count=$((retry_count+1))
      if [ $retry_count -lt $MAX_RETRIES ]; then
        echo "⚠️ Push failed. Retrying ($retry_count/$MAX_RETRIES)..."
        sleep 10
      else
        echo "❌ Failed to push multi-arch image after $MAX_RETRIES attempts. Skipping."
        continue 2 # Continue with the next image
      fi
    fi
  done
done

echo -e "\n🎉 All available images have been processed. Check output for details on successful operations."
echo "📊 Summary: Images processed and pushed to $ECR_URL"
