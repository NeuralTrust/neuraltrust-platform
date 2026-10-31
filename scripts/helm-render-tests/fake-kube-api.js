// Stands in for the service-account files and the Kubernetes API that the
// secrets generator's program uses, so render tests can run the rendered script.
//
//   FAKE_STATE        JSON file: {configmaps: {name: obj}, secrets: {name: obj}};
//                     rewritten on exit, with `log` listing every write in order
//   FAKE_DENY_TAKEOVER  any value: refuse metadata patches with 403, as a Role
//                     without patch, or an admission policy, would
//
// Load with `node --require <this file> <script>`.
const fs = require('node:fs')
const state = JSON.parse(fs.readFileSync(process.env.FAKE_STATE, 'utf8'))
state.log = state.log || []
const realRead = fs.readFileSync
fs.readFileSync = (p, ...rest) => {
  if (String(p).startsWith('/var/run/secrets/kubernetes.io/serviceaccount/')) return String(p).endsWith('namespace') ? 'ns' : 'token'
  return realRead(p, ...rest)
}
const reply = (status, body) => ({ ok: status < 300, status, json: async () => body, text: async () => JSON.stringify(body || {}) })

// RFC 7386: a null removes the key.
function merge(into, patch) {
  for (const [k, v] of Object.entries(patch || {})) {
    if (v === null) delete into[k]
    else if (typeof v === 'object' && !Array.isArray(v)) merge((into[k] = into[k] || {}), v)
    else into[k] = v
  }
  return into
}

global.fetch = async (url, opts = {}) => {
  const [, kind, name] = new URL(url).pathname.match(/\/namespaces\/ns\/(\w+)(?:\/(.+))?$/)
  const coll = (state[kind] = state[kind] || {})
  const method = opts.method || 'GET'
  if (method === 'GET') return coll[name] ? reply(200, coll[name]) : reply(404)
  if (method === 'DELETE') {
    state.log.push('delete ' + kind + '/' + name)
    delete coll[name]
    return reply(200, {})
  }
  const body = JSON.parse(opts.body)
  if (method === 'POST') {
    state.log.push('create ' + kind + '/' + body.metadata.name)
    coll[body.metadata.name] = body
    return reply(201, body)
  }
  const live = coll[name]
  if (!live) return reply(404)
  if (body.metadata && process.env.FAKE_DENY_TAKEOVER) return reply(403, { message: 'forbidden' })
  state.log.push('patch ' + kind + '/' + name + ' ' + Object.keys(body).sort().join(','))
  merge(live, body)
  return reply(200, live)
}
process.on('exit', () => fs.writeFileSync(process.env.FAKE_STATE, JSON.stringify(state)))
