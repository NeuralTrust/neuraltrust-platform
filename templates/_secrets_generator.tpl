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

Each component describes what it needs in a hook ConfigMap rendered from its own
context (`secretsGenerator.specObjects`), because only a subchart sees its own
values.yaml defaults. Values an operator pinned in values travel in a matching
hook Secret and always win. Per key the Job keeps an existing value, else adopts
the value the chart rendered before (so upgrades rotate nothing), else
generates.

Scope: external installs. Hybrid and saas keep render-time generation for now.
*/}}

{{/*
Whether the generator owns the chart-generated credentials of this install.
Needs the chart's root context (umbrella or subchart): `.Release` and `lookup`.

`global.secrets.generator.enabled`:
  true   on
  false  off: every credential is generated while rendering, as before
  auto   (default) on, except for a `helm upgrade` of a release the generator has
         never run for (no `neuraltrust-generated` in the namespace). That release
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
  {{- else if lookup "v1" "Secret" .Release.Namespace "neuraltrust-generated" -}}{{- $enabled = true -}}
  {{- end -}}
{{- end -}}
{{- if and $enabled
  (eq (include "neuraltrust-platform.autoGenerateSecrets" .) "true")
  (not $g.preserveExistingSecrets)
  (eq (include "neuraltrust-platform.isExternal" .) "true")
  (ne (include "neuraltrust-platform.isSaas" .) "true") -}}true{{- end -}}
{{- end }}

{{- define "neuraltrust-platform.secretsGenerator.name" -}}neuraltrust-generated{{- end }}

{{/*
Name of a generated TLS Secret. `id` is one of the names in
`secretsGenerator.tlsIds`, which the Job's Role is scoped to.
*/}}
{{- define "neuraltrust-platform.secretsGenerator.tlsName" -}}neuraltrust-generated-{{ .id }}-tls{{- end }}
{{- define "neuraltrust-platform.secretsGenerator.tlsIds" -}}trustguard-configsync agentgateway-configsync ingress{{- end }}

{{/*
Components that may contribute a spec. The Job reads
`neuraltrust-generator-spec-<component>` (and `-pins-<component>`) for each, so a
new contributor has to be added here, where the Role is also scoped.
*/}}
{{- define "neuraltrust-platform.secretsGenerator.components" -}}platform postgresql trustguard-client ingress alertengine datacore trustguard agentgateway clickhouse clickstack-collector{{- end }}

{{/*
Secrets the Job may read to adopt a value the chart rendered before. Adoption
entries outside this list fail the Job's Role, so keep it in step with the specs.
*/}}
{{- define "neuraltrust-platform.secretsGenerator.adoptable" -}}platform-secrets control-plane-secrets data-plane-jwt-secret postgresql-secrets firewall-secrets alertengine-secrets datacore-secrets trustguard-secrets agentgateway-secrets clickhouse clickstack-collector-secrets trustguard-client-credentials trustguard-configsync-tls agentgateway-configsync-tls neuraltrust-ingress-tls{{- end }}

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
Whether the generator owns the in-cluster PostgreSQL admin password: the chart
runs the instance, auth is a password, and the operator named neither a
`passwordSecret`, a whole `existingSecret`, nor a `global.postgresql.password`
(pinned, it renders identically every time and keeps its old path). Then
`postgresql.passwordSecretRef`
points every reader (the server itself, the bootstrap Job, the app and APIs) at
the generated Secret, through the same path an operator `passwordSecret` takes.
*/}}
{{- define "neuraltrust-platform.postgresql.generatedAdmin" -}}
{{- $pg := default dict (default dict .Values.global).postgresql -}}
{{- if and
  (eq (include "neuraltrust-platform.secretsGenerator.active" .) "true")
  (eq (include "neuraltrust-platform.secretsGenerator.pgInCluster" .) "true")
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
  (eq (include "neuraltrust-platform.trustguardClient.enabled" .) "true") -}}true{{- end -}}
{{- end }}

{{/*
A component's contribution to the generator: a hook ConfigMap with its entries,
and a hook Secret with the values the operator pinned for them.

  (dict "ctx" . "component" "alertengine" "entries" $entries "pins" $pins)

entries: list of dicts, each one key of the generated Secret (or one TLS Secret):
  key       key in `neuraltrust-generated`
  type      alnum (length), base64 (bytes), rsa-pkcs1, rsa-pkcs8, install (alnum,
            generated only on a fresh install, see freshIf), adopt (never
            generated), alias (= source), derived (format with %s = source), tls
  length    alnum / install length, or base64 byte count
  adopt     ordered [secretName, key] pairs the chart rendered the value into before
  freshIf   install: generate only when none of these Secrets exists
  tls       cn, sans, days, selfSigned, caCn; `secret` names the TLS Secret
pins: key -> value. Rendered only from values, so it is identical on every render.

The hook-delete policy is before-hook-creation only: under Argo a Secret or
ConfigMap hook "succeeds" the moment it exists, so hook-succeeded could delete it
before the Job (a later weight) reads it.
*/}}
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
    helm.sh/hook-delete-policy: before-hook-creation
  labels:
    app.kubernetes.io/managed-by: {{ $ctx.Release.Service }}
    app.kubernetes.io/component: secrets-generator
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
    helm.sh/hook-delete-policy: before-hook-creation
  labels:
    app.kubernetes.io/managed-by: {{ $ctx.Release.Service }}
    app.kubernetes.io/component: secrets-generator
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

// Untracked on purpose: no app.kubernetes.io/instance label and no owner, so no
// release manages, overwrites or prunes these. The Argo annotations are a second
// line of defence for label-tracking setups.
const METADATA = {
  labels: {
    'app.kubernetes.io/part-of': 'neuraltrust-platform',
    'app.kubernetes.io/managed-by': 'neuraltrust-secrets-generator',
  },
  annotations: {
    'argocd.argoproj.io/compare-options': 'IgnoreExtraneous',
    'argocd.argoproj.io/sync-options': 'Prune=false,Delete=false',
  },
}

async function get(kind, name) {
  const res = await fetch(base + '/' + kind + '/' + name, { headers: auth })
  if (res.status === 404) return null
  if (!res.ok) throw new Error('read ' + kind + '/' + name + ' failed: ' + res.status + ' ' + (await res.text()))
  return res.json()
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
      return crypto.generateKeyPairSync('rsa', { modulusLength: 4096 }).privateKey.export({ type: 'pkcs1', format: 'pem' }).toString()
    case 'rsa-pkcs8':
      return crypto.generateKeyPairSync('rsa', { modulusLength: 4096 }).privateKey.export({ type: 'pkcs8', format: 'pem' }).toString()
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

async function tls(e) {
  const annotations = { 'neuraltrust.ai/tls-sans': sansHash(e.sans) }
  const complete = (d) => d['tls.crt'] && d['tls.key'] && (e.selfSigned || d['ca.crt'])
  const live = await get('secrets', e.secret)
  if (live && complete(decode(live))) {
    console.log(e.secret + ': present, kept')
    return
  }
  for (const [name] of e.adopt || []) {
    const d = decode(await source(name))
    if (complete(d)) {
      if (!d['ca.crt']) d['ca.crt'] = d['tls.crt']
      await write(e.secret, live, { 'tls.crt': d['tls.crt'], 'tls.key': d['tls.key'], 'ca.crt': d['ca.crt'] }, 'kubernetes.io/tls', annotations)
      console.log(e.secret + ': adopted from ' + name)
      return
    }
  }
  await write(e.secret, live, issue(e), 'kubernetes.io/tls', annotations)
  console.log(e.secret + ': issued for ' + e.sans.join(', '))
}

async function main() {
  const specs = []
  const pins = {}
  for (const c of COMPONENTS) {
    const cm = await get('configmaps', 'neuraltrust-generator-spec-' + c)
    if (!cm) continue
    for (const e of JSON.parse(cm.data['spec.json'])) specs.push(e)
    Object.assign(pins, decode(await get('secrets', 'neuraltrust-generator-pins-' + c)))
  }

  const live = await get('secrets', TARGET)
  const current = decode(live)
  const next = Object.assign({}, current)
  const late = ['alias', 'derived']
  const scalars = specs.filter((e) => e.type !== 'tls')
  const ordered = scalars.filter((e) => !late.includes(e.type)).concat(scalars.filter((e) => late.includes(e.type)))
  for (const e of ordered) {
    const k = e.key
    if (e.type === 'alias' || e.type === 'derived') {
      const src = next[e.source]
      if (src) next[k] = e.type === 'alias' ? src : e.format.replace('%s', src)
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
      let predates = false
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
  if (!live && Object.keys(next).length) {
    await write(TARGET, null, next, 'Opaque')
    console.log(TARGET + ': created with ' + Object.keys(next).length + ' keys')
  } else if (Object.keys(changed).length) {
    await write(TARGET, live, changed, 'Opaque')
    console.log(TARGET + ': updated ' + Object.keys(changed).sort().join(', '))
  } else {
    console.log(TARGET + ': nothing to do, ' + Object.keys(current).length + ' keys already present')
  }

  for (const e of specs.filter((s) => s.type === 'tls')) await tls(e)
}

main().catch((err) => {
  console.error(String(err))
  process.exit(1)
})
{{- end }}
