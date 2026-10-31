{{/*
In-cluster secrets generator.

`helm template` — what ArgoCD and Flux run — cannot `lookup`, so every value the
chart used to generate while rendering came out new on each render, and the sync
applied it. Postgres kept the passwords it was initialised with, so services
stopped authenticating, and the keys that encrypt data at rest (AUTH_SECRET_KEY,
APP_ENCRYPTION_KEY, ADMIN_JWT_SECRET, SERVER_SECRET_KEY) made everything they had
encrypted unreadable. Argo has no per-resource "create once", and a hook Secret is
recreated on every sync, so the values cannot be rendered at all.

Instead a pre-install/pre-upgrade hook Job (templates/secrets-generator.yaml)
creates them in the cluster, once, into Secrets that no release owns: no
`app.kubernetes.io/instance` label and no ownerReferences, so neither Helm nor
Argo tracks, overwrites or prunes them. Workloads reference those Secrets.

The Secrets keep the names the chart rendered before: `platform-secrets` and the
TLS Secrets' own names. One the chart rendered (before 3.7) is taken over before
anything is written: the Job removes Argo's tracking and marks it
`Prune=false,Delete=false`, so the sync that stops rendering it cannot prune it.
A failed takeover fails the Job, and Argo stops the sync before pruning. 3.7 to
3.9 wrote to `neuraltrust-generated` and `neuraltrust-generated-<id>-tls`; their
values are adopted first and the Secrets are left in place, unread.

Each component describes what it needs in a hook ConfigMap rendered from its own
context (`secretsGenerator.specObjects`), because only a subchart sees its own
values.yaml defaults. Values an operator pinned in values travel in a matching
hook Secret and always win. Per key the Job keeps an existing value, else adopts
the value the chart rendered before (so upgrades rotate nothing), else
generates.

Scope: external and saas installs. Hybrid keeps render-time generation: it runs
no control-plane image, which the Job uses.
*/}}

{{/*
Whether the generator owns the chart-generated credentials of this install.
Needs the chart's root context (umbrella or subchart): `.Release` and `lookup`.

`global.secrets.generator.enabled`:
  true   on
  false  off: every credential is generated while rendering, as before
  auto   (default) on, except for a `helm upgrade` of a release the generator has
         never run for (neither a `platform-secrets` it marked nor the earlier
         `neuraltrust-generated` in the namespace). That release
         keeps generating while rendering, which is safe there because Helm's
         `lookup` reuses the live values, so a platform already deployed with Helm
         keeps working exactly as it did. `helm template` — what ArgoCD and Flux's
         source rendering run — always renders an install and cannot `lookup`, so
         it is always on: that is the case where rendering rotated every value.
*/}}
{{- define "neuraltrust-platform.secretsGenerator.active" -}}
{{- if not .Release -}}
{{- fail "internal: neuraltrust-platform.secretsGenerator.active needs the chart's root context; pass \"ctx\" $ to the helper that called it" -}}
{{- end -}}
{{- $g := default dict .Values.global -}}
{{- $cfg := default dict (default dict $g.secrets).generator -}}
{{- $mode := "auto" -}}
{{- if hasKey $cfg "enabled" -}}{{- $mode = $cfg.enabled | toString | lower -}}{{- end -}}
{{- $enabled := eq $mode "true" -}}
{{- if eq $mode "auto" -}}
  {{- if .Release.IsInstall -}}{{- $enabled = true -}}
  {{- else if lookup "v1" "Secret" .Release.Namespace (include "neuraltrust-platform.secretsGenerator.previousName" .) -}}{{- $enabled = true -}}
  {{- else -}}
    {{- $live := lookup "v1" "Secret" .Release.Namespace (include "neuraltrust-platform.secretsGenerator.name" .) -}}
    {{- $annotations := default dict (default dict (default dict $live).metadata).annotations -}}
    {{- if eq (index $annotations (include "neuraltrust-platform.secretsGenerator.marker" .) | default "") "managed" -}}{{- $enabled = true -}}{{- end -}}
  {{- end -}}
{{- end -}}
{{- if and $enabled
  (eq (include "neuraltrust-platform.autoGenerateSecrets" .) "true")
  (not $g.preserveExistingSecrets)
  (eq (include "neuraltrust-platform.isExternal" .) "true") -}}true{{- end -}}
{{- end }}

{{- define "neuraltrust-platform.secretsGenerator.name" -}}platform-secrets{{- end }}

{{/*
Name of a generated TLS Secret. `id` is one of the names in
`secretsGenerator.tlsIds`, which the Job's Role is scoped to.
*/}}
{{- define "neuraltrust-platform.secretsGenerator.tlsName" -}}
{{- if eq .id "ingress" -}}neuraltrust-ingress-tls{{- else -}}{{ .id }}-tls{{- end -}}
{{- end }}
{{- define "neuraltrust-platform.secretsGenerator.tlsIds" -}}trustguard-configsync agentgateway-configsync ingress databridge-southbound clickstack-ingest-gateway{{- end }}

{{/*
Where chart 3.7 to 3.9 wrote the same values. Adopted first, then left in place.
*/}}
{{- define "neuraltrust-platform.secretsGenerator.previousName" -}}neuraltrust-generated{{- end }}
{{- define "neuraltrust-platform.secretsGenerator.previousTlsName" -}}neuraltrust-generated-{{ .id }}-tls{{- end }}

{{/*
Annotation on every Secret the generator writes: `managed` once it has created or
taken it over. An operator who sets it to `external` keeps the generator from
ever writing that Secret; the Job then only checks it holds every key it needs.
*/}}
{{- define "neuraltrust-platform.secretsGenerator.marker" -}}neuraltrust.ai/secrets-generator{{- end }}

{{/*
Components that may contribute a spec. The Job reads
`neuraltrust-generator-spec-<component>` (and `-pins-<component>`) for each, so a
new contributor has to be added here, where the Role is also scoped.
*/}}
{{- define "neuraltrust-platform.secretsGenerator.components" -}}platform postgresql trustguard-client ingress alertengine datacore trustguard agentgateway clickhouse clickstack-collector databridge clickstack-ingest-gateway{{- end }}

{{/*
Secrets the Job may read to adopt a value the chart rendered before. Adoption
entries outside this list fail the Job's Role, so keep it in step with the specs.
*/}}
{{- define "neuraltrust-platform.secretsGenerator.adoptable" -}}platform-secrets control-plane-secrets data-plane-jwt-secret postgresql-secrets firewall-secrets alertengine-secrets datacore-secrets trustguard-secrets agentgateway-secrets clickhouse clickstack-collector-secrets trustguard-client-credentials trustguard-configsync-tls agentgateway-configsync-tls neuraltrust-ingress-tls databridge-southbound-tls clickstack-ingest-gateway-tls agentgateway-m2m-keys mcp-oauth-signing{{- end }}

{{/*
Whether the generator writes the registry keys into `platform-secrets`: it is
active, consumers read the shared Secret, and the operator does not supply it
under another name. Then it also mints the RSA keys the keygen hooks
(templates/_keygen.tpl) used to, so no install needs a hook beyond the
generator's.
*/}}
{{- define "neuraltrust-platform.secretsGenerator.ownsPlatform" -}}
{{- $target := include "neuraltrust-platform.secretsGenerator.name" . -}}
{{- if and
  (eq (include "neuraltrust-platform.secretsGenerator.active" .) "true")
  (eq (include "neuraltrust-platform.platformSecret.name" .) $target)
  (not (default dict (default dict (default dict .Values.global).platformSecret).existingSecret).name) -}}true{{- end -}}
{{- end }}

{{/*
In-cluster PostgreSQL that the chart runs itself (deploy on, no host). Only then
are the admin password and the service role passwords the chart's to mint.
*/}}
{{- define "neuraltrust-platform.secretsGenerator.pgInCluster" -}}
{{- $pg := default dict (default dict .Values.global).postgresql -}}
{{- if and (eq (include "neuraltrust-platform.postgresql.deploy" .) "true") (not ($pg.host | default "")) -}}true{{- end -}}
{{- end }}

{{/*
The Secret and key a service's database password comes from: the operator's
`existingSecret` when set, else (unless the password is pinned in values, which
renders identically every time) the generated Secret when the chart owns the role
(its own PostgreSQL, or managedBootstrap creating roles on a managed one), else
nothing, which leaves the service on its chart Secret as before.

  (dict "ctx" . "db" .Values.database "key" "ALERTENGINE_DB_PASSWORD")

Returns YAML; pipe through fromYaml. Callable from the umbrella or a subchart, as
long as `db` is that service's `database` block.
*/}}
{{- define "neuraltrust-platform.dbPasswordRef" -}}
{{- $db := default dict .db -}}
{{- $ref := default dict $db.existingSecret -}}
{{- if $ref.name -}}
{{- toYaml $ref -}}
{{- else if and
  (eq (include "neuraltrust-platform.secretsGenerator.active" .ctx) "true")
  (not ($db.password | default ""))
  (ne (include "neuraltrust-platform.postgres.iamAuth" (dict "ctx" .ctx "database" $db)) "true")
  (or (eq (include "neuraltrust-platform.secretsGenerator.pgInCluster" .ctx) "true")
      (eq (include "neuraltrust-platform.postgresql.managedBootstrap.enabled" .ctx) "true")) -}}
name: {{ include "neuraltrust-platform.secretsGenerator.name" .ctx | quote }}
key: {{ .key | quote }}
{{- end -}}
{{- end }}

{{/*
A service's database-password entry and pin, when that password is generated
(`dbPasswordRef` points at the generated Secret). Empty otherwise.

  (dict "ctx" . "db" .Values.database "key" "ALERTENGINE_DB_PASSWORD"
        "adopt" (list (list "alertengine-secrets" "DB_PASSWORD")))

Returns YAML {entry, pin}; pipe through fromYaml.
*/}}
{{- define "neuraltrust-platform.secretsGenerator.dbEntry" -}}
{{- $ref := include "neuraltrust-platform.dbPasswordRef" (dict "ctx" .ctx "db" .db "key" .key) | fromYaml -}}
{{- if eq ($ref.name | default "") (include "neuraltrust-platform.secretsGenerator.name" .ctx) -}}
entry: {{ dict "key" .key "type" "alnum" "length" 32 "adopt" .adopt | toJson }}
{{- with (default dict .db).password }}
pin: {{ . | toString | quote }}
{{- end }}
{{- end -}}
{{- end }}

{{/*
Whether the generator owns the in-cluster ClickHouse password: the install runs
the chart's ClickHouse (no global.clickhouse.host) and no operator Secret holds
the password. Takes the chart's root context.
*/}}
{{- define "neuraltrust-platform.clickhouse.generated" -}}
{{- $gch := default dict (default dict .Values.global).clickhouse -}}
{{- if and
  (eq (include "neuraltrust-platform.secretsGenerator.active" .) "true")
  (not ($gch.host | default ""))
  (not (default dict $gch.existingSecret).name) -}}true{{- end -}}
{{- end }}

{{/*
Whether the generator owns the control-plane PostgreSQL password: the chart
mints it, because it runs the instance or creates the roles on a managed one
(managedBootstrap), auth is a password, and the operator named neither a
`passwordSecret`, a whole `existingSecret`, nor a `global.postgresql.password`
(pinned, it renders identically every time and keeps its old path). Then
`postgresql.passwordSecretRef`
points every reader (the server itself, the bootstrap Job, the app and APIs) at
the generated Secret, through the same path an operator `passwordSecret` takes.
Rendered instead, a managed role's password changed on every ArgoCD sync, and
the bootstrap Job reset the role to it only after the pods had rolled.
*/}}
{{- define "neuraltrust-platform.postgresql.generatedAdmin" -}}
{{- $pg := default dict (default dict .Values.global).postgresql -}}
{{- if and
  (eq (include "neuraltrust-platform.secretsGenerator.active" .) "true")
  (or (eq (include "neuraltrust-platform.secretsGenerator.pgInCluster" .) "true")
      (eq (include "neuraltrust-platform.postgresql.managedBootstrap.enabled" .) "true"))
  (not (default dict $pg.passwordSecret).name)
  (not (default dict $pg.existingSecret).name)
  (not ($pg.password | default "")) -}}true{{- end -}}
{{- end }}

{{/*
Whether the generator owns the TrustGuard platform client secret: the install
carries the client pair (`trustguardClient.enabled`). CLIENT_ID stays in
trustguard-client-credentials; it is configuration, not a secret, and identical
on every render.
*/}}
{{- define "neuraltrust-platform.trustguardClient.generated" -}}
{{- if and
  (eq (include "neuraltrust-platform.secretsGenerator.active" .) "true")
  (eq (include "neuraltrust-platform.trustguardClient.enabled" .) "true")
  (not (default dict (default dict .Values.global).v2).trustguardClientSecretName) -}}true{{- end -}}
{{- end }}

{{/*
A component's contribution to the generator: a hook ConfigMap with its entries,
and a hook Secret with the values the operator pinned for them.

  (dict "ctx" . "component" "alertengine" "entries" $entries "pins" $pins)

entries: list of dicts, each one key of the generated Secret (or one TLS Secret):
  key       key in `neuraltrust-generated`
  type      alnum (length), base64 (bytes), rsa-pkcs1, rsa-pkcs8 (bits, default
            4096), install (alnum, generated only on a fresh install, see
            freshIf), adopt (never generated), alias (= source), derived
            (format with %s = source), public-key (the public half of the
            private key in source, as base64 of its SPKI PEM), tls
  length    alnum / install length, or base64 byte count
  adopt     ordered [secretName, key] pairs the chart rendered the value into before
  freshIf   install: generate only when none of these Secrets exists
  tls       cn, sans, days, selfSigned, caCn; `secret` names the TLS Secret;
            `reissue` replaces one issued for other SANs (a published listener);
            `annotations` are written on it alongside the SANs digest
pins: key -> value. Rendered only from values, so it is identical on every render.

Both are deleted once the sync succeeds (hook-succeeded), like the Job's
ServiceAccount and Role: Helm deletes succeeded hooks only after every hook of the
event has run, and Argo only when the whole operation has completed, so the Job (a
later weight) always reads them first. A component the next render drops then
leaves no spec behind for the Job to act on, and pinned values do not linger in
the namespace. The `specLabel` marks the format: the Job ignores, and
removes, spec objects an earlier chart left without it.
*/}}
{{- define "neuraltrust-platform.secretsGenerator.specLabel" -}}neuraltrust.ai/generator-spec{{- end }}
{{- define "neuraltrust-platform.secretsGenerator.specFormat" -}}2{{- end }}
{{- define "neuraltrust-platform.secretsGenerator.specObjects" -}}
{{- $ctx := .ctx -}}
{{- if and (eq (include "neuraltrust-platform.secretsGenerator.active" $ctx) "true") .entries }}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: neuraltrust-generator-spec-{{ .component }}
  namespace: {{ $ctx.Release.Namespace }}
  annotations:
    helm.sh/hook: pre-install,pre-upgrade
    helm.sh/hook-weight: "-20"
    helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
  labels:
    app.kubernetes.io/managed-by: {{ $ctx.Release.Service }}
    app.kubernetes.io/component: secrets-generator
    {{ include "neuraltrust-platform.secretsGenerator.specLabel" . }}: {{ include "neuraltrust-platform.secretsGenerator.specFormat" . | quote }}
data:
  spec.json: {{ toJson .entries | quote }}
{{- if .pins }}
---
apiVersion: v1
kind: Secret
metadata:
  name: neuraltrust-generator-pins-{{ .component }}
  namespace: {{ $ctx.Release.Namespace }}
  annotations:
    helm.sh/hook: pre-install,pre-upgrade
    helm.sh/hook-weight: "-20"
    helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
  labels:
    app.kubernetes.io/managed-by: {{ $ctx.Release.Service }}
    app.kubernetes.io/component: secrets-generator
    {{ include "neuraltrust-platform.secretsGenerator.specLabel" . }}: {{ include "neuraltrust-platform.secretsGenerator.specFormat" . | quote }}
type: Opaque
data:
  {{- range $k := (keys .pins | sortAlpha) }}
  {{ $k }}: {{ index $.pins $k | toString | b64enc }}
  {{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
The generator Job's program (Node, from the app image). Kept free of `{{`.

Per scalar entry, first that applies: a pinned value (always wins); the value the
generated Secret already holds (never replaced); the first non-empty adoption
source; otherwise generate. Aliases and derived keys are recomputed from their
source on every run. A TLS Secret that exists is kept; otherwise it is adopted
from the Secret the chart rendered before, else issued with openssl.

Only ever POSTs a missing Secret or merge-PATCHes the keys that changed, so a
run with nothing to do writes nothing, and no key is ever removed.
*/}}
{{- define "neuraltrust-platform.secretsGenerator.script" -}}
const crypto = require('node:crypto')
const fs = require('node:fs')
const path = require('node:path')
const { execFileSync } = require('node:child_process')

const sa = '/var/run/secrets/kubernetes.io/serviceaccount'
const ns = fs.readFileSync(sa + '/namespace', 'utf8').trim()
const token = fs.readFileSync(sa + '/token', 'utf8').trim()
// Dial the API server by name, not KUBERNETES_SERVICE_HOST: see _keygen.tpl.
const port = process.env.KUBERNETES_SERVICE_PORT || '443'
const base = 'https://kubernetes.default.svc:' + port + '/api/v1/namespaces/' + ns
const auth = { Authorization: 'Bearer ' + token }
const TARGET = process.env.GENERATED_SECRET
const COMPONENTS = (process.env.SPEC_COMPONENTS || '').split(' ').filter(Boolean)
const SPEC_LABEL = process.env.SPEC_LABEL
const SPEC_FORMAT = process.env.SPEC_FORMAT
const PREVIOUS = process.env.PREVIOUS_SECRET
const PREVIOUS_TLS = JSON.parse(process.env.PREVIOUS_TLS || '{}')
const MARKER = process.env.MARKER
// Secrets the operator supplies under a name the generator would write.
const OPERATOR = (process.env.OPERATOR_SECRETS || '').split(' ').filter(Boolean)

// Untracked on purpose: no app.kubernetes.io/instance label and no owner, so no
// release manages, overwrites or prunes these. The Argo annotations are a second
// line of defence for label-tracking setups.
const ARGO = {
  'argocd.argoproj.io/compare-options': 'IgnoreExtraneous',
  'argocd.argoproj.io/sync-options': 'Prune=false,Delete=false',
}
const METADATA = {
  labels: {
    'app.kubernetes.io/part-of': 'neuraltrust-platform',
    'app.kubernetes.io/managed-by': 'neuraltrust-secrets-generator',
  },
  annotations: Object.assign({ [MARKER]: 'managed' }, ARGO),
}

async function get(kind, name) {
  const res = await fetch(base + '/' + kind + '/' + name, { headers: auth })
  if (res.status === 404) return null
  if (!res.ok) throw new Error('read ' + kind + '/' + name + ' failed: ' + res.status + ' ' + (await res.text()))
  return res.json()
}

async function remove(kind, name) {
  const res = await fetch(base + '/' + kind + '/' + name, { method: 'DELETE', headers: auth })
  if (!res.ok && res.status !== 404) throw new Error('delete ' + kind + '/' + name + ' failed: ' + res.status + ' ' + (await res.text()))
}

// A spec object this chart rendered carries the format label. One without it was
// left by an earlier chart, for a component the current render no longer asks
// for: acting on it would keep or create a Secret nothing reads.
async function currentSpec(kind, name) {
  const obj = await get(kind, name)
  if (!obj) return null
  if (((obj.metadata || {}).labels || {})[SPEC_LABEL] === SPEC_FORMAT) return obj
  await remove(kind, name)
  console.log(kind.replace(/s$/, '') + ' ' + name + ': left by an earlier chart, removed')
  return null
}

function decode(obj) {
  const out = {}
  for (const [k, v] of Object.entries((obj && obj.data) || {})) out[k] = Buffer.from(v, 'base64').toString('utf8')
  return out
}

function encode(values) {
  const out = {}
  for (const [k, v] of Object.entries(values)) out[k] = Buffer.from(v, 'utf8').toString('base64')
  return out
}

// Who owns a Secret the generator writes, decided before anything is written:
//   absent    the generator creates it
//   managed   created or taken over by an earlier run: its values stand
//   external  the operator's (ownerReferences, e.g. External Secrets; the
//             marker set to external; or named in values): never written,
//             only checked
//   taken     rendered by an earlier chart (Helm, Argo): taken over now
// Taking over removes Argo's tracking and marks it Prune=false,Delete=false, so
// the sync that stops rendering it cannot prune it. A failed patch fails the Job,
// and Argo stops the sync before its prune step.
async function claim(name) {
  const live = await get('secrets', name)
  if (!live) return { live: null, owner: 'absent' }
  const meta = live.metadata || {}
  const marker = (meta.annotations || {})[MARKER]
  if (marker === 'managed') return { live: live, owner: 'managed' }
  if (OPERATOR.includes(name) || marker === 'external' || (meta.ownerReferences || []).length) {
    return { live: live, owner: 'external' }
  }
  const res = await fetch(base + '/secrets/' + name, {
    method: 'PATCH',
    headers: Object.assign({ 'Content-Type': 'application/merge-patch+json' }, auth),
    body: JSON.stringify({
      metadata: {
        labels: { 'app.kubernetes.io/instance': null },
        annotations: Object.assign({ 'argocd.argoproj.io/tracking-id': null, [MARKER]: 'managed' }, ARGO),
      },
    }),
  })
  if (!res.ok) throw new Error('take over ' + name + ' failed: ' + res.status + ' ' + (await res.text()))
  console.log(name + ': taken over from the release that rendered it')
  return { live: await res.json(), owner: 'taken' }
}

async function write(name, live, data, type, annotations) {
  if (!live) {
    const meta = { name: name, namespace: ns, labels: METADATA.labels, annotations: Object.assign({}, METADATA.annotations, annotations || {}) }
    const res = await fetch(base + '/secrets', {
      method: 'POST',
      headers: Object.assign({ 'Content-Type': 'application/json' }, auth),
      body: JSON.stringify({ apiVersion: 'v1', kind: 'Secret', type: type, metadata: meta, data: encode(data) }),
    })
    // A concurrent run created it first; the next run adopts what it wrote.
    if (res.status === 409) throw new Error(name + ' was created concurrently; retrying')
    if (!res.ok) throw new Error('create ' + name + ' failed: ' + res.status + ' ' + (await res.text()))
    return
  }
  const body = { data: encode(data) }
  if (annotations) body.metadata = { annotations: annotations }
  const res = await fetch(base + '/secrets/' + name, {
    method: 'PATCH',
    headers: Object.assign({ 'Content-Type': 'application/merge-patch+json' }, auth),
    body: JSON.stringify(body),
  })
  if (!res.ok) throw new Error('patch ' + name + ' failed: ' + res.status + ' ' + (await res.text()))
}

// Unbiased: 248 is the largest multiple of 62 below 256.
const ALNUM = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
function alnum(n) {
  let out = ''
  while (out.length < n) {
    for (const b of crypto.randomBytes(n * 2)) {
      if (b < 248) out += ALNUM[b % 62]
      if (out.length === n) break
    }
  }
  return out
}

function generate(e) {
  switch (e.type) {
    case 'alnum':
    case 'install':
      return alnum(e.length || 64)
    case 'base64':
      return crypto.randomBytes(e.length || 32).toString('base64')
    // Same shape as Sprig's genPrivateKey "rsa": a 4096-bit PKCS#1 PEM.
    case 'rsa-pkcs1':
      return crypto.generateKeyPairSync('rsa', { modulusLength: e.bits || 4096 }).privateKey.export({ type: 'pkcs1', format: 'pem' }).toString()
    case 'rsa-pkcs8':
      return crypto.generateKeyPairSync('rsa', { modulusLength: e.bits || 4096 }).privateKey.export({ type: 'pkcs8', format: 'pem' }).toString()
  }
  throw new Error('unknown type ' + e.type + ' for ' + e.key)
}

// Same digest the chart's TLS templates annotate: sha256 of the comma-joined SANs, 16 hex chars.
function sansHash(sans) {
  return crypto.createHash('sha256').update(sans.join(',')).digest('hex').slice(0, 16)
}

function openssl(args, cwd) {
  try {
    execFileSync('openssl', args, { cwd: cwd, stdio: ['ignore', 'ignore', 'pipe'] })
  } catch (err) {
    throw new Error('openssl ' + args[0] + ' failed: ' + String(err.stderr || err))
  }
}

function issue(e) {
  const dir = fs.mkdtempSync('/tmp/tls-')
  const san = e.sans.map((s) => (/^[0-9.]+$/.test(s) || s.includes(':') ? 'IP:' : 'DNS:') + s).join(',')
  const days = String(e.days || 3650)
  if (e.selfSigned) {
    openssl(['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'tls.key', '-out', 'tls.crt', '-days', days,
      '-subj', '/CN=' + e.cn, '-addext', 'subjectAltName=' + san], dir)
  } else {
    openssl(['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'ca.key', '-out', 'ca.crt', '-days', days,
      '-subj', '/CN=' + e.caCn, '-addext', 'basicConstraints=critical,CA:TRUE', '-addext', 'keyUsage=critical,keyCertSign,cRLSign'], dir)
    openssl(['req', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'tls.key', '-out', 'tls.csr', '-subj', '/CN=' + e.cn], dir)
    fs.writeFileSync(path.join(dir, 'ext'), 'subjectAltName=' + san + '\nbasicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n')
    openssl(['x509', '-req', '-in', 'tls.csr', '-CA', 'ca.crt', '-CAkey', 'ca.key', '-CAcreateserial', '-out', 'tls.crt', '-days', days, '-extfile', 'ext'], dir)
  }
  const read = (f) => fs.readFileSync(path.join(dir, f), 'utf8')
  const out = { 'tls.crt': read('tls.crt'), 'tls.key': read('tls.key'), 'ca.crt': e.selfSigned ? read('tls.crt') : read('ca.crt') }
  fs.rmSync(dir, { recursive: true, force: true })
  return out
}

const sources = {}
async function source(name) {
  if (!(name in sources)) sources[name] = await get('secrets', name)
  return sources[name]
}

// The SANs digest a TLS Secret was issued for, from its annotation.
function issuedFor(obj) {
  return (((obj && obj.metadata) || {}).annotations || {})['neuraltrust.ai/tls-sans'] || ''
}

// The certificate the services use now, first that applies: the TLS Secret when
// the generator already manages it; the earlier generator's copy (3.7 to 3.9);
// the Secret itself as an earlier chart rendered it; the other adoption sources;
// otherwise a new one.
//
// `reissue` marks a certificate other clusters dial under its public name: one
// issued for other names no longer fits, so only a certificate whose SANs digest
// matches counts, and a new set of names (global.controlPlane.domain retargeted)
// issues a new one, as the chart's own template did.
async function tls(e, claimed) {
  const hash = sansHash(e.sans)
  const annotations = Object.assign({}, e.annotations || {}, { 'neuraltrust.ai/tls-sans': hash })
  const fits = (obj) => !e.reissue || issuedFor(obj) === hash
  const complete = (d) => d['tls.crt'] && d['tls.key'] && (e.selfSigned || d['ca.crt'])
  const { live, owner } = claimed
  const own = decode(live)
  if (owner === 'external') {
    if (!complete(own)) throw new Error(e.secret + ' is supplied by the operator but lacks tls.crt, tls.key or ca.crt; the generator does not write it')
    console.log(e.secret + ': supplied by the operator, kept')
    return
  }
  if (owner === 'managed' && complete(own) && fits(live)) {
    console.log(e.secret + ': present, kept')
    return
  }
  const candidates = []
  if (PREVIOUS_TLS[e.secret]) candidates.push([PREVIOUS_TLS[e.secret], await source(PREVIOUS_TLS[e.secret])])
  candidates.push([e.secret, live])
  for (const [name] of e.adopt || []) if (name !== e.secret) candidates.push([name, await source(name)])
  for (const [name, obj] of candidates) {
    const d = decode(obj)
    if (!complete(d) || !fits(obj)) continue
    const data = { 'tls.crt': d['tls.crt'], 'tls.key': d['tls.key'], 'ca.crt': d['ca.crt'] || d['tls.crt'] }
    if (Object.keys(data).every((k) => own[k] === data[k])) {
      console.log(e.secret + ': present, kept')
    } else {
      await write(e.secret, live, data, 'kubernetes.io/tls', annotations)
      console.log(e.secret + ': adopted from ' + name)
    }
    return
  }
  await write(e.secret, live, issue(e), 'kubernetes.io/tls', annotations)
  console.log(e.secret + ': issued for ' + e.sans.join(', '))
}

// Keys the generator would have to write into a Secret it may not write.
function missing(entries, values) {
  return entries.filter((e) => e.type !== 'adopt' && !((e.type === 'alias' || e.type === 'public-key') && !values[e.source]) && !values[e.key]).map((e) => e.key)
}

async function main() {
  const specs = []
  const pins = {}
  for (const c of COMPONENTS) {
    const cm = await currentSpec('configmaps', 'neuraltrust-generator-spec-' + c)
    const pinned = await currentSpec('secrets', 'neuraltrust-generator-pins-' + c)
    if (!cm) continue
    for (const e of JSON.parse(cm.data['spec.json'])) specs.push(e)
    Object.assign(pins, decode(pinned))
  }

  // Every takeover happens before any value is written, so a refused patch
  // leaves everything as it was.
  const scalars = specs.filter((e) => e.type !== 'tls')
  const tlsSpecs = specs.filter((e) => e.type === 'tls')
  const target = scalars.length ? await claim(TARGET) : null
  const tlsTargets = {}
  for (const e of tlsSpecs) tlsTargets[e.secret] = await claim(e.secret)

  if (target && target.owner === 'external') {
    const absent = missing(scalars, decode(target.live))
    if (absent.length) {
      throw new Error(TARGET + ' is supplied by the operator, so the generator does not write it, and it lacks: ' + absent.join(', '))
    }
    console.log(TARGET + ': supplied by the operator, holds every key')
    for (const e of tlsSpecs) await tls(e, tlsTargets[e.secret])
    return
  }

  const live = target ? target.live : null
  const current = decode(live)
  // A Secret an earlier chart rendered holds what that chart rendered; the
  // earlier generator's copy holds what the services read since, so it wins.
  const next = target && target.owner === 'managed' ? Object.assign({}, current) : Object.assign({}, current, decode(await source(PREVIOUS)))
  const late = ['alias', 'derived', 'public-key']
  const ordered = scalars.filter((e) => !late.includes(e.type)).concat(scalars.filter((e) => late.includes(e.type)))
  for (const e of ordered) {
    const k = e.key
    if (e.type === 'alias' || e.type === 'derived') {
      const src = next[e.source]
      if (src) next[k] = e.type === 'alias' ? src : e.format.replace('%s', src)
      continue
    }
    // The public half of a private key in this Secret, as the keygen hook wrote
    // it: the SPKI PEM, base64-encoded onto one line. Always derived, so the
    // two halves cannot drift apart.
    if (e.type === 'public-key') {
      const src = next[e.source]
      if (src) next[k] = Buffer.from(crypto.createPublicKey(crypto.createPrivateKey(src)).export({ type: 'spki', format: 'pem' }).toString()).toString('base64')
      continue
    }
    if (pins[k]) {
      if (next[k] !== pins[k]) console.log(k + ': set from values')
      next[k] = pins[k]
      continue
    }
    if (next[k]) continue
    let adopted = ''
    for (const [name, key] of e.adopt || []) {
      const d = decode(await source(name))
      if (d[key]) {
        adopted = d[key]
        console.log(k + ': adopted from ' + name + '/' + key)
        break
      }
    }
    if (adopted) {
      next[k] = adopted
      continue
    }
    if (e.type === 'adopt') continue
    if (e.type === 'install') {
      // The earlier generator's Secret means the install predates this run too.
      let predates = !!(await source(PREVIOUS))
      for (const name of e.freshIf || []) if (await source(name)) predates = true
      if (predates) {
        console.log(k + ': not generated, the install predates it and may hold data under the default')
        continue
      }
    }
    next[k] = generate(e)
    console.log(k + ': generated (' + e.type + ')')
  }

  const changed = {}
  for (const [k, v] of Object.entries(next)) if (current[k] !== v) changed[k] = v
  if (!target) {
    // No scalar entries in this install: nothing to write.
  } else if (!live && Object.keys(next).length) {
    await write(TARGET, null, next, 'Opaque')
    console.log(TARGET + ': created with ' + Object.keys(next).length + ' keys')
  } else if (Object.keys(changed).length) {
    await write(TARGET, live, changed, 'Opaque')
    console.log(TARGET + ': updated ' + Object.keys(changed).sort().join(', '))
  } else {
    console.log(TARGET + ': nothing to do, ' + Object.keys(current).length + ' keys already present')
  }

  for (const e of tlsSpecs) await tls(e, tlsTargets[e.secret])
}

main().catch((err) => {
  console.error(String(err))
  process.exit(1)
})
{{- end }}
