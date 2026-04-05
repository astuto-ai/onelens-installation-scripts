# OOM (Out of Memory) Kill Issues — Root Cause Analysis

## What is an OOM kill?

When a container runs inside Kubernetes, you set a "memory limit" — the maximum amount of RAM it's allowed to use. If the process inside the container tries to use more memory than that limit, the Linux kernel immediately kills it. This is called an OOM kill (Out Of Memory kill).

When this happens, you'll see the pod status change to `OOMKilled` in `kubectl get pods`. Kubernetes may or may not restart the pod depending on the restart policy.

OOM kills are bad for us because:
- If **Prometheus** gets OOM-killed, we lose in-flight metrics and the scrape cycle breaks. It restarts but loses its in-memory data.
- If **kube-state-metrics** gets OOM-killed, Prometheus can't scrape Kubernetes object state, so we get gaps in our data.
- If **OpenCost** gets OOM-killed, cost calculations stop until it comes back.
- If **onelens-agent** gets OOM-killed, the hourly data upload to OneLens cloud fails for that cycle.
- Customer trust erodes when they see our pods constantly crashing in their cluster.

### Quick reference: which pods can OOM and where they come from

All the pods below run in the `onelens-agent` namespace. They come from two Helm releases:

| Pod | Helm Release | Controller Type | ServiceAccount | OOM Risk |
|---|---|---|---|---|
| **prometheus-server** | `onelens-agent` | Deployment (always running) | `onelens-agent-prometheus-server` | HIGH — TSDB head block + compaction spikes |
| **kube-state-metrics** | `onelens-agent` | Deployment (always running) | `onelens-agent-kube-state-metrics` | CRITICAL — `[*]` labels + 100Mi limit |
| **opencost** | `onelens-agent` | Deployment (always running) | `onelens-agent-prometheus-opencost-exporter` | MEDIUM — cost model computation spikes |
| **prometheus-pushgateway** | `onelens-agent` | Deployment (always running) | (shared with prometheus) | LOW — lightweight workload |
| **configmap-reload** | `onelens-agent` | Sidecar in Prometheus pod | (shared with prometheus) | LOW — tiny process |
| **onelens-agent** | `onelens-agent` | CronJob (hourly) | `onelens-agent-workload-reader` | LOW-MEDIUM — depends on query data volume |
| **onelensupdater** | `onelensdeployer` | CronJob (daily 2AM) | `onelensupdater-sa` | LOW — short-lived, runs helm upgrade |
| **onelensdeployerjob** | `onelensdeployer` | Job (one-time, deletes itself) | `onelensdeployerjob-sa` | LOW — short-lived, runs install.sh |

The deployer pods (`onelensupdater`, `onelensdeployerjob`) are short-lived and rarely OOM. The monitoring stack pods (Prometheus, KSM, OpenCost) are the ones that OOM because they hold large amounts of data in memory continuously. The resource limits for monitoring pods are set by `install.sh` initially, then updated by `patching.sh` daily — see Issue #2 for how patching can regress the limits.

---

## Issue #1 (CRITICAL): kube-state-metrics has `metricLabelsAllowlist: [*]` but only 100Mi memory

### Where is this configured?

The `metricLabelsAllowlist` is set in two places (both identical):

- `charts/onelens-agent/values.yaml` lines 323-336 (the chart defaults)
- `globalvalues.yaml` lines 840-855 (the file baked into the Docker image)

```yaml
metricLabelsAllowlist:
  - namespaces=[*]
  - pods=[*]
  - deployments=[*]
  - replicasets=[*]
  - daemonsets=[*]
  - statefulsets=[*]
  - cronjobs=[*]
  - jobs=[*]
  - horizontalpodautoscalers=[*]
  - limitranges=[*]
  - persistentvolumeclaims=[*]
  - storageclasses=[*]
  - nodes=[*]
  - resourcequotas=[*]
  - persistentvolumes=[*]
```

The memory limit is set in `globalvalues.yaml` lines 873-879:
```yaml
resources:
  requests:
    cpu: 100m
    memory: 100Mi
  limits:
    cpu: 100m
    memory: 100Mi
```

### What does `metricLabelsAllowlist: [*]` actually mean?

To understand this, you need to know what kube-state-metrics (KSM) does.

KSM watches the Kubernetes API and converts Kubernetes objects into Prometheus metrics. For example, for a pod, it creates metrics like:

```
kube_pod_info{namespace="default", pod="my-app-abc123", node="ip-10-0-1-5"} 1
kube_pod_status_phase{namespace="default", pod="my-app-abc123", phase="Running"} 1
```

By default, KSM only includes a small set of **built-in labels** in these metrics (like `namespace`, `pod`, `node`). But when you set `metricLabelsAllowlist: pods=[*]`, you're telling KSM: "For every pod metric, also include **every single Kubernetes label** that the pod has as a Prometheus metric label."

So if a customer has a pod with these Kubernetes labels:
```yaml
labels:
  app: my-app
  version: v2.3.1
  team: backend
  environment: production
  release: stable
  chart: my-app-1.0.0
  heritage: Helm
  managed-by: helm
  cost-center: engineering
  owner: john@company.com
```

Then instead of a simple metric like:
```
kube_pod_info{namespace="default", pod="my-app-abc123"} 1
```

KSM produces:
```
kube_pod_info{namespace="default", pod="my-app-abc123", label_app="my-app", label_version="v2.3.1", label_team="backend", label_environment="production", label_release="stable", label_chart="my-app-1.0.0", label_heritage="Helm", label_managed_by="helm", label_cost_center="engineering", label_owner="john@company.com"} 1
```

### Why does this cause OOM?

A common misconception: `[*]` does NOT multiply the number of time series by the number of labels. The number of time series stays roughly the same — for 400 pods with ~20 KSM metrics per pod, that's still ~8,000 time series from pods. What `[*]` does is make **each time series much wider** — every series now carries 10-15 extra label name/value pairs that it wouldn't have otherwise.

This blows up memory in two ways:

**1. Larger per-series memory footprint:**
Without `[*]`, a KSM time series looks like:
```
kube_pod_info{namespace="default", pod="my-app-abc123"} 1
```
~50 bytes of label data.

With `[*]`, the same series becomes:
```
kube_pod_info{namespace="default", pod="my-app-abc123", label_app="my-app", label_version="v2.3.1", label_team="backend", label_environment="production", label_release="stable", label_chart="my-app-1.0.0", label_heritage="Helm", label_managed_by="helm", label_cost_center="engineering", label_owner="john@company.com"} 1
```
~400+ bytes of label data. That's an 8x increase per series.

Across 15 resource types and thousands of objects, this adds up fast. For a cluster with ~8,000 pod time series + ~5,000 deployment/replicaset/etc series = ~13,000 total KSM series, each carrying ~400 extra bytes of labels, that's ~5MB just for the extra label data. But Go structs, string interning, hash maps, and internal bookkeeping multiply this significantly — real overhead is often 10-20x the raw label bytes.

**2. Much larger HTTP scrape responses:**
When Prometheus scrapes KSM every 30 seconds, the response body is the full text dump of all metrics. With `[*]`, this response can be **5-10x larger** (from ~500KB to 3-5MB+ for a medium cluster). KSM has to hold this entire response in memory while it's being served. Prometheus has to allocate buffers to parse it. Both sides spike in memory during each scrape.

### What does a customer cluster look like?

Let's take a concrete example. A customer with 400 pods across 50 namespaces:

- Most enterprise clusters use Helm, ArgoCD, or other tools that add 5-10 labels per object automatically
- Teams add their own labels (team, cost-center, environment, version, etc.)
- So ~10-15 labels per object is very common

That means KSM is tracking:
- ~400 pods × ~20 KSM metrics per pod = ~8,000 time series from pods
- Plus deployments, replicasets, daemonsets, nodes, etc. — easily another ~5,000-10,000 series
- Total: **~15,000-20,000 time series**, but each one is **5-10x wider** than it would be without `[*]`
- The scrape response alone can be 3-5MB of text, generated and parsed every 30 seconds

KSM has to hold all these wide series in memory, serve them as large HTTP responses, and handle Go GC overhead on top. 100Mi is nowhere near enough for this workload.

**100Mi is simply not enough.**

### Where is the 100Mi limit set?

It comes from multiple places:

1. **`globalvalues.yaml` lines 873-879** — hardcodes `100Mi` as the default in the values file
2. **`install.sh` lines 297-300** — for clusters <1000 pods, KSM is set to `100Mi`. Only clusters with 1000+ pods get `400Mi`
3. **`patching.sh` lines 166-170** — hardcodes `100Mi` regardless of cluster size (see Issue #2 below)

### What happens when KSM gets OOM-killed?

1. KSM pod gets killed by the kernel
2. Kubernetes restarts it (deployment has a restart policy)
3. KSM starts up again, re-lists all Kubernetes objects from the API
4. Memory climbs back up as it rebuilds its in-memory state
5. OOM-killed again
6. This cycle repeats — the pod is in a **CrashLoopBackOff**

During this entire cycle:
- Prometheus scrapes to KSM fail (connection refused or empty response)
- All KSM-sourced metrics have gaps
- OneLens loses visibility into Kubernetes object state for that period
- The customer sees flapping pods in their cluster, which is alarming

### Proposed solution

Since `[*]` labels are a **product requirement** (we need all Kubernetes labels for cost attribution and resource grouping), we cannot remove them. Instead, we need to give KSM enough memory to handle the workload that `[*]` creates.

**What to change:** Increase KSM memory limits in `install.sh`, `patching.sh`, and `globalvalues.yaml` to match the actual workload.

**Proposed memory tiers for KSM (compared to current):**

| Cluster Size | Current KSM Memory (request=limit) | Proposed KSM (request=limit) | Why this amount |
|---|---|---|---|
| <100 pods | 100Mi | 350Mi | Even small clusters with `[*]` and 10-15 labels/object need ~200Mi steady-state. 350Mi covers steady-state + GC spikes (~1.5x). |
| 100-499 pods | 100Mi | 700Mi | 400 pods × 15 resource types × wide labels = large in-memory representation. Scrape response is 2-4MB of text. Steady-state ~450Mi, peak ~650Mi. |
| 500-999 pods | 100Mi | 1024Mi | Scrape responses grow to 5-8MB. Go's internal data structures (hash maps, string interning) multiply raw label size by 10-20x. |
| 1000-1499 pods | 400Mi | 1536Mi | Current 400Mi was already too low — barely above the steady-state usage, no room for GC or scrape spikes. |
| 1500+ pods | 400Mi | 2048Mi | Very large clusters with `[*]` across 15 resource types create massive KSM state. |

**Why request=limit (Guaranteed QoS) must be preserved:** See Issue #4 for the full explanation. Short version: our pods run on the same nodes as customer production workloads. If we used Burstable QoS (limit > request), our pod's memory spike could consume unreserved node memory and cause the Linux OOM killer to kill customer production pods — or crash the entire node. This has been observed in production. Guaranteed QoS ensures that worst case, only our pod dies, never the customer's.

**Since we can't use Burstable QoS for burst headroom, the proposed values already include GC spike headroom.** Each value is approximately 1.5x the estimated steady-state usage. The trade-off is that we reserve more memory on the customer's nodes, but this prevents both OOM kills AND production impact.

**Files to change:**
- `globalvalues.yaml` lines 873-879 — update default KSM resources from `100Mi` to `256Mi/384Mi`
- `install.sh` — update KSM memory values in every cluster-size tier
- `patching.sh` — update KSM memory values (and move them inside the cluster-size if/else block — see Issue #2)

**Impact of this change:** KSM pods will consume more memory on the customer's nodes. For a small cluster, this adds ~150-280Mi of node memory usage. For large clusters, ~600-1900Mi more. This is a trade-off: slightly higher baseline resource consumption vs. eliminating OOM kills and data gaps. Given that customers are already paying for nodes that can run their workloads, an extra 256-1536Mi for reliable monitoring is almost always acceptable.

**Risk:** Low. We are only increasing memory limits, not changing any functional behavior. If we overshoot, the pod simply uses less than its limit. If we undershoot, we'll still see OOM kills and can increase further.

---

## Issue #2 (CRITICAL): `patching.sh` resets KSM memory to 100Mi regardless of cluster size

### Where is the problem?

`patching.sh` lines 156-170:

```bash
## Other component resources
PROMETHEUS_CONFIGMAP_RELOAD_MEMORY_LIMIT="100Mi"
PROMETHEUS_CONFIGMAP_RELOAD_MEMORY_REQUEST="100Mi"
PROMETHEUS_CONFIGMAP_RELOAD_CPU_LIMIT="100m"
PROMETHEUS_CONFIGMAP_RELOAD_CPU_REQUEST="100m"

PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT="100Mi"
PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST="100Mi"
PROMETHEUS_PUSHGATEWAY_CPU_LIMIT="100m"
PROMETHEUS_PUSHGATEWAY_CPU_REQUEST="100m"

KSM_MEMORY_LIMIT="100Mi"
KSM_MEMORY_REQUEST="100Mi"
KSM_CPU_LIMIT="100m"
KSM_CPU_REQUEST="100m"
```

Notice how these values are **defined outside** the cluster-size if/else block (lines 55-154). The if/else block above them only sizes Prometheus, OpenCost, and the OneLens Agent. KSM, Pushgateway, and ConfigMap Reload are hardcoded below it — they always get 100Mi no matter how big the cluster is.

### Why is this especially bad?

Compare this to `install.sh`, which **does** scale KSM with cluster size:

```bash
# install.sh — for 1000-1499 pods:
KSM_CPU_REQUEST="250m"
KSM_MEMORY_REQUEST="400Mi"
KSM_CPU_LIMIT="250m"
KSM_MEMORY_LIMIT="400Mi"
```

So here's the timeline of what happens to a customer with a large cluster (say, 1200 pods):

1. **Day 0 — Installation:** `install.sh` runs. It counts 1200 pods, enters the "1000-1499 pods" bracket, and sets KSM memory to **400Mi**. Everything works fine.

2. **Day 1 — 2 AM UTC:** The `onelensupdater` CronJob runs. `entrypoint.sh` fetches `patching.sh` from the API. `patching.sh` runs `helm upgrade ... --reuse-values --set prometheus.kube-state-metrics.resources.limits.memory="100Mi"`. The `--set` flag overrides the previously-set 400Mi. KSM is now limited to **100Mi**.

3. **Day 1 — minutes later:** KSM gets **OOM-killed** because 100Mi is nowhere near enough for a 1200-pod cluster with `[*]` labels.

4. **Day 1 onward:** KSM is stuck in CrashLoopBackOff. Every subsequent patching run keeps it at 100Mi. The customer sees broken pods indefinitely.

This means **every cluster with 1000+ pods will start failing within 24 hours of installation**, even though `install.sh` correctly sized the resources.

### How does the `--reuse-values` + `--set` interaction work?

This is a Helm concept that's important to understand:

- `--reuse-values` tells Helm: "Start with all the values from the last release (whatever was set during install or the last upgrade). Don't reset anything to chart defaults."
- `--set key=value` tells Helm: "Override this specific key with this new value."

When you combine them, Helm takes all the old values and then applies the `--set` overrides on top. So if the old value for KSM memory was 400Mi (from install.sh), and patching.sh does `--set prometheus.kube-state-metrics.resources.limits.memory="100Mi"`, the new value becomes 100Mi.

The `--reuse-values` flag preserves everything that `--set` doesn't explicitly touch. But anything that `--set` does touch gets overwritten.

### Proposed solution

**What to change:** Move the KSM, Pushgateway, and ConfigMap Reload resource variables **inside** the cluster-size if/else block in `patching.sh`, so they scale with cluster size — exactly like they do in `install.sh`.

**What the fix looks like (conceptually):**

Current `patching.sh` structure (broken):
```bash
# Lines 55-154: the cluster-size if/else block
if [ "$TOTAL_PODS" -lt 100 ]; then
    PROMETHEUS_MEMORY_LIMIT="1188Mi"    # ← sized per cluster
    OPENCOST_MEMORY_LIMIT="200Mi"       # ← sized per cluster
    ONELENS_MEMORY_LIMIT="400Mi"        # ← sized per cluster
    # KSM is NOT here — it's missing from every tier!
elif [ "$TOTAL_PODS" -lt 500 ]; then
    ...
fi

# Lines 156-170: OUTSIDE the if/else block — always runs
KSM_MEMORY_LIMIT="100Mi"               # ← hardcoded, ignores cluster size!
KSM_MEMORY_REQUEST="100Mi"
PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT="100Mi"
PROMETHEUS_CONFIGMAP_RELOAD_MEMORY_LIMIT="100Mi"
```

Fixed structure:
```bash
if [ "$TOTAL_PODS" -lt 100 ]; then
    PROMETHEUS_MEMORY_LIMIT="1188Mi"
    OPENCOST_MEMORY_LIMIT="200Mi"
    ONELENS_MEMORY_LIMIT="400Mi"
    KSM_MEMORY_REQUEST="256Mi"          # ← NOW inside the block
    KSM_MEMORY_LIMIT="384Mi"            # ← NOW inside the block, and scaled
    PROMETHEUS_PUSHGATEWAY_MEMORY_REQUEST="100Mi"
    PROMETHEUS_PUSHGATEWAY_MEMORY_LIMIT="150Mi"
    PROMETHEUS_CONFIGMAP_RELOAD_MEMORY_REQUEST="100Mi"
    PROMETHEUS_CONFIGMAP_RELOAD_MEMORY_LIMIT="150Mi"
elif [ "$TOTAL_PODS" -lt 500 ]; then
    ...
    KSM_MEMORY_REQUEST="512Mi"          # ← different value per tier
    KSM_MEMORY_LIMIT="768Mi"
    ...
fi
# Nothing hardcoded outside the block anymore
```

**Why this fixes the problem:** After this change, when the daily `onelensupdater` CronJob runs `patching.sh`, the `--set` flags for KSM memory will reflect the actual cluster size, not a hardcoded 100Mi. A 1200-pod cluster will get 1024Mi/1536Mi for KSM instead of 100Mi.

**Files to change:**
- `patching.sh` — restructure the resource allocation section

**Impact of this change:** Clusters that were regressing to 100Mi KSM after the first patching run will now maintain correctly-sized KSM memory. No functional behavior changes — only resource limits are affected.

**Risk:** Low. The only risk is if the `patching.sh` in this repo is a reference copy and the actual script served by the API is different (see Open Question #4). If the API serves a different version, this fix won't help until the API version is also updated.

---

## Issue #3 (HIGH): Prometheus server absorbs the cardinality explosion from KSM

### What is cardinality?

In Prometheus, "cardinality" means the total number of unique time series being tracked. Each unique combination of metric name + label names + label values is one time series. High cardinality = lots of unique time series = more memory.

### How does KSM's `[*]` affect Prometheus?

The `[*]` label wildcard doesn't just affect KSM's memory — it also floods Prometheus with high-cardinality data. When Prometheus scrapes KSM every 30 seconds, it receives all those hundreds of thousands of time series and has to:

1. **Parse** each time series from the scrape response (CPU + memory)
2. **Store** each time series in the TSDB head block (memory — this is the in-memory portion of the database)
3. **Index** each unique label combination for fast lookups (memory)
4. **Write** to the WAL (Write-Ahead Log) for crash recovery (disk I/O + memory)
5. **Compact** old data periodically (CPU + memory spikes during compaction)

### What are the current Prometheus memory limits?

Set dynamically by `install.sh` based on cluster size:

| Cluster Size | Prometheus Memory Limit |
|---|---|
| <100 pods | 1188Mi |
| 100-499 pods | 1771Mi |
| 500-999 pods | 3533Mi |
| 1000-1499 pods | 5400Mi |
| 1500+ pods | 7066Mi |

### Why might these limits be insufficient?

These limits were probably calculated assuming a "normal" Prometheus workload — a reasonable number of time series from standard scrape targets. But the `metricLabelsAllowlist: [*]` setting on KSM can multiply the expected time series count by 5-10x or more.

For example, for a 300-pod cluster (memory limit: 1771Mi):
- Without `[*]`: KSM produces maybe ~30,000 time series. Prometheus handles this easily.
- With `[*]` and 10 labels per object: KSM produces ~200,000+ time series. Prometheus needs significantly more memory for the head block and index.

Add in the other scrape targets (cAdvisor from every node, API server metrics, custom metrics) and the total cardinality can easily push Prometheus past its memory limit.

### When does the OOM happen?

Prometheus OOM kills typically happen during one of these events:

1. **TSDB compaction**: Prometheus periodically compacts the head block into on-disk blocks. During compaction, it temporarily needs extra memory to read old data and write new blocks. This is a memory spike that can push it over the limit.

2. **High scrape load**: If many targets respond simultaneously with large payloads (KSM with `[*]` produces very large scrape responses), the parsing buffers consume significant memory.

3. **Query load**: When the OneLens agent or OpenCost queries Prometheus, it has to load and process time series data. Large queries against high-cardinality data use more memory.

4. **Restart recovery**: When Prometheus restarts, it replays the WAL (Write-Ahead Log) to recover its state. This can be very memory-intensive, especially with high cardinality.

### Proposed solution

Since `[*]` labels are a product requirement, we can't reduce cardinality at the source. Instead, we need to give Prometheus enough memory to handle the `[*]`-inflated data volume, including peak usage during compaction and GC.

**What to change:** Increase both Prometheus request AND limit (keeping them equal — Guaranteed QoS, see Issue #4 for why) in `install.sh` and `patching.sh`.

**Proposed Prometheus memory tiers:**

| Cluster Size | Current Request=Limit | Proposed Request=Limit | Why |
|---|---|---|---|
| <100 pods | 1188Mi | 1700Mi | Steady-state ~1100Mi is fine, but TSDB compaction spikes to ~1.4x. Need 1700Mi to survive compaction without OOM. |
| 100-499 pods | 1771Mi | 2500Mi | With `[*]` KSM cardinality, head block is larger. Compaction + WAL replay peak at ~2300Mi. |
| 500-999 pods | 3533Mi | 5000Mi | Large clusters: KSM produces 5-8MB scrape responses, TSDB head block holds 200k+ series. Compaction peak ~4500Mi. |
| 1000-1499 pods | 5400Mi | 7500Mi | KSM alone produces 8-10MB scrape responses. WAL replay after restart is very memory-intensive. |
| 1500+ pods | 7066Mi | 10000Mi | Very large clusters. Consider whether nodes can fit this — may need dedicated node placement (see `scripts/dedicated-node-installation/`). |

**Why these specific numbers?** Each proposed value is approximately 1.4-1.5x the current value. The current values were already calculated based on cluster size, but they assumed normal cardinality without `[*]` labels. The `[*]` setting increases the head block size, WAL size, and compaction memory requirements. The 1.4-1.5x multiplier accounts for both the `[*]` cardinality increase AND the GC/compaction spike headroom.

**Files to change:**
- `install.sh` — update both `PROMETHEUS_MEMORY_REQUEST` and `PROMETHEUS_MEMORY_LIMIT` in every tier (keeping them equal)
- `patching.sh` — same

**Impact of this change:** More memory is reserved on the customer's node for Prometheus. For a small cluster, +512Mi. For the largest clusters, +2934Mi. This is significant — Prometheus is the largest consumer of memory in the stack. If a customer's nodes are already tight, the scheduler may not find a node with enough room. In that case, recommend dedicated node placement.

**Risk:** Medium. The increased reservation affects scheduling. But the alternative — Prometheus OOM during compaction, losing all in-memory data, then needing even MORE memory to replay the WAL during recovery — is worse both for stability and for memory consumption (WAL replay can spike higher than normal operation).

---

## Issue #4 (CONTEXT): Why `requests == limits` (Guaranteed QoS) is intentional — and how to work within that constraint

### Where is this set?

Every single component in the system has its memory request set exactly equal to its memory limit. For example:

`globalvalues.yaml` — KSM (lines 873-879):
```yaml
resources:
  requests:
    cpu: 100m
    memory: 100Mi
  limits:
    cpu: 100m
    memory: 100Mi
```

`install.sh` — for every cluster size bracket, requests always equal limits:
```bash
PROMETHEUS_MEMORY_REQUEST="1188Mi"
PROMETHEUS_MEMORY_LIMIT="1188Mi"
```

Same pattern in `patching.sh`.

### What does this mean technically?

In Kubernetes, every pod gets assigned a QoS (Quality of Service) class based on how its requests and limits are configured:

1. **Guaranteed** — requests == limits for both CPU and memory. The pod gets exactly what it asked for, no more, no less.
2. **Burstable** — requests < limits. The pod is guaranteed its request amount but can use more (up to the limit) if the node has spare capacity.
3. **BestEffort** — no requests or limits set. The pod gets whatever is left over.

When requests == limits, all our pods get **Guaranteed QoS**.

### Why Guaranteed QoS is the CORRECT choice for this project

**This is an intentional, critical design decision — not a mistake.**

OneLens monitoring pods run on the **same nodes as customer production workloads**. These are real production clusters running business-critical applications. Here's why Guaranteed QoS is mandatory:

**The danger of Burstable QoS (request < limit) on shared production nodes:**

1. The Kubernetes scheduler only looks at `request` when deciding where to place a pod. It does NOT consider `limit`.
2. If our pod has request=256Mi and limit=384Mi, the scheduler reserves 256Mi on the node. The remaining 128Mi (the gap between request and limit) is **unreserved** — the scheduler may promise that same memory to other pods.
3. If our pod spikes to 384Mi AND other pods on the same node are also using their reserved memory, the total memory demand exceeds what the node physically has.
4. The Linux kernel's **OOM killer** activates. It looks at all processes on the node and picks one to kill. It does NOT respect Kubernetes pod boundaries or priorities in a predictable way. **It might kill a customer's production pod instead of ours.**
5. In the worst case, the entire node crashes, taking down ALL pods running on it — including the customer's production workloads.

**This has actually been observed in production.** Nodes have crashed completely due to memory overcommitment, causing customer production workloads to go down. For an observability tool, this is completely unacceptable. An observability tool should NEVER cause production outages.

**Why Guaranteed QoS prevents this:**

With request == limit (e.g., 256Mi for both), Kubernetes does two things:
1. **Scheduling:** Reserves exactly 256Mi on the node. This memory is exclusively for our pod — no other pod can be promised this memory.
2. **Runtime:** If our pod tries to use more than 256Mi, the kernel kills **only our pod**. Our pod dies, but no other pod on the node is affected. The customer's production workloads keep running.

**In plain English:** We'd rather our monitoring pod crashes (and Kubernetes restarts it) than risk crashing a customer's production application. Guaranteed QoS ensures that in the worst case, only our pod suffers.

### The trade-off: how this interacts with Go's garbage collector

The downside of Guaranteed QoS is that there's zero headroom for temporary memory spikes. All our monitoring components (Prometheus, KSM, OpenCost, Pushgateway) are written in Go. Go has a garbage collector (GC) that periodically scans memory and frees unused objects. During this process:

1. The GC needs to keep both "live" objects AND "dead" objects in memory simultaneously (until scanning finishes)
2. Memory usage spikes above the steady-state level — typically by 1.3-1.5x
3. The spike is brief (milliseconds to seconds), then memory drops back down

With Guaranteed QoS, if the request=limit is set to the steady-state usage, the GC spike exceeds the limit and the pod gets OOM-killed.

```
Memory
               ┌── GC spike hits the limit → OOM killed
               ▼
150Mi ─ ─ ─ ─ ╱╲─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ (needed for peak = steady × 1.5)
             ╱    ╲
100Mi ──────╱──────╲──── LIMIT = REQUEST (current, too low)
      │    ╱        ╲        ╱╲     ╱╲
 80Mi │  ╱            ╲    ╱    ╲ ╱    ╲
      │╱                ╲╱                ╲
 60Mi │  ← steady state                    ╲
      │
      └──────────────────────────────────────── Time
```

**The solution is NOT to switch to Burstable QoS.** The solution is to **set request=limit high enough to cover peak usage (steady-state + GC spikes)**.

### How this affects all other solutions in this document

**CONSTRAINT: All proposed memory values in this document must keep request == limit (Guaranteed QoS).** The proposed values must account for peak usage, not just steady-state usage.

The formula becomes:
```
MEMORY_REQUEST = MEMORY_LIMIT = estimated_steady_state × 1.5
```

Where the 1.5x multiplier covers GC spikes, compaction, and temporary scrape buffer allocations. The trade-off is that we reserve more memory on the customer's node (since request determines scheduling), but this is necessary to prevent both OOM kills AND production impact.

### Current resource table for all components

| Component | Memory Request | Memory Limit | QoS Class | Problem? |
|---|---|---|---|---|
| KSM | 100Mi | 100Mi | Guaranteed | Yes — 100Mi is far below even steady-state for `[*]` workload |
| Pushgateway | 100Mi | 100Mi | Guaranteed | Minor — 100Mi is usually fine for pushgateway |
| ConfigMap Reload | 100Mi | 100Mi | Guaranteed | Minor — very lightweight process |
| OpenCost (<100 pods) | 200Mi | 200Mi | Guaranteed | Yes — query spikes can exceed this |
| OneLens Agent (<100 pods) | 400Mi | 400Mi | Guaranteed | Moderate — depends on data volume |
| Prometheus (<100 pods) | 1188Mi | 1188Mi | Guaranteed | Yes — compaction spikes can exceed this |

### Proposed solution

**What to change:** Increase **both** request AND limit **together** (keeping them equal) to values that account for peak memory usage including GC spikes, compaction, and scrape buffer allocations.

**The approach:**
1. Estimate the steady-state memory usage for each component (based on `[*]` labels, cluster size, scrape frequency)
2. Multiply by 1.5 to account for Go GC spikes and transient peaks
3. Set request = limit = that value (preserving Guaranteed QoS)

**Proposed resource table (for <100 pods tier as an example):**

| Component | Current Request=Limit | Proposed Request=Limit | QoS | Why this value |
|---|---|---|---|---|
| KSM | 100Mi | 350Mi | Guaranteed | Steady-state ~200Mi with `[*]`, peak ~300Mi during GC + scrape serve |
| Pushgateway | 100Mi | 128Mi | Guaranteed | Lightweight workload, small headroom for GC |
| ConfigMap Reload | 100Mi | 100Mi | Guaranteed | Tiny process, 100Mi is already generous |
| OpenCost | 200Mi | 350Mi | Guaranteed | Cost model loading + PromQL results, peak ~280Mi during startup |
| OneLens Agent | 400Mi | 512Mi | Guaranteed | Depends on query data volume, 400Mi was borderline |
| Prometheus | 1188Mi | 1700Mi | Guaranteed | TSDB head block + compaction peaks, need ~1.4x headroom |

The full tier-specific tables are in the "Complete proposed resource allocation table" at the end of this document.

**Files to change:**
- `install.sh` — increase all `*_MEMORY_REQUEST` and `*_MEMORY_LIMIT` values (keeping them equal)
- `patching.sh` — same
- `globalvalues.yaml` — update default resource blocks

**Impact of this change:** More memory is **reserved** on customer nodes (since request = limit and request determines scheduling). For a small cluster, total reserved memory increases from ~2088Mi to ~3140Mi — about 1Gi more. For large clusters, the increase is larger. This means customer nodes need more free memory to schedule our pods. If a customer's nodes are already very full, the scheduler might not find a node with enough room, and our pods would stay in `Pending` state.

**Mitigation for tight nodes:** The OneLens Helm charts support `nodeSelector` and `tolerations`. If a customer's production nodes are too tight, they can use a dedicated node (or node pool) for OneLens pods with enough memory. Scripts for creating dedicated nodes already exist in `scripts/dedicated-node-installation/`.

**Risk:** Medium. The risk is not functional — it's about scheduling. Larger requests mean the Kubernetes scheduler needs more free memory on a node to place our pods. But the alternative (OOM kills that crash our pods, lose data, and alarm customers) is worse. And this approach is safer than Burstable QoS, which could impact customer production workloads.

---

## Issue #5 (MEDIUM): OpenCost memory limits are too aggressive for medium clusters

### Where is this configured?

The default in `charts/onelens-agent/values.yaml` lines 367-373 gives OpenCost a generous limit:
```yaml
resources:
  requests:
    cpu: '10m'
    memory: '55Mi'
  limits:
    cpu: '999m'
    memory: '1Gi'
```

But `install.sh` overrides this based on cluster size:

| Cluster Size | OpenCost Memory Limit |
|---|---|
| <100 pods | 200Mi |
| 100-499 pods | 250Mi |
| 500-999 pods | 360Mi |
| 1000-1499 pods | 450Mi |
| 1500+ pods | 600Mi |

### Why is this a problem?

OpenCost works by querying Prometheus via PromQL to calculate costs. It runs queries like "give me the CPU usage for every pod in every namespace over the last hour" and then multiplies by pricing data.

For a cluster with 300 pods (memory limit: 250Mi):
- OpenCost fetches time series data from Prometheus for all pods
- It holds this data in memory while computing the cost model
- The result set for 300 pods across multiple metrics can easily be 100-200MB
- Add Go GC overhead and HTTP response buffers, and 250Mi becomes tight

The problem is worst during:
1. **Initial startup** — OpenCost loads the full cost model for the cluster. This is the most memory-intensive operation.
2. **Large query responses** — when Prometheus returns a lot of data for cost computation.
3. **Multiple concurrent queries** — if the OneLens agent and OpenCost's internal reconciliation both query at the same time.

### What does the customer see?

OpenCost takes 120 seconds for its liveness/readiness probes (`initialDelaySeconds: 120` in values.yaml). If it gets OOM-killed during startup, it restarts, waits another 120 seconds, tries to build the cost model, gets killed again... This creates a long CrashLoopBackOff cycle with increasing backoff delays.

The `install.sh` even waits 800 seconds for OpenCost to become ready:
```bash
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=prometheus-opencost-exporter -n onelens-agent --timeout=800s
```

If OpenCost can't start within 800 seconds due to repeated OOM kills, the entire installation fails.

### Proposed solution

**What to change:** Increase both OpenCost request AND limit (keeping them equal — Guaranteed QoS, see Issue #4) for all tiers.

**Proposed OpenCost memory tiers:**

| Cluster Size | Current Request=Limit | Proposed Request=Limit | Why |
|---|---|---|---|
| <100 pods | 200Mi | 350Mi | Startup cost model loading peaks at ~250-280Mi. 200Mi is too tight. |
| 100-499 pods | 250Mi | 500Mi | 300+ pods means larger PromQL result sets. Cost model holds per-pod data in memory. Peak ~400Mi during startup + GC. |
| 500-999 pods | 360Mi | 700Mi | Query results for 500+ pods × multiple metrics × time ranges. Peak ~550-600Mi. |
| 1000-1499 pods | 450Mi | 900Mi | Large clusters produce proportionally larger cost model data. |
| 1500+ pods | 600Mi | 1100Mi | Very large clusters. OpenCost's internal reconciliation loop runs continuously. |

**Why OpenCost needs more memory with `[*]` labels (indirect effect):**

OpenCost itself doesn't use `[*]` labels. But it queries Prometheus, which stores all the `[*]`-inflated data from KSM. When OpenCost runs a PromQL query like `sum(kube_pod_container_resource_requests{...})`, Prometheus has to scan wider series (because each series carries more labels). The query response sent back to OpenCost is also larger because the result includes all those extra labels. So OpenCost's HTTP response parsing buffers are bigger than they would be without `[*]`.

**Files to change:**
- `install.sh` — update both `OPENCOST_MEMORY_REQUEST` and `OPENCOST_MEMORY_LIMIT` in every cluster-size tier (keeping them equal)
- `patching.sh` — same (also ensure OpenCost values are inside the cluster-size if/else block)

**Impact of this change:** More memory reserved on customer nodes for OpenCost. For most tiers, the increase is 150-500Mi above current values. This is the trade-off: more node memory reserved vs. OpenCost stuck in CrashLoopBackOff and the entire installation failing at the 800-second timeout.

**Risk:** Low. No functional changes, just higher resource reservations.

---

## Issue #6 (MEDIUM): Confusing scrape interval configuration — 30s vs 1m

### What is a scrape interval?

Prometheus collects metrics by "scraping" — it sends an HTTP GET request to each target (KSM, nodes, OpenCost, etc.) at a fixed time interval, downloads the current metric values, and stores them. The **scrape interval** controls how often this happens.

- **30 seconds** = Prometheus scrapes every target 120 times per hour = 2,880 times per day
- **1 minute** = Prometheus scrapes every target 60 times per hour = 1,440 times per day

More frequent scraping means more data points, more memory, more CPU, more disk.

### Where is the conflict? (Explained step by step)

The scrape interval is set in the YAML configuration files. The problem is that **two different YAML keys** both try to set the scrape interval, and they have **different values**. Let's walk through the exact YAML nesting to see exactly what's happening.

**Background: how Helm values map to sub-chart config**

The `onelens-agent` umbrella chart has a sub-chart called `prometheus`. In Helm, when you write values under a key named after a sub-chart, those values get passed down to that sub-chart. So:

```yaml
# Everything under "prometheus:" gets passed to the prometheus sub-chart
prometheus:
  server:      # → this becomes server: inside the prometheus chart
    global:    # → this becomes server.global: inside the prometheus chart
      scrape_interval: 1m
```

The Prometheus Helm chart (v27.3.0) uses the value at `server.global` to render the `global:` section of `prometheus.yml` — the actual config file that Prometheus reads at startup.

**Key 1: `prometheus.server.global.scrape_interval: 1m`**

Found at `globalvalues.yaml` line 190-191 (identical in `charts/onelens-agent/values.yaml` line 190-191):

```yaml
prometheus:                    # line 74 — top-level key for the prometheus sub-chart
  ...
  server:                      # line 150 — configures the prometheus server component
    ...
    global:                    # line 190 — the "global" section of prometheus.yml
      scrape_interval: 1m     # line 191 ← THIS SAYS 1 MINUTE
      scrape_timeout: 10s
      evaluation_interval: 1m
```

This is the key that the Prometheus Helm chart actually uses to render `prometheus.yml`. When the chart template generates the config file, it reads `server.global.scrape_interval` and writes it into:

```yaml
# The generated prometheus.yml file inside the Prometheus pod
global:
  scrape_interval: 1m    # ← this is what Prometheus actually reads
  scrape_timeout: 10s
  evaluation_interval: 1m
```

**Key 2: `prometheus.global.scrape_interval: 30s`**

Found at `globalvalues.yaml` line 1075-1076 (identical in `charts/onelens-agent/values.yaml` line 351-352):

```yaml
prometheus:                    # line 74 — same top-level prometheus key
  ...
  # (hundreds of lines of other config)
  ...
  prometheus-node-exporter:    # line 1067 — another sub-sub-chart
    enabled: false
    nodeSelector:
      kubernetes.io/os: linux
    tolerations:
      - effect: NoSchedule
        operator: Exists
  kubernetes.io/os: linux      # line 1074 — NOTE: this looks like a stray/misindented key
  global:                      # line 1075 — this is prometheus.global (NOT server.global!)
    scrape_interval: 30s       # line 1076 ← THIS SAYS 30 SECONDS
    scrape_timeout: 10s
    evaluation_interval: 1m
```

Notice the difference in YAML nesting:
- Key 1 is at `prometheus.server.global.scrape_interval` (3 levels deep under prometheus)
- Key 2 is at `prometheus.global.scrape_interval` (2 levels deep under prometheus — there's no `server` in between)

These are **two completely different YAML paths**. They are not the same key set twice — they are two separate keys that both sound like they control the scrape interval.

### Which key actually controls Prometheus?

The Prometheus community Helm chart (version 27.3.0, which is what we use) renders its `prometheus.yml` configuration from the `server.global` values. The chart template does something like:

```yaml
# Inside the chart template (simplified)
global:
  {{- toYaml .Values.server.global | nindent 2 }}
```

So **Key 1 (`server.global.scrape_interval: 1m`) is most likely what controls the actual running Prometheus config**. Key 2 (`global.scrape_interval: 30s`) is probably ignored entirely — it sits at a YAML path that the chart template doesn't read from.

**However, we have NOT verified this on a running cluster.** Different chart versions may use different template logic. To confirm definitively, run this on a customer cluster:

```bash
kubectl exec -n onelens-agent <prometheus-server-pod> -- cat /etc/config/prometheus.yml | head -10
```

If the output shows `scrape_interval: 1m` → Key 1 wins (and we're scraping every 1 minute)
If the output shows `scrape_interval: 30s` → Key 2 wins somehow (and we're scraping every 30 seconds)

### Why does this matter for OOM?

If the actual scrape interval is **30 seconds** (Key 2 winning), then compared to 1 minute:

1. **2x more data points in memory**: Prometheus keeps recent data (the "head block") in RAM. With 30s scrapes, each time series gets 2 data points per minute instead of 1. For 200,000 time series (common with `[*]` labels), that's 200,000 extra samples per minute sitting in memory.

2. **2x faster WAL growth**: The Write-Ahead Log records every incoming sample for crash recovery. Double the samples = double the WAL size. When Prometheus restarts and replays the WAL, it needs to load all those samples back into memory. A larger WAL means a more memory-intensive recovery.

3. **2x more frequent scrape buffer allocations**: Each scrape cycle, Prometheus allocates memory buffers to download and parse the HTTP response from each target. With KSM producing 3-5MB responses (due to `[*]`), this means allocating and parsing 3-5MB every 30 seconds instead of every 60 seconds. There's less time for Go's garbage collector to reclaim the old buffers before new ones are allocated.

4. **CPU pressure delays GC**: More frequent scraping keeps the CPU busier. Go's garbage collector competes with the main program for CPU time. If GC gets delayed, memory accumulates longer before being freed, increasing the chance of hitting the OOM limit.

**Concrete example:** For a 400-pod cluster with `[*]` labels producing ~200,000 time series:
- At 1-minute intervals: ~200,000 samples/minute ingested, WAL grows at ~X MB/min
- At 30-second intervals: ~400,000 samples/minute ingested, WAL grows at ~2X MB/min
- The head block holds 2-3 hours of data. At 30s, that's 24-36 million samples. At 1m, that's 12-18 million samples. Each sample is ~16 bytes of data + indexing overhead. The difference is **~200-300MB of extra memory** just for the head block.

### Is 30 seconds actually necessary?

**Open question — we don't know why 30s was chosen.** For a cost monitoring use case, the OneLens agent only runs once per hour. Even 2-minute or 5-minute scrape intervals would likely provide enough granularity for cost analysis. However, the original team may have had a reason for 30s (e.g., right-sizing recommendations that need finer-grained data). This should be clarified with the team before changing it.

### Proposed solution

**Step 1: Verify which key controls Prometheus** on a running customer cluster:
```bash
kubectl exec -n onelens-agent <prometheus-server-pod> -- cat /etc/config/prometheus.yml | head -10
```

**Step 2: Remove the conflicting key.** Once we know which key controls Prometheus, delete the other one. Having two keys that look like they do the same thing is a maintenance trap — someone will change one and not the other, thinking they've updated the scrape interval.

**Step 3: Decide on the right interval.** This requires product input:
- If only cost monitoring → **1 minute or even 2 minutes** is sufficient. This halves (or quarters) memory pressure from scraping.
- If right-sizing or alerting features need sub-minute data → **30 seconds** may be justified, but then the Prometheus memory tiers should be increased to account for it.

**Files to change:**
- `globalvalues.yaml` — remove one of the two conflicting keys, keep the correct one
- `charts/onelens-agent/values.yaml` — same

**Impact of unifying to 1 minute (if chosen):**
- Prometheus memory usage drops by roughly 20-30% (fewer samples in head block, smaller WAL, less frequent buffer allocations)
- Data granularity drops from 30-second to 1-minute resolution — but the OneLens agent only queries hourly, so this is invisible to the end product
- Slightly less load on the Kubernetes API server and node kubelets (fewer scrape requests)

**Risk:** Low for the removal of the conflicting key. Medium for changing the interval — need to confirm no product feature depends on 30-second resolution before changing.

---

## Summary of all issues and solutions

**IMPORTANT CONSTRAINT:** All solutions maintain Guaranteed QoS (request == limit). See Issue #4 for why. Our pods share nodes with customer production workloads — Burstable QoS risks crashing customer pods if our memory spikes consume unreserved node memory.

| # | Priority | Issue | Root Cause | Solution | Files to Change | Risk |
|---|---|---|---|---|---|---|
| 1 | P0 | KSM has `[*]` labels but only 100Mi memory | `[*]` makes every metric series 8x wider, 100Mi can't hold it | Keep `[*]` (product requirement). Increase KSM request=limit: 350Mi-2Gi depending on cluster size. Values include GC spike headroom. | `install.sh`, `patching.sh`, `globalvalues.yaml` | Low |
| 2 | P0 | `patching.sh` resets KSM to 100Mi regardless of cluster size | KSM/Pushgateway/ConfigReload resources are hardcoded OUTSIDE the cluster-size if/else block | Move KSM/Pushgateway/ConfigReload variables INSIDE the if/else block so they scale with cluster size | `patching.sh` | Low |
| 3 | P1 | Prometheus absorbs `[*]` cardinality explosion from KSM | High cardinality → large TSDB head block + memory-intensive compaction + large WAL replay | Increase Prometheus request=limit by ~1.4-1.5x to cover compaction and WAL replay peaks | `install.sh`, `patching.sh` | Medium |
| 4 | CONTEXT | `requests == limits` (Guaranteed QoS) is intentional | Pods share nodes with customer production workloads. Burstable QoS could cause our memory spikes to crash customer pods. | Keep Guaranteed QoS. All memory increases must raise BOTH request AND limit together. Values must include GC spike headroom in the base number. | All files | N/A |
| 5 | P2 | OpenCost limits too low for medium clusters | 200-250Mi insufficient for cost model computation + PromQL query results | Increase OpenCost request=limit: 350Mi-1.1Gi depending on cluster size | `install.sh`, `patching.sh` | Low |
| 6 | P2 | Conflicting scrape interval: two YAML keys set different values (30s vs 1m) | `prometheus.server.global.scrape_interval: 1m` and `prometheus.global.scrape_interval: 30s` — different YAML paths, only one controls Prometheus | Step 1: verify on running cluster. Step 2: delete the unused key. Step 3: decide right interval with product team. | `globalvalues.yaml`, `values.yaml` | Low-Medium |
| bug | P2 | `install.sh` pod count off-by-2 vs `patching.sh` | `install.sh` missing `--no-headers` on kubectl, counts header rows as pods (+1 per kubectl command, two commands = +2) | Add `--no-headers` to both kubectl commands in `install.sh` | `install.sh` | Very low |

### Implementation order

The recommended order to implement these fixes:

1. **Issue #2 first** — fix `patching.sh` regression. This is the most impactful single fix. Without it, every other memory increase gets undone within 24 hours by the daily updater CronJob.
2. **Issue #1 next** — increase KSM memory across all tiers. KSM with `[*]` labels at 100Mi is the single biggest OOM trigger.
3. **Issue #3 + #5 together** — increase Prometheus and OpenCost request=limit values with GC headroom baked in.
4. **Issue #6** — resolve scrape interval after verifying on a running cluster.
5. **Pod counting bug** — fix alongside the `install.sh` changes above.

### Complete proposed resource allocation table (all tiers, all components)

**All values are request=limit (Guaranteed QoS).** Each value includes ~1.5x headroom over estimated steady-state to absorb Go GC spikes, TSDB compaction, and transient scrape buffer allocations — without using Burstable QoS.

**Small cluster (<100 pods):**

| Component | Current (request=limit) | Proposed (request=limit) | Extra Memory Reserved |
|---|---|---|---|
| Prometheus | 1188Mi | 1700Mi | +512Mi |
| KSM | 100Mi | 350Mi | +250Mi |
| OpenCost | 200Mi | 350Mi | +150Mi |
| OneLens Agent | 400Mi | 512Mi | +112Mi |
| Pushgateway | 100Mi | 128Mi | +28Mi |
| ConfigMap Reload | 100Mi | 100Mi | — |
| **Total** | **2088Mi** | **3140Mi** | **+1052Mi** |

**Medium cluster (100-499 pods):**

| Component | Current (request=limit) | Proposed (request=limit) | Extra Memory Reserved |
|---|---|---|---|
| Prometheus | 1771Mi | 2500Mi | +729Mi |
| KSM | 100Mi | 700Mi | +600Mi |
| OpenCost | 250Mi | 500Mi | +250Mi |
| OneLens Agent | 500Mi | 650Mi | +150Mi |
| Pushgateway | 100Mi | 128Mi | +28Mi |
| ConfigMap Reload | 100Mi | 100Mi | — |
| **Total** | **2821Mi** | **4578Mi** | **+1757Mi** |

**Large cluster (500-999 pods):**

| Component | Current (request=limit) | Proposed (request=limit) | Extra Memory Reserved |
|---|---|---|---|
| Prometheus | 3533Mi | 5000Mi | +1467Mi |
| KSM | 100Mi | 1024Mi | +924Mi |
| OpenCost | 360Mi | 700Mi | +340Mi |
| OneLens Agent | 500Mi | 650Mi | +150Mi |
| Pushgateway | 100Mi | 150Mi | +50Mi |
| ConfigMap Reload | 100Mi | 100Mi | — |
| **Total** | **4693Mi** | **7624Mi** | **+2931Mi** |

**Extra large cluster (1000-1499 pods):**

| Component | Current (request=limit) | Proposed (request=limit) | Extra Memory Reserved |
|---|---|---|---|
| Prometheus | 5400Mi | 7500Mi | +2100Mi |
| KSM | 400Mi | 1536Mi | +1136Mi |
| OpenCost | 450Mi | 900Mi | +450Mi |
| OneLens Agent | 600Mi | 768Mi | +168Mi |
| Pushgateway | 400Mi | 400Mi | — |
| ConfigMap Reload | 100Mi | 100Mi | — |
| **Total** | **7350Mi** | **11204Mi** | **+3854Mi** |

**Very large cluster (1500+ pods):**

| Component | Current (request=limit) | Proposed (request=limit) | Extra Memory Reserved |
|---|---|---|---|
| Prometheus | 7066Mi | 10000Mi | +2934Mi |
| KSM | 400Mi | 2048Mi | +1648Mi |
| OpenCost | 600Mi | 1100Mi | +500Mi |
| OneLens Agent | 700Mi | 900Mi | +200Mi |
| Pushgateway | 400Mi | 400Mi | — |
| ConfigMap Reload | 100Mi | 100Mi | — |
| **Total** | **9266Mi** | **14548Mi** | **+5282Mi** |

**Summary of extra memory reserved per tier:**

| Cluster Size | Current Total | Proposed Total | Extra Reserved | Note |
|---|---|---|---|---|
| <100 pods | 2.0 Gi | 3.1 Gi | +1.0 Gi | Fits on most nodes without issue |
| 100-499 pods | 2.8 Gi | 4.5 Gi | +1.7 Gi | May need a node with ≥8Gi free |
| 500-999 pods | 4.6 Gi | 7.4 Gi | +2.9 Gi | Recommend node with ≥16Gi |
| 1000-1499 pods | 7.2 Gi | 10.9 Gi | +3.8 Gi | Recommend dedicated node or ≥16Gi free |
| 1500+ pods | 9.0 Gi | 14.2 Gi | +5.2 Gi | Strongly recommend dedicated node via `scripts/dedicated-node-installation/` |

These are **reserved** amounts (since request=limit in Guaranteed QoS, the scheduler must find a node with this much free memory). Actual usage will typically be 60-80% of these values during normal operation, spiking toward 100% during GC, compaction, and WAL replay events.

---

## What to investigate on a customer cluster experiencing OOM

If a customer reports OOM issues, here's a quick diagnostic checklist:

1. **Which pod is OOM-killing?**
   ```bash
   kubectl get pods -n onelens-agent
   # Look for pods with STATUS = OOMKilled or CrashLoopBackOff
   ```
   Use the pod-to-release table above to identify which component it is. The most common OOM culprits:
   - `*-kube-state-metrics-*` → KSM (Issues #1, #2)
   - `*-prometheus-server-*` → Prometheus (Issues #3, #4, #6)
   - `*-opencost-*` → OpenCost (Issue #5)

2. **Check the pod's last termination reason:**
   ```bash
   kubectl describe pod <pod-name> -n onelens-agent
   # Look for "Last State: Terminated, Reason: OOMKilled"
   ```

3. **Check current memory limits:**
   ```bash
   kubectl get pod <pod-name> -n onelens-agent -o jsonpath='{.spec.containers[0].resources}'
   ```
   Compare against the resource tables in Issues above. If the limit is 100Mi for KSM, patching.sh likely regressed it (Issue #2).

4. **Check how many pods the customer has:**
   ```bash
   kubectl get pods --all-namespaces --no-headers | wc -l
   ```
   Cross-reference with the resource allocation tiers in `install.sh` (see `architecture.md` Phase 9) to determine what limits should be set.

5. **Check KSM cardinality (if KSM is running):**
   ```bash
   kubectl exec -n onelens-agent <prometheus-server-pod> -- \
     wget -qO- 'http://localhost:9090/api/v1/status/tsdb' | jq '.data.headStats'
   ```
   If `numSeries` is above 200,000, cardinality is likely the issue.

6. **Check if patching.sh regressed the values:**
   ```bash
   helm get values onelens-agent -n onelens-agent
   # Compare KSM memory limit to what install.sh would have set for this cluster size
   ```

---

## Known code bugs that affect resource sizing

### install.sh and patching.sh count pods differently (off-by-2)

**What is `--no-headers` and why does it matter?**

When you run `kubectl get pods`, the output looks like this:

```
NAMESPACE     NAME                              READY   STATUS    RESTARTS   AGE
default       my-app-abc123                     1/1     Running   0          5h
default       my-app-def456                     1/1     Running   0          5h
kube-system   coredns-5dd5756b68-abc12          1/1     Running   0          2d
```

Notice the **first line** — `NAMESPACE  NAME  READY  STATUS ...` — that's a **header row**. It's not a pod, it's a column label. It exists to make the output human-readable.

When you pipe this into `wc -l` (a Linux command that counts lines), it counts **all lines including the header**. So for 3 actual pods, `wc -l` returns **4** (3 pods + 1 header).

The `--no-headers` flag tells kubectl: "Don't print that header row." With `--no-headers`, the same output becomes:

```
default       my-app-abc123                     1/1     Running   0          5h
default       my-app-def456                     1/1     Running   0          5h
kube-system   coredns-5dd5756b68-abc12          1/1     Running   0          2d
```

Now `wc -l` returns **3** — the correct count.

**How the two scripts differ:**

`install.sh` lines 261-263 — does NOT use `--no-headers`:
```bash
NUM_RUNNING=$(kubectl get pods --field-selector=status.phase=Running --all-namespaces | wc -l | tr -d '[:space:]')
NUM_PENDING=$(kubectl get pods --field-selector=status.phase=Pending --all-namespaces | wc -l | tr -d '[:space:]')
TOTAL_PODS=$((NUM_RUNNING + NUM_PENDING))
```

This runs TWO separate kubectl commands (one for Running pods, one for Pending pods). Each command produces its own header row. So:
- `NUM_RUNNING` = actual running pods + 1 (header)
- `NUM_PENDING` = actual pending pods + 1 (header)
- `TOTAL_PODS` = actual running + actual pending + **2**

`patching.sh` line 46 — DOES use `--no-headers`:
```bash
TOTAL_PODS=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | wc -l)
```

This runs ONE kubectl command with `--no-headers`, so the count is correct.

**Concrete example:** A customer cluster has 98 running pods and 1 pending pod (99 total actual pods):

| Script | Calculation | Result | Tier Selected |
|---|---|---|---|
| `install.sh` | NUM_RUNNING=98+1=99, NUM_PENDING=1+1=2, TOTAL=101 | **101** | Medium (100-499 pods) |
| `patching.sh` | --no-headers, counts all pods | **99** | Small (<100 pods) |

**What the customer experiences:**
1. **Day 0 (install):** `install.sh` counts 101 pods → selects the medium tier → sets Prometheus to 1771Mi, KSM to 100Mi, OpenCost to 250Mi
2. **Day 1 (patching):** `patching.sh` counts 99 pods → selects the small tier → sets Prometheus to 1188Mi, OpenCost to 200Mi

Prometheus memory **drops from 1771Mi to 1188Mi** overnight. If the actual workload needed 1771Mi, the next Prometheus compaction or GC spike could trigger an OOM kill — all because of a counting error.

**This only affects clusters near tier boundaries** (around 100, 500, 1000, and 1500 pods). But those are not uncommon — a customer growing from 95 to 105 pods would bounce between tiers unpredictably.

### Proposed solution

**What to change:** Add `--no-headers` to the kubectl commands in `install.sh`.

**The fix:**
```bash
# Current (incorrect — counts header rows):
NUM_RUNNING=$(kubectl get pods --field-selector=status.phase=Running --all-namespaces | wc -l | tr -d '[:space:]')
NUM_PENDING=$(kubectl get pods --field-selector=status.phase=Pending --all-namespaces | wc -l | tr -d '[:space:]')

# Fixed (correct — excludes header rows):
NUM_RUNNING=$(kubectl get pods --field-selector=status.phase=Running --all-namespaces --no-headers | wc -l | tr -d '[:space:]')
NUM_PENDING=$(kubectl get pods --field-selector=status.phase=Pending --all-namespaces --no-headers | wc -l | tr -d '[:space:]')
```

**Files to change:** `install.sh` lines 261-262

**Impact:** Pod count will be 2 lower than before. For clusters not near tier boundaries, this changes nothing. For clusters right at a boundary (e.g., 100 or 101 actual pods), they might land in the lower tier, getting less memory. However, since the tier thresholds themselves should be reviewed anyway (per the solutions in Issues #1-5), this is best done alongside the memory limit increases.

**Risk:** Very low. We're correcting a counting error. The only scenario where this could cause a problem is if someone had manually compensated for the +2 error in the tier thresholds — but there's no evidence of that in the code.

---

## Open questions (unverified / need team input)

These are things we noticed during the review but could not verify from the code alone:

1. **Which scrape interval actually controls Prometheus?** There are two keys with different values (`prometheus.server.global.scrape_interval: 1m` at globalvalues.yaml:191, and `prometheus.global.scrape_interval: 30s` at globalvalues.yaml:1076). We don't know which one the Prometheus Helm chart v27.3.0 actually renders into `prometheus.yml`. Need to check a running cluster or the chart templates.

2. **Why was 30s scrape interval chosen?** We don't know if there's a product requirement for 30-second resolution. The OneLens agent runs hourly, so cost data doesn't need sub-minute granularity. But right-sizing recommendations or other features might. Clarify with the team before changing.

3. **What does the onelens-agent CronJob actually query from Prometheus/OpenCost?** The agent image (`onelens-agent:v2.0.1`) is proprietary and its code is not in this repo. We documented that it "queries Prometheus and OpenCost" based on the health-check URLs in the values (`PROMETHEUS_HEALTH_CHECKER_URL` and `OPENCOST_HEALTH_CHECKER_URL`), but we don't know the exact queries, data volume, or memory profile. If the agent runs heavy PromQL queries, it could also contribute to Prometheus OOM during the hourly collection window.

4. **Is the patching.sh in this repo the actual script served by the API?** The `entrypoint.sh` downloads the patching script from `POST /v1/kubernetes/patching-script` at runtime. The `patching.sh` in this repo may be a reference copy, a template, or completely out of date with what the API actually serves. The OOM issues we identified (hardcoded KSM at 100Mi) are based on the repo copy — the live version served by the API could be different. Verify with the backend team.
