# OneLens Installation Scripts

> **Simplified Kubernetes cost optimization and monitoring deployment**

[![Documentation](https://img.shields.io/badge/Documentation-OneLens-00C851?logo=gitbook)](https://docs.onelens.cloud/integrations/kubernetes/onelens-agent/onboarding-a-k8s-cluster)
[![Helm Charts](https://img.shields.io/badge/Helm-Charts-0F1689?logo=helm)](https://astuto-ai.github.io/onelens-installation-scripts/)
[![Docker](https://img.shields.io/badge/Docker-Multi--Arch-2496ED?logo=docker)](https://gallery.ecr.aws/w7k6q5m9/onelens-deployer)

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start) — install in one command
- [Configuration Reference](#configuration-reference) — all helm parameters with examples
- [Upgrade](#upgrade)
- [Uninstall](#uninstall)
- [Troubleshooting](docs/troubleshooting.md) — common issues, diagnostic commands, operations
- [Air-Gapped Deployment](#air-gapped-deployment) — deploy on clusters with no public internet
- [How It Works](#how-it-works)
- [Documentation](#documentation)
- [Support](#support)

## Overview

OneLens deploys a monitoring stack into your Kubernetes cluster to collect cost and resource utilization data. The deployment consists of two parts:

1. **OneLens Deployer** (this chart) - A Kubernetes Job that installs and configures the monitoring stack. A daily CronJob keeps it updated.
2. **OneLens Agent** (installed by the deployer) - The monitoring stack: OneLens Agent, Prometheus, OpenCost, and Kube-State-Metrics.

You only install the **deployer** chart. It handles everything else.

## Prerequisites

- Kubernetes cluster (1.25+)
- Helm 3.0+
- `kubectl` configured for your cluster
- AWS EBS CSI driver (for AWS EKS clusters) or Azure Disk CSI driver (for AKS clusters). Alternatively, AWS EFS CSI driver or Azure Files CSI driver for multi-AZ storage — see [Multi-AZ Storage](#multi-az-storage)
- Minimum node resources available: 50m CPU and 256Mi memory for the deployer job

Run the pre-requisite checker to validate your environment before installing. It checks connectivity, tools, Kubernetes version, and CSI driver status:

```bash
curl -sSL https://raw.githubusercontent.com/astuto-ai/onelens-installation-scripts/master/scripts/prereq-check/onelens-prereq-check.sh | bash
```

## Quick Start

### 1. Install

Your Kubernetes clusters are automatically discovered and visible in the OneLens console. Navigate to the cluster you want to connect, and the console provides a ready-to-use install command with the `REGISTRATION_TOKEN` pre-filled. Copy and run it directly, or use the template below:

```bash
helm repo add onelens https://astuto-ai.github.io/onelens-installation-scripts/ && \
helm repo update && \
helm upgrade --install onelensdeployer onelens/onelensdeployer \
  -n onelens-agent --create-namespace \
  --set job.env.CLUSTER_NAME=<cluster-name> \
  --set job.env.REGION=<region> \
  --set-string job.env.ACCOUNT=<account-id> \
  --set job.env.REGISTRATION_TOKEN=<token>
```

Need to run on dedicated nodes, add labels, or encrypt volumes?
See the [Configuration Reference](#configuration-reference) for all optional parameters.

### 2. Verify installation

```bash
# Check all pods are running
kubectl get pods -n onelens-agent

# Expected pods (all should be Running):
#   onelens-agent-prometheus-server-*        - Metrics storage
#   onelens-agent-kube-state-metrics-*       - Kubernetes object metrics
#   onelens-agent-prometheus-opencost-*      - Cost metrics
#   onelens-agent-prometheus-pushgateway-*   - Metrics push endpoint
#
# Note: The onelens-agent pod is a CronJob that runs hourly by default.
# It collects metrics from Prometheus and sends them to the OneLens API.
# It will not appear until its first scheduled run. To trigger it immediately,
# see step 3 below.
```

### 3. Trigger data collection

Once all 4 pods are Running and healthy for at least 2 minutes, trigger the first data collection. This is optional — it runs automatically on the hourly schedule — but a successful job completion verifies that everything is set up correctly.

```bash
kubectl create job manual-trigger --from=cronjob/onelens-agent -n onelens-agent
```

Your cluster will show as **Connected** in the OneLens console within ~15 minutes of installation. Cost data becomes available after 48 hours once it can be mapped with your cloud provider's cost and usage reports.

---

## Configuration Reference

All parameters below are passed via `--set` flags during `helm upgrade --install`. Examples are shown with each section so you can copy-paste and adapt.

- [Required Parameters](#required-parameters) — cluster name, region, account, token
- [Storage Encryption](#storage-encryption) — encrypt Prometheus persistent volumes (AWS EBS / Azure Disk)
- [Multi-AZ Storage](#multi-az-storage) — use EFS or Azure Files to avoid AZ-lock scheduling issues
- [Volume Tags](#volume-tags) — apply custom tags to persistent volumes for cost tracking
- [Node Scheduling](#node-scheduling) — run OneLens pods on dedicated or specific nodes
- [Labels](#labels) — apply custom labels to all OneLens resources
- [Other](#other) — image pull secrets, CronJob schedule, suspend updater

### Required Parameters

| Parameter | Description |
|---|---|
| `job.env.CLUSTER_NAME` | Your Kubernetes cluster name |
| `job.env.REGION` | Cloud region (e.g., `us-east-1`, `centralindia`) |
| `job.env.ACCOUNT` | Cloud account ID (use `--set-string` to preserve leading zeros) |
| `job.env.REGISTRATION_TOKEN` | Registration token from OneLens platform |

<details>
<summary><strong>AWS EKS example</strong></summary>

```bash
helm upgrade --install onelensdeployer onelens/onelensdeployer \
  -n onelens-agent --create-namespace \
  --set job.env.CLUSTER_NAME=my-eks-cluster \
  --set job.env.REGION=us-east-1 \
  --set-string job.env.ACCOUNT=123456789012 \
  --set job.env.REGISTRATION_TOKEN=your-token
```

</details>

<details>
<summary><strong>Azure AKS example</strong></summary>

```bash
helm upgrade --install onelensdeployer onelens/onelensdeployer \
  -n onelens-agent --create-namespace \
  --set job.env.CLUSTER_NAME=my-aks-cluster \
  --set job.env.REGION=centralindia \
  --set-string job.env.ACCOUNT=your-subscription-id \
  --set job.env.REGISTRATION_TOKEN=your-token
```

</details>

### Storage Encryption

OneLens creates a StorageClass for Prometheus persistent volumes. You can enable encryption on these volumes.

<details>
<summary><strong>AWS EBS</strong></summary>

| Parameter | Description | Default |
|---|---|---|
| `job.env.EBS_ENCRYPTION_ENABLED` | Enable EBS volume encryption | `false` |
| `job.env.EBS_ENCRYPTION_KEY` | Custom KMS key ARN (omit to use AWS default `aws/ebs` key) | `""` |

Encrypt with the default AWS-managed key (`aws/ebs`):

```bash
helm upgrade --install onelensdeployer onelens/onelensdeployer \
  -n onelens-agent --create-namespace \
  --set job.env.CLUSTER_NAME=my-eks-cluster \
  --set job.env.REGION=us-east-1 \
  --set-string job.env.ACCOUNT=123456789012 \
  --set job.env.REGISTRATION_TOKEN=your-token \
  --set job.env.EBS_ENCRYPTION_ENABLED=true
```

Encrypt with a customer-managed KMS key:

```bash
helm upgrade --install onelensdeployer onelens/onelensdeployer \
  -n onelens-agent --create-namespace \
  --set job.env.CLUSTER_NAME=my-eks-cluster \
  --set job.env.REGION=us-east-1 \
  --set-string job.env.ACCOUNT=123456789012 \
  --set job.env.REGISTRATION_TOKEN=your-token \
  --set job.env.EBS_ENCRYPTION_ENABLED=true \
  --set job.env.EBS_ENCRYPTION_KEY=arn:aws:kms:us-east-1:123456789012:key/your-key-id
```

</details>

<details>
<summary><strong>Azure Disk</strong></summary>

| Parameter | Description | Default |
|---|---|---|
| `job.env.AZURE_DISK_ENCRYPTION_ENABLED` | Enable Azure Disk encryption | `false` |
| `job.env.AZURE_DISK_ENCRYPTION_SET_ID` | Azure Disk Encryption Set resource ID | `""` |
| `job.env.AZURE_DISK_CACHING_MODE` | Disk caching mode (`None`, `ReadOnly`, `ReadWrite`) | `ReadOnly` |

```bash
helm upgrade --install onelensdeployer onelens/onelensdeployer \
  -n onelens-agent --create-namespace \
  --set job.env.CLUSTER_NAME=my-aks-cluster \
  --set job.env.REGION=centralindia \
  --set-string job.env.ACCOUNT=your-subscription-id \
  --set job.env.REGISTRATION_TOKEN=your-token \
  --set job.env.AZURE_DISK_ENCRYPTION_ENABLED=true \
  --set job.env.AZURE_DISK_ENCRYPTION_SET_ID=/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Compute/diskEncryptionSets/<des-name>
```

</details>

### Multi-AZ Storage

By default, OneLens uses block storage (EBS on AWS, Azure Disk on AKS) for Prometheus data. These volumes are **AZ-locked** — if the node hosting Prometheus moves to a different availability zone (common with spot instances or node scaling), Prometheus can't start because its volume is in the original AZ.

To avoid this, use multi-AZ file storage instead. This is recommended for clusters that use spot instances or have limited node capacity per AZ.

<details>
<summary><strong>AWS EFS</strong></summary>

Requires a pre-created EFS filesystem. The EFS CSI driver creates access points inside it automatically.

**Prerequisites:**
1. [EFS CSI driver](https://docs.aws.amazon.com/eks/latest/userguide/efs-csi.html) installed on your cluster
2. An EFS filesystem created in the same VPC as your EKS cluster
3. Mount targets in the subnets where your EKS nodes run
4. Security group allowing NFS traffic (port 2049) from node security group

| Parameter | Description |
|---|---|
| `job.env.EFS_FILESYSTEM_ID` | EFS filesystem ID (e.g., `fs-0abc123def456`) |

```bash
helm upgrade --install onelensdeployer onelens/onelensdeployer \
  -n onelens-agent --create-namespace \
  --set job.env.CLUSTER_NAME=my-eks-cluster \
  --set job.env.REGION=us-east-1 \
  --set-string job.env.ACCOUNT=123456789012 \
  --set job.env.REGISTRATION_TOKEN=your-token \
  --set job.env.EFS_FILESYSTEM_ID=fs-0abc123def456
```

</details>

<details>
<summary><strong>Azure Files</strong></summary>

No pre-created resources needed. The Azure Files CSI driver provisions storage accounts and file shares dynamically.

**Prerequisites:**
1. [Azure Files CSI driver](https://learn.microsoft.com/en-us/azure/aks/azure-files-csi) enabled on your AKS cluster (enabled by default on AKS 1.21+)
2. Managed identity with `Storage Account Contributor` role

| Parameter | Description | Default |
|---|---|---|
| `job.env.AZURE_FILES_ENABLED` | Enable Azure Files instead of Azure Disk | `false` |

```bash
helm upgrade --install onelensdeployer onelens/onelensdeployer \
  -n onelens-agent --create-namespace \
  --set job.env.CLUSTER_NAME=my-aks-cluster \
  --set job.env.REGION=centralindia \
  --set-string job.env.ACCOUNT=your-subscription-id \
  --set job.env.REGISTRATION_TOKEN=your-token \
  --set job.env.AZURE_FILES_ENABLED=true
```

</details>

### Volume Tags

Apply custom tags to the persistent volumes created by OneLens. Useful for cost tracking and compliance.

<details>
<summary><strong>AWS EBS</strong></summary>

| Parameter | Description | Default |
|---|---|---|
| `job.env.EBS_TAGS_ENABLED` | Enable custom tags on EBS volumes | `false` |
| `job.env.EBS_TAGS` | Comma-separated `key=value` pairs | `""` |

```bash
  --set job.env.EBS_TAGS_ENABLED=true \
  --set job.env.EBS_TAGS="env=prod,team=platform,cost-center=engineering"
```

</details>

<details>
<summary><strong>Azure Disk</strong></summary>

| Parameter | Description | Default |
|---|---|---|
| `job.env.AZURE_DISK_TAGS_ENABLED` | Enable custom tags on Azure Disks | `false` |
| `job.env.AZURE_DISK_TAGS` | Comma-separated `key=value` pairs | `""` |

```bash
  --set job.env.AZURE_DISK_TAGS_ENABLED=true \
  --set job.env.AZURE_DISK_TAGS="env=prod,team=platform,cost-center=engineering"
```

</details>

### Node Scheduling

Schedule OneLens pods on specific nodes using nodeSelector and tolerations. The `job.env.*` parameters apply to the **agent pods** (Prometheus, KSM, OpenCost, etc.). To also schedule the **deployer job/cronjob** on the same nodes, set `job.tolerations`, `job.nodeSelector`, `cronjob.tolerations`, and `cronjob.nodeSelector` as shown in the example.

| Parameter | Description | Default |
|---|---|---|
| `job.env.NODE_SELECTOR_KEY` | Node selector label key (applied to all agent pods) | `""` |
| `job.env.NODE_SELECTOR_VALUE` | Node selector label value | `""` |
| `job.env.TOLERATION_KEY` | Toleration key (applied to all agent pods) | `""` |
| `job.env.TOLERATION_VALUE` | Toleration value (leave empty for `Exists` operator) | `""` |
| `job.env.TOLERATION_OPERATOR` | `Equal` or `Exists` | `""` |
| `job.env.TOLERATION_EFFECT` | `NoSchedule`, `PreferNoSchedule`, or `NoExecute` | `""` |

**Example** — nodes tainted with `dedicated=onelens:NoSchedule`:

```bash
helm upgrade --install onelensdeployer onelens/onelensdeployer \
  -n onelens-agent --create-namespace \
  --set job.env.CLUSTER_NAME=my-cluster \
  --set job.env.REGION=us-east-1 \
  --set-string job.env.ACCOUNT=123456789012 \
  --set job.env.REGISTRATION_TOKEN=your-token \
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

For taints without a value (e.g., `dedicated:NoSchedule`), use `Exists` operator and omit the value:

```bash
  --set job.env.TOLERATION_OPERATOR=Exists \
  --set-string job.env.TOLERATION_VALUE="" \
  --set 'job.tolerations[0].operator=Exists'
```

### Labels

Apply custom labels to OneLens resources. Useful for organizational policies that require specific labels on all resources.

| Parameter | Description | Default |
|---|---|---|
| `globals.labels` | Applied to namespace, deployer job/cronjob, and all agent pods | `{}` |
| `job.labels` | Additional labels only on the deployer job | `{}` |
| `cronjob.labels` | Additional labels only on the updater cronjob | `{}` |

```bash
  --set globals.labels."company\.com/team"=platform \
  --set globals.labels."company\.com/env"=prod
```

### Other

| Parameter | Description | Default |
|---|---|---|
| `job.env.IMAGE_PULL_SECRET` | Image pull secret name for private registries | `""` |
| `cronjob.schedule` | Updater CronJob schedule | `"0 2 * * *"` |
| `cronjob.suspend` | Suspend the daily updater | `false` |

---

## Upgrade

To upgrade to a newer version:

```bash
helm repo update
helm upgrade onelensdeployer onelens/onelensdeployer \
  -n onelens-agent --reuse-values
```

This upgrades the deployer CronJob to the latest image. All existing configuration (tolerations, nodeSelector, labels, encryption settings) is preserved via `--reuse-values`. The CronJob automatically detects the version mismatch on its next run and upgrades the agent stack.

## Uninstall

```bash
# Remove the deployer
helm uninstall onelensdeployer -n onelens-agent

# Remove the agent stack (installed by the deployer)
helm uninstall onelens-agent -n onelens-agent

# Optionally delete the namespace and all resources
kubectl delete namespace onelens-agent
```

PersistentVolumeClaims are retained by default (`helm.sh/resource-policy: keep`) to preserve data across upgrades. Only delete them if you are facing persistent volume issues that cannot be resolved through upgrade, and as a last resort. All cluster utilization metrics stored locally will be permanently lost.

```bash
# WARNING: This permanently deletes all locally stored Prometheus metrics data
kubectl delete pvc -n onelens-agent --all
```

## Troubleshooting

See the [Troubleshooting Guide](docs/troubleshooting.md) for common issues, diagnostic commands, and operational procedures.

---

## Air-Gapped Deployment

For Kubernetes clusters that cannot reach public container registries (`public.ecr.aws`, `quay.io`, `ghcr.io`, `registry.k8s.io`), OneLens supports deployment from a private OCI registry.

**The install command is the same** — the only difference is the chart source:

```bash
helm upgrade --install onelensdeployer \
  oci://<your-registry>/charts/onelensdeployer \
  -n onelens-agent --create-namespace \
  --set job.env.CLUSTER_NAME=<cluster-name> \
  --set job.env.REGION=<region> \
  --set-string job.env.ACCOUNT=<account-id> \
  --set job.env.REGISTRATION_TOKEN=<token>
```

**Setup:** Run the migration script once per version on an internet-connected machine to mirror images and charts to your private registry:

```bash
curl -fsSL https://astuto-ai.github.io/onelens-installation-scripts/scripts/airgapped/airgapped_migrate_images.sh | bash -s -- \
  --registry <your-registry-url>
```

The script auto-detects the latest version. Add `--version <version>` to pin a specific version.

For full instructions, prerequisites, and troubleshooting, see the [Air-Gapped Deployment Guide](docs/airgapped-deployment-guide.md).

---

## What does the installation do?

You install one Helm chart (`onelensdeployer`). It runs a one-time Job that connects your cluster to your OneLens account, detects your cloud provider, and installs the full monitoring stack (`onelens-agent` chart) with right-sized resources.

After that, a CronJob runs every 5 minutes to healthcheck the stack. If anything is unhealthy or a new version is available, it automatically remediates — no manual intervention needed.

**What gets deployed:**

| Component | Purpose |
|---|---|
| Prometheus | Collects and stores cluster metrics |
| Kube-State-Metrics | Exposes Kubernetes object state as metrics |
| OpenCost | Calculates per-workload cost from cloud pricing + usage |
| OneLens Agent | Processes collected metrics and uploads to OneLens platform |
| Pushgateway | Receives metrics from batch jobs |
| Updater CronJob | Healthchecks the stack, auto-upgrades, right-sizes resources |

## Documentation

- [CI/CD Architecture](docs/ci-cd-architecture.md) - Complete CI/CD pipeline documentation
- [Quick Reference](docs/quick-reference.md) - Fast commands and troubleshooting
- [Release Process](docs/release-process.md) - How to create new releases
- [Configuration Guide](docs/configuration.md) - Detailed configuration options

## Scripts & Tools

- [Pre-requisite Checker](scripts/prereq-check/README.md) - Validate your environment before installation
- [EBS Driver Installation](scripts/ebs-driver-installation/) - Install AWS EBS CSI driver with IAM roles
- [Dedicated Node Setup](scripts/dedicated-node-installation/) - Create tainted node pools for OneLens
- [Air-Gapped Migration](scripts/airgapped/) - Mirror images and charts to private registries

## Support

- Email: support@astuto.ai
- Documentation: [OneLens Docs](https://docs.onelens.cloud/integrations/kubernetes/onelens-agent/onboarding-a-k8s-cluster)
- Issues: [GitHub Issues](https://github.com/astuto-ai/onelens-installation-scripts/issues)
