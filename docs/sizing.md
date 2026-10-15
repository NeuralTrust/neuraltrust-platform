# Cluster sizing (defaults)

Kubernetes schedules a pod only onto a node with enough unreserved capacity to
cover the pod's resource **requests**. Cluster size is therefore set by the
chart's default requests rather than by traffic: the node counts below are the
smallest pools on which every component of a new installation can be scheduled.
Treat them as the minimum of an autoscaling node pool, and let the cluster add
nodes as load grows.

## Minimum node pools

| Scenario | Firewall on CPU | Firewall on GPU |
|---|---|---|
| Hybrid, all products | **3** × 8 vCPU / 32 GiB | **2** × 8 vCPU / 16 GiB + **2** × L4 GPU nodes |
| Hybrid, TrustGuard only | **3** × 8 vCPU / 16 GiB | **2** × 8 vCPU / 16 GiB + **2** × L4 GPU nodes |
| Hybrid, TrustGate only | **2** × 8 vCPU / 16 GiB | — (no Firewall) |
| External or SaaS | **4** × 8 vCPU / 32 GiB | **3** × 8 vCPU / 16 GiB + **2** × L4 GPU nodes |

| Node | AWS | Azure | GCP |
|---|---|---|---|
| 8 vCPU / 32 GiB | `m6i.2xlarge` | `Standard_D8s_v5` | `e2-standard-8` |
| 8 vCPU / 16 GiB | `c6i.2xlarge` | `Standard_F8s_v2` | `c4-highcpu-8` |
| L4 GPU node: 8 vCPU / 32 GiB, one NVIDIA L4 | `g6.2xlarge` | No L4 size; not validated | `g2-standard-8` |

Each count allows for the cluster's own components — the node's system
reservation, DaemonSets, and kube-system — and keeps total requests at or below
85 % of allocatable capacity. The remaining 15 % absorbs the extra pod a rolling
upgrade creates. With one node fewer, the installation cannot be scheduled.
Where a single node would be enough, the table specifies two, so that the two
replicas of the request path run on different nodes.

**Enable cluster autoscaling.** Set each node pool's minimum to the count above
and its maximum at least two nodes higher. Capacity for additional replicas,
upgrades, and node failures is then added when it is needed, rather than
provisioned in advance.

## Firewall on GPU

Start from [`values-dataplane-gpu.yaml.example`](../values-dataplane-gpu.yaml.example).
With it, each Firewall worker requests 1 vCPU, 4 GiB, and one GPU, and is
scheduled onto the GPU pool; the Firewall gateway and every other component stay
on the CPU pool. The GPU pool needs:

- The NVIDIA device plugin, with the nodes tainted `nvidia.com/gpu:NoSchedule`
  and labelled `accelerator: nvidia`, or the selector you set in the example.
- **CUDA MPS sharing with four clients per GPU**, so that two L4 nodes can host
  all seven workers. On GKE, set the node pool's GPU sharing strategy to `MPS`
  with `max_shared_clients_per_gpu = 4`; on EKS, enable MPS sharing in the NVIDIA
  device plugin with four replicas. Four is the most an L4 can hold: each client
  may pin up to 6000 MB of device memory, and the L4 has 24 GB. Without sharing,
  every worker needs a GPU of its own.

## What the chart requests

These totals sum the requests of every replica and sidecar in the default
render, with the request path at two replicas and PostgreSQL and Redis running in
the cluster. Values are rounded up to whole vCPU and GiB.

| Scenario | Firewall on CPU | Firewall on GPU: CPU pool | Firewall on GPU: GPU pool |
|---|---|---|---|
| Hybrid, all products (`values-required.yaml`) | 13 vCPU / 37 GiB | 6 vCPU / 15 GiB | 7 vCPU / 28 GiB, 7 GPU shares |
| Hybrid, TrustGuard only | 9 vCPU / 25 GiB | 3 vCPU / 6 GiB | 6 vCPU / 24 GiB, 6 GPU shares |
| Hybrid, TrustGate only | 3 vCPU / 6 GiB | — | — |
| External (`values-external.yaml.example`) | 18 vCPU / 46 GiB | 11 vCPU / 24 GiB | 7 vCPU / 28 GiB, 7 GPU shares |
| SaaS (central control plane) | 19 vCPU / 47 GiB | 12 vCPU / 25 GiB | 7 vCPU / 28 GiB, 7 GPU shares |

- **Managed PostgreSQL and Redis** lower memory requests by 2 GiB.
- **SaaS** is External plus two DataBridge and two ingest-gateway replicas.
- **Excluded:** the node's system reservation, DaemonSets, kube-system, and your
  ingress controller or Gateway. The node counts above already allow for them.
- **Evaluation Jobs**, when `data-plane-api` runs evaluations as Kubernetes Jobs
  (`k8sJobs.enabled`, off by default), add up to 1 vCPU / 3 GiB while they run.

Requests describe what the scheduler reserves, not the throughput an
installation sustains. Measure under your own traffic before tuning.

## What drives capacity

| Area | Default request / limit | Notes |
|---|---|---|
| Firewall CPU workers | 1 vCPU / 3 GiB each; limit 2 vCPU / 4 GiB | Seven with all products, six with TrustGuard only. `prompt-moderation` requests 4 GiB (limit 6 GiB) and `topic-guard` is limited at 5 GiB. Together they are 60 % of Hybrid's memory requests |
| `data-plane-api` | 1 vCPU / 3 GiB per replica, two replicas; limit 2 vCPU / 6 GiB | Runs evaluations in-process unless `k8sJobs` is on |
| ClickHouse (External, SaaS) | 1 vCPU / 4 GiB; limit 4 vCPU / 8 GiB | 50 GiB volume; keep headroom for analytics queries |
| In-cluster PostgreSQL | 500m / 2 GiB | Prefer managed stores in production |
| In-cluster Redis | 100m / 128 MiB | Prefer managed stores in production |

Measured on CPU workers in a single-tenant cluster, load tests included, the
heaviest Firewall worker (`indirect-prompt-injections`) peaked at 3 GiB of
memory and the others stayed under it. To shrink the Firewall, leave out the
detectors you do not use before lowering any worker's memory request.

## Tuning

- **Scale out** the request path (`agentgateway` proxy / MCP, TrustGuard data
  plane) with `replicas`, or enable HPA when the cluster has metrics.
- **Right-size** the Firewall by running only the detectors you use.
- **Use managed PostgreSQL and Redis** so datastore capacity is independent of
  the node pool ([`values-managed-datastores.yaml.example`](../values-managed-datastores.yaml.example)).
- **Pin workloads** to a dedicated pool with `global.nodeSelector` /
  `global.tolerations`.

## How these numbers were produced

Requests come from `helm template` of this chart with the values files named in
each row (plus `values-dataplane-gpu.yaml.example` for GPU), summing every
Deployment, StatefulSet and DaemonSet container times its replicas, and rounding
up. Node counts use the allocatable capacity and add-on footprint read from GKE
and AKS clusters on 2026-10-15, taking the larger of the two. Re-derive them
after changing defaults; `ntctl preflight` runs the same request-versus-allocatable
check against a live cluster.

## Related

- [DEPLOYMENT.md](../DEPLOYMENT.md) — install paths
- [docs/architecture.md](./architecture.md) — topology contract
- Managed store minimums are documented alongside production datastore guidance
  in the public NeuralTrust deployment docs.
