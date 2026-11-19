# Pod labels and annotations

Add your own labels and annotations to every pod the chart runs:
- Deployments
- StatefulSets
- hook Jobs
- CronJobs

Common uses are a group label that a NetworkPolicy selects on, a cost-allocation
label, and an annotation a mesh or an agent reads.

Set them once in values:

```yaml
global:
  podLabels:
    example.com/communication-flow: platform
  podAnnotations:
    example.com/owner: platform-team
```

They go on `spec.template.metadata` only, never on a selector. Each change rolls
the affected pods on the next `helm upgrade`, and no resource is renamed or
replaced. The one exception is the PostgreSQL bootstrap Job, which is covered
below. With both maps empty, the render is the same as without them.

## Precedence

Each pod merges these layers. When two layers set the same key, the later one wins.

| Layer | Values | Applies to |
|---|---|---|
| 1 | `global.podLabels`, `global.podAnnotations` | Every pod |
| 2 | The component's own `podLabels`, `podAnnotations` (table below) | That component's pods |
| 3 | `global.jobs.podLabels`, `global.jobs.podAnnotations` | Job and CronJob pods only |
| 4 | Keys the chart sets itself | Always win |

Component keys:

| Component | Values |
|---|---|
| A subchart: `agentgateway`, `trustguard`, `firewall`, `alertengine`, `datacore`, `dataagent`, `databridge`, `clickhouse`, `clickstack-ingest-gateway`, `clickstack-otel-collector`, `control-plane-api`, `control-plane-app`, `data-plane-api`, `watchdog` | `<subchart>.podLabels`, `<subchart>.podAnnotations` |
| One DataAgent | `agentgateway.dataagent.*` or `trustguard.dataagent.*` |
| In-cluster PostgreSQL and its bootstrap Job | `global.postgresql.podLabels`, `global.postgresql.podAnnotations` |
| In-cluster Redis | `global.redis.podLabels`, `global.redis.podAnnotations` |
| OpenTelemetry collector | `global.observability.collector.podLabels`, `global.observability.collector.podAnnotations` |

A subchart's map covers every pod in it: for example, the admin, proxy and MCP
pods for `agentgateway`, and the gateway and every worker for `firewall`.

## Reserved keys

The render fails with the values path when a map sets a key the chart owns:

- **Labels:** `app.kubernetes.io/*`, `helm.sh/*`, `app`, `plane` and
  `azure.workload.identity/use`. Some of these are selectors, which Kubernetes
  never lets you change on a live Deployment.
- **Annotations:** `checksum/*`, which the chart uses to roll pods when their
  configuration changes.

## Jobs and sidecars

Jobs run to completion. A sidecar that never exits keeps a Job pod running, so
the Job never succeeds and the next `helm upgrade` can wait on it. Set the
injection opt-out for Jobs only:

```yaml
global:
  podLabels:
    sidecar.istio.io/inject: "true"
  jobs:
    podLabels:
      sidecar.istio.io/inject: "false"
```

Native sidecars, available on Kubernetes 1.29 and later when the mesh is
configured to use them, exit with the Job and need no opt-out.

Running the chart inside a service mesh is not validated yet. Init containers
that reach PostgreSQL or ClickHouse before the sidecar is ready can stay in
`Init` with a classic sidecar. Test injection in a non-production namespace first.

## PostgreSQL bootstrap Job

A Job's pod template cannot change in place, so the bootstrap Job's name includes
a hash of its pod inputs. Setting labels or annotations that reach it renames the
Job once, and Helm replaces it. The Job runs once more, as it does on every new
chart version, which is harmless. Installs that never set these maps keep their
Job name.
