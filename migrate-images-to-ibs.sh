#!/bin/bash
set -euo pipefail
# Variables
AWS_ACCOUNT_ID="376129875853"
AWS_REGION="ap-south-1"
ECR_URL="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
MAX_RETRIES=3
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
# Check prerequisites
echo " Checking prerequisites..."
check_command aws
check_command docker
check_command jq || echo " Warning: 'jq' not found. JSON output will not be formatted."
# Check AWS credentials
echo " Validating AWS credentials..."
if ! aws sts get-caller-identity --region "$AWS_REGION" >/dev/null 2>&1; then
  error_exit "AWS credentials are not configured or are invalid. Run 'aws configure' and ensure IAM permissions are correct."
fi
USER_ARN=$(aws sts get-caller-identity --query 'Arn' --output text --region "$AWS_REGION")
echo " Authenticated as: $USER_ARN"

# Authenticate Docker with ECR
echo " Logging in to Amazon ECR..."
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
for IMAGE_PAIR in "${IMAGES[@]}"; do
  # Split the image pair into source and target
  SOURCE=$(echo "${IMAGE_PAIR}" | cut -d'|' -f1)
  TARGET=$(echo "${IMAGE_PAIR}" | cut -d'|' -f2)

  ECR_IMAGE="${ECR_URL}/${TARGET}"
  REPO_NAME=$(echo "${TARGET}" | cut -d':' -f1)

  echo -e "\n Processing image: $SOURCE"
  echo " Pulling image from source..."
  retry_count=0
  while [ $retry_count -lt $MAX_RETRIES ]; do
    if docker pull "$SOURCE"; then
      echo " Successfully pulled: $SOURCE"
      break
    else
      retry_count=$((retry_count+1))
      if [ $retry_count -lt $MAX_RETRIES ]; then
        echo " Pull failed. Retrying ($retry_count/$MAX_RETRIES)..."
        sleep 5
      else
        echo " Failed to pull image after $MAX_RETRIES attempts. Skipping."
        continue 2 # Continue with the next image
      fi
    fi
  done

  echo " Tagging image for ECR as: $ECR_IMAGE"
  if ! docker tag "$SOURCE" "$ECR_IMAGE"; then
    error_exit "Failed to tag image: $SOURCE. Verify Docker tag format and disk space."
  fi

  echo " Checking if ECR repository exists: $REPO_NAME"
  if ! aws ecr describe-repositories --repository-names "$REPO_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo " Repository '$REPO_NAME' not found. Creating..."
    if ! aws ecr create-repository --repository-name "$REPO_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
      error_exit "Failed to create ECR repository: $REPO_NAME. Verify IAM permissions."
    fi
  fi

  echo " Pushing image to ECR..."
  retry_count=0
  while [ $retry_count -lt $MAX_RETRIES ]; do
    # Renew ECR authentication token before each push attempt to ensure it's fresh
    aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_URL" > /dev/null 2>&1

    if docker push "$ECR_IMAGE"; then
      echo " Successfully pushed: $ECR_IMAGE"
      break
    else
      retry_count=$((retry_count+1))
      if [ $retry_count -lt $MAX_RETRIES ]; then
        echo " Push failed. Retrying ($retry_count/$MAX_RETRIES)..."
        sleep 10 # Longer sleep before retry for push operations
      else
        echo " Failed to push image after $MAX_RETRIES attempts. Skipping."
        continue 2 # Continue with the next image
      fi
    fi
  done
done

echo -e "\n All available images have been processed. Check output for details on successful operations."
