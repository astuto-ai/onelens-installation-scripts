#!/bin/bash

# OneLens Agent Pre-requisite Checker
# This script validates all prerequisites for OneLens Agent installation
# Version: 1.0

set -e

# Configuration
REQUIRED_URLS=(
    "https://onelens-kubernetes-agent.s3.amazonaws.com"
    "https://api-in.onelens.cloud"
    "https://astuto-ai.github.io"
)

REQUIRED_CONTAINER_REGISTRIES=(
    "public.ecr.aws"
    "quay.io"
    "registry.k8s.io"
)

MIN_HELM_VERSION="3.0.0"
MIN_EKS_VERSION="1.27"

# Global array to track failed checks
FAILED_CHECKS=()

# Global array to track confirmed details
CONFIRMED_DETAILS=()

# Utility functions
print_header() {
    echo ""
    echo "================================================================"
    echo "$1"
    echo "================================================================"
    echo ""
}

print_step() {
    echo "Checking: $1"
}

print_success() {
    echo "PASS: $1"
}

print_error() {
    echo "FAIL: $1"
}

print_warning() {
    echo "WARNING: $1"
}

add_failed_check() {
    FAILED_CHECKS+=("$1")
}

add_confirmed_detail() {
    CONFIRMED_DETAILS+=("$1")
}



version_greater_equal() {
    [ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

check_command() {
    if command -v "$1" &> /dev/null; then
        return 0
    else
        return 1
    fi
}

# Silent check for required tools before starting
check_required_tools() {
    local missing_tools=()
    local required_tools=("curl" "ping" "nslookup" "jq" "aws" "kubectl" "helm")
    
    for tool in "${required_tools[@]}"; do
        if ! check_command "$tool"; then
            missing_tools+=("$tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        echo "ERROR: Missing required tools for this script to run:"
        printf '  - %s\n' "${missing_tools[@]}"
        echo ""
        echo "Please install the missing tools and try again."
        echo "Required tools: curl, ping, nslookup, jq, aws, kubectl, helm"
        exit 1
    fi
}

# Function to get actual EKS cluster name and region
get_eks_cluster_info() {
    local cluster_endpoint="$1"
    local context_name="$2"
    
    # Method 1: Try to get from AWS CLI if available and configured
    if check_command aws && aws sts get-caller-identity &> /dev/null; then
        
        # Extract region from endpoint if it's an EKS endpoint
        local region=""
        if [[ "$cluster_endpoint" =~ \.([a-z0-9-]+)\.eks\.amazonaws\.com ]]; then
            region="${BASH_REMATCH[1]}"
        fi
        
        if [ -n "$region" ]; then
            # List clusters and try to match by endpoint
            local clusters
            clusters=$(aws eks list-clusters --region "$region" --query 'clusters[]' --output text 2>/dev/null || echo "")
            
            for cluster in $clusters; do
                local cluster_endpoint_aws
                cluster_endpoint_aws=$(aws eks describe-cluster --name "$cluster" --region "$region" --query 'cluster.endpoint' --output text 2>/dev/null || echo "")
                if [ "$cluster_endpoint_aws" = "$cluster_endpoint" ]; then
                    echo "$cluster|$region"
                    return 0
                fi
            done
        fi
    fi
    
    # Method 2: Parse from EKS endpoint URL
    if [[ "$cluster_endpoint" =~ https://([A-Za-z0-9]+)\.gr[0-9]+\.([a-z0-9-]+)\.eks\.amazonaws\.com ]]; then
        local cluster_id="${BASH_REMATCH[1]}"
        local region="${BASH_REMATCH[2]}"
        
        # Try to get actual cluster name using the cluster ID
        if check_command aws && aws sts get-caller-identity &> /dev/null; then
            local cluster_name
            cluster_name=$(aws eks describe-cluster --name "$cluster_id" --region "$region" --query 'cluster.name' --output text 2>/dev/null || echo "")
            if [ -n "$cluster_name" ] && [ "$cluster_name" != "None" ]; then
                echo "$cluster_name|$region"
                return 0
            fi
        fi
        
        # Fallback: use cluster ID from URL
        echo "$cluster_id (parsed from endpoint)|$region"
        return 0
    fi
    
    # Method 3: Fallback to context name
    echo "$context_name (context name)|unknown"
    return 0
}

# Internet connectivity checks
check_internet_access() {
    print_step "Checking internet connectivity..."
    
    # Check basic internet connectivity
    if ! ping -c 1 8.8.8.8 &> /dev/null; then
        print_error "No internet connectivity detected"
        add_failed_check "Internet Connectivity: No basic internet access (ping to 8.8.8.8 failed)"
        return 1
    fi
    
    print_success "Basic internet connectivity verified"
    
    # Check required URLs
    print_step "Checking access to required URLs..."
    local has_url_failures=false
    
    for url in "${REQUIRED_URLS[@]}"; do
        # Use curl with less strict requirements - just check if we can connect
        if curl --connect-timeout 10 --max-time 30 -s -I "$url" &> /dev/null; then
            print_success "$url accessible"
        else
            print_error "$url not accessible"
            add_failed_check "Internet Connectivity: Cannot access required URL: $url"
            has_url_failures=true
        fi
    done
    
    # Check container registries DNS resolution
    print_step "Checking access to container registries..."
    for registry in "${REQUIRED_CONTAINER_REGISTRIES[@]}"; do
        if nslookup "$registry" &> /dev/null; then
            print_success "$registry accessible"
        else
            print_error "$registry not accessible"
            add_failed_check "Internet Connectivity: Cannot resolve container registry: $registry"
            has_url_failures=true
        fi
    done
    
    if [ "$has_url_failures" = false ]; then
        print_success "All required URLs and registries are accessible"
        return 0
    else
        print_error "Some URLs/registries are not accessible. Please check your network connectivity and firewall settings."
        return 1
    fi
}

# AWS CLI configuration check
check_aws_cli() {
    print_step "Checking AWS CLI configuration..."
    
    if ! check_command aws; then
        print_error "AWS CLI is not installed or not in PATH"
        add_failed_check "AWS CLI: AWS CLI is not installed or not in PATH"
        return 1
    fi
    
    # Check if AWS CLI is configured
    if ! aws sts get-caller-identity &> /dev/null; then
        print_error "AWS CLI is not configured or credentials are invalid"
        print_error "Please run 'aws configure' to set up your credentials"
        add_failed_check "AWS CLI: AWS CLI is not configured or credentials are invalid"
        return 1
    fi
    
    # Get AWS account information
    local aws_info
    aws_info=$(aws sts get-caller-identity --output json)
    local account_id=$(echo "$aws_info" | jq -r '.Account')
    local user_arn=$(echo "$aws_info" | jq -r '.Arn')
    local user_id=$(echo "$aws_info" | jq -r '.UserId')
    
    print_success "AWS CLI is configured"
    echo "AWS Account Details:"
    echo "  Account ID: $account_id"
    echo "  User/Role ARN: $user_arn"
    echo "  User ID: $user_id"
    
    # Store AWS details for final confirmation
    add_confirmed_detail "AWS Account: $account_id"
    add_confirmed_detail "AWS User/Role: $user_arn"
    return 0
}

# Kubectl cluster check
check_kubectl_cluster() {
    print_step "Checking kubectl cluster configuration..."
    
    if ! check_command kubectl; then
        print_error "kubectl is not installed or not in PATH"
        add_failed_check "Kubectl: kubectl is not installed or not in PATH"
        return 1
    fi
    
    # Check if kubectl can connect to cluster
    if ! kubectl cluster-info &> /dev/null; then
        print_error "kubectl cannot connect to any cluster"
        print_error "Please ensure your kubeconfig is properly configured"
        add_failed_check "Kubectl: kubectl cannot connect to any cluster"
        return 1
    fi
    
    # Get cluster information
    local cluster_context
    cluster_context=$(kubectl config current-context)
    local cluster_endpoint
    cluster_endpoint=$(kubectl cluster-info | grep "Kubernetes control plane" | awk '{print $NF}')
    
    # Try to get actual EKS cluster name and region
    local cluster_info
    cluster_info=$(get_eks_cluster_info "$cluster_endpoint" "$cluster_context")
    local actual_cluster_name="${cluster_info%|*}"
    local cluster_region="${cluster_info#*|}"
    
    print_success "kubectl is configured and connected"
    echo "Cluster Details:"
    echo "  Current Context: $cluster_context"
    echo "  Cluster Endpoint: $cluster_endpoint"
    echo "  EKS Cluster Name: $actual_cluster_name"
    echo "  AWS Region: $cluster_region"
    
    # Store cluster details for final confirmation
    add_confirmed_detail "EKS Cluster Name: $actual_cluster_name"
    add_confirmed_detail "AWS Region: $cluster_region"
    add_confirmed_detail "Kubectl Context: $cluster_context"
    add_confirmed_detail "Cluster Endpoint: $cluster_endpoint"
    return 0
}

# Helm version check
check_helm_version() {
    print_step "Checking Helm version..."
    
    if ! check_command helm; then
        print_error "Helm is not installed or not in PATH"
        print_error "Please install Helm version $MIN_HELM_VERSION or later"
        add_failed_check "Helm: Helm is not installed or not in PATH"
        return 1
    fi
    
    local helm_version
    helm_version=$(helm version --short --client | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | sed 's/v//')
    
    if version_greater_equal "$helm_version" "$MIN_HELM_VERSION"; then
        print_success "Helm version $helm_version is compatible (>= $MIN_HELM_VERSION)"
        add_confirmed_detail "Helm Version: $helm_version"
        return 0
    else
        print_error "Helm version $helm_version is too old (minimum required: $MIN_HELM_VERSION)"
        print_error "Please upgrade Helm to version $MIN_HELM_VERSION or later"
        add_failed_check "Helm: Version $helm_version is too old (minimum required: $MIN_HELM_VERSION)"
        return 1
    fi
}

# EKS version check
check_eks_version() {
    print_step "Checking EKS cluster version..."
    
    local k8s_version
    k8s_version=$(kubectl version --output=json | jq -r '.serverVersion.gitVersion' | sed 's/v//')
    
    if [ -z "$k8s_version" ] || [ "$k8s_version" = "null" ]; then
        print_error "Could not determine Kubernetes version"
        add_failed_check "EKS Version: Could not determine Kubernetes version"
        return 1
    fi
    
    # Extract major.minor version
    local version_major_minor
    version_major_minor=$(echo "$k8s_version" | cut -d. -f1,2)
    
    if version_greater_equal "$version_major_minor" "$MIN_EKS_VERSION"; then
        print_success "EKS version $k8s_version is compatible (>= $MIN_EKS_VERSION)"
        add_confirmed_detail "EKS Version: $k8s_version"
        return 0
    else
        print_error "EKS version $k8s_version is too old (minimum required: $MIN_EKS_VERSION)"
        print_error "Please upgrade your EKS cluster to version $MIN_EKS_VERSION or later"
        add_failed_check "EKS Version: Version $k8s_version is too old (minimum required: $MIN_EKS_VERSION)"
        return 1
    fi
}

# EBS CSI driver check
check_ebs_driver() {
    print_step "Checking EBS CSI driver installation..."
    
    # Check if EBS CSI driver is installed
    if ! kubectl get csidriver ebs.csi.aws.com &> /dev/null; then
        print_error "EBS CSI driver is not installed"
        echo ""
        echo "To install the EBS CSI driver, run the following command:"
        echo "curl -sSL https://raw.githubusercontent.com/astuto-ai/onelens-installation-scripts/release/v1.2.0-ebs-driver-installer/scripts/ebs-driver-installation/install-ebs-csi-driver.sh | bash -s -- my-cluster us-east-1"
        echo ""
        echo "Replace 'my-cluster' with your actual cluster name and 'us-east-1' with your region"
        echo "Alternative: Use the script in scripts/ebs-driver-installation/"
        add_failed_check "EBS CSI Driver: EBS CSI driver is not installed"
        return 1
    fi
    
    print_success "EBS CSI driver is installed"
    
    # Check EBS CSI driver controller pods
    print_step "Checking EBS CSI driver controller pod status..."
    local controller_pods_output
    controller_pods_output=$(kubectl get pods -n kube-system -l app=ebs-csi-controller --no-headers 2>/dev/null)
    
    if [ -z "$controller_pods_output" ]; then
        print_error "No EBS CSI driver controller pods found"
        add_failed_check "EBS CSI Driver: No controller pods found with label app=ebs-csi-controller"
        return 1
    fi
    
    # Check if all controller pods are ready (READY column should show X/X format where both numbers match)
    local controller_not_ready
    controller_not_ready=$(echo "$controller_pods_output" | awk '{split($2,a,"/"); if(a[1] != a[2] || $3 != "Running") print $0}')
    
    if [ -n "$controller_not_ready" ]; then
        print_warning "Some EBS CSI driver controller pods are not ready"
        echo "Controller pods status:"
        kubectl get pods -n kube-system -l app=ebs-csi-controller
        echo ""
        echo "Possible issues:"
        echo "- Pods may still be starting up"
        echo "- Resource constraints (CPU/Memory)"
        echo "- Image pull issues"
        echo "- Configuration errors"
        add_confirmed_detail "EBS CSI Driver: Controller pods have issues (see warnings above)"
    else
        print_success "EBS CSI driver controller pods are running and ready"
        add_confirmed_detail "EBS CSI Driver: Controller pods are healthy"
    fi
    
    # Check EBS CSI driver node pods
    print_step "Checking EBS CSI driver node pod status..."
    local node_pods_output
    node_pods_output=$(kubectl get pods -n kube-system -l app=ebs-csi-node --no-headers 2>/dev/null)
    
    if [ -z "$node_pods_output" ]; then
        print_warning "No EBS CSI driver node pods found"
        echo "This might indicate:"
        echo "- EBS CSI driver is not fully installed"
        echo "- DaemonSet is not deployed"
        echo "- Node selector issues"
        add_confirmed_detail "EBS CSI Driver: No node pods found (may affect volume mounting)"
    else
        # Check if all node pods are ready
        local node_not_ready
        node_not_ready=$(echo "$node_pods_output" | awk '{split($2,a,"/"); if(a[1] != a[2] || $3 != "Running") print $0}')
        
        if [ -n "$node_not_ready" ]; then
            print_warning "Some EBS CSI driver node pods are not ready"
            echo "Node pods status:"
            kubectl get pods -n kube-system -l app=ebs-csi-node
            echo ""
            echo "Possible issues:"
            echo "- Pods may still be starting up"
            echo "- Node resource constraints"
            echo "- Privileged access issues"
            echo "- Host path mount issues"
            add_confirmed_detail "EBS CSI Driver: Node pods have issues (see warnings above)"
        else
            print_success "EBS CSI driver node pods are running and ready"
            add_confirmed_detail "EBS CSI Driver: Node pods are healthy"
        fi
    fi
    
    return 0
}



# Main execution
main() {
    # Silent check for required tools first
    check_required_tools
    
    print_header "OneLens Agent Pre-requisite Checker"
    echo "This script will validate all prerequisites for OneLens Agent installation."
    echo "Please ensure you have the necessary permissions to access AWS and Kubernetes resources."
    echo ""
    echo "Running prerequisite checks..."
    
    local checks_passed=0
    local total_checks=6
    
    # Run all checks
    echo ""
    print_header "1/6 - Internet Connectivity Check"
    if check_internet_access; then
        ((checks_passed++))
    fi
    
    echo ""
    print_header "2/6 - AWS CLI Configuration Check"
    if check_aws_cli; then
        ((checks_passed++))
    fi
    
    echo ""
    print_header "3/6 - Kubectl Cluster Configuration Check"
    if check_kubectl_cluster; then
        ((checks_passed++))
    fi
    
    echo ""
    print_header "4/6 - Helm Version Check"
    if check_helm_version; then
        ((checks_passed++))
    fi
    
    echo ""
    print_header "5/6 - EKS Version Check"
    if check_eks_version; then
        ((checks_passed++))
    fi
    
    echo ""
    print_header "6/6 - EBS CSI Driver Check"
    if check_ebs_driver; then
        ((checks_passed++))
    fi
    
    # Summary
    echo ""
    print_header "Pre-requisite Check Summary"
    
    # Always show both passed and failed summary
    echo ""
    echo "PREREQUISITE CHECK RESULTS:"
    echo "============================"
    echo "Status: $checks_passed/$total_checks checks passed"
    echo ""
    
    # Show successful configuration details
    if [ ${#CONFIRMED_DETAILS[@]} -gt 0 ]; then
        echo ""
        echo "⚠️  PLEASE REVIEW THE DETECTED CONFIGURATION BELOW BEFORE PROCEEDING ⚠️"
        echo ""
        echo "PASSED CHECKS - DETECTED CONFIGURATION:"
        echo "======================================="
        
        # Group details by category for better readability
        echo ""
        echo "AWS CONFIGURATION:"
        echo "------------------"
        for detail in "${CONFIRMED_DETAILS[@]}"; do
            if [[ "$detail" =~ ^AWS ]] && [[ ! "$detail" =~ ^AWS\ Region ]]; then
                echo "  $detail"
            fi
        done
        
        echo ""
        echo "KUBERNETES CLUSTER:"
        echo "-------------------"
        for detail in "${CONFIRMED_DETAILS[@]}"; do
            if [[ "$detail" =~ ^EKS|^Kubectl|^Cluster|^AWS\ Region ]] && [[ ! "$detail" =~ ^EKS\ Version ]]; then
                echo "  $detail"
            fi
        done
        
        echo ""
        echo "TOOLS & VERSIONS:"
        echo "-----------------"
        for detail in "${CONFIRMED_DETAILS[@]}"; do
            if [[ "$detail" =~ ^Helm|^EKS\ Version ]]; then
                echo "  $detail"
            fi
        done
        
        echo ""
        echo "STORAGE:"
        echo "--------"
        for detail in "${CONFIRMED_DETAILS[@]}"; do
            if [[ "$detail" =~ ^EBS ]]; then
                echo "  $detail"
            fi
        done
        
        echo ""
    fi
    
    # Show failed checks if any
    if [ ${#FAILED_CHECKS[@]} -gt 0 ]; then
        echo "FAILED CHECKS:"
        echo "=============="
        local count=1
        for failure in "${FAILED_CHECKS[@]}"; do
            echo "$count. $failure"
            ((count++))
        done
        echo ""
    fi
    
    # Final status and next steps
    if [ $checks_passed -eq $total_checks ]; then
        print_success "All pre-requisites passed! Your environment is ready for OneLens Agent installation."
        echo ""
        echo "IMPORTANT: Please carefully review the detected configuration sections above"
        echo "to ensure OneLens Agent will be installed on the correct AWS account and cluster."
        echo ""
        echo "NEXT STEPS:"
        echo "1. Verify the AWS account, region, and cluster details above are correct"
        echo "2. Run the OneLens Agent installation script"
        echo "3. Follow the installation guide for configuration"
    else
        print_error "Some pre-requisites failed! Please address the failed checks above before proceeding."
        echo ""
        echo "NEXT STEPS:"
        echo "1. Review the failed checks above"
        echo "2. Fix the issues listed in the failed checks"
        echo "3. Re-run this script to verify fixes"
        echo "4. Proceed with OneLens Agent installation once all checks pass"
        exit 1
    fi
}

# Script entry point
# Handle both direct execution and piped execution (curl | bash)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] || [[ "${BASH_SOURCE[0]}" == "" ]]; then
    main "$@"
fi
