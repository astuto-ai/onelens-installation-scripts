# OneLens Agent Base Helm Chart

This Helm chart provides the base configuration for deploying the OneLens Agent in Kubernetes environments. It contains the core components and configurations needed for the agent to function properly.

## Overview

The OneLens Agent Base chart serves as a foundation for deploying and managing OneLens agents in your Kubernetes cluster. This chart handles the deployment, configuration, and service setup required for the agent to operate effectively.

## Versioning

The chart follows semantic versioning (MAJOR.MINOR.PATCH) with additional pre-release identifiers when needed (e.g., `-beta.3`). Version information is maintained in the `Chart.yaml` file.

## Working with the Helm Chart

### Prerequisites

- Helm 3.x installed
- AWS CLI configured with appropriate permissions
- Access to AWS ECR repository

### Packaging the Chart

To create a packaged version of the chart:

```bash
# Navigate to the chart directory
cd onelens-agent/helm-chart/onelens-agent-base

# Create a packages directory if it doesn't exist
mkdir -p packages

# Package the chart
helm package ../ -d packages/
```

This will create a `.tgz` file in the packages directory, e.g., `packages/onelens-agent-base-0.0.1-beta.3.tgz`.

### Publishing to AWS ECR

1. **Login to AWS ECR**:

```bash
aws ecr get-login-password --region <region> | helm registry login --username AWS --password-stdin <account-id>.dkr.ecr.<region>.amazonaws.com
```

Example:
```bash
aws ecr get-login-password --region ap-south-1 | helm registry login --username AWS --password-stdin 609916866699.dkr.ecr.ap-south-1.amazonaws.com
```

2. **Push the chart to ECR**:

```bash
helm push packages/onelens-agent-base-<version>.tgz oci://<account-id>.dkr.ecr.<region>.amazonaws.com/helm-charts/
```

Example:
```bash
helm push packages/onelens-agent-base-0.0.1-beta.3.tgz oci://609916866699.dkr.ecr.ap-south-1.amazonaws.com/helm-charts/
```

### Pulling the Chart from ECR

To download a chart from ECR:

```bash
helm pull oci://<account-id>.dkr.ecr.<region>.amazonaws.com/helm-charts/onelens-agent-base --version <version>
```

Example:
```bash
helm pull oci://609916866699.dkr.ecr.ap-south-1.amazonaws.com/helm-charts/onelens-agent-base --version 0.0.1-beta.3
```

## Troubleshooting

- If you encounter a 404 error when pushing, ensure the repository exists in ECR
- Make sure to use the correct path format when pushing to or pulling from ECR
- Verify that you have the necessary permissions to push to and pull from the ECR repository

## Additional Resources

For more information on using Helm, run:
```bash
helm --help
```
