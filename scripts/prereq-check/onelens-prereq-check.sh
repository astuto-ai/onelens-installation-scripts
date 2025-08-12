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

ask_confirmation() {
    # If running in auto mode, automatically confirm
    if [ "${AUTO_MODE:-false}" = true ]; then
        echo "$1 (y/n): y [auto]"
        return 0
    fi
    
    while true; do
        read -p "$1 (y/n): " yn
        case $yn in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "Please answer yes or no.";;
        esac
    done
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
    
    if ! ask_confirmation "Is this the correct AWS account and user/role?"; then
        print_error "Please configure AWS CLI with the correct credentials"
        add_failed_check "AWS CLI: User rejected AWS account/role confirmation"
        return 1
    fi
    
    print_success "AWS configuration confirmed"
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
    local cluster_info
    cluster_info=$(kubectl config current-context)
    local cluster_endpoint
    cluster_endpoint=$(kubectl cluster-info | grep "Kubernetes control plane" | awk '{print $NF}')
    
    print_success "kubectl is configured and connected"
    echo "Cluster Details:"
    echo "  Current Context: $cluster_info"
    echo "  Cluster Endpoint: $cluster_endpoint"
    
    if ! ask_confirmation "Is this the correct cluster for OneLens Agent installation?"; then
        print_error "Please switch to the correct cluster context"
        print_error "Use 'kubectl config use-context <context-name>' to switch contexts"
        add_failed_check "Kubectl: User rejected cluster context confirmation"
        return 1
    fi
    
    print_success "Cluster configuration confirmed"
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
    
    if [ -z "$k8s_version" ]; then
        print_error "Could not determine Kubernetes version"
        add_failed_check "EKS Version: Could not determine Kubernetes version"
        return 1
    fi
    
    # Extract major.minor version
    local version_major_minor
    version_major_minor=$(echo "$k8s_version" | cut -d. -f1,2)
    
    if version_greater_equal "$version_major_minor" "$MIN_EKS_VERSION"; then
        print_success "EKS version $k8s_version is compatible (>= $MIN_EKS_VERSION)"
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
        if ! ask_confirmation "Continue anyway? (EBS driver controller issues may affect storage)"; then
            add_failed_check "EBS CSI Driver: Controller pods are not ready and user chose not to continue"
            return 1
        fi
    else
        print_success "EBS CSI driver controller pods are running and ready"
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
        if ! ask_confirmation "Continue anyway? (Missing node pods may affect EBS volume mounting)"; then
            add_failed_check "EBS CSI Driver: No node pods found and user chose not to continue"
            return 1
        fi
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
            if ! ask_confirmation "Continue anyway? (Node pod issues may affect EBS volume operations)"; then
                add_failed_check "EBS CSI Driver: Node pods are not ready and user chose not to continue"
                return 1
            fi
        else
            print_success "EBS CSI driver node pods are running and ready"
        fi
    fi
    
    return 0
}



# Main execution
main() {
    local auto_mode=false
    
    # Check for auto flag
    for arg in "$@"; do
        case $arg in
            --auto|--yes|-y)
                auto_mode=true
                shift
                ;;
        esac
    done
    
    # Silent check for required tools first
    check_required_tools
    
    print_header "OneLens Agent Pre-requisite Checker"
    echo "This script will validate all prerequisites for OneLens Agent installation."
    echo "Please ensure you have the necessary permissions to access AWS and Kubernetes resources."
    echo ""
    
    if [ "$auto_mode" = false ]; then
        if ! ask_confirmation "Do you want to proceed with the pre-requisite check?"; then
            echo "Pre-requisite check cancelled."
            exit 0
        fi
    else
        echo "Auto mode enabled - proceeding with pre-requisite check..."
        export AUTO_MODE=true
    fi
    
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
    
    if [ $checks_passed -eq $total_checks ]; then
        print_success "All pre-requisites passed! ($checks_passed/$total_checks)"
        print_success "Your environment is ready for OneLens Agent installation."
        echo ""
        echo "Next steps:"
        echo "1. Run the OneLens Agent installation script"
        echo "2. Follow the installation guide for configuration"
    else
        print_error "Some pre-requisites failed! ($checks_passed/$total_checks passed)"
        echo ""
        echo "FAILED CHECKS SUMMARY:"
        echo "========================"
        if [ ${#FAILED_CHECKS[@]} -eq 0 ]; then
            echo "No specific failure details collected."
        else
            local count=1
            for failure in "${FAILED_CHECKS[@]}"; do
                echo "$count. $failure"
                ((count++))
            done
        fi
        echo ""
        print_error "Please address the failed checks above before proceeding with installation."
        exit 1
    fi
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
