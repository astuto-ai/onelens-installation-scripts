# OneLens Dedicated Node Installation

This directory contains scripts and templates for creating dedicated Kubernetes nodes specifically for OneLens workloads. The solution supports both **AWS EKS** and **Azure AKS** with automated and manual deployment options.

## Overview

The OneLens Dedicated Node Installation creates node groups/pools with specific configurations:
- **Dedicated nodes** with taints to prevent other workloads from scheduling
- **Automatic instance sizing** based on current pod count in your cluster
- **Single node deployment** for cost optimization
- **Pre-configured permissions** with necessary policies
- **Multi-cloud support** for AWS EKS and Azure AKS

## 📁 Directory Structure

```
dedicated-node-installation/
├── node-group-install.sh      # AWS EKS - Bash script
├── node-group-install.yaml    # AWS EKS - CloudFormation template
├── aks-nodepool-install.sh    # Azure AKS - Bash script
├── aks-nodepool-install.json  # Azure AKS - ARM template
└── README.md                  # This file
```

---

## 🚀 Quick Start

### AWS EKS

#### Method 1: Run directly from the internet
```bash
bash <(curl -sSL https://raw.githubusercontent.com/astuto-ai/onelens-installation-scripts/main/scripts/dedicated-node-installation/node-group-install.sh) <cluster_name> <region>
```

#### Method 2: Deploy CloudFormation via AWS Console
```bash
# Download the template
curl -sSL https://raw.githubusercontent.com/astuto-ai/onelens-installation-scripts/main/scripts/dedicated-node-installation/node-group-install.yaml -o node-group-install.yaml

# Deploy via AWS Console or CLI
aws cloudformation create-stack \
  --stack-name onelens-nodegroup \
  --template-body file://node-group-install.yaml \
  --parameters ParameterKey=ClusterName,ParameterValue=<cluster-name> \
               ParameterKey=SubnetId,ParameterValue=<subnet-id> \
               ParameterKey=InstanceType,ParameterValue=t4g.medium \
  --capabilities CAPABILITY_NAMED_IAM
```

### Azure AKS

#### Method 1: Run directly from the internet
```bash
bash <(curl -sSL https://raw.githubusercontent.com/astuto-ai/onelens-installation-scripts/main/scripts/dedicated-node-installation/aks-nodepool-install.sh) <cluster_name> <resource_group>
```

#### Method 2: Deploy ARM template via Azure Portal/CLI
```bash
# Download the template
curl -sSL https://raw.githubusercontent.com/astuto-ai/onelens-installation-scripts/main/scripts/dedicated-node-installation/aks-nodepool-install.json -o aks-nodepool-install.json

# Deploy via Azure CLI
az deployment group create \
  --resource-group <resource-group> \
  --template-file aks-nodepool-install.json \
  --parameters clusterName=<cluster-name> vmSize=Standard_B2s
```

---

## 📋 Arguments

### AWS EKS Script

| Argument | Description | Required | Example |
|----------|-------------|----------|---------|
| `CLUSTER_NAME` | Name of your EKS cluster | ✅ | `my-eks-cluster` |
| `REGION` | AWS region where cluster is located | ✅ | `us-east-1` |

### Azure AKS Script

| Argument | Description | Required | Example |
|----------|-------------|----------|---------|
| `CLUSTER_NAME` | Name of your AKS cluster | ✅ | `my-aks-cluster` |
| `RESOURCE_GROUP` | Azure resource group containing the cluster | ✅ | `my-resource-group` |

---

## 🔍 What the Scripts Do

### AWS EKS Script
1. **Validates prerequisites** - Checks for AWS CLI, kubectl, and proper configuration
2. **Creates IAM role** - Sets up EKS worker node role with necessary policies
3. **Detects subnet** - Shows available subnets and lets you select one
4. **Counts pods** - Determines current workload to size instances appropriately
5. **Creates nodegroup** - Deploys the EKS nodegroup with proper taints and labels
6. **Asks user consent** - Confirms the configuration before proceeding

### Azure AKS Script
1. **Validates prerequisites** - Checks for Azure CLI, kubectl, and login status
2. **Verifies cluster** - Confirms the AKS cluster exists
3. **Counts pods** - Determines current workload to size instances appropriately
4. **Creates node pool** - Deploys the AKS node pool with proper taints and labels
5. **Asks user consent** - Confirms the configuration before proceeding

---

## 📊 Recommended Instance Sizing

### Based on Cluster Size

| Cluster Size | Pod Count | Total CPU | Total Memory | AWS Instance | Azure VM Size |
|--------------|-----------|-----------|--------------|--------------|---------------|
| **Small** | < 100 | 1.1 vCPU | ~2 GB | `t4g.medium` | `Standard_B2s` |
| **Medium** | 100-499 | 1.25 vCPU | ~2.7 GB | `t4g.medium` | `Standard_B2s` |
| **Large** | 500-999 | 1.95 vCPU | ~4.5 GB | `t4g.xlarge` | `Standard_B4ms` |
| **Extra Large** | 1000-1499 | 2.2 vCPU | ~6.5 GB | `t4g.xlarge` | `Standard_B4ms` |
| **Very Large** | 1500+ | 2.7 vCPU | ~8.4 GB | `t4g.xlarge` | `Standard_B4ms` |

### Component Resource Breakdown

| Component | Small | Medium | Large | XL | Very Large |
|-----------|-------|--------|-------|-----|------------|
| Prometheus | 300m/1.2Gi | 350m/1.7Gi | 1000m/3.5Gi | 1150m/5.4Gi | 1500m/7Gi |
| OpenCost | 200m/200Mi | 200m/250Mi | 250m/360Mi | 250m/450Mi | 300m/600Mi |
| OneLens Agent | 400m/400Mi | 500m/500Mi | 500m/500Mi | 600m/600Mi | 700m/700Mi |
| Pushgateway | 100m/100Mi | 100m/100Mi | 100m/100Mi | 100m/100Mi | 100m/100Mi |
| KSM | 100m/100Mi | 100m/100Mi | 100m/100Mi | 100m/100Mi | 100m/100Mi |

---

## 📋 Prerequisites

### AWS EKS

- **AWS CLI** installed and configured
- **kubectl** configured to access your EKS cluster
- **IAM permissions** for EKS, IAM, and EC2 operations

```bash
# Verify AWS CLI
aws --version
aws sts get-caller-identity

# Configure kubectl for EKS
aws eks update-kubeconfig --name my-cluster --region us-east-1
```

### Azure AKS

- **Azure CLI** installed and logged in
- **kubectl** configured to access your AKS cluster
- **Contributor** role on the resource group

```bash
# Verify Azure CLI
az --version
az account show

# Login to Azure
az login

# Configure kubectl for AKS
az aks get-credentials --resource-group my-rg --name my-aks-cluster
```

---

## 🔧 Template Parameters

### AWS CloudFormation (`node-group-install.yaml`)

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `ClusterName` | String | - | Name of the EKS cluster |
| `SubnetId` | AWS::EC2::Subnet::Id | - | Subnet ID for the nodegroup |
| `InstanceType` | String | `t4g.small` | EC2 instance type |
| `AMIType` | String | `AL2023_ARM_64_STANDARD` | AMI type for instances |
| `RoleName` | String | auto-generated | IAM role name |

### Azure ARM Template (`aks-nodepool-install.json`)

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `clusterName` | String | - | Name of the AKS cluster |
| `nodePoolName` | String | `onelenspool` | Name for the node pool |
| `vmSize` | String | `Standard_B2s` | Azure VM size |
| `nodeCount` | Integer | `1` | Number of nodes |
| `osType` | String | `Linux` | OS type for nodes |

---

## 🛠 Troubleshooting

### AWS EKS

**AWS CLI not configured:**
```bash
aws configure
# or set environment variables
export AWS_ACCESS_KEY_ID=your-access-key
export AWS_SECRET_ACCESS_KEY=your-secret-key
export AWS_DEFAULT_REGION=us-east-1
```

**kubectl not configured:**
```bash
aws eks update-kubeconfig --name my-cluster --region us-east-1
```

### Azure AKS

**Azure CLI not logged in:**
```bash
az login
az account set --subscription <subscription-id>
```

**kubectl not configured:**
```bash
az aks get-credentials --resource-group my-rg --name my-aks-cluster
```

**Node pool creation failed:**
```bash
# Check node pool status
az aks nodepool show --resource-group my-rg --cluster-name my-aks --name onelenspool

# Check cluster events
kubectl get events --all-namespaces --sort-by='.lastTimestamp'
```

---

## 🔗 Related Documentation

### AWS
- [Amazon EKS Managed Node Groups](https://docs.aws.amazon.com/eks/latest/userguide/managed-node-groups.html)
- [EKS IAM Roles](https://docs.aws.amazon.com/eks/latest/userguide/worker_node_IAM_role.html)
- [CloudFormation User Guide](https://docs.aws.amazon.com/cloudformation/)

### Azure
- [AKS Node Pools](https://docs.microsoft.com/en-us/azure/aks/use-multiple-node-pools)
- [AKS Taints and Tolerations](https://docs.microsoft.com/en-us/azure/aks/operator-best-practices-advanced-scheduler)
- [ARM Templates](https://docs.microsoft.com/en-us/azure/azure-resource-manager/templates/)

### Kubernetes
- [Taints and Tolerations](https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/)
- [Node Selectors](https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/)

---

## 📞 Support

For issues or questions:
1. Check the troubleshooting section above
2. Review cloud provider console for node/pool status
3. Check cluster events with kubectl
4. Visit the [GitHub repository](https://github.com/astuto-ai/onelens-installation-scripts)
