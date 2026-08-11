# Hybrid network allowlist

Hybrid data planes initiate outbound connections for configuration sync,
DataBridge, and telemetry. Your firewall / security group rules must allow the
destinations below from cluster worker nodes (and from any egress NAT / proxy
that fronts them).

This page is for hybrids that dial **NeuralTrust-hosted** control planes
(`global.saasRegion`). If the control plane is **yours**
(`global.deploymentMode: saas` on another cluster), allowlist *that* operator's
four endpoints instead — see [saas-mode.md](./saas-mode.md#endpoints).

Prefer **hostname** rules when your firewall supports DNS-based allowlists.
The IPs are provided for static ACLs. If DNS resolves differently in your
region, trust DNS and contact NeuralTrust support to refresh the IP list.

## Pick your SaaS region first

`global.saasRegion` decides which NeuralTrust SaaS the cluster talks to and
therefore which hostnames to allowlist:

```yaml
global:
  saasRegion: "eu"   # default; "us" for Americas
```

It drives config-sync, DataBridge, and telemetry together — allowlist the row
for your region only.

## Outbound (egress)

Allow **TCP 443** from your cluster egress to:

### `saasRegion: eu` (default)

| Hostname | IP | Purpose |
|---|---|---|
| `agentgateway-configsync.neuraltrust.ai` | `34.22.134.169` | TrustGate (AgentGateway) config-sync gRPC |
| `trustguard-configsync.neuraltrust.ai` | `34.62.69.111` | TrustGuard config-sync gRPC |
| `databridge.neuraltrust.ai` | `34.62.63.231` | DataAgent DataBridge gRPC |
| `telemetry.neuraltrust.ai` | DNS | ClickStack OTLP egress |

### `saasRegion: us`

| Hostname | IP | Purpose |
|---|---|---|
| `agentgateway-configsync.us.neuraltrust.ai` | DNS | TrustGate (AgentGateway) config-sync gRPC |
| `trustguard-configsync.us.neuraltrust.ai` | DNS | TrustGuard config-sync gRPC |
| `databridge.us.neuraltrust.ai` | DNS | DataAgent DataBridge gRPC |
| `telemetry.us.neuraltrust.ai` | DNS | ClickStack OTLP egress |

US rows list DNS only; use hostname rules and ask NeuralTrust support for
static IPs if your firewall cannot resolve names.

Also allow outbound HTTPS to your container registry (or mirror), LLM
upstreams, and managed PostgreSQL / Redis. Product OTLP exits via the local
`clickstack-egress-collector`, which is the only workload that dials the
telemetry host.

Config-sync tokens and the DataAgent enrolment token are region-scoped: a
credential issued by EU will not authenticate against US.

## Inbound (ingress)

Allow traffic **from** this NeuralTrust source IP into your cluster / edge
(typically to your published TrustGate LLM and MCP entry points):

| Source IP |
|---|
| `34.78.98.144` |

Config-sync and DataBridge themselves are **outbound-only** from your cluster;
they do not require opening inbound ports for those services.

## Related

- [docs/architecture.md](./architecture.md) — hybrid control and data channels
- [docs/saas-mode.md](./saas-mode.md) — customer-owned control plane (different allowlist)
- [DEPLOYMENT.md](../DEPLOYMENT.md) — install paths
