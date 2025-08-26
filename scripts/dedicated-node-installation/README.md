# OneLens Dedicated Node Installation

This directory contains scripts and CloudFormation templates for creating dedicated EKS nodes specifically for OneLens workloads. The solution provides both automated bash script deployment and manual CloudFormation template deployment options.

## Overview

The OneLens Dedicated Node Installation creates EKS nodegroups with specific configurations:
- **Dedicated nodes** with taints to prevent other workloads from scheduling
- **Automatic instance sizing** based on current pod count in your cluster
- **Single AZ deployment** for cost optimization
- **Pre-configured IAM roles** with necessary EKS worker node policies
- **ARM64 architecture** support using Amazon Linux 2023

## 🚀 Quick Start

### Method 1: Run directly from the internet
```bash
bash <(curl -sSL https://raw.githubusercontent.com/astuto-ai/onelens-installation-scripts/release/v1.3.0-dedicated-node/scripts/dedicated-node-installation/node-group-install.sh) <cluster_name> <region>
```

### Method 2: Deploy CloudFormation template manually via AWS Console
```bash
# Download the CloudFormation template
curl -sSL https://raw.githubusercontent.com/astuto-ai/onelens-installation-scripts/release/v1.3.0-dedicated-node/scripts/dedicated-node-installation/node-group-install.yaml -o node-group-install.yaml

# Then deploy via AWS Console:
# 1. Go to AWS CloudFormation Console
# 2. Create Stack → Upload a template file → Select node-group-install.yaml
# 3. Provide parameters:
#    - ClusterName: your-cluster-name
#    - SubnetId: your-subnet-id
#    - InstanceType: t4g.small (or choose based on pod count)
#    - NodeGroupName: your-nodegroup-name
#    - AMIType: your-ami
#    - RoleName: desired-name
# 4. Review and create stack
```

## 📋 Prerequisites

Before running the script, ensure you have:

- **AWS CLI** installed and configured with appropriate permissions
- **kubectl** configured to access your EKS cluster
- **EKS cluster** running with at least one subnet
- **IAM permissions** for EKS, IAM, and EC2 operations

### Required IAM Permissions

The user/role running this script needs the following permissions:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "eks:CreateNodegroup",
                "eks:DescribeCluster",
                "eks:DescribeNodegroup",
                "eks:ListNodegroups"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "iam:CreateRole",
                "iam:AttachRolePolicy",
                "iam:GetRole",
                "iam:PassRole"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "ec2:DescribeSubnets",
                "ec2:DescribeVpcs"
            ],
            "Resource": "*"
        }
    ]
}
```

## 🛠 Usage

### Bash Script Usage

```bash
bash node-group-install.sh CLUSTER_NAME REGION
```

### Arguments

| Argument | Description | Required | Example |
|----------|-------------|----------|---------|
| `CLUSTER_NAME` | Name of your EKS cluster | ✅ | `my-eks-cluster` |
| `REGION` | AWS region where cluster is located | ✅ | `us-east-1` |

### Example

```bash
bash node-group-install.sh production-cluster us-east-1
```

## 🔍 What the Script Does

1. **Validates prerequisites** - Checks for AWS CLI, kubectl, and proper configuration
2. **Creates IAM role** - Sets up EKS worker node role with necessary policies
3. **Detects subnet** - Automatically finds a suitable public subnet in your cluster
4. **Counts pods** - Determines current workload to size instances appropriately
5. **Creates nodegroup** - Deploys the EKS nodegroup with proper taints and labels
6. **Configures isolation** - Applies taints to prevent other workloads from scheduling

Upon successful completion, the script will display:

```
✅ Nodegroup onelens-nodegroup is now ACTIVE in private subnet subnet-005afaa5f6ce9c2d1 with instance type t4g.large and AMI type AL2023_ARM_64_STANDARD. (values change based on your environment)
```

### CloudFormation Template Usage

The CloudFormation template accepts the following parameters:

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `ClusterName` | String | - | Name of the EKS cluster |
| `SubnetId` | AWS::EC2::Subnet::Id | - | Subnet ID where the nodegroup will be created |
| `InstanceType` | String | `t4g.small` | EC2 instance type for the nodegroup |
| `AMIType` | String | `AL2023_ARM_64_STANDARD` | AMIType for instance |
| `NodeGroupName` | String | `onelens-nodegroup` | Name for the nodegroup |
| `RoleName` | String | `onelens-{clustername}-{region}` | Name for the noderole |

## 🔧 Instance Type Selection

The script automatically determines the optimal instance type based on your current pod count:

| Instance Type | Pod Count Range | Use Case |
|---------------|-----------------|----------|
| `t4g.small` | < 100 pods | Development/testing |
| `t4g.medium` | 100–499 pods | Small production |
| `t4g.large` | 500–1499 pods | Medium production |
| `t4g.xlarge` | 1500–2000 pods | Large production |
| `t4g.2xlarge` | 2000 > pods | Large production |



## 🛠 Troubleshooting

### Common Issues

**AWS CLI not configured:**
```bash
aws configure
# or set environment variables:
export AWS_ACCESS_KEY_ID=your-access-key
export AWS_SECRET_ACCESS_KEY=your-secret-key  
export AWS_DEFAULT_REGION=us-east-1
```

**kubectl not configured:**
```bash
# Update kubeconfig for your EKS cluster
aws eks update-kubeconfig --name my-cluster --region us-east-1
```

**Insufficient permissions:**
```bash
# Verify your current permissions
aws sts get-caller-identity
aws eks describe-cluster --name my-cluster --region us-east-1
```


## 🔗 Related Documentation

- [Amazon EKS Nodegroups](https://docs.aws.amazon.com/eks/latest/userguide/managed-node-groups.html)
- [EKS IAM Roles](https://docs.aws.amazon.com/eks/latest/userguide/worker_node_IAM_role.html)
- [EKS Taints and Tolerations](https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/)
- [CloudFormation User Guide](https://docs.aws.amazon.com/cloudformation/)

## 📞 Support

For issues or questions:
1. Check the troubleshooting section above
2. Review AWS EKS console for nodegroup status
3. Check AWS CloudTrail for API call details
4. Visit the [GitHub repository](https://github.com/astuto-ai/onelens-installation-scripts)
