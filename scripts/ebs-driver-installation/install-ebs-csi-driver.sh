#!/bin/bash

# ==============================================================================
# EBS CSI Driver IAM Role Installation Script
# ==============================================================================
#
# This script automatically creates an IAM role for Amazon EBS CSI Driver
# with OIDC trust relationship for your EKS cluster.
#
# USAGE:
#   # Run directly from internet:
#   curl -sSL https://raw.githubusercontent.com/astuto-ai/onelens-installation-scripts/release/v1.2.0-ebs-driver-installer/scripts/ebs-driver-installation/install-ebs-csi-driver.sh | bash -s -- CLUSTER_NAME REGION
#
#   # Or download and run:
#   curl -sSL https://raw.githubusercontent.com/astuto-ai/onelens-installation-scripts/release/v1.2.0-ebs-driver-installer/scripts/ebs-driver-installation/install-ebs-csi-driver.sh -o install-ebs-csi-driver.sh
#   chmod +x install-ebs-csi-driver.sh
#   ./install-ebs-csi-driver.sh CLUSTER_NAME REGION
#
# EXAMPLES:
#   ./install-ebs-csi-driver.sh my-eks-cluster us-east-1
#   ./install-ebs-csi-driver.sh production-cluster eu-west-1
#
# PREREQUISITES:
#   - AWS CLI installed and configured
#   - EKS cluster must exist with OIDC identity provider enabled
#   - Appropriate IAM permissions for CloudFormation and IAM operations
#
# ==============================================================================

# Removed set -e as it causes silent failures with stderr logging

# Script version
readonly SCRIPT_VERSION="1.2.0"
readonly SCRIPT_NAME="install-ebs-csi-driver"

# CloudFormation template URL (can be overridden with environment variable)
readonly CFT_TEMPLATE_URL="${CFT_TEMPLATE_URL:-https://raw.githubusercontent.com/astuto-ai/onelens-installation-scripts/release/v1.2.0-ebs-driver-installer/scripts/ebs-driver-installation/ebs-driver-role.yaml}"

# Global variables
CLUSTER_NAME=""
REGION=""
STACK_NAME=""
TEMP_DIR=""
OIDC_URL=""
START_TIME=""
SKIP_WAIT=""

# ==============================================================================
# Utility Functions
# ==============================================================================

log() {
    local level="$1"
    shift
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case "$level" in
        "INFO")  echo "[INFO]  [$timestamp] $*" ;;
        "WARN")  echo "[WARN]  [$timestamp] $*" ;;
        "ERROR") echo "[ERROR] [$timestamp] $*" >&2 ;;
        "SUCCESS") echo "[SUCCESS] [$timestamp] $*" ;;
        "DEBUG") [[ "${DEBUG:-}" == "true" ]] && echo "[DEBUG] [$timestamp] $*" ;;
    esac
}

show_banner() {
    cat << 'BANNER_EOF'
╔══════════════════════════════════════════════════════════════════════════════╗
║                     EBS CSI Driver IAM Role Installer                       ║
║                                                                              ║
║  This script will create an IAM role for Amazon EBS CSI Driver with         ║
║  OIDC trust relationship for your EKS cluster.                              ║
╚══════════════════════════════════════════════════════════════════════════════╝
BANNER_EOF
    log "INFO" "Script version: $SCRIPT_VERSION"
    echo
}

show_usage() {
    cat << USAGE_EOF
Usage: $0 CLUSTER_NAME REGION

Arguments:
  CLUSTER_NAME    Name of your EKS cluster
  REGION          AWS region where the EKS cluster is located

Examples:
  $0 my-eks-cluster us-east-1
  $0 production-cluster eu-west-1

Prerequisites:
  - AWS CLI installed and configured
  - EKS cluster must exist with OIDC identity provider enabled
  - Appropriate IAM permissions for CloudFormation and IAM operations

Environment Variables:
  DEBUG=true              Enable debug logging
  CFT_TEMPLATE_URL=<url>  Override CloudFormation template URL
  
For more information, visit: https://github.com/astuto-ai/onelens-installation-scripts/tree/release/v1.2.0-ebs-driver-installer
USAGE_EOF
}

check_prerequisites() {
    log "INFO" "Checking prerequisites..."
    
    local missing_deps=()
    
    # Check AWS CLI
    if ! command -v aws >/dev/null 2>&1; then
        missing_deps+=("aws-cli")
    fi
    

    
    # Check curl (for downloading template)
    if ! command -v curl >/dev/null 2>&1; then
        missing_deps+=("curl")
    fi
    
    if [[ ${#missing_deps[@]} -ne 0 ]]; then
        log "ERROR" "Missing required dependencies: ${missing_deps[*]}"
        log "ERROR" "Please install the missing dependencies and try again"
        exit 1
    fi
    
    # Check AWS CLI configuration
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        log "ERROR" "AWS CLI is not configured or credentials are invalid"
        log "ERROR" "Please run 'aws configure' or set AWS environment variables"
        exit 1
    fi
    
    log "SUCCESS" "All prerequisites satisfied"
}

validate_inputs() {
    log "INFO" "Validating input parameters..."
    
    if [[ -z "$CLUSTER_NAME" ]]; then
        log "ERROR" "Cluster name is required"
        show_usage
        exit 1
    fi
    
    if [[ -z "$REGION" ]]; then
        log "ERROR" "Region is required"
        show_usage
        exit 1
    fi
    
    # Validate region format (basic check)
    if [[ ! "$REGION" =~ ^[a-z]{2}(-gov)?-[a-z]+-[0-9]$ ]]; then
        log "WARN" "Region format looks unusual: '$REGION'. Continuing anyway..."
    fi
    
    # Generate stack name
    STACK_NAME="ebs-csi-driver-role-${CLUSTER_NAME}-${REGION}"
    
    log "INFO" "Cluster: $CLUSTER_NAME"
    log "INFO" "Region: $REGION"
    log "INFO" "Stack: $STACK_NAME"
}

verify_cluster_exists() {
    log "INFO" "Verifying EKS cluster exists and has OIDC provider..."
    
    # Check if cluster exists and extract OIDC issuer URL using AWS CLI query
    if ! OIDC_URL=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" --query 'cluster.identity.oidc.issuer' --output text 2>/dev/null); then
        log "ERROR" "EKS cluster '$CLUSTER_NAME' not found in region '$REGION'"
        log "ERROR" "Please verify the cluster name and region are correct"
        exit 1
    fi
    
    if [[ -z "$OIDC_URL" || "$OIDC_URL" == "null" || "$OIDC_URL" == "None" ]]; then
        log "ERROR" "EKS cluster '$CLUSTER_NAME' does not have OIDC identity provider enabled"
        log "ERROR" "Please enable OIDC identity provider for your cluster first"
        exit 1
    fi
    
    log "SUCCESS" "EKS cluster found and OIDC provider is enabled"
    log "INFO" "OIDC Issuer URL: $OIDC_URL"
}

download_template() {
    local template_file="$TEMP_DIR/ebs-driver-role.yaml"
    
    # Check if template exists locally first (for development/testing)
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
    local local_template="$script_dir/ebs-driver-role.yaml"
    
    if [[ -f "$local_template" ]]; then
        log "INFO" "Using local CloudFormation template..." >&2
        cp "$local_template" "$template_file"
    else
        log "INFO" "Downloading CloudFormation template..." >&2
        log "DEBUG" "Template URL: $CFT_TEMPLATE_URL" >&2
        
        if ! curl -sSL -f "$CFT_TEMPLATE_URL" -o "$template_file"; then
            log "ERROR" "Failed to download CloudFormation template" >&2
            log "ERROR" "URL: $CFT_TEMPLATE_URL" >&2
            log "ERROR" "You can set CFT_TEMPLATE_URL environment variable to use a different URL" >&2
            exit 1
        fi
    fi
    
    # Verify template is valid YAML
    if ! aws cloudformation validate-template --template-body "file://$template_file" --region "$REGION" >/dev/null 2>&1; then
        log "ERROR" "CloudFormation template is not valid" >&2
        exit 1
    fi
    
    log "SUCCESS" "CloudFormation template ready and validated" >&2
    echo "$template_file"
}

deploy_cloudformation() {
    local template_file="$1"
    
    log "INFO" "Deploying CloudFormation stack..."
    log "INFO" "This may take a few minutes..."
    
    # Check if stack already exists
    local stack_status
    if stack_status=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" --query 'Stacks[0].StackStatus' --output text 2>/dev/null); then
        case "$stack_status" in
            "CREATE_COMPLETE"|"UPDATE_COMPLETE")
                log "WARN" "Stack '$STACK_NAME' already exists with status: $stack_status"
                log "WARN" "Updating existing stack..."
                deploy_action="update"
                ;;
            "CREATE_IN_PROGRESS"|"UPDATE_IN_PROGRESS"|"DELETE_IN_PROGRESS")
                log "ERROR" "Stack '$STACK_NAME' is currently in progress with status: $stack_status"
                log "ERROR" "Please wait for the current operation to complete"
                exit 1
                ;;
            *)
                log "ERROR" "Stack '$STACK_NAME' exists but is in an unexpected state: $stack_status"
                exit 1
                ;;
        esac
    else
        deploy_action="create"
    fi
    
    # Deploy stack
    local deploy_cmd
    if [[ "$deploy_action" == "create" ]]; then
        deploy_cmd=(aws cloudformation create-stack)
    else
        deploy_cmd=(aws cloudformation update-stack)
    fi
    
    # Capture command output to handle errors properly
    local cf_output cf_exit_code
    if cf_output=$("${deploy_cmd[@]}" \
        --stack-name "$STACK_NAME" \
        --template-body "file://$template_file" \
        --parameters \
            "ParameterKey=ClusterName,ParameterValue=$CLUSTER_NAME" \
            "ParameterKey=OIDCIssuerURL,ParameterValue=$OIDC_URL" \
        --capabilities CAPABILITY_NAMED_IAM \
        --region "$REGION" \
        --tags \
            "Key=CreatedBy,Value=$SCRIPT_NAME" \
            "Key=Version,Value=$SCRIPT_VERSION" \
            "Key=EKSCluster,Value=$CLUSTER_NAME" \
        2>&1); then
        
        # Success case
        if [[ "$deploy_action" == "create" ]]; then
            log "SUCCESS" "CloudFormation stack creation initiated"
        else
            log "SUCCESS" "CloudFormation stack update initiated"
        fi
    else
        # Handle specific error cases
        if [[ "$deploy_action" == "update" && "$cf_output" == *"No updates are to be performed"* ]]; then
            log "INFO" "No changes detected - stack is already up to date"
            log "SUCCESS" "CloudFormation stack is current"
            # Set flag to skip waiting
            SKIP_WAIT=true
        else
            log "ERROR" "CloudFormation deployment failed:"
            log "ERROR" "$cf_output"
            exit 1
        fi
    fi
}

wait_for_stack_completion() {
    log "INFO" "Waiting for CloudFormation stack deployment to complete..."
    
    local start_time=$(date +%s)
    local dots=0
    local last_status=""
    
    while true; do
        local current_status
        if ! current_status=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" --query 'Stacks[0].StackStatus' --output text 2>/dev/null); then
            log "ERROR" "Failed to check stack status"
            exit 1
        fi
        
        # Show status change
        if [[ "$current_status" != "$last_status" ]]; then
            if [[ -n "$last_status" ]]; then
                echo # New line after dots
            fi
            log "INFO" "Stack status: $current_status"
            last_status="$current_status"
            dots=0
        fi
        
        case "$current_status" in
            "CREATE_COMPLETE"|"UPDATE_COMPLETE")
                echo # New line after dots
                log "SUCCESS" "CloudFormation stack deployment completed successfully!"
                break
                ;;
            "CREATE_FAILED"|"UPDATE_FAILED"|"ROLLBACK_COMPLETE"|"UPDATE_ROLLBACK_COMPLETE")
                echo # New line after dots
                log "ERROR" "CloudFormation stack deployment failed with status: $current_status"
                log "ERROR" "Check AWS CloudFormation console for detailed error information"
                exit 1
                ;;
            "CREATE_IN_PROGRESS"|"UPDATE_IN_PROGRESS"|"UPDATE_ROLLBACK_IN_PROGRESS")
                # Show progress dots
                printf "."
                dots=$((dots + 1))
                if [[ $dots -eq 60 ]]; then
                    printf "\n"
                    local elapsed=$(($(date +%s) - start_time))
                    log "INFO" "Still waiting... (${elapsed}s elapsed)"
                    dots=0
                fi
                ;;
            *)
                echo # New line after dots
                log "WARN" "Unexpected stack status: $current_status"
                ;;
        esac
        
        sleep 5
    done
}

get_stack_outputs() {
    log "INFO" "Retrieving stack outputs..."
    
    # Check if stack has outputs
    local has_outputs
    if ! has_outputs=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" --query 'Stacks[0].Outputs' --output text 2>/dev/null); then
        log "ERROR" "Failed to retrieve stack outputs"
        exit 1
    fi
    
    if [[ "$has_outputs" == "null" || "$has_outputs" == "None" || -z "$has_outputs" ]]; then
        log "WARN" "No outputs found for stack"
        return
    fi
    
    echo
    # Show appropriate success message based on whether deployment occurred
    if [[ "${SKIP_WAIT:-}" == "true" ]]; then
        log "SUCCESS" "IAM Role fetched from existing stack!"
        echo "╔══════════════════════════════════════════════════════════════════════════════╗"
        echo "║                           EXISTING STACK RESULTS                            ║"
        echo "╚══════════════════════════════════════════════════════════════════════════════╝"
    else
        log "SUCCESS" "IAM Role created successfully!"
        echo "╔══════════════════════════════════════════════════════════════════════════════╗"
        echo "║                            DEPLOYMENT RESULTS                               ║"
        echo "╚══════════════════════════════════════════════════════════════════════════════╝"
    fi
    echo
    
    # Parse and display outputs using AWS CLI queries
    local role_name role_arn
    role_name=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" --query 'Stacks[0].Outputs[?OutputKey==`RoleName`].OutputValue' --output text 2>/dev/null)
    role_arn=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" --query 'Stacks[0].Outputs[?OutputKey==`RoleArn`].OutputValue' --output text 2>/dev/null)
    
    if [[ -n "$role_name" ]]; then
        echo "IAM Role Name: $role_name"
    fi
    
    if [[ -n "$role_arn" ]]; then
        echo "IAM Role ARN:  $role_arn"
    fi
    
    echo
    echo "Next Steps:"
    echo "1. Install the EBS CSI driver add-on in your EKS cluster"
    echo "2. Use the IAM role ARN above when configuring the EBS CSI driver"
    echo
    echo "Useful Commands:"
    if [[ -n "$role_arn" ]]; then
        echo "# Install EBS CSI driver add-on (using AWS CLI):"
        echo "aws eks create-addon \\"
        echo "  --cluster-name $CLUSTER_NAME \\"
        echo "  --addon-name aws-ebs-csi-driver \\"
        echo "  --service-account-role-arn $role_arn \\"
        echo "  --region $REGION"
    fi
    echo
}

cleanup() {
    local exit_code=$?
    
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        log "DEBUG" "Cleaning up temporary directory: $TEMP_DIR"
        rm -rf "$TEMP_DIR"
    fi
    
    if [[ $exit_code -ne 0 ]]; then
        echo
        log "ERROR" "Script execution failed"
        log "INFO" "For troubleshooting help, check:"
        log "INFO" "- AWS CloudFormation console for stack events"
        log "INFO" "- AWS CloudTrail for API call details"
        log "INFO" "- EKS cluster OIDC provider configuration"
    else
        local end_time=$(date +%s)
        local duration=$((end_time - START_TIME))
        log "SUCCESS" "Script completed successfully in ${duration}s"
    fi
    
    exit $exit_code
}

# ==============================================================================
# Main Execution
# ==============================================================================

main() {
    # Set up error handling
    trap cleanup EXIT
    trap 'log "ERROR" "Script interrupted by user"; exit 130' INT TERM
    
    START_TIME=$(date +%s)
    
    # Parse arguments
    if [[ $# -ne 2 ]]; then
        show_banner
        show_usage
        exit 1
    fi
    
    CLUSTER_NAME="$1"
    REGION="$2"
    
    # Create temporary directory
    TEMP_DIR=$(mktemp -d)
    log "DEBUG" "Created temporary directory: $TEMP_DIR"
    
    # Main execution flow
    show_banner
    check_prerequisites
    validate_inputs
    verify_cluster_exists
    
    local template_file
    template_file=$(download_template)
    
    deploy_cloudformation "$template_file"
    
    # Only wait for completion if an actual deployment occurred
    if [[ "${SKIP_WAIT:-}" != "true" ]]; then
        wait_for_stack_completion
    fi
    
    get_stack_outputs
}

# Run main function with all arguments
main "$@" 
