# Cluster sizing (defaults)

Chart defaults are a **sensible starting point** for evaluation and typical
production traffic — not a hard ceiling. Right-size and fine-tune CPU, memory,
replicas, and node pools to match your traffic, latency goals, and budget.

Numbers below are **Kubernetes resource requests** from the current chart
defaults (in-cluster PostgreSQL + Redis; Firewall CPU workers when TrustGuard
is on). They do **not** include the node OS, kube-system, or ingress controller.
Leave headroom for those.

## Recommended worker profile

| | Hybrid (full products) | External (self-hosted) | SaaS (central control plane) |
|---|---|---|---|
| Approx. chart requests | ~10 vCPU / ~28 GiB | ~15 vCPU / ~38 GiB | ~external + DataBridge HA (2 pods) + ingest gateway |
| Comfortable cluster shape | **3–4** workers at **8 vCPU / 16–32 GiB** each | **4–5** workers at **8 vCPU / 16–32 GiB** each | Same as external; plan for two DataBridge replicas |
| Example cloud shapes | AWS `m6i.2xlarge` × 3 · Azure `Standard_D8s_v5` × 3 · GCP `e2-standard-8` × 3 (regional) | Same SKU class with **one extra node** | Same as external |

Hybrid with fewer products (for example TrustGate only, no Firewall) needs
substantially less memory — Firewall CPU workers are the largest consumers.

External adds control-plane API/app, ClickHouse, ClickStack collector, DataCore,
and AlertEngine on top of the data path. SaaS is external plus DataBridge
(default `replicas: 2`) and the public telemetry ingest path — see
[saas-mode.md](./saas-mode.md#quick-start). Opt down with `databridge.replicas: 1`
on cheap central clusters.

## What drives capacity

| Area | Notes |
|---|---|
| Firewall CPU workers | Largest memory footprint when TrustGuard is enabled (~3–4 GiB request each) |
| `data-plane-api` | Significant CPU/memory for evaluation / analytics API |
| ClickHouse (external only) | ~4 GiB request; keep headroom for analytics queries |
| PostgreSQL / Redis | Smaller in-cluster defaults; prefer managed stores in production |

GPU Firewall workers need a separate GPU pool — see
[`values-dataplane-gpu.yaml.example`](../values-dataplane-gpu.yaml.example).

## Tuning for your needs

Defaults are intentionally conservative and portable. Common adjustments:

- **Scale out** busy gateways (`agentgateway.proxy` / `mcp`, TrustGuard data plane)
  with higher `replicaCount` or enable HPA when your cluster has metrics.
- **Right-size** Firewall workers if you run a subset of detectors, or move
  heavy workers to GPU.
- **Use managed PostgreSQL and Redis** so datastore capacity is independent of
  the Kubernetes node pool ([`values-managed-datastores.yaml.example`](../values-managed-datastores.yaml.example)).
- **Pin workloads** to a dedicated pool with `global.nodeSelector` /
  `global.tolerations`.

There is no single “correct” size — start from the defaults, measure under your
workload, then tune.

## Related

- [DEPLOYMENT.md](../DEPLOYMENT.md) — install paths
- [docs/architecture.md](./architecture.md) — topology contract
- Managed store minimums are documented alongside production datastore guidance
  in the public NeuralTrust deployment docs.
