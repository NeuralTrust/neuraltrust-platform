# Changelog

All notable changes to the `neuraltrust-platform` umbrella chart are tracked in this file. The chart follows semantic versioning at the chart level (`Chart.yaml#version`).

## [Unreleased]

## [v2.11.10] — 2026-08-24

### Added

- **AgentGateway Admin API machine credentials (ENG-1212).** The control-plane
  app mints short-lived admin tokens from a long-lived `client_id` /
  `client_secret` pair; TrustGate verifies them with a matching RSA public key.
  `global.agentgatewayM2m` is three-state like MCP OAuth: on by default in
  external/saas (off in hybrid), with a hook Job that writes a PKCS#8 private
  key and the matching public PEM into `agentgateway-m2m-keys` so nothing has to
  be configured. Both sides share one issuer helper (`https://app.<domain>`)
  because a trailing-slash mismatch 401s every service token. An operator-supplied
  pair stands the generator down; pinning only one half fails the render.
  Subcharts: `control-plane-app` `0.1.31 → 0.1.32`, `agentgateway` `0.1.47 → 0.1.48`.

## [v2.11.6] — 2026-08-18

### Fixed

- **Hybrid raw telemetry was silently dropped: metadata and raw OTLP exporters
  collided on the name `otlp`.** Both products merge the metadata and raw
  default exporter lists into one map keyed by exporter name, so the bare
  `otlp` token on both sides resolved to a single metadata exporter and raw
  payloads were never emitted — the console showed no raw rows while pods
  stayed Ready. `TELEMETRY_EXPORTERS_METADATA` / `TELEMETRY_EXPORTERS_RAW` now
  render explicitly named exporters (`metadata-otlp` plus `raw-postgres` in
  hybrid, `raw-otlp` in external/saas), so the collision cannot recur.
  TrustGate bumped `v0.36.1 → v0.37.0`.

  Hybrid also no longer dual-writes raw payloads over OTLP. Previously the
  hybrid exporter list carried `raw-otlp` alongside the postgres exporter, so
  prompts and responses left the cluster even though the documented hybrid
  promise is that only metadata is exported — and nothing read those rows
  (console raw reads for a hybrid deployment go through DataBridge to
  DataAgent's Postgres store). Hybrid raw is now `raw-postgres` only.

  The `telemetry.yaml` ConfigMaps are gone: `TELEMETRY_EXPORTERS_METADATA` /
  `TELEMETRY_EXPORTERS_RAW` are now the only exporter source, and
  `TELEMETRY_EXPORTERS_FILE` is pinned empty so the binary default
  (`config/telemetry.yaml`, absent from both images) is never probed. This
  requires **TrustGate v0.37.0+** and **TrustGuard v0.37.1+** — older images
  read only the file and would register no exporters at all, dropping every
  event while staying Ready. TrustGuard is bumped `v0.36.1 → v0.37.1`
  (`v0.37.0` never reached the prod registry; its release Trivy gate failed
  and the promote was skipped). Pin no product image below those versions
  without restoring a mounted exporters file.

### Changed

- **saas post-install NOTES name the mode and the four remote-plane endpoints.**
  `global.deploymentMode: saas` used to print the external profile and only the
  Ingress hostnames, so operators never saw DataBridge, the ingest gateway, or
  the L4 names they have to put in DNS. NOTES now print `saas (customer-owned
  central control plane)`, those two components, `databridge.<domain>:443` /
  `https://telemetry.<domain>` / `<product>-configsync.<domain>:443`, a
  `kubectl get svc` line for the LoadBalancers, and a warning when any of those
  listeners is still on a chart-minted certificate. Hybrid and external NOTES
  are unchanged.

- Image bumps: TrustGate (`agentgateway`) `v0.36.1 → v0.37.0`, TrustGuard
  `v0.36.1 → v0.37.1`, control-plane `app` `v1.141.1 → v1.141.2`. Subcharts:
  `agentgateway` `0.1.43 → 0.1.45`, `trustguard` `0.1.39 → 0.1.41`,
  `control-plane-app` `0.1.29 → 0.1.30`, `dataagent` `0.1.14 → 0.1.15`.

## [v2.11.5] — 2026-08-14

### Fixed

- **A scalar `global.controlPlane.configSyncAddr` no longer silently breaks
  every product but one.** Config-sync is per product (own L4 listener, own
  certificate SAN). The single dial host applied to every product, so the
  second product presented SNI the first product's load balancer could not
  cover and sat on last-known-good with a healthy-looking pod. Hybrid now
  fails the render when that key is set with two or more products enabled;
  set `agentgateway.configSync.endpoint` / `trustguard.configSync.endpoint`,
  or rely on DNS (`<product>-configsync.<domain>:443`).

## [v2.11.3] — 2026-08-12

### Fixed

- **Local L4 annotations no longer silently discard `loadBalancerScheme`.**
  `neuraltrust-platform.controlPlane.l4Annotations` returned a service's local
  `annotations` verbatim whenever the map was non-empty, so setting any single
  key — even the `nlb` type it was already defaulting to — dropped the scheme
  derived from `global.controlPlane.loadBalancerScheme`. The Service fell back to
  an `internal` NLB, AWS published only RFC1918 addresses, and a data plane in
  another VPC failed with `dial tcp 10.x.x.x:443: i/o timeout`; the DataAgent
  reported itself unready, which reads as an application fault rather than a
  values one. Local annotations are now merged *over* the provider defaults, the
  same way `neuraltrust-platform.ingress.annotations` already worked. An explicit
  local `service.beta.kubernetes.io/aws-load-balancer-scheme` still wins, so
  existing overrides keep their meaning.

- **SaaS telemetry no longer dies on the last hop.** The clickstack-ingest-gateway
  verified each sender's OIDC token and then forwarded to clickstack-collector
  with no credential of its own, so the collector — which enforces
  `OTLP_AUTH_TOKEN` on its receivers — rejected every batch with
  `Unauthenticated: missing or empty authorization header`. Nothing upstream
  noticed: senders got 200s, the gateway logged success, and the data was
  dropped after the last check passed. The exporter now authenticates with a
  `bearertokenauth` extension reading `OTLP_AUTH_TOKEN` from
  `clickstack-collector-secrets` (`scheme: ""`, because the collector compares
  the raw token). The hop also moved from OTLP/gRPC :4317 to OTLP/HTTP :4318:
  gRPC refuses per-RPC credentials on a cleartext connection
  (`credentials require transport level security`) and crashloops at startup.
  `clickstack-ingest-gateway.downstream.tlsInsecure` is gone — set
  `downstream.endpoint` with an explicit scheme to override.

- **Hybrid egress CA no longer drops publicly-trusted telemetry.** When
  `global.controlPlane.caSecretName` (or `global.clickstack.egress.tlsCaSecretName`)
  is set, the clickstack-egress-collector exporter used `tls.ca_file` alone,
  which replaces the system root pool in otelcol. Mixed topologies — chart-
  signed DataBridge/config-sync plus a publicly signed certificate on
  `telemetry.<domain>` — then failed with `x509: certificate signed by unknown
  authority` and silently dropped OTLP batches. The exporter now emits
  `include_system_ca_certs_pool: true` by default; set
  `global.clickstack.egress.tlsIncludeSystemCaCerts: false` only for a closed
  private-PKI trust store.
- **Egress collector no longer inherits `SSL_CERT_FILE`.** The sidecar received
  the `global.customCaCert` Go env var, and Go's `crypto/x509` treats
  `SSL_CERT_FILE` as a *replacement* for the system bundle, so
  `x509.SystemCertPool()` came back holding only the private CA. That voided
  `include_system_ca_certs_pool` and reproduced the same x509 failure from a
  second direction. The collector now trusts its private anchor solely through
  the exporter's `tls.ca_file` (still mounted from `caSecretName`), while the
  DataAgent container keeps `SSL_CERT_FILE` as before.

## [v2.11.2] — 2026-08-12

### Changed

- **Watchdog: drop bundled Prometheus; RED/freshness query ClickStack.** The
  chart no longer renders `neuraltrust-watchdog-prometheus` or injects
  `PROMETHEUS_QUERY_URL`. `runner.prometheusQueryEnv` is replaced by
  `runner.clickstack` (`address`, `database`, `usernameEnv`, `passwordEnv`).
  In `external` / `saas`, an empty address defaults to `clickhouse:9000` /
  database `otel` (same `CLICKHOUSE_*` secrets as the clickhouse health check).
  In `hybrid` the block stays empty — there is no in-cluster ClickHouse; the
  central SaaS watchdog evaluates tenant RED. Default `red-*` rows no longer
  carry `endpointEnv`; `watchdog-self-staleness` (`scrape_staleness`) is
  replaced by disabled `watchdog-self-freshness` (`otlp_freshness`).
  **Upgrade:** if you enabled `red-*` against the old bundled Prometheus, set
  `watchdog.runner.clickstack.address` (or rely on the external default) before
  or with the image bump that removes PromQL support — otherwise the new binary
  rejects checks that have no ClickStack address.

## [v2.11.1] — 2026-08-11

### Changed

- **Slim saas operator path.** Common control-plane installs need only
  `global.deploymentMode: saas` and `global.domain`. Dial names fall back from
  `global.controlPlane.domain` → `global.domain` (split-DNS still overrides).
  DataBridge defaults to HA (`replicas: 2` + peer headless); set `replicas: 1`
  for singleton. Self-signed TLS is the default for DataBridge and published
  config-sync when no `existingSecret` is set — export the CA with
  `scripts/export-controlplane-ca.sh`. On AWS, empty L4 annotations get internal
  NLB defaults via `global.controlPlane.loadBalancerScheme` (flip to
  `internet-facing` for public hybrids). Telemetry Ingress remains on by default.
  Operator runbook: [`docs/saas-mode.md` quick start](./docs/saas-mode.md#quick-start).

## [v2.9.8] — 2026-08-10

### Added

- **AUT-488: `global.deploymentMode: saas` — a customer-owned central control
  plane.** A superset of `external` that additionally serves data planes running
  in *other* clusters, for an organisation that wants one control plane and
  several independently deployed data planes. Adds two subcharts: `databridge`
  (the gRPC broker DataCore reaches remote planes through) and
  `clickstack-ingest-gateway` (authenticated OTLP edge that verifies a
  DataCore-signed RS256 JWT per batch and stamps the tenant from the verified
  claim). DataCore switches to `RESIDENCY_BACKEND=hybrid` so reads route through
  DataBridge instead of straight to ClickHouse, and the AgentGateway and
  TrustGuard config-sync listeners — ClusterIP-only in `external` — are published
  as layer-4 Services. `external` and `hybrid` renders are byte-identical to
  before; the new mode is opt-in.

- **`global.controlPlane.domain` retargets every cross-cluster endpoint.** One
  value moves DataBridge, telemetry and both config-sync listeners off
  `*.neuraltrust.ai` onto the customer's own domain, on the central cluster and on
  each remote data plane alike. Empty keeps the existing `global.saasRegion`
  behaviour. Bare hostnames only — a scheme, port or path is rejected at render.

- **Chart-generated TLS for a control plane on a private network.**
  `databridge.tls.autoGenerate`, `clickstack-ingest-gateway.ingress.tls.autoGenerate`
  and `{agentgateway,trustguard}.configSync.expose.selfSignedTls` let the chart
  mint the certificates for endpoints reached over VPC peering, Direct Connect or
  a private link, where no publicly trusted certificate is possible or needed.
  Keypairs are preserved across upgrades and reissued only when the names they
  cover change. Each option is off by default and the render fails closed with
  the alternatives spelled out, because a certificate no remote cluster trusts
  fails at handshake time rather than at install time.
  `scripts/export-controlplane-ca.sh` collects the resulting CAs into one
  `kubectl apply`-able Secret for the remote clusters, refusing to bundle
  anything that is not a parseable certificate.

- **`saas` refuses to render without `global.controlPlane.domain`.** It is the
  value that makes the install a control plane of its own; left empty every
  endpoint fell back through `global.saasRegion` to NeuralTrust's hosted domain,
  so the chart would mint certificates and publish load balancers for hostnames
  the operator does not own and point their own data planes at NeuralTrust SaaS.
  `hybrid` and `external` keep the regional fallback.

- **Telemetry token drift between DataCore and the ingest gateway is refused.**
  The issuer and audience live in two independent values blocks that agree only
  on their defaults. Overriding one alone rendered a manifest with nothing visibly
  wrong and a gateway that 401s every batch, so the umbrella — the only place that
  can see both — now compares them.

- **Remote data planes can trust a private control plane.**
  `dataagent.databridge.tlsCa` emits `TLS_CA_FILE` for the DataAgent, and
  `global.clickstack.egress.tlsCaSecretName` gives the egress collector a
  `tls.ca_file` plus the volume and mount to back it. Previously a data plane had
  no supported way to verify a control plane presenting a private certificate:
  the DataAgent value did not exist and the collector reads its trust store from
  its own config, so `global.customCaCert` alone never covered that hop.

### Fixed

- **`dataagent.databridge.tlsMode: insecure` no longer crash-loops.** The binary
  refuses to start on an insecure transport without an explicit
  `ALLOW_INSECURE_TRANSPORT`, which the chart never emitted, so the one value
  documented for a plaintext DataBridge hop was unusable.

- **`create-secrets.sh` no longer flattens a PEM into one line.** Values went
  through a trim that ends in `tr -d '\n\r'`, which is harmless for a token and
  destroys a private key: the new RS256 telemetry key was stored unparseable, so
  DataCore came up with signing off and the ingest gateway rejected every OTLP
  batch — from a Secret that looks correct in `kubectl`. Multi-line values are now
  stored byte-exact, and the generated key matches the shape the chart's own
  `genPrivateKey "rsa"` produces (PKCS#1, 4096) instead of OpenSSL 3.x's PKCS#8
  default at 2048.

- **A reissued certificate now reaches the listener that serves it.** DataBridge
  and both config-sync control planes read their keypair off disk at startup, and
  nothing they mount by `envFrom` changes when a certificate is reissued, so
  retargeting `global.controlPlane.domain` updated the Secret while the listeners
  kept presenting the old certificate — failing the handshake on exactly the name
  the reissue existed to cover. Only the chart-generated path is annotated; an
  operator-supplied or cert-manager Secret rotates where a template checksum
  cannot see it.

- **A string-typed `false` no longer switches flags on.** Flux `valuesFrom`,
  Helmfile and `--set-string` all deliver `"false"` rather than `false`, and a Go
  template reads any non-empty string as true, so
  `configSync.expose.enabled="false"` published a config-sync listener on a public
  load balancer — the unsafe direction. `expose.enabled`, `expose.selfSignedTls`,
  the two `tls.autoGenerate` flags and `tls.certManager.enabled` now coerce.

- **The DataBridge budget no longer deadlocks a node drain.** `minAvailable: 1`
  against a single replica makes `disruptionsAllowed` permanently 0: no
  replacement can be Ready before the only pod is evicted, and the eviction is
  what the budget refuses, so `kubectl drain` blocked forever on that node.

### Changed

- **The saas ingest gateway pulls its collector from the NeuralTrust registry**
  (`europe-west1-docker.pkg.dev/.../opentelemetry-collector-contrib`) rather than
  Docker Hub, so an install pulls every image from one registry, under the
  `gcr-secret` pull secret it already has, and an air-gapped cluster has one more
  entry to mirror rather than a second registry to reach. It is the same image
  and tag the hybrid egress sidecars run; `bump-images.yml` now moves all three
  together, and `scripts/release-images-markdown.sh` lists `databridge` and the
  gateway for mirroring runs. Unlike the two older collector copies,
  `global.imageRegistry` retargets this one.

## [v2.9.6] — 2026-08-06

Chart `2.9.5` → `2.9.6`. Watchdog subchart `0.3.4` → `0.3.5`.

### Fixed

- **AUT-346: watchdog OTLP follows ClickStack by `deploymentMode`.** Customer
  installs no longer default to `collector.neuraltrust.ai` +
  `OPENTELEMETRY_AUTH_TOKEN`. Empty `watchdog.telemetry.otlp.endpoint` resolves
  to a signal-neutral `:4318` base: hybrid with DataAgent egress →
  `clickstack-egress-collector` (no app auth header); external →
  `clickstack-collector` plus `OTEL_EXPORTER_OTLP_HEADERS` from
  `clickstack-collector-secrets`. Data-plane-only hybrid leaves OTLP unset
  unless overridden. Explicit `telemetry.otlp.endpoint` / `headers` remain
  break-glass.

- **`hostedExport.enabled: false` is honoured.** Sprig
  `default true $hosted.enabled` treated boolean false as empty. The watchdog
  helper and the umbrella observability-token Secret now use an explicit
  key-presence / boolean check so air-gap renders suppress the hosted endpoint,
  token Secret, and hosted-only side effects.

### Added

- **`global.saasRegion` selects the SaaS region a hybrid install dials.**
  `eu` (default, `*.neuraltrust.ai`) or `us` (`*.us.neuraltrust.ai`). One value
  now drives config-sync (`{product}-configsync.<domain>:443`), DataAgent
  DataBridge (`databridge.<domain>:443`, SNI follows), and the ClickStack egress
  exporter (`https://telemetry.<domain>`). Previously each surface hardcoded EU,
  so Americas installs silently synced and enrolled against the EU control plane
  unless the operator overrode all three independently. Any other value is
  rejected at render. Watchdog is unaffected: its OTLP stays in-cluster and
  reaches the region through the egress sidecar.

### Changed

- Watchdog logExport / log-export RBAC auto-enable when ClickStack OTLP is
  wired (external or hybrid egress), not only when hostedExport is on.

- `agentgateway.configSync.saasDomain`, `trustguard.configSync.saasDomain`, and
  `dataagent.databridge.addr` / `serverName` default to empty and derive from
  `global.saasRegion`. Explicitly set values still win, and EU renders are
  unchanged.

## [v2.9.5] — 2026-08-06

Chart `2.9.4` → `2.9.5`.

### Fixed

- **AUT-390: control-plane pull secrets honour documented precedence.**
  `controlPlane.imagePullSecrets`, the subchart root key, and
  `global.imagePullSecrets` were ignored because both control-plane charts
  defaulted `imagePullSecrets` to `"gcr-secret"`, so the first branch always
  won. Defaults are omitted; a shared helper resolves
  `controlPlane` → root → `global` → `gcr-secret`, with `"none"` /
  `["none"]` suppressing. The MCP signing-key Job uses the same helper so it
  keeps tracking the app image.

## [v2.9.2] — 2026-08-05

Chart `2.9.1` → `2.9.2`. Four chart defects against the SaaS gitops reference.

### Fixed

- **AUT-385: AlertEngine ClickHouse database is `default`, not `otel`.** The
  OTLP landing database is `otel`; DataCore materialized views write event
  tables into `default`. Every SaaS overlay already sets
  `CLICKHOUSE_DATABASE=default`. The chart default and the umbrella overlay
  now match.

- **AUT-382: AlertEngine credentials follow the subchart flag.**
  `AUTH_JWT_SECRET` and `APP_ENCRYPTION_KEY` in `platform-secrets` used
  `requires: external`, so they were minted even with
  `alertengine.enabled=false`. They now use a dedicated `alertengine` shape
  (external + enabled), mirroring the TrustLens opt-in gate.

- **AUT-386: firewall gets a shared `REDIS_URL`.** The Python client only
  reads `REDIS_URL` and otherwise falls back to `localhost:6379`, which is
  unreachable in-cluster. The chart now composes the URL from the shared
  Redis helpers into `firewall-config` (no password) or `firewall-secrets`
  (password present). ElastiCache IAM is unsupported by this client — use a
  static password or in-cluster Redis.

- **AUT-392: umbrella IAM no longer silently falls back to password auth.**
  `database.iamAuth: false` hardcodes used to ignore
  `global.postgresql.authMode=iam` on TrustGate / TrustGuard / DataCore /
  AlertEngine in external mode. Per-service `iamAuth` is now unset by
  default and inherits the global auth mode; an explicit `true`/`false`
  still wins for mixed-auth installs.

### Changed

- **Service image pins refreshed to the latest Artifact Registry tags:**
  - TrustGate / agentgateway `v0.32.1 → v0.33.2`
  - TrustGuard `v0.27.0 → v0.29.0`
  - Firewall `v2.19.0 → v2.21.0`
  - control-plane-api `v1.23.1 → v1.23.2`
  - app / control-plane-app `v1.125.2 → v1.126.0`
  - data-plane-api `v1.44.3 → v1.45.0`
  - watchdog `v0.13.2 → v0.13.4`
  - AlertEngine `v0.6.0`, DataCore `v0.15.1`, dataagent `v0.5.0`,
    clickstack-otel-collector `2.32.0` unchanged (already latest).

- Subcharts: `agentgateway` `0.1.37 → 0.1.38`, `trustguard` `0.1.34 → 0.1.35`,
  `datacore` `0.1.16 → 0.1.17`, `alertengine` `0.1.7 → 0.1.8`,
  `firewall` `2.1.6 → 2.1.7`.

## [v2.8.0] — 2026-08-01

Chart `2.7.1` → `2.8.0`. A managed external values file can now hold no
credential at all.

### Added

- **`global.postgresql.passwordSecret` — the control-plane PostgreSQL password
  from a Secret you created** (AUT-413). It was the last credential that had to
  be written into a values file, and therefore into Helm release history, because
  the chart composed connection strings while rendering and could not compose one
  out of a password it could not read. `global.postgresql.existingSecret` was the
  only escape and it suppresses `postgresql-secrets` wholesale, leaving all eleven
  keys to be hand-written.

  Set `name` (and `key`, defaulting to `POSTGRES_PASSWORD`) and the chart keeps
  writing every other key, omits `POSTGRES_PASSWORD` and `POSTGRES_PRISMA_URL`,
  and points `control-plane-app` (both containers), `control-plane-api` and
  `data-plane-api` at your Secret by reference. The parts those services already
  received are enough for the console to assemble its own connection.

  The connection-string environment entries are not rendered at all in this mode,
  rather than merely left unset. A `POSTGRES_PRISMA_URL` surviving in a preserved
  or hand-written Secret would otherwise outrank the credential you just pointed
  the chart at, and keep the old password alive through a rotation with no error
  anywhere. For the same reason the reference to your Secret is **required**: a
  typo in `key` stops the pod with `CreateContainerConfigError` instead of
  connecting without a password.

  **External only, and only against a managed instance.** Rendering fails if the
  key is combined with an inline `password` (either `global.postgresql.password`
  or the `control-plane-api` overlay) or with `existingSecret`, if the release is
  hybrid (which still composes `SENSIBLE_PG_DSN` for the TrustGate and TrustGuard
  telemetry exporters and for DataAgent — RUN-1086, AUT-397), or if
  `global.postgresql.deploy` is true (the chart's own PostgreSQL is initialised
  from that key and the bootstrap Job authenticates with it). Under
  `authMode: iam` it is ignored rather than rejected, like the per-service
  credential hooks: there is no static password to redirect.

  **Requires an app image carrying `scripts/postgres-password-url.mjs`.** The
  runtime builds its own connection from the parts, but `prisma migrate deploy`
  goes through Prisma's CLI, which reads a URL and nothing else; the init
  container now builds one with that script whenever the Secret carries none.
  An older image starts with no datasource and fails its migrations. The
  subchart's default `app` tag must be at or above that release before this key
  is usable with chart defaults — check `charts/control-plane-app/values.yaml`
  against the app release that introduced the script.

### Changed

- **External mode no longer stores `SENSIBLE_PG_DSN`.** Nothing there ever read
  it: the gateways gate that environment entry on hybrid, and DataAgent is
  hybrid-only. It was a credential written for no one, and the second reason the
  password had to be readable at render time. Hybrid is unchanged. If an overlay
  of yours reads the key out of `postgresql-secrets` in external mode, compose it
  yourself from the `POSTGRES_*` keys, which all remain.

- **`control-plane-app` receives `POSTGRES_SSLMODE` and
  `POSTGRES_CONNECTION_LIMIT` in every external release**, not only when the hook
  above is set, so the URL the app builds can match the one the chart composes.
  Both containers therefore roll on upgrade in external mode. Hybrid renders
  byte-identically to 2.7.1.

- **Upgrade note for the omitted keys.** Helm prunes `POSTGRES_PASSWORD` and
  `POSTGRES_PRISMA_URL` from `postgresql-secrets` when you adopt the hook, but
  only for keys it wrote itself. A key added out of band — by `kubectl` or by
  `create-secrets.sh` — was never in the previous manifest and survives. It is
  inert, since nothing references those entries any more, but delete it if you
  would rather not leave an old credential in the cluster.

### Fixed

- **The user is now URL-encoded in the composed Prisma URL.** The lib/pq DSN
  next to it already encoded it. No effect on any name that is a plain SQL
  identifier, which is every default.

## [v2.7.0] — 2026-07-31

Chart `2.6.0` → `2.7.0`. External mode can now be installed on the chart's own
PostgreSQL without a DBA, which is the shape every demo and smoke test takes.

### Added

- **The chart creates the roles and databases its services need when it is
  running PostgreSQL itself** (AUT-412). External mode gives each service its own
  database so it can own its own migrations, but the PostgreSQL image bootstraps
  exactly one role and one database, and nothing created the rest. A clean install
  with `deploymentMode: external` and the default `global.postgresql.deploy: true`
  therefore came up with AgentGateway, TrustGuard, AlertEngine and DataCore
  authenticating as roles that did not exist, and crash-looping — taking the
  gateway data planes down with them, since their control planes never started.
  Every generated `DB_PASSWORD` differs per install, so fixing it by hand meant
  reading four Secrets and replaying SQL.

  A `control-plane-postgresql-bootstrap` Job now runs on install and upgrade,
  connects as the bootstrap superuser and, per deployed service, creates the role
  with the password already in the Secret the pods read, then creates the database
  owned by it and grants it the `public` schema. Idempotent: an existing role has
  its password re-aligned with the Secret (which is what makes a re-install into a
  namespace with kept Secrets work), and an existing database keeps every table but
  is handed to the service as owner — on PostgreSQL 15+ that also hands it the
  `public` schema, which is what a role needs to migrate. Skipped per service
  when it is not deployed, when it uses `iamAuth`, or when it shares the bootstrap
  role — every hybrid service does, so hybrid gets no per-service role.
  `<service>.database.existingSecret` is honoured, so a pre-created Secret still
  owns the credential.

  It never touches a managed instance. The Job is not rendered at all once
  `global.postgresql.host` names another instance, `deploy` is false, or auth is
  IAM, and its host and port are templated from `global.postgresql.service`
  rather than read from `postgresql-secrets`, so no values path can aim it
  somewhere else. Turn it off with `global.postgresql.bootstrapJob.enabled: false`
  — a different key from the one AUT-334 retired, whose `mode: enabled` did reach
  managed instances.

  Hybrid still renders it, with nothing per-service to do, for the one diagnostic
  it adds: a data directory that outlived its Secret now fails in one place with
  an explanation, instead of six workloads crash-looping on a password the image
  only ever applied to an empty directory.

  Expect the Job to run for as long as PostgreSQL takes to accept connections
  (it waits up to 5 minutes), and expect the services that need a role to restart
  a few times while it does — a clean install of the full external stack on the
  chart's own datastores settles with 3-5 restarts on the workloads that were
  waiting. The Job stays in the namespace afterwards either way, so
  `kubectl logs job/control-plane-postgresql-bootstrap` says which roles it
  created; it is replaced on the next upgrade and expires after a day.

## [v2.6.0] — 2026-07-31

Chart `2.5.4` → `2.6.0`. Two minor bumps' worth of new behaviour in the
per-service datastore blocks: endpoint inheritance, and credentials that can come
from a Secret you created. Default renders are byte-identical.

### Added

- **Datastore passwords can be read from a Secret you pre-created, instead of
  being written into a values file** (AUT-411). External mode gives each service
  its own database and migrations, so their passwords differ and none can inherit
  from a single global value; until now the only way to supply them was inline,
  which also put them in Helm release history. Set
  `<service>.database.existingSecret.name` (or `.redis.existingSecret.name`) and
  the chart leaves that key out of the Secret it renders, injecting the variable
  at each Deployment with a `secretKeyRef` to yours:

  | Values path | Variable | Key defaults to |
  |---|---|---|
  | `agentgateway.database.existingSecret` | `DB_PASSWORD` | `DB_PASSWORD` |
  | `agentgateway.redis.existingSecret` | `REDIS_PASSWORD` | `REDIS_PASSWORD` |
  | `trustguard.database.existingSecret` | `DB_PASSWORD` | `DB_PASSWORD` |
  | `trustguard.redis.existingSecret` | `REDIS_PASSWORD` | `REDIS_PASSWORD` |
  | `alertengine.database.existingSecret` | `DB_PASSWORD` | `DB_PASSWORD` |
  | `datacore.database.existingSecret` | `POSTGRES_PASSWORD` | `POSTGRES_PASSWORD` |
  | `data-plane-api.dataPlane.components.api.redis.existingSecret` | `REDIS_URL` | `REDIS_URL` |

  `key` is configurable, so one Secret can hold every Aurora role under its own
  key. `data-plane-api` is the exception: it reads an assembled DSN rather than a
  password, so its key holds the whole `redis://` URL and the chart stops
  composing one into `data-plane-jwt-secret`.

  An inline `password` next to a hook is now **rejected at render** rather than
  silently ignored. The hooks are inert under `iamAuth: true`, which mints a token
  per connection, and in hybrid, where every workload takes the shared
  `postgresql-secrets` / `redis-secrets` wholesale through `envFrom` — that mode
  already had `global.postgresql.existingSecret` for the same purpose.

  Not covered: the control-plane `neuraltrust` role password
  (`global.postgresql.password`). The chart bakes it into `SENSIBLE_PG_DSN` and
  `POSTGRES_PRISMA_URL` while rendering and so must be able to read it; composing
  those strings from a Secret would require the readers to assemble their own DSN.

  Setting a hook changes nothing for existing installs — renders with every hook
  unset are byte-identical to `2.6.0`.

### Changed

- **A managed PostgreSQL or Redis is declared once on `global.postgresql` /
  `global.redis` instead of once per service.** Every runtime resolved its own
  endpoint before this: an empty `agentgateway.database.host` fell straight
  through to the literal `control-plane-postgresql`, never consulting
  `global.postgresql.host`. `port` and `sslMode` behaved the same way, and the
  Redis equivalents were worse — the umbrella hard-coded `redis` as the host for
  `agentgateway`, `trustguard` and `data-plane-api`, so there was no empty value
  left to inherit from. Pointing the platform at Aurora and ElastiCache meant
  repeating one hostname across six blocks and one cache endpoint across three,
  with each service free to drift from the others on a later edit.

  `host`, `port` and `sslMode` under `<service>.database`, and `host`, `port`,
  `username` and `tls` under `<service>.redis`, now resolve in three steps: the
  per-service value, then the matching `global.*` entry, then the previous
  in-cluster default. Per-service values keep winning, so a *per-service* overlay
  is unaffected — including the `*.database.name` / `*.database.user` that give
  each external service its own role and database, which stay per-service by
  design.

  **A global overlay is not unaffected.** If your values set
  `global.postgresql.sslMode`, `global.redis.tls`, `global.redis.username` or
  `global.redis.password` and leave the matching per-service field empty, those
  values now reach the runtime services for the first time. Before this change all
  five services rendered `sslMode: prefer` from their own default, and the gateway
  ConfigMaps and Secrets never saw the global Redis TLS flag, ACL username or
  password at all. A global `sslMode: require` against a Postgres without TLS
  fails, and `disable` silently drops TLS on an install that had been negotiating
  it opportunistically. Diff `helm template` against your live release before
  upgrading if any of those four keys appear in your values.

  Two of those keys land in ConfigMaps that the services read with `envFrom`, so a
  changed value does not alter the pod template and `helm upgrade` will not restart
  anything — the new `DB_SSL_MODE` / `REDIS_TLS` sits in the ConfigMap until a pod
  happens to restart for some unrelated reason. If you are in the global-overlay
  case above, `kubectl rollout restart` the affected Deployments yourself so the
  change lands at a moment you chose.

  Affected: `agentgateway`, `trustguard`, `alertengine`, `datacore`, `trustlens`,
  `dataagent` (its generated DSN) and `data-plane-api` (its composed
  `REDIS_URL`, which upgrades to the `rediss://` scheme when TLS is inherited).
  The control plane, `data-plane-api`'s Postgres wiring and hybrid workloads were
  already reading the global blocks through `postgresql-secrets` /
  `redis-secrets`; they are unchanged.

  To make inheritance reachable, per-service defaults that could never have been
  intended as endpoints were emptied: `port: 5432` → `""`, `sslMode: "prefer"` →
  `""`, `redis.port: 6379` → `""`, the umbrella's `agentgateway.redis.host`,
  `trustguard.redis.host` and `data-plane-api` `redis.host` `"redis"` → `""`, and
  `trustlens.database.host` `"control-plane-postgresql"` → `""`. Each resolves to
  the same value it had before, which the render suite asserts.

  **Inheritance is not gated on `global.<block>.deploy`.** An earlier cut of this
  change skipped the global step while the chart was deploying its own Postgres,
  on the theory that a leftover global host should not repoint the runtimes. That
  produced a split platform: `neuraltrust-platform.v2.hybridPg.host` already
  honours an explicit global host whatever `deploy` says, so the control plane and
  `data-plane-api` dialled the managed endpoint through `postgresql-secrets` while
  the runtimes stayed on the in-cluster Service — two halves against two
  databases. `deploy` decides whether the chart runs a datastore of its own; it
  does not decide who may read the endpoint. Scenario 17 asserts the two agree.

  One consequence worth knowing: because an empty per-service value inherits, and
  Helm renders a boolean `false` as an empty string, `--set
  <service>.redis.tls=false` does **not** switch off an inherited
  `global.redis.tls: true` — it inherits. Use the quoted form,
  `--set-string <service>.redis.tls=false` or `tls: "false"` in a values file,
  which is non-empty and wins. Same for `username`. This matches how
  `neuraltrust-platform.dataPlaneApi.redisUrl` has always resolved `tls` and
  `username`.

  `global.redis.password` needed one guard rather than a caveat: the Redis this
  chart deploys runs without `--requirepass`, so setting the password while
  `global.redis.deploy` is true and `global.redis.host` is empty now fails at
  render instead of leaving all three cache consumers unable to authenticate.

## [v2.5.4] — 2026-07-31

Chart `2.5.3` → `2.5.4`. The patch bump reflects a change to which environment
variables the config-sync workloads take from an operator-owned Secret.

### Changed

- **Operators are no longer asked to invent `CONFIG_SYNC_LKG_KEY`.** The chart has
  always generated it — `configSync.lkgKey` falls back to the key already stored in
  the chart-managed service Secret, then to `randBytes 32` — but three separate
  things insisted otherwise: `configSyncTokenEnv` pulled the key out of the
  operator's `configSync.existingSecret` alongside the token, the render-time
  validation demanded both keys, and six documents printed
  `--from-literal=CONFIG_SYNC_LKG_KEY=…` in the setup steps. An operator who only
  wanted to keep the console-issued token out of `values.yaml` had to mint an
  AES-256 key to sit next to it.

  Only the token is genuinely operator-owned: the hosted control plane verifies it.
  The LKG key is used by the runtimes purely as the AES-256-GCM key for one local
  file, the last-known-good config snapshot. That file exists only on the three
  data planes — agentgateway proxy, agentgateway MCP and the TrustGuard data plane
  — and lives on an `emptyDir`, so it is discarded on every pod restart regardless;
  a changed key costs one re-fetch and nothing else. The two control planes never
  receive `CONFIG_SYNC_DATA_PLANE_ENABLED`, so the key was inert there to begin
  with.

  `CONFIG_SYNC_TOKEN` still comes from the operator Secret. `CONFIG_SYNC_LKG_KEY`
  now arrives from the chart-managed Secret through the `envFrom` those workloads
  already carry.

  Whether the reference is emitted depends **only on Secret ownership, never on
  `lookup`**. Under `autoGenerateSecrets: false` or `preserveExistingSecrets: true`
  the chart owns no Secret, so the pre-2.6 reference is kept and
  **`CONFIG_SYNC_LKG_KEY` remains yours to supply** — unchanged behaviour for those
  two modes, and the documentation now says so instead of claiming the key is
  always generated.

  An earlier cut of this change consulted `lookup` to detect whether the operator
  Secret already carried the key. That was withdrawn: it makes the rendered pod spec
  depend on *how* you render. `helm upgrade` sees the cluster; `helm template`,
  ArgoCD, `--dry-run` and any CI identity without RBAC to read Secrets do not. Same
  values, different output, and the divergence only shows up in production.

  **Upgrade note.** If you followed pre-2.6 documentation and put your own
  `CONFIG_SYNC_LKG_KEY` into the config-sync Secret, it is no longer read on the
  default path — the generated one is used instead. This is safe: the key only
  decrypts a cache on an `emptyDir` that is discarded on restart anyway, so a
  mismatch costs one refetch. To pin a specific value, set `configSync.lkgKey`,
  which does not depend on how the chart is rendered.

  Affects five workloads: agentgateway proxy, MCP and control plane, and the
  TrustGuard data and control planes. No Secret is rewritten and no value rotates.
  Removing an `env` entry does change the pod template hash, so those five roll once
  on upgrade.

- **Validation asks for the token only.** `agentgateway config-sync requires
  CONFIG_SYNC_TOKEN and CONFIG_SYNC_LKG_KEY` becomes
  `agentgateway config-sync requires CONFIG_SYNC_TOKEN`, and the check no longer
  tests for a managed LKG key. Nothing that rendered before stops rendering; a
  hybrid install whose operator Secret holds only the token now renders where it
  previously produced pods stuck in `CreateContainerConfigError`.

### Fixed

- **The `mcp-signing-key` hook no longer breaks `helm upgrade` on IPv6 clusters.** The
  pre-install/pre-upgrade Job built the API server URL from `KUBERNETES_SERVICE_HOST`.
  On IPv6 single-stack clusters that holds a bare IPv6 literal, which is not a parsable
  URL host without brackets — and bracketing it only moves the failure to TLS, because
  the compressed address is string-compared against the certificate's expanded IP SAN.
  The Job exhausted `backoffLimit: 3`, leaving the release in `pending-upgrade`; under
  Flux's default upgrade remediation, or `helm upgrade --atomic`, that then took the
  whole release down with an automatic rollback. Either way the platform could not be
  installed or upgraded at all on IPv6. It now
  dials `kubernetes.default.svc`, which is always a certificate SAN and is
  address-family agnostic. Behaviour on IPv4 clusters is unchanged.

### Documentation

- `SECRETS.md` claimed the pair was "never auto-generated", which was false for the
  LKG key. The two are now separate rows: the token as operator-supplied, the LKG
  key as auto-generated with its threat model spelled out. `README.md` (setup step
  and troubleshooting row), `DEPLOYMENT.md`, `README-OPENSHIFT.md`,
  `docs/architecture.md`, `values-required.yaml` and
  `values-hybrid-reference.yaml.example` no longer tell operators to create the key
  on the default path.

  Each of those now carries the precondition rather than an unqualified promise:
  generation depends on the chart owning the service Secret. `SECRETS.md`
  **Pre-existing secrets (external management)** — the Vault / Sealed Secrets /
  External Secrets Operator recipe — additionally spells out that the LKG key
  becomes the operator's responsibility in that mode, which is the case an
  unqualified claim would have broken.

- **The console emits a product key the chart rejects.** Older consoles write
  `global.products.agentgateway: true` into the generated `values.yaml`, which
  fails at render with `global.products supports only trustgate, trustguard, and
  dataPlane (got "agentgateway")`. TrustGate is the only product whose product id
  and values block differ, and the wizard used one name for both. `README.md`
  step 4 now states the distinction and the rename. Fixed upstream in the console;
  the note stays because consoles and charts version independently.

- **The `DB_*` warning in `values-managed-datastores.yaml.example` read as
  unconditional.** "Do NOT add DB_* or DATABASE_URL here" is correct for the
  chart's own `postgresql-secrets`, which is what that file pre-creates, but the
  exact opposite holds when `global.postgresql.existingSecret.name` points at a
  Secret of your own: the chart then renders nothing to map from, every consumer
  `envFrom`s yours directly, and the keys must be `DB_*`. An operator on the
  `existingSecret` path who followed the header would have produced a Secret whose
  keys are never read. The header now scopes the warning and names the other
  contract.

- **Managed ClickHouse is presented as the norm when it is the exception.**
  `values-managed-datastores.yaml.example` wires ClickHouse externally in five
  places and its title implied that is the expected external shape. Managed
  PostgreSQL and Redis are the usual production choice; ClickHouse is the
  platform's own telemetry store and is normally left in-cluster. The header now
  says so and gives the exact edit to keep it in-cluster — including the Secret
  swap that `preserveExistingSecrets: true` forces, from `managed-clickhouse` to
  `clickhouse-secrets` (`admin-password`, `CLICKHOUSE_HOST`, `CLICKHOUSE_PORT`,
  `CLICKHOUSE_DATABASE`) and `clickhouse` (`CLICKHOUSE_USER`). Verified by
  rendering both variants.

- **The chart registry is public; only the images are not.** `README.md` step 5
  showed the OCI install without saying so, leaving operators to assume the pull
  Secret from step 1 also gated `helm install`.

## [v2.5.3] — 2026-07-31

Chart `2.5.2` → `2.5.3`, `data-plane-api` `1.4.8` → `1.5.0`. The minor bumps reflect
removed values keys and three templates dropped from `data-plane-api`; no image
versions change, and the other subcharts render identically, so they are not bumped.

### Removed

- **The retired v1 generation is gone from the chart.** `isV2` returned a hardcoded
  `true`, so every `if not isV2` branch had been unreachable since v1 was retired and
  every `and (eq isV2 "true") …` guard was a redundant conjunct. Both the helper and
  its 41 call sites are removed, along with the code only those dead branches reached:
  the `data-plane-api` `secrets.yaml`, `monitoring.yaml` and `trusttest-configmap.yaml`
  templates (each wholly wrapped in the dead guard, so each rendered nothing), the
  worker and kafka-connect HPA/PodDisruptionBudget blocks, the watchdog
  `v1EnabledCheckIds` overlay, and the `v1` install shape in `platform-secrets`.

  Removing those templates orphaned a few more things, cleaned up here: the
  `trusttest-config-volume` mount on `data-plane-api`, which referenced a ConfigMap
  nothing creates any more and would have left the pod in `ContainerCreating` had
  anyone set `trustTestConfig.enabled: true`; the `trustTestConfig` value and its
  helper; the `data-plane.getSecretValue` helper; the now-unread
  `files/.trusttest_config.json`; and four inline `dataPlane.secrets.*` credential
  values whose only reader was the deleted Secret template — `openaiApiKey`,
  `googleApiKey`, `resendApiKey` and `huggingFaceToken`. `huggingFaceTokenSecretName`
  goes with them, having lost its last reader; the firewall's own
  `firewall.secrets.huggingFaceToken` is a different path and is untouched.

  `dataPlaneJWTSecret` is deliberately **kept**: unlike the four above it is still an
  operator pin for the shared `DATA_PLANE_JWT_SECRET`. The `openai`/`google`/`resend`
  `*SecretName` keys also stay — the chart selects those Secrets by name and reads
  them with optional `secretKeyRef`s; it just never created them in v2. Note that
  `dataPlaneJWTSecretName`'s refs are *not* optional, so a Secret named there must
  carry both `DATA_PLANE_JWT_SECRET` and `REDIS_URL`.

  `isFull` is removed as a *name* only. It was an alias for `isExternal`, which is
  genuinely false in hybrid, so its 11 call sites now call `isExternal` directly rather
  than being dropped.

  The deleted `monitoring.yaml` also carried a `DataPlaneApiDown` PrometheusRule for a
  component v2 still ships. It never rendered, so no alert is lost in practice, but
  restoring alerting for `data-plane-api` is deliberately deferred to its own change
  rather than smuggled into a deletion.

  **This release renders byte-identical output** in hybrid, and in external differs only
  by the three deliberate removals below. Verified by diffing full renders against the
  previous release across hybrid, external, and external with TrustLens and AlertEngine
  enabled.

- **`FORCE_V2_UI` and `controlPlane.components.app.config.forceV2Ui`.** The console
  deleted the variable and its UI-version toggle, so the chart was setting an
  environment variable nothing read. Removing the value is safe: it had no effect.

- **`TRUSTGATE_JWT_SECRET` and `resend-invite-sender` from `control-plane-secrets`**,
  plus the `trustgateJwtSecret` and `resendInviteSender` values and the registry row
  aliasing the former to `SERVER_SECRET_KEY`. Both keys were written but never read —
  `TRUSTGATE_JWT_SECRET`'s only consumer was the v1 env block, and v2 uses
  `SERVER_SECRET_KEY` (delivered to the console as `AGENTGATEWAY_JWT_SECRET`) for
  gateway integration.

  **Upgrade note:** the first upgrade to this version *removes* these keys from a live
  `control-plane-secrets`, and removes `TRUSTGATE_JWT_SECRET` from a live
  `platform-secrets` as well. Existing external installs carry all of them today.

  A **fresh** install never had the `platform-secrets` copy: the retired row required
  the long-dead `v1` install shape, so a cluster-less render omits it and the render
  suite asserts that. Clusters upgraded through this release line nevertheless carry
  it, because the registry keeps any key the live Secret already holds regardless of
  what the current shape asks for. Once acquired, the key stayed pinned by that
  carry-over; deleting the row is what releases it. Both copies were observed on live
  external and hybrid clusters and both are gone after the upgrade.

  Nothing rotates and no workload restarts: there is no `secretKeyRef` to either key
  anywhere in the chart, which is also why no dual-key migration window applies here.

  The two copies of `TRUSTGATE_JWT_SECRET` hold **different values**, so treat them
  separately. The `platform-secrets` copy was an `aliasOf: SERVER_SECRET_KEY` and
  mirrors that key exactly, so nothing is lost — `SERVER_SECRET_KEY` survives with the
  same value. The `control-plane-secrets` copy is independently generated and has no
  surviving twin. If anything outside the chart reads *that* one, copy it out before
  upgrading:

  ```bash
  kubectl get secret control-plane-secrets -o jsonpath='{.data.TRUSTGATE_JWT_SECRET}' | base64 -d
  ```

  If you pre-create Secrets with `preserveExistingSecrets: true`, you no longer need
  `TRUSTGATE_JWT_SECRET` in `control-plane-secrets`.

### Known issue

- The console still reads five v1-era variables the chart has never emitted in v2, and
  falls back to values that are wrong for a self-hosted install: `TRUSTGATE_JWT_SECRET`
  to the literal `secret`, the three `TRUSTGATE_*_URL` variables to SaaS hostnames, and
  `CONTROL_PLANE_SCHEDULER_URL` to `localhost:3001`. The chart cannot fix these by
  emitting values — the URLs address v1 API paths that v2 services do not serve, and no
  scheduler component exists in v2 — so the fallbacks are being removed on the console
  side. Deleting the dead chart block does not change this behaviour either way.

## [v2.5.0] — 2026-07-30

### Added

- **AgentGateway config-sync gRPC now runs over TLS in external mode.** TrustGate's
  control plane refuses to build its config-sync listener without a keypair once
  `APP_ENV` is a deployed value, and its data plane refuses to dial that listener in
  cleartext. TrustGuard has provisioned both sides for some time; AgentGateway had
  neither, and stayed reachable only because the chart never set `APP_ENV`, leaving the
  binary on its `dev` default. The chart now sets `agentgateway.config.appEnv`
  (default `production`, matching TrustGuard) and generates a self-signed CA plus a
  server certificate whose SANs cover the control-plane Service DNS names. The admin
  pod serves it; the proxy and MCP data planes verify against the generated CA instead
  of dialing insecurely. Preserved across upgrades through `lookup` and
  `helm.sh/resource-policy: keep`, so it is never rotated.

  Configured under `agentgateway.configSync.grpcTls` (`autoGenerate`, `existingSecret`,
  `durationDays`). Skipped when an operator supplies `existingSecret`, when
  `global.preserveExistingSecrets` is set, or when `config.appEnv` is not a deployed
  value. Hybrid is unaffected: it runs no control plane and already dialed SaaS with
  verification on.

- **`TRUSTGUARD_PUBLIC_URL` on the console.** Collector, WAF and SDK setup snippets
  build their evaluate URL from this variable, and the console deliberately refuses to
  print in-cluster hostnames in customer-facing instructions — so `TRUSTGUARD_URL`
  could not stand in for it and the snippets rendered with no endpoint at all. It is
  now derived as `https://trustguard.<global.domain>`, matching the TrustGuard chart's
  data-plane ingress, and overridable through
  `control-plane-app.controlPlane.components.app.config.trustguardPublicUrl`.

- **`AWS_REGION` for RDS IAM on the two Go gateways.** AgentGateway and TrustGuard mint
  a SigV4 token per connection, but were the only IAM-authenticated services the chart
  never told which region to sign for — AlertEngine, DataCore and the control plane all
  set it. IRSA supplies a role and a token file, not a region, so the SDK's default
  chain resolved nothing and the pool failed to initialise unless the region happened to
  be present in node-level configuration. Emitted from `global.postgresql.awsRegion`,
  overridable per chart via `<chart>.database.awsRegion`, and only when `iamAuth` is on.

### Fixed

- **Hybrid Redis TLS never reached AgentGateway.** TrustGate reads `REDIS_TLS_ENABLED`
  while TrustGuard reads `REDIS_TLS`. The shared `redis-secrets` stores the canonical
  `REDIS_TLS` and is injected wholesale, so setting `global.redis.tls` secured
  TrustGuard and left both AgentGateway data planes connecting in plaintext to a
  TLS-only Redis, with nothing in the manifest to show it. The flag is now renamed at
  the AgentGateway consumption sites, the same way Postgres variables are. Emitted only
  when `global.redis.tls` is set, so a subchart-level `redis.tls` still wins where the
  global is unset.

- **A boolean `global.redis.tls` aborted the render.** The value reached `b64enc`
  unconverted, failing with `wrong type for value; expected string; got bool`, so the
  setting only ever worked when quoted. It is now converted explicitly.

- **`configSync.grpcTls.autoGenerate: false` was silently ignored.** The condition read
  the value through sprig's `default`, which treats boolean `false` as empty and so
  resolved an explicit `false` back to `true`. Both gateway charts now resolve it with
  `hasKey`. Turning generation off without supplying an `existingSecret` produces a
  control plane that cannot start, so the chart also rejects that combination at render
  time rather than at rollout.

## [v2.4.1] — 2026-07-30

### Changed

- **`postgresql-secrets` stores one canonical name per fact.** The Secret previously
  carried `DB_*` copies of `POSTGRES_HOST`/`_PORT`/`_USER`/`_PASSWORD`/`_DB`/`sslMode`,
  plus `DATABASE_URL` (a byte-identical copy of `POSTGRES_PRISMA_URL`) and the
  `DATABASE_AUTH_MODE` / `DATABASE_IAM_AUTH` flags, which had no reader in any service
  the chart deploys. Those keys are no longer written; the canonical family is
  `POSTGRES_*` plus `POSTGRES_SSLMODE`, `POSTGRES_LOGIN`, `SENSIBLE_PG_DSN`, and
  `POSTGRES_PRISMA_URL` (external only — hybrid has no Prisma reader). This supersedes
  the "`postgresql-secrets` carries DB_* aliases alongside `POSTGRES_*`" contract
  described under v2.2.0.
- **Hybrid workloads receive only the datastore variables they read.** AgentGateway
  (proxy + MCP), TrustGuard's data plane and DataAgent took `postgresql-secrets`
  wholesale via `envFrom`, so a pod got eighteen datastore variables to read six and
  no manifest showed which. They now map explicit `env` entries through the new
  `neuraltrust-platform.postgresEnv` helper, which renames the canonical keys to the
  `DB_*` names the Go services read. DataAgent gets only `DATABASE_URL`, from
  `SENSIBLE_PG_DSN`. Effective values are unchanged, and external mode is untouched.
- **Hybrid honours `global.postgresql.authMode: iam`.** `POSTGRES_LOGIN`, the only IAM
  switch TrustGate and TrustGuard read, was emitted solely from the external branch of
  the per-service ConfigMaps, so a hybrid install against an IAM-authenticated Postgres
  silently attempted password authentication regardless of any flag. It now comes from
  the shared Secret, driven by the global auth mode. External mode still takes it from
  the per-service `database.iamAuth` flag; reconciling those two sources is tracked
  separately.
- **Removed dead IAM variables** `DB_IAM_AUTH` and `DB_AUTH_MODE` from the AgentGateway
  and TrustGuard ConfigMaps. Neither binary reads them — `DB_AUTH_MODE` is read by
  AlertEngine, a different service.
- **`preserveExistingSecrets: true` keeps the Postgres `envFrom` passthrough.** Renaming
  is only safe for a Secret the chart writes. That mode skips both `postgresql-secrets`
  emitters, so the live Secret is whatever an earlier release wrote — under the old key
  names — and referencing `POSTGRES_SSLMODE` there would have resolved nothing. Because
  the references are optional the loss would have been silent: `DB_SSL_MODE` would have
  disappeared and the gateways would have fallen back to their built-in `disable`,
  turning an install configured for opportunistic TLS into a plaintext one. An
  operator-supplied `global.postgresql.existingSecret.name` already took the passthrough
  path and is unaffected.

### Removed

- `global.postgresql.existingSecret.keys` — an unused map whose defaults described the
  retired `DB_*` layout. Naming an `existingSecret` injects it with `envFrom`, so its
  keys are used under your own names and were never remapped.

Keys left over in an existing `postgresql-secrets` are inert (nothing references them)
and are removed on the next upgrade that rewrites the Secret.

### Documentation

- **Stopped describing Firewall as optional — it is not.** Firewall renders
  whenever TrustGuard does and cannot be switched off: rendering
  `values-trustguard.yaml.example` with `firewall.enabled`,
  `firewall.firewall.enabled`, and `trustguard.firewall.enabled` all set to
  `false` still produces the gateway and all five workers, byte-identical to the
  default. Since Firewall's CPU workers are the largest memory consumer in the
  data path, an operator who trusted those flags to trim a deployment would have
  under-provisioned. The chart READMEs and the docs-site Firewall, External,
  feature-flags, overview, and secrets pages now state the dependency and mark
  the three flags as no-ops. AlertEngine, which *is* genuinely optional
  (`alertengine.enabled: false` removes it), is called out separately. Two
  unrelated errors on the Firewall page were corrected in passing: `toolguard`
  was listed as a worker when it is a deprecated gateway path forwarding to
  `indirect-prompt-injections`, and the image pin was quoted as `v2.14.0` when
  the chart ships `v2.16.0` — the page now refers to the chart-pinned tag rather
  than restating a version that drifts.
- **Removed Watchdog and TrustLens from operator-facing documentation.** Both are
  still under development, so the READMEs, `SECRETS.md`, `VALUES_SCENARIOS.md`,
  `docs/architecture.md`, and `docs/observability.md` no longer present them as
  deployable options. **`values-watchdog.yaml.example` and
  `values-self-monitoring.yaml.example` are deleted**, and the `watchdog:` block
  is dropped from `values-observability-self-hosted.yaml.example` — pipelines
  passing the removed files with `-f` must drop them. The subcharts themselves
  are untouched and still default to `enabled: false`; past release entries in
  this changelog are left as written.
- **`README-EXTERNAL.md` now lists the external component set in full** instead
  of describing it as "everything hybrid runs, plus". The list is grouped by
  TrustGate, TrustGuard and Firewall, control plane, analytics, and datastores,
  and matches a render of `values-external.yaml.example` with every
  `global.products` flag off — external ignores those flags, so the set is
  fixed.
- **Documented both image-pull paths, and the two places mirroring silently
  breaks.** Operators receive a registry key from NeuralTrust and can either pull
  directly or mirror into their own registry, but the docs only described
  mirroring. Two rendering facts were verified and are now written down:
  `global.imageRegistry` does **not** rewrite the OTel collector repositories
  (`global.clickstack.egress.image.repository` on hybrid,
  `global.observability.collector.image.repository` when observability is on),
  so an air-gapped hybrid install leaves the DataAgent egress sidecar pulling
  from the NeuralTrust registry; and `global.imagePullSecrets` only reaches the
  chart's own PostgreSQL and Redis, leaving the twelve product workloads on the
  `gcr-secret` default. `global.imagePullSecrets: ["none"]` is documented as
  unsupported — it does not clear the product references and renders a Redis
  pull secret literally named `none`.
- **Dropped the `v2-` qualifier from packaged example filenames.** v2 is the only
  topology this chart ships, so the qualifier carried no information. Files were
  renamed with `git mv`: `values-v2-external.yaml.example` →
  `values-external.yaml.example`, `values-v2-hybrid.yaml.example` →
  `values-hybrid.yaml.example`, `values-v2.yaml.example` →
  `values-hybrid-reference.yaml.example`, `values-v2-managed-datastores.yaml.example`
  → `values-managed-datastores.yaml.example`, and `docs/platform-v2.md` →
  `docs/architecture.md`. Pipelines or overlays that pass the old names with `-f`
  must be updated. The seven duplicated "Legacy v1" sections collapse into a
  one-line footnote linking the final v1.14.x release.
- **Added `README-EXTERNAL.md` and rewrote `README.md` around a working hybrid
  quick start.** The previous quick start omitted the config-sync Secrets, so an
  operator who copied its values block hit
  `agentgateway config-sync requires CONFIG_SYNC_TOKEN and CONFIG_SYNC_LKG_KEY`
  at install. The README now walks through the four operator-supplied Secrets,
  the rendered hostnames, and the validation errors each missing value produces.
  `README-EXTERNAL.md` covers the self-hosted path end to end: bootstrap admin
  Secret, component inventory, ClickHouse sizing, and air-gap requirements.
- **Fixed dangling references to five example files that do not exist.**
  `values-all-deployed.yaml.example`, `values-openshift-ingress.yaml.example`,
  `values-aws-ipv6.yaml.example`, `values-minimal-observability.yaml.example`,
  and `values-watchdog-gmp.yaml.example` were cited across the README, OpenShift
  guide, `DEPLOYMENT.md`, `VALUES_SCENARIOS.md`, and `docs/observability.md`.
  Each is replaced with the inline values it would have contained.
- **Corrected the OpenShift quick start.** `values-openshift.yaml` selects only
  the platform and topology, so installing with it alone fails on
  `v2 hybrid requires at least one product`. Documented commands now layer it
  over `values-required.yaml`.
- **Documented what `create-secrets.sh` no longer covers.** It does not create
  `platform-secrets`, and the `postgresql-secrets` it writes omits `SENSIBLE_PG_DSN`,
  `POSTGRES_SSLMODE`, `POSTGRES_LOGIN` and the mode flags while still writing the
  retired `DATABASE_URL`. This only affects installs where the chart does not manage
  those Secrets (`preserveExistingSecrets`, `autoGenerateSecrets: false`, or an
  `existingSecret`), since otherwise the chart writes the full canonical family.
- **Corrected the login CAPTCHA guidance, which overstated the risk.** Earlier text
  in `SECRETS.md`, `docs/neuraltrust/deployment/external.mdx`, and the quick start
  warned that three failed logins would lock an operator out of a self-hosted
  console unless `TURNSTILE_SECRET_KEY` was supplied. Reading the app shows the
  entire path is gated on the build-time `NEXT_PUBLIC_TURNSTILE_SITE_KEY`: with no
  site key in the image the widget never renders, `/api/validateTurnstile` is never
  called, and the secret is never read. The counter is also client-side with a
  30-minute TTL, so even in the misconfigured case the state clears itself. The two
  `<Warning>` blocks are removed and `SECRETS.md` now documents the key as optional,
  needed only when an image carries a site key and you want the challenge enforced.
- **Documented a `NEXT_PUBLIC_*` trap in `control-plane-app`.** These variables are
  inlined at image build time
  and cannot be set from Helm at all, so the SCIM tenant URL and SCIM `meta.location`
  fall back to the hosted default on a self-hosted install — with the surfaces that are
  *not* affected spelled out, since most SSO setup screens derive their origin from the
  browser and are correct.
- **Propagated the `postgresql-secrets` key change to the remaining docs.**
  `docs/architecture.md` and the "Platform v2 secrets" table in `SECRETS.md` still
  described the retired `DB_*` aliases and claimed every hybrid workload `envFrom`'s
  the Secret, contradicting the corrected PostgreSQL section a few hundred lines
  above. Both now describe the canonical `POSTGRES_*` family and distinguish stored
  key names from the environment variables a container receives.
- **`SECRETS.md` leads with the Secrets the chart will not create.** Its quick start
  opened with "No action required", which is false for any hybrid install running
  TrustGate or TrustGuard. A new "Secrets you must create" section lists them per mode
  before any reference material. The duplicated "Firewall integration" section was
  merged into the Firewall reference, and `clickhouse-secrets` — rendered in external
  mode but previously undocumented — was added.
- **Documented values-file layering.** `VALUES_SCENARIOS.md` now states that later
  `-f` wins, that overlays do not install on their own, and marks per file whether it
  works as a base. `values-hybrid-reference.yaml.example` selects no products and was
  listed alongside files that do.
- **Corrected the public docs site.** `overview.mdx` and `deployment-models.mdx`
  described DataAgent as optional in Hybrid, though the mandatory OTLP path runs
  through its co-located egress collector. `secrets.mdx` documented a retired
  interface (`dataagent.tenantId`, `dataagent.enrolmentTokenExistingSecret`,
  `global.clickstack.existingSecret`) and now shows the per-product
  `configSync.existingSecret` and `dataagent.enrolment.existingSecret` keys the chart
  actually reads.
- **Fixed the product-flag defaults in `docs/architecture.md`.** The component table
  read "opt-in (default on)" for TrustGate, TrustGuard, and the data-plane API, while
  the same document correctly stated that chart defaults are all `false`.
- **Documented the operator-supplied PostgreSQL Secret passthrough.** Key renaming is
  only possible for a Secret the chart writes. Under
  `global.postgresql.existingSecret.name` or `preserveExistingSecrets: true`, workloads
  fall back to `envFrom` and the Secret's keys become environment variables verbatim —
  so an operator-supplied Secret must use the `DB_*` names the applications read, the
  opposite of the canonical `POSTGRES_*` layout. No document stated this, which made
  the new "never use `DB_*`" guidance actively wrong for that path.

## [v2.4.0] — 2026-07-30

### Added

- **Cross-service credentials the chart never set.** Three credentials had
  to match on two sides but were absent from the chart, so operators set them by hand
  or the services fell back to built-in defaults. `platform-secrets` now carries
  `MCP_OAUTH_CLIENT_SECRET` (the app is the authorization server, TrustGate the
  pre-registered client, and the value must be identical), `MCP_OAUTH_SIGNING_KEY`, and
  `AUTH_SECRET_KEY`.
- **MCP OAuth is on by default in external installs.** `global.mcpOAuth.enabled` is a
  three-state gate: unset auto-enables where the chart can deliver both halves,
  `true` demands it and fails the render with the reason when it cannot, `false` never
  enables it. It stays off in hybrid, which has no in-cluster app. A pre-install hook
  Job generates the RSA signing key in-cluster (PKCS#8, which Helm cannot produce)
  using the app image, so a fresh install needs no `openssl` step; the key lands in its
  own `mcp-oauth-signing` Secret and is never replaced once present. Supplying your own
  key still works and is adopted as-is.
- **`generate: install` policy** for keys that encrypt data at rest. `AUTH_SECRET_KEY`
  is generated only on a fresh install and adopted on upgrade — handing an existing
  release a new value would make already-encrypted SSO client secrets and SMTP
  credentials undecryptable.

### Migration notes

- Nothing rotates. Every new key resolves from `global.platformSecret.values`, then the
  live Secret, then the legacy per-service Secret, before generating.
- `AUTH_SECRET_KEY` stays **absent** on upgrades by design; adopt one deliberately by
  pinning it once existing ciphertext no longer matters.
- Do not `kubectl apply` the output of `helm template` against a live release: Helm
  renders every template as an install, so the output carries freshly generated
  credentials.

## [v2.3.10] — 2026-07-30

### Added

- **Shared `platform-secrets` Secret.** Credentials read by two or more
  services — a signing key on one side and its validator on the other — were generated
  independently by each subchart, so the two copies could hold different values and
  produce silent `401`s. One `platformSecret.registry` now resolves each logical key
  once and every consumer references it through `neuraltrust-platform.secretRef`.
  `requires` shapes keep an install down to the keys its services actually read, so a
  hybrid install carries far fewer keys than an external one.

### Migration notes

- **Nothing rotates on upgrade.** Each key is adopted from whatever the live
  per-service Secret already holds.
- **The legacy per-service Secrets keep being written for one release**, so a rollback
  still finds the values it expects. They will be dropped in a later release; until
  then both copies exist and agree.
- Two keys that must match are emitted from one resolved value via `aliasOf`
  (`AUTH_SECRET`/`NEXTAUTH_SECRET`, `SERVER_SECRET_KEY`/`TRUSTGATE_JWT_SECRET`), so they
  can no longer drift.
- Opt out entirely with `global.platformSecret.enabled: false`;
  `global.preserveExistingSecrets: true` implies it. In both cases references fall back
  to the legacy Secrets rather than dangling.

## [v2.3.9] — 2026-07-30

### Fixed

- **Bootstrap superadmin password exposed as a plain env value.** `control-plane-app`
  received `ONPREM_SUPERADMIN_PASSWORD` inline, where `kubectl describe pod` shows it.
  It is now always injected through `secretKeyRef`. Prefer
  `global.superadmin.existingSecret.name` over the inline
  `global.superadmin.email`/`password`, which still enter Helm release history.

### Added

- **Selectable email provider.** `control-plane-app` is the only sender; the transport
  is chosen by `global.email.provider` (`resend` | `ses` | `smtp`) and a misconfigured
  provider fails at render time instead of silently dropping mail. Static SES keys are
  emitted only when supplied, so the pod IAM role (IRSA) keeps working by default. The
  chart skips any name an operator already set through `extraEnv`, because emitting the
  same env name twice makes Kubernetes reject the strategic-merge patch.

## [v2.3.6] — 2026-07-29

### Changed

- **Operator docs and chart comments:** replaced “SaaS” / internal overlay
  wording with hybrid / hosted control plane / external language; trimmed
  verbose maintainer comments in values and templates.
- **Cluster sizing guidance:** documented default Hybrid / External worker
  shapes and that chart resource defaults are a starting point to right-size
  (`docs/sizing.md`, README, DEPLOYMENT).
- **Hybrid network allowlist:** documented egress hostnames/IPs for
  config-sync and DataBridge, plus the NeuralTrust inbound source IP
  (`docs/hybrid-network.md`).

## [v2.3.4] — 2026-07-27

### Breaking

- **Data Plane API PostgreSQL schema defaults to `public`.** Deployments can
  override `data-plane-api.dataPlane.components.api.database.postgresql.schema`
  with a pre-created schema whose application role has `USAGE` and `CREATE`.
  The migration no longer executes `CREATE SCHEMA` or requires database-level
  `CREATE`.

## [v2.3.3] — 2026-07-27

### Fixed

- **Control Plane App migrations with hardened images.** The `init-db`
  container invokes the image-bundled Prisma CLI directly because production
  images no longer include `npm` or `npx`. It also applies versioned migrations
  without running the production-unsafe `prisma db push`. Control Plane App
  subchart is now `0.1.18`.

## [v2.3.1] — 2026-07-23

### Breaking

- **Positive hybrid product selection.** `global.products.trustgate`,
  `trustguard`, and `dataPlane` default to `false`. Hybrid installs must set
  at least one to `true` (fail-fast otherwise). External mode ignores these
  flags and always deploys the full product stack. Firewall has no
  independent gate and always follows TrustGuard. Chart.yaml no longer uses
  static product `condition:` entries — templates gate via a mode-aware
  selector. Product selector is `global.products.trustgate`; component
  configuration stays under `agentgateway:` (K8s names `agentgateway-*`,
  image repository `agentgateway`).
- **One DataAgent per enabled product.** Enrolment moves under
  `agentgateway.dataagent` / `trustguard.dataagent` (mixable `-f` overlays).
  Dual installs preserve `dataagent` for TrustGate and add
  `dataagent-trustguard`. Only the primary agent owns
  `clickstack-egress-collector`. Top-level `dataagent` now contains shared
  runtime defaults only. Hybrid fail-closed requires a DataAgent only when
  TrustGate and/or TrustGuard is selected (red-teaming skips it).

### Added

- Positive product slice examples: `values-trustgate.yaml.example`,
  `values-trustguard.yaml.example`, `values-red-teaming.yaml.example`
  (no all-off baseline). `values-required.yaml` selects all three products.
- Render scenarios for hybrid no-selection failure, standalone / pairwise /
  all-product mixes, and external full-stack compatibility without product
  flags.
- **External on-prem superadmin.** Optional bootstrap admin on
  control-plane-app. Prefer `global.superadmin.existingSecret.name` (keys
  default to `ONPREM_SUPERADMIN_EMAIL` / `ONPREM_SUPERADMIN_PASSWORD`);
  inline `email` + `password` remains as an escape hatch (enters Helm
  release history). Ignored in hybrid (app does not render). Control Plane
  App subchart `0.1.13 → 0.1.14`.

### Changed

- Image bumps (local AR latest): control-plane-app `v1.107.1`, firewall
  `v2.15.0`, agentgateway `v0.18.1`, trustguard `v0.19.1`. Control Plane App
  subchart `0.1.14 → 0.1.15`.
- **Firewall workers new module set.** Dropped the retired
  `toolguard-worker` (`src.workers.toolguard` removed in firewall v2.15.0+)
  and added `indirect-prompt-injections-worker`
  (`src.workers.indirect_prompt_injections.app:app`). Gateway
  `/v1/toolguard` remains a deprecated compatibility shim that forwards to
  IPI. Portable CPU defaults, Recreate strategy, and disabled HPA/PDB/OTel
  are unchanged. Firewall subchart `2.1.3 → 2.1.4`.
- DataAgent subchart is a Helm **library** (v0.1.11); umbrella templates render
  deterministic instances. TrustGate omits `TRUSTGUARD_BASE_URL` when Guard
  is not selected in hybrid.
- **DataAgent identity from enrolment JWT only.** Hybrid DataAgent readiness
  requires enrolment credentials, not `tenantId`. The agent derives
  `tenant_id` from `ENROLMENT_TOKEN`; DataBridge matches `instance_id` from
  the same JWT. Helm no longer exposes `tenantId` / `TENANT_ID` or
  `instanceId` / `INSTANCE_ID` for DataAgent.
- AgentGateway `0.1.28`, TrustGuard `0.1.26`, Firewall `2.1.2`, data-plane-api
  `1.4.4`, and Control Plane App `0.1.11` consume the mode-aware product
  contract; Firewall no longer exposes an independent enable flag.

## [v2.2.1] — 2026-07-21

### Breaking

- **Remove AgentGateway `GATEWAY_DISCOVERY_MODE` / `config.gatewayDiscoveryMode`.**
  The app always supports dual discovery: exact primary hosts
  (`gateway.<domain>` / `mcp.<domain>`) require the gateway header; wildcard
  slug hosts (`*.llm.<domain>` / `*.mcp.<domain>`) need none. Empty base
  domains always yield `GATEWAY_BASE_DOMAIN=llm.<global.domain>` /
  `MCP_BASE_DOMAIN=mcp.<global.domain>`, and empty `additionalHosts` always
  auto-add the matching Ingress/Route wildcards. Set
  `config.autoWildcardHosts: false` to keep exact hosts only. Drop the mode
  key from overlays; explicit `gatewayBaseDomain` / `mcpBaseDomain` /
  `additionalHosts` remain authoritative.

### Changed

- **Bump registry images (latest from Artifact Registry).** control-plane-api
  `v1.23.0 → v1.23.1`, control-plane-app `v1.101.6 → v1.102.1`, agentgateway
  `v0.16.1 → v0.17.0` (includes dual-discovery chart work). Matching subchart
  `values.yaml` / `appVersion` / Chart dependency patch bumps. trustguard,
  datacore, alertengine, and other bumpable images were already at the latest
  AR tags from the local refresh.

### Fixed

- **DataAgent hybrid `DATABASE_URL` uses `SENSIBLE_PG_DSN`.** The shared
  `postgresql-secrets` `DATABASE_URL` includes Prisma's `connection_limit`,
  which lib/pq sends as a Postgres GUC and breaks DataBridge residency
  queries (`unrecognized configuration parameter "connection_limit"`).
  Hybrid DataAgent now overrides `DATABASE_URL` from `SENSIBLE_PG_DSN`.
- **Hybrid ClickStack egress sidecar binds dual-stack by default.** The
  DataAgent-co-located OTel collector health/OTLP endpoints used
  `0.0.0.0`, which is IPv4-only and breaks kubelet probes and Service
  routing on IPv6-only clusters. Defaults to `global.clickstack.egress.listenHost: "::"`
  (emitted as `[::]:port`). Override to `0.0.0.0` only if needed.
- **Umbrella otel-collector binds dual-stack by default.** Health, OTLP,
  and prometheus exporter endpoints now honor
  `global.observability.collector.listenHost` (default `::` → `[::]:port`).

## [v2.2.0] — 2026-07-21

### Changed

- **Bump registry images (latest from Artifact Registry).** control-plane-app
  `v1.101.0 → v1.101.6`, agentgateway `v0.15.0 → v0.15.1`, trustguard
  `v0.18.0 → v0.18.2`, datacore `v0.13.0 → v0.13.1`. Matching subchart
  `values.yaml` / `appVersion` / Chart dependency patch bumps. Other bumpable
  images were already at the latest AR tags.

## [v2.1.1] — 2026-07-21

### Breaking

- **Hybrid product OTLP is mandatory with no opt-out.** Remove
  `global.clickstack.enabled: false` and `global.clickstack.egress.enabled`.
  Hybrid uses the DataAgent-co-located egress collector (enrolment-backed);
  there is no direct SaaS `authToken` / `existingSecret` bearer path on apps.
  Air-gapped or local-only product telemetry requires
  `global.deploymentMode: external`.
- **Rename DataAgent enrolment values to match config-sync.** Use
  `dataagent.enrolment.token` and `dataagent.enrolment.existingSecret`
  (same ritual as `*.configSync.token` / `existingSecret`). Legacy
  `enrolmentToken` / `enrolmentTokenExistingSecret` are rejected.

### Changed

- **Hybrid config-sync is on by default** (mode-derived; subchart
  `enabled: null`). Overlays set `existingSecret` only; do not restate
  `enabled: true`. Explicit `enabled: false` remains for Postgres-managed
  configuration.
- **AgentGateway subdomain discovery auto-derives base domains and wildcards.**
  With `gatewayDiscoveryMode: subdomain`, empty base domains yield
  `GATEWAY_BASE_DOMAIN=llm.<global.domain>` /
  `MCP_BASE_DOMAIN=mcp.<global.domain>`, and empty `additionalHosts` auto-add
  `*.llm.<domain>` / `*.mcp.<domain>` on Ingress/Routes. Explicit
  `additionalHosts` remain authoritative.
- **Bump `agentgateway` / `trustguard` subcharts `0.1.21 → 0.1.22`** for the
  subdomain routing helpers and mode-derived config-sync defaults.
- **Bump `dataagent` subchart `0.1.5 → 0.1.6`** for the enrolment value rename.

## [v2.1.0] — 2026-07-20

### Changed

- **Bump `opentelemetry-collector-contrib` to `0.156.0`.** Shared default for the
  umbrella OTel Collector and the hybrid ClickStack egress sidecar. Upstream
  0.154–0.156 breakages do not affect the chart's OTLP / oauth2client pipelines
  (Prometheus `IgnoreScopeInfoMetric` is a scrape-attribute behavioral change only).
- **Bump registry images (latest from Artifact Registry).** control-plane-app
  `v1.99.1 → v1.101.0`, agentgateway `v0.14.0 → v0.15.0`, trustguard
  `v0.17.0 → v0.18.0`, dataagent `v0.3.0 → v0.4.0`, datacore `v0.12.1 → v0.13.0`.
  Matching subchart `values.yaml` / `appVersion` / Chart dependency patch bumps.
- **Include `opentelemetry-collector-contrib` in `bump-images.yml`.** Auto-detect
  bare `X.Y.Z` tags from AR; sync `global.observability.collector.image.tag`,
  `global.clickstack.egress.image.tag`, and the matching template fallbacks.

## [v2.0.7] — 2026-07-20

### Changed

- **Document the complete hybrid outbound contract.** SaaS-managed
  AgentGateway and TrustGuard data planes use separate config-sync gRPC
  channels; enrolled DataAgent uses DataBridge gRPC; product events go directly
  to the SaaS ClickStack OTLP endpoint (no in-cluster collector in hybrid).

### Fixed

- **Make hybrid config-sync fail closed and preserve its runtime cache.**
  AgentGateway and TrustGuard can read SaaS tokens from dedicated existing
  Secrets, reject enabled config-sync without a token source, and mount writable
  last-known-good storage when pod root filesystems are read-only.
- **Point the Watchdog `otel-collector` check at the umbrella collector.**
  Health URL and selector now target `otel-collector` /
  `app.kubernetes.io/component=otel-collector` in the release namespace.
  Default `enabledCheckIds` no longer include `clickhouse` (hybrid has none);
  external overlays should opt in explicitly.

### Removed

- **`global.selfMonitoring.enabled`.** The flag was never consumed by templates;
  enable `global.observability.enabled` and `watchdog.enabled` explicitly
  instead.

## [v2.0.3] — 2026-07-18

### Added

- **AgentGateway wildcard public routing.** Proxy and MCP Ingress (AWS/Azure/GCP)
  accept opt-in `ingress.dataPlane.additionalHosts` /
  `ingress.mcp.additionalHosts` (for example `*.llm.<domain>` /
  `*.mcp.<domain>`), rendered as extra rules and TLS hosts. On OpenShift,
  `ingress.resourceType: auto|route` renders native Routes with
  `wildcardPolicy: Subdomain` for `*.` hosts (exact hosts use `None`). Set
  `resourceType: ingress` to keep Kubernetes Ingress on OpenShift. Pair with
  `config.gatewayDiscoveryMode: subdomain` and `gatewayBaseDomain` /
  `mcpBaseDomain`. Admin stays exact-host only. See
  `values-agentgateway-wildcard.yaml.example` and `docs/platform-v2.md`.

### Fixed

- **External ClickStack product logs path.** AgentGateway and TrustGuard export
  business telemetry as OTLP **logs** via `otlploghttp.WithEndpointURL`, which
  takes the URL path verbatim. External mode now sets
  `OTEL_EXPORTER_OTLP_ENDPOINT` to
  `http://clickstack-collector.<ns>.svc.cluster.local:4318/v1/logs` again
  (matching TrustGate/TrustGuard SaaS overlays). The earlier base-URL-only value
  caused POSTs to `/` and left `otel.otel_logs` empty while runtime traces still
  filled `otel_traces` via `OPENTELEMETRY_*` host:port endpoints.

## [v2.0.2] — 2026-07-17

### Changed

- **DataCore `v0.12.1` + RDS IAM auth.** Bumped the default image to `v0.12.1`.
  The `datacore` subchart now supports `database.iamAuth` / `database.awsRegion`
  (`POSTGRES_LOGIN=aws`, omits `POSTGRES_PASSWORD`, requires TLS SSL modes).

### Fixed

- **DataCore Postgres wiring (external).** DataCore now requires `POSTGRES_HOST` /
  `POSTGRES_DATABASE` (and related `POSTGRES_*` env) for deployment metadata unless
  `RESIDENCY_ALLOW_STUB=true`. The `datacore` subchart emits those from
  `datacore.database.*`, stores `POSTGRES_PASSWORD` in `datacore-secrets`, and
  defaults to the own `datacore` role/database (same pattern as AlertEngine).

## [2.0.0] — 2026-07-17

**Official GA** of the NeuralTrust Platform **v2-only** umbrella chart.

This is the customer-facing `2.0.0` release. Legacy v1 (TrustGate/Kafka) is
maintained solely on the `v1.14.x` release line — pin
`helm install ... --version ~1.14.0` for v1 clusters. Do **not** upgrade a v1
install in place to this chart.

> **Tag note.** An earlier git tag named `v2.0.0` pointed at a TrustGate-era
> chart. This GA **reclaims** chart version `2.0.0` for the v2-only stack.
> Pre-GA interim numbers (`2.1.x` / `2.2.0` / `1.16.x` on `main`) are superseded
> by this release.

### Highlights

- **Two topologies, one chart:** `global.deploymentMode: hybrid | external`.
- **Hybrid install UX:** one Postgres block, one Redis block, one ClickStack
  token — AgentGateway + TrustGuard in-cluster; control planes stay in SaaS.
- **External mode:** full self-hosted control/data planes, DataCore,
  ClickStack collector, and AlertEngine with per-service datastore/IAM overlays.
- **Stable Kubernetes names** after the physical chart split (`control-plane-api`,
  `control-plane-app`, `data-plane-api`, `firewall`, `watchdog`, shared Secrets /
  PVCs).

### Removed

- **v1 stack and generation switch.** Deleted `charts/trustgate`, `charts/kafka`,
  the Kafka helper/connection templates, the control-plane `scheduler`, the
  legacy data-plane workers / Kafka Connect / ClickHouse-config / Postgres-config
  templates, and the v1-only `values-external-services.yaml.example`. Removed the
  `global.platformVersion` / `confirmV2Migration` value switches and the v1
  migration detection; the `isV2` / `isFull` render guards collapse to always-true
  aliases (retained so subchart templates compile without a mass rewrite).
  `global.deploymentMode` is now `hybrid | external` only (the deprecated `full`
  alias is gone).
- **v1 secret provisioning.** `create-secrets.sh` no longer creates the v1
  `trustgate-secrets` (`SERVER_SECRET_KEY`, per-service `DATABASE_*`) or the
  external-Kafka SASL/TLS Secrets. `TRUSTGATE_JWT_SECRET` (the control-plane ↔
  gateway integration key) remains in `control-plane-secrets`.
- **v1 automation rows/inputs.** `scripts/release-images-markdown.sh` and
  `.github/workflows/bump-images.yml` drop the TrustGate, Kafka, scheduler,
  data-plane-workers, and Kafka-Connect images/inputs and now reference only the
  unprefixed v2 chart paths.

### Fixed

- **TrustGuard → Firewall env wiring.** Policy plugins (`prompt_guard`,
  `toxicity`, `prompt_moderation`) require `NEURAL_TRUST_FIREWALL_BASE_URL` +
  `NEURAL_TRUST_FIREWALL_SECRET_KEY`. The chart never set them, so sandbox
  evaluation failed with `neuraltrust base url is required` even when the
  Firewall Service was healthy. TrustGuard now emits the in-cluster
  `http://firewall.<ns>.svc.cluster.local` URL and mounts `firewall-secrets`
  `JWT_SECRET` (gated by `trustguard.firewall.enabled`, default true — keep in
  sync with `firewall.enabled`). Subchart `0.1.14 → 0.1.15`.
- **Restore `templates/postgresql/secrets.yaml` fallback.** With the
  control-plane split, the `autoGenerateSecrets: false` path stopped emitting
  `postgresql-secrets` while in-cluster Postgres still referenced it. The
  umbrella fallback Secret is back (mutually exclusive with
  `platform-secrets.yaml`).
- **control-plane-app external-only gate.** Templates now honor
  `control-plane-app.enabled` (same pattern as `control-plane-api`), so hybrid
  installs no longer render the App Deployment/Service/Ingress against missing
  `control-plane` SA / secrets. Subchart `0.1.4 → 0.1.5`.
- **External ClickStack OTLP auth + endpoint for TrustGuard / AgentGateway.**
  In-cluster ClickStack requires `Authorization` on OTLP HTTP; external mode
  never wired it, so TrustGuard traces failed with `401 … missing or empty
  authorization header`. The chart now emits
  `OTEL_EXPORTER_OTLP_HEADERS=authorization=<token>` on
  `clickstack-collector-secrets` (same value as `OTLP_AUTH_TOKEN`) and mounts
  that key on TrustGuard control-plane **and** data-plane, plus AgentGateway
  admin/proxy/MCP. Also drops the erroneous `/v1/logs` suffix from
  `OTEL_EXPORTER_OTLP_ENDPOINT` so the OTel SDK does not POST traces to
  `/v1/logs/v1/traces`. Subcharts `trustguard` / `agentgateway`
  `0.1.13 → 0.1.14`, `clickstack-otel-collector` `0.1.2 → 0.1.3`. If
  `global.preserveExistingSecrets=true`, add the header key to the existing
  collector Secret once (token must match `OTLP_AUTH_TOKEN`).
- **Control-plane RDS IAM env contract.** `authMode: iam` now emits the keys the
  apps actually read — `POSTGRES_CONNECTION_TYPE=aurora` (Python API) and
  `POSTGRES_AUTH_MODE=iam` (Next.js app) — plus `AWS_REGION` from
  `controlPlane.components.postgresql.awsRegion` / `global.postgresql.awsRegion`.
  The app
  init-db container mints a short-lived token via `scripts/postgres-iam-url.mjs`
  before Prisma migrate (requires app image v1.93.0+). Subcharts
  `control-plane-api` / `control-plane-app` `0.1.0 → 0.1.1`.

### Changed

- **Physical chart split and rename.** `charts/neuraltrust-control-plane` split
  into `charts/control-plane-api` and `charts/control-plane-app` (external only);
  the v2 read shim extracted from `charts/neuraltrust-data-plane` into
  `charts/data-plane-api`; `charts/neuraltrust-firewall` → `charts/firewall` and
  `charts/neuraltrust-watchdog` → `charts/watchdog`. All live Kubernetes resource
  names, Secrets, PVCs, and selectors are preserved (`control-plane-api`,
  `control-plane-app`, `data-plane-api`, `control-plane-postgresql`,
  `postgresql-secrets`, `redis`, `neuraltrust-watchdog`, …) via hardcoded names /
  `fullnameOverride`.
- **Flattened values contract.** `control-plane-api:`, `control-plane-app:`,
  `data-plane-api:`, `firewall:`, and `watchdog:` are the canonical subchart value
  roots in `values.yaml`. Removed the `neuraltrust-*` alias keys and the merge
  helpers, plus deprecated `hybridRoleLayout` / `sharedWriter` / `initJob`
  no-ops and the `infrastructure.postgresql` / `infrastructure.redis` mirrors.
  `global.postgresql` / `global.redis` are the sole datastore deploy gates.
- **v2-only docs and rules.** README, deployment/observability/SECRETS docs,
  NOTES, examples, and Cursor rules rewritten as v2-only with a support note
  pointing v1 users at the `v1.14.x` line. `Chart.yaml` set to `2.0.0`.
- **v2-only render suite.** `scripts/test-helm-render.sh` rewritten to cover
  minimal hybrid, hybrid external datastores, external per-service IAM, the new
  value roots, absence of the v1 stack, and stable Kubernetes names after the
  physical moves.
- **External control-plane-app defaults `AUTH_EMAIL_FORCE_ENV=true`.** On-prem
  installs prefer platform env email (`AUTH_EMAIL_PROVIDER` / SES / SMTP /
  Resend) over per-org `TeamAuthConfig` in the DB. Opt out with
  `control-plane-app.controlPlane.components.app.config.authEmailForceEnv: "false"`.
  Subchart `control-plane-app` `0.1.1 → 0.1.2`.
- **control-plane-app always sets `DEPLOYMENT_MODE=external`.** Matches the
  Next.js app contract (`saas` | `external`); unset would resolve to SaaS
  behavior. Safe to hardcode because this subchart only renders in external
  mode. Subchart `control-plane-app` `0.1.3 → 0.1.4`.
- **Image bumps (AR latest for GA):** control-plane-app `v1.97.0`,
  agentgateway `v0.10.3`, trustguard `v0.13.3`, datacore `v0.12.1`,
  data-plane-api `v1.41.0`, control-plane-api `v1.23.0`, firewall `v2.14.0`,
  watchdog `v0.13.1`, alertengine `v0.4.5`, dataagent `v0.1.2`. Subchart patches
  for this refresh: `agentgateway` `0.1.14 → 0.1.15`, `trustguard`
  `0.1.15 → 0.1.16`, `datacore` `0.1.6 → 0.1.7`.

## [v2.1.0] — 2026-07-16

> **Pre-release note (superseded by [2.0.0]).** Interim tag cut before customer
> GA. The hybrid contract below is historical; install chart `2.0.0` for the
> official v2-only release.

Chart 2.1.0 simplifies the Platform v2 hybrid contract to "one Postgres block, one Redis block, one ClickStack token" and reorganizes umbrella-side value overlays around unprefixed root keys.

### Highlights

- **Shared hybrid datastores.** `global.postgresql` and `global.redis` now drive a single connection contract for every hybrid workload (AgentGateway, TrustGuard, DataAgent, `data-plane-api`). Defaults: user `neuraltrust`, database `neuraltrust`, passwordless in-cluster Redis. The chart renders `postgresql-secrets` and `redis-secrets` and every hybrid workload `envFrom`'s them.
- **No hybrid init Job.** `templates/v2-postgres-init.yaml` is removed. Application migrations own their tables (already namespaced: `trustgate_migration_versions` / `trustguard_migration_versions`). `hybridRoleLayout` / `sharedWriter` / `initJob.mode` are retained as deprecated no-ops so 2.x values keep parsing. External / managed PostgreSQL is now owned by the DBA (or Terraform); the chart never runs `CREATE USER` from Helm.
- **Mandatory ClickStack token, fixed SaaS endpoint.** `global.clickstack` moves from opt-in dual-write to always-on OTLP export with `endpoint` / `protocol` / TLS fixed by the chart. Operators supply only the bearer token — inline via `authToken` or by pointing `existingSecret.name` at a pre-created Secret. Rendering fails when neither is set. `global.clickstack.enabled: false` is the air-gap escape hatch.
- **In-cluster PostgreSQL moved to the umbrella.** `control-plane-postgresql` Deployment/PVC/Service and the `postgresql-secrets` fallback Secret now live under `templates/postgresql/` (mirroring `templates/redis/`). Kubernetes resource names, PVC identity, and gating switches are preserved bit-for-bit.
- **Unprefixed root-value aliases.** New helpers merge overlays keyed under `control-plane` / `data-plane` / `firewall` / `watchdog` on top of the legacy `neuraltrust-*` subchart-name keys (alias wins per key). Umbrella-side reads honor either form; subchart-scoped values (component images, replica counts) still live under the legacy key until the physical chart rename lands.

### Migration notes (v2 hybrid, from earlier 2.x drafts)

- Earlier unreleased drafts used a shared-writer `trustdata` role/database and an init Job. Fresh installs use `neuraltrust` / `neuraltrust`. If you already provisioned `trustdata`, seed `global.postgresql.user` / `database` / `password` (or `existingSecret`) accordingly.
- `trustdata-secrets` is not emitted. `postgresql-secrets` carries DB_* aliases alongside `POSTGRES_*`.
- Hybrid requires `global.clickstack.authToken` (or `existingSecret.name`), or `global.clickstack.enabled: false` for air-gap.
- Deprecated no-ops (`hybridRoleLayout`, `sharedWriter`, `initJob.mode`) still parse but are ignored.
- v1 and v2 external are unchanged; external keeps per-service overlays.

### Changed

- **Umbrella now owns in-cluster PostgreSQL (AUT-337).** The `control-plane-postgresql` Deployment, PVC (`control-plane-postgresql-pvc`), Service, and the `postgresql-secrets` fallback Secret moved from `charts/neuraltrust-control-plane/templates/postgresql/` to the umbrella `templates/postgresql/` directory (mirroring the existing `templates/redis/` layout). Resource names, selectors, PVC name, and gating (`global.postgresql.deploy` canonical; `neuraltrust-control-plane.infrastructure.postgresql.deploy` legacy) are preserved bit-for-bit so live clusters upgrade in place. New umbrella helpers `neuraltrust-platform.postgresql.{deploy,componentConfig,imagePullSecrets}` drive the moved templates. The umbrella `platform-secrets.yaml` (autoGenerate default path) remains the primary owner of `postgresql-secrets`; the new `templates/postgresql/secrets.yaml` preserves the pre-existing autoGenerate=false fallback under umbrella ownership (guards are mutually exclusive, so `postgresql-secrets` is never rendered twice). Existing umbrella-level helpers (`neuraltrust-platform.postgresql.{host,port,user,database}`) are refactored to source values through the new dual-key resolver so operator overlays under either the legacy or unprefixed alias keep working. Subchart `neuraltrust-control-plane` `1.2.48 → 1.2.49` (templates removed only). Render coverage: `scripts/test-helm-render.sh` scenario 41 asserts umbrella ownership + preserved names.
- **Unprefixed root-value aliases for control-plane and data-plane (AUT-338, AUT-339).** Umbrella-side templates now read control-plane values through the new `neuraltrust-platform.controlPlaneValues` helper (and data-plane values through `neuraltrust-platform.dataPlaneValues`). Each resolver deep-merges three inputs, alias winning per key: kebab-case unprefixed (`control-plane:` / `data-plane:`) overlays camelCase (`controlPlane:` / `dataPlane:`) which overlays the legacy `neuraltrust-control-plane:` / `neuraltrust-data-plane:` subchart-name key. Operators can now overlay individual umbrella-scoped values (e.g. `control-plane.controlPlane.secrets.openaiApiKey`, `data-plane.dataPlane.secrets.dataPlaneJWTSecretName`) without restating the full defaults tree. The subcharts themselves are still fed from the legacy keys (Helm subchart injection has not moved), so chart-consumed values (component images, replica counts, per-service knobs) continue to live under `neuraltrust-control-plane:` / `neuraltrust-data-plane:` — the alias bridge covers the umbrella-scoped reads only until the physical chart split lands. `templates/platform-secrets.yaml` and `neuraltrust-platform.dataPlane.components` now route through the resolvers so the JWT secret name, control-plane secret leaves, and dataPlaneApi lookups all honor the alias. Render coverage: `scripts/test-helm-render.sh` scenarios 42 (control-plane alias + precedence) and 43 (data-plane alias).
- **Unprefixed root-value aliases for firewall and watchdog (AUT-340).** Same pattern as AUT-338/339, extended to the last two `neuraltrust-*`-scoped subchart keys still consumed by the umbrella. New helpers `neuraltrust-platform.firewallValues` and `neuraltrust-platform.watchdogValues` deep-merge two inputs (alias winning per key): unprefixed `firewall:` / `watchdog:` overlays the legacy `neuraltrust-firewall:` / `neuraltrust-watchdog:` subchart-name key. `templates/platform-secrets.yaml` and `templates/otel-collector/secret.yaml` now route firewall/watchdog reads through the helpers, and `neuraltrust-platform.watchdogEnabled` (which gates the OTel Collector's Prometheus exporter port) is refactored to consume the resolver so `watchdog.enabled: true` and `neuraltrust-watchdog.enabled: true` are equivalent at the umbrella. Chart.yaml `condition:` is a static value path and cannot call helpers, so the subchart-loading gate stays on `neuraltrust-firewall.firewall.enabled` / `neuraltrust-watchdog.enabled` for BC — enabling/disabling the physical subcharts still requires the legacy key, and subchart-scoped values (component images, replica counts, RBAC, checks) still live under the legacy key until the physical chart split lands. Live Kubernetes resource names are unchanged (e.g. watchdog keeps `fullnameOverride: neuraltrust-watchdog`). `.cursor/rules/component-registry.mdc` updated to document the pattern for future subchart renames; `values-watchdog.yaml.example` documents the alias. Render coverage: `scripts/test-helm-render.sh` scenarios 44 (firewall alias + precedence + legacy-only BC) and 45 (watchdog alias flips umbrella gate + legacy BC).
- **BREAKING (v2 hybrid): ClickStack OTLP dual-write is always on with a fixed SaaS endpoint.** The `global.clickstack` block moves from opt-in dual-write with an operator-supplied endpoint to a mandatory-token, chart-owned pipeline. Endpoint (`https://clickstack-collector.neuraltrust.ai/v1/logs`), protocol (`http/protobuf`), and TLS (system-root verification; `OTEL_EXPORTER_OTLP_INSECURE` is no longer emitted for the default route) are FIXED for hybrid; operators supply ONLY the bearer token — either inline via `global.clickstack.authToken` OR by pointing `global.clickstack.existingSecret.name`/`key` (default key `OTEL_EXPORTER_OTLP_HEADERS`) at a pre-created Secret carrying the full header. `templates/validate-values.yaml` fails render when v2 hybrid ClickStack is enabled and neither is set. The legacy `endpoint`/`protocol`/`insecure` overrides remain honored (deprecated) so existing values files keep parsing. The `enabled` key becomes an **air-gap escape hatch** (`enabled: false` skips the OTLP dual-write entirely; raw payloads still land in Postgres for DataAgent). When `existingSecret.name` is set the data-plane Deployments mount `OTEL_EXPORTER_OTLP_HEADERS` directly from the operator-owned Secret via `secretKeyRef` and the chart-managed `agentgateway-secrets` / `trustguard-secrets` skip the key — recommended for `preserveExistingSecrets=true` and GitOps flows where `lookup` is not available. External mode's always-on in-cluster ClickStack wiring is unchanged and ignores this block. New helpers `neuraltrust-platform.clickstack.{defaultEndpoint,defaultProtocol,usesExistingSecret,otlpHeadersEnv}` and updated `clickstackHybridEnabled`/`clickstack.otlpEnv`/`clickstack.otlpHeaders`. **Migration:** hybrid installs coming from earlier 2.x drafts that were on the opt-in dual-write already have the token; installs that did not enable ClickStack must add `global.clickstack.authToken` (or `existingSecret.name`), or set `global.clickstack.enabled: false`, before upgrading. Render coverage added to `scripts/test-helm-render.sh` (scenario 38p rewritten: default-on + token-required + fixed endpoint + `enabled=false` escape hatch + existingSecret pattern). Subcharts: `agentgateway` `0.1.11 → 0.1.12`, `trustguard` `0.1.11 → 0.1.12`.

- **BREAKING (v2 hybrid): one shared PostgreSQL + Redis connection contract.** The hybrid data-plane stack (AgentGateway, TrustGuard, DataAgent, `data-plane-api`) now connects to ONE Postgres role owning ONE Postgres database and ONE Redis, driven by the new top-level `global.postgresql` / `global.redis` blocks. The blocks expose `deploy`, `host`, `port`, `user`, `database`, `password`, `sslMode`, and `existingSecret` (for PostgreSQL — `password`, `username`, `tls`, `existingSecret` for Redis), and the chart renders a shared `postgresql-secrets` Secret carrying both the legacy `POSTGRES_*` keys and DB_* aliases (`DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, `DB_NAME`, `DB_SSL_MODE`, `SENSIBLE_PG_DSN`, `DATABASE_URL`) plus a new shared `redis-secrets` Secret (`REDIS_HOST`/`REDIS_PORT`/`REDIS_PASSWORD`/`REDIS_USERNAME`/`REDIS_TLS`). Every hybrid workload `envFrom`'s these Secrets — per-service `agentgateway-secrets`/`trustguard-secrets` no longer emit `DB_PASSWORD`, `SENSIBLE_PG_DSN`, or `REDIS_PASSWORD`, and per-service ConfigMaps stop emitting `DB_*` / `REDIS_HOST` / `REDIS_PORT` in hybrid. Defaults: `user: neuraltrust`, `database: neuraltrust`, `sslMode: prefer`, in-cluster Redis is passwordless. External deployments keep their per-service overlays (`agentgateway.database` / `trustguard.database` / `alertengine.database` / `trustlens.database`) and IAM auth paths untouched. The `neuraltrust-platform.postgres.host` and `v2.dbName`/`v2.writerUser` helpers now route hybrid callers through `global.postgresql`. **Migration:** hybrid installs from earlier drafts pick up new defaults on upgrade; if the previous install used the shared-writer `trustdata` role/database, seed `global.postgresql.user: trustdata` / `global.postgresql.database: trustdata` / `global.postgresql.password: <existing>` before upgrading, or set `global.postgresql.existingSecret.name` to point at your pre-provisioned Secret.
- **BREAKING (v2 hybrid): `templates/v2-postgres-init.yaml` is removed.** Hybrid no longer runs a Helm-managed schema/role init Job — the shared `neuraltrust` role owns the shared `neuraltrust` database, and application migrations (already namespaced: `trustgate_migration_versions`, `trustguard_migration_versions`) create their tables directly. `neuraltrust-platform.postgresql.hybridRoleLayout` now always returns `"separate"`, and `global.postgresql.hybridRoleLayout` / `sharedWriter` / `initJob.mode` are retained only as deprecated no-ops so existing values files keep parsing. The parent-managed `trustdata-secrets` Secret is no longer emitted (superseded by `postgresql-secrets` DB_* aliases + `SENSIBLE_PG_DSN`). External/managed PostgreSQL setup is now owned by the DBA/Terraform (or an out-of-band job); the chart never runs `CREATE USER` or `ALTER ROLE ... PASSWORD` from Helm.
- **`global.redis.deploy` is authoritative in v2.** `neuraltrust-platform.v2Redis.enabled` now prefers `global.redis.deploy` (canonical), falling back to `infrastructure.redis.deploy` (legacy mirror) for BC. v1 (`global.platformVersion: v1`) and v2 external remain unchanged.
- **`clickstack-otel-collector` defaults to the NeuralTrust AR mirror.** The subchart image repository is now `europe-west1-docker.pkg.dev/neuraltrust-app-prod/nt-docker/clickstack-otel-collector` (tag `2.30.1`) instead of the public `docker.clickhouse.com` registry, with `imagePullSecrets: gcr-secret` by default. The image helper strips the AR prefix under `global.imageRegistry`, and `bump-images.yml` auto-detects tags from AR (bare `X.Y.Z`). Subchart `0.1.1 → 0.1.2`.
- **Release image refresh.** Bumped registry defaults to control-plane app `v1.94.1`, data-plane API `v1.41.0`, TrustGuard `v0.12.1`, DataCore `v0.8.0`, and AlertEngine `v0.4.5`. Matching subchart defaults, template fallbacks, chart versions, and dependency metadata remain synchronized.
- **Hybrid `data-plane-api` defaults to PostgreSQL — no ClickHouse required.** The `data-plane-api` image (`v1.41.0`) can read its evaluation/analytics store from PostgreSQL, so v2 **hybrid** no longer needs a ClickHouse at all. A new `neuraltrust-platform.dataPlaneApi.sqlBackend` helper resolves the store: empty/`auto` → PostgreSQL in v2 hybrid (reusing the umbrella-managed PostgreSQL), ClickHouse in v2 external and v1. Existing hybrid installs that opted into an **external** (dotted) ClickHouse host still resolve to ClickHouse for backward compatibility, and an explicit `neuraltrust-data-plane.dataPlane.components.api.database.backend: postgres|clickhouse` overrides either way (rollback / advanced). Because the shim no longer hard-requires ClickHouse, `neuraltrust-platform.dataPlaneApiV2.enabled` now renders the API in hybrid whenever the resolved backend is PostgreSQL. In PostgreSQL mode the Deployment emits `SQL_DATABASE=postgres` + the five `POSTGRES_*` vars (host/port/user/database default to the `postgresql-secrets` Secret; password is always a `secretKeyRef`, never inlined; scalar `api.database.postgresql.{host,port,user,database}` values override for external PostgreSQL, alongside a configurable `existingSecret` name/key map) and runs a `postgres-migrations` initContainer that applies the bundled idempotent schema (`charts/neuraltrust-data-plane/files/postgres/init-db.sql`, byte-identical to the `data-plane-api` source) under a transaction-scoped advisory lock via `pg_isready` + `psql -v ON_ERROR_STOP=1`. The ClickHouse initContainer/env/`clickhouse-secrets`/`clickhouse-init-job` now render **only** in ClickHouse mode, so a default hybrid install carries no `data-plane-api` ClickHouse metadata. Render-time validation rejects unknown backends and hybrid `clickhouse` without an external host. New helpers `neuraltrust-platform.dataPlane.components`/`dataPlaneApi.sqlBackend`/`dataPlaneApi.postgresConfig`/`dataPlaneApi.postgresEnv`; new ConfigMap `data-plane-postgres-init`; the copied SQL is kept in sync with `data-plane-api` manually for now (automated cross-repo sync is a follow-up). Render coverage added to `scripts/test-helm-render.sh`. Data-plane subchart `1.2.50 → 1.3.2`.

### Fixed

- **AgentGateway / TrustGuard Redis IAM: emit the apps' real ElastiCache contract.** `redis.iamAuth=true` previously only set `REDIS_IAM_AUTH=true`, which neither binary reads. Both services authenticate via `REDIS_LOGIN=aws` and require `REDIS_CACHE_NAME` (+ `REDIS_USERNAME`, TLS, and optionally `REDIS_AWS_SERVERLESS`). The chart now emits `REDIS_LOGIN=aws`, `REDIS_CACHE_NAME` (from `redis.cacheName`), and `REDIS_AWS_SERVERLESS` (from `redis.awsServerless`), still omitting the static Redis password. Subcharts: `agentgateway` / `trustguard` `0.1.10 → 0.1.11`.
- **AlertEngine RDS IAM is live (was documented as pending).** AlertEngine `v0.4.0+` authenticates with `DB_AUTH_MODE=iam` and requires `AWS_REGION`. The chart already emitted `DB_AUTH_MODE`/`DB_IAM_AUTH` when `database.iamAuth=true`; it now also emits `AWS_REGION` from `database.awsRegion`. Subchart `alertengine` `0.1.2 → 0.1.3`.

## [v2.0.1] — 2026-07-15

> **Release accounting.** The unreleased changes ship as chart `2.0.0`.
> Platform v2 hybrid is the default; explicit `global.platformVersion: v1`
> remains the legacy escape hatch.

### Fixed

- **In-cluster v2 Redis: disable protected-mode so cross-pod clients can connect.** The umbrella-managed Redis (`templates/redis/deployment.yaml`) started as `redis-server --port 6379 …` with no password and no `bind`, leaving Redis' default `protected-mode yes` in effect. In that state Redis accepts a TCP connection from a non-loopback peer and then immediately drops it, so `agentgateway-proxy`, `agentgateway-mcp`, and `trustguard-data-plane` crash-looped at boot with `failed to connect to redis … write: broken pipe`, while the pod itself looked healthy (its `redis-cli ping` readiness probe runs over loopback, which protected-mode always allows). The Deployment now passes `--protected-mode no`; the cache stays passwordless and reachable only through its ClusterIP Service (consistent with the chart's other in-cluster datastores). Render coverage added to `scripts/test-helm-render.sh` (scenario 36).

### Added

- **Hybrid drops in-cluster ClickHouse; `data-plane-api` shim is external-ClickHouse-only in hybrid.** In v2 **hybrid** the analytics store lives in NeuralTrust SaaS (data planes write raw telemetry to Postgres, DataAgent bridges it out; optionally also OTLP to ClickStack), so a local ClickHouse had nothing writing to it. `neuraltrust-platform.clickhouseAllowed` now renders the in-cluster ClickHouse subchart only in **v1 (any mode)** and **v2 external** — never v2 hybrid (was: always). Because the temporary `data-plane-api` read shim hard-requires a ClickHouse, `neuraltrust-platform.dataPlaneApiV2.enabled` now additionally requires, **in hybrid only**, that it be pointed at an EXTERNAL ClickHouse — a dotted `neuraltrust-data-plane.dataPlane.components.clickhouse.host`; with the default bare host the shim (and its `clickhouse-secrets`/`clickhouse-init-job`) stays OFF. v2 external and v1 are unchanged (in-cluster ClickHouse + shim as before). Operators who want local analytics in hybrid set a dotted external ClickHouse host in a private overlay. Render coverage: scenario 36 updated (no ClickHouse/shim in hybrid default) + new scenario 36-ext (external ClickHouse opts the shim in). **Upgrade note (pre-release 2.0):** a hybrid install that previously rendered the empty in-cluster ClickHouse + shim will have them removed on upgrade.
- **Hybrid ClickStack OTLP export (opt-in dual-write).** A new `global.clickstack` block lets a v2 **hybrid** deployment ALSO stream AgentGateway + TrustGuard product data (`meta`/`raw`) over OTLP to a ClickStack collector, in addition to the default Postgres raw path that DataAgent bridges to SaaS (dual-write, per the collector's own `docs/agentgateway-integration.md` migration model). Default OFF — existing hybrid installs are byte-identical. When `enabled=true`, the `*-telemetry` ConfigMaps gain `metadata-otlp` + `raw-otlp` exporters alongside `sensible-pg`, the `*-env-vars` ConfigMaps emit `OTEL_EXPORTER_OTLP_ENDPOINT`/`OTEL_EXPORTER_OTLP_PROTOCOL` (+ optional `OTEL_EXPORTER_OTLP_INSECURE`), and the bearer token (`global.clickstack.authToken`) is stored ONLY in the `agentgateway-secrets`/`trustguard-secrets` Secret as `OTEL_EXPORTER_OTLP_HEADERS` (never the plaintext ConfigMap); with `preserveExistingSecrets=true` the header is read back from the existing Secret. `endpoint` is required when enabled (rendering fails otherwise) and must be the collector's OTLP/HTTP URL (the public route exposes `:4318` only). External mode's always-on ClickStack wiring is unchanged. New helpers `neuraltrust-platform.clickstackHybridEnabled`/`clickstack.otlpEnv`/`clickstack.otlpHeaders`; render coverage added to `scripts/test-helm-render.sh` (scenario 38p). Subcharts: `agentgateway` `0.1.7 → 0.1.8`, `trustguard` `0.1.6 → 0.1.7`.
- **Release image refresh.** Updated the registry-backed 2.0 defaults to AgentGateway `v0.6.0` (Redis auth fix), TrustGuard `v0.11.1`, DataCore `v0.3.0`, DataAgent `v0.1.1`, control-plane app `v1.92.0`, control-plane API `v1.23.0`, data-plane API `v1.39.0`, TrustGate `v1.28.4`, Firewall `v2.14.0`, Watchdog `v0.13.1`, and Redis Stack `7.2.0-v20`. Matching subchart defaults, template fallbacks, chart versions, dependency metadata, and the image-bump workflow remain synchronized. TrustLens stays disabled and now requires an explicit image tag because no release image is published yet.
- **Data-plane API: Redis-backed evaluation-progress cache.** `data-plane-api` now defaults its `EVALUATION_PROGRESS_BACKEND` explicitly instead of relying on the image's own `redis` default, which required a `REDIS_URL` the chart never provided. v1 pins `kafka` (already deployed and wired — no new dependency). v2 pins `redis`, wired to the same umbrella-managed Redis AgentGateway/TrustGuard use (in-cluster service `redis`, or `infrastructure.redis.external` when `infrastructure.redis.deploy=false`) via new `neuraltrust-data-plane.dataPlane.components.api.redis` values (host/port/db/password/username/tls, plus AWS ElastiCache IAM auth — fully supported by `data-plane-api`, unlike the chart-prepared-only IAM flags on AgentGateway/TrustGuard). Redis 6+ ACL (username) auth is already supported by `data-plane-api` via the standard `redis://` URL, so no application change was needed. `REDIS_URL` (which may carry a password) is generated into the existing `data-plane-jwt-secret` Secret, never the plaintext env ConfigMap. Redis-backed API pods no longer receive the legacy `KAFKA_BOOTSTRAP_SERVERS=kafka:9092` client configuration, and new pool, MGET batching, and timeout values expose the full Redis tuning contract with safe defaults. New helpers `neuraltrust-platform.dataPlaneApi.redisBackend`/`redisConfig`/`redisUrl`; render coverage added to `scripts/test-helm-render.sh` (scenario 38o).
- **Control-plane app: correct public URL and wire platform-v2 backends.** `APP_URL`/`NEXTAUTH_URL` now resolve to the real public app origin. In v2 external mode the app receives AgentGateway, TrustGuard, DataCore, AlertEngine, and TrustLens endpoints plus their JWT contracts. Backend URLs follow the existing direct Deployment `env` pattern; core backend Secret references are required and fail closed while optional backend Secret references remain optional. The entire contract remains v2-gated.
- **Platform v2 external: flag-driven control-plane, shared ClickHouse secret, and optional IAM auth.** Follow-up to the control-plane/AlertEngine work below. (1) The product **control-plane API + App UI** now auto-enable in v2 **external** purely from the platform flags — a new subchart helper `neuraltrust-control-plane.controlPlaneEnabled` (v2 → external-only, ignoring `controlPlane.enabled`; v1 → the explicit opt-in) replaces the raw `controlPlane.enabled` checks across the `api`/`app`/`secrets`/`serviceaccount`/`hpa`/`monitoring`/`poddisruptionbudgets`/`scheduler` templates. Operators no longer set `controlPlane.enabled` in external mode; v2 hybrid keeps the console SaaS-side even if it is set. The `scheduler` stays force-off in v2. (2) **DataCore + AlertEngine** now read `CLICKHOUSE_PASSWORD` from a single shared secret (the in-cluster `clickhouse` secret, key `admin-password`, via a `clickhouse.existingSecret` values block) instead of generating their own — one credential for both readers; external ClickHouse points `existingSecret` at your secret. (3) Optional **IAM DB/Redis auth** is now chart-prepared for the v2 Go services: `database.iamAuth` / `redis.iamAuth` (default `false`) emit `DB_IAM_AUTH`/`DB_AUTH_MODE`/`REDIS_IAM_AUTH` and ship no static password when on (service-side token minting lands separately; RDS IAM is already live for the Python control-plane via `postgresql.authMode: iam`). New sibling overlay **`values-v2-managed-datastores.yaml.example`** (RDS/ElastiCache IAM), and `values-v2-external.yaml.example` cleaned up (control-plane enable toggles + `neuraltrust-data-plane` block + duplicate ClickHouse passwords removed). Tests: `scripts/test-helm-render.sh` scenario 38c reworked (auto-enable without `controlPlane.enabled`) + new 38d (shared ClickHouse secret) and 38e (IAM env). Docs/rules/secrets updated. Subcharts: `agentgateway`/`trustguard` `0.1.2 → 0.1.3`, `datacore`/`alertengine` `0.1.0 → 0.1.1`, `neuraltrust-control-plane` `1.2.42 → 1.2.43`; umbrella `1.20.0 → 1.21.0`.
- **Platform v2: product control-plane in external mode + a new `alertengine` subchart.** Two changes for the zero-SaaS `external` deployment. (1) The product **control-plane API + App UI** (`neuraltrust-control-plane` `api` + `app`) now render on-prem in v2 **external** (they stayed off in all v2 modes before); the `api`/`app` templates switched from `if not isV2` to `if or (not isV2) (isV2 and isExternal)` and the previously version-agnostic `app` templates gained the same guard so v2 **hybrid** keeps the console SaaS-side. The legacy `scheduler` stays off in all v2 modes. Operators still opt in via `neuraltrust-control-plane.controlPlane.enabled=true`. (2) New **`alertengine`** subchart (`charts/alertengine`, external only) — one Go image, two runtimes (`api` on `:8085` consumed in-cluster by the app BFF; `worker` runs rule evaluation + SIEM forwarding). It evaluates detection rules over ClickHouse telemetry (`otel` DB written by `clickstack-otel-collector`), dedupes alerts in its **own** Postgres database `alertengine` (separate migrations; `templates/v2-postgres-init.yaml` now creates its role + DB), and forwards findings to SIEMs. Secrets `DB_PASSWORD`, `AUTH_JWT_SECRET`, `APP_ENCRYPTION_KEY`, `CLICKHOUSE_PASSWORD` auto-generate via `resolveSecret`. `values-v2-external.yaml.example` rewritten as a v2 **external** AWS overlay (external Aurora Postgres + ElastiCache Redis placeholders, in-cluster ClickHouse, control-plane api+app on, alertengine on, Kafka/in-cluster PG/Redis off). Registry/CI/tests/docs updated (`scripts/release-images-markdown.sh`, `.github/workflows/bump-images.yml`, `scripts/test-helm-render.sh` scenarios 36/37/37b + new 38c, `docs/platform-v2.md`, `.cursor/rules/platform-v2.mdc`, `SECRETS.md`, `values.yaml`, `values-v2.yaml.example`). New subchart `alertengine` `0.1.0`; `neuraltrust-control-plane` `1.2.41 → 1.2.42`; umbrella `1.19.0 → 1.20.0`.
- **Platform v2: dynamic service URLs, auto-shared client credentials, and a single shared `trustdata` Postgres.** In a single-umbrella v2 deploy the operator no longer sets service-to-service wiring: (1) AgentGateway's `TRUSTGUARD_BASE_URL` auto-derives to the in-cluster data-plane Service `http://trustguard-data-plane.<namespace>.svc.cluster.local` (port 80); (2) TrustGuard's `TRUSTGUARD_BASE_URL` (the platform-token `aud`) auto-derives to `https://trustguard.<global.domain>`, falling back to the in-cluster URL so it is never empty when a platform client is set; (3) the AgentGateway↔TrustGuard `client_credentials` pair is owned centrally by a new parent Secret `templates/v2-trustguard-client-secret.yaml` (id `global.v2.trustguardClientId`, default `agentgateway-platform`; secret auto-generated or `global.v2.trustguardClientSecret`) and injected into both services via the new `neuraltrust-platform.trustguardClientEnv` helper as `TRUSTGUARD_CLIENT_ID`/`_SECRET` (AgentGateway) and `TRUSTGUARD_PLATFORM_CLIENT_ID`/`_SECRET` (TrustGuard) so the pair always matches; (4) DataAgent's `databridge.addr`/`serverName` now default to the SaaS DataBridge (`databridge.neuraltrust.ai`). **Postgres:** AgentGateway and TrustGuard now share ONE database `trustdata` — `templates/v2-postgres-init.yaml` creates it once, gives each service its own role + schema with a per-role `search_path` (isolation so identically-named tables don't collide), and provisions a read-only `dataagent` role with SELECT + default privileges on both schemas; DataAgent's DSN and `DB_PASSWORD` are assembled/auto-generated from a new component `database` block (host auto-derives via the new `neuraltrust-platform.postgres.host` helper; overlay `database.host` + `database.password` for external Postgres). `trustlens` keeps its own database. Per-subchart `clientId`/`clientSecret` and DataAgent `databaseUrl` remain as deprecated overrides. Caveat: sharing one DB is a scaffold-level risk (apps that pin `public.*` migration trackers can still collide); the fallback is distinct `database.name` per service. Docs/rules/examples updated (`docs/platform-v2.md`, `.cursor/rules/platform-v2.mdc`, `SECRETS.md`, `values.yaml`, `values-v2.yaml.example`); test coverage added in `scripts/test-helm-render.sh`. Subcharts: `agentgateway` `0.1.1 → 0.1.2`, `trustguard` `0.1.1 → 0.1.2`, `dataagent` `0.1.1 → 0.1.2`. Umbrella `1.18.0 → 1.19.0`.
- **Platform v2: in-cluster ClickHouse + a temporary `data-plane-api` analytics shim (no Kafka).** ClickHouse deploys in-cluster under v2 **external** (and v1), governed by `infrastructure.clickhouse.deploy` and the `neuraltrust-platform.clickhouseAllowed` guard. (Superseded above: hybrid no longer deploys in-cluster ClickHouse, and its `data-plane-api` shim renders only against an external ClickHouse.) Under v2 the legacy `neuraltrust-data-plane` subchart stays disabled **except** its `api` component (`data-plane-api`), the read/analytics API over ClickHouse until TrustLens ships its own write path. A new `neuraltrust-platform.dataPlaneApiV2.enabled` helper (`isV2` AND `dataPlane.enabled` AND `dataPlane.components.api.enabled`) gates the shim templates — `api/deployment.yaml`, `api/service.yaml`, `api/rbac.yaml`, `api/otel-configmap.yaml`, `serviceaccount.yaml`, `clickhouse-config/secrets.yaml`, `clickhouse-config/sql-configmap.yaml` (guard: `if or (not isV2) dataPlaneApiV2.enabled`). The **kafka-workers** (`worker/*`) and **kafka-connect** (`kafka-components/*`) stay `isV2`-off. The `data-plane-api` server boots without a broker (Kafka init is best-effort and non-fatal; only ingest/eval endpoints touch Kafka and degrade gracefully) — it hard-requires ClickHouse only. Note: with no Kafka/worker consumer, ingest endpoints do not populate ClickHouse yet; the shim serves reads. Tests (`scripts/test-helm-render.sh` scenarios 36/37b/38: assert `data-plane-api` present, worker/kafka-connect absent, ClickHouse on in hybrid) and docs (`docs/platform-v2.md`, `.cursor/rules/platform-v2.mdc`, `.cursor/rules/project-context.mdc`, `values.yaml`, `values-v2.yaml.example`) updated. Data-plane subchart `1.2.48 → 1.2.49`; umbrella `1.17.0 → 1.18.0`.
- **Platform v2: in-cluster Postgres + Redis by default, mode unification, and a mandatory-secret/variable review.** Under `global.platformVersion=v2`: (1) the in-cluster `control-plane-postgresql` deploys by default in **all** v2 modes, and a new `isV2`-guarded parent Job `templates/v2-postgresql-init.yaml` creates a database + role per enabled v2 service (`agentgateway`, `trustguard`, and `trustlens` when enabled) from each service's generated password — services default `database.host` to `control-plane-postgresql`; (2) a new umbrella-managed in-cluster Redis (`templates/redis/`, service `redis`, `infrastructure.redis.deploy=true` default) deploys in all v2 modes, with services defaulting `redis.host` to `redis` and an `infrastructure.redis.external` block for hosted Redis; (3) ClickHouse now renders in-cluster **only** in `external` mode under v2 (new `neuraltrust-platform.clickhouseAllowed` guard wraps every `charts/clickhouse` template; v1 unchanged); (4) the `full` and `external` deployment modes are **unified** — `full` is now a deprecated alias that renders byte-identically to `external`, and `neuraltrust-platform.isFull` is a deprecated alias of `isExternal`; (5) TrustLens is **disabled by default** (`trustlens.enabled=false`, all templates additionally gated on `.Values.enabled`). Datastore SSL: v2 services default `database.sslMode: prefer` (TLS-when-available, plaintext fallback for the non-TLS in-cluster Postgres; also passes TrustGuard's production guard, which rejects only `disable`). **Secret/variable fixes:** AgentGateway now emits the env var names the binary actually reads — `DB_*` (was `DATABASE_*`), `GATEWAY_BASE_DOMAIN`/`MCP_BASE_DOMAIN` (was `SERVER_BASE_DOMAIN`), secret key `DB_PASSWORD` (was `DATABASE_PASSWORD`) — and defaults `TELEMETRY_ENABLED=false` for the Kafka-less v2 path. DataAgent's `ENROLMENT_TOKEN` and `DATABASE_URL` are no longer random-auto-generated (invalid); they are sourced from values and preserved from the existing secret on upgrade. Kafka comments clarified (never renders under v2). Registry/tests/docs updated: `scripts/release-images-markdown.sh` (v2 Redis image), `.github/workflows/bump-images.yml` (Redis sync), `scripts/test-helm-render.sh` (scenarios 36/37/37b + new 37c full==external and 37d TrustLens opt-in), `docs/platform-v2.md`, `.cursor/rules/platform-v2.mdc`, `.cursor/rules/project-context.mdc`, `values-v2.yaml.example`, `SECRETS.md`. Subcharts: `agentgateway` `0.1.0 → 0.1.1`, `trustguard` `0.1.0 → 0.1.1`, `trustlens` `0.1.0 → 0.1.1`, `dataagent` `0.1.0 → 0.1.1`, `clickhouse` `1.0.2 → 1.0.3`. Umbrella `1.16.1 → 1.17.0`.
- **Platform v2 data pipeline: `dataagent`, `datacore` and `clickstack-otel-collector` subcharts + a new `global.deploymentMode: external`.** `dataagent` (customer-side, outbound-only gRPC bridge to the SaaS DataBridge; no inbound Service) renders only in `hybrid` mode. `clickstack-otel-collector` (ClickStack image; OTLP `:4317`/`:4318` → ClickHouse) and `datacore` (residency query API reading `otel_logs` from ClickHouse) render only in the new `external` mode — a zero-SaaS-dependency install that extends `full` (control + data planes on-prem) with a self-hosted analytics stack over local (or external) ClickHouse. New guard helpers `neuraltrust-platform.isExternal` / `neuraltrust-platform.isHybrid`, and `neuraltrust-platform.isFull` now also matches `external`. All three subcharts carry the `isV2` guard so `v1` renders byte-identical. ClickHouse target defaults to the in-cluster `clickhouse` subchart and can point at an external endpoint when `infrastructure.clickhouse.deploy=false`. `values-v2.yaml.example`, `docs/platform-v2.md`, `.cursor/rules/platform-v2.mdc` and the component-registry touchpoints (`scripts/release-images-markdown.sh`, `.github/workflows/bump-images.yml`, `scripts/test-helm-render.sh` scenarios 35/36/37/37b) updated. Umbrella `1.15.0 → 1.16.0`.
- **Platform v2 stack behind a single `global.platformVersion` switch.** Three new subcharts — `agentgateway` (TrustGate v2: `admin` control-plane + `proxy`/`mcp` data-plane), `trustguard` (control-plane admin API + data-plane `/v1/guard` runtime) and `trustlens` (`api` control-plane + River `worker` data-plane, Postgres-only) — are added as umbrella dependencies. They render **only** when `global.platformVersion: v2`; the default (`v1`/empty) keeps today's deployment byte-identical (backward-compatible). `global.deploymentMode` picks the split-plane boundary: `hybrid` (default) deploys only the data-plane workloads on-prem, `full` deploys control-plane + data-plane. The switch is implemented with the `neuraltrust-platform.isV2` / `neuraltrust-platform.isFull` helpers guarding every v2 template. New overlay `values-v2.yaml.example`, docs at `docs/platform-v2.md`, and agent guidance in `.cursor/rules/platform-v2.mdc`. Render coverage added to `scripts/test-helm-render.sh` (scenarios 35-38b). Component-registry touchpoints updated (`scripts/release-images-markdown.sh`, `.github/workflows/bump-images.yml`). Umbrella `1.14.16 → 1.15.0`.

### Changed

- **Platform v2 is the chart 2.0 default.** Empty or omitted generation resolves to v2 and hybrid; invalid generations/modes fail rendering. A live upgrade that detects v1 workloads requires either explicit `global.platformVersion: v1` or `global.confirmV2Migration: true`, preventing silent workload replacement. DataAgent now renders only with a tenant plus direct or existing-Secret enrolment token. AgentGateway, TrustGuard, DataCore, the control-plane app, secret pre-provisioning, OTel scraping, monitoring, and watchdog defaults now use the canonical v2 boot/security contracts while explicit v1 retains TrustGate/Kafka behavior.

- **Retired AISPM and legacy SIEM Connector subcharts.** Their dependencies, values, image automation, release rows, tests, and chart-managed secrets were removed. AlertEngine SIEM forwarding remains supported. Explicitly enabling either retired component fails with an upgrade migration message.

- **Platform v2 chart portability: unified Postgres `sslMode`, working registry-auth opt-out, external ClickHouse wiring, and air-gap image mirroring.** An audit of the v2 stack for custom image registry / domain / registry auth (or none) / namespace / external Postgres+Redis+ClickHouse closed the remaining gaps. (1) **`sslMode` default is now `prefer` everywhere** — `agentgateway`, `trustguard`, `alertengine`, `trustlens` subchart defaults changed from `require` to `prefer` (plus the umbrella `alertengine` default), so a single default works against both the non-TLS in-cluster Postgres (plaintext fallback) and TLS hosted DBs; force TLS by setting `sslMode: require` in the overlay (done for AlertEngine in `values-v2-external.yaml.example` / `values-v2-managed-datastores.yaml.example`). The control-plane keeps its auto-derived `disable`/`require`. `trustlens` also now routes `DATABASE_HOST` through the shared `neuraltrust-platform.postgres.host` helper. (2) **Registry-auth opt-out fixed** — nested `neuraltrust-control-plane.controlPlane.imagePullSecrets` and `neuraltrust-data-plane.dataPlane.imagePullSecrets` set to `"none"`/`""` now actually suppress the pull-secret block (previously they silently kept `gcr-secret`); `clickhouse` handles `"none"` too. (3) **External ClickHouse wiring** — the `data-plane-api` shim no longer force-appends `.<ns>.svc.cluster.local` to the ClickHouse host (a dotted/external host is used verbatim), and its `CLICKHOUSE_PASSWORD` secret name/key are now configurable via `dataPlane.components.clickhouse.existingSecret` (default `clickhouse`/`admin-password`). `clickstack-otel-collector` now reads `CLICKHOUSE_PASSWORD` from the shared `clickhouse` secret via `clickhouse.existingSecret` (matching DataCore/AlertEngine) instead of generating its own. (4) **Air-gap image mirroring** — the `clickstack-otel-collector` image helper now strips the vendor prefix `docker.clickhouse.com/` before prepending `global.imageRegistry`, so a mirror gets `<mirror>/clickhouse/clickstack-otel-collector` (not a doubled-up vendor path). (5) **Domain portability** — hardcoded `*.neuraltrust.ai` fallbacks in the control-plane `app`/`api`/`scheduler` and `data-plane-api` OpenShift routes/URLs are replaced with the in-cluster service name when no `global.domain`/host is set (behavior with a domain set is unchanged). External Kafka was already supported via `global.kafka.bootstrapServers` (no change). Tests: `scripts/test-helm-render.sh` scenarios 38f (sslMode=prefer), 38g (imagePullSecrets none opt-out), 38h (external ClickHouse host verbatim + secret), 38i (clickstack mirror). Docs (`docs/platform-v2.md`, `.cursor/rules/platform-v2.mdc`, `SECRETS.md`) updated. Subcharts: `agentgateway`/`trustguard` `0.1.3 → 0.1.4`, `alertengine`/`trustlens` `0.1.1 → 0.1.2`, `clickstack-otel-collector` `0.1.0 → 0.1.1`, `neuraltrust-control-plane` `1.2.43 → 1.2.44`, `neuraltrust-data-plane` `1.2.49 → 1.2.50`, `clickhouse` `1.0.3 → 1.0.4`; umbrella `1.21.0 → 1.22.0`.
- **Hugging Face token is now documented as optional for the firewall and data-plane (models are bundled in the images).** The official firewall images bundle all ML models at build time (`/app/resources/*`, `TRANSFORMERS_OFFLINE=1`), and the `data-plane-api` image bundles its own model (fastText, `lid.176.bin`); neither needs a Hugging Face token to run. For the data-plane, `HUGGINGFACE_TOKEN` is only *forwarded* to spawned evaluation Jobs when set (skipped if absent), so it only matters for Jobs that use HF-gated models. Both charts already mounted `HUGGINGFACE_TOKEN` as an `optional` secret key and only created the secret when a token was provided, so default installs are unaffected — this only clarifies the values/docs/examples as optional. Updated `charts/neuraltrust-firewall/values.yaml`, `charts/neuraltrust-data-plane/templates/api/deployment.yaml`, umbrella `values.yaml`, firewall gateway/worker deployment comments, `SECRETS.md`, `values-openshift.yaml`, `values-openshift-ingress.yaml.example`, and `values-dataplane-gpu.yaml.example`. Firewall subchart `2.0.14 → 2.0.15`; data-plane subchart `1.2.47 → 1.2.48`; umbrella `1.16.0 → 1.16.1`.
- **Bump NeuralTrust images to latest releases.** `app` `v1.78.2 → v1.79.0`, `data-plane-api` `v1.37.0 → v1.38.1`. All other bump-images targets were already at the latest Artifact Registry tags. Subcharts: control-plane `1.2.40 → 1.2.41`, data-plane `1.2.45 → 1.2.47`.
- **TrustGate `SERVER_SECRET_KEY` is now required, and the firewall API key is enforced when the firewall is enabled.** All three TrustGate deployments (control-plane, data-plane, actions) previously referenced `SERVER_SECRET_KEY` with `optional: true`, so pods could boot without the mandatory server key and fail auth at runtime; the reference is now required so a missing key surfaces immediately as `CreateContainerConfigError`. In addition, the parent `platform-secrets.yaml` now fails the render fast if `SERVER_SECRET_KEY` cannot be resolved, or if `neuraltrust-firewall.firewall.enabled` is true but `NEURAL_TRUST_FIREWALL_SECRET_KEY` cannot be resolved for `trustgate-secrets`. Default installs are unaffected (both keys are auto-generated under `global.autoGenerateSecrets: true`); the change only fails fast on genuinely misconfigured deployments (e.g. `preserveExistingSecrets` with a required key omitted). Render coverage added to `scripts/test-helm-render.sh` (scenario 34). TrustGate subchart `1.2.31 → 1.2.32`.

- **Platform v2 Postgres per-mode isolation + hybrid raw-telemetry wiring.** `v2-postgresql-init` now provisions Postgres **by deployment mode** instead of a single shared-`public` layout, and wires the raw-telemetry write path so hybrid DataAgent actually has data. **Why:** the two v2 data planes ship telemetry migrations that both register `id="0001"` in a `migration_versions` (TEXT PRIMARY KEY) tracker (`trustgate/pkg/metrics/migrations/migration_0001_*`, `TrustGuard/pkg/metrics/migrations/migration_0001_*`); in one schema the second migrator sees `0001` applied and **skips creating its data table**, so a shared-`public` layout silently loses one of `trustgate_data` / `trustguard_data`. DataAgent also reads both tables as **unqualified** identifiers on one `DATABASE_URL` pool (`DataAgent/internal/infra/store/postgres/store.go`), so it needs both visible via `search_path` on a single connection. **Model:** (a) **hybrid** — one shared `trustdata` DB where AgentGateway and TrustGuard each get their **own schema** (role name) with the role's `search_path` defaulted there (`ensure_writer_schema`), so the per-service `migration_versions` never collide; the read-only `dataagent` role gets `SELECT` on both schemas and `search_path = agentgateway, trustguard, public` so its unqualified reads resolve. (b) **external** — each service gets its **own database** (`ensure_owned_db agentgateway` / `trustguard`) on `public`, since control planes run on-prem and own their migrations (DataCore reads ClickHouse; no Postgres reader). `DB_NAME` is now **mode-derived** from an empty `database.name` (`neuraltrust-platform.v2.dbName`): external → the service name; hybrid → `trustdata`. **Raw telemetry (hybrid):** new per-service `*-telemetry` ConfigMaps ship a postgres raw exporter (`dsn_env: SENSIBLE_PG_DSN`), mounted at `/etc/telemetry` and selected via `TELEMETRY_EXPORTERS_FILE` on the data-plane workloads; `SENSIBLE_PG_DSN` is added to `agentgateway-secrets` / `trustguard-secrets` (hybrid, non-IAM). External Postgres provisioning updated to separate databases (`cloud-infrastructure/aws/aurora_databases.tf` + `dev.tfvars` + `docs/aurora-app-databases.md`). No service image change. Render coverage updated in `scripts/test-helm-render.sh` (hybrid: per-service `CREATE SCHEMA`, `dataagent` `search_path`, `SENSIBLE_PG_DSN`, telemetry ConfigMaps; external: `ensure_owned_db`, no shared `trustdata`/reader, no `SENSIBLE_PG_DSN`). Docs/comments updated (`docs/platform-v2.md`, `SECRETS.md`, `values-v2.yaml.example`, subchart + umbrella `values.yaml`, `charts/dataagent/values.yaml`). Supersedes the earlier shared-`public` approach within this unreleased window. Subcharts: `agentgateway` / `trustguard` `0.1.1 → 0.1.2`; umbrella `1.16.0 → 1.17.0`.

### Fixed

- **v2 runtime telemetry and database IAM auth.** AgentGateway and TrustGuard now mount mode-specific telemetry profiles in every v2 mode: hybrid persists raw events to the local Postgres schemas for DataAgent, while external exports metadata and raw events over OTLP/HTTP to the in-cluster ClickStack collector. AgentGateway telemetry is enabled by default so the configured profile is active. Database IAM mode now selects the binaries' actual `POSTGRES_LOGIN=aws` contract instead of emitting only unused compatibility flags.

- **Platform v2 external: AgentGateway Redis TLS env-var name + TrustGuard control-plane config-sync gRPC TLS.** Two boot-blocking fixes surfaced by a v2 `external` deploy against TLS-only managed Redis. (1) **AgentGateway Redis TLS was silently ignored.** The `agentgateway` (and v1 `trustgate`) charts emitted `REDIS_TLS`, but the TrustGate binary reads **`REDIS_TLS_ENABLED`** / `REDIS_TLS_INSECURE_VERIFY` (`trustgate/pkg/config/config.go`), so TLS stayed off and the client dialed a TLS-only endpoint (e.g. ElastiCache Serverless) in plaintext → `context deadline exceeded` → `CrashLoopBackOff`. Both charts now emit `REDIS_TLS_ENABLED` (plus optional `REDIS_TLS_INSECURE_VERIFY` from a new `redis.tlsInsecureVerify` knob); TrustGuard is unaffected (it correctly reads `REDIS_TLS`). Note: TrustGate has no Redis ACL-username support, so `REDIS_USERNAME` is emitted for parity but the binary AUTHs as the default user. (2) **TrustGuard control-plane refused to boot in a deployed `APP_ENV`.** Its config-sync gRPC listener requires `CONFIG_SYNC_GRPC_TLS_CERT`/`_KEY` when `APP_ENV` is `prod`/`staging` (`TrustGuard/internal/container/modules/control_config_sync.go`), which the chart never provided → `invalid configuration` boot failure. New template `charts/trustguard/templates/configsync-tls-secret.yaml` auto-generates a self-signed CA + server cert (SANs cover the `trustguard-control-plane` Service DNS), preserved across upgrades via `lookup` and `helm.sh/resource-policy: keep`; the cert/key mount on the control plane (`CONFIG_SYNC_GRPC_TLS_CERT`/`_KEY`) and, when config-sync is enabled in full mode, the CA mounts on the data plane which then dials with TLS verification (`CONFIG_SYNC_TLS_CA` + `CONFIG_SYNC_TLS_SERVER_NAME`, `CONFIG_SYNC_TLS_INSECURE=false`) via the extended `neuraltrust-platform.configSyncEnv` helper. New values block `trustguard.configSync.grpcTls` (`autoGenerate`, `existingSecret`, `durationDays`); rendered only for v2 + external/full + deployed `APP_ENV`. Render coverage added to `scripts/test-helm-render.sh`. Subcharts: `agentgateway` / `trustguard` `0.1.2 → 0.1.3`, `trustgate` `1.2.32 → 1.2.33`; umbrella `1.17.0 → 1.18.0`.
- **Platform v2 external: TLS-only managed Redis, control-plane secret gating, DataCore ClickHouse database, and the ClickStack collector `metrics/promql` pipeline.** Four independent fixes for a v2 `external` deployment against hosted infrastructure (managed Postgres + TLS-only serverless Redis + in-cluster ClickHouse). (1) **Redis TLS + ACL username** — `agentgateway` and `trustguard` now expose `redis.username` and `redis.tls` values and emit `REDIS_USERNAME` / `REDIS_TLS` (only when set), using each runtime’s supported variable names. TLS-only managed Redis (e.g. serverless caches that enforce in-transit encryption and use a Redis 6+ ACL user) previously timed out at boot because the clients spoke plaintext with no username; default installs are unaffected (both render only when set). (2) **`control-plane-secrets` in v2 external** — `templates/platform-secrets.yaml` gated the `control-plane-secrets` Secret on `controlPlane.enabled`, but the control-plane API + App auto-enable in v2 external (see `neuraltrust-control-plane.controlPlaneEnabled`), so the pods hit `CreateContainerConfigError` for a missing Secret. The Secret (and the `ingress-tls-secret.yaml` host collection) now also render when `isV2` && `isExternal`. (3) **DataCore ClickHouse database** — `charts/datacore` defaulted `clickhouse.database` to a non-existent `datacore` DB, crash-looping DataCore; it now defaults to the built-in `default` database, matching DataCore's own SaaS/prod overlays (`CLICKHOUSE_DATABASE=default`, `CLICKHOUSE_OTEL_DATABASE=otel`) — no database needs creating. (4) **ClickStack collector** — the `metrics/promql` pipeline override in `clickstack-otel-collector` `customConfig` declared an exporter with no receiver, so the collector errored on boot; it is now a self-contained inert pipeline (built-in `nop` receiver + `nop` exporter), and a configurable `HYPERDX_LOG_LEVEL` (default `info`) was added. Render coverage added to `scripts/test-helm-render.sh`. Subcharts: `agentgateway` / `trustguard` / `datacore` / `clickstack-otel-collector` `0.1.0 → 0.1.1`; umbrella `1.15.0 → 1.16.0`.

## [v1.14.14] — 2026-07-01

### Changed

- **Bump NeuralTrust images to latest releases.** `trustgate-ee` `v1.28.2 → v1.28.3`, `app` `v1.72.0 → v1.76.0`, `data-plane-api` `v1.35.1 → v1.36.0`, `watchdog` `v0.12.0 → v0.13.0`. All other bump-images targets were already at the latest Artifact Registry tags. Subcharts: TrustGate `1.2.30 → 1.2.31`, control-plane `1.2.37 → 1.2.38`, data-plane `1.2.43 → 1.2.44`, watchdog `0.2.3 → 0.2.4`.

### Fixed

- **TrustGate Kafka SASL auth works without a binary change.** The shared Kafka auth env emits the platform-standard `KAFKA_SASL_USERNAME` / `KAFKA_SASL_PASSWORD`, but the TrustGate binary reads `KAFKA_USERNAME` / `KAFKA_PASSWORD`. With auth enabled the credentials therefore arrived empty and the telemetry producer connected in PLAINTEXT against a SASL broker (`broker might require SASL authentication`). `trustgate.kafkaEnv` now also emits the legacy `KAFKA_USERNAME` / `KAFKA_PASSWORD` aliases (same inline/existing-secret source as `KAFKA_SASL_*`), so SASL (e.g. SCRAM-SHA-512 on a `SASL_PLAINTEXT` listener) works with the current image. The alias is harmless once the binary aligns to the `KAFKA_SASL_*` names. Only rendered when `global.kafka.auth` is enabled and no `jaasConfigKey` is set. TrustGate subchart `1.2.29 → 1.2.30`.

## [v1.14.12] — 2026-06-29

### Fixed

- **Watchdog platform check namespaces follow the Helm release namespace.** Platform-scoped checks (`pod-health`, `deployment-health`, `cert-renewal`, `log-error-rate`, …) no longer hardcode `neuraltrust`; empty `target.namespace` / `target.namespaces` now resolve to `platformNamespace` (default: the release namespace). Cross-namespace checks (`deploy-api`, `aispm`, `trustscan`, `opentelemetry`, …) keep explicit namespaces. `logExport.sources` uses the same resolution. watchdog subchart `0.2.0 → 0.2.1`.

## [v1.14.10] — 2026-06-26

### Fixed

- **data-plane-api TrustTest config mount uses an explicit opt-in flag.** `trustTestConfig: {}` is an empty map and Helm treats it as falsy, so the `data-plane-trusttest-config` ConfigMap was created but never mounted at `/app/.trusttest_config.json`. The chart now gates the mount on `trustTestConfig.enabled` (default `false`; set `enabled: true` to opt in). data-plane subchart `1.2.41 → 1.2.42`.

- **Auto-generated secrets no longer rotate on upgrade when `lookup` is unavailable, and ClickHouse now honors `global.preserveExistingSecrets`.** Secret preservation relied solely on Helm's `lookup`, which returns nothing under restricted RBAC or template-only renders (ArgoCD/Flux, `helm template`, `--dry-run`). In those flows the ClickHouse `admin-password` (and other generated secrets) could be overwritten with a fresh random value on every upgrade, breaking consumers that cached the previous value (e.g. Kafka Connect) until they were restarted. `charts/clickhouse/templates/secret.yaml` now (1) honors `global.preserveExistingSecrets` like every other subchart, (2) carries `helm.sh/resource-policy: keep`, and (3) skips emission on upgrade when no value is resolvable (no explicit `clickhouse.auth.password` and an empty `lookup`) so the live Secret is preserved instead of clobbered. The non-hook parent secrets (`control-plane-secrets`, `data-plane-jwt-secret`, `postgresql-secrets`, `firewall-secrets`, `aispm-secrets`) also gain `helm.sh/resource-policy: keep`, making it safe to set `global.preserveExistingSecrets: true` after first install (Helm will not prune them). NOTE: these secrets are now retained on `helm uninstall`. Render coverage added to `scripts/test-helm-render.sh` (scenarios 31-33). ClickHouse subchart `1.0.1 → 1.0.2`.

## [v1.14.9] — 2026-06-23

### Fixed

- **Kafka Connect now provisions and validates its internal topics so it starts reliably against an external broker.** Kafka Connect requires `connect-configs` to have exactly 1 partition; on a broker with `auto.create.topics.enable=true` and a default `num.partitions > 1` it could be created with multiple partitions, after which Connect's herder refuses to start (`config.storage.topic ... required to have a single partition`). The `kafka-connect` init container now **creates the internal topics that are missing** with the correct layout (`connect-configs=1`, `connect-offsets=25`, `connect-status=5`, `cleanup.policy=compact`) — idempotent (`--create --if-not-exists`), so it also recovers clusters where the topics or their volume were deleted, and never overrides topics an operator pre-created. If `connect-configs` already exists with the wrong partition count it **fails fast**, printing the exact `kafka-topics.sh --delete` command to run (it never deletes topics automatically). Render coverage added to `scripts/test-helm-render.sh` (scenario 28). data-plane subchart `1.2.39 → 1.2.40`.
- **Kafka Connect logs no longer fail under `securityHardening`.** With `readOnlyRootFilesystem` enabled, log4j's `RollingFileAppender` and the Kafka CLI tools could not create `/opt/kafka/logs` (`Read-only file system`), emitting startup errors before falling back to stdout. A writable `emptyDir` is now mounted at `/opt/kafka/logs` on the `kafka-connect` container and its init container.

## [v1.14.8] — 2026-06-23

### Changed

- **Bump NeuralTrust images to latest releases.** The Kafka-client releases now honor the `KAFKA_SECURITY_PROTOCOL` / `KAFKA_SASL_*` / `KAFKA_SSL_CA_LOCATION` env the chart already injects for external brokers (`global.kafka.auth`), so connecting to a SASL-authenticated Kafka now works: `trustgate-ee` `v1.28.1 → v1.28.2`, `data-plane-api` `v1.34.1 → v1.35.0`, `workers` `v1.6.12 → v1.8.0`, `kafka-connect` `v0.4.0 → v0.4.1`. Also `watchdog` `v0.9.0 → v0.10.0`. Subcharts: TrustGate `1.2.28 → 1.2.29`, data-plane `1.2.38 → 1.2.39`, watchdog `0.1.9 → 0.1.10`.

### Added

- **TrustGate `postgresql.passwordSecretRef` — keep the DB password only in an external Secret.** For operators using external-secrets / Secrets Store CSI, set `trustgate.postgresql.passwordSecretRef.name` and `.key` to keep **only** the database password in their own Kubernetes Secret while host/port/user/database/sslMode stay in values (`trustgate.global.env.DATABASE_*`). Setting both fields activates the mode (no separate boolean). In this mode the chart never `lookup`s or copies the password: the TrustGate control-plane, data-plane, actions containers and the `postgresql-init` Job reference it directly via `secretKeyRef` → `{name, key}`. TrustGate connects using the individual `DATABASE_*` vars (it does not read `DATABASE_URL`), so `DATABASE_URL` is omitted entirely in this mode and the password is never embedded in a chart-managed object. This fixes both the external-secrets timing problem (the Secret no longer has to exist at `helm` render time) and credential rotation (rotating the source Secret no longer requires re-running Helm), with no password URL-encoding constraints. Leaving `passwordSecretRef` unset preserves the existing lookup-and-copy behavior; `DATABASE_PASSWORD`/`DATABASE_URL` are omitted from `trustgate-secrets` only in the new mode. The shared `trustgate.databaseEnv` helper now backs all three deployments. Render coverage added to `scripts/test-helm-render.sh` (scenario 18c). TrustGate subchart `1.2.27 → 1.2.28`.

## [v1.14.7] — 2026-06-22

### Fixed

- **Firewall GPU workers could not be pinned to a separate node pool from `global.nodeSelector`.** The worker template previously rendered the per-worker selector as `nodeAffinity` **and** `global.nodeSelector` as a plain `nodeSelector`. When both used the same label key (e.g. a CPU pool in `global.nodeSelector.nodepool` and a GPU pool in `firewall.workerDefaults.nodeSelector.nodepool`), the two constraints were ANDed and could never be satisfied, so GPU workers stuck on / fell back to the global pool with no values-only workaround. The selectors are now merged into a single `nodeAffinity` where the per-worker selector **wins on key conflicts** and non-conflicting global keys remain required (ANDed). Behavior is unchanged when the keys differ or when only one selector is set. Render coverage added to `scripts/test-helm-render.sh` (scenario 25d). Firewall subchart `2.0.12 → 2.0.13`.

## [v1.14.3] — 2026-06-15

### Added

- **External Kafka auth/TLS wiring** — `global.kafka` configures bootstrap servers, SASL credentials via an existing Secret (`auth.existingSecret` + `usernameKey`/`passwordKey`, or `jaasConfigKey`), and broker CA trust (`tls.existingSecret`). All Kafka consumers receive consistent `KAFKA_*` / `CONNECT_*` env vars. Renders a shared `kafka-connection` ConfigMap when `global.kafka.bootstrapServers` (or `brokers`) is set. `global.customCaCert` does not enable Kafka TLS unless `global.kafka.tls.enabled` is true.
- **TrustGate PostgreSQL existing Secret** — `trustgate.postgresql.existingSecret` lets operators source only the TrustGate database connection fields from a pre-created Secret while keeping `global.autoGenerateSecrets: true` for `SERVER_SECRET_KEY`, firewall keys, Redis internals, and the rest of the platform-generated secrets.

### Changed

- **Kafka bootstrap resolution** — components no longer hardcode `kafka:9092` when `global.kafka.bootstrapServers` is configured (with `infrastructure.kafka.deploy: false`). Override per component only when needed (e.g. `neuraltrust-data-plane.dataPlane.components.kafka.connect.bootstrapServers`).
- **Removed `infrastructure.kafka.external`** — external broker settings live only under `global.kafka` (visible to all subcharts). No clients had adopted the old alias path.


### Changed

- **Right-sized default resource requests/limits to fit 16 GiB worker nodes.** Reduced inflated umbrella defaults toward the values NeuralTrust runs in SaaS prod, so the documented sizing baselines now target **8 vCPU / 16 GiB** nodes instead of 8 vCPU / 32 GiB: hybrid fits **4 nodes** (~12.25 vCPU / ~40.5 GiB requests, down from ~58.5 GiB), self-hosted **5 nodes** (~43.75 GiB), self-hosted + AISPM **6 nodes** (~45 GiB). Changes (req/lim memory): TrustGate gateway `4Gi→8Gi` ⇒ `3Gi→6Gi`; TrustGate admin & actions `2Gi→4Gi` ⇒ `1Gi→2Gi`; Data Plane API `4Gi→6Gi` ⇒ `3Gi→6Gi`; Data Plane worker `4Gi→8Gi` ⇒ `3Gi→6Gi`; Firewall worker defaults `4Gi→6Gi` ⇒ `2Gi→3Gi`, with a per-worker override keeping the heavier `prompt-moderation` worker at `3Gi→4Gi`. **ClickHouse memory is intentionally unchanged at `4Gi`/`8Gi`** (the chart ships no in-chart memory caps, so lowering it risks `MEMORY_LIMIT_EXCEEDED`/OOM) — only its CPU *request* was relaxed `2→1` (limit stays `4`) to improve bin-packing. Control Plane API (`1Gi`/`2Gi`), PostgreSQL (`2Gi`/`4Gi`), Kafka (`1Gi`/`2Gi`), Redis (`1Gi`/`2Gi`, tied to the hardcoded `maxmemory 1gb`) and Kafka Connect (`2Gi`, JVM heap floor) are unchanged. All values remain operator-overridable; HPAs still scale components above these baselines under load.
- **HPA and PDB off by default across all Deployments.** `autoscaling.enabled` and `podDisruptionBudget.enabled` now default to `false` on every workload that supports them (TrustGate, Control Plane api/app/scheduler, Data Plane api/worker/kafka-connect, Firewall, AISPM, SIEM connectors, OTel Collector). New optional HPA/PDB templates were added for Control Plane and Data Plane components that previously lacked them. Fixed replica counts come from each component's `replicas` / `replicaCount` value. Opt in per component when your cluster has a metrics server (HPA) or you want voluntary-disruption guards during node drains (PDB).

### Added

- **`global.postgresql.deploy` — single switch for external PostgreSQL.** A new umbrella-wide flag (default `true`) controls in-cluster vs external PostgreSQL across **all** subcharts (Control Plane, TrustGate, AISPM). When set to `false`, the chart skips every consumer of the heavy `postgres` image so it is never pulled:
  - the in-cluster `control-plane-postgresql` Deployment,
  - the Control Plane API/scheduler `wait-for-postgresql` initContainers,
  - the TrustGate and AISPM `postgresql-init` Jobs.
  - The operator must pre-create the users/databases on the external server. The Control Plane app `init-db` initContainer (Prisma migrations, app image) still runs. The legacy `neuraltrust-control-plane.infrastructure.postgresql.deploy` remains honored and takes precedence; `global.postgresql.deploy` is the recommended single override. Defaults preserve existing behavior. Render coverage added to `scripts/test-helm-render.sh` (scenario 26).

### Removed

- **Dead `controlPlane.components.api.healthCheck.image` (curl) value.** No template referenced it; removed from `values.yaml`, the `release-images-markdown.sh` image table, and the `bump-images.yml` doc-only bump. The functional `curl` usage (ClickHouse backup CronJob, gated by `backup.enabled`) is unchanged.

## [v1.13.0] — 2026-06-05

### Added

- **Global node pinning via `global.nodeSelector` and `global.tolerations`.** Operators can now pin **every** platform workload to a dedicated node pool with a single setting instead of configuring each component separately. Both default to empty (`{}` / `[]`), so existing releases are unaffected.
  - `global.nodeSelector` is merged into every pod spec across all subcharts (TrustGate, Control Plane, Data Plane, Firewall, AISPM, SIEM connectors, ClickHouse, Kafka, Watchdog) and the parent-chart workloads (OTel Collector, init/cron Jobs). Per-component `nodeSelector` still works and **wins on key conflicts**.
  - `global.tolerations` is concatenated onto every pod spec (companion for an *exclusive*, tainted pool — a `nodeSelector` alone won't keep other tenants off). Per-component tolerations are preserved and merged.
  - The Firewall workers keep expressing their per-worker GPU-pool selection as `nodeAffinity` (its values are lists); `global.nodeSelector` is added there as a plain `nodeSelector` (ANDed with the affinity), so a GPU pool can still be pinned under a broader dedicated pool.
  - Implemented via the shared helpers `neuraltrust-platform.nodeSelector` / `neuraltrust-platform.tolerations` in `templates/_helpers.tpl`. Render coverage added to `scripts/test-helm-render.sh` (scenario 25).

## [v1.12.19] — 2026-06-03

### Changed

- **data-plane-api evaluation Jobs reuse the shared `data-plane` ServiceAccount.** The chart no longer creates a separate `data-plane-api` ServiceAccount for the k8sJobs feature. The API Deployment now always runs under the existing `data-plane` SA (like the worker and kafka-connect components, and matching the app's own `K8S_JOB_SERVICE_ACCOUNT=data-plane` default and the SaaS manifests). When `k8sJobs.enabled: true`, the `data-plane-job-creator` Role/RoleBinding is bound to `data-plane`, and spawned Job pods also run under `data-plane`. Removed `dataPlane.components.api.k8sJobs.serviceAccount`.
  - **Why:** the bespoke SA was the only thing referencing `data-plane-api`, and flipping `k8sJobs` off pruned that SA while leaving the Deployment pinned to it — Helm's 3-way merge does not clear a field that is absent in both the previous and current rendered manifests, so the live Deployment kept a dangling `serviceAccountName: data-plane-api` and pods failed with `serviceaccount … not found`.
  - **Upgrade note:** a release that previously had `k8sJobs` enabled may carry a stale `serviceAccountName: data-plane-api` on the live `data-plane-api` Deployment. This upgrade re-renders the Deployment with `serviceAccountName: data-plane`, which produces a real diff and a clean rollout. If you upgraded across the earlier OFF→OFF window and pods are stuck, clear it once with `kubectl patch deploy data-plane-api -n <ns> -p '{"spec":{"template":{"spec":{"serviceAccountName":"data-plane"}}}}'`.

### Fixed

- **`ImagePullBackOff` on private images that lacked a pull secret.** Three workloads pulled private GCP Artifact Registry images without resolving the chart-wide `gcr-secret`:
  - **In-chart OTel Collector** only honored `global.imagePullSecrets` (empty by default). It now defaults to `gcr-secret` (`global.observability.collector.imagePullSecret`), still honoring `global.imagePullSecrets` first. Opt out with `"none"`/`""` on IAM / Workload Identity clusters.
  - **`neuraltrust-watchdog`** subchart defaulted `imagePullSecrets: []`. It now defaults to `gcr-secret`. The bundled Prometheus uses a public image and is unaffected. Set `[]` to opt out.
  - **data-plane-api evaluation Jobs** (`rt-eval-*`) are created at runtime by the API process and were created with no `imagePullSecrets`. The chart now forwards the resolved pull-secret name to the API as `K8S_JOB_IMAGE_PULL_SECRET`, so spawned Job pods inherit the same secret as the Deployment. Resolves to the same value (and opt-out) as `neuraltrust-data-plane.imagePullSecrets`; omitted entirely when suppressed.
  - **In-chart OTel Collector CrashLoopBackOff on v0.153.x** — `service.telemetry.metrics.address` was removed in Collector v0.128+. Config now uses the `readers` / `pull` / `prometheus` block so the collector starts cleanly.

### Changed

- **GitHub Release notes** — `auto-release` (workflows `ai-release-bump`) writes **What changed** + **Commits**; `publish-chart.yml` appends a **Container images** table (`scripts/release-images-markdown.sh`) and **Installation** when the chart is published.
- **`data-plane-api k8sJobs` default is now OFF** (`dataPlane.components.api.k8sJobs.enabled: false`). Matches data-plane-api's `K8S_JOBS_ENABLED=false` when unset — red teaming / evaluation workloads run as in-process FastAPI background tasks unless the operator opts in. Set `k8sJobs.enabled: true` (requires `data-plane-api >= v1.25.0`) to spawn evaluation workloads as Kubernetes Jobs with the bundled SA/RBAC and `K8S_*` env wiring. Clusters that relied on the prior default must add the explicit opt-in to their values overlay.
- **`neuraltrust-watchdog` resources dropped the release-name prefix.** Set `fullnameOverride: "neuraltrust-watchdog"` so the Deployment/Service/ConfigMap/RBAC/PrometheusRule are named `neuraltrust-watchdog` (and `neuraltrust-watchdog-prometheus`) — matching `clickhouse`, `kafka`, `data-plane-api`, … — instead of `<release>-neuraltrust-watchdog`. The `app.kubernetes.io/name` label is unchanged, so OTel Collector label-based scraping and monitoring discovery are unaffected. On upgrade Helm replaces the prior `<release>-neuraltrust-watchdog` objects with the new names.
- **In-chart OTel Collector resources dropped the release-name prefix.** Set `global.observability.collector.fullnameOverride: "otel-collector"` so the Deployment/Service/ConfigMap/RBAC/PVC/ServiceMonitor are named `otel-collector` (and `otel-collector-config`, `otel-collector-buffer`, …) instead of `<release>-otel-collector`. Label-based discovery (`app.kubernetes.io/component: otel-collector`) is unchanged. On upgrade Helm replaces the prior prefixed objects.

## [v1.12.11] — 2026-05-22

### Added

- **data-plane-api Kubernetes Job runner is now the default** (`dataPlane.components.api.k8sJobs.enabled: true`). The data-plane-api Deployment spawns evaluation workloads as ephemeral Jobs in the release namespace instead of running them as FastAPI background tasks — keeping the API pod responsive and bounding per-evaluation resource usage. A new namespaced `ServiceAccount data-plane-api`, `Role data-plane-job-creator`, and matching `RoleBinding` are rendered automatically; the API Deployment binds to the new SA and receives `K8S_JOBS_ENABLED`, `K8S_JOBS_NAMESPACE`, `K8S_JOB_IMAGE`, `K8S_JOB_SERVICE_ACCOUNT` plus tunable resource/TTL/concurrency env vars. The API process inherits its own env into each Job pod's `env:` block at job-creation time, so the same code path works on Helm (Kubernetes Secrets via `secretKeyRef`) and Flux + Secret Manager (CSI) — no separate Secret object, SecretProviderClass, or mount is needed for Jobs. **Requires `data-plane-api >= v1.25.0`**. To opt out on older images, set `dataPlane.components.api.k8sJobs.enabled: false`.
- **`neuraltrust-watchdog` subchart** (default `enabled: false`). Long-running Go service that periodically probes platform components (TrustGate, Control Plane, Data Plane, Firewall, ClickHouse, Kafka, Kafka Connect, Postgres, Redis) and emits OTel events + Prometheus metrics. Optionally restarts Deployments / Kafka Connect tasks behind a `dryRun` flag. See [`charts/neuraltrust-watchdog/README.md`](charts/neuraltrust-watchdog/README.md).
- **In-chart OpenTelemetry Collector** (`templates/otel-collector/`, default `global.observability.enabled: false`). Renders when `global.observability.enabled: true` or when `neuraltrust-watchdog.enabled: true` (watchdog stack expects the in-chart collector for scrapes and optional hosted export). Exports cluster + component telemetry to `collector.neuraltrust.ai` with payload redaction. Gracefully degrades to a local-only collector when no token is configured — installs never break in air-gapped clusters.
- **Optional `global.monitoring.enabled` flag**. When the cluster ships `monitoring.coreos.com/v1` CRDs (Prometheus Operator), every subchart renders a `PrometheusRule` (and TrustGate / OTel Collector additionally render `PodMonitor`/`ServiceMonitor`). Default OFF.
- **`global.observability.collector.endpoint`** umbrella override. Set once and every subchart (TrustGate, Firewall, AISPM) routes OTLP to that endpoint without per-subchart edits. Defaults preserved for upgrades.
- **HTTP liveness + readiness probes** on `control-plane-app` and `control-plane-scheduler`. Default ON; opt out per component via `controlPlane.components.<name>.healthProbes.enabled: false` for older images that don't expose the health route.
- **Optional `PodDisruptionBudget`s** for every Control Plane Deployment, gated per component (`controlPlane.components.<name>.podDisruptionBudget.enabled: true`). Default OFF; only renders when `replicaCount > 1`.
- **Hardened ClickHouse backup CronJob**. Adds `set -euo pipefail`, `activeDeadlineSeconds`, and synchronous BACKUP by default (operators can re-enable ASYNC fire-and-forget via `dataPlane.components.clickhouse.backup.failOnError: false`). The Job now fails loudly on a server-side ClickHouse error instead of always exiting 0.
- **Helm render assertions** (`scripts/test-helm-render.sh`, `.github/workflows/helm-render-tests.yml`) covering: graceful degradation of the hosted exporter, payload redaction processors, watchdog rendering, monitoring CRD gating, and TrustGate/Firewall/AISPM endpoint flipping.
- **Docs**: [`docs/observability.md`](docs/observability.md) (rollout / dry-run / per-check cutover) and the companion [`cloud-infrastructure/docs/alerts-migration.md`](../cloud-infrastructure/docs/alerts-migration.md).
- **Example values**: `values-observability-self-hosted.yaml.example` (in-chart Collector + own Alertmanager) and `values-watchdog.yaml.example` (watchdog standalone with safe defaults).

### Changed

- **In-chart OTel Collector is now OFF by default** (`global.observability.enabled: false`). It auto-deploys when `neuraltrust-watchdog.enabled: true`, or when operators set `global.observability.enabled: true` explicitly. Clusters that relied on the prior always-on default should set one of those flags (or merge `values-self-monitoring.yaml.example`).
- TrustGate's `OPENTELEMETRY_ENABLED` auto-flips to `true` when `global.observability.collector.endpoint` is set; legacy off-by-default behaviour preserved otherwise.
- Firewall and AISPM ConfigMaps prefer `global.observability.collector.endpoint` over their per-subchart defaults. No behaviour change when the global override is unset.
- OTel Collector internal telemetry (`address: 0.0.0.0:8888`) is now exposed via the Collector Service so existing Prometheus Operator installs can scrape collector internals.
- **Fixed**: TrustGate's OTel endpoint ConfigMap now emits the only env names TrustGate-EE actually reads — `OPENTELEMETRY_TRACES_ENDPOINT` and `OPENTELEMETRY_METRICS_ENDPOINT` (`internal/config/config.go`). The previously written `OPENTELEMETRY_ENDPOINT` / `OPENTELEMETRY_OTLP_ENDPOINT` keys were never consumed by the binary and have been removed (safe because no customer is on TrustGate OTel yet). Without this fix TrustGate's OTLP egress was silently a no-op even when the umbrella endpoint was set.
- Control Plane (`api`, `app`) and Data Plane (`api`, `worker`) subcharts now ship an `<component>-otel` ConfigMap that emits `OTEL_ENABLED`, `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_SERVICE_NAME`, `OTEL_ENVIRONMENT` whenever `global.observability.collector.endpoint` is resolved. Each Deployment auto-`envFrom`s the matching ConfigMap. Backward-compatible: ConfigMap and `envFrom` are both omitted when the endpoint is empty.
- **Fixed**: `control-plane-scheduler` liveness/readiness probes now default to `/v1/health` (the route the scheduler binary actually exposes). Probing `/health` hit auth middleware and returned 401, causing CrashLoopBackOff.
- **Fixed**: IPv6-only Kubernetes clusters (e.g. EKS with IPv6-only pod networking) could not start `clickhouse`, `trustgate-redis`, or `control-plane-app` because the bind addresses were hardcoded to `0.0.0.0`. New overrides `clickhouse.listenHost`, `trustgate.redis.bind`, and `controlPlane.components.app.hostname` make the bind address tunable per cluster topology.
  - `clickhouse.listenHost` and `controlPlane.components.app.hostname` default to `::` — on Linux a socket bound to `::` accepts both IPv4 and IPv6 when `net.ipv6.bindv6only=0` (the kernel default), so a single value works on IPv4-only, dual-stack, and IPv6-only clusters.
  - `trustgate.redis.bind` defaults to **`0.0.0.0 -::`** (Redis 7.0+ multi-bind syntax: the `-` prefix marks an address optional, so Redis skips it instead of aborting when the socket cannot be created). This is Redis-specific because the kubelet `tcpSocket` liveness probe connects to the pod's IPv4 address — on certain IPv4-only nodes (notably AWS EKS) a Redis instance bound only to `::` rejected those probes and entered a SIGTERM crash loop. The new default explicitly takes the IPv4 wildcard and adds IPv6 opportunistically. IPv6-only clusters override to `bind: "::"`.
  - Firewall gateway/workers and AISPM were already addressed via image bumps (`firewall v2.9.5`, AISPM CMD) whose entrypoints dual-bind to `0.0.0.0` and `::` at startup; firewall probes also omit `httpGet.host` so kubelet uses the pod IP.
  - Existing IPv4-only clusters continue to work with no change.
- `neuraltrust-watchdog` `data-plane-synthetic` check added (covers `data-plane-api` `/health`, `/health/ready`, `/health/deep`). Default `enabled: false`.
- `neuraltrust-watchdog` `control-plane-synthetic` check now targets the scheduler's actual route — `http://control-plane-scheduler:3000/v1/health` instead of the previously incorrect `/health`.

### Added

- **`global.selfMonitoring.enabled`** umbrella flag and companion overlay `values-self-monitoring.yaml.example`. Merging the overlay on top of customer values enables the watchdog subchart and flips a curated default check set (control plane / data plane / trustgate / firewall synthetics, pod- and deployment-health, otel-collector, cert-renewal, kafka and clickhouse infra) without re-declaring every `target` / `thresholds` / `actions` block.
- **`neuraltrust-watchdog.enabledCheckIds`** additive overlay. Lists check ids to flip on by id without replacing the rest of the check definition. Per-check `enabled: true/false` in `.Values.checks` still wins. Lets the umbrella opt-in stay compact and customer-edits stay surgical.

### Removed

- **`kafka.connectorMonitor` CronJob and Secret are gone.** Functionality moved into the `neuraltrust-watchdog` subchart's `kafka_connect_connectors` check. The `kafka.connectorMonitor` values key is preserved as an empty placeholder so existing customer values files keep rendering, but every nested key under it is now ignored.
  - **Migration**: enable the watchdog (`neuraltrust-watchdog.enabled: true`) and add a `kafka-connect` check pointing at your Kafka Connect URL. To restart FAILED tasks automatically, leave `neuraltrust-watchdog.actions.dryRun: false` and include `kafka_connect.restart_task` in the check's `actions:` list (default keeps `dryRun: true`).
  - **No data loss**: the Helm upgrade garbage-collects `connector-monitor` CronJob + the `kafka-connect-monitor-secrets` Secret. The `monitor-connectors.sh` script remains in the `kafka-connect` image as a manual debug tool but is no longer the production self-heal path.
  - **Auto-bumper**: `.github/workflows/bump-images.yml` no longer touches `kafka.connectorMonitor.image.tag`.
