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
│  │   --registry <url>           │    │ Your private registry  │  │
│  │   (auto-detects version)     │    │ (images + charts)      │  │
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
                │   │ Healthchecks + auto-remediation          │   │
                │   │ Upgrades when new chart is in ConfigMap  │   │
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
| kubectl | Access to the target Kubernetes cluster (for chart setup) |

> **Note:** This guide assumes AWS ECR as the private registry. If you use a different registry (Harbor, Artifactory, GCR, etc.), adapt the registry authentication and image push commands accordingly — the Helm install command remains the same.
>
> **Note:** The migration script requires `kubectl` access to the target cluster to create a ConfigMap containing the agent chart. Ensure your kubeconfig is configured for the target cluster before running.

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

Your EKS **node IAM role** needs read access to the private ECR repositories. This is required because all OneLens pod images (agent, Prometheus, OpenCost, kube-state-metrics, pushgateway, etc.) are pulled from your private registry. Without this, pods will fail with `ImagePullBackOff`:

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
>
> **EKS managed node groups** include the `AmazonEC2ContainerRegistryReadOnly` policy by default, which covers same-account ECR. For **cross-account ECR**, add a repository policy on each ECR repository granting pull access to the node role in the other account. For **Azure AKS**, use `az aks update --attach-acr`. For **GCP GKE**, grant `roles/artifactregistry.reader` to the node service account.

---

## Step 1: Validate Connectivity (Optional)

Run the accessibility check to verify your environment can reach the required services. No parameters needed.

```bash
curl -fsSL https://astuto-ai.github.io/onelens-installation-scripts/scripts/airgapped/airgapped_accessibility_check.sh | bash
```

The script tests:
- **OneLens API** — reachability (`api-in.onelens.cloud`)
- **Upload gateway** — data upload endpoint reachability (`api-in-fileupload.onelens.cloud`)
- **DNS resolution** — that cluster nodes can resolve the required domains

---

## Step 2: Mirror Images and Set Up Cluster Resources

This step runs **once per OneLens version** on a machine with internet access AND `kubectl` access to the target cluster.

```bash
bash airgapped_migrate_images.sh --registry <your-registry-url>/<prefix>
```

> **Version:** The script auto-detects the latest released version. To pin a specific version, add `--version <version>`.

> **Registry format:** Use a path prefix to namespace OneLens repos under your registry (e.g. `123456789.dkr.ecr.ap-south-1.amazonaws.com/onelensk8sagent`). All image and chart repos will be created under the prefix (e.g. `onelensk8sagent/prometheus`, `onelensk8sagent/opencost`). You can choose any prefix name — `onelensk8sagent` is recommended. A bare domain without a prefix also works but may conflict with existing repos.

The script will:
1. Authenticate to your ECR (auto-detects account/region from the registry URL)
2. Fetch the image list for the specified version from `globalvalues.yaml`
3. Create ECR repositories if they don't exist (under your prefix if specified)
4. Pull each image from its public registry and push to your ECR (multi-arch: amd64 + arm64)
5. Pull the `onelensdeployer` Helm chart, rewrite its image reference, and push to your registry
6. Create a ConfigMap in the target cluster containing the `onelens-agent` chart (used by the deployer pod to install without needing registry access)

### Verify

```bash
aws ecr describe-repositories --region <region> --query 'repositories[].repositoryName' --output table
```

You should see repositories for: `<prefix>/onelens-agent`, `<prefix>/onelens-deployer`, `<prefix>/prometheus`, `<prefix>/opencost`, `<prefix>/prometheus-config-reloader`, `<prefix>/kube-state-metrics`, `<prefix>/pushgateway`, `<prefix>/kube-rbac-proxy`, and `<prefix>/charts/onelensdeployer`.

Also verify the chart ConfigMap was created:

```bash
kubectl get configmap onelens-agent-chart -n onelens-agent
```

---

## Step 3: Deploy OneLens on Each Cluster

Run the standard OneLens install command, pointing to your private registry instead of the public one.

**Standard install (for reference):**

```bash
helm repo add onelens https://astuto-ai.github.io/onelens-installation-scripts/ && helm repo update onelens
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

1. Helm deploys the `onelensdeployer` chart (deployer image pulled from your private registry by the node IAM role)
2. The deployer Job registers the cluster with the OneLens API
3. `install.sh` detects the private registry, reads the `onelens-agent` chart from the ConfigMap (created by the migration script)
4. All component images (agent, Prometheus, OpenCost, KSM, etc.) are pulled from your private registry by the node IAM role
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

### Step 1: Re-run the migration script (once per version, on your setup machine)

```bash
bash airgapped_migrate_images.sh --registry <your-registry-url>
```

This mirrors the new version's images, updates the deployer chart in your registry, and updates the ConfigMap in the cluster with the new agent chart.

### Step 2: Clusters upgrade automatically

The `onelensupdater` CronJob runs every 5 minutes. When it detects a version mismatch, it reads the chart from the ConfigMap (updated in Step 1) and runs a helm upgrade with the new version.

**You control the timing** — clusters only upgrade after you re-run the migration script. No coordination with OneLens needed.

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
2. Check node IAM role has ECR read permissions (see [Prerequisites](#aws-permissions))
3. Check the image tag matches the deployed version: `kubectl describe pod <pod-name> -n onelens-agent | grep Image`

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
