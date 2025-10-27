# EBS CSI Driver IAM Role Installer

Enterprise-ready shell script that automatically creates an IAM role for Amazon EBS CSI Driver with OIDC trust relationship for your EKS cluster.

## 🚀 Quick Start

### Method 1: Run directly from the internet
```bash
curl -sSL https://raw.githubusercontent.com/astuto-ai/onelens-installation-scripts/release/v1.2.0-ebs-driver-installer/scripts/ebs-driver-installation/install-ebs-csi-driver.sh | bash -s -- my-cluster us-east-1
```

### Method 2: Download and run locally
```bash
# Download the script
curl -sSL https://raw.githubusercontent.com/astuto-ai/onelens-installation-scripts/release/v1.2.0-ebs-driver-installer/scripts/ebs-driver-installation/install-ebs-csi-driver.sh -o install-ebs-csi-driver.sh

# Make it executable
chmod +x install-ebs-csi-driver.sh

# Run it
./install-ebs-csi-driver.sh my-cluster us-east-1
```

### Method 3: Deploy CloudFormation template manually via AWS Console
```bash
# Download the CloudFormation template
curl -sSL https://raw.githubusercontent.com/astuto-ai/onelens-installation-scripts/release/v1.2.0-ebs-driver-installer/scripts/ebs-driver-installation/ebs-driver-role.yaml -o ebs-driver-role.yaml

# Then deploy via AWS Console:
# 1. Go to AWS CloudFormation Console
# 2. Create Stack → Upload a template file → Select ebs-driver-role.yaml
# 3. Provide parameters:
#    - ClusterName: your-cluster-name
#    - OIDCIssuerURL: From the console
# 4. Review and create stack
# 5. Copy the IAM Role ARN from the stack outputs
```

## 📋 Prerequisites

Before running the script, ensure you have:

- **AWS CLI** installed and configured with appropriate permissions
- **curl** for downloading templates
- **EKS cluster** with OIDC identity provider enabled
- **IAM permissions** for CloudFormation and IAM operations

### Required IAM Permissions

The user/role running this script needs the following permissions:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "cloudformation:CreateStack",
                "cloudformation:UpdateStack", 
                "cloudformation:DeleteStack",
                "cloudformation:DescribeStacks",
                "cloudformation:ValidateTemplate"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "iam:CreateRole",
                "iam:DeleteRole", 
                "iam:GetRole",
                "iam:PassRole",
                "iam:AttachRolePolicy",
                "iam:DetachRolePolicy",
                "iam:TagRole",
                "iam:UntagRole"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "eks:DescribeCluster"
            ],
            "Resource": "*"
        }
    ]
}
```

## 🛠 Usage

```bash
./install-ebs-csi-driver.sh CLUSTER_NAME REGION
```

### Arguments

| Argument | Description | Required | Example |
|----------|-------------|----------|---------|
| `CLUSTER_NAME` | Name of your EKS cluster | ✅ | `my-eks-cluster` |
| `REGION` | AWS region where cluster is located | ✅ | `us-east-1` |

### Examples

```bash
# Production cluster in US East
./install-ebs-csi-driver.sh production-cluster us-east-1

# Development cluster in EU West  
./install-ebs-csi-driver.sh dev-cluster eu-west-1

# Staging cluster in Asia Pacific
./install-ebs-csi-driver.sh staging-cluster ap-south-1
```

## 🔧 Environment Variables

You can customize the script behavior using these environment variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `DEBUG` | Enable debug logging | `false` |
| `CFT_TEMPLATE_URL` | Override CloudFormation template URL | GitHub raw URL |

### Examples

```bash
# Enable debug logging
DEBUG=true ./install-ebs-csi-driver.sh my-cluster us-east-1

# Use custom template URL  
CFT_TEMPLATE_URL=https://my-bucket.s3.amazonaws.com/template.yaml ./install-ebs-csi-driver.sh my-cluster us-east-1
```

## 📤 Output

Upon successful completion, the script will display:

```
╔══════════════════════════════════════════════════════════════════════════════╗
║                            DEPLOYMENT RESULTS                               ║
╚══════════════════════════════════════════════════════════════════════════════╝

IAM Role Name: AmazonEKS_EBS_CSI_DriverRole-my-cluster-us-east-1
IAM Role ARN:  arn:aws:iam::123456789012:role/AmazonEKS_EBS_CSI_DriverRole-my-cluster-us-east-1

Next Steps:
1. Install the EBS CSI driver add-on in your EKS cluster
2. Use the IAM Role ARN above as the **IAM Role for IRSA** when configuring the EBS CSI driver add-on

## Using the IAM Role ARN

The CloudFormation stack outputs an **IAM Role ARN** that must be used when installing the EBS CSI driver add-on. This role enables **IRSA (IAM Roles for Service Accounts)** which allows the EBS CSI driver pods to assume the IAM role and access AWS EBS APIs.

### Via AWS CLI:
```bash
# Install EBS CSI driver add-on with the IAM Role ARN for IRSA:
aws eks create-addon \
  --cluster-name my-cluster \
  --addon-name aws-ebs-csi-driver \
  --service-account-role-arn arn:aws:iam::123456789012:role/AmazonEKS_EBS_CSI_DriverRole-my-cluster-us-east-1 \
  --region us-east-1
```

## 🔍 What the Script Does

1. **Validates prerequisites** - Checks for AWS CLI, curl, and proper configuration
2. **Verifies EKS cluster** - Ensures the cluster exists and has OIDC enabled  
3. **Downloads CloudFormation template** - Gets the latest IAM role template
4. **Deploys/Updates stack** - Creates or updates the CloudFormation stack
5. **Monitors progress** - Shows real-time deployment status with progress indicators
6. **Returns results** - Displays the created IAM role details and next steps

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



**OIDC provider not enabled:**
```bash
# Enable OIDC for your cluster
aws eks update-cluster-config \
  --name my-cluster \
  --identity '{"oidc":{"issuer":"enabled"}}'
```

### Debug Mode

Enable debug logging to see detailed execution information:

```bash
DEBUG=true ./install-ebs-csi-driver.sh my-cluster us-east-1
```

### Idempotency & Multiple Runs

**✅ Safe to re-run when:**
- No stack exists → Creates new stack
- Stack exists with `CREATE_COMPLETE` or `UPDATE_COMPLETE` status → Updates stack

**❌ Will fail when:**
- Stack is in progress (`*_IN_PROGRESS`) → Exits with error
- Stack in failed state → Exits with error  
- **No changes needed** → CloudFormation update fails (script limitation)

**Note:** Running twice with identical parameters will fail on the second run due to "No updates to perform" error.

## 📁 Files Created

The script creates a CloudFormation stack named:
```
ebs-csi-driver-role-{CLUSTER_NAME}-{REGION}
```

With the following resources:
- **IAM Role** for EBS CSI Driver
- **Trust policy** with OIDC identity provider
- **Managed policy** attachment (AmazonEBSCSIDriverPolicy)

## 🏷️ Resource Tags

All created resources are automatically tagged with:
- `CreatedBy`: install-ebs-csi-driver
- `Version`: Script version
- `EKSCluster`: Cluster name

## 🔗 Related Documentation

- [Amazon EBS CSI Driver](https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html)
- [EKS OIDC Identity Provider](https://docs.aws.amazon.com/eks/latest/userguide/enable-iam-roles-for-service-accounts.html)
- [CloudFormation User Guide](https://docs.aws.amazon.com/cloudformation/)

## 📞 Support

For issues or questions:
1. Check the troubleshooting section above
2. Review AWS CloudFormation console for stack events
3. Check AWS CloudTrail for API call details
4. Visit the [GitHub repository](https://github.com/astuto-ai/onelens-installation-scripts)

---

**Version:** 1.2.0  
**Compatibility:** Bash 4.0+, AWS CLI 2.0+  
**Dependencies:** Only AWS CLI and curl