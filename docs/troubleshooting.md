# Troubleshooting

## Common Issues

- [EBS CSI driver not found (AWS)](#ebs-csi-driver-not-found-aws) — storage provisioning fails because the CSI driver is missing
- [PVC stuck in Pending](#pvc-stuck-in-pending) — Prometheus can't start because its volume isn't provisioned
- [OpenCost in CrashLoopBackOff](#opencost-in-crashloopbackoff) — pod restarts while downloading cloud pricing data (usually self-resolves)
- [Prometheus OOMKilled or restarting](#prometheus-oomkilled-or-restarting) — Prometheus pod gets killed due to memory pressure
- [Helm upgrade ran but pods haven't changed](#helm-upgrade-ran-but-pods-havent-changed) — monitoring stack pods still on old version after deployer upgrade
- [Cloud provider auto-detection failed](#cloud-provider-auto-detection-failed) — deployer can't determine if the cluster is AWS or Azure
- [Pods stuck in Pending (scheduling issues)](#pods-stuck-in-pending-scheduling-issues) — pods can't be scheduled due to taints, resources, or node selectors
- [Registration failed](#registration-failed) — cluster registration with OneLens API returned an error

## Diagnostic Commands

- [Deployment status](#deployment-status) — check if all OneLens pods are running and which nodes they're on
- [Deployer logs](#deployer-logs) — view the install/upgrade job output to find errors
- [Storage diagnostics](#storage-diagnostics) — trace PVC, PV, StorageClass, and CSI driver status
- [Resource inspection](#resource-inspection) — check CPU/memory requests and limits on all components
- [Prometheus node and zone info](#prometheus-node-and-zone-info) — diagnose AZ mismatch between Prometheus pod and its volume
- [Describe Prometheus pod](#describe-prometheus-pod) — full pod details for crash loops, mount errors, or stuck containers

## Operations

- [Trigger a manual data collection](#trigger-a-manual-data-collection) — send data to OneLens immediately without waiting for the hourly schedule
- [Uninstallation](#uninstallation) — remove all OneLens components and clean up volumes

---

# Common Issues

Always start by checking the deployer logs:

```bash
kubectl get pods -n onelens-agent -o wide
kubectl logs -n onelens-agent -l batch.kubernetes.io/job-name=onelensdeployerjob -f
```

---

## EBS CSI driver not found (AWS)

**Symptom:** Deployer logs show `EBS CSI driver is not installed` or PVCs stuck in `Pending`.

The deployer attempts to install the EBS CSI driver automatically, but this can fail if your cluster lacks the required IAM permissions.

**Fix:** Install the EBS CSI driver manually before running the deployer:

```bash
# Option 1: Using the EKS add-on (recommended)
aws eks create-addon --cluster-name <cluster-name> --addon-name aws-ebs-csi-driver

# Option 2: Using Helm
helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver
helm install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver \
  --namespace kube-system
```

Ensure the EBS CSI driver's service account has the `AmazonEBSCSIDriverPolicy` IAM policy attached.

Verify the driver is running:

```bash
# Check for the CSIDriver object (works regardless of namespace)
kubectl get csidriver ebs.csi.aws.com

# Check controller pods (may be in kube-system or a custom namespace)
kubectl get pods --all-namespaces -l app=ebs-csi-controller
```

---

## PVC stuck in Pending

**Symptom:** `kubectl get pvc -n onelens-agent` shows PVCs in `Pending` state.

```bash
# Check PVC events for the root cause
kubectl describe pvc onelens-agent-prometheus-server -n onelens-agent
```

Common causes:
- **CSI driver not installed** — see [EBS CSI driver not found](#ebs-csi-driver-not-found-aws) above
- **StorageClass not created** — check if `onelens-sc` exists: `kubectl get storageclass | grep onelens-sc`
- **Insufficient disk quota** — AWS or Azure account limits on volume creation
- **Availability zone mismatch** — EBS and Azure Disk volumes are AZ-locked. If the node in the PV's AZ is gone, Prometheus can't start. See [Prometheus node and zone info](#prometheus-node-and-zone-info) to diagnose. **To prevent this:** reinstall with multi-AZ storage (EFS for AWS, Azure Files for Azure) — see [Multi-AZ Storage](../README.md#multi-az-storage).

---

## OpenCost in CrashLoopBackOff

**Symptom:** `onelens-agent-prometheus-opencost-*` pod keeps restarting.

This is usually **not an error**. On first startup, OpenCost downloads a large cloud pricing file (~100MB+ for AWS). The pod may restart 1-2 times before the download completes.

```bash
# Check if it's still downloading pricing data
kubectl logs -n onelens-agent -l app.kubernetes.io/name=prometheus-opencost-exporter
```

If the logs show pricing file download activity, wait 5-10 minutes. The pod will stabilize on its own.

---

## Prometheus OOMKilled or restarting

**Symptom:** Prometheus pod shows `OOMKilled` status or keeps restarting with memory-related errors.

No action needed. The deployer's healthcheck runs every 5 minutes and will detect the unhealthy pod automatically. It right-sizes Prometheus memory based on the actual workload density of your cluster — pod count, label cardinality, and historical usage patterns. The next healthcheck cycle will adjust the memory limits and restart the pod with appropriate resources.

OneLens intentionally avoids over-provisioning. Resource limits are continuously tuned to match your cluster's actual needs, so occasional OOMKills can happen when workload density changes suddenly (e.g., a large deployment rollout). The self-healing loop resolves this within minutes.

If the pod keeps getting OOMKilled across multiple cycles, contact [OneLens support](mailto:support@astuto.ai) with the output of:

```bash
kubectl describe pod -l app.kubernetes.io/name=prometheus -n onelens-agent
kubectl get deploy -n onelens-agent -o custom-columns='NAME:.metadata.name,MEM_LIM:.spec.template.spec.containers[*].resources.limits.memory'
```

---

## Helm upgrade ran but pods haven't changed

**Symptom:** `helm upgrade onelensdeployer` succeeded but the monitoring stack pods are still running the old version.

The upgrade command only updates the deployer. The monitoring stack (Prometheus, KSM, OpenCost, Agent) is upgraded automatically by the deployer's CronJob within 5-10 minutes.

If the pods still haven't updated after 10 minutes, trigger the upgrade manually:

```bash
kubectl create job --from=cronjob/onelensupdater manual-upgrade -n onelens-agent
kubectl logs -f job/manual-upgrade -n onelens-agent
```

To verify the upgrade completed:

```bash
helm list -n onelens-agent
```

---

## Cloud provider auto-detection failed

**Symptom:** Deployer logs show `Cloud provider auto-detection failed`.

OneLens currently supports **AWS EKS** and **Azure AKS** only. On-premises clusters, GKE, and other providers are not yet supported.

If you are on a supported provider and auto-detection still fails, the deployer may not be able to read node labels. Verify with:

```bash
kubectl get nodes -o jsonpath='{.items[0].spec.providerID}'
```

You can bypass auto-detection by setting the provider manually:

```bash
  --set job.env.CLOUD_PROVIDER_OVERRIDE=AWS   # or AZURE
```

---

## Pods stuck in Pending (scheduling issues)

**Symptom:** Agent pods (Prometheus, KSM, etc.) are in `Pending` state.

```bash
kubectl describe pod <pod-name> -n onelens-agent
```

Common causes:
- **Tainted nodes without tolerations** — if your nodes have taints, pass matching tolerations (see [Node Scheduling](../README.md#node-scheduling))
- **Insufficient CPU/memory** — the node doesn't have enough resources. Check `kubectl describe node <node>` under "Allocated resources"
- **NodeSelector mismatch** — the label specified in `NODE_SELECTOR_KEY`/`NODE_SELECTOR_VALUE` doesn't exist on any node
- **PV AZ mismatch** — Prometheus PV is in one AZ but no nodes are available there. Common on clusters with spot instances. Check with the [Prometheus node and zone info](#prometheus-node-and-zone-info) commands. To prevent: use multi-AZ storage — see [Multi-AZ Storage](../README.md#multi-az-storage)

---

## Registration failed

**Symptom:** Deployer logs show registration API errors or empty `REGISTRATION_ID`.

This happens when the cluster is already registered with OneLens. Re-running the install command on an already-connected cluster will fail because the registration API returns an empty response.

**To reinstall on an already-registered cluster:**

1. The cluster must first be marked as **Disconnected** in the OneLens platform
2. Currently, this can only be done by contacting [OneLens support](mailto:support@astuto.ai) — self-service disconnect from the OneLens console is coming soon
3. Once disconnected, re-run the helm install command with a new `REGISTRATION_TOKEN` from the console

**To verify:** Check the cluster's connection status in the OneLens console. If it shows as connected, it's already registered and cannot be re-registered until disconnected.

---

# Diagnostic Commands

## Deployment status

Check the health of all OneLens pods. Use `-o wide` to see which node each pod is running on — helpful when diagnosing node-specific issues.

```bash
# All pods in onelens-agent namespace
kubectl get pods -n onelens-agent -o wide

# Deployer pod only
kubectl get pods -n onelens-agent -o wide | grep onelensdeployer
```

## Deployer logs

The deployer job runs `install.sh` inside a pod. If installation failed or behaved unexpectedly, this is the first place to look. The `-f` flag streams logs in real-time if the pod is still running.

```bash
kubectl logs -n onelens-agent -l batch.kubernetes.io/job-name=onelensdeployerjob -f
```

## Storage diagnostics

Prometheus stores metrics on a PersistentVolume. If Prometheus is not starting or data is missing, check the PVC/PV chain to find where the problem is — the PVC may be unbound, the PV may be in the wrong AZ, or the CSI driver may be missing.

```bash
# PVC status — look for "Bound" state. "Pending" means storage is not provisioned.
kubectl get pvc -n onelens-agent

# PVC events — shows why provisioning failed (CSI driver errors, quota limits, etc.)
kubectl describe pvc onelens-agent-prometheus-server -n onelens-agent

# Find the underlying PV backing the Prometheus PVC
kubectl get pv --no-headers | grep 'onelens-agent/onelens-agent-prometheus-server'

# PV events — shows disk-level issues (attach failures, AZ mismatches)
kubectl describe pv $(kubectl get pv --no-headers | awk '$6=="onelens-agent/onelens-agent-prometheus-server" {print $1}')

# Verify the OneLens StorageClass exists
kubectl get storageclass | grep onelens-sc

# Verify EBS CSI driver pods are running (AWS only)
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver
```

## Resource inspection

If a pod is getting OOMKilled or throttled, check its current resource requests and limits. The daily updater sets these based on cluster size — this shows you what's actually configured.

```bash
# Requests and limits for all deployments (Prometheus, KSM, OpenCost, Pushgateway)
kubectl get deploy -n onelens-agent -o custom-columns='\
NAME:.metadata.name,\
CPU_REQ:.spec.template.spec.containers[*].resources.requests.cpu,\
CPU_LIM:.spec.template.spec.containers[*].resources.limits.cpu,\
MEM_REQ:.spec.template.spec.containers[*].resources.requests.memory,\
MEM_LIM:.spec.template.spec.containers[*].resources.limits.memory'

# Requests and limits for cronjobs (onelens-agent data collector)
kubectl get cronjob -n onelens-agent -o custom-columns='\
NAME:.metadata.name,\
CPU_REQ:.spec.jobTemplate.spec.template.spec.containers[*].resources.requests.cpu,\
CPU_LIM:.spec.jobTemplate.spec.template.spec.containers[*].resources.limits.cpu,\
MEM_REQ:.spec.jobTemplate.spec.template.spec.containers[*].resources.requests.memory,\
MEM_LIM:.spec.jobTemplate.spec.template.spec.containers[*].resources.limits.memory'
```

## Prometheus node and zone info

EBS and Azure Disk volumes are AZ-bound — a PV created in `us-east-1a` can only attach to a node in `us-east-1a`. If Prometheus gets rescheduled to a different AZ (e.g., after a node replacement), it can't mount its existing volume. Use these commands to check if there's a mismatch.

```bash
# Which node is Prometheus running on
kubectl get pod -l app.kubernetes.io/name=prometheus -n onelens-agent \
  -o jsonpath="{.items[0].spec.nodeName}"

# Which AZ is that node in
kubectl get pod -l app.kubernetes.io/name=prometheus -n onelens-agent \
  -o jsonpath="{.items[0].spec.nodeName}" | \
  xargs -I {} kubectl get node {} -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}'

# Which AZ is the PV provisioned in (should match the above)
kubectl get pv $(kubectl get pv --no-headers | awk '$6=="onelens-agent/onelens-agent-prometheus-server" {print $1}') \
  -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[?(@.key=="topology.kubernetes.io/zone")].values[0]}'
```

## Describe Prometheus pod

Shows the full pod spec, events, conditions, and mount status. Use this when Prometheus is in a crash loop, stuck in `ContainerCreating`, or showing mount errors.

```bash
kubectl describe pod $(kubectl get pods -l app.kubernetes.io/name=prometheus \
  -n onelens-agent -o jsonpath="{.items[0].metadata.name}") -n onelens-agent
```

---

# Operations

## Trigger a manual data collection

The onelens-agent runs as a CronJob (hourly by default). If you need data sent to OneLens immediately — for example, after initial installation or after fixing an issue — create a one-off job manually.

```bash
# Create a one-off job from the cronjob (timestamp ensures unique name)
kubectl create job onelens-agent-manual-$(date +%s) --from=cronjob/onelens-agent -n onelens-agent

# Watch the job pod start and complete
kubectl get pods -n onelens-agent --watch | grep manual

# View logs (replace <job-name> with the name from above)
kubectl logs -l batch.kubernetes.io/job-name=<job-name> -n onelens-agent -f
```

## Uninstallation

Removes all OneLens components from the cluster. The two Helm releases must be uninstalled. PVCs are retained by default to protect Prometheus data — delete them explicitly if you want a clean removal.

```bash
# Uninstall both charts at once
helm uninstall -n onelens-agent onelens-agent onelensdeployer

# Or individually:
# helm uninstall onelensdeployer -n onelens-agent
# helm uninstall onelens-agent -n onelens-agent

# Delete PVC (removes Prometheus stored metrics data)
kubectl delete pvc onelens-agent-prometheus-server -n onelens-agent

# Delete the associated PV (the underlying cloud disk)
kubectl get pv --no-headers | grep 'onelens-agent/onelens-agent-prometheus-server' | \
  awk '{print $1}' | xargs -r kubectl delete pv

# Delete the namespace entirely
kubectl delete namespace onelens-agent
```
