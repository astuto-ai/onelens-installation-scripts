# Azure Disk CSI Driver Installer

Enterprise-ready shell script that automatically enables/installs Azure Disk CSI Driver for your AKS cluster to support persistent volume claims.

## 🚀 Quick Start

### Method 1: Run directly from the internet
```bash
curl -sSL https://raw.githubusercontent.com/astuto-ai/onelens-installation-scripts/release/v1.3.0-azure-disk-driver/scripts/azure-disk-driver-installation/install-azure-disk-csi-driver.sh | bash -s -- my-aks-cluster my-resource-group
```

### Method 2: Download and run locally
```bash
# Download the script
curl -sSL https://raw.githubusercontent.com/astuto-ai/onelens-installation-scripts/release/v1.3.0-azure-disk-driver/scripts/azure-disk-driver-installation/install-azure-disk-csi-driver.sh -o install-azure-disk-csi-driver.sh

# Make it executable
chmod +x install-azure-disk-csi-driver.sh

# Run it
./install-azure-disk-csi-driver.sh my-aks-cluster my-resource-group
```

### Method 3: Enable via Azure CLI manually
```bash
# Enable the disk driver add-on for your AKS cluster
az aks update \
  --name my-aks-cluster \
  --resource-group my-resource-group \
  --enable-disk-driver
```

## 📋 Prerequisites

Before running the script, ensure you have:

- **Azure CLI** installed and logged in (`az login`)
- **kubectl** installed and configured
- **AKS cluster** that exists and is running
- **Appropriate permissions** for AKS update operations

### Required Azure Permissions

The user/service principal running this script needs the following permissions:

- `Microsoft.ContainerService/managedClusters/read`
- `Microsoft.ContainerService/managedClusters/write`
- Or the built-in role: **Azure Kubernetes Service Contributor**

## 🛠 Usage

```bash
./install-azure-disk-csi-driver.sh CLUSTER_NAME RESOURCE_GROUP [OPTIONS]
```

### Arguments

| Argument | Description | Required | Example |
|----------|-------------|----------|---------|
| `CLUSTER_NAME` | Name of your AKS cluster | ✅ | `my-aks-cluster` |
| `RESOURCE_GROUP` | Azure resource group | ✅ | `my-resource-group` |

### Options

| Option | Description | Example |
|--------|-------------|---------|
| `--subscription` | Azure subscription ID | `--subscription 12345678-...` |
| `--helm` | Force Helm installation method | `--helm` |
| `--help` | Show usage information | `--help` |

### Examples

```bash
# Production cluster
./install-azure-disk-csi-driver.sh production-aks prod-rg

# Development cluster with specific subscription
./install-azure-disk-csi-driver.sh dev-aks dev-rg --subscription 12345678-1234-1234-1234-123456789012

# Force Helm installation method
./install-azure-disk-csi-driver.sh my-aks my-rg --helm
```

## 🔧 Environment Variables

You can customize the script behavior using these environment variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `DEBUG` | Enable debug logging | `false` |

### Examples

```bash
# Enable debug logging
DEBUG=true ./install-azure-disk-csi-driver.sh my-cluster my-rg
```

## 📤 Output

Upon successful completion, the script will display:

```
╔══════════════════════════════════════════════════════════════════════════════╗
║                          INSTALLATION RESULTS                               ║
╚══════════════════════════════════════════════════════════════════════════════╝

Cluster:         my-aks-cluster
Resource Group:  my-resource-group
Install Method:  aks-addon

CSI Driver:      disk.csi.azure.com

Available Storage Classes:
NAME          PROVISIONER            DEFAULT
managed-csi   disk.csi.azure.com     
default       disk.csi.azure.com     true

Next Steps:
1. You can now create PersistentVolumeClaims using Azure Disk storage
2. Use 'managed-csi' or 'default' storage class for your PVCs
```

## 🔍 What the Script Does

1. **Validates prerequisites** - Checks for Azure CLI, kubectl, and proper authentication
2. **Verifies AKS cluster** - Ensures the cluster exists and is accessible
3. **Checks current status** - Determines if CSI driver is already installed
4. **Enables/Installs driver** - Uses AKS add-on (preferred) or Helm
5. **Verifies installation** - Confirms CSI driver and pods are running
6. **Creates storage class** - Ensures a storage class is available for PVCs

## 🏗 Installation Methods

### Method 1: AKS Add-on (Recommended)
The script first tries to enable the Azure Disk CSI driver as an AKS managed add-on:
```bash
az aks update --name $CLUSTER --resource-group $RG --enable-disk-driver
```

**Advantages:**
- Managed by Azure
- Automatic updates
- No additional maintenance
- **No separate IAM/Identity setup required** (unlike AWS EKS)

### Method 2: Helm Installation (Fallback)
If the AKS add-on method fails, the script falls back to Helm installation:
```bash
helm install azuredisk-csi-driver azuredisk-csi-driver/azuredisk-csi-driver \
  --namespace kube-system
```

**When to use:**
- Custom configuration needed
- Non-AKS Kubernetes clusters
- Specific version requirements

## 🔄 Key Difference from AWS EKS

| Aspect | AWS EKS (EBS) | Azure AKS (Disk) |
|--------|---------------|------------------|
| IAM/Identity Setup | Required (CloudFormation template) | **Not required** (AKS manages automatically) |
| Installation | EKS Add-on + IAM Role | AKS Add-on only |
| Files Needed | Shell script + CloudFormation YAML | Shell script only |

> **Note:** Unlike AWS EKS where you need to create an IAM role first using `ebs-driver-role.yaml`, Azure AKS automatically manages the identity when you enable the disk driver add-on.

## 🛠 Troubleshooting

### Common Issues

**Azure CLI not logged in:**
```bash
az login
# or for service principal:
az login --service-principal -u $APP_ID -p $PASSWORD --tenant $TENANT_ID
```

**Cluster not found:**
```bash
# List available clusters
az aks list --output table

# Verify cluster exists
az aks show --name my-cluster --resource-group my-rg
```

**Permission denied:**
```bash
# Check current account
az account show

# Verify role assignments
az role assignment list --assignee $(az account show --query user.name -o tsv)
```

### Debug Mode

Enable debug logging to see detailed execution information:

```bash
DEBUG=true ./install-azure-disk-csi-driver.sh my-cluster my-rg
```

### Verify Installation Manually

```bash
# Check CSI driver
kubectl get csidriver disk.csi.azure.com

# Check CSI pods
kubectl get pods -n kube-system | grep csi-azuredisk

# Check storage classes
kubectl get storageclass
```

## 📁 Storage Classes Created

The script ensures the following storage class is available:

### managed-csi
```yaml
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
```

## 📝 Example PVC

After installation, you can create PersistentVolumeClaims:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: managed-csi
  resources:
    requests:
      storage: 10Gi
```

## 🏷️ Available Disk SKUs

| SKU | Description | Use Case |
|-----|-------------|----------|
| `StandardSSD_LRS` | Standard SSD, LRS | General purpose (default) |
| `Premium_LRS` | Premium SSD, LRS | Production workloads |
| `StandardHDD_LRS` | Standard HDD, LRS | Dev/test, backups |
| `Premium_ZRS` | Premium SSD, ZRS | Zone-redundant |
| `StandardSSD_ZRS` | Standard SSD, ZRS | Zone-redundant |

## 🔗 Related Documentation

- [Azure Disk CSI Driver](https://docs.microsoft.com/azure/aks/azure-disk-csi)
- [AKS Storage Options](https://docs.microsoft.com/azure/aks/concepts-storage)
- [Persistent Volumes in Kubernetes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)
- [Azure Disk CSI Driver GitHub](https://github.com/kubernetes-sigs/azuredisk-csi-driver)

## 📞 Support

For issues or questions:
1. Check the troubleshooting section above
2. Review Azure Portal for AKS cluster status
3. Check `kubectl get events -n kube-system` for CSI driver issues
4. Visit the [GitHub repository](https://github.com/astuto-ai/onelens-installation-scripts)

---

**Version:** 1.0.0  
**Compatibility:** Bash 4.0+, Azure CLI 2.0+, kubectl 1.20+  
**Dependencies:** Azure CLI, kubectl, Helm (optional)
