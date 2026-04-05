# OneLens Installation Scripts — Complete Architecture

## What is this project?

OneLens is a product that helps companies understand how much money they're spending on their Kubernetes clusters. Think of it like a electricity meter for your cloud infrastructure — it watches what's running, measures resource usage, and calculates costs.

This repository is **not the OneLens product itself**. This repository is the **installer**. Its job is to set up monitoring tools inside a customer's Kubernetes cluster so that data can be collected and sent back to OneLens's cloud servers for analysis.

When a customer signs up for OneLens, they get a registration token. They use that token to run this installer, which sets up everything automatically inside their cluster.

---

## What gets deployed to the customer's cluster?

After installation is complete, these are the actual pods running inside the customer's cluster in a namespace called `onelens-agent`. They come from **two separate Helm releases** (explained in detail later):

### From Helm Release #1: `onelensdeployer` (the installer/updater)

| Pod | What it is in plain English | Lifecycle |
|---|---|---|
| **onelensdeployerjob** | A one-time Job that runs `install.sh` — it registers with OneLens API, detects the cloud provider, calculates resource sizes, and runs `helm install` to set up the monitoring stack. | Runs once, then **deletes itself** after install completes. You won't see this pod in steady state. |
| **onelensupdater** | A CronJob that runs once a day at 2 AM UTC — it fetches the latest patching script from the OneLens API and runs `helm upgrade` to keep the monitoring stack updated. | Creates a fresh pod every day at 2 AM. Pod completes and is cleaned up. |

Each of these pods runs as a different **ServiceAccount** (Kubernetes identity) with different permissions. The Job gets temporary "bootstrap" permissions to create things from scratch; the CronJob only gets ongoing permissions to manage existing resources. Full RBAC details in the "RBAC Architecture" section below.

### From Helm Release #2: `onelens-agent` (the monitoring stack, installed by the Job above)

| Pod | What it is in plain English | Lifecycle |
|---|---|---|
| **prometheus-server** | A database that collects and stores metrics (numbers like CPU usage, memory usage, pod counts) by pulling them from various sources at a regular interval (configured as 30s or 1m — see `oom-issues.md` Issue #6 for details on this ambiguity) | Always running (Deployment) |
| **kube-state-metrics (KSM)** | A small program that reads the Kubernetes API and converts the current state of all objects (pods, deployments, nodes, etc.) into numbers that Prometheus can store | Always running (Deployment) |
| **prometheus-pushgateway** | A temporary holding area where short-lived jobs can push their metrics before they die, so Prometheus can pick them up later | Always running (Deployment) |
| **prometheus-configmap-reload** | A tiny sidecar that runs alongside Prometheus and triggers a hot configuration reload (via `POST /-/reload`) when the Prometheus ConfigMap changes. Prometheus keeps running — it just re-reads its config without restarting. | Always running (sidecar in Prometheus pod) |
| **opencost** | A cost calculator. It reads metrics from Prometheus and uses pricing data to figure out how much each pod/namespace/workload costs in real dollars | Always running (Deployment) |
| **onelens-agent** | A CronJob that runs once every hour — it talks to Prometheus and OpenCost, gathers all the collected data, and sends it to the OneLens cloud backend via HTTPS | Creates a pod every hour, completes and exits |

Each monitoring pod also has its own ServiceAccount with specific read-only ClusterRole permissions (Prometheus needs to scrape, KSM needs to watch K8s objects, etc.). These are separate from the deployer's ServiceAccounts.

---

## How does everything get installed? (The full sequence)

### Step 1: Customer deploys the "deployer" chart

The customer (or their DevOps engineer) runs something like:

```bash
helm install onelensdeployer onelens/onelensdeployer \
  --set job.env.REGISTRATION_TOKEN="abc123" \
  --set job.env.CLUSTER_NAME="my-cluster" \
  --set job.env.ACCOUNT="123456" \
  --set job.env.REGION="us-east-1"
```

This installs the **first Helm chart** called `onelensdeployer`. This chart is small — it doesn't install the monitoring stack directly. Instead, it creates 9 Kubernetes resources. Here's each one and why it exists:

**Two workloads (the pods that actually run code):**

1. **Job: `onelensdeployerjob`** — Runs **once** right now. Kubernetes creates a pod from this Job, which executes `install.sh` to set up the entire monitoring stack. After it finishes, the pod auto-deletes after 300 seconds (`ttlSecondsAfterFinished: 300`). Think of it as a construction crew that builds the house and then leaves.

2. **CronJob: `onelensupdater`** — Runs **daily at 2 AM UTC** (`schedule: "0 2 * * *"`). Each day, Kubernetes creates a fresh pod from this CronJob. That pod fetches the latest patching script from the OneLens API and runs it to keep the monitoring stack updated. Think of it as a maintenance crew that visits every day.

Both use the exact same Docker image (`public.ecr.aws/w7k6q5m9/onelens-deployer`), but are configured with different `deployment_type` environment variables (`job` vs `cronjob`) so the entrypoint script knows which code path to run.

**Two ServiceAccounts (identities for the pods):**

3. **`onelensdeployerjob-sa`** — The identity used by the Job pod
4. **`onelensupdater-sa`** — The identity used by the CronJob pod

*Why two separate ServiceAccounts instead of one?* Because the Job needs extra "bootstrap" permissions (to create things that don't exist yet during first install), but the CronJob should never have those broad powers. By giving each workload its own identity, we can grant the bootstrap permissions **only** to the Job's identity. This is called the "principle of least privilege" — each identity gets the minimum permissions it needs, nothing more.

*What is a ServiceAccount?* When a pod talks to the Kubernetes API (e.g., to run `kubectl` or `helm` commands inside the pod), Kubernetes needs to know "who is this pod?" A ServiceAccount is that identity. Without it, the pod can't create, read, or modify anything in the cluster. The ServiceAccount by itself has zero permissions — it's just a name tag. Permissions are granted to it through Roles and Bindings (explained below).

**Namespace-scoped permissions (what the pods can do inside the `onelens-agent` namespace):**

5. **Role: `onelensdeployer-role`** — A list of permissions that apply **only within the `onelens-agent` namespace**. In this case: full control (`apiGroups=* resources=* verbs=*`) — meaning the pods can create, read, update, and delete any resource type, but only inside this one namespace. This is needed because `install.sh` and `patching.sh` run `helm install/upgrade` which creates pods, services, secrets, configmaps, etc. in the namespace.

   *What is a Role vs ClusterRole?* A **Role** is scoped to a single namespace — like a key to one room. A **ClusterRole** is cluster-wide — like a master key that works on all rooms plus the hallways (cluster-scoped resources like nodes and storageclasses).

6. **RoleBinding: `onelensdeployer-rolebinding`** — The glue that connects the Role to the ServiceAccounts. It says: "Both `onelensdeployerjob-sa` AND `onelensupdater-sa` get the permissions listed in `onelensdeployer-role`."

   *What is a RoleBinding?* A Role by itself is just a list of permissions sitting there — it doesn't do anything on its own. A RoleBinding connects it to one or more ServiceAccounts (or users). Think of it as: the Role is the permission slip, the ServiceAccount is the person, and the RoleBinding is the staple that attaches the slip to the person.

**Cluster-wide permanent permissions (what the pods can do across the entire cluster, forever):**

7. **ClusterRole: `onelensdeployer-clusterrole`** (the "ongoing" role) — Cluster-wide permissions that persist after installation. Has two types of rules:
   - **READ-ONLY** (`get`, `list`, `watch`) on pods, nodes, deployments, namespaces, services, etc. across all namespaces. Why? Because the monitoring stack installed later (Prometheus, kube-state-metrics) needs to read data from the entire cluster to collect metrics.
   - **WRITE access restricted to specific named resources** that OneLens owns — using `resourceNames` restrictions. For example, it can modify the StorageClass named `onelens-sc` but no other StorageClass. It can modify the Namespace named `onelens-agent` but no other namespace. It can modify specific ClusterRoles by exact name (`onelens-agent-prometheus-server`, `onelens-agent-kube-state-metrics`, etc.) but cannot touch any other ClusterRole.

8. **ClusterRoleBinding: `onelensdeployer-clusterrolebinding`** — Connects the ongoing ClusterRole to **both** ServiceAccounts. Both the Job and the CronJob get these permanent cluster-wide permissions.

**Cluster-wide temporary permissions (extra powers for first-time installation only):**

9. **ClusterRole: `onelensdeployer-bootstrap-clusterrole`** (the "bootstrap" role) — Temporary permissions needed only during the very first installation. It allows only one verb: `create`. It can create namespaces, storageclasses, clusterroles, and clusterrolebindings — but cannot read, update, or delete them.

   *Why is this needed?* Chicken-and-egg problem. The ongoing ClusterRole (#7 above) restricts writes by `resourceNames` — e.g., it can only modify the StorageClass named `onelens-sc`. But during the very first install, `onelens-sc` doesn't exist yet! You can't restrict to a name that hasn't been created. So the bootstrap role provides unrestricted `create` permission for these resource types. Once `install.sh` creates them, the ongoing role can manage them by name going forward.

   **ClusterRoleBinding: `onelensdeployer-bootstrap-clusterrolebinding`** — Connects the bootstrap ClusterRole to **only the Job ServiceAccount** (`onelensdeployerjob-sa`). The CronJob never gets bootstrap powers. This is deliberate — the CronJob runs daily and should never have broad creation permissions.

   These bootstrap resources are deleted at the end of `install.sh` (see Step 11 below) — the scaffolding is removed once the house is built.

**Source files for all of the above:**
- `charts/onelensdeployer/templates/job.yaml` — creates the Job, uses `serviceAccountName: onelensdeployerjob-sa`
- `charts/onelensdeployer/templates/cronjob.yaml` — creates the CronJob, uses `serviceAccountName: onelensupdater-sa`
- `charts/onelensdeployer/templates/sa.yaml` — creates both ServiceAccounts in one file
- `charts/onelensdeployer/templates/role.yaml` — creates the namespace-scoped Role
- `charts/onelensdeployer/templates/rolebinding.yaml` — binds Role to both SAs
- `charts/onelensdeployer/templates/clusterole.yaml` — creates the ongoing ClusterRole
- `charts/onelensdeployer/templates/clusterrolebinding.yaml` — binds ongoing ClusterRole to both SAs
- `charts/onelensdeployer/templates/bootstrap-clusterrole.yaml` — creates the bootstrap ClusterRole
- `charts/onelensdeployer/templates/bootstrap-clusterrolebinding.yaml` — binds bootstrap ClusterRole to Job SA only

The Job and CronJob both use the same Docker image: `public.ecr.aws/w7k6q5m9/onelens-deployer`. This image is built from the `Dockerfile` in this repo. It's based on Alpine Linux and has `curl`, `wget`, `jq`, `bash`, `git`, `python3`, and `aws-cli` pre-installed. It also has `install.sh`, `globalvalues.yaml`, and `entrypoint.sh` baked into it. Note: `helm` and `kubectl` are **not** in the image — they are downloaded at runtime by `install.sh` and `patching.sh` every time they run.

---

### Step 2: The installation Job starts running

Kubernetes sees the Job and creates a pod for it. The pod starts and runs `entrypoint.sh`.

`entrypoint.sh` is a simple router. It checks the environment variable `deployment_type`:
- If `deployment_type=job` → run `install.sh` (this is what happens now, during first install)
- If `deployment_type=cronjob` → fetch and run patching script from the API (this is what happens daily later)

Since this is the installation job, `deployment_type=job`, so it runs `install.sh`.

---

### Step 3: `install.sh` runs inside the Job pod

This is the main installation script. Here's what it does, phase by phase:

#### Phase 1 — Logging setup (`install.sh:8-34`)

It creates a log file and sets up a trap. If anything goes wrong (the script exits with a non-zero code), it automatically sends the full log to the OneLens API so the OneLens support team can debug what happened. This is important because the customer might not have easy access to pod logs.

#### Phase 2 — Environment variables (`install.sh:37-43`)

Sets defaults:
- `RELEASE_VERSION=2.0.1` (which version of the monitoring charts to install)
- `API_BASE_URL=https://api-in.onelens.cloud` (the OneLens backend)
- `PVC_ENABLED=true` (whether to use persistent storage for Prometheus)

#### Phase 3 — Register with OneLens API (`install.sh:52-71`)

The script calls `POST /v1/kubernetes/registration` with the customer's registration token, cluster name, account ID, and region. The API responds with two important values:
- `CLUSTER_TOKEN` — a secret token that identifies this specific cluster going forward
- `REGISTRATION_ID` — a unique ID for this installation

These are stored as Kubernetes Secrets later so the agent CronJob can use them.

#### Phase 4-6 — Install tools (`install.sh:75-115`)

The script installs `helm` (v3.13.2) and `kubectl` (v1.28.2) binaries inside the pod. Yes, it downloads and installs them every time the job runs. This is because the Docker image is kept lightweight — it doesn't bundle these tools at build time. It detects the CPU architecture (AMD64 or ARM64) and downloads the right binaries.

#### Phase 7 — Create namespace (`install.sh:118-123`)

Creates the `onelens-agent` namespace if it doesn't exist. All monitoring components will live here.

#### Phase 7.5 — Detect cloud provider (`install.sh:127-193`)

This is where the script figures out whether the customer is running on AWS EKS or Azure AKS. It does this by:

1. Running `kubectl cluster-info` and checking the URL:
   - If it contains `.eks.amazonaws.com` → AWS
   - If it contains `.azmk8s.io` → Azure
2. If that fails, it checks the first node's `providerID` field:
   - If it starts with `aws://` → AWS
   - If it starts with `azure://` → Azure
3. If that also fails, it checks for a manual override env var `CLOUD_PROVIDER_OVERRIDE`

Based on the cloud provider, it sets which storage driver to use:
- AWS: `ebs.csi.aws.com` with `gp3` volume type
- Azure: `disk.csi.azure.com` with `StandardSSD_LRS` SKU

#### Phase 8 — CSI driver check (`install.sh:196-256`)

For Prometheus to store its data persistently, the cluster needs a CSI (Container Storage Interface) driver. This is the software that creates and mounts disk volumes.

- On **AWS**: The script checks if the EBS CSI driver is installed by looking for pods with the label `app.kubernetes.io/name=aws-ebs-csi-driver` in `kube-system`. If not found, it installs it via Helm.
- On **Azure**: The Azure Disk CSI driver comes pre-installed on AKS clusters, so it just validates it exists.

#### Phase 9 — Calculate resource allocations (`install.sh:261-455`)

This is a critical step. The script counts the total number of running + pending pods in the cluster and uses that to decide how much CPU and memory each monitoring component should get.

The logic is a series of if/else thresholds:

| Cluster Size | Prometheus Memory | OpenCost Memory | OneLens Agent Memory | KSM Memory | Pushgateway Memory |
|---|---|---|---|---|---|
| <100 pods | 1188Mi | 200Mi | 400Mi | 100Mi | 100Mi |
| 100-499 pods | 1771Mi | 250Mi | 500Mi | 100Mi | 100Mi |
| 500-999 pods | 3533Mi | 360Mi | 500Mi | 100Mi | 100Mi |
| 1000-1499 pods | 5400Mi | 450Mi | 600Mi | 400Mi | 400Mi |
| 1500+ pods | 7066Mi | 600Mi | 700Mi | 400Mi | 400Mi |

It also sizes the Prometheus persistent volume and retention:

| Cluster Size | Volume Size | Retention Size |
|---|---|---|
| <100 pods | 10Gi | 6GB |
| 100-499 pods | 20Gi | 12GB |
| 500-999 pods | 30Gi | 20GB |
| 1000-1499 pods | 40Gi | 30GB |
| 1500+ pods | 50Gi | 35GB |

Retention is always 10 days.

#### Phase 10 — Install the monitoring stack (`install.sh:458-652`)

Now the script runs the big command. It does:

```bash
helm upgrade --install onelens-agent onelens/onelens-agent \
  --version 2.0.1 \
  -f globalvalues.yaml \
  --set <dozens of --set flags>
```

What happens here:

1. `helm upgrade --install` — install the chart if it doesn't exist, upgrade it if it does
2. `onelens-agent` — the name of the Helm release
3. `onelens/onelens-agent` — the chart to install, from the OneLens Helm repository (`https://astuto-ai.github.io/onelens-installation-scripts/`)
4. `--version 2.0.1` — the exact chart version to install
5. `-f globalvalues.yaml` — a values file baked into the Docker image that contains the base configuration
6. `--set ...` flags — these override specific values from `globalvalues.yaml` with the computed values (resource sizes, secrets, storage class settings, cloud-specific config)

The `-f globalvalues.yaml` file provides defaults for everything: Prometheus scrape configs, KSM collectors, OpenCost settings, image versions, etc. Then the `--set` flags override the things that vary per customer (secrets, resource sizes, cloud provider settings, tolerations, node selectors).

This single helm command creates **all the monitoring pods** (Prometheus, KSM, Pushgateway, OpenCost, OneLens Agent) as a single Helm release.

After the helm command succeeds, the script waits up to 800 seconds for the OpenCost pod to become ready:
```bash
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=prometheus-opencost-exporter ...
```

#### Phase 11 — Finalize (`install.sh:654-679`)

The script cleans up after itself. This is the "remove the scaffolding" step:

1. **Calls `PUT /v1/kubernetes/registration` with status `CONNECTED`** — tells the OneLens backend that installation succeeded. This updates the cluster status in the OneLens dashboard so the customer can see it's connected.

2. **Sleeps 60 seconds** — gives all newly created pods time to stabilize, pull images, pass health checks, etc.

3. **Deletes the bootstrap RBAC** — specifically, it deletes:
   - `onelensdeployer-bootstrap-clusterrole` — the ClusterRole that allowed creating namespaces, storageclasses, and clusterroles/bindings without name restrictions
   - `onelensdeployer-bootstrap-clusterrolebinding` — the binding that connected that ClusterRole to the Job's ServiceAccount

   These are no longer needed because all the resources they were needed to create (the `onelens-agent` namespace, the `onelens-sc` StorageClass, the monitoring stack's own ClusterRoles) now exist. The ongoing ClusterRole (`onelensdeployer-clusterrole`) can manage them going forward since it restricts writes to their specific names.

4. **Deletes the Job itself and its ServiceAccount** — the installer's work is done, so it removes:
   - The `onelensdeployerjob` Job resource
   - The `onelensdeployerjob-sa` ServiceAccount

   After this, only the CronJob (`onelensupdater`) and its ServiceAccount (`onelensupdater-sa`) remain from the deployer chart. The CronJob retains:
   - The namespace-scoped Role (full control within `onelens-agent` namespace) — needed for `helm upgrade`
   - The ongoing ClusterRole (read-only cluster access + named resource writes) — needed for managing monitoring stack ClusterRoles/Bindings
   - It does NOT have the bootstrap ClusterRole (deleted above) — the CronJob can never create new cluster-scoped resources

---

### Step 4: The monitoring stack is now running

After `install.sh` completes, here's what's happening continuously inside the cluster:

**At the configured scrape interval (30s or 1m — there's a config ambiguity, see `oom-issues.md` Issue #6):**
- Prometheus server wakes up and scrapes metrics from multiple sources:
  - **Kubernetes API server** (`/metrics` endpoint) — how busy the API server is
  - **Every node** (`/api/v1/nodes/<name>/proxy/metrics`) — node-level metrics
  - **Every node's cAdvisor** (`/api/v1/nodes/<name>/proxy/metrics/cadvisor`) — container-level CPU/memory/disk/network metrics
  - **kube-state-metrics** — all Kubernetes object state as metrics
  - **Pushgateway** — any pushed batch metrics
  - **Any pods/services with the annotation `custom.metrics/scrape: "true"`** — custom application metrics

**Every 1 minute:**
- Prometheus scrapes **OpenCost** (`/metrics` on port 9003) to collect cost metrics

**Continuously:**
- **kube-state-metrics** watches the Kubernetes API for changes to all 15 resource types (pods, deployments, nodes, etc.) and maintains an in-memory representation of the current state. When Prometheus scrapes it, KSM returns all this state as metrics. Because `metricLabelsAllowlist=[*]` is set, every single Kubernetes label on every object is included as a metric label.

- **OpenCost** continuously queries Prometheus (via HTTP on port 80) to compute cost allocation. It uses the kubecost cost model to map resource usage to dollar amounts.

- **Prometheus** stores all scraped data in its TSDB (time series database). Data is kept for 10 days or until the retention size limit is hit, whichever comes first.

**Every hour (at minute 0):**
- The **onelens-agent CronJob** spawns a pod that:
  1. Health-checks Prometheus (`/-/healthy`) and OpenCost (`/healthz`)
  2. Queries both for the collected metrics and cost data
  3. Packages it up and sends it to `api-in.onelens.cloud` via HTTPS
  4. The pod exits after it's done

---

### Step 5: Daily updates via the updater CronJob

**Every day at 2 AM UTC**, Kubernetes runs the `onelensupdater` CronJob. Here's exactly what happens:

1. A pod starts using the same Docker image as the installer
2. `entrypoint.sh` runs, sees `deployment_type=cronjob`
3. It calls `POST /v1/kubernetes/cluster-version` with the cluster's `REGISTRATION_ID` and `CLUSTER_TOKEN`
4. The API responds with:
   - `patching_enabled: true/false` — whether OneLens wants to update this cluster
   - `current_version` — what version the cluster is currently running
   - `patching_version` — what version to update to
5. If patching is disabled, the pod exits cleanly
6. If patching is enabled, it calls `POST /v1/kubernetes/patching-script` to **download the actual patching script** from the API. This is important — the script is **not baked into the image**. OneLens can change what the patching script does without rebuilding the Docker image.
7. It saves the downloaded script as `patching.sh`, makes it executable, and runs it
8. The `patching.sh` script (the reference copy is in this repo) does:
   - Installs helm and kubectl (just like install.sh did)
   - Counts pods in the cluster again
   - Computes new resource allocations based on current cluster size
   - Runs `helm upgrade onelens-agent ...` with `--reuse-values` (keeps existing config) plus `--set` overrides for the new resource values
9. After success, it reports back to the API: `PATCH_STATUS: SUCCESS`, updates the version, and disables patching until next time

---

## The two Helm charts and how they relate

There are **two separate Helm releases** in the cluster:

### Release 1: `onelensdeployer`
- Installed by the customer directly
- Contains: the installer Job + the updater CronJob + all RBAC
- Its templates are in `charts/onelensdeployer/templates/`
- This is the "control plane" for the installation

### Release 2: `onelens-agent`
- Installed **by Release 1** (the Job runs `helm install` from inside the cluster)
- Contains: Prometheus + KSM + Pushgateway + OpenCost + OneLens Agent
- This is an **umbrella chart** — it has **zero templates of its own**
- It bundles three sub-charts as `.tgz` files in its `charts/` directory:
  - `onelens-agent-base-2.0.1.tgz` — the proprietary agent (CronJob, Secrets, StorageClass, RBAC)
  - `prometheus-27.3.0.tgz` — the full Prometheus community chart (server, KSM, pushgateway, configmap-reload)
  - `prometheus-opencost-exporter-0.1.1.tgz` — the OpenCost community chart

The umbrella chart's `values.yaml` configures all three sub-charts. Values are passed down by key name:
- Keys under `onelens-agent:` → go to `onelens-agent-base`
- Keys under `prometheus:` → go to the Prometheus chart
- Keys under `prometheus.kube-state-metrics:` → go to KSM (sub-sub-chart of Prometheus)
- Keys under `prometheus.prometheus-pushgateway:` → go to Pushgateway (sub-sub-chart of Prometheus)
- Keys under `prometheus-opencost-exporter:` → go to OpenCost

---

## Configuration layering — how values get applied

This is crucial to understand when debugging issues. Values are applied in layers, where each layer can override the previous one:

**Layer 1 (lowest priority): Sub-chart built-in defaults**
Each sub-chart (Prometheus, KSM, OpenCost, etc.) has its own `values.yaml` with defaults. For example, the Prometheus community chart might default to 15-day retention.

**Layer 2: The umbrella chart's `values.yaml`**
The file at `charts/onelens-agent/values.yaml` overrides sub-chart defaults. For example, it sets Prometheus retention to 30 days and KSM collectors to a specific list of 15 types.

**Layer 3: `globalvalues.yaml`**
This file is baked into the Docker image and passed via `-f globalvalues.yaml` during `helm install`. It provides the "OneLens standard" configuration. It overrides some things from the umbrella chart's values.yaml (like scrape intervals, resource settings, etc.).

**Layer 4 (highest priority): `--set` flags**
Both `install.sh` and `patching.sh` pass `--set` flags that override everything above. This is where cluster-specific values (secrets, computed resource sizes, cloud provider settings) are applied.

**The gotcha:** `patching.sh` also uses `--set` flags with `--reuse-values`. The `--reuse-values` flag tells Helm to keep all previously-set values, but any `--set` flags in the patching command will override them. So if `install.sh` set KSM memory to 400Mi, but `patching.sh` sets it to 100Mi, the patching run wins and KSM memory drops to 100Mi.

---

## The CI/CD pipeline (how releases are built)

### Building the Docker image (`.github/workflows/build-onelens-deployer.yml`)
1. A developer pushes a git tag like `v2.0.1`
2. GitHub Actions builds the Docker image from the `Dockerfile`
3. It runs Trivy security scanning — if any CRITICAL or HIGH vulnerabilities are found, the build fails
4. If scanning passes, it builds for both AMD64 and ARM64 architectures
5. Pushes to `public.ecr.aws/w7k6q5m9/onelens-deployer:v2.0.1`

### Publishing the Helm charts (`.github/workflows/helm-package-release.yml`)
1. Same git tag triggers this workflow
2. It validates that the git tag matches the version in both `Chart.yaml` files
3. It packages both charts (onelens-agent and onelensdeployer) into `.tgz` files
4. Copies them to the `gh-pages` branch and updates the Helm repository index
5. Creates a PR for review — once merged, the charts are live at `https://astuto-ai.github.io/onelens-installation-scripts/`

---

## RBAC Architecture — Full Permission Map

RBAC (Role-Based Access Control) is how Kubernetes controls "who can do what." Three concepts:
- **ServiceAccount** = an identity (who you are). A pod runs as a ServiceAccount.
- **Role / ClusterRole** = a permission list (what you're allowed to do). Role = namespace-scoped, ClusterRole = cluster-wide.
- **RoleBinding / ClusterRoleBinding** = the link between an identity and a permission list (giving permissions to someone).

### Deployer chart RBAC — at installation time

During the first install, the Job pod (`onelensdeployerjob`) runs as `onelensdeployerjob-sa`. This ServiceAccount has three sets of permissions:

| Permission | Type | Scope | What it allows | Why needed |
|---|---|---|---|---|
| `onelensdeployer-role` | Role | `onelens-agent` namespace only | Everything (`*/*` verbs `*`) | `helm install` creates pods, services, secrets, configmaps etc. in the namespace |
| `onelensdeployer-clusterrole` | ClusterRole | Entire cluster | READ-ONLY on pods/nodes/deployments/etc. + WRITE on named resources (`onelens-sc`, `onelens-agent` ns, specific ClusterRoles by name) | Monitoring stack needs cluster-wide reads; deployer manages its own named resources |
| `onelensdeployer-bootstrap-clusterrole` | ClusterRole | Entire cluster | CREATE only — namespaces, storageclasses, clusterroles, clusterrolebindings | First install: these resources don't exist yet, so ongoing role's `resourceNames` restrictions can't apply |

The bootstrap ClusterRole is bound **only** to the Job SA (via `bootstrap-clusterrolebinding.yaml`). The CronJob SA never gets it.

### Deployer chart RBAC — ongoing (after install)

After `install.sh` finishes, it deletes the bootstrap ClusterRole, bootstrap ClusterRoleBinding, the Job itself, and the Job's ServiceAccount. What remains:

The CronJob pod (`onelensupdater`) runs as `onelensupdater-sa`. This ServiceAccount has two sets of permissions:

| Permission | Type | Scope | What it allows | Why needed |
|---|---|---|---|---|
| `onelensdeployer-role` | Role | `onelens-agent` namespace only | Everything (`*/*` verbs `*`) | `helm upgrade` modifies pods, services, secrets, etc. in the namespace |
| `onelensdeployer-clusterrole` | ClusterRole | Entire cluster | READ-ONLY on cluster resources + WRITE on named resources only | Same as before — manages monitoring stack's ClusterRoles by name, reads cluster state |

Notice: no bootstrap ClusterRole. The CronJob can manage existing resources by name but cannot create new cluster-scoped resources from scratch.

### Monitoring stack RBAC (created by `helm install onelens-agent`)

When `install.sh` runs `helm install onelens-agent`, the monitoring chart creates its own ServiceAccounts and ClusterRoles for the monitoring pods:

| ServiceAccount | Used by | Permissions | Why |
|---|---|---|---|
| `onelens-agent-prometheus-server` | Prometheus server pod | ClusterRole: read-only on pods, nodes, endpoints, services, ingresses + scrape `/metrics` non-resource URL | Prometheus needs to discover and scrape metrics from all targets across all namespaces |
| `onelens-agent-kube-state-metrics` | KSM pod | ClusterRole: read-only on all 15 resource types (pods, deployments, nodes, replicasets, daemonsets, statefulsets, cronjobs, jobs, HPAs, limitranges, PVCs, PVs, storageclasses, namespaces, resourcequotas) | KSM watches the K8s API and converts object state into Prometheus metrics — it needs to see everything |
| `onelens-agent-prometheus-opencost-exporter` | OpenCost pod | ClusterRole: read-only on nodes, pods, namespaces | OpenCost needs node pricing info and pod resource requests to compute costs |
| `onelens-agent-workload-reader` | OneLens agent CronJob | ClusterRole: read-only on common workload resources | The agent queries Prometheus/OpenCost and may need to cross-reference with live cluster state |

These ClusterRoles/Bindings are the ones listed by name in the deployer's ongoing ClusterRole (so the deployer can manage them via `helm upgrade`).

### Visual: Who has what permissions

```
DURING FIRST INSTALL:
┌─────────────────────────┐
│ onelensdeployerjob-sa   │──── RoleBinding ────▶ Role: full namespace control
│ (Job pod)               │──── ClusterRoleBinding ──▶ ClusterRole: ongoing (read + named writes)
│                         │──── ClusterRoleBinding ──▶ ClusterRole: bootstrap (create only) ← TEMPORARY
└─────────────────────────┘

┌─────────────────────────┐
│ onelensupdater-sa       │──── RoleBinding ────▶ Role: full namespace control
│ (CronJob pod)           │──── ClusterRoleBinding ──▶ ClusterRole: ongoing (read + named writes)
└─────────────────────────┘

AFTER INSTALL CLEANUP (steady state):
┌─────────────────────────┐
│ onelensdeployerjob-sa   │  ← DELETED (Job + SA removed)
└─────────────────────────┘
bootstrap ClusterRole      ← DELETED
bootstrap ClusterRoleBinding ← DELETED

┌─────────────────────────┐
│ onelensupdater-sa       │──── RoleBinding ────▶ Role: full namespace control
│ (CronJob, runs daily)   │──── ClusterRoleBinding ──▶ ClusterRole: ongoing (read + named writes)
└─────────────────────────┘

┌─────────────────────────┐
│ prometheus-server SA    │──── ClusterRoleBinding ──▶ ClusterRole: read pods/nodes/endpoints + /metrics
└─────────────────────────┘
┌─────────────────────────┐
│ kube-state-metrics SA   │──── ClusterRoleBinding ──▶ ClusterRole: read all 15 resource types
└─────────────────────────┘
┌─────────────────────────┐
│ opencost SA             │──── ClusterRoleBinding ──▶ ClusterRole: read nodes/pods/namespaces
└─────────────────────────┘
┌─────────────────────────┐
│ onelens-agent SA        │──── ClusterRoleBinding ──▶ ClusterRole: read workload resources
└─────────────────────────┘
```

---

## File-by-file reference

| File | What it does |
|---|---|
| `install.sh` | The main installer. Runs inside the Job pod. Registers, detects cloud, sizes resources, runs `helm install`. |
| `patching.sh` | Reference copy of the daily update script. The real one is served from the API and may differ. |
| `entrypoint.sh` | Docker entrypoint. Routes to `install.sh` (for jobs) or fetches+runs patching script (for cronjobs). |
| `Dockerfile` | Builds the deployer image. Alpine + curl + helm + kubectl + jq + aws-cli + the scripts above. |
| `globalvalues.yaml` | Base Helm values for the monitoring stack. Baked into the Docker image. Defines scrape configs, collectors, image tags, etc. |
| `charts/onelens-agent/Chart.yaml` | Defines the umbrella chart and its three dependencies. |
| `charts/onelens-agent/values.yaml` | Default configuration for the umbrella chart. Configures all sub-charts. |
| `charts/onelens-agent/charts/*.tgz` | Packaged sub-charts (onelens-agent-base, prometheus, opencost). |
| `charts/onelensdeployer/Chart.yaml` | Defines the deployer chart. |
| `charts/onelensdeployer/values.yaml` | Configuration for the Job, CronJob, and RBAC. Resource limits, schedules, image tags. |
| `charts/onelensdeployer/templates/job.yaml` | Template for the one-time installer Job. |
| `charts/onelensdeployer/templates/cronjob.yaml` | Template for the daily updater CronJob. Reads secrets from `onelens-agent-secrets`. |
| `charts/onelensdeployer/templates/sa.yaml` | Two ServiceAccounts — one for the job, one for the cronjob. |
| `charts/onelensdeployer/templates/role.yaml` | Namespace-scoped role: full control over `onelens-agent` namespace. |
| `charts/onelensdeployer/templates/clusterole.yaml` | Cluster-scoped role: limited to specific resource names (onelens-sc, onelens-agent namespace, specific ClusterRoles). |
| `charts/onelensdeployer/templates/bootstrap-clusterrole.yaml` | Temporary broad permissions for initial setup. Deleted after installation. |
| `scripts/prereq-check/` | Standalone script customers can run before installation to verify their environment. |
| `scripts/ebs-driver-installation/` | Standalone script to install the AWS EBS CSI driver with proper IAM roles. |
| `scripts/dedicated-node-installation/` | Scripts to create dedicated node pools (with taints) for OneLens workloads. |

---

## Summary in one paragraph

A customer installs the `onelensdeployer` Helm chart, which creates a one-time Job. That Job runs `install.sh` inside a Docker container, which registers with the OneLens API, detects the cloud provider, sizes resources based on cluster size, and runs `helm install` to deploy the actual monitoring stack (Prometheus + KSM + Pushgateway + OpenCost + OneLens Agent) as a second Helm release. Once running, Prometheus scrapes metrics at a regular interval from nodes, pods, and KSM; OpenCost queries Prometheus to compute costs; and the OneLens agent sends everything to the cloud every hour. A daily CronJob fetches an update script from the OneLens API and runs `helm upgrade` to keep the stack up to date. The installer Job and its broad permissions are cleaned up after first run, leaving only minimal RBAC for the daily updater.
