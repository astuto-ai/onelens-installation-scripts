# OneLens Installation Scripts

> **Simplified Kubernetes cost optimization and monitoring deployment**

[![Documentation](https://img.shields.io/badge/Documentation-OneLens-00C851?logo=gitbook)](https://docs.onelens.cloud/integrations/kubernetes/onelens-agent/onboarding-a-k8s-cluster)
[![Helm Charts](https://img.shields.io/badge/Helm-Charts-0F1689?logo=helm)](https://astuto-ai.github.io/onelens-installation-scripts/)
[![Docker](https://img.shields.io/badge/Docker-Multi--Arch-2496ED?logo=docker)](https://gallery.ecr.aws/w7k6q5m9/onelens-deployer)

## Overview

OneLens Installation Scripts provides automated deployment tools for setting up comprehensive Kubernetes cost monitoring and optimization infrastructure. This repository contains Helm charts and automation scripts to deploy OneLens agents and supporting monitoring stack.

## Components

### OneLens Deployer
A Kubernetes job orchestrator that handles the initial setup and configuration of OneLens infrastructure in your cluster.

**Features:**
- One-time setup jobs
- Cluster configuration automation
- Cross-platform Docker images (AMD64/ARM64)

### OneLens Agent
The core monitoring agent that collects cost and resource utilization data from your Kubernetes cluster.

**Includes:**
- **OneLens Agent**: Main cost monitoring and optimization agent
- **Prometheus**: Metrics collection and storage
- **OpenCost Exporter**: Kubernetes cost metrics calculation
- **Custom Storage Classes**: Optimized storage configurations

## Quick Start

### Prerequisites
- Kubernetes cluster (1.25+)
- Helm 3.0+
- kubectl configured for your cluster

### Installation

1. **Add the OneLens Helm repository:**
   ```bash
   helm repo add onelens https://astuto-ai.github.io/onelens-installation-scripts/
   helm repo update
   ```

2. **Deploy OneLens Deployer:**
   ```bash
   helm upgrade --install onelensdeployer onelens/onelensdeployer \
     --set job.env.CLUSTER_NAME=your-cluster-name \
     --set job.env.REGION=your-aws-region \
     --set-string job.env.ACCOUNT=your-aws-account-id \
     --set job.env.REGISTRATION_TOKEN="your-registration-token"
   ```

3. **Deploy OneLens Agent:**
   ```bash
   helm upgrade --install onelens-agent onelens/onelens-agent \
     --namespace onelens-system \
     --create-namespace
   ```

### List Available Charts

```bash
helm search repo onelens
```

## Creating New Releases

### Prerequisites
- GitHub CLI (`gh`) installed and authenticated
- Access to the repository with release permissions

### Release Process

1. **Create and push a new tag:**
   ```bash
   git tag -a v1.2.1 -m "Release version 1.2.1"
   git push origin v1.2.1
   ```

2. **Create GitHub release:**
   ```bash
   gh release create v1.2.1 \
     --title "OneLens Charts v1.2.1" \
     --notes "Release notes for version 1.2.1" \
     --generate-notes
   ```

3. **Upload chart packages (if not automated):**
   ```bash
   gh release upload v1.2.1 onelens-agent-1.2.1.tgz onelensdeployer-1.2.1.tgz
   ```

4. **Update Helm repository index:**
   ```bash
   helm repo index . --url https://astuto-ai.github.io/onelens-installation-scripts/
   git add index.yaml
   git commit -m "Update Helm repository index for v1.2.1"
   git push origin gh-pages
   ```

### Automated Release
Charts are automatically published when new releases are created through GitHub Actions. The CI/CD pipeline will:
- Build and package Helm charts
- Update the repository index
- Deploy to GitHub Pages

## Repository Information

- **Repository URL**: https://astuto-ai.github.io/onelens-installation-scripts/
- **Source Code**: https://github.com/astuto-ai/onelens-installation-scripts
- **Documentation**: [OneLens Docs](https://docs.onelens.cloud/integrations/kubernetes/onelens-agent/onboarding-a-k8s-cluster)

## Contributing

We welcome contributions! Please see our development guide for details on:
- Setting up development environment
- Running tests
- Submitting pull requests

## Support

- Email: support@onelens.ai
- Documentation: [OneLens Docs](https://docs.onelens.cloud/integrations/kubernetes/onelens-agent/onboarding-a-k8s-cluster)
- Issues: [GitHub Issues](https://github.com/astuto-ai/onelens-installation-scripts/issues)

## What's Next?

After installation, your cluster will be monitored by OneLens. Visit the OneLens platform to:
- View real-time cost analytics
- Get optimization recommendations
- Set up cost alerts and budgets
- Analyze resource utilization trends

---

**Made with love ♥️ by the OneLens Team**