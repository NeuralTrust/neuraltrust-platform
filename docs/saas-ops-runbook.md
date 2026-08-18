# Ops runbook — central control plane + remote data planes

Operational companion to [`saas-mode.md`](./saas-mode.md). That doc is the
chart contract. This one is install order, the silent failure modes, and what
to do when a plane looks healthy but is not.

No secrets belong in this file. Use `platform.example.com` as the domain
placeholder.

## Install order

1. **Central cluster first**, `global.deploymentMode: saas`, and wait until it
   is fully healthy (control-plane API/app, DataBridge 2/2, ingest gateway,
   DataCore, both config-sync L4 Services have load-balancer hostnames).
2. Create DNS (see [DNS split](#dns-split)) and export the chart CA with
   `scripts/export-controlplane-ca.sh` unless every L4 leaf is already from a
   CA the remote planes trust.
3. Open the console (`https://app.<domain>`). Create one **Private gateway**
   per remote plane. Collectors belong to a **guard instance** — do not copy
   a `collector_id` from the central plane into a remote one.
4. Mint **one enrolment token and one config-sync token per remote plane**,
   each with its own `instance_id`. Never share tokens across clusters.
5. **One remote cluster as canary**: `global.deploymentMode: hybrid`,
   `global.controlPlane.domain` (or `global.domain`) pointing at the central
   domain, `global.controlPlane.caSecretName` if you exported the CA, products
   enabled explicitly. Confirm enrolment, config-sync snapshots, a console
   query, and a telemetry row in central ClickHouse before adding more planes.
6. Remaining remotes, one at a time.

Remote clusters keep their own Redis and Postgres. They stream through
DataBridge; they do not need the central RDS/ElastiCache/ClickHouse.
Metadata still needs egress to `https://telemetry.<domain>` — already
one of the four 443 legs.

## DNS split

Four names derive from one domain. They are not treated the same:

| Name | Kind | Proxy |
| -- | -- | -- |
| `databridge.<domain>` | L4 gRPC, TLS in the pod | **Must be unproxied** (straight to the NLB) |
| `agentgateway-configsync.<domain>` | L4 gRPC, TLS in the pod | **Must be unproxied** |
| `trustguard-configsync.<domain>` | L4 gRPC, TLS in the pod | **Must be unproxied** |
| `telemetry.<domain>` | HTTPS, publicly trusted cert | **Should stay on the public edge** |

A TLS-terminating proxy in front of the three L4 names serves the proxy's
certificate. The data plane pins the chart CA and rejects it. The same proxy
in front of telemetry is correct.

`loadBalancerSourceRanges` on the L4 Services must include each remote
cluster's egress NAT. Empty means the whole internet can open TCP
(authentication still applies). A laptop `openssl` to those names will time
out when the allowlist is the remote NAT only — that is not a DNS miss.
Probe from a pod in the remote cluster.

Do not pin raw `*.elb.amazonaws.com` hostnames in hybrid values. A `helm
upgrade` that recreates a Service mints a new NLB name and every pinned
client fails with `produced zero addresses`. Stable CNAMEs keep remote values
unchanged; if you *do* recreate a Service, retarget the CNAME **targets**.

Post-install NOTES in saas mode print the four names and:

```bash
kubectl get svc -n <namespace> \
  databridge-southbound \
  agentgateway-admin-configsync \
  trustguard-control-plane-configsync
```

## Config-sync is per product

`global.controlPlane.configSyncAddr` is a single dial host. Each product
publishes its own L4 listener and certificate SAN. A scalar address with two
or more products **fails the render**. Use DNS (`<product>-configsync.<domain>:443`)
or per-product `agentgateway.configSync.endpoint` /
`trustguard.configSync.endpoint`.

The failure mode without the guard is silent: the product that does not own
the configured load balancer retries TLS in the background and keeps serving
last-known-good. The pod looks Ready.

## Collectors are per guard instance

A TrustGuard plugin `collector_id` is scoped to the guard instance in that
plane's config-sync token. Copying a collector from the central instance onto
a remote plane returns **403**. AgentGateway **fails open** (client still gets
200). Telemetry, latency and cost look healthy while requests pass
uninspected.

Create the collector under the remote guard instance and point the plugin at
**that** id. Confirm `/v1/evaluate → 200` and a blocked-content probe before
calling the plane enforced.

## Upgrades

- **Stagger central and remote.** Overlapping upgrades can roll the TrustGuard
  control plane while the remote worker starts; the first converge then times
  out for ~15s and recovers. That is noisy, not a rollback signal.
- **DataBridge** is HA (`replicas: 2` by default). A rolling restart drops
  each agent's stream for ~1–3s; agents reconnect unattended. The query path
  (`/raw`) is down for that window.
- **OTLP token refresh still depends on the DataBridge stream.** An outage
  longer than about five minutes that overlaps an agent's refresh window
  silently drops telemetry (pods stay Ready). See the chart follow-up on
  token refresh; do not treat "no new ClickHouse rows" as "no traffic"
  without checking ingest-gateway auth and the egress collector.

Do not recreate L4 Services to "test DNS". Retarget CNAME targets first if
you must.

## Troubleshooting (looks healthy)

| Symptom | Likely cause |
| -- | -- |
| Pod Ready, config never updates | Scalar `configSyncAddr` / wrong product LB; or L4 DNS behind a TLS-terminating proxy |
| `dial tcp 10.x.x.x:443: i/o timeout` | Internal NLB, no peering; set `global.controlPlane.loadBalancerScheme` and source ranges |
| `produced zero addresses` | Raw NLB hostname in values after a Service recreate |
| Enrolment flaps every few seconds | DataBridge restart; wait for unattended reconnect |
| Telemetry 401 / empty `otel.otel_logs` | Ingest gateway auth, missing telemetry Ingress, or OTLP token refresh during a broker gap |
| `/v1/evaluate` 403, client still 200 | `collector_id` belongs to a different guard instance |
| NOTES say "external" on a saas install | Chart older than the saas-aware NOTES change; ignore and use this runbook |

Live tables: `otel.otel_logs` → `default.trustgate_events` /
`default.trustguard_events` (plus `*_raw` for bodies). Empty
`neuraltrust.agentgateway_requests` does **not** mean telemetry is broken.

## Rollback

| Change | Safe independently? |
| -- | -- |
| Remote hybrid chart only | Yes, if the central L4 names and CA are unchanged |
| Central chart that does not recreate L4 Services | Yes; remotes keep last-known-good during the roll |
| Recreating a central L4 Service | No — update CNAME targets before or with the upgrade |
| Rotating the chart CA | No — export and roll `caSecretName` on every remote first |
| DataBridge image | Yes at HA; expect a few seconds of query-path 503 |

## Ownership

| Component | Owner |
| -- | -- |
| Chart / NOTES / render suite | Platform (Automation) |
| Central DNS (proxied vs unproxied split) | whoever owns the zone |
| Enrolment and config-sync tokens | console operator per remote plane |
| Guard collectors | console operator; per instance, never copied |
| Central RDS / ElastiCache / ClickHouse | infra for the central cluster only |
| Remote Postgres / Redis | that remote's operators |
