# Network Cost Attribution

## Overview

OneLens can attribute network data transfer costs to individual pods and namespaces in your Kubernetes cluster. This enables you to see exactly which workloads are responsible for cross-AZ, cross-region, and internet egress traffic — and what each costs.

Without network cost attribution, OneLens tracks CPU, memory, GPU, and storage costs but reports network costs as $0. With it enabled, you get a complete picture of your Kubernetes spend.

## What You Get

Once enabled, OneLens breaks down network costs per pod and namespace into four categories:

| Category | Description | Example (AWS us-east-1) |
|---|---|---|
| **Same-zone** | Traffic between pods/services in the same availability zone | Free ($0.00/GB) |
| **Cross-zone** | Traffic between availability zones in the same region | $0.01/GB |
| **Cross-region** | Traffic to a different cloud region | $0.02/GB |
| **Internet** | Traffic to external destinations (public internet, third-party APIs) | $0.09/GB |

This allows you to:

- Identify which namespaces or services generate the most network cost
- Find workloads with excessive cross-AZ traffic (a common hidden cost)
- Optimize pod placement to reduce data transfer charges
- Get accurate total cost per service including network

## How It Works

OneLens deploys a lightweight Rust-based agent on each node in your cluster as a DaemonSet. The agent reads the Linux kernel's connection tracking table (`/proc/net/nf_conntrack`) to see which pods are communicating with which destinations and how much data is being transferred. Traffic is classified by destination type (same-zone, cross-zone, cross-region, internet) using cloud provider IP range data.

OpenCost — already part of the OneLens stack — downloads your cloud provider's data transfer pricing automatically and multiplies the classified traffic bytes by the correct per-GB rates. No pricing configuration is needed.

The agent is:

- **Read-only** — it reads existing kernel connection tracking data; it does not intercept, modify, or inspect traffic content
- **Lightweight** — uses approximately 50m CPU and 64MB memory per node
- **Rust-based** — minimal resource footprint, no runtime dependencies

## Requirements

Network cost attribution requires elevated permissions compared to the standard OneLens agent installation. Please review these requirements with your security team before enabling.

### Permissions Needed

| Permission | Reason |
|---|---|
| **Privileged container** | Required to read the kernel's connection tracking table (`/proc/net/nf_conntrack`). This is a read-only data structure maintained by the Linux kernel for NAT and stateful firewall tracking. |
| **Host network access** | Required to observe network connections at the node level. Without this, the agent would only see traffic within its own pod network namespace. |

### What This Does NOT Do

- Does **not** inspect packet contents or payload data — only connection metadata (source IP, destination IP, byte count)
- Does **not** require any additional cluster-wide RBAC permissions beyond what OneLens already has
- Does **not** modify network routing, firewall rules, or iptables
- Does **not** modify kernel parameters
- Does **not** require node restarts
- Does **not** affect application network performance

### Cluster Compatibility

| Environment | Compatible? | Notes |
|---|---|---|
| Amazon EKS | Yes | Fully supported |
| Google GKE | Yes | Standard and Autopilot (Autopilot may require workload policy exception) |
| Azure AKS | Yes | Standard clusters |
| Oracle OKE | Yes | Requires manual VCN CIDR configuration (see below) |
| On-premises (kubeadm, RKE, etc.) | Yes | If nodes run standard Linux kernel with conntrack |
| Clusters with PodSecurity `restricted` | No | Privileged pods are blocked by policy |
| Clusters with Kyverno/OPA blocking privileged pods | No | Policy must exempt `onelens-agent` namespace |

If your cluster enforces policies that block privileged pods, you can either:
1. Add an exception for the `onelens-agent` namespace
2. Leave network cost attribution disabled (all other OneLens features continue to work normally)

OneLens performs an automated pre-flight check before attempting deployment. If your cluster's security policies block privileged pods, the feature is skipped gracefully and the specific admission error is logged for troubleshooting.

## Enabling Network Cost Attribution

Network cost attribution is **disabled by default** and must be explicitly enabled.

### During Installation

Set the `NETWORK_COSTS_ENABLED` environment variable when installing the deployer:

```bash
helm upgrade --install onelensdeployer onelens/onelensdeployer \
  -n onelens-agent --create-namespace \
  --set job.env.CLUSTER_NAME=<cluster-name> \
  --set job.env.REGION=<region> \
  --set-string job.env.ACCOUNT=<account-id> \
  --set job.env.REGISTRATION_TOKEN=<token> \
  --set job.env.NETWORK_COSTS_ENABLED=true
```

### On an Existing Cluster

Contact your OneLens account team to enable network cost attribution. The OneLens team will:

1. Verify your cluster supports privileged pods (an automated pre-flight check runs before deployment)
2. Auto-detect your cloud provider for correct traffic classification
3. Enable the feature via the next scheduled patching cycle

### For OCI / OKE Clusters

Oracle Cloud Infrastructure does not publish IP ranges in a format the network agent can auto-detect. If you are running on OCI, please provide your VCN CIDRs to the OneLens team so traffic can be classified correctly:

- **Same availability domain (AD):** Your primary VCN CIDR (e.g., `10.0.0.0/16`)
- **Same region, different AD:** Other VCN CIDRs in the same region
- **Cross-region:** VCN CIDRs in other OCI regions

Without these, all traffic will be classified as "internet" which overstates costs.

## Resource Usage

The network cost agent runs one pod per node with the following resource footprint:

| Resource | Request | Limit |
|---|---|---|
| CPU | 50m | 200m |
| Memory | 64Mi | 128Mi |

For a 20-node cluster, total additional resource consumption is approximately 1 CPU core and 1.3GB memory across all nodes.

## Limitations

Network cost attribution covers pod-to-pod and pod-to-external traffic visible at the node level. The following network costs are **not** covered and require cloud billing data (e.g., AWS CUR) for visibility:

| Cost type | Why not covered |
|---|---|
| Load Balancer (ELB/ALB/NLB) | Billed by cloud provider per hour + per request, not visible in node connection tracking |
| NAT Gateway data processing | Managed cloud service, processing fees not visible at node level |
| S3 / RDS / DynamoDB transfer | Traffic to out-of-cluster cloud services is classified as internet egress |
| DNS query costs (Route53) | DNS queries are not connection-tracked |
| VPC Peering / Transit Gateway | Cloud networking plane costs, not visible at node level |
| Inbound (ingress) traffic | Cloud providers do not charge for inbound data transfer |

## Disabling Network Cost Attribution

If you need to disable network cost attribution after it has been enabled, contact your OneLens account team. The network cost agent will be removed during the next patching cycle. No data is lost — historical network cost data remains available for the period it was active. All other OneLens features continue to work normally.

## Frequently Asked Questions

**Does this affect my application's network performance?**
No. The agent reads existing kernel data structures passively. It does not sit in the network path, does not proxy traffic, and does not add latency to any connections.

**Can the agent see my application's data/payload?**
No. The agent only reads connection metadata: source IP, destination IP, protocol, and byte counts. It cannot read packet contents or application data.

**What happens if a node reboots?**
The DaemonSet pod restarts automatically when the node comes back. There is a brief gap in network cost data while the node is down, which resolves automatically.

**What if my cluster blocks privileged containers?**
Network cost attribution will not be enabled. OneLens performs a pre-flight check before attempting deployment. If your cluster's security policies block privileged pods, the feature is skipped gracefully and all other OneLens features continue to work. The specific admission error is logged for troubleshooting.

**Does this work with Fargate / serverless nodes?**
No. Fargate nodes do not support DaemonSets or host-level access. Network cost attribution requires traditional EC2/VM-based nodes.

**Can I enable this for only some nodes?**
Not currently. The agent runs on all nodes to provide complete network cost visibility. Partial deployment would result in incomplete data. If you need to exclude specific node pools, contact the OneLens team.

**How does pricing work?**
OpenCost — already part of the OneLens stack — downloads your cloud provider's published data transfer rates automatically. The network cost agent only classifies traffic by destination type; OpenCost handles all pricing calculations. No manual pricing configuration is needed.
