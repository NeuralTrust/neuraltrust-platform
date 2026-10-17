# Running data planes outside this chart

This chart renders and validates the environment that AgentGateway (TrustGate)
and TrustGuard data planes start with. If you run those images any other way —
Amazon ECS, Docker Compose, or a hand-written container runtime — nothing
renders that environment for you and none of the chart's checks run. This page
lists the settings the chart takes care of that you must apply yourself.

## Hybrid: raw payloads stay local

In `hybrid` mode, request and response bodies (the *raw* telemetry class) stay
in your PostgreSQL, where DataAgent serves them. Only metadata leaves the
cluster, over OTLP through the DataAgent egress collector.

The chart enforces this:

- `global.telemetry.raw` defaults to `local` in hybrid, which renders
  `TELEMETRY_EXPORTERS_RAW=[{"name":"raw-postgres","type":"postgres"}]` for
  both AgentGateway and TrustGuard.
- `global.telemetry.raw: remote` fails the render unless
  `global.telemetry.rawRemoteExperimental: true` is also set. That escape hatch
  is for local experiments only and is unsupported.
- Any value other than `local` or `remote` fails the render, so a typo cannot
  silently change where payloads go.

Outside the chart none of this is checked. The data planes read
`TELEMETRY_EXPORTERS_METADATA` and `TELEMETRY_EXPORTERS_RAW` from their
environment and use whatever they are given. For a hybrid data plane, check by
hand that every AgentGateway and TrustGuard task or container sets:

```bash
TELEMETRY_EXPORTERS_METADATA='[{"name":"metadata-otlp","type":"otlp"}]'
TELEMETRY_EXPORTERS_RAW='[{"name":"raw-postgres","type":"postgres"}]'
```

and in particular that `TELEMETRY_EXPORTERS_RAW` has **no** `otlp` exporter.
An `otlp` raw exporter sends request and response bodies out of your network
with the metadata stream.

`external` and `saas` modes keep all telemetry in your own cluster, so raw
`otlp` is the correct value there.

## Config-sync last-known-good snapshot path

With config-sync on, each data plane writes an encrypted last-known-good (LKG)
snapshot of its configuration to `CONFIG_SYNC_LKG_PATH`, using
`CONFIG_SYNC_LKG_KEY` (base64 that decodes to exactly 32 bytes) as the
AES-256-GCM key. On start it restores that snapshot before contacting the
control plane.

| Product | Default `CONFIG_SYNC_LKG_PATH` |
| -- | -- |
| AgentGateway (TrustGate) | `/var/lib/trustgate/snapshot.lkg` |
| TrustGuard | `/var/lib/trustguard/snapshot.lkg` |

The images run as a non-root user that cannot write under `/var/lib`. The
chart hides this by mounting an `emptyDir` at the default directory. Outside
the chart, the default path is not writable, and every snapshot write logs a
`failed to persist last-known-good snapshot` warning with the error:

```text
configsync: create lkg dir: mkdir /var/lib/trustgate: permission denied
```

Set the path explicitly to a writable location. The Docker Compose bundle
shipped with TrustGate uses:

```bash
CONFIG_SYNC_LKG_PATH=/tmp/trustgate-snapshot.lkg
```

Two things to know:

- **An empty value does not disable the snapshot.** An unset or empty
  `CONFIG_SYNC_LKG_PATH` falls back to the default path above, so you get the
  same permission error. Point it at a writable path instead.
- **A failed write is a warning, not a crash.** The data plane keeps serving
  the configuration it converged on. What you lose is the snapshot itself:
  a data plane that starts while the control plane is unreachable has nothing
  to restore and must wait for config-sync to reconnect.

On `/tmp` inside the container the snapshot lives only as long as that
container. To let a replacement task start from the last snapshot, put the path
on persistent storage — on ECS, an EFS volume mounted into the task.

## Secrets

The chart delivers `CONFIG_SYNC_TOKEN`, `CONFIG_SYNC_LKG_KEY` and the database
credentials from Kubernetes Secrets. On ECS, keep them in AWS Secrets Manager
or SSM Parameter Store and inject them through the task definition's `secrets`
field, not as plain `environment` values. See [SECRETS.md](../SECRETS.md) for
what each value is.

## Related

- [Architecture and topology contract](./architecture.md) — exporter
  defaults per mode
- [Hybrid network allowlist](./hybrid-network.md) — egress a hybrid data plane needs
- [Observability](./observability.md)
