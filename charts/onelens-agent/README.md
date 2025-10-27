# OneLens Agent Helm Chart

This Helm chart provides the configuration for deploying the OneLens Agent in Kubernetes environments. It builds upon the  OneLens Agent Base chart and includes additional components like Prometheus and OpenCost.

## Overview

The OneLens Agent chart serves as a comprehensive solution for deploying and managing OneLens agents in your Kubernetes cluster. This chart handles the deployment, configuration, and service setup required for  agent to operate effectively, along with supporting monitoring and cost analysis tools.

## Versioning

The chart follows semantic versioning (MAJOR.MINOR.PATCH) with additional pre-release identifiers when needed (e.g., `-beta.3`). Version information is maintained in the `Chart.yaml` file.

## Updating the Helm Chart

### Prerequisites

- Helm 3.x installed
- AWS CLI configured with appropriate permissions
- Access to AWS ECR repository

### Dependencies

This chart includes the following dependencies:
- OneLens Agent Base (from private ECR)
- Prometheus (from Prometheus Community Helm charts)
- Prometheus OpenCost Exporter (from Prometheus Community Helm charts)

### Installing Dependencies

Before packaging the chart, update the dependencies:

```bash
# Navigate to the chart directory
cd onelens-agent/helm-chart/onelens-agent

# Update dependencies
helm dependency update
```

### Packaging the Chart

To create a packaged version of the chart:

```bash
# Navigate to the chart directory
cd onelens-agent/helm-chart/onelens-agent

# Create a packages directory if it doesn't exist
mkdir -p packages

# Package the chart
helm package . -d packages/
```
> **Note**: This will create a `.tgz` file in the packages directory, e.g., `packages/onelens-agent-0.0.1-beta.5.tgz`.
> After successfully pushing to ECR, you must delete the local package file.

### Publishing 
TODO

## Configuration

The chart can be configured through the `values.yaml` file. Key configuration sections include:

- OneLens Agent settings
  - Image configuration
  - Service account settings
  - Storage class configuration
  - Resource limits
  - CronJob settings
  - Environment variables and secrets
- Prometheus configuration
  - Server settings
  - Retention policies
  - Scrape configurations
  - Alert manager settings
- OpenCost exporter settings
  - Cloud provider configuration
  - Resource limits
  - Persistence settings

### CronJob Configuration

The OneLens Agent runs as a CronJob with the following default settings:
- Schedule: Once per hour (`0 * * * *`)
- Concurrency Policy: Forbid (prevents concurrent executions)
- History Limits: 3 successful jobs, 2 failed jobs
- Restart Policy: Never
- Health Check: Disabled by default

### Storage Class Configuration

The chart includes a storage class configuration with the following defaults:
- Provisioner: ebs.csi.aws.com
- Reclaim Policy: Retain
- Volume Binding Mode: WaitForFirstConsumer
- Volume Type: gp3
- Volume Expansion: Disabled

### Health Monitoring

The agent includes health check endpoints for both Prometheus and OpenCost:
- Prometheus Health: `http://onelens-agent-prometheus-server:80/-/healthy`
- OpenCost Health: `http://onelens-agent-prometheus-opencost-exporter:9003/healthz`

## Troubleshooting

- If you encounter a 404 error when pushing, ensure the repository exists in ECR
- Make sure to use the correct path format when pushing to or pulling from ECR
- Verify that you have the necessary permissions to push to and pull from the ECR repository

## Additional Resources

For more information on using Helm, run:
```bash
helm --help
```

For OneLens Agent documentation, visit the OneLens documentation portal.

## Deploying the Chart

### Prerequisites

- Helm 3.x installed

### Deploying the Chart

Add the charts
```bash
# Add the AWS ECR repository
helm repo add onelens-agent <>

# Update the Helm repositories
helm repo update
```

Upgrade the chart:
```bash
helm upgrade --install onelens-agent -n onelens-agent --create-namespace <chart> --version <chart-version> \
    --set onelens-agent.image.tag="<image-version>" \
    --set onelens-agent.secrets.API_BASE_URL="<api-base-url>" \
    --set onelens-agent.secrets.CLUSTER_TOKEN="<cluster-token>" \
    --set onelens-agent.secrets.REGISTRATION_ID="<registration-id>" \
    --set onelens-agent.storageClass.enabled=true \
    --set onelens-agent.storageClass.name="<storage-class-name>" \
```

Sample run:
```bash
helm upgrade --install onelens-agent -n onelens-agent --create-namespace <chart> --version 0.1.1-beta.2 \
    --set onelens-agent.image.tag="v0.1.1-beta.2" \
    --set onelens-agent.secrets.API_BASE_URL="https://dev-api.onelens.cloud" \
    --set onelens-agent.secrets.CLUSTER_TOKEN="plain-cluster-token" \
    --set onelens-agent.secrets.REGISTRATION_ID="plain-registration-id" \
    --set onelens-agent.storageClass.enabled=true \
    --set onelens-agent.storageClass.name="onelens-sc" \
```

### Configuration

The chart can be configured through the `values.yaml` file. Key configuration sections include:

- OneLens Agent settings
  - Image configuration
  - Service account settings
  - Storage class configuration
  - Resource limits
  - CronJob settings
  - Environment variables and secrets
- Prometheus configuration
  - Server settings
  - Retention policies
  - Scrape configurations
  - Alert manager settings
- OpenCost exporter settings
  - Cloud provider configuration
  - Resource limits
  - Persistence settings

### CronJob Configuration

The OneLens Agent runs as a CronJob with the following default settings:
- Schedule: Once per hour (`0 * * * *`)
- Concurrency Policy: Forbid (prevents concurrent executions)
- History Limits: 3 successful jobs, 2 failed jobs
- Restart Policy: Never
- Health Check: Disabled by default

### Storage Class Configuration

The chart includes a storage class configuration with the following defaults:
- Provisioner: ebs.csi.aws.com
- Reclaim Policy: Retain
- Volume Binding Mode: WaitForFirstConsumer
- Volume Type: gp3
- Volume Expansion: Disabled

### Health Monitoring

The agent includes health check endpoints for both Prometheus and OpenCost:
- Prometheus Health: `http://onelens-agent-prometheus-server:80/-/healthy`
- OpenCost Health: `http://onelens-agent-prometheus-opencost-exporter:9003/healthz`
