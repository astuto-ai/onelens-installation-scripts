# OneLens Agent Installation Guide (IBS Version)

This guide will help you install OneLens Agent on your Kubernetes cluster using images from your own AWS ECR (Elastic Container Registry). This is useful when your cluster cannot access public container registries due to security policies.

## What Does This Do?

OneLens Agent is a monitoring and cost analysis tool for Kubernetes clusters. This installation process:
1. Copies all required container images to your private AWS ECR
2. Checks if your cluster can access those images
3. Installs OneLens Agent using your private images

---

## Before You Start

### Required Tools

Make sure these tools are installed on your computer:

- **AWS CLI** - To interact with AWS services
  - Check: `aws --version`
  - Install: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html

- **Docker** - To handle container images
  - Check: `docker --version`
  - Install: https://docs.docker.com/get-docker/

- **kubectl** - To interact with Kubernetes
  - Check: `kubectl version --client`
  - Install: https://kubernetes.io/docs/tasks/tools/

- **Helm** - To install applications on Kubernetes
  - Check: `helm version`
  - Install: https://helm.sh/docs/intro/install/

- **jq** - To process JSON data
  - Check: `jq --version`
  - Install: `brew install jq` (Mac) or `apt install jq` (Linux)

### AWS Requirements

You need:
- An AWS account with access to create ECR repositories
- AWS CLI configured with credentials (`aws configure`)
- Permissions to create and push to ECR repositories

### Kubernetes Requirements

You need:
- Access to a Kubernetes cluster
- kubectl configured to connect to your cluster
- Cluster admin permissions to install applications

### Firewall Requirments

Whitelist the following domains so that agent can post K8s cluster utilization data to OneLens servers:
- `*.onelens.cloud`

---

## Installation Steps

### Step 1: Get the Installation Scripts

Clone this specific branch to your computer:

```bash
git clone -b release/ibs-v1.7.0 https://github.com/astuto-ai/onelens-installation-scripts.git
cd onelens-installation-scripts
```

---

### Step 2: Migrate Images to Your ECR

This step copies all required container images from public registries to your private AWS ECR.

**Run the script:**
```bash
bash ibs_migrate_image.sh
```

**You will be asked for:**

1. **AWS Account ID** - The script will detect this automatically. Just press Enter to use it, or type a different one.
   - Example: `123456789012`

2. **AWS Region** - Where your ECR repositories should be created
   - Example: `us-east-1` or `ap-southeast-1`

**What it does:**
- Creates ECR repositories in your AWS account (if they don't exist)
- Pulls these images from public registries:
  - `onelens-agent:v1.0.0`
  - `prometheus:v3.1.0`
  - `kubecost-cost-model:prod-1.108.0`
  - `prometheus-config-reloader:v0.79.2`
  - `kube-state-metrics:v2.14.0`
  - `pushgateway:v1.11.0`
- Pushes all images to your private ECR

**Time:** This takes 5-15 minutes depending on your internet speed.

**Success looks like:**
```
✅ Successfully pushed multi-arch image: 123456789012.dkr.ecr.us-east-1.amazonaws.com/onelens-agent:v1.0.0
✅ Successfully pushed multi-arch image: 123456789012.dkr.ecr.us-east-1.amazonaws.com/prometheus:v3.1.0
...
🎉 All available images have been processed.
```

---

### Step 3: Deploy OneLens Agent

This is the final step that installs OneLens Agent on your cluster.

**Run the script:**
```bash
bash ibs_deployment.sh
```

**You will be asked for:**

1. **Registry URL** 
   - Default: `609916866699.dkr.ecr.ap-southeast-1.amazonaws.com`
   - Press `n` and enter your own: `{YOUR_ACCOUNT_ID}.dkr.ecr.{YOUR_REGION}.amazonaws.com`
   - Example: `123456789012.dkr.ecr.us-east-1.amazonaws.com`

2. **AWS Region** - Will be auto-detected from registry URL
   - Press Enter to keep it, or type a new region

3. **AWS Account ID** - Will be auto-detected from registry URL
   - Press Enter to keep it, or type a new account ID

4. **Registration Token** 
   - Default is provided: `c8573285-7f68-4b44-8a6f-68cb1f95ccbc`
   - Press Enter to use default, or get a new token from your OneLens account

5. **Cluster Name** - A friendly name for your cluster
   - Example: `production-eks-cluster`

6. **Release Version** 
   - Default: `1.7.0`
   - Press Enter to use default, or type a specific version

7. **Image Pull Secret** 
   - Default: `regcred` (same as Step 3)
   - Press Enter to use default

8. **Tolerations and Node Selectors** (Optional)
   - Press Enter to skip these advanced options
   - Only fill these if you know your cluster requires them

**What it does:**
- Registers your cluster with OneLens cloud API
- Analyzes your cluster size and sets appropriate resource limits
- Downloads configuration files
- Installs OneLens Agent using Helm
- Installs Prometheus for metrics collection
- Installs OpenCost for cost analysis
- Waits for all components to start successfully
- Updates OneLens API that installation is complete

**Time:** This takes 3-5 minutes.

**Success looks like:**
```
✅ Registration successful.
✅ Authenticated as: arn:aws:iam::123456789012:user/your-user
[INFO] Installing OneLens Agent using Helm...
[INFO] Waiting for OneLens pods to become ready...
[INFO] Installation complete!
[INFO] To verify deployment: kubectl get pods -n onelens-agent
```

---

## Verify Installation

After all steps complete, check that everything is running:

```bash
kubectl get pods -n onelens-agent
```

You should see pods like:
- `prometheus-server-xxxxx` - Running
- `prometheus-opencost-exporter-xxxxx` - Running
- `prometheus-kube-state-metrics-xxxxx` - Running
- `prometheus-pushgateway-xxxxx` - Running

All pods should show status: **Running** or **Completed**

---

## Common Issues

### "Failed to log in to Amazon ECR"
- Run `aws configure` to set up your AWS credentials
- Check your AWS IAM user has ECR permissions

### "kubectl not found"
- Install kubectl following the official guide
- Make sure it's in your system PATH

### "Failed to pull image"
- Verify Step 2 completed successfully
- Check the image exists in your ECR: Go to AWS Console → ECR → Repositories
- Verify Step 3 passed

### "Pods are not ready"
- Wait a few more minutes (first-time pulls can be slow)
- Check pod logs: `kubectl logs -n onelens-agent POD_NAME`
- Check events: `kubectl get events -n onelens-agent`

### "API registration failed"
- Check your internet connection
- Verify the registration token is correct
- Check if `api-in.onelens.cloud` is accessible from your machine

---

## Need Help?

- Check pod status: `kubectl get pods -n onelens-agent`
- View pod logs: `kubectl logs -n onelens-agent POD_NAME`
- View events: `kubectl get events -n onelens-agent --sort-by='.lastTimestamp'`
- Contact OneLens support with the above information

---

## What Gets Installed?

The following components are installed in the `onelens-agent` namespace:

- **OneLens Agent** - Main agent that collects and sends data to OneLens cloud
- **Prometheus** - Time-series database for metrics
- **OpenCost (Kubecost)** - Cost calculation engine
- **Kube-State-Metrics** - Kubernetes object state metrics
- **Pushgateway** - Accepts metrics from batch jobs

All images are pulled from your private ECR, not from public registries.

---

## Cleanup (Optional)

To remove OneLens Agent from your cluster:

```bash
helm uninstall onelens-agent -n onelens-agent
kubectl delete namespace onelens-agent
```

To remove images from ECR:
- Go to AWS Console → ECR → Repositories
- Delete the repositories created during installation
