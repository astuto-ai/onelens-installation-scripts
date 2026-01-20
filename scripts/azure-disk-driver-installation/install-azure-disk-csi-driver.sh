#!/bin/bash

# ==============================================================================
# Azure Disk CSI Driver Installation Script
# ==============================================================================
#
# This script automatically enables/installs Azure Disk CSI Driver for your 
# AKS cluster.
#
# USAGE:
#   # Run directly from internet:
#   curl -sSL https://raw.githubusercontent.com/astuto-ai/onelens-installation-scripts/release/v1.3.0-azure-disk-driver/scripts/azure-disk-driver-installation/install-azure-disk-csi-driver.sh | bash -s -- CLUSTER_NAME RESOURCE_GROUP
#
#   # Or download and run:
#   curl -sSL https://raw.githubusercontent.com/astuto-ai/onelens-installation-scripts/release/v1.3.0-azure-disk-driver/scripts/azure-disk-driver-installation/install-azure-disk-csi-driver.sh -o install-azure-disk-csi-driver.sh
#   chmod +x install-azure-disk-csi-driver.sh
#   ./install-azure-disk-csi-driver.sh CLUSTER_NAME RESOURCE_GROUP
#
# EXAMPLES:
#   ./install-azure-disk-csi-driver.sh my-aks-cluster my-resource-group
#   ./install-azure-disk-csi-driver.sh production-aks prod-rg
#
# PREREQUISITES:
#   - Azure CLI installed and logged in
#   - AKS cluster must exist
#   - Appropriate permissions for AKS operations
#
# ==============================================================================

# Script version
readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="install-azure-disk-csi-driver"

# Global variables
CLUSTER_NAME=""
RESOURCE_GROUP=""
SUBSCRIPTION_ID=""
START_TIME=""
INSTALL_METHOD=""

# ==============================================================================
# Utility Functions
# ==============================================================================

log() {
    local level="$1"
    shift
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case "$level" in
        "INFO")    echo "[INFO]    [$timestamp] $*" ;;
        "WARN")    echo "[WARN]    [$timestamp] $*" ;;
        "ERROR")   echo "[ERROR]   [$timestamp] $*" >&2 ;;
        "SUCCESS") echo "[SUCCESS] [$timestamp] $*" ;;
        "DEBUG")   [[ "${DEBUG:-}" == "true" ]] && echo "[DEBUG]   [$timestamp] $*" ;;
    esac
}

show_banner() {
    cat << 'BANNER_EOF'
╔══════════════════════════════════════════════════════════════════════════════╗
║                    Azure Disk CSI Driver Installer                          ║
║                                                                              ║
║  This script will enable/install Azure Disk CSI Driver for your             ║
║  AKS cluster to support persistent volume claims.                           ║
╚══════════════════════════════════════════════════════════════════════════════╝
BANNER_EOF
    log "INFO" "Script version: $SCRIPT_VERSION"
    echo
}

show_usage() {
    cat << USAGE_EOF
Usage: $0 CLUSTER_NAME RESOURCE_GROUP [OPTIONS]

Arguments:
  CLUSTER_NAME      Name of your AKS cluster
  RESOURCE_GROUP    Azure resource group containing the AKS cluster

Options:
  --subscription    Azure subscription ID (optional, uses default if not provided)
  --helm            Force Helm installation method instead of AKS add-on

Examples:
  $0 my-aks-cluster my-resource-group
  $0 production-aks prod-rg --subscription 12345678-1234-1234-1234-123456789012

Prerequisites:
  - Azure CLI installed and logged in (az login)
  - AKS cluster must exist
  - Appropriate permissions for AKS update operations

Environment Variables:
  DEBUG=true        Enable debug logging

For more information, visit: https://github.com/astuto-ai/onelens-installation-scripts
USAGE_EOF
}

check_prerequisites() {
    log "INFO" "Checking prerequisites..."
    
    local missing_deps=()
    
    # Check Azure CLI
    if ! command -v az >/dev/null 2>&1; then
        missing_deps+=("azure-cli")
    fi
    
    # Check kubectl
    if ! command -v kubectl >/dev/null 2>&1; then
        missing_deps+=("kubectl")
    fi
    
    # Check helm (optional, for Helm installation method)
    if ! command -v helm >/dev/null 2>&1; then
        log "WARN" "Helm is not installed. Will use AKS add-on method only."
    fi
    
    if [[ ${#missing_deps[@]} -ne 0 ]]; then
        log "ERROR" "Missing required dependencies: ${missing_deps[*]}"
        log "ERROR" "Please install the missing dependencies and try again"
        log "INFO" "Install Azure CLI: https://docs.microsoft.com/cli/azure/install-azure-cli"
        exit 1
    fi
    
    # Check Azure CLI login
    if ! az account show >/dev/null 2>&1; then
        log "ERROR" "Azure CLI is not logged in"
        log "ERROR" "Please run 'az login' to authenticate"
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
    
    if [[ -z "$RESOURCE_GROUP" ]]; then
        log "ERROR" "Resource group is required"
        show_usage
        exit 1
    fi
    
    # Get subscription ID if not provided
    if [[ -z "$SUBSCRIPTION_ID" ]]; then
        SUBSCRIPTION_ID=$(az account show --query 'id' -o tsv)
        log "INFO" "Using current subscription: $SUBSCRIPTION_ID"
    fi
    
    log "INFO" "Cluster: $CLUSTER_NAME"
    log "INFO" "Resource Group: $RESOURCE_GROUP"
    log "INFO" "Subscription: $SUBSCRIPTION_ID"
}

verify_cluster_exists() {
    log "INFO" "Verifying AKS cluster exists..."
    
    # Set subscription
    az account set --subscription "$SUBSCRIPTION_ID" 2>/dev/null
    
    # Check if cluster exists
    if ! az aks show --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
        log "ERROR" "AKS cluster '$CLUSTER_NAME' not found in resource group '$RESOURCE_GROUP'"
        log "ERROR" "Please verify the cluster name and resource group are correct"
        exit 1
    fi
    
    # Get cluster info
    local cluster_location
    cluster_location=$(az aks show --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" --query 'location' -o tsv)
    local k8s_version
    k8s_version=$(az aks show --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" --query 'kubernetesVersion' -o tsv)
    
    log "SUCCESS" "AKS cluster found"
    log "INFO" "Location: $cluster_location"
    log "INFO" "Kubernetes Version: $k8s_version"
}

check_csi_driver_status() {
    log "INFO" "Checking current Azure Disk CSI driver status..."
    
    # Check if disk driver is enabled via AKS
    local disk_driver_enabled
    disk_driver_enabled=$(az aks show --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" \
        --query 'storageProfile.diskCsiDriver.enabled' -o tsv 2>/dev/null)
    
    if [[ "$disk_driver_enabled" == "true" ]]; then
        log "SUCCESS" "Azure Disk CSI driver is already enabled via AKS add-on"
        return 0
    fi
    
    # Check if CSI driver is installed via kubectl
    if kubectl get csidriver disk.csi.azure.com >/dev/null 2>&1; then
        log "SUCCESS" "Azure Disk CSI driver is already installed (detected via kubectl)"
        return 0
    fi
    
    log "INFO" "Azure Disk CSI driver is not currently enabled/installed"
    return 1
}

enable_disk_driver_addon() {
    log "INFO" "Enabling Azure Disk CSI driver via AKS add-on..."
    log "INFO" "This may take a few minutes..."
    
    if az aks update \
        --name "$CLUSTER_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --enable-disk-driver \
        --only-show-errors 2>&1; then
        
        log "SUCCESS" "Azure Disk CSI driver enabled successfully via AKS add-on"
        INSTALL_METHOD="aks-addon"
        return 0
    else
        log "ERROR" "Failed to enable Azure Disk CSI driver via AKS add-on"
        return 1
    fi
}

install_via_helm() {
    log "INFO" "Installing Azure Disk CSI driver via Helm..."
    
    if ! command -v helm >/dev/null 2>&1; then
        log "ERROR" "Helm is required for this installation method"
        return 1
    fi
    
    # Add the Helm repo
    log "INFO" "Adding Azure Disk CSI driver Helm repository..."
    if ! helm repo add azuredisk-csi-driver https://raw.githubusercontent.com/kubernetes-sigs/azuredisk-csi-driver/master/charts 2>/dev/null; then
        log "WARN" "Helm repo may already exist, continuing..."
    fi
    
    helm repo update >/dev/null 2>&1
    
    # Install or upgrade the driver
    log "INFO" "Installing Azure Disk CSI driver..."
    if helm upgrade --install azuredisk-csi-driver azuredisk-csi-driver/azuredisk-csi-driver \
        --namespace kube-system \
        --set controller.runOnControlPlane=false \
        --wait \
        --timeout 10m; then
        
        log "SUCCESS" "Azure Disk CSI driver installed successfully via Helm"
        INSTALL_METHOD="helm"
        return 0
    else
        log "ERROR" "Failed to install Azure Disk CSI driver via Helm"
        return 1
    fi
}

verify_installation() {
    log "INFO" "Verifying Azure Disk CSI driver installation..."
    
    local max_retries=12
    local retry_interval=10
    local retry_count=0
    
    while [[ $retry_count -lt $max_retries ]]; do
        # Check CSI driver
        if kubectl get csidriver disk.csi.azure.com >/dev/null 2>&1; then
            log "SUCCESS" "CSI driver 'disk.csi.azure.com' is registered"
            
            # Check controller pods
            local controller_pods
            controller_pods=$(kubectl get pods -n kube-system -l app=csi-azuredisk-controller --no-headers 2>/dev/null | grep -c "Running" || echo "0")
            
            # Check node pods
            local node_pods
            node_pods=$(kubectl get pods -n kube-system -l app=csi-azuredisk-node --no-headers 2>/dev/null | grep -c "Running" || echo "0")
            
            if [[ "$controller_pods" -gt 0 ]] || [[ "$node_pods" -gt 0 ]]; then
                log "SUCCESS" "CSI driver pods are running"
                log "INFO" "Controller pods running: $controller_pods"
                log "INFO" "Node pods running: $node_pods"
                return 0
            fi
            
            # For AKS managed CSI, pods might have different labels
            # Just verify the driver is registered
            if [[ "$INSTALL_METHOD" == "aks-addon" ]]; then
                log "SUCCESS" "Azure Disk CSI driver is enabled (AKS managed)"
                return 0
            fi
        fi
        
        retry_count=$((retry_count + 1))
        if [[ $retry_count -lt $max_retries ]]; then
            log "INFO" "Waiting for CSI driver to be ready... (attempt $retry_count/$max_retries)"
            sleep $retry_interval
        fi
    done
    
    log "WARN" "Could not fully verify CSI driver installation, but it may still be starting up"
    return 0
}

create_storage_class() {
    log "INFO" "Checking for Azure Disk storage classes..."
    
    # Check if managed-csi storage class exists
    if kubectl get storageclass managed-csi >/dev/null 2>&1; then
        log "SUCCESS" "Storage class 'managed-csi' already exists"
        return 0
    fi
    
    # Check if any Azure Disk storage class exists
    local azure_sc
    azure_sc=$(kubectl get storageclass -o jsonpath='{.items[?(@.provisioner=="disk.csi.azure.com")].metadata.name}' 2>/dev/null)
    
    if [[ -n "$azure_sc" ]]; then
        log "SUCCESS" "Azure Disk storage class found: $azure_sc"
        return 0
    fi
    
    # Create a default managed-csi storage class
    log "INFO" "Creating 'managed-csi' storage class..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: managed-csi
provisioner: disk.csi.azure.com
parameters:
  skuName: StandardSSD_LRS
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF
    
    if [[ $? -eq 0 ]]; then
        log "SUCCESS" "Storage class 'managed-csi' created successfully"
    else
        log "WARN" "Failed to create storage class, but CSI driver is installed"
    fi
}

show_results() {
    echo
    log "SUCCESS" "Azure Disk CSI Driver installation completed!"
    echo "╔══════════════════════════════════════════════════════════════════════════════╗"
    echo "║                          INSTALLATION RESULTS                               ║"
    echo "╚══════════════════════════════════════════════════════════════════════════════╝"
    echo
    echo "Cluster:         $CLUSTER_NAME"
    echo "Resource Group:  $RESOURCE_GROUP"
    echo "Install Method:  ${INSTALL_METHOD:-aks-addon}"
    echo
    echo "CSI Driver:      disk.csi.azure.com"
    echo
    
    # Show storage classes
    echo "Available Storage Classes:"
    kubectl get storageclass -o custom-columns=NAME:.metadata.name,PROVISIONER:.provisioner,DEFAULT:.metadata.annotations."storageclass\.kubernetes\.io/is-default-class" 2>/dev/null | head -10
    echo
    
    echo "Next Steps:"
    echo "1. You can now create PersistentVolumeClaims using Azure Disk storage"
    echo "2. Use 'managed-csi' or 'default' storage class for your PVCs"
    echo
    echo "Example PVC:"
    echo "---"
    echo "apiVersion: v1"
    echo "kind: PersistentVolumeClaim"
    echo "metadata:"
    echo "  name: my-pvc"
    echo "spec:"
    echo "  accessModes:"
    echo "    - ReadWriteOnce"
    echo "  storageClassName: managed-csi"
    echo "  resources:"
    echo "    requests:"
    echo "      storage: 10Gi"
    echo
}

cleanup() {
    local exit_code=$?
    
    if [[ $exit_code -ne 0 ]]; then
        echo
        log "ERROR" "Script execution failed"
        log "INFO" "For troubleshooting help, check:"
        log "INFO" "- Azure Portal for AKS cluster status"
        log "INFO" "- kubectl get pods -n kube-system | grep csi"
        log "INFO" "- kubectl describe csidriver disk.csi.azure.com"
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
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --subscription)
                SUBSCRIPTION_ID="$2"
                shift 2
                ;;
            --helm)
                FORCE_HELM=true
                shift
                ;;
            --help|-h)
                show_banner
                show_usage
                exit 0
                ;;
            *)
                if [[ -z "$CLUSTER_NAME" ]]; then
                    CLUSTER_NAME="$1"
                elif [[ -z "$RESOURCE_GROUP" ]]; then
                    RESOURCE_GROUP="$1"
                else
                    log "WARN" "Unknown argument: $1"
                fi
                shift
                ;;
        esac
    done
    
    if [[ -z "$CLUSTER_NAME" || -z "$RESOURCE_GROUP" ]]; then
        show_banner
        show_usage
        exit 1
    fi
    
    # Main execution flow
    show_banner
    check_prerequisites
    validate_inputs
    verify_cluster_exists
    
    # Get kubeconfig for the cluster
    log "INFO" "Getting AKS credentials..."
    az aks get-credentials --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" --overwrite-existing >/dev/null 2>&1
    
    # Check if already installed
    if check_csi_driver_status; then
        log "INFO" "Azure Disk CSI driver is already available"
        create_storage_class
        show_results
        exit 0
    fi
    
    # Try to enable via AKS add-on first (recommended method)
    if [[ "${FORCE_HELM:-}" != "true" ]]; then
        if enable_disk_driver_addon; then
            verify_installation
            create_storage_class
            show_results
            exit 0
        fi
        log "WARN" "AKS add-on method failed, trying Helm installation..."
    fi
    
    # Fallback to Helm installation
    if install_via_helm; then
        verify_installation
        create_storage_class
        show_results
        exit 0
    fi
    
    log "ERROR" "Failed to install Azure Disk CSI driver"
    log "INFO" "Please try manual installation or check Azure Portal for cluster status"
    exit 1
}

# Run main function with all arguments
main "$@"
