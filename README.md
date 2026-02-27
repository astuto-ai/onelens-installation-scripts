# OneLens Installation Scripts

> **Simplified Kubernetes cost optimization and monitoring deployment**

[![Documentation](https://img.shields.io/badge/Documentation-OneLens-00C851?logo=gitbook)](https://docs.onelens.cloud/integrations/kubernetes/onelens-agent/onboarding-a-k8s-cluster)
[![Helm Charts](https://img.shields.io/badge/Helm-Charts-0F1689?logo=helm)](https://astuto-ai.github.io/onelens-installation-scripts/)
[![Docker](https://img.shields.io/badge/Docker-Multi--Arch-2496ED?logo=docker)](https://gallery.ecr.aws/w7k6q5m9/onelens-deployer)

## 📋 Overview

OneLens Installation Scripts provides automated deployment tools for setting up comprehensive Kubernetes cost monitoring and optimization infrastructure. This repository contains Helm charts and automation scripts to deploy OneLens agents and supporting monitoring stack.

## 🏗️ Components

### 🚀 OneLens Deployer
A Kubernetes job orchestrator that handles the initial setup and configuration of OneLens infrastructure in your cluster.

**Features:**
- One-time setup jobs
- Cluster configuration automation
- Cross-platform Docker images (AMD64/ARM64)

### 📊 OneLens Agent
The core monitoring agent that collects cost and resource utilization data from your Kubernetes cluster.

**Includes:**
- **OneLens Agent**: Main cost monitoring and optimization agent
- **Prometheus**: Metrics collection and storage
- **OpenCost Exporter**: Kubernetes cost metrics calculation
- **Custom Storage Classes**: Optimized storage configurations

## 🚀 Quick Start

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

3. **Deploy OneLens Agent** (only if not using the deployer; the deployer installs the agent for you):
   ```bash
   helm upgrade --install onelens-agent onelens/onelens-agent \
     --namespace onelens-agent \
     --create-namespace
   ```

### Configuration

#### OneLens Deployer Configuration
| Parameter | Description | Default |
|-----------|-------------|---------|
| `job.env.CLUSTER_NAME` | Your Kubernetes cluster name | `""` |
| `job.env.REGION` | AWS region where cluster is located | `""` |
| `job.env.ACCOUNT` | AWS account ID | `""` |
| `job.env.REGISTRATION_TOKEN` | OneLens registration token | `""` |

#### OneLens Agent Configuration
| Parameter | Description | Default |
|-----------|-------------|---------|
| `onelens-agent.enabled` | Enable OneLens agent | `true` |
| `prometheus.enabled` | Enable Prometheus monitoring | `true` |
| `prometheus-opencost-exporter.enabled` | Enable cost metrics | `true` |
| `onelens-agent.cronJob.cronSchedule` | Data collection schedule | `"0 * * * *"` |

### Deployment examples

Use one of the following patterns depending on whether you need labels, nodeSelector, or tolerations. Replace placeholders (`your-cluster-name`, `your-registration-token`, etc.) with your values.

**Labels:** `globals.labels` apply to the namespace, deployer Job/CronJob, and all agent deployments. Use `job.labels` and `cronjob.labels` for labels only on the Job or CronJob (they also flow to deployments when the job runs).

**Tolerations:** Use **Exists** when the taint has no value; use **Equal** when the taint has a key=value.

---

#### 1. Minimal (no labels, no nodeSelector/tolerations)

```bash
helm upgrade --install onelensdeployer onelens/onelensdeployer -n onelens-agent --create-namespace \
  --set job.env.CLUSTER_NAME=your-cluster-name \
  --set job.env.REGION=your-aws-region \
  --set-string job.env.ACCOUNT=your-aws-account-id \
  --set job.env.REGISTRATION_TOKEN=your-registration-token
```

---

#### 2. With global labels only (namespace + deployer + all agent components get these labels)

```bash
helm upgrade --install onelensdeployer onelens/onelensdeployer -n onelens-agent --create-namespace \
  --set job.env.CLUSTER_NAME=your-cluster-name \
  --set job.env.REGION=your-aws-region \
  --set-string job.env.ACCOUNT=your-aws-account-id \
  --set job.env.REGISTRATION_TOKEN=your-registration-token \
  --set globals.labels."company\.com/team"=platform \
  --set globals.labels."company\.com/env"=prod \
  --set globals.labels."company\.com/component"=onelens
```

---

#### 3. With job and cronjob labels (labels on deployer Job and CronJob; same labels also flow to agent deployments)

```bash
helm upgrade --install onelensdeployer onelens/onelensdeployer -n onelens-agent --create-namespace \
  --set job.env.CLUSTER_NAME=your-cluster-name \
  --set job.env.REGION=your-aws-region \
  --set-string job.env.ACCOUNT=your-aws-account-id \
  --set job.env.REGISTRATION_TOKEN=your-registration-token \
  --set job.labels."company\.com/team"=platform \
  --set job.labels."company\.com/env"=prod \
  --set cronjob.labels."company\.com/team"=platform \
  --set cronjob.labels."company\.com/env"=prod
```

---

#### 4. With nodeSelector and tolerations (Exists — taint has no value)

Use when your node taint is like `key=value:NoSchedule` and you want to match only the key (operator `Exists`), or when the taint has no value.

```bash
helm upgrade --install onelensdeployer onelens/onelensdeployer -n onelens-agent --create-namespace \
  --set job.env.CLUSTER_NAME=your-cluster-name \
  --set job.env.REGION=your-aws-region \
  --set-string job.env.ACCOUNT=your-aws-account-id \
  --set job.env.REGISTRATION_TOKEN=your-registration-token \
  --set job.env.NODE_SELECTOR_KEY=your-node-selector-key \
  --set job.env.NODE_SELECTOR_VALUE=your-node-selector-value \
  --set job.env.TOLERATION_KEY=your-toleration-key \
  --set-string job.env.TOLERATION_VALUE="" \
  --set job.env.TOLERATION_OPERATOR=Exists \
  --set job.env.TOLERATION_EFFECT=NoSchedule \
  --set job.nodeSelector.your-node-selector-key=your-node-selector-value \
  --set 'job.tolerations[0].key=your-toleration-key' \
  --set 'job.tolerations[0].operator=Exists' \
  --set 'job.tolerations[0].effect=NoSchedule' \
  --set cronjob.nodeSelector.your-node-selector-key=your-node-selector-value \
  --set 'cronjob.tolerations[0].key=your-toleration-key' \
  --set 'cronjob.tolerations[0].operator=Exists' \
  --set 'cronjob.tolerations[0].effect=NoSchedule'
```

---

#### 5. With nodeSelector and tolerations (Equal — taint has key=value)

Use when your node taint has a key and a value (e.g. `dedicated=onelens:NoSchedule`) and you want to match that exact value.

```bash
helm upgrade --install onelensdeployer onelens/onelensdeployer -n onelens-agent --create-namespace \
  --set job.env.CLUSTER_NAME=your-cluster-name \
  --set job.env.REGION=your-aws-region \
  --set-string job.env.ACCOUNT=your-aws-account-id \
  --set job.env.REGISTRATION_TOKEN=your-registration-token \
  --set job.env.NODE_SELECTOR_KEY=dedicated \
  --set job.env.NODE_SELECTOR_VALUE=onelens \
  --set job.env.TOLERATION_KEY=dedicated \
  --set job.env.TOLERATION_VALUE=onelens \
  --set job.env.TOLERATION_OPERATOR=Equal \
  --set job.env.TOLERATION_EFFECT=NoSchedule \
  --set job.nodeSelector.dedicated=onelens \
  --set 'job.tolerations[0].key=dedicated' \
  --set 'job.tolerations[0].operator=Equal' \
  --set 'job.tolerations[0].value=onelens' \
  --set 'job.tolerations[0].effect=NoSchedule' \
  --set cronjob.nodeSelector.dedicated=onelens \
  --set 'cronjob.tolerations[0].key=dedicated' \
  --set 'cronjob.tolerations[0].operator=Equal' \
  --set 'cronjob.tolerations[0].value=onelens' \
  --set 'cronjob.tolerations[0].effect=NoSchedule'
```

---

#### 6. Full example (labels + nodeSelector + tolerations Exists, all with dummy values)

```bash
helm upgrade --install onelensdeployer onelens/onelensdeployer -n onelens-agent --create-namespace \
  --set job.env.CLUSTER_NAME=your-cluster-name \
  --set job.env.REGION=your-aws-region \
  --set-string job.env.ACCOUNT=your-aws-account-id \
  --set job.env.REGISTRATION_TOKEN=your-registration-token \
  --set job.env.NODE_SELECTOR_KEY=your-node-selector-key \
  --set job.env.NODE_SELECTOR_VALUE=your-node-selector-value \
  --set job.env.TOLERATION_KEY=your-toleration-key \
  --set-string job.env.TOLERATION_VALUE="" \
  --set job.env.TOLERATION_OPERATOR=Exists \
  --set job.env.TOLERATION_EFFECT=NoSchedule \
  --set job.nodeSelector.your-node-selector-key=your-node-selector-value \
  --set 'job.tolerations[0].key=your-toleration-key' \
  --set 'job.tolerations[0].operator=Exists' \
  --set 'job.tolerations[0].effect=NoSchedule' \
  --set cronjob.nodeSelector.your-node-selector-key=your-node-selector-value \
  --set 'cronjob.tolerations[0].key=your-toleration-key' \
  --set 'cronjob.tolerations[0].operator=Exists' \
  --set 'cronjob.tolerations[0].effect=NoSchedule' \
  --set globals.labels."company\.com/team"=platform \
  --set globals.labels."company\.com/env"=prod \
  --set globals.labels."company\.com/component"=onelens
```

When you use `globals.labels`, the deployer job also applies those labels to the **namespace** `onelens-agent` (if the namespace is created by Helm or already exists). Labels flow to all deployer resources and to every agent deployment (Prometheus, KSM, Pushgateway, OpenCost, onelens-agent CronJob).

## 📚 Documentation

- [🏗️ CI/CD Architecture](docs/ci-cd-architecture.md) - Complete CI/CD pipeline documentation
- [⚡ Quick Reference](docs/quick-reference.md) - Fast commands and troubleshooting
- [📖 Release Process](docs/release-process.md) - How to create new releases
- [🔄 CI/CD Flow](docs/ci-cd-flow.md) - Understanding the automation pipeline
- [⚙️ Configuration Guide](docs/configuration.md) - Detailed configuration options
- [🔧 Development Guide](docs/development.md) - Contributing and development setup

## 🛠️ Scripts & Tools

- [🔍 Pre-requisite Checker](scripts/prereq-check/README.md) - Automated environment validation script
- [📦 Tools Installation Guide](scripts/prereq-check/tools-installation.md) - Step-by-step installation for required tools

## 🔄 Architecture

```mermaid
graph TB
    subgraph "OneLens Installation"
        A[OneLens Deployer] --> B[Cluster Setup]
        B --> C[OneLens Agent Deployment]
    end
    
    subgraph "Monitoring Stack"
        C --> D[OneLens Agent]
        D --> E[Prometheus]
        D --> F[OpenCost Exporter]
        E --> G[Metrics Storage]
        F --> G
    end
    
    subgraph "Data Flow"
        G --> H[Cost Analysis]
        H --> I[OneLens Platform]
    end
```

## 🏷️ Versioning

This project follows [Semantic Versioning](https://semver.org/). Version history and release notes are available in:
- [OneLens Agent Versions](charts/onelens-agent/version.md)
- [Release Tags](https://github.com/astuto-ai/onelens-installation-scripts/releases)

## 🤝 Contributing

We welcome contributions! Please see our [Development Guide](docs/development.md) for details on:
- Setting up development environment
- Running tests
- Submitting pull requests


## 📞 Support

- 📧 Email: support@astuto.ai
- 📖 Documentation: [OneLens Docs](https://docs.onelens.cloud/integrations/kubernetes/onelens-agent/onboarding-a-k8s-cluster)
- 🐛 Issues: [GitHub Issues](https://github.com/astuto-ai/onelens-installation-scripts/issues)

## 🚀 What's Next?

After installation, your cluster will be monitored by OneLens. Visit the OneLens platform to:
- View real-time cost analytics
- Get optimization recommendations
- Set up cost alerts and budgets
- Analyze resource utilization trends

---

**Made with ❤️ by the OneLens Team**



