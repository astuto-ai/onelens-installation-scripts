# OneLens Agent Pre-requisite Checker

This script validates all prerequisites required for OneLens Agent installation on your EKS cluster.

## Overview

The OneLens Agent Pre-requisite Checker is an interactive script that validates your environment against all requirements needed for a successful OneLens Agent deployment. It performs comprehensive checks and provides clear feedback on what needs to be addressed.

## Usage

### Method 1: Run directly from the internet
```bash
curl -sSL https://raw.githubusercontent.com/astuto-ai/onelens-installation-scripts/release/v1.3.0-prereq-check/scripts/prereq-check/onelens-prereq-check.sh | bash
```

### Method 2: Download and run locally
```bash
# Download the script
curl -sSL https://raw.githubusercontent.com/astuto-ai/onelens-installation-scripts/release/v1.3.0-prereq-check/scripts/prereq-check/onelens-prereq-check.sh -o onelens-prereq-check.sh

# Make it executable
chmod +x onelens-prereq-check.sh

# Run it
./onelens-prereq-check.sh
```

### Method 3: Run from local repository
```bash
# Navigate to the script directory
cd scripts/prereq-check

# Run the pre-requisite checker
./onelens-prereq-check.sh
```

## Prerequisites for Running This Script

The script will automatically check for required tools before starting. If any tools are missing, it will exit with an error message listing what needs to be installed:

- `bash`
- `curl` 
- `ping`
- `nslookup`
- `jq` (for JSON parsing)
- `aws` CLI
- `kubectl`
- `helm`

> **📦 Need Help Installing Tools?**  
> If any of these tools are missing from your system, follow our [Tools Installation Guide](tools-installation.md) for step-by-step installation instructions on Linux/Ubuntu systems.

## What This Script Checks

### 1. Internet Connectivity
- Basic internet access (ping test)
- Access to required OneLens URLs:
  - `https://onelens-kubernetes-agent.s3.amazonaws.com`
  - `https://api-in.onelens.cloud`
  - `https://astuto-ai.github.io`
- Access to container registries:
  - `public.ecr.aws`
  - `quay.io`
  - `registry.k8s.io`

### 2. AWS CLI Configuration
- Verifies AWS CLI is installed and configured
- Retrieves and displays current AWS account information
- Asks for user confirmation of the correct account/user/role

### 3. Kubernetes Cluster Access
- Verifies kubectl is installed and configured
- Checks cluster connectivity
- Displays current cluster context and endpoint
- **Detects actual EKS cluster name and AWS region** using multiple methods:
  - AWS CLI (if configured): Matches cluster endpoint to get real cluster name and region
  - URL parsing: Extracts cluster ID and region from EKS endpoint URL
  - Fallback: Uses kubectl context name
- Displays comprehensive cluster information including name, region, context, and endpoint

### 4. Helm Version
- Checks that Helm version 3.0.0 or later is installed
- Displays current Helm version

### 5. EKS Version
- Verifies EKS cluster version is 1.27 or later
- Displays current Kubernetes version

### 6. EBS CSI Driver
- Checks if EBS CSI driver is installed using `kubectl get csidriver ebs.csi.aws.com`
- Verifies EBS CSI driver controller pods are running and ready (any container count)
- Verifies EBS CSI driver node pods (DaemonSet) are running and ready
- Provides detailed diagnostics and possible solutions for pod failures

### Script Flow

The script will:
1. Run all prerequisite checks automatically
2. Display progress for each check
3. Show detailed information about your AWS account and cluster
4. Collect all configuration details during checks
5. Present a comprehensive summary of both passed and failed checks
6. Provide clear next steps based on results

### Example Output

```
================================================================
OneLens Agent Pre-requisite Checker
================================================================

This script will validate all prerequisites for OneLens Agent installation.
Please ensure you have the necessary permissions to access AWS and Kubernetes resources.

Running prerequisite checks...

================================================================
1/6 - Internet Connectivity Check
================================================================

Checking: internet connectivity
PASS: Basic internet connectivity verified
...

================================================================
Pre-requisite Check Summary
================================================================

PREREQUISITE CHECK RESULTS:
============================
Status: 6/6 checks passed

⚠️  PLEASE REVIEW THE DETECTED CONFIGURATION BELOW BEFORE PROCEEDING ⚠️

PASSED CHECKS - DETECTED CONFIGURATION:
=======================================

AWS CONFIGURATION:
------------------
  AWS Account: 123456789012
  AWS User/Role: arn:aws:iam::123456789012:user/admin

KUBERNETES CLUSTER:
-------------------
  EKS Cluster Name: my-production-cluster
  AWS Region: us-east-1
  Kubectl Context: arn:aws:eks:us-east-1:123456789012:cluster/my-production-cluster
  Cluster Endpoint: https://ABC123.gr7.us-east-1.eks.amazonaws.com

TOOLS & VERSIONS:
-----------------
  Helm Version: 3.17.0
  EKS Version: 1.29.3

STORAGE:
--------
  EBS CSI Driver: Controller pods are healthy
  EBS CSI Driver: Node pods are healthy

PASS: All pre-requisites passed! Your environment is ready for OneLens Agent installation.

IMPORTANT: Please carefully review the detected configuration sections above
to ensure OneLens Agent will be installed on the correct AWS account and cluster.

NEXT STEPS:
1. Verify the AWS account, region, and cluster details above are correct
2. Run the OneLens Agent installation script
3. Follow the installation guide for configuration
```

### Example Output (Missing Tools)

If required tools are missing, the script will exit immediately:

```
ERROR: Missing required tools for this script to run:
  - jq
  - aws

Please install the missing tools and try again.
Required tools: curl, ping, nslookup, jq, aws, kubectl, helm
```

### Example Output (Partial Failure)

If some checks fail, the script shows both passed and failed checks:

```
================================================================
Pre-requisite Check Summary
================================================================

PREREQUISITE CHECK RESULTS:
============================
Status: 3/6 checks passed

⚠️  PLEASE REVIEW THE DETECTED CONFIGURATION BELOW BEFORE PROCEEDING ⚠️

PASSED CHECKS - DETECTED CONFIGURATION:
=======================================

AWS CONFIGURATION:
------------------

KUBERNETES CLUSTER:
-------------------
  EKS Cluster Name: my-production-cluster
  AWS Region: us-east-1
  Kubectl Context: arn:aws:eks:us-east-1:123456789012:cluster/my-production-cluster
  Cluster Endpoint: https://ABC123.gr7.us-east-1.eks.amazonaws.com

TOOLS & VERSIONS:
-----------------
  EKS Version: 1.29.3

STORAGE:
--------

FAILED CHECKS:
==============
1. Internet Connectivity: Cannot access required URL: https://onelens-kubernetes-agent.s3.amazonaws.com
2. AWS CLI: AWS CLI is not configured or credentials are invalid
3. Helm: Version 2.14.3 is too old (minimum required: 3.0.0)

FAIL: Some pre-requisites failed! Please address the failed checks above before proceeding.

NEXT STEPS:
1. Review the failed checks above
2. Fix the issues listed in the failed checks
3. Re-run this script to verify fixes
4. Proceed with OneLens Agent installation once all checks pass
```

### Example Output (EBS Driver Not Installed)

When EBS CSI driver is not found, the script provides installation guidance:

```
Checking: Checking EBS CSI driver installation...
FAIL: EBS CSI driver is not installed

To install the EBS CSI driver, run the following command:
curl -sSL https://raw.githubusercontent.com/astuto-ai/onelens-installation-scripts/release/v1.3.0-ebs-driver-installer/scripts/ebs-driver-installation/install-ebs-csi-driver.sh | bash -s -- my-cluster us-east-1

Replace 'my-cluster' with your actual cluster name and 'us-east-1' with your region
Alternative: Use the script in scripts/ebs-driver-installation/
```

## Troubleshooting

### Common Issues

#### Internet Connectivity Issues
- **Problem**: URLs or container registries not accessible
- **Solution**: Check your network connectivity, proxy settings, and firewall rules

#### AWS CLI Not Configured
- **Problem**: AWS CLI credentials not set up
- **Solution**: Run `aws configure` to set up your credentials

#### Wrong AWS Account/Cluster
- **Problem**: Script detects wrong AWS account or Kubernetes cluster
- **Solution**: 
  - For AWS: Use `aws configure` or `aws configure --profile <profile-name>`
  - For Kubernetes: Use `kubectl config use-context <context-name>`

#### Helm Version Too Old
- **Problem**: Helm version is less than 3.0.0
- **Solution**: Update Helm to version 3.0.0 or later

#### EKS Version Too Old
- **Problem**: EKS cluster version is less than 1.27
- **Solution**: Upgrade your EKS cluster to version 1.27 or later

#### EBS CSI Driver Not Installed
- **Problem**: EBS CSI driver is not installed or not working
- **Solution**: The script will provide a direct installation command:
  ```bash
  curl -sSL https://raw.githubusercontent.com/astuto-ai/onelens-installation-scripts/release/v1.3.0-ebs-driver-installer/scripts/ebs-driver-installation/install-ebs-csi-driver.sh | bash -s -- my-cluster us-east-1
  ```
  Replace `my-cluster` with your actual cluster name and `us-east-1` with your region
- **Alternative**: Use the EBS driver installation script in `../ebs-driver-installation/`

### Getting Help

If you encounter issues not covered in this troubleshooting section:

1. Check the detailed error messages provided by the script
2. Verify your network connectivity and permissions
3. Ensure all required tools are properly installed
4. Review the OneLens documentation for additional guidance

## Script Maintenance

### Adding New Checks

To add new pre-requisite checks:

1. Create a new function following the naming pattern `check_<name>()`
2. Use the provided utility functions for consistent output
3. Add the new check to the main execution flow
4. Update the total checks counter
5. Update this README with the new check information

### Modifying Requirements

To modify existing requirements:

1. Update the configuration variables at the top of the script
2. Modify the relevant check function
3. Update this README with the new requirements

### Utility Functions

The script provides several utility functions for consistent output:
- `print_header()` - Section headers
- `print_step()` - Step descriptions
- `print_success()` - Success messages
- `print_error()` - Error messages
- `print_warning()` - Warning messages
- `ask_confirmation()` - User confirmation prompts
- `version_greater_equal()` - Version comparison
- `check_command()` - Command availability check

## Integration

This script is designed to be run before the OneLens Agent installation process. It can be:
- Run manually by users before installation
- Integrated into CI/CD pipelines
- Called from other installation scripts
- Used as a troubleshooting tool

## Exit Codes

- `0` - All pre-requisites passed
- `1` - One or more pre-requisites failed
- Script also exits with error codes from individual checks when they fail

## Security Considerations

- The script only performs read-only operations
- No sensitive information is logged or stored
- AWS credentials are validated but not displayed
- Network requests are made only to verify connectivity
