# OneLens Air-Gapped Deployment Guide

Deploy OneLens on Kubernetes clusters that have restricted or no internet access. This guide walks you through mirroring container images to your private registry and deploying using Helm.

---

## How It Works

```
┌──────────────────────────────────────────────────────────────────┐
│                    MACHINE WITH INTERNET ACCESS                   │
│                                                                  │
│  Step 1: Validate connectivity                                   │
│  ┌──────────────────────────────┐                                │
│  │ airgapped_accessibility      │                                │
│  │ _check.sh                    │──→ Tests OneLens API + S3      │
│  └──────────────────────────────┘                                │
│                                                                  │
│  Step 2: Mirror container images to your private registry        │
│  ┌──────────────────────────────┐    ┌────────────────────────┐  │
│  │ airgapped_migrate_images.sh  │──→ │ Public registries ──→  │  │
│  │   --version <ver>            │    │ Your private ECR       │  │
│  └──────────────────────────────┘    └────────────────────────┘  │
│                                                                  │
│  Step 3: Deploy OneLens agent on your cluster                    │
│  ┌──────────────────────────────┐    ┌────────────────────────┐  │
│  │ airgapped_deployment.sh      │──→ │ helm upgrade --install │  │
│  │   --version <ver>            │    │ (images from your ECR) │  │
│  └──────────────────────────────┘    └───────────┬────────────┘  │
│                                                  │               │
│  Step 4 (optional): Setup automatic patching     │               │
│  ┌──────────────────────────────┐                │               │
│  │ airgapped_patch_onboard.sh   │                │               │
│  └──────────────────────────────┘                │               │
└──────────────────────────────────────────────────┼───────────────┘
                                                   │
                ┌──────────────────────────────────┼───────────────┐
                │        YOUR KUBERNETES CLUSTER                   │
                │        (No internet access required)             │
                │        Only outbound: *.onelens.cloud            │
                │                                                  │
                │   ┌──────────────┐  ┌──────────────────────────┐ │
                │   │ OneLens      │  │ Prometheus + OpenCost    │ │
                │   │ Agent        │  │ + KSM + Pushgateway      │ │
                │   └──────┬───────┘  └──────────┬───────────────┘ │
                │          │                     │                 │
                │   All images pulled from YOUR private registry   │
                │   API calls go to api-in.onelens.cloud only      │
                └──────────────────────────────────────────────────┘
```

### Upgrade Flow

When a new OneLens version is released, re-run steps 2 and 3 with the new version:

```
airgapped_migrate_images.sh --version <new-version>   # mirror new images
airgapped_patching.sh --version <new-version>          # upgrade the deployment
```

If you set up auto-patching (Step 4), the CronJob handles upgrades automatically.

---

## Prerequisites

### Tools (on the machine with internet access)

| Tool | Purpose | Install |
|------|---------|---------|
| AWS CLI v2 | ECR authentication and repo management | [Install guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) |
| Docker (with buildx) | Pull and push multi-arch images | [Install guide](https://docs.docker.com/get-docker/) |
| kubectl | Kubernetes cluster access | [Install guide](https://kubernetes.io/docs/tasks/tools/) |
| Helm v3 | Chart deployment | [Install guide](https://helm.sh/docs/intro/install/) |
| jq | JSON parsing | [Install guide](https://jqlang.github.io/jq/download/) |

### Network Access

The machine running these scripts needs outbound access to the following URLs:

| URL | Purpose |
|-----|---------|
| `https://api-in.onelens.cloud` | OneLens API (cluster registration, status updates) |
| `https://astuto-ai.github.io` | Helm chart repository |
| `https://raw.githubusercontent.com` | Script and config file downloads |
| `https://public.ecr.aws` | OneLens agent and deployer images |
| `https://quay.io` | Prometheus, config-reloader, pushgateway images |
| `https://registry.k8s.io` | kube-state-metrics image |
| `https://ghcr.io` | OpenCost image |

**Your Kubernetes cluster nodes** only need outbound access to:

| URL | Purpose |
|-----|---------|
| `https://*.onelens.cloud` | Agent API communication and data upload |
| Your private ECR endpoint | Pulling container images |

> **Note:** The OneLens agent receives upload URLs from the API at runtime. For air-gapped environments, data upload is routed through `api-in-fileupload.onelens.cloud` (an OneLens-hosted upload gateway), so no direct access to cloud storage endpoints (GCS/S3) is required. The `*.onelens.cloud` wildcard covers both the API and the upload gateway.

### AWS Permissions

The IAM role or user running the migration script needs:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:CreateRepository",
        "ecr:DescribeRepositories",
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:PutImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload"
      ],
      "Resource": "*"
    }
  ]
}
```

Your EKS **node IAM role** (or imagePullSecrets) needs read access to the private ECR repositories:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:BatchCheckLayerAvailability"
      ],
      "Resource": "arn:aws:ecr:<region>:<account-id>:repository/*"
    },
    {
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    }
  ]
}
```

> Replace `<region>` and `<account-id>` with your AWS region and account ID.

### Validation

Before proceeding, verify network access from your machine:

```bash
nslookup api-in.onelens.cloud
nslookup astuto-ai.github.io
```

---

## Step 1: Validate Connectivity

Download and run the accessibility check script to verify that your environment can reach the required OneLens services.

```bash
curl -fsSL https://raw.githubusercontent.com/astuto-ai/onelens-installation-scripts/master/scripts/airgapped/airgapped_accessibility_check.sh -o airgapped_accessibility_check.sh

bash airgapped_accessibility_check.sh \
  --registration-token <your-registration-token> \
  --cluster-name <your-cluster-name> \
  --account <your-aws-account-id> \
  --region <your-aws-region>
```

The script tests:
- OneLens API registration endpoint
- S3 pre-signed URL upload capability

If both tests pass, proceed to Step 2.

---

## Step 2: Mirror Images to Your Private Registry

This script pulls all required container images from public registries and pushes them to your private ECR. It reads the image list dynamically from the OneLens release configuration, so no manual image tracking is needed.

```bash
curl -fsSL https://raw.githubusercontent.com/astuto-ai/onelens-installation-scripts/master/scripts/airgapped/airgapped_migrate_images.sh -o airgapped_migrate_images.sh

bash airgapped_migrate_images.sh --version <version>
```

The script will:
1. Prompt for your AWS account ID and region (auto-detected from AWS CLI if configured)
2. Fetch the image list for the specified version
3. Create ECR repositories if they don't exist
4. Pull each image from its public registry
5. Push multi-architecture images (amd64 + arm64) to your ECR

**Omit `--version` to use the latest published version.**

### Verify

After the script completes, confirm the images exist in your ECR:

```bash
aws ecr describe-repositories --region <region> --query 'repositories[].repositoryName' --output table
```

You should see repositories for: `onelens-agent`, `onelens-deployer`, `prometheus`, `opencost`, `prometheus-config-reloader`, `kube-state-metrics`, `pushgateway`, `kube-rbac-proxy`.

---

## Step 3: Deploy OneLens Agent

This script registers your cluster with the OneLens API and deploys the agent using Helm, with all container images pointing to your private registry.

```bash
curl -fsSL https://raw.githubusercontent.com/astuto-ai/onelens-installation-scripts/master/scripts/airgapped/airgapped_deployment.sh -o airgapped_deployment.sh

bash airgapped_deployment.sh --version <version>
```

The script will interactively prompt for:

| Prompt | Description |
|--------|-------------|
| Registry URL | Your ECR URL (e.g., `123456789.dkr.ecr.us-east-1.amazonaws.com`) |
| Registration token | Provided by your OneLens account team |
| Cluster name | A unique name for this cluster |
| Image pull secret | Kubernetes secret name for ECR auth (or press Enter to skip) |
| Tolerations / Node selectors | Optional — for scheduling on specific nodes |

**Omit `--version` to use the latest published version.**

### What it does

1. Registers the cluster with the OneLens API
2. Counts pods in the cluster to determine the right resource tier
3. Downloads the Helm values file for the specified version
4. Runs `helm upgrade --install` with image overrides pointing to your ECR
5. Deploys the OneLens deployer CronJob for automated maintenance
6. Waits for pods to become ready
7. Updates cluster status to `CONNECTED`

### Verify

```bash
kubectl get pods -n onelens-agent
```

All pods should be in `Running` state:
- `onelens-agent-*`
- `onelens-agent-prometheus-server-*`
- `onelens-agent-prometheus-opencost-exporter-*`
- `onelens-agent-prometheus-kube-state-metrics-*`
- `onelens-agent-prometheus-pushgateway-*`

---

## Step 4: Setup Auto-Patching (Optional)

This script creates Kubernetes RBAC rules and a CronJob that automatically checks for and applies updates.

```bash
curl -fsSL https://raw.githubusercontent.com/astuto-ai/onelens-installation-scripts/master/scripts/airgapped/airgapped_patch_onboard.sh -o airgapped_patch_onboard.sh

bash airgapped_patch_onboard.sh
```

The CronJob:
- Runs daily at 2:00 AM UTC
- Downloads the latest `airgapped_patching.sh` from GitHub
- Performs a Helm upgrade with current resource sizing based on cluster size
- Uses the existing registry configuration from the deployed release

> **Important:** The machine or pod running the CronJob needs internet access to download the patching script from GitHub. If your job runner nodes have internet access, this works automatically.

---

## Upgrading to a New Version

When a new OneLens version is released:

### Manual upgrade

```bash
# 1. Mirror the new images
bash airgapped_migrate_images.sh --version <new-version>

# 2. Upgrade the deployment
bash airgapped_patching.sh --version <new-version>
```

### Automatic upgrade (if Step 4 was completed)

The CronJob picks up the latest version automatically. Just ensure the new images are mirrored to your ECR first:

```bash
bash airgapped_migrate_images.sh --version <new-version>
```

The next CronJob run will upgrade the agent to the latest version.

---

## Troubleshooting

### Image pull errors

```
ErrImagePull or ImagePullBackOff
```

**Cause:** Cluster nodes can't pull from your private ECR.

**Fix:**
1. Verify the image exists in your ECR: `aws ecr describe-images --repository-name <repo> --region <region>`
2. Check node IAM role has ECR read permissions (see Prerequisites)
3. If using imagePullSecrets, verify the secret exists: `kubectl get secret <secret-name> -n onelens-agent`

### Helm timeout

```
Error: timed out waiting for the condition
```

**Cause:** Pods failed to start within the timeout period.

**Fix:**
1. Check pod status: `kubectl describe pod <pod-name> -n onelens-agent`
2. Check pod logs: `kubectl logs <pod-name> -n onelens-agent`
3. Common causes: image pull failure, insufficient resources, PVC binding issues

### API registration failure

```
API registration failed. REGISTRATION_ID or CLUSTER_TOKEN are empty or null.
```

**Cause:** Can't reach OneLens API or invalid registration token.

**Fix:**
1. Verify DNS resolution: `nslookup api-in.onelens.cloud`
2. Verify connectivity: `curl -s https://api-in.onelens.cloud/health`
3. Confirm registration token with your OneLens account team

### PVC not binding

```
pod has unbound immediate PersistentVolumeClaims
```

**Cause:** No matching StorageClass or CSI driver issue.

**Fix:**
1. Check available StorageClasses: `kubectl get storageclass`
2. Verify EBS CSI driver is installed: `kubectl get pods -n kube-system | grep ebs`
3. During deployment, you can disable PVC by responding when prompted

---

## Container Images Reference

The following images are mirrored by `airgapped_migrate_images.sh`. This list is fetched dynamically per version — you don't need to track it manually.

| Image | Source Registry | Purpose |
|-------|----------------|---------|
| `onelens-agent` | `public.ecr.aws` | OneLens data collection agent |
| `onelens-deployer` | `public.ecr.aws` | Automated deployer/patcher |
| `prometheus` | `quay.io` | Metrics collection |
| `opencost` | `ghcr.io` | Cost analysis exporter |
| `prometheus-config-reloader` | `quay.io` | Prometheus config reload sidecar |
| `kube-state-metrics` | `registry.k8s.io` | Kubernetes state metrics |
| `pushgateway` | `quay.io` | Prometheus push gateway |
| `kube-rbac-proxy` | `quay.io` | RBAC proxy for kube-state-metrics |

> Exact tags depend on the version you deploy. The migration script handles this automatically.

---

## Support

For issues with air-gapped deployment, contact your OneLens account team with:
- Output of `airgapped_accessibility_check.sh`
- Cluster name and version deployed
- `kubectl get pods -n onelens-agent -o wide`
- `kubectl describe pod <failing-pod> -n onelens-agent`
- `helm list -n onelens-agent`
