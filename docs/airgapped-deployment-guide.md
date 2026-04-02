# OneLens Air-Gapped Deployment Guide

Deploy OneLens on Kubernetes clusters that have restricted or no internet access. This guide walks you through mirroring container images to your private registry and deploying using the standard Helm command.

---

## How It Works

```
┌──────────────────────────────────────────────────────────────────┐
│               MACHINE WITH INTERNET ACCESS                       │
│                                                                  │
│  One-time per version:                                           │
│  ┌──────────────────────────────┐    ┌────────────────────────┐  │
│  │ airgapped_migrate_images.sh  │──→ │ Public registries ──→  │  │
│  │   --version <ver>            │    │ Your private registry  │  │
│  │   --registry <url>           │    │ (images + Helm charts) │  │
│  └──────────────────────────────┘    └────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│               PER CLUSTER (same as standard install)             │
│                                                                  │
│  helm upgrade --install onelensdeployer                          │
│    oci://<your-registry>/charts/onelensdeployer \                │
│    -n onelens-agent --create-namespace \                         │
│    --set job.env.CLUSTER_NAME=<name> \                           │
│    --set job.env.REGION=<region> \                               │
│    --set-string job.env.ACCOUNT=<account> \                      │
│    --set job.env.REGISTRATION_TOKEN=<token>                      │
│                                                                  │
└───────────────────────────────┬──────────────────────────────────┘
                                │
                ┌───────────────┼──────────────────────────────────┐
                │        YOUR KUBERNETES CLUSTER                   │
                │        (No internet access required)             │
                │        Only outbound: *.onelens.cloud            │
                │                       + your private registry    │
                │                                                  │
                │   ┌──────────────┐  ┌──────────────────────────┐ │
                │   │ OneLens      │  │ Prometheus + OpenCost    │ │
                │   │ Agent        │  │ + KSM + Pushgateway      │ │
                │   └──────┬───────┘  └──────────┬───────────────┘ │
                │          │                     │                 │
                │   All images pulled from YOUR private registry   │
                │   API calls go to *.onelens.cloud only           │
                │                                                  │
                │   ┌──────────────────────────────────────────┐   │
                │   │ Updater CronJob (onelensupdater)         │   │
                │   │ Runs every 5 minutes                     │   │
                │   │ Detects new version in private registry  │   │
                │   │ Upgrades automatically                   │   │
                │   └──────────────────────────────────────────┘   │
                └──────────────────────────────────────────────────┘
```

---

## Prerequisites

### Tools (on the machine with internet access)

| Tool | Purpose |
|------|---------|
| AWS CLI v2 | ECR authentication and repo management |
| Docker (with buildx) | Pull and push multi-arch images |
| Helm v3 | Chart deployment |
| jq | JSON parsing |

> **Note:** This guide assumes AWS ECR as the private registry. If you use a different registry (Harbor, Artifactory, GCR, etc.), adapt the registry authentication and image push commands accordingly — the Helm install command remains the same.

### Network Access

**Setup machine** (internet-connected):

| URL | Used in | Purpose |
|-----|---------|---------|
| `https://api-in.onelens.cloud` | Pre-check | Validate connectivity to OneLens API |
| `https://astuto-ai.github.io` | Migration | Download Helm charts and version config from the OneLens public GitHub repository |
| `https://public.ecr.aws` | Migration | Pull `onelens-agent` and `onelens-deployer` container images |
| `https://quay.io` | Migration | Pull `prometheus`, `config-reloader`, `pushgateway`, `kube-rbac-proxy` images |
| `https://registry.k8s.io` | Migration | Pull `kube-state-metrics` image |
| `https://ghcr.io` | Migration | Pull `opencost` image |

**Cluster nodes** (air-gapped — no general internet access):

| URL | Purpose |
|-----|---------|
| `https://*.onelens.cloud` | Agent API communication and data upload (includes upload gateway) |
| Your private registry endpoint | Pulling container images |

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

---

## Step 1: Validate Connectivity (Optional)

Run the accessibility check to verify your environment can reach the required services.

```bash
curl -fsSL https://astuto-ai.github.io/onelens-installation-scripts/scripts/airgapped/airgapped_accessibility_check.sh -o airgapped_accessibility_check.sh

bash airgapped_accessibility_check.sh \
  --registration-token <your-registration-token> \
  --cluster-name <your-cluster-name> \
  --account <your-aws-account-id> \
  --region <your-aws-region>
```

The script tests:
- **OneLens API** — registration endpoint reachability (`api-in.onelens.cloud`)
- **Upload gateway** — data upload endpoint reachability (`api-in-fileupload.onelens.cloud`)
- **Private registry** — that cluster nodes can authenticate and pull from your registry

---

## Step 2: Mirror Images and Charts to Your Private Registry

This step runs **once per OneLens version** on your internet-connected machine. It mirrors all container images and Helm charts to your private registry.

```bash
curl -fsSL https://astuto-ai.github.io/onelens-installation-scripts/scripts/airgapped/airgapped_migrate_images.sh -o airgapped_migrate_images.sh

bash airgapped_migrate_images.sh \
  --version <version> \
  --registry <your-registry-url>
```

> **Important:** Always specify `--version` explicitly. The version must match what you deploy.

The script will:
1. Authenticate to your ECR (auto-detects account/region from the registry URL)
2. Fetch the image list for the specified version from `globalvalues.yaml`
3. Create ECR repositories if they don't exist
4. Pull each image from its public registry and push to your ECR (multi-arch: amd64 + arm64)
5. Pull the `onelensdeployer` and `onelens-agent` Helm charts
6. Rewrite the deployer chart image reference to point to your registry
7. Push both charts as OCI artifacts to your registry

### Verify

```bash
aws ecr describe-repositories --region <region> --query 'repositories[].repositoryName' --output table
```

You should see repositories for: `onelens-agent`, `onelens-deployer`, `prometheus`, `opencost`, `prometheus-config-reloader`, `kube-state-metrics`, `pushgateway`, `kube-rbac-proxy`, and the Helm charts.

---

## Step 3: Deploy OneLens on Each Cluster

Run the standard OneLens install command, pointing to your private registry instead of the public one.

**Standard install (for reference):**

```bash
helm repo add onelens https://astuto-ai.github.io/onelens-installation-scripts/ && helm repo update
helm upgrade --install onelensdeployer onelens/onelensdeployer \
  -n onelens-agent --create-namespace \
  --set job.env.CLUSTER_NAME=<cluster-name> \
  --set job.env.REGION=<region> \
  --set-string job.env.ACCOUNT=<account-id> \
  --set job.env.REGISTRATION_TOKEN=<token>
```

**Air-gapped install:**

```bash
helm upgrade --install onelensdeployer \
  oci://<your-registry>/charts/onelensdeployer \
  -n onelens-agent --create-namespace \
  --set job.env.CLUSTER_NAME=<cluster-name> \
  --set job.env.REGION=<region> \
  --set-string job.env.ACCOUNT=<account-id> \
  --set job.env.REGISTRATION_TOKEN=<token>
```

**The only differences:**
1. Chart source: `oci://<your-registry>/charts/onelensdeployer` instead of `onelens/onelensdeployer`
2. No `helm repo add` step needed — OCI references are direct

The deployer automatically detects that it's running from a private registry and configures all OneLens components to pull images from the same registry.

### What happens after you run this

1. Helm deploys the `onelensdeployer` chart (deployer image pulled from your private registry)
2. The deployer Job registers the cluster with the OneLens API
3. `install.sh` detects the private registry, pulls the `onelens-agent` chart from your registry via OCI
4. All component images (agent, Prometheus, OpenCost, KSM, etc.) are pulled from your private registry
5. The `onelensupdater` CronJob is created for automated health checks and upgrades
6. Cluster status is updated to `CONNECTED`

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

## Upgrading to a New Version

### Step 1: Mirror the new version (once, on your internet-connected machine)

```bash
bash airgapped_migrate_images.sh \
  --version <new-version> \
  --registry <your-registry-url>
```

### Step 2: Clusters upgrade automatically

The `onelensupdater` CronJob on each cluster checks your private registry every 5 minutes. When it detects a higher chart version than what's currently deployed, it upgrades automatically.

**You control the timing** — clusters only upgrade after you mirror the new version. No coordination with OneLens needed.

### Manual upgrade (optional)

To upgrade the deployer chart itself on a specific cluster:

```bash
helm upgrade onelensdeployer \
  oci://<your-registry>/charts/onelensdeployer \
  -n onelens-agent --reuse-values
```

---

## Troubleshooting

### Image pull errors

```
ErrImagePull or ImagePullBackOff
```

**Cause:** Cluster nodes can't pull from your private registry.

**Fix:**
1. Verify the image exists: `aws ecr describe-images --repository-name <repo> --region <region>`
2. Check node IAM role has ECR read permissions (see Prerequisites)
3. If using imagePullSecrets, verify the secret exists: `kubectl get secret <secret-name> -n onelens-agent`
4. Check the image tag matches the deployed version: `kubectl describe pod <pod-name> -n onelens-agent | grep Image`

### Images reset to public registries after patching

```
ErrImagePull for quay.io/... or public.ecr.aws/...
```

**Cause:** A patching run did not preserve the private registry overrides.

**Fix:**
1. Check current image sources: `helm get values onelens-agent -n onelens-agent -o json | jq`
2. Re-run the migration and upgrade: `bash airgapped_migrate_images.sh --version <version> --registry <url>`

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

---

## Container Images Reference

The following images are mirrored by `airgapped_migrate_images.sh`. The list is fetched dynamically per version — you don't need to track it manually.

| Image | Source Registry | Purpose |
|-------|----------------|---------|
| `onelens-agent` | `public.ecr.aws` | OneLens data collection agent |
| `onelens-deployer` | `public.ecr.aws` | Deployer and updater CronJob |
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
- `helm get values onelens-agent -n onelens-agent`
