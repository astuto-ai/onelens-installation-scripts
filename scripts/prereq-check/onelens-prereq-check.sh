#!/bin/bash

# OneLens Agent Pre-requisite Checker
# This script validates all prerequisites for OneLens Agent installation
# Supports AWS EKS, Azure AKS, and GCP GKE clusters
# Version: 2.0


# Configuration
REQUIRED_URLS=(
    "https://api-in.onelens.cloud"
    "https://astuto-ai.github.io"
    "https://storage.googleapis.com"
)

REQUIRED_CONTAINER_REGISTRIES=(
    "public.ecr.aws"
    "quay.io"
    "registry.k8s.io"
    "pkg.dev"
)

MIN_HELM_VERSION="3.0.0"
MIN_K8S_VERSION="1.25"

# Global array to track failed checks
FAILED_CHECKS=()

# Global array to track confirmed details
CONFIRMED_DETAILS=()

# Cloud provider detection (will be set by detect_cloud_provider)
CLOUD_PROVIDER=""

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

print_info() {
    echo "INFO: $1"
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

# Detect cloud provider based on cluster endpoint
detect_cloud_provider() {
    print_step "Detecting cloud provider from cluster endpoint..."
    
    if ! check_command kubectl; then
        print_error "kubectl is not installed. Please install kubectl first."
        echo "  See: https://kubernetes.io/docs/tasks/tools/"
        return 1
    fi

    if ! kubectl cluster-info &> /dev/null; then
        print_error "kubectl cannot connect to any cluster."
        echo "  For EKS: aws eks update-kubeconfig --name <cluster-name> --region <region>"
        echo "  For AKS: az aks get-credentials --resource-group <rg> --name <cluster>"
        echo "  For GKE: gcloud container clusters get-credentials <cluster> --zone <zone> --project <project>"
        return 1
    fi
    
    local cluster_endpoint
    cluster_endpoint=$(kubectl cluster-info | grep "Kubernetes control plane" | awk '{print $NF}' | sed 's/\x1b\[[0-9;]*m//g')
    
    if [[ "$cluster_endpoint" =~ \.eks\.amazonaws\.com ]]; then
        CLOUD_PROVIDER="aws"
        print_success "Detected AWS EKS cluster"
    elif [[ "$cluster_endpoint" =~ \.azmk8s\.io ]]; then
        CLOUD_PROVIDER="azure"
        print_success "Detected Azure AKS cluster"
    elif [[ "$cluster_endpoint" =~ \.gke\.goog ]]; then
        CLOUD_PROVIDER="gke"
        print_success "Detected GCP GKE cluster"
    else
        # Try to detect from node labels
        local node_provider
        node_provider=$(kubectl get nodes -o jsonpath='{.items[0].spec.providerID}' 2>/dev/null || echo "")
        
        if [[ "$node_provider" =~ ^aws:// ]]; then
            CLOUD_PROVIDER="aws"
            print_success "Detected AWS EKS cluster (from node provider)"
        elif [[ "$node_provider" =~ ^azure:// ]]; then
            CLOUD_PROVIDER="azure"
            print_success "Detected Azure AKS cluster (from node provider)"
        elif [[ "$node_provider" =~ ^gce:// ]]; then
            CLOUD_PROVIDER="gke"
            print_success "Detected GCP GKE cluster (from node provider)"
        else
            print_warning "Could not auto-detect cloud provider"
            print_info "Cluster endpoint: $cluster_endpoint"
            print_info "Node provider: $node_provider"
            
            # Ask user or default to generic
            echo ""
            echo "Please specify your cloud provider:"
            echo "1) AWS (EKS)"
            echo "2) Azure (AKS)"
            echo "3) GCP (GKE)"
            read -r -p "Enter choice [1/2/3]: " choice < /dev/tty
            case "$choice" in
                1) CLOUD_PROVIDER="aws" ;;
                2) CLOUD_PROVIDER="azure" ;;
                3) CLOUD_PROVIDER="gke" ;;
                *)
                    print_error "Invalid choice. OneLens supports AWS EKS, Azure AKS, and GCP GKE."
                    echo "  See: https://github.com/astuto-ai/onelens-installation-scripts/blob/master/docs/troubleshooting.md#cloud-provider-auto-detection-failed"
                    exit 1
                    ;;
            esac
        fi
    fi
    
    add_confirmed_detail "Cloud Provider: $(echo "$CLOUD_PROVIDER" | tr '[:lower:]' '[:upper:]')"
    return 0
}

# Silent check for required tools before starting
check_required_tools() {
    local missing_tools=()
    local required_tools=("curl" "kubectl" "helm")

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
        echo "Required tools: curl, kubectl, helm"
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

# Function to get AKS cluster info
get_aks_cluster_info() {
    local cluster_endpoint="$1"
    local context_name="$2"
    
    # Extract location from endpoint URL first
    # AKS endpoints look like: https://<cluster-dns-prefix>.<location>.azmk8s.io:443
    # or https://<cluster-dns-prefix>.hcp.<location>.azmk8s.io:443
    local location="unknown"
    if [[ "$cluster_endpoint" =~ \.hcp\.([^.]+)\.azmk8s\.io ]]; then
        location="${BASH_REMATCH[1]}"
    elif [[ "$cluster_endpoint" =~ \.([^.]+)\.azmk8s\.io ]]; then
        location="${BASH_REMATCH[1]}"
    fi
    
    # Method 1: Try to get actual cluster info from Azure CLI
    if check_command az && az account show &> /dev/null; then
        # Extract FQDN from endpoint for matching
        local endpoint_fqdn="${cluster_endpoint#https://}"
        endpoint_fqdn="${endpoint_fqdn%:443}"
        endpoint_fqdn="${endpoint_fqdn%/}"
        
        # Try to find the cluster by listing all AKS clusters
        local cluster_info
        cluster_info=$(az aks list --query "[].{name:name,resourceGroup:resourceGroup,location:location,fqdn:fqdn}" -o tsv 2>/dev/null)
        
        if [ -n "$cluster_info" ]; then
            while IFS=$'\t' read -r name rg loc fqdn; do
                # Match by FQDN or by context name
                if [[ "$fqdn" == "$endpoint_fqdn" ]] || [[ "$name" == "$context_name" ]]; then
                    echo "$name|$loc|$rg"
                    return 0
                fi
            done <<< "$cluster_info"
        fi
    fi
    
    # Method 2: Fallback to context name with parsed location
    echo "$context_name (context name)|$location|unknown"
    return 0
}

# Function to get GKE cluster info
get_gke_cluster_info() {
    local cluster_endpoint="$1"
    local context_name="$2"

    # Method 1: Try to get from gcloud CLI if available
    if check_command gcloud; then
        local cluster_name project zone_region
        cluster_name=$(gcloud config get-value container/cluster 2>/dev/null || echo "")
        project=$(gcloud config get-value project 2>/dev/null || echo "")
        zone_region=$(gcloud config get-value compute/zone 2>/dev/null || echo "")
        if [ -z "$zone_region" ]; then
            zone_region=$(gcloud config get-value compute/region 2>/dev/null || echo "")
        fi

        if [ -n "$cluster_name" ] && [ "$cluster_name" != "(unset)" ]; then
            [ -z "$project" ] || [ "$project" = "(unset)" ] && project="unknown"
            [ -z "$zone_region" ] || [ "$zone_region" = "(unset)" ] && zone_region="unknown"
            echo "$cluster_name|$project|$zone_region"
            return 0
        fi
    fi

    # Method 2: Parse from context name (GKE contexts are typically gke_<project>_<zone>_<cluster>)
    if [[ "$context_name" =~ ^gke_([^_]+)_([^_]+)_(.+)$ ]]; then
        local project="${BASH_REMATCH[1]}"
        local zone_region="${BASH_REMATCH[2]}"
        local cluster_name="${BASH_REMATCH[3]}"
        echo "$cluster_name|$project|$zone_region"
        return 0
    fi

    # Method 3: Fallback to context name
    echo "$context_name (context name)|unknown|unknown"
    return 0
}

# Internet connectivity checks
check_internet_access() {
    print_step "Checking connectivity and access to required URLs..."
    local has_url_failures=false
    
    for url in "${REQUIRED_URLS[@]}"; do
        if curl --connect-timeout 10 --max-time 30 -s -I "$url" &> /dev/null; then
            print_success "$url accessible"
        else
            print_error "$url not accessible"
            add_failed_check "Internet Connectivity: Cannot access $url"
            has_url_failures=true
        fi
    done

    # Check container registries DNS resolution
    print_step "Checking access to container registries..."
    print_info "OneLens components pull images from these registries during installation."
    for registry in "${REQUIRED_CONTAINER_REGISTRIES[@]}"; do
        if nslookup "$registry" &> /dev/null 2>&1 || host "$registry" &> /dev/null 2>&1 || ping -c 1 -W 5 "$registry" &> /dev/null 2>&1; then
            print_success "$registry accessible"
        else
            print_error "$registry not accessible"
            add_failed_check "Internet Connectivity: Cannot resolve container registry $registry — pods will fail to pull images"
            has_url_failures=true
        fi
    done

    if [ "$has_url_failures" = false ]; then
        print_success "All required URLs and registries are accessible"
        return 0
    else
        print_error "Some URLs or registries are not accessible."
        echo "  Ensure your firewall or proxy allows outbound access to the URLs and registries listed above."
        echo "  For details, see: https://github.com/astuto-ai/onelens-installation-scripts/blob/master/docs/troubleshooting.md"
        return 1
    fi
}

# Kubectl cluster check for EKS
check_kubectl_cluster_eks() {
    print_step "Checking kubectl cluster configuration..."
    
    if ! check_command kubectl; then
        print_error "kubectl is not installed or not in PATH"
        add_failed_check "Kubectl: kubectl is not installed or not in PATH"
        return 1
    fi
    
    # Check if kubectl can connect to cluster
    if ! kubectl cluster-info &> /dev/null; then
        print_error "kubectl cannot connect to any cluster"
        echo "  Configure kubectl for your EKS cluster:"
        echo "  aws eks update-kubeconfig --name <cluster-name> --region <region>"
        add_failed_check "Kubectl: Cannot connect to cluster. Run: aws eks update-kubeconfig --name <cluster-name> --region <region>"
        return 1
    fi

    # Get cluster information
    local cluster_context
    cluster_context=$(kubectl config current-context)
    local cluster_endpoint
    cluster_endpoint=$(kubectl cluster-info | grep "Kubernetes control plane" | awk '{print $NF}' | sed 's/\x1b\[[0-9;]*m//g')

    # Try to get actual EKS cluster name and region
    local cluster_info
    cluster_info=$(get_eks_cluster_info "$cluster_endpoint" "$cluster_context")
    local actual_cluster_name="${cluster_info%|*}"
    local cluster_region="${cluster_info#*|}"

    print_success "kubectl is configured and connected to the cluster"
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

# Kubectl cluster check for AKS
check_kubectl_cluster_aks() {
    print_step "Checking kubectl cluster configuration..."

    if ! check_command kubectl; then
        print_error "kubectl is not installed or not in PATH"
        add_failed_check "Kubectl: kubectl is not installed or not in PATH"
        return 1
    fi

    # Check if kubectl can connect to cluster
    if ! kubectl cluster-info &> /dev/null; then
        print_error "kubectl cannot connect to any cluster"
        echo "  Configure kubectl for your AKS cluster:"
        echo "  az aks get-credentials --resource-group <rg> --name <cluster>"
        add_failed_check "Kubectl: Cannot connect to cluster. Run: az aks get-credentials --resource-group <rg> --name <cluster>"
        return 1
    fi
    
    # Get cluster information
    local cluster_context
    cluster_context=$(kubectl config current-context)
    local cluster_endpoint
    cluster_endpoint=$(kubectl cluster-info | grep "Kubernetes control plane" | awk '{print $NF}' | sed 's/\x1b\[[0-9;]*m//g')
    
    # Try to get actual AKS cluster info
    local cluster_info
    cluster_info=$(get_aks_cluster_info "$cluster_endpoint" "$cluster_context")
    local actual_cluster_name="${cluster_info%%|*}"
    local remaining="${cluster_info#*|}"
    local cluster_location="${remaining%%|*}"
    local resource_group="${remaining#*|}"
    
    print_success "kubectl is configured and connected"
    echo "Cluster Details:"
    echo "  Current Context: $cluster_context"
    echo "  Cluster Endpoint: $cluster_endpoint"
    echo "  AKS Cluster Name: $actual_cluster_name"
    echo "  Azure Location: $cluster_location"
    echo "  Resource Group: $resource_group"
    
    # Store cluster details for final confirmation
    add_confirmed_detail "AKS Cluster Name: $actual_cluster_name"
    add_confirmed_detail "Azure Location: $cluster_location"
    add_confirmed_detail "Resource Group: $resource_group"
    add_confirmed_detail "Kubectl Context: $cluster_context"
    add_confirmed_detail "Cluster Endpoint: $cluster_endpoint"
    return 0
}

# Kubectl cluster check for GKE
check_kubectl_cluster_gke() {
    print_step "Checking kubectl cluster configuration..."

    if ! check_command kubectl; then
        print_error "kubectl is not installed or not in PATH"
        add_failed_check "Kubectl: kubectl is not installed or not in PATH"
        return 1
    fi

    # Check if kubectl can connect to cluster
    if ! kubectl cluster-info &> /dev/null; then
        print_error "kubectl cannot connect to any cluster"
        echo "  Configure kubectl for your GKE cluster:"
        echo "  gcloud container clusters get-credentials <cluster> --zone <zone> --project <project>"
        add_failed_check "Kubectl: Cannot connect to cluster. Run: gcloud container clusters get-credentials <cluster> --zone <zone> --project <project>"
        return 1
    fi

    # Get cluster information
    local cluster_context
    cluster_context=$(kubectl config current-context)
    local cluster_endpoint
    cluster_endpoint=$(kubectl cluster-info | grep "Kubernetes control plane" | awk '{print $NF}' | sed 's/\x1b\[[0-9;]*m//g')

    # Try to get actual GKE cluster info
    local cluster_info
    cluster_info=$(get_gke_cluster_info "$cluster_endpoint" "$cluster_context")
    local actual_cluster_name="${cluster_info%%|*}"
    local remaining="${cluster_info#*|}"
    local project="${remaining%%|*}"
    local zone_region="${remaining#*|}"

    print_success "kubectl is configured and connected"
    echo "Cluster Details:"
    echo "  Current Context: $cluster_context"
    echo "  Cluster Endpoint: $cluster_endpoint"
    echo "  GKE Cluster Name: $actual_cluster_name"
    echo "  GCP Project: $project"
    echo "  Zone/Region: $zone_region"

    # Store cluster details for final confirmation
    add_confirmed_detail "GKE Cluster Name: $actual_cluster_name"
    add_confirmed_detail "GCP Project: $project"
    add_confirmed_detail "Zone/Region: $zone_region"
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
    helm_version=$(helm version --short 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | sed 's/v//')

    if [ -z "$helm_version" ]; then
        print_error "Could not determine Helm version"
        echo "  Run 'helm version' to check manually."
        add_failed_check "Helm: Could not determine version. Run 'helm version' to check manually."
        return 1
    fi

    if version_greater_equal "$helm_version" "$MIN_HELM_VERSION"; then
        print_success "Helm version $helm_version is compatible (>= $MIN_HELM_VERSION)"
        add_confirmed_detail "Helm Version: $helm_version"
        return 0
    else
        print_error "Helm version $helm_version is too old (minimum required: $MIN_HELM_VERSION)"
        echo "  Your version: $helm_version"
        echo "  Required: $MIN_HELM_VERSION or later"
        echo "  Upgrade: https://helm.sh/docs/intro/install/"
        add_failed_check "Helm: Version $helm_version is too old (minimum required: $MIN_HELM_VERSION)"
        return 1
    fi
}

# Kubernetes version check (generic for both EKS and AKS)
check_k8s_version() {
    local provider_name="$1"
    print_step "Checking $provider_name cluster version..."
    
    local k8s_version
    k8s_version=$(
        kubectl version -o json 2>/dev/null | \
            grep -o '"gitVersion": *"v[^"]*"' | \
            tail -1 | \
            cut -d'"' -f4 | \
            sed 's/^v//' | \
            grep -oE '^[0-9]+\.[0-9]+\.[0-9]+'
    )
    
    if [ -z "$k8s_version" ] || [ "$k8s_version" = "null" ]; then
        print_error "Could not determine Kubernetes version"
        add_failed_check "$provider_name Version: Could not determine Kubernetes version"
        return 1
    fi
    
    # Extract major.minor version
    local version_major_minor
    version_major_minor=$(echo "$k8s_version" | cut -d. -f1,2)
    
    if version_greater_equal "$version_major_minor" "$MIN_K8S_VERSION"; then
        print_success "$provider_name version $k8s_version is compatible (>= $MIN_K8S_VERSION)"
        add_confirmed_detail "$provider_name Version: $k8s_version"
        return 0
    else
        print_error "$provider_name version $k8s_version is too old (minimum required: $MIN_K8S_VERSION)"
        print_error "Please upgrade your $provider_name cluster to version $MIN_K8S_VERSION or later"
        add_failed_check "$provider_name Version: Version $k8s_version is too old (minimum required: $MIN_K8S_VERSION)"
        return 1
    fi
}

# EBS CSI driver check (AWS)
check_ebs_driver() {
    print_step "Checking EBS CSI driver installation..."
    
    # Check if EBS CSI driver is installed
    if ! kubectl get csidriver ebs.csi.aws.com &> /dev/null; then
        print_error "EBS CSI driver is not installed"
        echo ""
        echo "  The EBS CSI driver is required for OneLens to create persistent volumes for Prometheus data storage."
        echo ""
        echo "  Install using the EKS add-on (recommended):"
        echo "    aws eks create-addon --cluster-name <cluster-name> --addon-name aws-ebs-csi-driver"
        echo ""
        echo "  Or install using Helm:"
        echo "    helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver"
        echo "    helm install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver --namespace kube-system"
        echo ""
        echo "  Ensure the driver's service account has the AmazonEBSCSIDriverPolicy IAM policy attached."
        echo "  See: https://github.com/astuto-ai/onelens-installation-scripts/blob/master/docs/troubleshooting.md#ebs-csi-driver-not-found-aws"
        add_failed_check "EBS CSI Driver: Not installed. OneLens requires EBS CSI driver for persistent storage."
        return 1
    fi
    
    print_success "EBS CSI driver is installed"
    
    # Check EBS CSI driver controller pods (search all namespaces — driver may not be in kube-system)
    print_step "Checking EBS CSI driver controller pod status..."
    local controller_pods_output
    controller_pods_output=$(kubectl get pods --all-namespaces -l app=ebs-csi-controller --no-headers 2>/dev/null)

    if [ -z "$controller_pods_output" ]; then
        print_error "No EBS CSI driver controller pods found"
        add_failed_check "EBS CSI Driver: No controller pods found with label app=ebs-csi-controller"
        return 1
    fi

    # Check if all controller pods are ready (with --all-namespaces, READY is column $3 and STATUS is $4)
    local controller_not_ready
    controller_not_ready=$(echo "$controller_pods_output" | awk '{split($3,a,"/"); if(a[1] != a[2] || $4 != "Running") print $0}')

    if [ -n "$controller_not_ready" ]; then
        print_warning "Some EBS CSI driver controller pods are not ready"
        echo "Controller pods status:"
        kubectl get pods --all-namespaces -l app=ebs-csi-controller
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

    # Check EBS CSI driver node pods (search all namespaces)
    print_step "Checking EBS CSI driver node pod status..."
    local node_pods_output
    node_pods_output=$(kubectl get pods --all-namespaces -l app=ebs-csi-node --no-headers 2>/dev/null)

    if [ -z "$node_pods_output" ]; then
        print_warning "No EBS CSI driver node pods found"
        echo "This might indicate:"
        echo "- EBS CSI driver is not fully installed"
        echo "- DaemonSet is not deployed"
        echo "- Node selector issues"
        add_confirmed_detail "EBS CSI Driver: No node pods found (may affect volume mounting)"
    else
        # Check if all node pods are ready (with --all-namespaces, READY is column $3 and STATUS is $4)
        local node_not_ready
        node_not_ready=$(echo "$node_pods_output" | awk '{split($3,a,"/"); if(a[1] != a[2] || $4 != "Running") print $0}')

        if [ -n "$node_not_ready" ]; then
            print_warning "Some EBS CSI driver node pods are not ready"
            echo "Node pods status:"
            kubectl get pods --all-namespaces -l app=ebs-csi-node
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

# EFS CSI driver check (AWS) — informational, not required
check_efs_driver() {
    print_step "Checking EFS CSI driver (optional, for multi-AZ storage)..."

    if kubectl get csidriver efs.csi.aws.com &> /dev/null; then
        print_success "EFS CSI driver is available"
        echo "  You can use multi-AZ storage by setting EFS_FILESYSTEM_ID at install time."
        echo "  This eliminates PV availability zone scheduling issues (recommended for spot instances)."
        echo "  See: https://github.com/astuto-ai/onelens-installation-scripts#multi-az-storage"
        add_confirmed_detail "EFS CSI Driver: Available (multi-AZ storage option)"
    else
        print_info "EFS CSI driver not found (optional)"
        echo "  OneLens will use EBS (default). If you need multi-AZ storage to avoid"
        echo "  AZ-lock scheduling issues (common with spot instances), install the EFS CSI driver:"
        echo "    aws eks create-addon --cluster-name <cluster-name> --addon-name aws-efs-csi-driver"
        echo "  See: https://github.com/astuto-ai/onelens-installation-scripts#multi-az-storage"
        add_confirmed_detail "EFS CSI Driver: Not installed (optional — EBS will be used)"
    fi
}

# Azure Disk CSI driver check (Azure)
check_azure_disk_driver() {
    print_step "Checking Azure Disk CSI driver installation..."
    
    # Check if Azure Disk CSI driver is installed
    if ! kubectl get csidriver disk.csi.azure.com &> /dev/null; then
        print_error "Azure Disk CSI driver is not installed"
        echo ""
        echo "  The Azure Disk CSI driver is required for OneLens to create persistent volumes for Prometheus data storage."
        echo "  It is typically pre-installed on AKS clusters. If missing, enable it via Azure CLI:"
        echo ""
        echo "    az aks update -g <resource-group> -n <cluster-name> --enable-disk-driver"
        echo ""
        echo "  See: https://github.com/astuto-ai/onelens-installation-scripts/blob/master/docs/troubleshooting.md"
        add_failed_check "Azure Disk CSI Driver: Not installed. OneLens requires Azure Disk CSI driver for persistent storage."
        return 1
    fi
    
    print_success "Azure Disk CSI driver is installed"
    
    # Check Azure Disk CSI driver controller pods
    print_step "Checking Azure Disk CSI driver controller pod status..."
    local controller_pods_output
    controller_pods_output=$(kubectl get pods -n kube-system -l app=csi-azuredisk-controller --no-headers 2>/dev/null)
    
    if [ -z "$controller_pods_output" ]; then
        # Try alternative label
        controller_pods_output=$(kubectl get pods -n kube-system | grep "csi-azuredisk-controller" | head -5)
    fi
    
    if [ -z "$controller_pods_output" ]; then
        print_warning "No Azure Disk CSI driver controller pods found"
        echo "This might be normal for some AKS configurations."
        echo "Checking if storage classes are available..."
        
        # Check if default storage class exists
        if kubectl get storageclass | grep -q "default"; then
            print_success "Default storage class is available"
            add_confirmed_detail "Azure Disk CSI Driver: Storage class available"
        else
            add_failed_check "Azure Disk CSI Driver: No controller pods or storage class found"
            return 1
        fi
    else
        # Check if controller pods are ready
        local controller_not_ready
        controller_not_ready=$(echo "$controller_pods_output" | awk '{split($2,a,"/"); if(a[1] != a[2] || $3 != "Running") print $0}')
        
        if [ -n "$controller_not_ready" ]; then
            print_warning "Some Azure Disk CSI driver controller pods are not ready"
            echo "Controller pods status:"
            kubectl get pods -n kube-system | grep "csi-azuredisk"
            add_confirmed_detail "Azure Disk CSI Driver: Controller pods have issues (see warnings above)"
        else
            print_success "Azure Disk CSI driver controller pods are running and ready"
            add_confirmed_detail "Azure Disk CSI Driver: Controller pods are healthy"
        fi
    fi
    
    # Check Azure Disk CSI driver node pods
    print_step "Checking Azure Disk CSI driver node pod status..."
    local node_pods_output
    node_pods_output=$(kubectl get pods -n kube-system -l app=csi-azuredisk-node --no-headers 2>/dev/null)
    
    if [ -z "$node_pods_output" ]; then
        # Try alternative approach
        node_pods_output=$(kubectl get pods -n kube-system | grep "csi-azuredisk-node" 2>/dev/null)
    fi
    
    if [ -z "$node_pods_output" ]; then
        print_warning "No Azure Disk CSI driver node pods found explicitly"
        echo "This might be normal for managed AKS clusters."
    else
        local node_not_ready
        node_not_ready=$(echo "$node_pods_output" | awk '{split($2,a,"/"); if(a[1] != a[2] || $3 != "Running") print $0}')
        
        if [ -n "$node_not_ready" ]; then
            print_warning "Some Azure Disk CSI driver node pods are not ready"
            echo "Node pods status:"
            kubectl get pods -n kube-system | grep "csi-azuredisk-node"
            add_confirmed_detail "Azure Disk CSI Driver: Node pods have issues (see warnings above)"
        else
            print_success "Azure Disk CSI driver node pods are running and ready"
            add_confirmed_detail "Azure Disk CSI Driver: Node pods are healthy"
        fi
    fi
    
    # Verify a storage class exists for Azure Disk
    print_step "Checking Azure Disk storage classes..."
    local storage_classes
    storage_classes=$(kubectl get storageclass -o jsonpath='{.items[*].provisioner}' 2>/dev/null)
    
    if [[ "$storage_classes" =~ disk.csi.azure.com ]] || [[ "$storage_classes" =~ kubernetes.io/azure-disk ]]; then
        print_success "Azure Disk storage class is available"
        add_confirmed_detail "Azure Disk CSI Driver: Storage class configured"
    else
        print_warning "No Azure Disk storage class found"
        echo "Available storage classes:"
        kubectl get storageclass
    fi
    
    return 0
}

# Azure Files CSI driver check (Azure) — informational, not required
check_azure_files_driver() {
    print_step "Checking Azure Files CSI driver (optional, for multi-AZ storage)..."

    if kubectl get csidriver file.csi.azure.com &> /dev/null; then
        print_success "Azure Files CSI driver is available"
        echo "  You can use multi-AZ storage by setting AZURE_FILES_ENABLED=true at install time."
        echo "  This eliminates PV availability zone scheduling issues (recommended for spot instances)."
        echo "  See: https://github.com/astuto-ai/onelens-installation-scripts#multi-az-storage"
        add_confirmed_detail "Azure Files CSI Driver: Available (multi-AZ storage option)"
    else
        print_info "Azure Files CSI driver not found (optional)"
        echo "  OneLens will use Azure Disk (default). If you need multi-AZ storage to avoid"
        echo "  AZ-lock scheduling issues (common with spot instances), enable the Azure Files CSI driver:"
        echo "    az aks update -g <resource-group> -n <cluster-name> --enable-file-driver"
        echo "  See: https://github.com/astuto-ai/onelens-installation-scripts#multi-az-storage"
        add_confirmed_detail "Azure Files CSI Driver: Not installed (optional — Azure Disk will be used)"
    fi
}

# GKE Persistent Disk CSI driver check (GKE)
check_gke_pd_driver() {
    print_step "Checking GKE Persistent Disk CSI driver installation..."

    # Check if PD CSI driver is installed
    if ! kubectl get csidriver pd.csi.storage.gke.io &> /dev/null; then
        # PD CSI driver is typically pre-installed on GKE; check storage classes as fallback
        local storage_classes
        storage_classes=$(kubectl get storageclass -o jsonpath='{.items[*].provisioner}' 2>/dev/null)

        if [[ "$storage_classes" =~ pd.csi.storage.gke.io ]]; then
            print_success "GKE Persistent Disk storage class is available"
            add_confirmed_detail "GKE PD CSI Driver: Storage class configured"
        else
            print_error "GKE Persistent Disk CSI driver is not installed"
            echo ""
            echo "  The GKE Persistent Disk CSI driver is required for OneLens to create persistent volumes for Prometheus data storage."
            echo "  For GKE clusters, the PD CSI driver is typically pre-installed."
            echo "  If missing, enable it via gcloud:"
            echo ""
            echo "    gcloud container clusters update <cluster> --zone <zone> --update-addons=GcePersistentDiskCsiDriver=ENABLED"
            echo ""
            add_failed_check "GKE PD CSI Driver: Not installed. OneLens requires the Persistent Disk CSI driver for persistent storage."
            return 1
        fi

        return 0
    fi

    print_success "GKE Persistent Disk CSI driver is installed"

    # Check PD CSI driver controller pods
    print_step "Checking GKE PD CSI driver controller pod status..."
    local controller_pods_output
    controller_pods_output=$(kubectl get pods --all-namespaces -l app=gcp-compute-persistent-disk-csi-driver --no-headers 2>/dev/null)

    if [ -z "$controller_pods_output" ]; then
        # Try kube-system with name pattern as fallback (single-namespace output)
        local fallback_pods
        fallback_pods=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | grep "pdcsi-node\|csi-gce-pd")

        if [ -z "$fallback_pods" ]; then
            print_warning "No GKE PD CSI driver pods found explicitly"
            echo "This might be normal for managed GKE clusters."

            # Check if a storage class exists
            if kubectl get storageclass | grep -q "pd.csi.storage.gke.io"; then
                print_success "GKE PD storage class is available"
                add_confirmed_detail "GKE PD CSI Driver: Storage class available"
            else
                add_confirmed_detail "GKE PD CSI Driver: No pods or storage class found"
            fi
        else
            # Single-namespace output: READY is column $2 and STATUS is $3
            local not_ready
            not_ready=$(echo "$fallback_pods" | awk '{split($2,a,"/"); if(a[1] != a[2] || $3 != "Running") print $0}')

            if [ -n "$not_ready" ]; then
                print_warning "Some GKE PD CSI driver pods are not ready"
                echo "Pod status:"
                echo "$fallback_pods"
                add_confirmed_detail "GKE PD CSI Driver: Pods have issues (see warnings above)"
            else
                print_success "GKE PD CSI driver pods are running and ready"
                add_confirmed_detail "GKE PD CSI Driver: Pods are healthy"
            fi
        fi
    else
        # --all-namespaces output: READY is column $3 and STATUS is $4
        local not_ready
        not_ready=$(echo "$controller_pods_output" | awk '{split($3,a,"/"); if(a[1] != a[2] || $4 != "Running") print $0}')

        if [ -n "$not_ready" ]; then
            print_warning "Some GKE PD CSI driver pods are not ready"
            echo "Pod status:"
            echo "$controller_pods_output"
            add_confirmed_detail "GKE PD CSI Driver: Pods have issues (see warnings above)"
        else
            print_success "GKE PD CSI driver pods are running and ready"
            add_confirmed_detail "GKE PD CSI Driver: Pods are healthy"
        fi
    fi

    # Verify a storage class with PD CSI provisioner exists
    print_step "Checking GKE Persistent Disk storage classes..."
    local storage_classes
    storage_classes=$(kubectl get storageclass -o jsonpath='{.items[*].provisioner}' 2>/dev/null)

    if [[ "$storage_classes" =~ pd.csi.storage.gke.io ]]; then
        print_success "GKE Persistent Disk storage class is available"
        add_confirmed_detail "GKE PD CSI Driver: Storage class configured"
    else
        print_warning "No GKE Persistent Disk storage class found"
        echo "Available storage classes:"
        kubectl get storageclass
    fi

    return 0
}

# GKE Filestore CSI driver check (GKE) — informational, not required
check_gke_filestore_driver() {
    print_step "Checking GKE Filestore CSI driver (optional, for multi-AZ storage)..."

    if kubectl get csidriver filestore.csi.storage.gke.io &> /dev/null; then
        print_success "GKE Filestore CSI driver is available"
        echo "  You can use Filestore for multi-AZ shared storage if needed."
        echo "  See: https://cloud.google.com/kubernetes-engine/docs/how-to/persistent-volumes/filestore-csi-driver"
        add_confirmed_detail "GKE Filestore CSI Driver: Available (multi-AZ storage option)"
    else
        print_info "GKE Filestore CSI driver not found (optional)"
        echo "  OneLens will use Persistent Disk (default). If you need multi-AZ storage,"
        echo "  enable the Filestore CSI driver:"
        echo "    gcloud container clusters update <cluster> --zone <zone> --update-addons=GcpFilestoreCsiDriver=ENABLED"
        add_confirmed_detail "GKE Filestore CSI Driver: Not installed (optional — PD will be used)"
    fi
}

# Print summary for AWS
print_summary_aws() {
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
        if [[ "$detail" =~ ^EBS|^EFS ]]; then
            echo "  $detail"
        fi
    done
}

# Print summary for Azure
print_summary_azure() {
    echo ""
    echo "KUBERNETES CLUSTER:"
    echo "-------------------"
    for detail in "${CONFIRMED_DETAILS[@]}"; do
        if [[ "$detail" =~ ^AKS|^Kubectl|^Cluster|^Azure\ Location|^Resource\ Group ]] && [[ ! "$detail" =~ ^AKS\ Version ]]; then
            echo "  $detail"
        fi
    done

    echo ""
    echo "TOOLS & VERSIONS:"
    echo "-----------------"
    for detail in "${CONFIRMED_DETAILS[@]}"; do
        if [[ "$detail" =~ ^Helm|^AKS\ Version ]]; then
            echo "  $detail"
        fi
    done

    echo ""
    echo "STORAGE:"
    echo "--------"
    for detail in "${CONFIRMED_DETAILS[@]}"; do
        if [[ "$detail" =~ ^Azure\ Disk|^Azure\ Files ]]; then
            echo "  $detail"
        fi
    done
}

# Print summary for GKE
print_summary_gke() {
    echo ""
    echo "KUBERNETES CLUSTER:"
    echo "-------------------"
    for detail in "${CONFIRMED_DETAILS[@]}"; do
        if [[ "$detail" =~ ^GKE\ Cluster|^Kubectl|^Cluster|^GCP\ Project|^Zone/Region ]] && [[ ! "$detail" =~ ^GKE\ Version ]]; then
            echo "  $detail"
        fi
    done

    echo ""
    echo "TOOLS & VERSIONS:"
    echo "-----------------"
    for detail in "${CONFIRMED_DETAILS[@]}"; do
        if [[ "$detail" =~ ^Helm|^GKE\ Version ]]; then
            echo "  $detail"
        fi
    done

    echo ""
    echo "STORAGE:"
    echo "--------"
    for detail in "${CONFIRMED_DETAILS[@]}"; do
        if [[ "$detail" =~ ^GKE\ PD|^GKE\ Filestore ]]; then
            echo "  $detail"
        fi
    done
}

# Global variables for check results
CHECKS_PASSED=0
TOTAL_CHECKS=5

# Main execution for AWS/EKS
run_aws_checks() {
    CHECKS_PASSED=0
    TOTAL_CHECKS=5

    echo ""
    print_header "1/5 - Internet Connectivity Check"
    if check_internet_access; then
        ((CHECKS_PASSED++))
    fi

    echo ""
    print_header "2/5 - Kubectl Cluster Configuration Check"
    if check_kubectl_cluster_eks; then
        ((CHECKS_PASSED++))
    fi

    echo ""
    print_header "3/5 - Helm Version Check"
    if check_helm_version; then
        ((CHECKS_PASSED++))
    fi

    echo ""
    print_header "4/5 - EKS Version Check"
    if check_k8s_version "EKS"; then
        ((CHECKS_PASSED++))
    fi

    echo ""
    print_header "5/5 - Storage CSI Driver Check"
    if check_ebs_driver; then
        ((CHECKS_PASSED++))
    fi
    check_efs_driver
}

# Main execution for Azure/AKS
run_azure_checks() {
    CHECKS_PASSED=0
    TOTAL_CHECKS=5

    echo ""
    print_header "1/5 - Internet Connectivity Check"
    if check_internet_access; then
        ((CHECKS_PASSED++))
    fi

    echo ""
    print_header "2/5 - Kubectl Cluster Configuration Check"
    if check_kubectl_cluster_aks; then
        ((CHECKS_PASSED++))
    fi

    echo ""
    print_header "3/5 - Helm Version Check"
    if check_helm_version; then
        ((CHECKS_PASSED++))
    fi

    echo ""
    print_header "4/5 - AKS Version Check"
    if check_k8s_version "AKS"; then
        ((CHECKS_PASSED++))
    fi

    echo ""
    print_header "5/5 - Storage CSI Driver Check"
    if check_azure_disk_driver; then
        ((CHECKS_PASSED++))
    fi
    check_azure_files_driver
}

# Main execution for GCP/GKE
run_gke_checks() {
    CHECKS_PASSED=0
    TOTAL_CHECKS=5

    echo ""
    print_header "1/5 - Internet Connectivity Check"
    if check_internet_access; then
        ((CHECKS_PASSED++))
    fi

    echo ""
    print_header "2/5 - Kubectl Cluster Configuration Check"
    if check_kubectl_cluster_gke; then
        ((CHECKS_PASSED++))
    fi

    echo ""
    print_header "3/5 - Helm Version Check"
    if check_helm_version; then
        ((CHECKS_PASSED++))
    fi

    echo ""
    print_header "4/5 - GKE Version Check"
    if check_k8s_version "GKE"; then
        ((CHECKS_PASSED++))
    fi

    echo ""
    print_header "5/5 - Storage CSI Driver Check"
    if check_gke_pd_driver; then
        ((CHECKS_PASSED++))
    fi
    check_gke_filestore_driver
}

# Main execution
main() {
    print_header "OneLens Agent Pre-requisite Checker"
    echo "This script will validate all prerequisites for OneLens Agent installation."
    echo "Supports AWS EKS, Azure AKS, and GCP GKE clusters."
    echo ""
    
    # First detect cloud provider
    print_header "Cloud Provider Detection"
    if ! detect_cloud_provider; then
        print_error "Could not detect cloud provider. Please ensure kubectl is configured."
        exit 1
    fi
    
    echo ""
    echo "Running prerequisite checks for $(echo "$CLOUD_PROVIDER" | tr '[:lower:]' '[:upper:]')..."
    
    # Check required tools after detecting provider
    check_required_tools
    
    # Run appropriate checks based on cloud provider
    if [ "$CLOUD_PROVIDER" = "aws" ]; then
        run_aws_checks
    elif [ "$CLOUD_PROVIDER" = "azure" ]; then
        run_azure_checks
    elif [ "$CLOUD_PROVIDER" = "gke" ]; then
        run_gke_checks
    else
        print_error "Unsupported cloud provider: $CLOUD_PROVIDER"
        exit 1
    fi
    
    # Summary
    echo ""
    print_header "Pre-requisite Check Summary"
    
    echo ""
    echo "PREREQUISITE CHECK RESULTS:"
    echo "============================"
    echo "Cloud Provider: $(echo "$CLOUD_PROVIDER" | tr '[:lower:]' '[:upper:]')"
    echo "Status: $CHECKS_PASSED/$TOTAL_CHECKS checks passed"
    echo ""
    
    # Show successful configuration details
    if [ ${#CONFIRMED_DETAILS[@]} -gt 0 ]; then
        echo ""
        echo "⚠️  PLEASE REVIEW THE DETECTED CONFIGURATION BELOW BEFORE PROCEEDING ⚠️"
        echo ""
        echo "PASSED CHECKS - DETECTED CONFIGURATION:"
        echo "======================================="
        
        if [ "$CLOUD_PROVIDER" = "aws" ]; then
            print_summary_aws
        elif [ "$CLOUD_PROVIDER" = "azure" ]; then
            print_summary_azure
        elif [ "$CLOUD_PROVIDER" = "gke" ]; then
            print_summary_gke
        fi
        
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
    if [ "$CHECKS_PASSED" -eq "$TOTAL_CHECKS" ]; then
        echo ""
        print_success "All checks passed. You are ready to install OneLens."
        echo ""
        echo "Go to the OneLens console, copy the helm install command for your cluster, and run it."
    else
        echo ""
        print_error "Some checks failed. Fix the issues listed above and re-run this script."
        echo ""
        echo "Troubleshooting: https://github.com/astuto-ai/onelens-installation-scripts/blob/master/docs/troubleshooting.md"
        exit 1
    fi
}

# Script entry point
# Handle both direct execution and piped execution (curl | bash)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] || [[ "${BASH_SOURCE[0]}" == "" ]]; then
    main "$@"
fi
