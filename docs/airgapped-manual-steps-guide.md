# OneLens Air-Gapped Deployment — Proxy / Manual Steps Guide

This guide is for environments where internet access from the bastion server is routed through an HTTP proxy. Once the proxy is configured correctly, the standard automated scripts from the [Air-Gapped Deployment Guide](./airgapped-deployment-guide.md) should work as-is. Manual fallback steps are provided at the end in case the scripts still fail.

---

## Proxy Configuration

### Shell Environment (curl, aws, helm, kubectl)

Export these variables at the start of your session. All CLI tools (`curl`, `aws`, `helm`, `kubectl`, `jq`) will automatically route through the proxy.

```bash
export HTTP_PROXY="http://<proxy-host>:<proxy-port>"
export HTTPS_PROXY="https://<proxy-host>:<proxy-port>"
export NO_PROXY="localhost,127.0.0.1,169.254.169.254"
```

> **Note:** If your proxy does not support HTTPS on its listening port (common with many corporate proxies), use `http://` for both:
> ```bash
> export HTTPS_PROXY="http://<proxy-host>:<proxy-port>"
> ```

**`NO_PROXY` — adjust based on your network setup:**

The `NO_PROXY` variable tells tools which destinations should bypass the proxy and connect directly. Start with these baseline entries:

| Entry | Why it's needed |
|-------|----------------|
| `localhost` | Prevents local connections from being sent to the proxy |
| `127.0.0.1` | Same as above (numeric form — some tools only check one) |
| `169.254.169.254` | AWS EC2 Instance Metadata Service (IMDS). The `aws` CLI calls this to fetch IAM credentials from the instance. Only reachable directly from within the EC2 instance, never through a proxy |

Then add entries depending on what your bastion can reach **directly** (without the proxy):

| If your bastion can directly reach... | Add to `NO_PROXY` | Why |
|---|---|---|
| AWS APIs (bastion is an EC2 instance in the VPC) | `.amazonaws.com` | AWS CLI and Docker ECR calls go direct via VPC networking |

> **Key point:** Only add an entry to `NO_PROXY` if the bastion has a **direct network path** to that destination. If your bastion can **only** reach AWS and your ECR through the proxy, do **not** add `.amazonaws.com` to `NO_PROXY` — let those calls go through the proxy.

> **Tip:** Add the exports to your `~/.bashrc` or `~/.bash_profile` to persist across sessions.

Verify the proxy is working:

```bash
curl -sL --max-time 10 https://astuto-ai.github.io/onelens-installation-scripts/ -o /dev/null -w "HTTP %{http_code}\n"
```

### Docker Daemon

Docker runs as a separate daemon and does **not** inherit shell environment variables. You must configure the proxy separately for Docker.

**On Linux with systemd (most EC2 instances — Amazon Linux 2, Ubuntu, RHEL, etc.):**

```bash
sudo mkdir -p /etc/systemd/system/docker.service.d

sudo tee /etc/systemd/system/docker.service.d/http-proxy.conf > /dev/null <<EOF
[Service]
Environment="HTTP_PROXY=http://<proxy-host>:<proxy-port>"
Environment="HTTPS_PROXY=https://<proxy-host>:<proxy-port>"
Environment="NO_PROXY=localhost,127.0.0.1,169.254.169.254"
EOF

sudo systemctl daemon-reload
sudo systemctl restart docker
```

> Use the same protocol (`http://` or `https://`) and `NO_PROXY` entries as the shell exports above.

**If `systemctl` is not available**, configure via `/etc/docker/daemon.json` instead:

```bash
sudo mkdir -p /etc/docker

sudo tee /etc/docker/daemon.json > /dev/null <<EOF
{
  "proxies": {
    "http-proxy": "http://<proxy-host>:<proxy-port>",
    "https-proxy": "https://<proxy-host>:<proxy-port>",
    "no-proxy": "localhost,127.0.0.1,169.254.169.254"
  }
}
EOF

sudo service docker restart
```

**Verify Docker is using the proxy:**

```bash
docker info | grep -i proxy
```

Expected output should show your proxy host and port. Then test a pull:

```bash
docker pull hello-world
```

**If the pull fails with a TLS/certificate error** like `x509: certificate signed by unknown authority`, your proxy is performing SSL/TLS inspection. In that case, the proxy's CA certificate must be added to Docker's trusted certificates:

```bash
# Get the CA certificate from your network/security team, then:
sudo mkdir -p /etc/docker/certs.d/<registry-domain>
sudo cp <proxy-ca-cert.crt> /etc/docker/certs.d/<registry-domain>/ca.crt
sudo systemctl restart docker
```

Contact your network/security team to obtain the proxy's CA certificate.

---

## Run the Standard Steps (With Proxy Configured)

Once the proxy is set up for both the shell session and Docker daemon, the automated scripts should work normally. Run them as documented in the [Air-Gapped Deployment Guide](./airgapped-deployment-guide.md):

### Step 1: Verify Bastion Prerequisites

```bash
curl -fsSL https://astuto-ai.github.io/onelens-installation-scripts/scripts/airgapped/airgapped_bastion_precheck.sh | bash
```

### Step 2: Mirror Images and Set Up Cluster Resources

```bash
curl -fsSL https://astuto-ai.github.io/onelens-installation-scripts/scripts/airgapped/airgapped_migrate_images.sh -o airgapped_migrate_images.sh
bash airgapped_migrate_images.sh --registry <your-registry-url>/<prefix>
```

### Step 3: Verify Cluster-to-API Connectivity

```bash
curl -fsSL https://astuto-ai.github.io/onelens-installation-scripts/scripts/airgapped/airgapped_accessibility_check.sh | bash
```

If all three steps pass, proceed to [Step 4: Deploy OneLens](./airgapped-deployment-guide.md#step-4-deploy-onelens-on-each-cluster).

---

## Manual Fallback Steps

If the automated scripts still fail after proxy configuration (e.g., the proxy blocks piped execution, script download fails, or specific commands need adjustments), use the manual steps below.

---

### Step 1: Verify Bastion Prerequisites (Manual)

#### 1.1 Check Required Tools

```bash
# curl
curl --version

# AWS CLI (must be v2+)
aws --version
# Expected: aws-cli/2.x.x ...

# Docker + Buildx
docker --version
docker buildx version

# Helm (must be v3+)
helm version --short
# Expected: v3.x.x

# jq
jq --version

# kubectl
kubectl version --client
```

If any tool is missing, install it before proceeding.

#### 1.2 Check Network Access to Container Registries

```bash
curl -sL --max-time 10 https://public.ecr.aws/ -o /dev/null -w "public.ecr.aws: HTTP %{http_code}\n"
curl -sL --max-time 10 https://quay.io/ -o /dev/null -w "quay.io: HTTP %{http_code}\n"
curl -sL --max-time 10 https://ghcr.io/ -o /dev/null -w "ghcr.io: HTTP %{http_code}\n"
curl -sL --max-time 10 https://registry.k8s.io/ -o /dev/null -w "registry.k8s.io: HTTP %{http_code}\n"
curl -sL --max-time 10 https://nvcr.io/ -o /dev/null -w "nvcr.io: HTTP %{http_code}\n"
```

All should return an HTTP status (200, 301, 302, etc.) — not a connection error.

#### 1.3 Check GitHub Pages Access

```bash
curl -sL --max-time 10 https://astuto-ai.github.io/onelens-installation-scripts/ -o /dev/null -w "astuto-ai.github.io: HTTP %{http_code}\n"
```

#### 1.4 Check Docker Daemon

```bash
docker info > /dev/null 2>&1 && echo "PASS: Docker daemon running" || echo "FAIL: Docker daemon not running"
```

If Docker is not running:

```bash
sudo systemctl start docker
```

#### 1.5 Check AWS Credentials

```bash
aws sts get-caller-identity
```

Expected output: JSON with `Account`, `Arn`, and `UserId`. If this fails:

```bash
aws configure
# OR for SSO:
aws sso login
```

#### 1.6 Check Kubectl Cluster Access

```bash
kubectl cluster-info
kubectl config current-context
```

If kubeconfig is not pointing to the target cluster:

```bash
aws eks update-kubeconfig --name <cluster-name> --region <region>
```

---

### Step 2: Mirror Images and Set Up Cluster Resources (Manual)

The goal of this step is to copy all OneLens container images from public registries into your private ECR, push the deployer Helm chart to your ECR, and create a ConfigMap in the target cluster containing the agent chart. Here's how to do it manually.

#### A. Prepare your environment

1. Decide your private registry URL with a path prefix to namespace OneLens repos, e.g. `123456789.dkr.ecr.ap-south-1.amazonaws.com/onelensk8sagent`. You can choose any prefix — `onelensk8sagent` is recommended.

2. Authenticate Docker to your ECR:
   ```bash
   aws ecr get-login-password --region <your-region> | docker login --username AWS --password-stdin <your-ecr-domain>
   ```

3. Add the OneLens Helm repository:
   ```bash
   helm repo add onelens https://astuto-ai.github.io/onelens-installation-scripts/
   helm repo update
   ```

#### B. Find the image tags for your version

1. Identify the version you want to deploy. To find the latest:
   ```bash
   helm search repo onelens/onelens-agent -o json | jq -r '.[0].version'
   ```

2. Download the global values file for that version — this contains all the image repositories and tags:
   ```bash
   curl -fsSL "https://astuto-ai.github.io/onelens-installation-scripts/globalvalues-v<VERSION>.yaml" -o globalvalues.yaml
   ```

3. Also pull and extract the agent chart — two sub-charts (kube-state-metrics, pushgateway) have empty tags in globalvalues; their actual tags are in the sub-chart's `Chart.yaml` under `appVersion`:
   ```bash
   helm pull onelens/onelens-agent --version <VERSION> --untar
   ```

4. Open `globalvalues.yaml` and note down the image repository and tag for each component. The table below shows where to find each one:

   | Component | Where to find the tag |
   |---|---|
   | onelens-agent | `globalvalues.yaml` — look for `repository: public.ecr.aws/w7k6q5m9/onelens-agent`, tag is on the next line |
   | onelens-deployer | Always `v<VERSION>` (e.g. `v2.1.81`) |
   | prometheus | `globalvalues.yaml` — `repository: quay.io/prometheus/prometheus` |
   | prometheus-config-reloader | `globalvalues.yaml` — `repository: quay.io/prometheus-operator/prometheus-config-reloader` |
   | opencost | `globalvalues.yaml` — `repository: opencost/opencost` (source registry is `ghcr.io`) |
   | kube-state-metrics | Tag is empty in globalvalues. Use `appVersion` from `onelens-agent/charts/prometheus/charts/kube-state-metrics/Chart.yaml`, prefixed with `v` |
   | kube-rbac-proxy | `globalvalues.yaml` — `repository: brancz/kube-rbac-proxy` (source registry is `quay.io`) |
   | pushgateway | Tag is empty in globalvalues. Use `appVersion` from `onelens-agent/charts/prometheus/charts/prometheus-pushgateway/Chart.yaml` |
   | dcgm-exporter | `globalvalues.yaml` — under `gpu.dcgmExporter.image`. Only needed for GPU clusters |
   | onelens-network-costs | `globalvalues.yaml` — under `networkCosts.image`. Only needed if network costs is enabled |

#### C. Create ECR repositories and mirror the images

For each image in the table below, create an ECR repository under your prefix (if it doesn't exist) and mirror the image using `docker buildx imagetools create` for multi-arch support. If `buildx` fails, fall back to `docker pull` / `docker tag` / `docker push`.

| # | Source (pull from) | ECR repo name to create under your prefix |
|---|---|---|
| 1 | `public.ecr.aws/w7k6q5m9/onelens-agent:<tag>` | `onelens-agent` |
| 2 | `public.ecr.aws/w7k6q5m9/onelens-deployer:v<VERSION>` | `onelens-deployer` |
| 3 | `quay.io/prometheus/prometheus:<tag>` | `prometheus` |
| 4 | `quay.io/prometheus-operator/prometheus-config-reloader:<tag>` | `prometheus-config-reloader` |
| 5 | `ghcr.io/opencost/opencost:<tag>` | `opencost` |
| 6 | `registry.k8s.io/kube-state-metrics/kube-state-metrics:<tag>` | `kube-state-metrics` |
| 7 | `quay.io/brancz/kube-rbac-proxy:<tag>` | `kube-rbac-proxy` |
| 8 | `quay.io/prometheus/pushgateway:<tag>` | `pushgateway` |
| 9 | `nvcr.io/nvidia/k8s/dcgm-exporter:<tag>` | `dcgm-exporter` (GPU only) |
| 10 | `public.ecr.aws/w7k6q5m9/onelens-network-costs:<tag>` | `onelens-network-costs` (network costs only) |

For example, to mirror the onelens-agent image:

```bash
# Create the ECR repo (skip if it already exists)
aws ecr create-repository --repository-name <prefix>/onelens-agent --region <region>

# Mirror multi-arch
docker buildx imagetools create \
  --tag <your-registry>/<prefix>/onelens-agent:<tag> \
  public.ecr.aws/w7k6q5m9/onelens-agent:<tag>

# If buildx fails, use the single-arch fallback:
docker pull public.ecr.aws/w7k6q5m9/onelens-agent:<tag>
docker tag public.ecr.aws/w7k6q5m9/onelens-agent:<tag> <your-registry>/<prefix>/onelens-agent:<tag>
docker push <your-registry>/<prefix>/onelens-agent:<tag>
```

Repeat for all images in the table.

#### D. Mirror the deployer Helm chart

1. Pull and extract the `onelensdeployer` chart:
   ```bash
   helm pull onelens/onelensdeployer --version <VERSION> --untar
   ```

2. Open `onelensdeployer/values.yaml` and replace the deployer image reference `public.ecr.aws/w7k6q5m9/onelens-deployer` with your private registry path (e.g. `123456789.dkr.ecr.ap-south-1.amazonaws.com/onelensk8sagent/onelens-deployer`).

3. Create an ECR repository for the chart:
   ```bash
   aws ecr create-repository --repository-name <prefix>/charts/onelensdeployer --region <region>
   ```

4. Package and push the chart:
   ```bash
   helm package onelensdeployer/
   helm push onelensdeployer-<VERSION>.tgz oci://<your-registry>/<prefix>/charts/
   ```

#### E. Create Kubernetes resources in the target cluster

The deployer pod needs the agent chart available as a ConfigMap (so it can install without needing registry access from inside the pod).

1. Pull the agent chart tarball (if you haven't already):
   ```bash
   helm pull onelens/onelens-agent --version <VERSION>
   ```

2. Create the namespace and ConfigMap:
   ```bash
   kubectl create namespace onelens-agent --dry-run=client -o yaml | kubectl apply -f -

   kubectl create configmap onelens-agent-chart -n onelens-agent \
     --from-file=chart.tgz=onelens-agent-<VERSION>.tgz \
     --dry-run=client -o yaml | kubectl apply -f -
   ```

#### F. Verify

- Check that all ECR repositories were created:
  ```bash
  aws ecr describe-repositories --region <region> --query 'repositories[].repositoryName' --output table
  ```

- Check that the ConfigMap exists in the cluster:
  ```bash
  kubectl get configmap onelens-agent-chart -n onelens-agent
  ```

---

### Step 3: Verify Cluster-to-API Connectivity (Manual)

#### 3.1 Test from Bastion

```bash
curl -sL --max-time 10 https://api-in.onelens.cloud/v1/kubernetes/cluster-version -o /dev/null -w "api-in.onelens.cloud: HTTP %{http_code}\n"
curl -sL --max-time 10 https://api-in-fileupload.onelens.cloud -o /dev/null -w "api-in-fileupload.onelens.cloud: HTTP %{http_code}\n"
nslookup api-in.onelens.cloud
nslookup api-in-fileupload.onelens.cloud
```

#### 3.2 Test from Within the Cluster (Recommended)

The bastion may have different network routes than the cluster nodes. Run a temporary pod to verify:

```bash
kubectl run connectivity-test --rm -it --restart=Never \
    --image=curlimages/curl:latest \
    -n onelens-agent \
    -- sh -c '
echo "Testing API...";
curl -sL --max-time 10 https://api-in.onelens.cloud/v1/kubernetes/cluster-version -o /dev/null -w "api-in.onelens.cloud: HTTP %{http_code}\n";
echo "Testing Upload Gateway...";
curl -sL --max-time 10 https://api-in-fileupload.onelens.cloud -o /dev/null -w "api-in-fileupload.onelens.cloud: HTTP %{http_code}\n";
echo "Done."
'
```

> If the cluster cannot pull `curlimages/curl` from Docker Hub, mirror it to your private ECR first, or use any image already available in your cluster that has `curl`.

---

## Next Step: Deploy OneLens

After all three steps pass, proceed to [Step 4: Deploy OneLens](./airgapped-deployment-guide.md#step-4-deploy-onelens-on-each-cluster):

```bash
helm upgrade --install onelensdeployer \
  oci://<your-registry>/<prefix>/charts/onelensdeployer \
  -n onelens-agent --create-namespace \
  --set job.env.CLUSTER_NAME=<cluster-name> \
  --set job.env.REGION=<region> \
  --set-string job.env.ACCOUNT=<account-id> \
  --set job.env.REGISTRATION_TOKEN=<token>
```

---

## Cleanup

After a successful migration, remove the downloaded files (`globalvalues.yaml`, `onelens-agent/`, `onelens-agent-*.tgz`, `onelensdeployer/`, `onelensdeployer-*.tgz`).

---

## Troubleshooting

### Proxy issues with Docker pull/push

Docker daemon doesn't inherit shell env vars. Verify its proxy config:

```bash
docker info | grep -i proxy
```

If empty, configure the systemd override as described in [Proxy Configuration](#proxy-configuration).

### ECR authentication expires

ECR tokens are valid for 12 hours. Re-authenticate if you get `unauthorized` errors:

```bash
aws ecr get-login-password --region "$ECR_REGION" | docker login --username AWS --password-stdin "$ECR_DOMAIN"
```

### `docker buildx imagetools create` fails

Initialize a builder if Buildx isn't set up:

```bash
docker buildx create --use --name onelens-builder
docker buildx inspect --bootstrap
```

If it still fails, the fallback (`docker pull` + `docker tag` + `docker push`) mirrors single-arch images, which works for most deployments.

