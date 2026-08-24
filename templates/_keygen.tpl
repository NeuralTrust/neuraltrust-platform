{{- /*
Pre-install hook that mints an RSA key pair in-cluster and writes it into a
hook-owned Secret. Shared by the MCP OAuth signing key and the AgentGateway
Admin API machine credentials, which differ only in which Secret they write and
whether the public half is kept.

Why a hook Job at all: both consumers load the private key as PKCS#8, and Helm
cannot produce one — `genPrivateKey "rsa"` is PKCS#1, `"ecdsa"` is SEC1, and
`"ed25519"` is PKCS#8 but the wrong algorithm. Nothing in Sprig derives a public
key from a private one either, which the m2m pair needs. Without a stable key
every replica signs with its own ephemeral one, so tokens fail verification
across replicas.

Why no new image: some installs mirror their own registry or run under a
vulnerability allowlist, so a dedicated tool image is a real cost. This reuses
the exact app image the chart already deploys — Node generates PKCS#8 natively
and reaches the API server with the projected service-account token. Both
consumers are external-only, so that image is always present.

Why its own Secret rather than `platform-secrets`: pre-install hooks run before
Helm creates any manifest, so a Job that pre-created the chart-owned Secret would
collide with Helm's ownership metadata on install. Hook-owned also means
`helm uninstall` leaves it in place and a reinstall keeps the same key.

Callers gate on their own generate helper, so this template renders
unconditionally. Parameters:

  ctx           root context
  component     app.kubernetes.io/component, and the suffix of every object name
  secretName    hook-owned Secret the key material is written into
  subject       how the hook logs refer to the material, e.g. "signing key"
  nameEnv       env var carrying secretName to the script
  privateEnv    env var carrying privateField to the script
  privateField  Secret field the PKCS#8 private key is written to
  publicEnv     env var carrying publicField; omit for a private key alone
  publicField   Secret field the public key is written to; omit likewise

The public half is written base64 of base64: the consumer reads a single-line
base64-encoded PEM, and Secret data is base64 on top of that. The private half
is stored as the raw PEM, which is what its consumer expects.
*/ -}}
{{- define "neuraltrust-platform.keygenHook" -}}
{{- $ctx := .ctx }}
{{- $component := .component }}
{{- $secretName := .secretName }}
{{- $publicEnv := .publicEnv | default "" }}
{{- $publicField := .publicField | default "" }}
{{- $saName := printf "%s-%s" (include "neuraltrust-platform.name" $ctx) $component }}
{{- $cpApp := default dict (index $ctx.Values "control-plane-app") }}
{{- $cp := default dict $cpApp.controlPlane }}
{{- $appImage := default dict (default dict (default dict $cp.components).app).image }}
{{- $repo := $appImage.repository | default "europe-west1-docker.pkg.dev/neuraltrust-app-prod/nt-docker/app" }}
{{- $appTag := $appImage.tag | default "v1.147.3" }}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ $saName }}
  namespace: {{ $ctx.Release.Namespace }}
  annotations:
    helm.sh/hook: pre-install,pre-upgrade
    helm.sh/hook-weight: "-5"
    helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
  labels:
    app.kubernetes.io/name: {{ include "neuraltrust-platform.name" $ctx }}
    app.kubernetes.io/instance: {{ $ctx.Release.Name }}
    app.kubernetes.io/managed-by: {{ $ctx.Release.Service }}
    app.kubernetes.io/component: {{ $component }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: {{ $saName }}
  namespace: {{ $ctx.Release.Namespace }}
  annotations:
    helm.sh/hook: pre-install,pre-upgrade
    helm.sh/hook-weight: "-5"
    helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
  labels:
    app.kubernetes.io/name: {{ include "neuraltrust-platform.name" $ctx }}
    app.kubernetes.io/instance: {{ $ctx.Release.Name }}
    app.kubernetes.io/managed-by: {{ $ctx.Release.Service }}
    app.kubernetes.io/component: {{ $component }}
rules:
  {{- /* Reads and writes exactly one Secret, by name. */}}
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: [{{ $secretName | quote }}]
    verbs: ["get", "patch"]
  {{- /* RBAC cannot scope `create` by name — the object does not exist yet — so
         this one verb is namespace-wide. It is the minimum that lets a fresh
         install bootstrap its own key; the Job only ever creates the Secret named
         above, and both the Role and the Job are deleted once the hook
         succeeds. */}}
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: {{ $saName }}
  namespace: {{ $ctx.Release.Namespace }}
  annotations:
    helm.sh/hook: pre-install,pre-upgrade
    helm.sh/hook-weight: "-5"
    helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
  labels:
    app.kubernetes.io/name: {{ include "neuraltrust-platform.name" $ctx }}
    app.kubernetes.io/instance: {{ $ctx.Release.Name }}
    app.kubernetes.io/managed-by: {{ $ctx.Release.Service }}
    app.kubernetes.io/component: {{ $component }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: {{ $saName }}
subjects:
  - kind: ServiceAccount
    name: {{ $saName }}
    namespace: {{ $ctx.Release.Namespace }}
---
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ $saName }}
  namespace: {{ $ctx.Release.Namespace }}
  annotations:
    helm.sh/hook: pre-install,pre-upgrade
    helm.sh/hook-weight: "0"
    helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
  labels:
    app.kubernetes.io/name: {{ include "neuraltrust-platform.name" $ctx }}
    app.kubernetes.io/instance: {{ $ctx.Release.Name }}
    app.kubernetes.io/managed-by: {{ $ctx.Release.Service }}
    app.kubernetes.io/component: {{ $component }}
spec:
  backoffLimit: 3
  template:
    metadata:
      labels:
        app.kubernetes.io/name: {{ include "neuraltrust-platform.name" $ctx }}
        app.kubernetes.io/instance: {{ $ctx.Release.Name }}
        app.kubernetes.io/component: {{ $component }}
    spec:
      restartPolicy: Never
      serviceAccountName: {{ $saName }}
      {{- include "neuraltrust-platform.controlPlane.imagePullSecrets" (dict "root" $cpApp "global" ($ctx.Values.global | default dict)) | nindent 6 }}
      securityContext:
        runAsNonRoot: true
        runAsUser: 1001
        runAsGroup: 1001
      containers:
        - name: generate
          image: {{ include "neuraltrust-platform.image" (dict "repository" $repo "tag" $appTag "global" $ctx.Values.global) | quote }}
          imagePullPolicy: {{ $appImage.pullPolicy | default "IfNotPresent" }}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          env:
            - name: {{ .nameEnv }}
              value: {{ $secretName | quote }}
            - name: {{ .privateEnv }}
              value: {{ .privateField | quote }}
            {{- if $publicEnv }}
            - name: {{ $publicEnv }}
              value: {{ $publicField | quote }}
            {{- end }}
            - name: KEY_SUBJECT
              value: {{ .subject | quote }}
            {{- /* Node's TLS trusts the API server through the projected CA. */}}
            - name: NODE_EXTRA_CA_CERTS
              value: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
          resources:
            requests:
              cpu: 10m
              memory: 64Mi
            limits:
              memory: 128Mi
          command:
            - node
            - -e
            - |
              const crypto = require('node:crypto')
              const fs = require('node:fs')
              const sa = '/var/run/secrets/kubernetes.io/serviceaccount'
              const ns = fs.readFileSync(sa + '/namespace', 'utf8').trim()
              const token = fs.readFileSync(sa + '/token', 'utf8').trim()
              const name = process.env[{{ .nameEnv | quote }}]
              const privField = process.env[{{ .privateEnv | quote }}]
              // Empty for consumers that only need the private half.
              const pubField = {{ if $publicEnv }}process.env[{{ $publicEnv | quote }}]{{ else }}''{{ end }}
              const subject = process.env.KEY_SUBJECT
              // Dial the API server by its in-cluster DNS name rather than
              // KUBERNETES_SERVICE_HOST. On IPv6 single-stack clusters that variable
              // holds a bare IPv6 literal, which is not a parsable URL host without
              // brackets, and even bracketed it fails TLS verification because the
              // compressed form is string-compared against the expanded IP SAN.
              // kubernetes.default.svc is address-family agnostic and is in the
              // default SAN set on every distribution this chart targets — if this
              // hook fails TLS on a bespoke cluster, check the apiserver certificate
              // carries it. This does mean the hook needs cluster DNS, which the rest
              // of the platform needs anyway.
              const port = process.env.KUBERNETES_SERVICE_PORT || '443'
              const base = 'https://kubernetes.default.svc:' + port
              const collection = base + '/api/v1/namespaces/' + ns + '/secrets'
              const auth = { Authorization: 'Bearer ' + token }
              const json = Object.assign({ 'Content-Type': 'application/json' }, auth)
              const merge = Object.assign({ 'Content-Type': 'application/merge-patch+json' }, auth)

              // Reports the key's algorithm and size without revealing it, so the log
              // is evidence the consumer will be able to load it.
              function describe(encoded) {
                const key = crypto.createPrivateKey(Buffer.from(encoded, 'base64').toString())
                return key.asymmetricKeyType + ' ' + key.asymmetricKeyDetails.modulusLength + '-bit'
              }

              function publicFrom(encoded) {
                const key = crypto.createPrivateKey(Buffer.from(encoded, 'base64').toString())
                const pem = crypto.createPublicKey(key).export({ type: 'spki', format: 'pem' }).toString()
                return Buffer.from(Buffer.from(pem).toString('base64')).toString('base64')
              }

              function payload() {
                const pair = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 })
                const pem = pair.privateKey.export({ type: 'pkcs8', format: 'pem' }).toString()
                const pubPem = pair.publicKey.export({ type: 'spki', format: 'pem' }).toString()
                const data = {}
                data[privField] = Buffer.from(pem).toString('base64')
                if (pubField) {
                  data[pubField] = Buffer.from(Buffer.from(pubPem).toString('base64')).toString('base64')
                }
                return data
              }

              async function patch(data, message) {
                const res = await fetch(collection + '/' + name, {
                  method: 'PATCH',
                  headers: merge,
                  body: JSON.stringify({ data: data }),
                })
                if (!res.ok) {
                  throw new Error('patch failed: ' + res.status + ' ' + (await res.text()))
                }
                console.log(message)
              }

              async function main() {
                const found = await fetch(collection + '/' + name, { headers: auth })
                if (found.status === 200) {
                  const body = await found.json()
                  // Never replace an existing private key: it signs live tokens.
                  const existing = (body.data && body.data[privField]) || ''
                  if (existing) {
                    let shape = 'unparseable, the consumer will not be able to load it'
                    try {
                      shape = describe(existing)
                    } catch (err) {
                      console.error('warning: existing ' + subject + ' does not parse: ' + String(err))
                    }
                    if (!pubField || (body.data && body.data[pubField])) {
                      console.log(subject + ' already present (' + shape + '), leaving it untouched')
                      return
                    }
                    // The private half survived an interrupted run; derive the public
                    // half rather than mint a pair the consumer no longer matches.
                    const half = {}
                    half[pubField] = publicFrom(existing)
                    await patch(half, 'backfilled the public half next to the existing private key (' + shape + ')')
                    return
                  }
                } else if (found.status !== 404) {
                  throw new Error('read failed: ' + found.status + ' ' + (await found.text()))
                }

                const data = payload()
                // Fail here rather than let the consumer discover it at request time.
                const shape = describe(data[privField])

                if (found.status === 404) {
                  const meta = { name: name, namespace: ns }
                  const created = await fetch(collection, {
                    method: 'POST',
                    headers: json,
                    body: JSON.stringify({ apiVersion: 'v1', kind: 'Secret', type: 'Opaque', metadata: meta, data: data }),
                  })
                  // Another replica of this hook won the race; its key is as good.
                  if (created.status === 409) {
                    console.log('another run created it first, leaving it untouched')
                    return
                  }
                  if (!created.ok) {
                    throw new Error('create failed: ' + created.status + ' ' + (await created.text()))
                  }
                  console.log('generated an RSA PKCS#8 ' + subject + ' (' + shape + ')')
                  return
                }

                await patch(data, 'added an RSA PKCS#8 ' + subject + ' to the existing Secret (' + shape + ')')
              }

              main().catch((err) => {
                console.error(String(err))
                process.exit(1)
              })
{{- end }}
