# Hybrid network allowlist

Hybrid data planes initiate outbound connections to NeuralTrust for
configuration sync and DataBridge. Your firewall / security group rules must
allow the destinations below from cluster worker nodes (and from any egress
NAT / proxy that fronts them).

Prefer **hostname** rules when your firewall supports DNS-based allowlists.
The IPs are provided for static ACLs. If DNS resolves differently in your
region, trust DNS and contact NeuralTrust support to refresh the IP list.

## Outbound (egress)

Allow **TCP 443** from your cluster egress to:

| Hostname | IP | Purpose |
|---|---|---|
| `agentgateway-configsync.neuraltrust.ai` | `34.22.134.169` | TrustGate (AgentGateway) config-sync gRPC |
| `trustguard-configsync.neuraltrust.ai` | `34.62.69.111` | TrustGuard config-sync gRPC |
| `databridge.neuraltrust.ai` | `34.62.63.231` | DataAgent DataBridge gRPC |

Also allow outbound HTTPS to your container registry (or mirror), LLM
upstreams, and managed PostgreSQL / Redis. Product OTLP exits via the local
`clickstack-egress-collector` (default target `telemetry.neuraltrust.ai`) —
include that host if your policy lists every external destination.

## Inbound (ingress)

Allow traffic **from** this NeuralTrust source IP into your cluster / edge
(typically to your published TrustGate LLM and MCP entry points):

| Source IP |
|---|
| `34.78.98.144` |

Config-sync and DataBridge themselves are **outbound-only** from your cluster;
they do not require opening inbound ports for those services.

## Related

- [docs/platform-v2.md](./platform-v2.md) — hybrid control and data channels
- [DEPLOYMENT.md](../DEPLOYMENT.md) — install paths
