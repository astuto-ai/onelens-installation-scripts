# OneLens — Architecture & Sequence Diagrams

Quick visual reference for the entire system. For verbose explanations, see `architecture.md`.

---

## 1. High-Level System Overview

What exists after a successful installation. Two Helm releases + the cloud backend.

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                                  │
│                              CUSTOMER'S KUBERNETES CLUSTER                                       │
│                              namespace: onelens-agent                                            │
│                                                                                                  │
│  ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐  │
│    HELM RELEASE #1: onelensdeployer                                                           │  │
│  │ (installed by customer directly)                                                           │  │
│                                                                                               │  │
│  │ ┌──────────────────────────────┐    ┌──────────────────────────────────────────────────┐   │  │
│    │                              │    │                                                  │      │
│  │ │  Job: onelensdeployerjob     │    │  CronJob: onelensupdater                         │   │  │
│    │  (runs ONCE at install time) │    │  (runs DAILY at 2:00 AM UTC)                     │      │
│  │ │                              │    │                                                  │   │  │
│    │  Image: onelens-deployer     │    │  Image: onelens-deployer (same image)            │      │
│  │ │  SA: onelensdeployerjob-sa   │    │  SA: onelensupdater-sa                           │   │  │
│    │                              │    │                                                  │      │
│  │ │  Runs: entrypoint.sh        │    │  Runs: entrypoint.sh                             │   │  │
│    │    └─▶ install.sh            │    │    └─▶ fetches patching.sh from API              │      │
│  │ │       (baked in image)       │    │        (downloaded at runtime, NOT in image)      │   │  │
│    │                              │    │                                                  │      │
│  │ │  Resources: 400m / 250Mi    │    │  Resources: 400m / 250Mi                         │   │  │
│    │                              │    │                                                  │      │
│  │ │  DELETED after install ──────┼─X  │  Reads secrets from: onelens-agent-secrets       │   │  │
│    │  (job + SA + bootstrap RBAC) │    │  (CLUSTER_TOKEN, REGISTRATION_ID)                │      │
│  │ └──────────────────────────────┘    └──────────────────────────────────────────────────┘   │  │
│   ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─   │
│                                                                                                  │
│         │ helm upgrade --install                          │ helm upgrade --reuse-values           │
│         │ (creates Release #2)                            │ (updates Release #2)                  │
│         ▼                                                 ▼                                       │
│  ┌───────────────────────────────────────────────────────────────────────────────────────────┐   │
│  │ HELM RELEASE #2: onelens-agent                                                            │   │
│  │ (umbrella chart — has NO templates of its own, only bundles sub-charts)                    │   │
│  │                                                                                           │   │
│  │  ┌─────────────────────────────────────────────────────────────────────────────────────┐  │   │
│  │  │ SUB-CHART: onelens-agent-base v2.0.1                                                │  │   │
│  │  │ (proprietary — hosted on ECR OCI registry)                                          │  │   │
│  │  │                                                                                     │  │   │
│  │  │  ┌─────────────────────────────┐  ┌────────────────┐  ┌─────────────────────────┐  │  │   │
│  │  │  │ CronJob: onelens-agent      │  │ Secret:        │  │ StorageClass: onelens-sc │  │  │   │
│  │  │  │ Schedule: every hour (0 *)  │  │ API_BASE_URL   │  │                         │  │  │   │
│  │  │  │                             │  │ CLUSTER_TOKEN  │  │ AWS: ebs.csi.aws.com    │  │  │   │
│  │  │  │ Collects metrics from       │  │ REGISTRATION_ID│  │      volumeType: gp3    │  │  │   │
│  │  │  │ Prometheus + OpenCost       │  │                │  │                         │  │  │   │
│  │  │  │ and sends to OneLens cloud  │  └────────────────┘  │ Azure: disk.csi.azure   │  │  │   │
│  │  │  │                             │                      │        sku: StandardSSD  │  │  │   │
│  │  │  │ Resources: 400m / 400Mi     │  ┌────────────────┐  │                         │  │  │   │
│  │  │  │ (varies by cluster size)    │  │ ServiceAccount │  │ reclaimPolicy: Delete   │  │  │   │
│  │  │  │                             │  │ onelens-agent  │  │ binding: WaitForFirst   │  │  │   │
│  │  │  │ Image: onelens-agent:v2.0.1 │  │ -sa            │  │ Consumer                │  │  │   │
│  │  │  └─────────────────────────────┘  └────────────────┘  └─────────────────────────┘  │  │   │
│  │  └─────────────────────────────────────────────────────────────────────────────────────┘  │   │
│  │                                                                                           │   │
│  │  ┌─────────────────────────────────────────────────────────────────────────────────────┐  │   │
│  │  │ SUB-CHART: prometheus v27.3.0                                                       │  │   │
│  │  │ (community chart from prometheus-community)                                         │  │   │
│  │  │                                                                                     │  │   │
│  │  │  ┌───────────────────────────────────────────────────────────────────────────────┐  │  │   │
│  │  │  │ Deployment: prometheus-server                                                 │  │  │   │
│  │  │  │                                                                               │  │  │   │
│  │  │  │  ┌─────────────────────────────┐  ┌─────────────────────────────────────┐     │  │  │   │
│  │  │  │  │ Container: prometheus        │  │ Sidecar: configmap-reload           │     │  │  │   │
│  │  │  │  │                             │  │                                     │     │  │  │   │
│  │  │  │  │ Image: prometheus:v3.1.0    │  │ Image: prometheus-config-reloader   │     │  │  │   │
│  │  │  │  │ Port: 9090                  │  │ v0.79.2                             │     │  │  │   │
│  │  │  │  │ Service port: 80            │  │                                     │     │  │  │   │
│  │  │  │  │                             │  │ Watches ConfigMap changes and       │     │  │  │   │
│  │  │  │  │ Scrape interval: 30s or 1m  │  │ triggers hot reload via POST to    │     │  │  │   │
│  │  │  │  │ (see oom-issues.md #6 —     │  │ /-/reload (NOT a restart)          │     │  │  │   │
│  │  │  │  │  two keys set differently)  │  │                                     │     │  │  │   │
│  │  │  │  │ Retention: 10d              │  │                                     │     │  │  │   │
│  │  │  │  │ Retention size: 6-35GB      │  │ Resources: 100m / 100Mi            │     │  │  │   │
│  │  │  │  │ (varies by cluster size)    │  └─────────────────────────────────────┘     │  │  │   │
│  │  │  │  │                             │                                              │  │  │   │
│  │  │  │  │ PVC: onelens-sc             │  Storage: PersistentVolume 10-50Gi           │  │  │   │
│  │  │  │  │ (enabled via install.sh)    │  (sized by install.sh based on pod count)    │  │  │   │
│  │  │  │  │                             │                                              │  │  │   │
│  │  │  │  │ Resources: 300m-1500m CPU   │                                              │  │  │   │
│  │  │  │  │           1188Mi-7066Mi RAM │                                              │  │  │   │
│  │  │  │  │ (varies by cluster size)    │                                              │  │  │   │
│  │  │  │  └─────────────────────────────┘                                              │  │  │   │
│  │  │  └───────────────────────────────────────────────────────────────────────────────┘  │  │   │
│  │  │                                                                                     │  │   │
│  │  │  ┌───────────────────────────────────┐  ┌────────────────────────────────────────┐  │  │   │
│  │  │  │ Deployment: kube-state-metrics    │  │ Deployment: prometheus-pushgateway     │  │  │   │
│  │  │  │ (KSM)                             │  │                                        │  │  │   │
│  │  │  │                                   │  │ Accepts pushed metrics from             │  │  │   │
│  │  │  │ Watches K8s API for 15 resource   │  │ short-lived batch jobs                  │  │  │   │
│  │  │  │ types and converts object state   │  │                                        │  │  │   │
│  │  │  │ into Prometheus metrics           │  │ Port: 9091                             │  │  │   │
│  │  │  │                                   │  │ Resources: 100m / 100Mi               │  │  │   │
│  │  │  │ 15 collectors:                    │  │                                        │  │  │   │
│  │  │  │  pods, deployments, replicasets,  │  │ ⚠ OOM RISK: Fixed 100Mi for all       │  │  │   │
│  │  │  │  daemonsets, statefulsets, nodes,  │  │   cluster sizes (patching.sh)          │  │  │   │
│  │  │  │  namespaces, jobs, cronjobs,      │  └────────────────────────────────────────┘  │  │   │
│  │  │  │  HPAs, PVCs, PVs, limitranges,   │                                              │  │   │
│  │  │  │  resourcequotas, storageclasses   │                                              │  │   │
│  │  │  │                                   │                                              │  │   │
│  │  │  │ ⚠ metricLabelsAllowlist: [*]     │                                              │  │   │
│  │  │  │   (exports ALL K8s labels — this  │                                              │  │   │
│  │  │  │   is the #1 cause of OOM kills)   │                                              │  │   │
│  │  │  │                                   │                                              │  │   │
│  │  │  │ Port: 8080                        │                                              │  │   │
│  │  │  │ Resources: 100m / 100Mi           │                                              │  │   │
│  │  │  │                                   │                                              │  │   │
│  │  │  │ ⚠ OOM RISK: 100Mi is far too     │                                              │  │   │
│  │  │  │   low for [*] label cardinality   │                                              │  │   │
│  │  │  └───────────────────────────────────┘                                              │  │   │
│  │  └─────────────────────────────────────────────────────────────────────────────────────┘  │   │
│  │                                                                                           │   │
│  │  ┌─────────────────────────────────────────────────────────────────────────────────────┐  │   │
│  │  │ SUB-CHART: prometheus-opencost-exporter v0.1.1                                      │  │   │
│  │  │ (community chart from prometheus-community)                                         │  │   │
│  │  │                                                                                     │  │   │
│  │  │  ┌───────────────────────────────────────────────────────────────────────────────┐  │  │   │
│  │  │  │ Deployment: opencost (kubecost-cost-model)                                    │  │  │   │
│  │  │  │                                                                               │  │  │   │
│  │  │  │ Queries Prometheus server on :80 to fetch resource usage metrics              │  │  │   │
│  │  │  │ Computes per-pod / per-namespace / per-workload cost in dollars               │  │  │   │
│  │  │  │ Exposes cost metrics on :9003/metrics (scraped by Prometheus every 1m)        │  │  │   │
│  │  │  │ Health endpoint: :9003/healthz                                                │  │  │   │
│  │  │  │                                                                               │  │  │   │
│  │  │  │ Resources: 200m-300m CPU / 200Mi-600Mi RAM (varies by cluster size)           │  │  │   │
│  │  │  │ Liveness/Readiness: initialDelaySeconds=120 (needs 2 min to build cost model) │  │  │   │
│  │  │  │                                                                               │  │  │   │
│  │  │  │ ⚠ OOM RISK: 200-250Mi too low for medium clusters (100-499 pods)             │  │  │   │
│  │  │  └───────────────────────────────────────────────────────────────────────────────┘  │  │   │
│  │  └─────────────────────────────────────────────────────────────────────────────────────┘  │   │
│  └───────────────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                                  │
└──────────────────────────────────────────────────────────────────────────────────────────────────┘
                           │                                │
                           │ HTTPS                          │ HTTPS
                           ▼                                ▼
              ┌──────────────────────────────────────────────────────────┐
              │                                                          │
              │              OneLens Cloud Backend                       │
              │              https://api-in.onelens.cloud                │
              │                                                          │
              │  Endpoints used:                                         │
              │    POST /v1/kubernetes/registration      ← register      │
              │    PUT  /v1/kubernetes/registration      ← status update │
              │    POST /v1/kubernetes/cluster-version   ← check patch   │
              │    POST /v1/kubernetes/patching-script   ← get script    │
              │    PUT  /v1/kubernetes/cluster-version   ← report done   │
              │                                                          │
              └──────────────────────────────────────────────────────────┘
```

---

## 2. Installation Sequence (What happens when a customer installs)

Step-by-step timeline from customer running `helm install` to a fully operational monitoring stack.

```
CUSTOMER                    KUBERNETES                   ONELENS API
   │                           │                             │
   │  helm install             │                             │
   │  onelensdeployer          │                             │
   │  --set TOKEN=xxx          │                             │
   │  --set CLUSTER_NAME=yyy   │                             │
   │ ─────────────────────────▶│                             │
   │                           │                             │
   │                    ┌──────┴───────────────────────────────────────────────────────┐
   │                    │ Creates in namespace "onelens-agent":                        │
   │                    │                                                              │
   │                    │ PODS (both use same Docker image, different purposes):        │
   │                    │  • Job: onelensdeployerjob                                   │
   │                    │    - Runs ONCE at install time, executes install.sh           │
   │                    │    - Auto-deletes after 300s (ttlSecondsAfterFinished)        │
   │                    │    - Uses ServiceAccount: onelensdeployerjob-sa               │
   │                    │  • CronJob: onelensupdater                                   │
   │                    │    - Runs DAILY at 2am (schedule: "0 2 * * *")               │
   │                    │    - Fetches latest patching script from API, runs it         │
   │                    │    - Uses ServiceAccount: onelensupdater-sa                   │
   │                    │                                                              │
   │                    │ IDENTITIES (who the pods "are" when talking to K8s API):      │
   │                    │  • ServiceAccount: onelensdeployerjob-sa   (for Job)          │
   │                    │  • ServiceAccount: onelensupdater-sa       (for CronJob)      │
   │                    │  Separate SAs so bootstrap perms go to Job only, not CronJob  │
   │                    │                                                              │
   │                    │ NAMESPACE-SCOPED PERMISSIONS (only within onelens-agent ns):  │
   │                    │  • Role: onelensdeployer-role                                 │
   │                    │    - Rules: apiGroups=* resources=* verbs=*                   │
   │                    │    - Means: full control, but ONLY inside this namespace      │
   │                    │  • RoleBinding: onelensdeployer-rolebinding                   │
   │                    │    - Connects: Role → BOTH ServiceAccounts                    │
   │                    │    - Both Job and CronJob can manage resources in namespace   │
   │                    │                                                              │
   │                    │ CLUSTER-WIDE PERMISSIONS — ONGOING (permanent, day-to-day):   │
   │                    │  • ClusterRole: onelensdeployer-clusterrole                   │
   │                    │    - READ-ONLY (get/list/watch) on cluster resources:          │
   │                    │      pods, nodes, deployments, namespaces, etc.               │
   │                    │      (needed by Prometheus + KSM to scrape entire cluster)    │
   │                    │    - WRITE access restricted to named resources we own:        │
   │                    │      StorageClass "onelens-sc", Namespace "onelens-agent",    │
   │                    │      specific ClusterRoles/Bindings by exact name             │
   │                    │  • ClusterRoleBinding: onelensdeployer-clusterrolebinding     │
   │                    │    - Connects: ClusterRole → BOTH ServiceAccounts             │
   │                    │                                                              │
   │                    │ CLUSTER-WIDE PERMISSIONS — BOOTSTRAP (temporary, install-only):│
   │                    │  • ClusterRole: onelensdeployer-bootstrap-clusterrole         │
   │                    │    - Only verb: "create" (not update, not delete, not get)    │
   │                    │    - Can create: namespaces, storageclasses, clusterroles,    │
   │                    │      clusterrolebindings                                     │
   │                    │    - WHY NEEDED: chicken-and-egg problem — the ongoing role   │
   │                    │      restricts writes by resourceNames (e.g. "onelens-sc"),   │
   │                    │      but on first install those resources don't exist yet,    │
   │                    │      so we need unrestricted "create" to make them            │
   │                    │    - Cleaned up by install.sh after first install completes   │
   │                    │  • ClusterRoleBinding: bootstrap-clusterrolebinding           │
   │                    │    - Connects: bootstrap ClusterRole → ONLY Job SA            │
   │                    │    - CronJob never gets bootstrap powers (least privilege)    │
   │                    └──────┬───────────────────────────────────────────────────────┘
   │                           │                             │
   │                    ┌──────┴──────────────────────┐      │
   │                    │ Job pod starts               │      │
   │                    │ Image: onelens-deployer      │      │
   │                    │                              │      │
   │                    │ entrypoint.sh                │      │
   │                    │  └─▶ deployment_type="job"   │      │
   │                    │      └─▶ runs install.sh     │      │
   │                    └──────┬──────────────────────┘      │
   │                           │                             │
   │                           │  POST /v1/kubernetes/       │
   │                           │  registration               │
   │                           │  {registration_token,       │
   │                           │   cluster_name, account_id, │
   │                           │   region, agent_version}    │
   │                           │ ───────────────────────────▶│
   │                           │                             │
   │                           │  Response:                  │
   │                           │  {cluster_token,            │
   │                           │   registration_id}          │
   │                           │ ◀───────────────────────────│
   │                           │                             │
   │                    ┌──────┴──────────────────────┐      │
   │                    │ install.sh continues:        │      │
   │                    │                              │      │
   │                    │ 1. Install helm binary       │      │
   │                    │ 2. Install kubectl binary    │      │
   │                    │ 3. Create namespace          │      │
   │                    │    "onelens-agent"            │      │
   │                    │ 4. Detect cloud provider:    │      │
   │                    │    - Check cluster endpoint   │      │
   │                    │    - *.eks.amazonaws.com→AWS  │      │
   │                    │    - *.azmk8s.io→AZURE       │      │
   │                    │ 5. Check/install CSI driver   │      │
   │                    │    - AWS: EBS CSI driver      │      │
   │                    │    - Azure: validate          │      │
   │                    │ 6. Count pods in cluster      │      │
   │                    │ 7. Calculate resources:       │      │
   │                    │    <100  → small tier         │      │
   │                    │    <500  → medium tier        │      │
   │                    │    <1000 → large tier         │      │
   │                    │    <1500 → xlarge tier        │      │
   │                    │    1500+ → xxlarge tier       │      │
   │                    └──────┬──────────────────────┘      │
   │                           │                             │
   │                    ┌──────┴──────────────────────┐      │
   │                    │ install.sh runs:             │      │
   │                    │                              │      │
   │                    │ helm upgrade --install       │      │
   │                    │   onelens-agent              │      │
   │                    │   onelens/onelens-agent      │      │
   │                    │   --version 2.0.1            │      │
   │                    │   -f globalvalues.yaml       │      │
   │                    │   --set <secrets>            │      │
   │                    │   --set <resource sizes>     │      │
   │                    │   --set <cloud config>       │      │
   │                    │   --set <tolerations>        │      │
   │                    │   --wait                     │      │
   │                    │                              │      │
   │                    │ This creates ALL monitoring  │      │
   │                    │ pods as Helm Release #2      │      │
   │                    └──────┬──────────────────────┘      │
   │                           │                             │
   │                    ┌──────┴──────────────────────┐      │
   │                    │ Pods starting up:            │      │
   │                    │                              │      │
   │                    │  prometheus-server     ✓     │      │
   │                    │  kube-state-metrics    ✓     │      │
   │                    │  pushgateway           ✓     │      │
   │                    │  opencost              ...   │      │
   │                    │  (waiting 120s startup)      │      │
   │                    └──────┬──────────────────────┘      │
   │                           │                             │
   │                    ┌──────┴──────────────────────┐      │
   │                    │ kubectl wait --timeout=800s  │      │
   │                    │ for opencost pod ready       │      │
   │                    │                              │      │
   │                    │ (opencost needs 2+ min to    │      │
   │                    │  build its cost model by     │      │
   │                    │  querying prometheus)         │      │
   │                    └──────┬──────────────────────┘      │
   │                           │                             │
   │                           │  PUT /v1/kubernetes/        │
   │                           │  registration               │
   │                           │  {registration_id,          │
   │                           │   cluster_token,            │
   │                           │   status: "CONNECTED"}      │
   │                           │ ───────────────────────────▶│
   │                           │                             │
   │                    ┌──────┴──────────────────────┐      │
   │                    │ Cleanup:                     │      │
   │                    │                              │      │
   │                    │ 1. Delete bootstrap          │      │
   │                    │    ClusterRole +             │      │
   │                    │    ClusterRoleBinding        │      │
   │                    │    (broad permissions no     │      │
   │                    │     longer needed)            │      │
   │                    │                              │      │
   │                    │ 2. Delete Job +              │      │
   │                    │    Job's ServiceAccount      │      │
   │                    │    (installer is done)        │      │
   │                    └──────┬──────────────────────┘      │
   │                           │                             │
   │                    INSTALLATION COMPLETE                 │
   │                    Monitoring stack is running           │
   │                                                         │
```

---

## 3. Steady-State Data Flow (What happens continuously after installation)

How data flows between components during normal operation.

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                              KUBERNETES CLUSTER                                          │
│                                                                                          │
│                                                                                          │
│    ┌───────────────────────────────────────────────────┐                                 │
│    │           KUBERNETES API SERVER                    │                                 │
│    │                                                   │                                 │
│    │   Stores all cluster state:                       │                                 │
│    │   pods, deployments, nodes, services, etc.        │                                 │
│    │                                                   │                                 │
│    │   Also exposes:                                   │                                 │
│    │   • /metrics (API server own metrics)             │                                 │
│    │   • /api/v1/nodes/<n>/proxy/metrics (node metrics)│                                 │
│    │   • /api/v1/nodes/<n>/proxy/metrics/cadvisor      │                                 │
│    │     (container CPU/memory/disk/network metrics)   │                                 │
│    └────┬──────────────────┬───────────────────────────┘                                 │
│         │                  │                                                              │
│         │ watches          │ scrapes /metrics                                             │
│         │ (streaming)      │ and /cadvisor                                                │
│         ▼                  │ (every 30s or 1m — see oom-issues.md #6)                     │
│    ┌──────────────────┐    │                                                              │
│    │                  │    │                                                              │
│    │ kube-state-      │    │    ┌─────────────────────────────────────────────┐           │
│    │ metrics (KSM)    │    │    │                                             │           │
│    │                  │    │    │  PROMETHEUS SERVER                          │           │
│    │ Converts K8s     │    │    │                                             │           │
│    │ object state     │    │    │  ┌─────────────────────────────────────┐    │           │
│    │ into Prometheus  ├────┼───▶│  │  SCRAPE TARGETS (what it pulls     │    │           │
│    │ metrics          │    │    │  │  data from at the scrape interval):│    │           │
│    │                  │    │    │  │                                     │    │           │
│    │ Example:         │    └───▶│  │  1. kubernetes-apiservers          │    │           │
│    │ kube_pod_info    │         │  │     (API server /metrics)          │    │           │
│    │ kube_pod_status  │         │  │                                     │    │           │
│    │ kube_deploy_     │         │  │  2. kubernetes-nodes               │    │           │
│    │   status_replicas│         │  │     (kubelet /metrics per node)    │    │           │
│    │ kube_node_info   │         │  │                                     │    │           │
│    │ ... (hundreds    │         │  │  3. kubernetes-nodes-cadvisor      │    │           │
│    │  of metric types)│         │  │     (cAdvisor per node — container │    │           │
│    │                  │         │  │      CPU, memory, disk, network)   │    │           │
│    │ Port: 8080       │         │  │                                     │    │           │
│    │                  │         │  │  4. kube-state-metrics ◀── KSM     │    │           │
│    └──────────────────┘         │  │     (K8s object state metrics)     │    │           │
│                                 │  │                                     │    │           │
│    ┌──────────────────┐         │  │  5. prometheus-pushgateway         │    │           │
│    │                  │         │  │     (batch job metrics)            │    │           │
│    │  pushgateway     ├────────▶│  │                                     │    │           │
│    │                  │         │  │  6. kubernetes-service-endpoints   │    │           │
│    │  Port: 9091      │         │  │     (custom app metrics via        │    │           │
│    │                  │         │  │      annotation: custom.metrics/   │    │           │
│    └──────────────────┘         │  │      scrape: "true")              │    │           │
│                                 │  │                                     │    │           │
│                                 │  │  7. kubernetes-pods                │    │           │
│                                 │  │     (pod-level custom metrics      │    │           │
│                                 │  │      via annotation)              │    │           │
│                                 │  │                                     │    │           │
│    ┌──────────────────┐    ┌───▶│  │  8. opencost ◀── OpenCost         │    │           │
│    │                  │    │    │  │     (cost metrics, every 1 min)    │    │           │
│    │  OPENCOST        │    │    │  │                                     │    │           │
│    │                  │    │    │  │  9. prometheus (self-monitoring)   │    │           │
│    │  Queries ────────┼────┘    │  └─────────────────────────────────────┘    │           │
│    │  Prometheus      │         │                                             │           │
│    │  on :80 to get   │◀───────▶│  ┌─────────────────────────────────────┐    │           │
│    │  resource usage  │  scrape │  │  TSDB (Time Series Database)       │    │           │
│    │  data for cost   │  +query │  │                                     │    │           │
│    │  calculation     │         │  │  In-memory head block (recent data) │    │           │
│    │                  │         │  │  On-disk blocks (older data)        │    │           │
│    │  Exposes cost    │         │  │  WAL (Write-Ahead Log for recovery) │    │           │
│    │  metrics on      │         │  │                                     │    │           │
│    │  :9003/metrics   │         │  │  Retention: 10 days                │    │           │
│    │                  │         │  │  Max size: 6-35 GB                 │    │           │
│    │  Port: 9003      │         │  │  PVC: onelens-sc (10-50 Gi)       │    │           │
│    └──────────────────┘         │  └─────────────────────────────────────┘    │           │
│                                 │                                             │           │
│                                 │  Service: onelens-agent-prometheus-server   │           │
│                                 │  Port: 80 (ClusterIP)                      │           │
│                                 └──────────────────────────┬──────────────────┘           │
│                                                            │                              │
│                                                            │ queries on :80               │
│                                                            │ (PromQL over HTTP)           │
│                                                            │                              │
│                                 ┌──────────────────────────┴──────────────────┐           │
│                                 │                                             │           │
│                                 │  ONELENS AGENT (CronJob — runs every hour)  │           │
│                                 │                                             │           │
│                                 │  1. Health-check Prometheus                 │           │
│                                 │     GET :80/-/healthy                       │           │
│                                 │                                             │           │
│                                 │  2. Health-check OpenCost                   │           │
│                                 │     GET :9003/healthz                       │           │
│                                 │                                             │           │
│                                 │  3. Query Prometheus for resource metrics   │           │
│                                 │                                             │           │
│                                 │  4. Query OpenCost for cost data            │           │
│                                 │                                             │           │
│                                 │  5. Package and send to OneLens cloud ──────┼──── HTTPS │
│                                 │                                             │      │    │
│                                 │  Image: onelens-agent:v2.0.1               │      │    │
│                                 │  Resources: 400m-700m / 400Mi-700Mi        │      │    │
│                                 └─────────────────────────────────────────────┘      │    │
│                                                                                      │    │
└──────────────────────────────────────────────────────────────────────────────────────┼────┘
                                                                                       │
                                                                              ┌────────▼────────┐
                                                                              │  OneLens Cloud   │
                                                                              │  Backend         │
                                                                              │                  │
                                                                              │  Receives hourly │
                                                                              │  data uploads    │
                                                                              │  for cost        │
                                                                              │  analysis and    │
                                                                              │  dashboards      │
                                                                              └─────────────────┘
```

---

## 4. Daily Patching Sequence (What happens every day at 2 AM UTC)

```
KUBERNETES (CronJob)                                     ONELENS API
        │                                                     │
        │  2:00 AM UTC — CronJob triggers                     │
        │  Pod starts with same Docker image                  │
        │  as the installer (onelens-deployer)                │
        │                                                     │
        │  entrypoint.sh runs                                 │
        │  deployment_type = "cronjob"                        │
        │                                                     │
        │  POST /v1/kubernetes/cluster-version                │
        │  {registration_id, cluster_token}                   │
        │ ───────────────────────────────────────────────────▶│
        │                                                     │
        │  Response: {                                        │
        │    patching_enabled: true/false,                    │
        │    current_version: "2.0.0",                        │
        │    patching_version: "2.0.1"                        │
        │  }                                                  │
        │ ◀───────────────────────────────────────────────────│
        │                                                     │
        ├─── if patching_enabled == false ───▶ exit 0 (done)  │
        │                                                     │
        │  POST /v1/kubernetes/patching-script                │
        │  {registration_id, cluster_token}                   │
        │ ───────────────────────────────────────────────────▶│
        │                                                     │
        │  Response: {                                        │
        │    script_content: "#!/bin/bash\n..."               │
        │  }                                                  │
        │  (the ACTUAL patching script — may differ           │
        │   from the patching.sh in this repo!)               │
        │ ◀───────────────────────────────────────────────────│
        │                                                     │
  ┌─────┴───────────────────────────────────┐                 │
  │ Saves script as patching.sh             │                 │
  │ chmod +x patching.sh                    │                 │
  │ Executes patching.sh                    │                 │
  │                                         │                 │
  │ patching.sh does:                       │                 │
  │  1. Install helm + kubectl binaries     │                 │
  │  2. Count pods in cluster               │                 │
  │  3. Calculate new resource sizes        │                 │
  │     based on current pod count          │                 │
  │  4. helm repo add + update              │                 │
  │  5. helm upgrade onelens-agent          │                 │
  │     --reuse-values                      │                 │
  │     --set <new resource sizes>          │                 │
  │     --set <new image tag>               │                 │
  │     --atomic --timeout=5m               │                 │
  │                                         │                 │
  │  ⚠ BUG: KSM memory hardcoded to 100Mi  │                 │
  │    regardless of cluster size!          │                 │
  │    (overrides whatever install.sh set)  │                 │
  └─────┬───────────────────────────────────┘                 │
        │                                                     │
        ├─── if patching.sh failed ───▶ PUT /cluster-version  │
        │                               {logs: "failed"}      │
        │                               exit 1                │
        │                                                     │
        │  PUT /v1/kubernetes/cluster-version                 │
        │  {                                                  │
        │    registration_id, cluster_token,                  │
        │    logs: "Patching success",                        │
        │    patching_enabled: false,                         │
        │    prev_version: "2.0.0",                           │
        │    current_version: "2.0.1",                        │
        │    patch_status: "SUCCESS",                         │
        │    last_patched: "2026-02-24T02:05:00Z"             │
        │  }                                                  │
        │ ───────────────────────────────────────────────────▶│
        │                                                     │
        │  exit 0                                             │
        │  Pod terminates.                                    │
        │  TTL: auto-deleted after 120s.                      │
        │                                                     │
```

---

## 5. Configuration Layering (What overrides what)

Values are applied bottom-to-top. Higher layers override lower layers.

```
    HIGHEST PRIORITY (wins)
    ┌─────────────────────────────────────────────────────────────────────────┐
    │                                                                         │
    │  Layer 4: --set flags in install.sh / patching.sh                      │
    │                                                                         │
    │  These are computed at runtime based on cluster size.                   │
    │  Examples:                                                              │
    │    --set prometheus.server.resources.limits.memory="1771Mi"             │
    │    --set onelens-agent.secrets.CLUSTER_TOKEN="abc123"                   │
    │    --set onelens-agent.storageClass.provisioner="ebs.csi.aws.com"      │
    │                                                                         │
    │  ⚠ patching.sh --set values OVERRIDE install.sh --set values           │
    │    because patching runs AFTER install (even with --reuse-values)       │
    │                                                                         │
    ├─────────────────────────────────────────────────────────────────────────┤
    │                                                                         │
    │  Layer 3: globalvalues.yaml (passed via -f flag)                       │
    │                                                                         │
    │  Baked into the Docker image. Provides the "OneLens standard" config.  │
    │  Contains: scrape configs, KSM collectors, metricLabelsAllowlist,      │
    │  image tags, OpenCost settings, default resource sizes.                │
    │                                                                         │
    │  File: /globalvalues.yaml (inside the container)                       │
    │  Repo: /globalvalues.yaml (root of this repo)                          │
    │                                                                         │
    ├─────────────────────────────────────────────────────────────────────────┤
    │                                                                         │
    │  Layer 2: charts/onelens-agent/values.yaml (umbrella chart defaults)   │
    │                                                                         │
    │  The parent chart's values.yaml. Configures all three sub-charts.      │
    │  This is what you get if you do "helm install" without any -f or --set │
    │  Contains: full Prometheus config, KSM settings, OpenCost settings,    │
    │  retention, scrape jobs, security contexts, service types.             │
    │                                                                         │
    ├─────────────────────────────────────────────────────────────────────────┤
    │                                                                         │
    │  Layer 1: Sub-chart built-in defaults (inside .tgz packages)           │
    │                                                                         │
    │  Each sub-chart has its own values.yaml with upstream defaults.         │
    │  For example, the prometheus community chart defaults:                  │
    │    - retention: 15d                                                     │
    │    - server.resources: {} (no limits!)                                  │
    │    - kube-state-metrics.resources: {} (no limits!)                      │
    │  These are overridden by every layer above.                            │
    │                                                                         │
    └─────────────────────────────────────────────────────────────────────────┘
    LOWEST PRIORITY (gets overridden)


    Example flow for KSM memory limit:

    Layer 1: Sub-chart default         → {} (no limit set)
    Layer 2: umbrella values.yaml      → limits.memory: 100Mi
    Layer 3: globalvalues.yaml         → limits.memory: 100Mi  (same, no change)
    Layer 4: install.sh --set          → limits.memory: 400Mi  (for 1000+ pod cluster)
             patching.sh --set         → limits.memory: 100Mi  ⚠ REGRESSION! Overrides to 100Mi
```

---

## 6. RBAC Architecture (Who can do what)

**Key concepts for someone new to Kubernetes RBAC:**
- **ServiceAccount** = an identity for a pod. When a pod runs `kubectl` or `helm` inside itself, K8s checks "what ServiceAccount is this pod running as?" to decide what it's allowed to do. A ServiceAccount alone has ZERO permissions — it's just a name tag.
- **Role** = a list of permissions scoped to **one namespace** only. Like a key to one room.
- **ClusterRole** = a list of permissions across the **entire cluster**. Like a master key for all rooms + hallways (cluster-scoped resources like nodes, storageclasses).
- **RoleBinding** = connects a Role to one or more ServiceAccounts. "This person gets this room key."
- **ClusterRoleBinding** = connects a ClusterRole to one or more ServiceAccounts. "This person gets this master key."
- **Bootstrap** = temporary permissions needed only during first install. Deleted afterward.
- **Ongoing** = permanent permissions that persist after install for day-to-day operations.
- **`resourceNames`** = a restriction that limits a permission to specific named resources (e.g., "you can modify storageclasses, but only the one named `onelens-sc`").

```
 ┌──────────────────────────────────────────────────────────────────────────────────────────┐
 │                                                                                          │
 │  INSTALLATION TIME (Day 0)                                                               │
 │                                                                                          │
 │  onelensdeployerjob-sa ─────┬───▶ bootstrap-clusterrole                                 │
 │  (Job's ServiceAccount)     │     • create namespaces                                    │
 │                             │     • create storageclasses                                 │
 │                             │     • create clusterroles                                   │
 │                             │     • create clusterrolebindings                            │
 │                             │                                                             │
 │                             │     ⚠ DELETED after install.sh finishes                    │
 │                             │       (broad permissions, only needed once)                 │
 │                             │                                                             │
 │                             ├───▶ onelensdeployer-clusterrole (ongoing)                  │
 │                             │     • storageclasses: * BUT only resourceNames=[onelens-sc] │
 │                             │     • namespaces: * BUT only resourceNames=[onelens-agent]  │
 │                             │     • clusterroles: * BUT only specific resourceNames       │
 │                             │     • clusterrolebindings: * BUT only specific names        │
 │                             │     • READ-ONLY: pods, nodes, deployments, services, etc.   │
 │                             │     • READ-ONLY: /metrics (non-resource URL)                │
 │                             │                                                             │
 │                             └───▶ onelensdeployer-role (namespace-scoped)                │
 │                                   • namespace: onelens-agent                              │
 │                                   • ALL apiGroups, ALL resources, ALL verbs               │
 │                                   • (full control within own namespace)                   │
 │                                                                                          │
 │  DELETED after install:                                                                  │
 │    ✗ onelensdeployerjob-sa                                                               │
 │    ✗ bootstrap-clusterrole                                                               │
 │    ✗ bootstrap-clusterrolebinding                                                        │
 │    ✗ Job: onelensdeployerjob                                                             │
 │                                                                                          │
 └──────────────────────────────────────────────────────────────────────────────────────────┘

 ┌──────────────────────────────────────────────────────────────────────────────────────────┐
 │                                                                                          │
 │  ONGOING (Day 1+)                                                                        │
 │                                                                                          │
 │  onelensupdater-sa ─────────┬───▶ onelensdeployer-clusterrole (same as above)           │
 │  (CronJob's ServiceAccount) │     (scoped by resourceNames — minimal cluster access)     │
 │                             │                                                             │
 │                             └───▶ onelensdeployer-role (same as above)                   │
 │                                   (full control within onelens-agent namespace)           │
 │                                                                                          │
 │  onelens-agent-sa ──────────────▶ onelens-agent-workload-reader                         │
 │  (Agent CronJob's SA)            • READ-ONLY cluster-wide access                         │
 │                                  • pods, nodes, deployments, services, etc.               │
 │                                                                                          │
 │  prometheus-server-sa ──────────▶ prometheus-server ClusterRole                          │
 │  (Prometheus's SA)               • READ: pods, nodes, endpoints, services,               │
 │                                    configmaps, ingresses                                  │
 │                                  • GET: /metrics (non-resource URL)                       │
 │                                  • Needed for service discovery + scraping                │
 │                                                                                          │
 │  kube-state-metrics-sa ─────────▶ kube-state-metrics ClusterRole                        │
 │  (KSM's SA)                     • READ: all 15 resource types it collects                │
 │                                  • pods, deployments, nodes, PVCs, etc.                   │
 │                                                                                          │
 │  opencost-sa ───────────────────▶ opencost ClusterRole                                  │
 │  (OpenCost's SA)                 • READ: nodes, pods, namespaces                         │
 │                                  • Needed for cost model node pricing                     │
 │                                                                                          │
 └──────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 7. Docker Image Contents

What's inside the `onelens-deployer` Docker image used by the Job and CronJob.

```
 ┌─────────────────────────────────────────────────────────────┐
 │  Docker Image: public.ecr.aws/w7k6q5m9/onelens-deployer    │
 │  Base: alpine:3.18                                          │
 │                                                             │
 │  ┌───────────────────────────────────────────────────────┐  │
 │  │  OS packages (installed via apk):                     │  │
 │  │    curl, tar, gzip, bash, git, unzip, wget, jq,      │  │
 │  │    python3, py3-pip, aws-cli                          │  │
 │  └───────────────────────────────────────────────────────┘  │
 │                                                             │
 │  ┌───────────────────────────────────────────────────────┐  │
 │  │  Baked-in files:                                      │  │
 │  │                                                       │  │
 │  │  /entrypoint.sh      ← ENTRYPOINT (routes to         │  │
 │  │  │                      install.sh or API-fetched     │  │
 │  │  │                      patching script)              │  │
 │  │  │                                                    │  │
 │  │  /install.sh          ← Main installer (used by Job) │  │
 │  │  │                                                    │  │
 │  │  /globalvalues.yaml   ← Helm values (used by both    │  │
 │  │                         install.sh and patching.sh)   │  │
 │  └───────────────────────────────────────────────────────┘  │
 │                                                             │
 │  ┌───────────────────────────────────────────────────────┐  │
 │  │  NOT baked in (downloaded at runtime):                │  │
 │  │                                                       │  │
 │  │  helm binary        ← downloaded by install.sh /      │  │
 │  │                       patching.sh from get.helm.sh    │  │
 │  │                                                       │  │
 │  │  kubectl binary     ← downloaded by install.sh /      │  │
 │  │                       patching.sh from dl.k8s.io      │  │
 │  │                                                       │  │
 │  │  patching.sh        ← downloaded by entrypoint.sh     │  │
 │  │                       from OneLens API at runtime     │  │
 │  │                       (only for cronjob runs)         │  │
 │  └───────────────────────────────────────────────────────┘  │
 │                                                             │
 │  Note: helm and kubectl are re-downloaded every single      │
 │  time the Job or CronJob runs. This adds ~30-60 seconds    │
 │  to every execution and depends on external URLs being      │
 │  reachable from the customer's cluster.                     │
 │                                                             │
 └─────────────────────────────────────────────────────────────┘
```

---

## 8. Helm Chart Dependency Tree

How the charts nest inside each other.

```
 onelensdeployer (Chart v2.0.1)              onelens-agent (Chart v2.0.1)
 ├── templates/                              ├── NO templates (umbrella only)
 │   ├── job.yaml                            ├── values.yaml (configures all sub-charts)
 │   ├── cronjob.yaml                        │
 │   ├── sa.yaml (2 ServiceAccounts)         └── charts/
 │   ├── role.yaml                               │
 │   ├── rolebinding.yaml                        ├── onelens-agent-base-2.0.1.tgz
 │   ├── clusterole.yaml                         │   ├── templates/
 │   ├── clusterrolebinding.yaml                 │   │   ├── cronjob.yaml        ← agent CronJob
 │   ├── bootstrap-clusterrole.yaml              │   │   ├── secrets.yaml         ← API credentials
 │   ├── bootstrap-clusterrolebinding.yaml       │   │   ├── storageclass.yaml    ← onelens-sc
 │   └── _helpers.tpl                            │   │   ├── serviceaccount.yaml
 └── values.yaml                                 │   │   ├── configmap.yaml
                                                 │   │   ├── clusterrole.yaml
     Installed by: CUSTOMER                      │   │   ├── clusterrolebinding.yaml
     Contains: deployer job + updater cronjob    │   │   └── _helpers.tpl
                                                 │   └── values.yaml
                                                 │
                                                 ├── prometheus-27.3.0.tgz
                                                 │   ├── templates/
                                                 │   │   ├── deploy.yaml          ← server deployment
                                                 │   │   ├── cm.yaml              ← scrape configs
                                                 │   │   ├── pvc.yaml             ← persistent volume
                                                 │   │   ├── service.yaml
                                                 │   │   ├── clusterrole.yaml
                                                 │   │   └── ... (30+ templates)
                                                 │   ├── charts/
                                                 │   │   ├── kube-state-metrics/   ← sub-sub-chart
                                                 │   │   │   └── templates/
                                                 │   │   │       ├── deployment.yaml
                                                 │   │   │       ├── service.yaml
                                                 │   │   │       └── ...
                                                 │   │   ├── prometheus-pushgateway/ ← sub-sub-chart
                                                 │   │   │   └── templates/
                                                 │   │   │       ├── deployment.yaml
                                                 │   │   │       └── ...
                                                 │   │   └── prometheus-node-exporter/ ← DISABLED
                                                 │   └── values.yaml
                                                 │
                                                 └── prometheus-opencost-exporter-0.1.1.tgz
                                                     ├── templates/
                                                     │   ├── deployment.yaml      ← opencost pod
                                                     │   ├── service.yaml
                                                     │   ├── clusterrole.yaml
                                                     │   └── ...
                                                     └── values.yaml

                                                 Installed by: DEPLOYER JOB (install.sh)
                                                 Contains: full monitoring stack
```

---

## 9. Resource Allocation by Cluster Size

What `install.sh` sets for each cluster size tier. All values have `request == limit` (Guaranteed QoS).

```
 ┌─────────────────────────────────────────────────────────────────────────────────────────────────┐
 │                         RESOURCE ALLOCATION TABLE (from install.sh)                              │
 ├──────────────┬──────────────┬──────────────┬──────────────┬──────────────┬──────────────────────┤
 │  Component   │  <100 pods   │  100-499     │  500-999     │  1000-1499   │  1500+ pods          │
 │              │  (small)     │  (medium)    │  (large)     │  (xlarge)    │  (xxlarge)           │
 ├──────────────┼──────────────┼──────────────┼──────────────┼──────────────┼──────────────────────┤
 │              │              │              │              │              │                      │
 │  Prometheus  │  300m CPU    │  350m CPU    │  1000m CPU   │  1150m CPU   │  1500m CPU           │
 │  Server      │  1188Mi RAM  │  1771Mi RAM  │  3533Mi RAM  │  5400Mi RAM  │  7066Mi RAM          │
 │              │              │              │              │              │                      │
 ├──────────────┼──────────────┼──────────────┼──────────────┼──────────────┼──────────────────────┤
 │              │              │              │              │              │                      │
 │  OpenCost    │  200m CPU    │  200m CPU    │  250m CPU    │  250m CPU    │  300m CPU            │
 │              │  200Mi RAM   │  250Mi RAM   │  360Mi RAM   │  450Mi RAM   │  600Mi RAM           │
 │              │              │              │              │              │                      │
 ├──────────────┼──────────────┼──────────────┼──────────────┼──────────────┼──────────────────────┤
 │              │              │              │              │              │                      │
 │  OneLens     │  400m CPU    │  500m CPU    │  500m CPU    │  600m CPU    │  700m CPU            │
 │  Agent       │  400Mi RAM   │  500Mi RAM   │  500Mi RAM   │  600Mi RAM   │  700Mi RAM           │
 │              │              │              │              │              │                      │
 ├──────────────┼──────────────┼──────────────┼──────────────┼──────────────┼──────────────────────┤
 │              │              │              │              │              │                      │
 │  KSM         │  100m CPU    │  100m CPU    │  100m CPU    │  250m CPU    │  250m CPU            │
 │  ⚠ TOO LOW  │  100Mi RAM ⚠ │  100Mi RAM ⚠ │  100Mi RAM ⚠ │  400Mi RAM   │  400Mi RAM           │
 │              │              │              │              │              │                      │
 ├──────────────┼──────────────┼──────────────┼──────────────┼──────────────┼──────────────────────┤
 │              │              │              │              │              │                      │
 │  Pushgateway │  100m CPU    │  100m CPU    │  100m CPU    │  250m CPU    │  250m CPU            │
 │              │  100Mi RAM   │  100Mi RAM   │  100Mi RAM   │  400Mi RAM   │  400Mi RAM           │
 │              │              │              │              │              │                      │
 ├──────────────┼──────────────┼──────────────┼──────────────┼──────────────┼──────────────────────┤
 │              │              │              │              │              │                      │
 │  ConfigMap   │  100m CPU    │  100m CPU    │  100m CPU    │  100m CPU    │  100m CPU            │
 │  Reload      │  100Mi RAM   │  100Mi RAM   │  100Mi RAM   │  100Mi RAM   │  100Mi RAM           │
 │  (sidecar)   │              │              │              │              │                      │
 ├──────────────┼──────────────┼──────────────┼──────────────┼──────────────┼──────────────────────┤
 │              │              │              │              │              │                      │
 │  Prom Volume │  10Gi        │  20Gi        │  30Gi        │  40Gi        │  50Gi                │
 │  Retention   │  6GB / 10d   │  12GB / 10d  │  20GB / 10d  │  30GB / 10d  │  35GB / 10d          │
 │              │              │              │              │              │                      │
 └──────────────┴──────────────┴──────────────┴──────────────┴──────────────┴──────────────────────┘

 ⚠ = These values are too low when combined with metricLabelsAllowlist: [*]

 ┌─────────────────────────────────────────────────────────────────────────────────────────────────┐
 │                     patching.sh OVERRIDES (runs daily, IGNORES cluster size for some)            │
 ├──────────────┬──────────────────────────────────────────────────────────────────────────────────┤
 │  Prometheus  │  Sized correctly (same tiers as install.sh)                                      │
 │  OpenCost    │  Sized correctly (same tiers as install.sh)                                      │
 │  Agent       │  Sized correctly (same tiers as install.sh)                                      │
 │  KSM         │  ⚠ HARDCODED to 100m / 100Mi (ignores cluster size — regresses large clusters)  │
 │  Pushgateway │  ⚠ HARDCODED to 100m / 100Mi (ignores cluster size — regresses large clusters)  │
 │  ConfigReload│  HARDCODED to 100m / 100Mi (acceptable — lightweight process)                    │
 └──────────────┴──────────────────────────────────────────────────────────────────────────────────┘
```

---

## 10. File Map (What lives where)

```
 onelens-installation-scripts/
 │
 ├── install.sh                          ← MAIN INSTALLER (runs in Job pod)
 ├── patching.sh                         ← DAILY UPDATER (reference copy — real one served from API)
 ├── entrypoint.sh                       ← DOCKER ENTRYPOINT (routes job vs cronjob)
 ├── Dockerfile                          ← BUILDS onelens-deployer image (alpine + tools + scripts)
 ├── globalvalues.yaml                   ← HELM VALUES (baked into image, base config for monitoring stack)
 │
 ├── charts/
 │   ├── onelens-agent/                  ← UMBRELLA CHART (no templates, bundles sub-charts)
 │   │   ├── Chart.yaml                     chart metadata + 3 dependencies declared here
 │   │   ├── Chart.lock                     locked dependency versions
 │   │   ├── values.yaml                    default config for all sub-charts (1184 lines)
 │   │   ├── version.md                     version history / changelog
 │   │   ├── README.md                      chart documentation
 │   │   └── charts/                        packaged dependencies
 │   │       ├── onelens-agent-base-2.0.1.tgz    proprietary agent (from ECR OCI)
 │   │       ├── prometheus-27.3.0.tgz            community prometheus chart
 │   │       └── prometheus-opencost-exporter-0.1.1.tgz   community opencost chart
 │   │
 │   └── onelensdeployer/                ← DEPLOYER CHART (installed by customer)
 │       ├── Chart.yaml                     chart metadata (no dependencies)
 │       ├── values.yaml                    job + cronjob + RBAC config
 │       └── templates/
 │           ├── job.yaml                    one-time installer Job
 │           ├── cronjob.yaml                daily updater CronJob
 │           ├── sa.yaml                     2 ServiceAccounts (job + cronjob)
 │           ├── role.yaml                   namespace-scoped: full control of onelens-agent ns
 │           ├── rolebinding.yaml            binds both SAs to the Role
 │           ├── clusterole.yaml             cluster-scoped: minimal, scoped by resourceNames
 │           ├── clusterrolebinding.yaml     binds both SAs to the ClusterRole
 │           ├── bootstrap-clusterrole.yaml  temporary broad permissions (deleted after install)
 │           ├── bootstrap-clusterrolebinding.yaml   binds only Job SA to bootstrap role
 │           └── _helpers.tpl                template helper functions
 │
 ├── scripts/
 │   ├── prereq-check/                   ← PRE-INSTALL VALIDATOR (standalone, run by customer)
 │   ├── ebs-driver-installation/        ← AWS EBS CSI DRIVER INSTALLER (standalone)
 │   ├── azure-disk-driver-installation/ ← AZURE DISK CSI DRIVER INSTALLER (standalone)
 │   └── dedicated-node-installation/    ← NODE POOL CREATOR (AWS + Azure, standalone)
 │
 ├── docs/                               ← DOCUMENTATION
 │   ├── ci-cd-architecture.md
 │   ├── release-process.md
 │   ├── ci-cd-flow.md
 │   └── quick-reference.md
 │
 ├── .github/
 │   └── workflows/
 │       ├── build-onelens-deployer.yml  ← CI: build + scan + push Docker image to ECR
 │       └── helm-package-release.yml    ← CI: package + publish Helm charts to gh-pages
 │
 └── .gitignore                          ← ignores internalwiki/ folder
```
