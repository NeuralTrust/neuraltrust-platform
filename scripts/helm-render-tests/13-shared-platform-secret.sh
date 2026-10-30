#!/usr/bin/env bash
# Render scenarios 12, 12a, 12f, 12g, 12h, 12i, 12j, 12k, 12m, 12b, 12c, 12d. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

# ---------------------------------------------------------------------------
# Shared platform Secret (`platform-secrets`)
#
# The chart used to duplicate cross-service credentials by hand, and two
# independent resolveSecret calls cannot agree on a freshly generated value
# (lookup is empty during install). So the invariant under test is that every
# migrated key has exactly ONE source: no workload may still read a migrated
# key from its legacy per-service Secret, and every platform-secrets reference
# must resolve to a key the Secret actually carries.
# ---------------------------------------------------------------------------
assert_shared_secret_wiring() {
  local file="$1" label="$2"
  if ! ruby -ryaml -rbase64 -e '
    docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
    # logical key => [legacy Secret name, legacy key]
    reg = {
      "SERVER_SECRET_KEY" => ["agentgateway-secrets", "SERVER_SECRET_KEY"],
      "ADMIN_JWT_SECRET" => ["trustguard-secrets", "ADMIN_JWT_SECRET"],
      "TRUSTGUARD_TOKEN_SIGNING_SECRET" => ["trustguard-secrets", "TRUSTGUARD_TOKEN_SIGNING_SECRET"],
      "REDIS_EVENTS_SECRET" => ["trustguard-secrets", "REDIS_EVENTS_SECRET"],
      "AUTH_JWT_HS256_SECRET" => ["datacore-secrets", "AUTH_JWT_HS256_SECRET"],
      "AUTH_JWT_SECRET" => ["alertengine-secrets", "AUTH_JWT_SECRET"],
      "APP_ENCRYPTION_KEY" => ["alertengine-secrets", "APP_ENCRYPTION_KEY"],
      "JWT_SECRET" => ["firewall-secrets", "JWT_SECRET"],
      "DATA_PLANE_JWT_SECRET" => ["data-plane-jwt-secret", "DATA_PLANE_JWT_SECRET"],
      "CONTROL_PLANE_JWT_SECRET" => ["control-plane-secrets", "CONTROL_PLANE_JWT_SECRET"],
      "AUTH_SECRET" => ["control-plane-secrets", "AUTH_SECRET"],
      "AGENTGATEWAY_M2M_PRIVATE_KEY" => ["control-plane-secrets", "AGENTGATEWAY_M2M_PRIVATE_KEY"],
    }
    shared = docs.find { |d| d["kind"] == "Secret" && d.dig("metadata", "name") == "platform-secrets" }
    abort "platform-secrets not rendered" if shared.nil?
    data = shared["data"] || {}
    errors = []
    refs = 0
    docs.each do |d|
      next unless %w[Deployment StatefulSet DaemonSet].include?(d["kind"])
      name = d.dig("metadata", "name")
      pod = d.dig("spec", "template", "spec") || {}
      ((pod["containers"] || []) + (pod["initContainers"] || [])).each do |c|
        seen = Hash.new(0)
        (c["env"] || []).each do |e|
          seen[e["name"]] += 1
          skr = e.dig("valueFrom", "secretKeyRef")
          next if skr.nil?
          if skr["name"] == "platform-secrets"
            refs += 1
            # An optional ref to an absent key is how an unconfigured
            # integration is expressed, so only required refs must resolve.
            unless data.key?(skr["key"]) || skr["optional"]
              errors << "#{name}/#{c["name"]} #{e["name"]} -> platform-secrets/#{skr["key"]} which is absent"
            end
          else
            reg.each do |logical, (ln, lk)|
              if skr["name"] == ln && skr["key"] == lk
                errors << "#{name}/#{c["name"]} #{e["name"]} still reads migrated #{logical} from #{ln}"
              end
            end
          end
        end
        seen.each { |k, v| errors << "#{name}/#{c["name"]} duplicate env #{k} (x#{v})" if v > 1 }
      end
    end
    # Documented invariants that must survive a fresh install, where each key
    # would otherwise be generated independently.
    # An alias is only present when the install shape needs it, so compare the
    # pair only when both were emitted.
    [["ENROLMENT_INTROSPECTION_TOKEN", "DATACORE_SERVICE_TOKEN"]].each do |a, b|
      next unless data.key?(a) && data.key?(b)
      errors << "#{a} != #{b}" if data[a] != data[b]
    end
    errors << "no workload references platform-secrets" if refs.zero?
    unless errors.empty?
      warn errors.join("\n  ")
      abort
    end
  ' "$file"; then
    red "FAIL: $label"
    exit 1
  fi
  green "ok  - $label"
}

# Key presence inside the platform-secrets document specifically. A plain grep
# also matches the legacy Secrets, which keep dual-emitting migrated keys for
# one release, so it cannot tell the two sources apart.
blue "==> Scenario 12: shared platform Secret"
out12ext="$TMP/scenario-shared-secret-external.yaml"
render_default "$out12ext" --set global.deploymentMode=external
assert_contains "$out12ext" '^  name: platform-secrets$' \
  "external: platform-secrets renders"
assert_shared_secret_wiring "$out12ext" \
  "external: every migrated key has a single source in platform-secrets"

out12hyb="$TMP/scenario-shared-secret-hybrid.yaml"
render_default "$out12hyb" --set global.deploymentMode=hybrid
assert_contains "$out12hyb" '^  name: platform-secrets$' \
  "hybrid: platform-secrets renders"
assert_shared_secret_wiring "$out12hyb" \
  "hybrid: every migrated key has a single source in platform-secrets"

# control-plane-app used to reach into seven Secrets to build its env.
# A hybrid install must not carry credentials only the hosted control plane
# reads. Keys already present in a live Secret are preserved by a `lookup` that
# render tests cannot exercise, so only the gating is asserted here.
# AUTH_JWT_SECRET / APP_ENCRYPTION_KEY follow the alertengine shape:
# present in external with alertengine.enabled (default), absent in hybrid.
blue "==> Scenario 12a: keys are gated to the install shape"
assert_platform_keys "$out12hyb" absent \
  "hybrid: platform-secrets omits control-plane-only key" \
  CONTROL_PLANE_JWT_SECRET AUTH_SECRET \
  AUTH_JWT_HS256_SECRET AUTH_JWT_SECRET APP_ENCRYPTION_KEY
assert_platform_keys "$out12ext" present \
  "external: platform-secrets carries" \
  CONTROL_PLANE_JWT_SECRET AUTH_SECRET \
  AUTH_JWT_HS256_SECRET AUTH_JWT_SECRET APP_ENCRYPTION_KEY

# AlertEngine off ⇒ its credentials must not be minted.
out12aeoff="$TMP/scenario-shared-secret-alertengine-off.yaml"
render_default "$out12aeoff" --set global.deploymentMode=external --set alertengine.enabled=false
assert_platform_keys "$out12aeoff" absent \
  "alertengine disabled: platform-secrets omits" \
  AUTH_JWT_SECRET APP_ENCRYPTION_KEY

# A retired code path must not mint credentials nobody reads, in either mode.
assert_platform_keys "$out12ext" absent \
  "external: platform-secrets omits unused" \
  TRUSTGATE_JWT_SECRET
assert_platform_keys "$out12hyb" absent \
  "hybrid: platform-secrets omits unused" \
  TRUSTGATE_JWT_SECRET

# No service reads MODEL_SCANNER_SECRET, and the app reads AUTH_SECRET before
# NEXTAUTH_SECRET, so neither is stored or wired any more, even when pinned.
out12ms="$TMP/scenario-shared-secret-unread-keys.yaml"
render_default "$out12ms" --set global.deploymentMode=external \
  --set global.platformSecret.values.MODEL_SCANNER_SECRET=ms-pinned
for key in MODEL_SCANNER_SECRET NEXTAUTH_SECRET; do
  assert_platform_key "$out12ms" absent "$key" \
    "external: platform-secrets does not store the unread ${key}"
done
assert_not_contains "$out12ms" 'MODEL_SCANNER_SECRET|NEXTAUTH_SECRET' \
  "external: no Secret or workload carries MODEL_SCANNER_SECRET or NEXTAUTH_SECRET"
# Disabling a product drops the credentials only that product reads.
out12tgoff="$TMP/scenario-shared-secret-trustguard-off.yaml"
render_default "$out12tgoff" --set global.deploymentMode=hybrid --set global.products.trustguard=false
assert_platform_keys "$out12tgoff" absent \
  "hybrid without TrustGuard: platform-secrets omits" \
  ADMIN_JWT_SECRET TRUSTGUARD_TOKEN_SIGNING_SECRET REDIS_EVENTS_SECRET JWT_SECRET
assert_platform_key "$out12tgoff" present SERVER_SECRET_KEY \
  "hybrid without TrustGuard: TrustGate credentials still present"
# Gating a product off must not leave a consumer pointing at a key nobody emits.
assert_shared_secret_wiring "$out12tgoff" \
  "hybrid without TrustGuard: every migrated key has a single source in platform-secrets"

# autoGenerateSecrets=false means the chart mints nothing. Consumers must fall
# back to the legacy Secrets rather than reference a Secret that is never created.
out12nogen="$TMP/scenario-shared-secret-nogen.yaml"
render_default "$out12nogen" --set global.deploymentMode=external --set global.autoGenerateSecrets=false
assert_not_contains "$out12nogen" '^  name: platform-secrets$' \
  "autoGenerateSecrets=false: shared Secret not rendered"
assert_not_contains "$out12nogen" 'name: "platform-secrets"' \
  "autoGenerateSecrets=false: no workload references the shared Secret"
assert_contains "$out12nogen" 'name: "control-plane-secrets"' \
  "autoGenerateSecrets=false: refs fall back to the legacy Secret"

# An operator override through extraEnv must win without producing a duplicate
# env name, which would break the strategic merge patch on the next upgrade.
out12dup="$TMP/scenario-shared-secret-extraenv-override.yaml"
render_default "$out12dup" --set global.deploymentMode=external \
  --set 'trustguard.dataPlane.extraEnv[0].name=ADMIN_JWT_SECRET' \
  --set 'trustguard.dataPlane.extraEnv[0].value=operator-wins' \
  --set 'agentgateway.controlPlane.extraEnv[0].name=SERVER_SECRET_KEY' \
  --set 'agentgateway.controlPlane.extraEnv[0].value=operator-wins'
assert_shared_secret_wiring "$out12dup" \
  "extraEnv override: no duplicate env names and every ref still resolves"
assert_contains "$out12dup" 'value: operator-wins' \
  "extraEnv override: the operator value reaches the container"

# Watchdog usage export authenticates against both APIs, so it must read the
# same signing keys they verify with — including in hybrid, where the shared
# Secret would not otherwise carry the control-plane key.
out12wd="$TMP/scenario-shared-secret-watchdog.yaml"
render_default "$out12wd" --set watchdog.enabled=true --set watchdog.usageExport.enabled=true
assert_shared_secret_wiring "$out12wd" \
  "hybrid + watchdog usage export: every ref resolves to an emitted key"
for key in CONTROL_PLANE_JWT_SECRET DATA_PLANE_JWT_SECRET; do
  assert_platform_key "$out12wd" present "${key}" \
    "hybrid + watchdog usage export: platform-secrets carries ${key}"
done
out12wdoff="$TMP/scenario-shared-secret-watchdog-override.yaml"
render_default "$out12wdoff" --set watchdog.enabled=true --set watchdog.usageExport.enabled=true \
  --set watchdog.usageExport.jwtSecret.existingSecret=my-watchdog-secret
assert_contains "$out12wdoff" 'name: my-watchdog-secret' \
  "watchdog: an operator-supplied Secret still overrides the shared one"

# An alias key exists because two names must hold one value. Pinning the alias
# instead of its target cannot be honoured, so it must fail loudly rather than
# be silently overwritten by the mirror.
assert_render_fails_with "must equal ENROLMENT_INTROSPECTION_TOKEN" \
  "pinning an alias key is rejected with a pointer to its target" \
  --set global.deploymentMode=saas \
  --set global.platformSecret.values.DATACORE_SERVICE_TOKEN=pinned-alias

# A credential path that accepts either a string or a {secretName, secretKey}
# map must not reach b64enc as a map, which would abort the whole render.
out12map="$TMP/scenario-shared-secret-map-value.yaml"
render_default "$out12map" --set global.deploymentMode=external \
  --set-json 'global.platformSecret.values.MCP_OAUTH_SIGNING_KEY={"secretName":"ms","secretKey":"k"}'
assert_platform_key "$out12map" absent MCP_OAUTH_SIGNING_KEY \
  "a map-shaped credential is ignored rather than aborting the render"

# AUTH_SECRET_KEY encrypts SSO client secrets and SMTP credentials at rest. The
# app has a committed default, so an install already running on that default has
# ciphertext bound to it: generating a new key on upgrade would make those rows
# undecryptable. Fresh install gets one, upgrade does not.
blue "==> Scenario 12f: AUTH_SECRET_KEY is generated on install only"
assert_platform_key "$out12ext" present AUTH_SECRET_KEY \
  "external install: platform-secrets carries AUTH_SECRET_KEY"
out12askup="$TMP/scenario-shared-secret-authsecretkey-upgrade.yaml"
render_default "$out12askup" --set global.deploymentMode=external --is-upgrade
assert_platform_key "$out12askup" absent AUTH_SECRET_KEY \
  "external upgrade: AUTH_SECRET_KEY is not generated, so nothing already encrypted breaks"
out12askpin="$TMP/scenario-shared-secret-authsecretkey-pinned.yaml"
render_default "$out12askpin" --set global.deploymentMode=external --is-upgrade \
  --set global.platformSecret.values.AUTH_SECRET_KEY=operator-adopted
assert_platform_key "$out12askpin" present AUTH_SECRET_KEY \
  "external upgrade: an operator can still adopt AUTH_SECRET_KEY deliberately"
# It signs nothing — AUTH_SECRET does. Sharing one value would be key reuse.
ruby -ryaml -e '
  docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
  d = docs.find { |x| x["kind"] == "Secret" && x.dig("metadata", "name") == "platform-secrets" }
  data = d["data"] || {}
  abort "AUTH_SECRET or AUTH_SECRET_KEY missing" unless data["AUTH_SECRET"] && data["AUTH_SECRET_KEY"]
  abort "AUTH_SECRET_KEY reuses the session signing key" if data["AUTH_SECRET"] == data["AUTH_SECRET_KEY"]
' "$out12ext" || { red "FAIL: AUTH_SECRET_KEY must not equal AUTH_SECRET"; exit 1; }
green "ok  - external: AUTH_SECRET_KEY is a distinct key from AUTH_SECRET"

# MCP OAuth is on by default in external. A signing key is always available because
# the chart generates one through a pre-install hook when nothing else provides it —
# Helm's own templating cannot, since it emits PKCS#1 while the app parses PKCS#8,
# and without a stable key each replica signs with its own ephemeral one. The gate
# stays three-state: unset means auto, true means required, false means never.
blue "==> Scenario 12g: MCP OAuth follows the signing key, not intent alone"
# The signing key is opaque to the chart; only the app parses it, so a placeholder
# is enough to prove the gate and the wiring.
mcpkey="pem-placeholder"
# Nothing supplied: the generator covers the key, so the feature is simply on.
assert_platform_key "$out12ext" present MCP_OAUTH_CLIENT_SECRET \
  "external defaults: MCP OAuth is on with no operator action"
# The generated key lives in its own hook-owned Secret, never in platform-secrets.
assert_platform_key "$out12ext" absent MCP_OAUTH_SIGNING_KEY \
  "external defaults: the generated key stays out of platform-secrets"
assert_contains "$out12ext" 'name: "mcp-oauth-signing"' \
  "external defaults: the app reads the generated signing key"
# Default-on: external plus a key, and nobody had to set the flag.
out12mcp="$TMP/scenario-mcp-oauth-on.yaml"
render_default "$out12mcp" --set global.deploymentMode=external \
  --set global.platformSecret.values.MCP_OAUTH_SIGNING_KEY="$mcpkey"
assert_platform_key "$out12mcp" present MCP_OAUTH_CLIENT_SECRET \
  "auto with a signing key: MCP OAuth switches on without global.mcpOAuth.enabled"
assert_platform_key "$out12mcp" present MCP_OAUTH_SIGNING_KEY \
  "auto with a signing key: the operator-supplied key is emitted"
# Adopted verbatim, never regenerated: a chart-invented value would not parse.
ruby -ryaml -rbase64 -e '
  docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
  s = docs.find { |d| d["kind"] == "Secret" && d.dig("metadata", "name") == "platform-secrets" }
  abort "platform-secrets not rendered" if s.nil?
  got = Base64.decode64(s.fetch("data").fetch("MCP_OAUTH_SIGNING_KEY"))
  abort "signing key was not adopted verbatim: #{got.inspect}" unless got == ARGV.fetch(1)
' "$out12mcp" "$mcpkey" || { red "FAIL: the signing key must be adopted, not generated"; exit 1; }
green "ok  - the signing key is adopted verbatim, never generated"
# An operator key makes the generator redundant; running it anyway would leave a
# second key nobody reads.
assert_not_contains "$out12mcp" 'component: mcp-signing-key' \
  "an operator-supplied key stands the generator down"
assert_contains "$out12mcp" 'name: "platform-secrets"' \
  "an operator-supplied key is read from platform-secrets, not the generated one"
# Intent without the material is a misconfiguration, not a silent no-op: half the
# logins would fail JWKS verification across replicas. Only reachable by refusing
# the generator, since otherwise the chart always has a key.
assert_render_fails "mcpOAuth=true with no key and no generator fails loudly" \
  --set global.deploymentMode=external \
  --set global.mcpOAuth.generateSigningKey=false \
  --set global.mcpOAuth.enabled=true
# An explicit false still wins over an available key.
out12mcpoff="$TMP/scenario-mcp-oauth-forced-off.yaml"
render_default "$out12mcpoff" --set global.deploymentMode=external \
  --set global.mcpOAuth.enabled=false \
  --set global.platformSecret.values.MCP_OAUTH_SIGNING_KEY="$mcpkey"
assert_not_contains "$out12mcpoff" 'MCP_DEFAULT_IDP_|name: MCP_OAUTH_CLIENT_ID' \
  "explicit false with a key present: MCP OAuth stays off"
assert_platform_key "$out12mcpoff" absent MCP_OAUTH_CLIENT_SECRET \
  "explicit false with a key present: no client secret is generated"
assert_shared_secret_wiring "$out12mcp" \
  "mcpOAuth on: every ref still resolves to an emitted key"
# One value, two env names, and one issuer both sides resolve identically: a
# mismatch on either would surface only as a failed login at request time.
ruby -ryaml -e '
  docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
  def env_of(docs, name)
    d = docs.find { |x| x["kind"] == "Deployment" && x.dig("metadata", "name") == name }
    abort "#{name} not rendered" if d.nil?
    (d.dig("spec", "template", "spec", "containers") || []).flat_map { |c| c["env"] || [] }
  end
  app = env_of(docs, "control-plane-app")
  mcp = env_of(docs, "agentgateway-mcp")
  app_ref = app.find { |e| e["name"] == "MCP_OAUTH_CLIENT_SECRET" }
  mcp_ref = mcp.find { |e| e["name"] == "MCP_DEFAULT_IDP_CLIENT_SECRET" }
  abort "client secret not wired on both sides" if app_ref.nil? || mcp_ref.nil?
  a = app_ref.dig("valueFrom", "secretKeyRef")
  b = mcp_ref.dig("valueFrom", "secretKeyRef")
  unless a && b && a["name"] == b["name"] && a["key"] == b["key"]
    abort "client secret sources differ: #{a.inspect} vs #{b.inspect}"
  end
  app_iss = app.find { |e| e["name"] == "MCP_OAUTH_ISSUER" }&.fetch("value", nil)
  mcp_iss = mcp.find { |e| e["name"] == "MCP_DEFAULT_IDP_ISSUER" }&.fetch("value", nil)
  abort "issuer missing on one side: #{app_iss.inspect} vs #{mcp_iss.inspect}" if app_iss.nil? || mcp_iss.nil?
  abort "issuers differ: #{app_iss} vs #{mcp_iss}" unless app_iss == mcp_iss
  # Only the MCP plane brokers logins; the others must not advertise an IdP.
  %w[agentgateway-admin agentgateway-proxy].each do |name|
    leaked = env_of(docs, name).map { |e| e["name"] }.grep(/^MCP_DEFAULT_IDP/)
    abort "#{name} carries #{leaked.join(", ")}" unless leaked.empty?
  end
' "$out12mcp" || { red "FAIL: MCP OAuth wiring is not consistent across services"; exit 1; }
green "ok  - mcpOAuth on: app and TrustGate share one client secret and one issuer"
# Empty allowlist means the app accepts a callback on any https origin.
assert_contains "$out12mcp" 'name: MCP_OAUTH_ALLOWED_REDIRECT_HOSTS' \
  "mcpOAuth on: the redirect-host allowlist is always set"
# With no domain there is neither a derivable issuer nor a derivable allowlist. Auto
# resolves to off, which is the point of the three-state gate; an explicit enable
# must still refuse rather than wire a login that cannot complete.
out12nodomain="$TMP/scenario-mcp-oauth-no-domain.yaml"
render_default "$out12nodomain" --set global.deploymentMode=external --set global.domain= \
  --set global.platformSecret.values.MCP_OAUTH_SIGNING_KEY="$mcpkey"
assert_not_contains "$out12nodomain" 'MCP_DEFAULT_IDP_|name: MCP_OAUTH_CLIENT_ID' \
  "no domain: auto leaves MCP OAuth off even with a signing key present"
assert_render_fails "mcpOAuth without a resolvable issuer fails loudly when required" \
  --set global.deploymentMode=external \
  --set global.platformSecret.values.MCP_OAUTH_SIGNING_KEY="$mcpkey" \
  --set global.mcpOAuth.enabled=true \
  --set global.domain=
# Hybrid deploys no control-plane app, so there is no authorization server to
# point at. Refuse rather than hand TrustGate an issuer nobody serves.
assert_render_fails "mcpOAuth is rejected in hybrid, where the app is the hosted platform" \
  --set global.deploymentMode=hybrid \
  --set global.mcpOAuth.enabled=true
assert_platform_key "$out12hyb" absent MCP_OAUTH_CLIENT_SECRET \
  "hybrid: platform-secrets omits the MCP OAuth client secret"
assert_not_contains "$out12hyb" 'MCP_DEFAULT_IDP_' \
  "hybrid: agentgateway carries no MCP default IdP env"
# Auto must not fire in hybrid just because a key happens to be present: the
# authorization server is the hosted platform, which never saw this client secret.
out12hybkey="$TMP/scenario-mcp-oauth-hybrid-key.yaml"
render_default "$out12hybkey" --set global.deploymentMode=hybrid \
  --set global.platformSecret.values.MCP_OAUTH_SIGNING_KEY="$mcpkey"
assert_not_contains "$out12hybkey" 'MCP_DEFAULT_IDP_|name: MCP_OAUTH_CLIENT_ID' \
  "hybrid with a signing key present: auto still leaves MCP OAuth off"
assert_platform_key "$out12hybkey" absent MCP_OAUTH_CLIENT_SECRET \
  "hybrid with a signing key present: no client secret is generated"

# The signing key generator exists so a fresh external install needs no operator
# step. It must reuse an image the install already pulls: some operators mirror
# their own registry or run under a vulnerability allowlist, where an extra image
# is a real cost.
blue "==> Scenario 12h: the signing key generator is self-contained"
ruby -ryaml -e '
  docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
  hook = docs.select { |d| d.dig("metadata", "labels", "app.kubernetes.io/component") == "mcp-signing-key" }
  kinds = hook.map { |d| d["kind"] }.sort
  want = %w[Job Role RoleBinding ServiceAccount]
  abort "hook bundle is #{kinds.inspect}, want #{want.inspect}" unless kinds == want
  hook.each do |d|
    ann = d.dig("metadata", "annotations") || {}
    unless ann["helm.sh/hook"] == "pre-install,pre-upgrade"
      abort "#{d["kind"]} is not a pre-install,pre-upgrade hook: #{ann["helm.sh/hook"].inspect}"
    end
  end
  # RBAC must exist before the Job that uses it.
  weight = ->(k) { hook.find { |d| d["kind"] == k }.dig("metadata", "annotations", "helm.sh/hook-weight").to_i }
  abort "the Job is not ordered after its RBAC" unless weight.call("Role") < weight.call("Job")

  job = hook.find { |d| d["kind"] == "Job" }
  app = docs.find { |d| d["kind"] == "Deployment" && d.dig("metadata", "name") == "control-plane-app" }
  app_image = app.dig("spec", "template", "spec", "containers").find { |c| c["name"] == "app" }.fetch("image")
  job_image = job.dig("spec", "template", "spec", "containers", 0).fetch("image")
  abort "the Job pulls #{job_image}, not the app image #{app_image}" unless job_image == app_image

  # A generator that rewrote an existing key would invalidate live access tokens.
  script = job.dig("spec", "template", "spec", "containers", 0, "command").last
  abort "the generator does not check for an existing key" unless script.include?("already present")
  abort "the generator does not produce PKCS#8" unless script.include?("pkcs8")
  # On IPv6 single-stack, KUBERNETES_SERVICE_HOST is a bare literal: unparsable
  # as a URL host, and unmatchable against the certificate SAN even bracketed.
  # The Job then exhausts its backoffLimit and fails the release.
  abort "the generator dials the apiserver by IP instead of DNS" \
    if script.include?("process.env.KUBERNETES_SERVICE_HOST")
  abort "the generator does not dial kubernetes.default.svc" \
    unless script.include?("https://kubernetes.default.svc:")

  role = hook.find { |d| d["kind"] == "Role" }
  named = role["rules"].select { |r| r["resourceNames"] }
  abort "no rule is scoped to a single Secret" if named.empty?
  named.each do |r|
    abort "a name-scoped rule reaches beyond the generated Secret: #{r["resourceNames"].inspect}" \
      unless r["resourceNames"] == ["mcp-oauth-signing"]
  end
  # `create` cannot be name-scoped in RBAC, but nothing else may be unscoped.
  role["rules"].reject { |r| r["resourceNames"] }.each do |r|
    abort "an unscoped rule grants #{r["verbs"].inspect}, only create is acceptable" unless r["verbs"] == ["create"]
  end
  abort "the Role reaches outside the core API group" unless role["rules"].all? { |r| r["apiGroups"] == [""] }
  abort "the Role touches something other than secrets" unless role["rules"].all? { |r| r["resources"] == ["secrets"] }
' "$out12ext" || { red "FAIL: the signing key generator is not correctly scoped"; exit 1; }
green "ok  - the generator reuses the app image and can write only its own Secret"

# `enabled` is read by this helper family and by validate-values. A raw bool test
# and Go truthiness disagree for a string, and a Flux HelmRelease sourcing values
# from a ConfigMap makes every value a string — so a string-typed flag must mean the
# same thing everywhere, or disabling the feature turns it on.
blue "==> Scenario 12i: the gate reads the same way however enabled is typed"
out12strfalse="$TMP/scenario-mcp-oauth-string-false.yaml"
render_default "$out12strfalse" --set global.deploymentMode=external \
  --set-string global.mcpOAuth.enabled=false
assert_not_contains "$out12strfalse" 'MCP_DEFAULT_IDP_|name: MCP_OAUTH_CLIENT_ID' \
  'enabled="false" as a string disables the feature, as a bool would'
assert_not_contains "$out12strfalse" 'component: mcp-signing-key' \
  'enabled="false" as a string also stands the generator down'
# The same string in hybrid must not be read as intent to enable, which would
# reject the install for turning the feature off.
out12strhyb="$TMP/scenario-mcp-oauth-string-false-hybrid.yaml"
render_default "$out12strhyb" --set global.deploymentMode=hybrid \
  --set-string global.mcpOAuth.enabled=false
assert_contains "$out12strhyb" '^  name: platform-secrets$' \
  'hybrid with enabled="false" as a string still renders'
# An explicit string true must be honoured as intent, so it still fails loudly.
assert_render_fails 'enabled="true" as a string is honoured as required' \
  --set global.deploymentMode=external \
  --set global.mcpOAuth.generateSigningKey=false \
  --set-string global.mcpOAuth.enabled=true
# Anything else is a typo, not a third state to guess at.
assert_render_fails 'a non-boolean enabled is rejected rather than guessed at' \
  --set global.deploymentMode=external \
  --set-string global.mcpOAuth.enabled=maybe

# Both sides read one client secret from whichever Secret secretRef resolves to.
# When the shared Secret is out of play those refs land on legacy Secrets the chart
# never writes this key into, and since they are optional the env is simply absent:
# the login fails at request time with nothing pointing at the cause.
blue "==> Scenario 12j: MCP OAuth needs a Secret that actually carries the client secret"
# Two representative undeliverable shapes (opt-out vs preserve); other flags share the gate.
for flag in global.platformSecret.enabled=false global.preserveExistingSecrets=true; do
  out12nodel="$TMP/scenario-mcp-oauth-undeliverable-${flag%%=*}.yaml"
  render_default "$out12nodel" --set global.deploymentMode=external --set "$flag"
  assert_not_contains "$out12nodel" 'MCP_DEFAULT_IDP_|name: MCP_OAUTH_CLIENT_ID' \
    "${flag}: MCP OAuth stays off rather than half-wired"
  assert_not_contains "$out12nodel" 'component: mcp-signing-key' \
    "${flag}: no signing key is minted for a login that cannot complete"
  assert_render_fails "${flag}: an explicit enable is refused with guidance" \
    --set global.deploymentMode=external --set "$flag" \
    --set global.mcpOAuth.enabled=true
done

# An empty allowlist is not merely unset: the app then accepts an OAuth callback on
# ANY https origin, handing the authorization code to whoever asks. It was possible
# to reach that state with an explicit issuer and no domain.
blue "==> Scenario 12k: MCP OAuth refuses to run without a callback allowlist"
out12noallow="$TMP/scenario-mcp-oauth-no-allowlist.yaml"
render_default "$out12noallow" --set global.deploymentMode=external --set global.domain= \
  --set global.mcpOAuth.issuer=https://console.example.com/api/mcp/oauth
assert_not_contains "$out12noallow" 'MCP_DEFAULT_IDP_|name: MCP_OAUTH_CLIENT_ID' \
  "an issuer without a derivable allowlist leaves MCP OAuth off"
assert_render_fails "an explicit enable without an allowlist is refused" \
  --set global.deploymentMode=external --set global.domain= \
  --set global.mcpOAuth.issuer=https://console.example.com/api/mcp/oauth \
  --set global.mcpOAuth.enabled=true
# Supplying one explicitly is the documented way out, with no domain at all.
out12allow="$TMP/scenario-mcp-oauth-explicit-allowlist.yaml"
render_default "$out12allow" --set global.deploymentMode=external --set global.domain= \
  --set global.mcpOAuth.issuer=https://console.example.com/api/mcp/oauth \
  --set 'global.mcpOAuth.allowedRedirectHosts=https://*.mcp.example.com'
assert_contains "$out12allow" 'name: MCP_OAUTH_ALLOWED_REDIRECT_HOSTS' \
  "an explicit allowlist enables the feature without global.domain"

# The issuer is derived as app.<domain> because a subchart cannot read a sibling's
# values. An install serving the app elsewhere would advertise an issuer nobody
# serves, and default-on means the operator never opts into finding out.
assert_render_fails "a custom app host without an explicit issuer is refused" \
  --set global.deploymentMode=external \
  --set 'control-plane-app.controlPlane.components.app.host=console.acme.test'
out12host="$TMP/scenario-mcp-oauth-custom-host.yaml"
render_default "$out12host" --set global.deploymentMode=external \
  --set 'control-plane-app.controlPlane.components.app.host=console.acme.test' \
  --set global.mcpOAuth.issuer=https://console.acme.test/api/mcp/oauth \
  --set global.agentgatewayM2m.issuer=https://console.acme.test
assert_contains "$out12host" 'https://console.acme.test/api/mcp/oauth' \
  "a custom app host works once the issuer is explicit"

# The generator's premise is that it costs no new image: if the app can be pulled,
# so can the Job. That must survive a mirrored registry and operator pull secrets,
# where reaching for a different image would fail with ImagePullBackOff mid-upgrade.
out12reg="$TMP/scenario-mcp-generator-mirrored-registry.yaml"
render_default "$out12reg" --set global.deploymentMode=external \
  --set global.imageRegistry=registry.internal.example.com/nt \
  --set 'control-plane-app.imagePullSecrets=mirror-creds' \
  --set 'control-plane-app.controlPlane.components.app.image.pullPolicy=Always'
ruby -ryaml -e '
  docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
  app = docs.find { |d| d["kind"] == "Deployment" && d.dig("metadata", "name") == "control-plane-app" }
  job = docs.find { |d| d["kind"] == "Job" && d.dig("metadata", "labels", "app.kubernetes.io/component") == "mcp-signing-key" }
  abort "the generator Job is not rendered" if job.nil?
  m2m = docs.find { |d| d["kind"] == "Job" && d.dig("metadata", "labels", "app.kubernetes.io/component") == "agentgateway-m2m-keys" }
  abort "the m2m generator Job is not rendered" if m2m.nil?
  app_c = app.dig("spec", "template", "spec", "containers").find { |c| c["name"] == "app" }
  job_c = job.dig("spec", "template", "spec", "containers", 0)
  m2m_c = m2m.dig("spec", "template", "spec", "containers", 0)
  abort "the Job pulls #{job_c["image"]}, the app pulls #{app_c["image"]}" unless job_c["image"] == app_c["image"]
  abort "the m2m Job pulls #{m2m_c["image"]}, the app pulls #{app_c["image"]}" unless m2m_c["image"] == app_c["image"]
  abort "the mirrored registry was not applied: #{job_c["image"]}" unless job_c["image"].start_with?("registry.internal.example.com/nt/")
  pull = ->(d) { (d.dig("spec", "template", "spec", "imagePullSecrets") || []).map { |s| s["name"] } }
  abort "pull secrets differ: #{pull.call(job).inspect} vs #{pull.call(app).inspect}" unless pull.call(job) == pull.call(app)
  abort "m2m pull secrets differ: #{pull.call(m2m).inspect} vs #{pull.call(app).inspect}" unless pull.call(m2m) == pull.call(app)
  abort "the operator pull secret did not reach the Job: #{pull.call(job).inspect}" unless pull.call(job) == ["mirror-creds"]
  unless job_c["imagePullPolicy"] == app_c["imagePullPolicy"]
    abort "pull policies differ: #{job_c["imagePullPolicy"]} vs #{app_c["imagePullPolicy"]}"
  end
' "$out12reg" || { red "FAIL: the generator does not follow the app image into a custom registry"; exit 1; }
green "ok  - the generator follows the app image through a mirrored registry and pull secrets"

# AgentGateway Admin API machine credentials. On by default in
# external/saas: a hook Job writes a PKCS#8 private key and the matching public
# PEM so the Credentials tab works with no operator action. Hybrid has no Admin
# API and no in-cluster app, so the feature stays off.
blue "==> Scenario 12m: AgentGateway Admin API machine credentials"
assert_platform_key "$out12ext" absent AGENTGATEWAY_M2M_PRIVATE_KEY \
  "external defaults: the generated m2m private key stays out of platform-secrets"
assert_contains "$out12ext" 'name: "agentgateway-m2m-keys"' \
  "external defaults: the app and TrustGate read the generated m2m Secret"
assert_not_contains "$out12hyb" 'AGENTGATEWAY_M2M_|ADMIN_M2M_|component: agentgateway-m2m-keys' \
  "hybrid: Admin API machine credentials stay off"
assert_render_fails "agentgatewayM2m=true in hybrid fails loudly" \
  --set global.agentgatewayM2m.enabled=true
assert_render_fails "agentgatewayM2m=true with no key and no generator fails loudly" \
  --set global.deploymentMode=external \
  --set global.agentgatewayM2m.generateKeys=false \
  --set global.agentgatewayM2m.enabled=true
assert_render_fails "a private m2m key without publicKeys fails loudly" \
  --set global.deploymentMode=external \
  --set global.agentgatewayM2m.generateKeys=false \
  --set global.platformSecret.values.AGENTGATEWAY_M2M_PRIVATE_KEY=pem-placeholder
assert_render_fails "publicKeys without a private m2m key fails loudly" \
  --set global.deploymentMode=external \
  --set global.agentgatewayM2m.generateKeys=false \
  --set global.agentgatewayM2m.publicKeys=pub-placeholder
m2mkey="pem-placeholder"
m2mpub="pub-placeholder"
out12m2m="$TMP/scenario-agentgateway-m2m-on.yaml"
render_default "$out12m2m" --set global.deploymentMode=external \
  --set global.platformSecret.values.AGENTGATEWAY_M2M_PRIVATE_KEY="$m2mkey" \
  --set global.agentgatewayM2m.publicKeys="$m2mpub"
assert_platform_key "$out12m2m" present AGENTGATEWAY_M2M_PRIVATE_KEY \
  "an operator-supplied private key is emitted into platform-secrets"
assert_not_contains "$out12m2m" 'component: agentgateway-m2m-keys' \
  "an operator-supplied pair stands the m2m generator down"
ruby -ryaml -rbase64 -e '
  docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
  def env_of(docs, name)
    d = docs.find { |x| x["kind"] == "Deployment" && x.dig("metadata", "name") == name }
    abort "#{name} not rendered" if d.nil?
    (d.dig("spec", "template", "spec", "containers") || []).flat_map { |c| c["env"] || [] }
  end
  app = env_of(docs, "control-plane-app")
  admin = env_of(docs, "agentgateway-admin")
  priv = app.find { |e| e["name"] == "AGENTGATEWAY_M2M_PRIVATE_KEY" }
  abort "app is missing AGENTGATEWAY_M2M_PRIVATE_KEY" if priv.nil?
  skr = priv.dig("valueFrom", "secretKeyRef")
  abort "app private key is not from platform-secrets: #{skr.inspect}" unless skr && skr["name"] == "platform-secrets" && skr["key"] == "AGENTGATEWAY_M2M_PRIVATE_KEY"
  pub = admin.find { |e| e["name"] == "ADMIN_M2M_PUBLIC_KEYS" }
  abort "admin is missing ADMIN_M2M_PUBLIC_KEYS" if pub.nil?
  abort "admin public keys were not taken from values: #{pub.inspect}" unless pub["value"] == ARGV.fetch(1)
  app_iss = app.find { |e| e["name"] == "AGENTGATEWAY_M2M_ISSUER" }&.fetch("value", nil)
  admin_iss = admin.find { |e| e["name"] == "ADMIN_M2M_ISSUER" }&.fetch("value", nil)
  abort "issuer missing on one side: #{app_iss.inspect} vs #{admin_iss.inspect}" if app_iss.nil? || admin_iss.nil?
  abort "issuers differ: #{app_iss} vs #{admin_iss}" unless app_iss == admin_iss
  abort "issuer has a trailing slash: #{app_iss}" if app_iss.end_with?("/")
  abort "derived issuer is not the app origin: #{app_iss}" unless app_iss == "https://app.platform.example.com"
  app_aud = app.find { |e| e["name"] == "AGENTGATEWAY_M2M_AUDIENCE" }&.fetch("value", nil)
  admin_aud = admin.find { |e| e["name"] == "ADMIN_M2M_AUDIENCE" }&.fetch("value", nil)
  abort "audiences differ: #{app_aud.inspect} vs #{admin_aud.inspect}" unless app_aud == admin_aud
  %w[agentgateway-proxy agentgateway-mcp].each do |name|
    leaked = env_of(docs, name).map { |e| e["name"] }.grep(/^(ADMIN_M2M_|AGENTGATEWAY_M2M_)/)
    abort "#{name} carries #{leaked.join(", ")}" unless leaked.empty?
  end
  s = docs.find { |d| d["kind"] == "Secret" && d.dig("metadata", "name") == "platform-secrets" }
  got = Base64.decode64(s.fetch("data").fetch("AGENTGATEWAY_M2M_PRIVATE_KEY"))
  abort "private key was not adopted verbatim: #{got.inspect}" unless got == ARGV.fetch(2)
' "$out12m2m" "$m2mpub" "$m2mkey" || { red "FAIL: m2m wiring is not consistent across app and TrustGate"; exit 1; }
green "ok  - m2m on: app and TrustGate share one issuer; private key stays on the app, public keys on admin"
# Default-on: the generated Secret is what both sides read, and the Job never
# rewrites a live pair.
ruby -ryaml -e '
  docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
  hook = docs.select { |d| d.dig("metadata", "labels", "app.kubernetes.io/component") == "agentgateway-m2m-keys" }
  kinds = hook.map { |d| d["kind"] }.sort
  want = %w[Job Role RoleBinding ServiceAccount]
  abort "hook bundle is #{kinds.inspect}, want #{want.inspect}" unless kinds == want
  job = hook.find { |d| d["kind"] == "Job" }
  script = job.dig("spec", "template", "spec", "containers", 0, "command").last
  abort "the generator does not check for an existing key" unless script.include?("already present")
  abort "the generator does not produce PKCS#8" unless script.include?("pkcs8")
  abort "the generator dials the apiserver by IP instead of DNS" \
    if script.include?("process.env.KUBERNETES_SERVICE_HOST")
  abort "the generator does not dial kubernetes.default.svc" \
    unless script.include?("https://kubernetes.default.svc:")
  abort "the generator does not derive the public half from the private one" \
    unless script.include?("createPublicKey")
  jobenv = (job.dig("spec", "template", "spec", "containers", 0, "env") || [])
    .each_with_object({}) { |e, h| h[e["name"]] = e["value"] }
  abort "the private half is written as #{jobenv["M2M_PRIVATE_KEY"].inspect}" \
    unless jobenv["M2M_PRIVATE_KEY"] == "AGENTGATEWAY_M2M_PRIVATE_KEY"
  abort "the public half is written as #{jobenv["M2M_PUBLIC_KEYS"].inspect}" \
    unless jobenv["M2M_PUBLIC_KEYS"] == "ADMIN_M2M_PUBLIC_KEYS"
  role = hook.find { |d| d["kind"] == "Role" }
  named = role["rules"].select { |r| r["resourceNames"] }
  abort "no rule is scoped to a single Secret" if named.empty?
  named.each do |r|
    abort "a name-scoped rule reaches beyond the generated Secret: #{r["resourceNames"].inspect}" \
      unless r["resourceNames"] == ["agentgateway-m2m-keys"]
  end
  def env_of(docs, name)
    d = docs.find { |x| x["kind"] == "Deployment" && x.dig("metadata", "name") == name }
    abort "#{name} not rendered" if d.nil?
    (d.dig("spec", "template", "spec", "containers") || []).flat_map { |c| c["env"] || [] }
  end
  app = env_of(docs, "control-plane-app")
  admin = env_of(docs, "agentgateway-admin")
  priv = app.find { |e| e["name"] == "AGENTGATEWAY_M2M_PRIVATE_KEY" }.dig("valueFrom", "secretKeyRef")
  pub = admin.find { |e| e["name"] == "ADMIN_M2M_PUBLIC_KEYS" }.dig("valueFrom", "secretKeyRef")
  abort "generated private key ref missing" if priv.nil?
  abort "generated public keys ref missing" if pub.nil?
  abort "generated halves live in different Secrets: #{priv.inspect} vs #{pub.inspect}" unless priv["name"] == pub["name"]
  abort "generated Secret is not agentgateway-m2m-keys: #{priv["name"]}" unless priv["name"] == "agentgateway-m2m-keys"
  abort "app reads #{priv["key"].inspect}, not AGENTGATEWAY_M2M_PRIVATE_KEY" unless priv["key"] == "AGENTGATEWAY_M2M_PRIVATE_KEY"
  abort "admin reads #{pub["key"].inspect}, not ADMIN_M2M_PUBLIC_KEYS" unless pub["key"] == "ADMIN_M2M_PUBLIC_KEYS"
' "$out12ext" || { red "FAIL: the m2m generator is not self-contained"; exit 1; }
green "ok  - m2m generator writes both halves into agentgateway-m2m-keys and never rewrites a live pair"
out12m2moff="$TMP/scenario-agentgateway-m2m-forced-off.yaml"
render_default "$out12m2moff" --set global.deploymentMode=external \
  --set global.agentgatewayM2m.enabled=false
assert_not_contains "$out12m2moff" 'AGENTGATEWAY_M2M_|ADMIN_M2M_|component: agentgateway-m2m-keys' \
  "explicit false: Admin API machine credentials stay off"
out12m2miss="$TMP/scenario-agentgateway-m2m-explicit-issuer.yaml"
render_default "$out12m2miss" --set global.deploymentMode=external \
  --set global.agentgatewayM2m.issuer=https://console.example.com/
ruby -ryaml -e '
  docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
  def env_of(docs, name)
    d = docs.find { |x| x["kind"] == "Deployment" && x.dig("metadata", "name") == name }
    (d.dig("spec", "template", "spec", "containers") || []).flat_map { |c| c["env"] || [] }
  end
  app_iss = env_of(docs, "control-plane-app").find { |e| e["name"] == "AGENTGATEWAY_M2M_ISSUER" }&.fetch("value", nil)
  admin_iss = env_of(docs, "agentgateway-admin").find { |e| e["name"] == "ADMIN_M2M_ISSUER" }&.fetch("value", nil)
  abort "explicit issuer was not trimmed: #{app_iss.inspect}" unless app_iss == "https://console.example.com"
  abort "issuers differ after trim: #{app_iss} vs #{admin_iss}" unless app_iss == admin_iss
' "$out12m2miss" || { red "FAIL: explicit m2m issuer was not applied identically on both sides"; exit 1; }
green "ok  - explicit m2m issuer is trimmed and identical on app and TrustGate"

# control-plane pull-secret precedence
#   controlPlane.imagePullSecrets → subchart root → global.imagePullSecrets → gcr-secret
#   "none" (or global ["none"]) suppresses. Default path must stay gcr-secret.
blue "==> control-plane imagePullSecrets precedence"
assert_pull_secrets() {
  local file="$1" workload="$2" expected_csv="$3" msg="$4"
  ruby -ryaml -e '
    docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
    want, expected = ARGV.fetch(1), ARGV.fetch(2).split(",").reject(&:empty?)
    d = docs.find { |x|
      next false unless %w[Deployment Job].include?(x["kind"])
      x.dig("metadata", "name") == want ||
        x.dig("metadata", "labels", "app.kubernetes.io/component") == want
    }
    abort "#{want} not rendered" if d.nil?
    actual = (d.dig("spec", "template", "spec", "imagePullSecrets") || []).map { |s| s["name"] }
    abort "expected #{expected.inspect}, got #{actual.inspect}" unless actual == expected
  ' "$file" "$workload" "$expected_csv" || { red "FAIL: $msg"; exit 1; }
  green "ok  - $msg"
}

out390def="$TMP/scenario-aut390-default.yaml"
render_default "$out390def" --set global.deploymentMode=external
assert_pull_secrets "$out390def" control-plane-app "gcr-secret" \
  "default external app still uses gcr-secret"
assert_pull_secrets "$out390def" control-plane-api "gcr-secret" \
  "default external api still uses gcr-secret"
assert_pull_secrets "$out390def" mcp-signing-key "gcr-secret" \
  "default signing-key Job still uses gcr-secret"

out390cp="$TMP/scenario-aut390-controlplane.yaml"
render_default "$out390cp" --set global.deploymentMode=external \
  --set 'control-plane-app.controlPlane.imagePullSecrets=cp-creds' \
  --set 'control-plane-api.controlPlane.imagePullSecrets=cp-api-creds'
assert_pull_secrets "$out390cp" control-plane-app "cp-creds" \
  "controlPlane.imagePullSecrets reaches the app pod"
assert_pull_secrets "$out390cp" control-plane-api "cp-api-creds" \
  "controlPlane.imagePullSecrets reaches the api pod"
assert_pull_secrets "$out390cp" mcp-signing-key "cp-creds" \
  "signing-key Job tracks app controlPlane pull secret"

out390root="$TMP/scenario-aut390-root.yaml"
render_default "$out390root" --set global.deploymentMode=external \
  --set 'control-plane-app.imagePullSecrets=root-creds' \
  --set 'control-plane-api.imagePullSecrets=root-api-creds'
assert_pull_secrets "$out390root" control-plane-app "root-creds" \
  "subchart root imagePullSecrets reaches the app pod"
assert_pull_secrets "$out390root" mcp-signing-key "root-creds" \
  "signing-key Job tracks app root pull secret"

out390glob="$TMP/scenario-aut390-global.yaml"
render_default "$out390glob" --set global.deploymentMode=external \
  --set 'global.imagePullSecrets[0].name=global-creds'
assert_pull_secrets "$out390glob" control-plane-app "global-creds" \
  "global.imagePullSecrets reaches the app pod"
assert_pull_secrets "$out390glob" control-plane-api "global-creds" \
  "global.imagePullSecrets reaches the api pod"
assert_pull_secrets "$out390glob" mcp-signing-key "global-creds" \
  "signing-key Job tracks global pull secret"

out390none="$TMP/scenario-aut390-none-cp.yaml"
render_default "$out390none" --set global.deploymentMode=external \
  --set 'control-plane-app.controlPlane.imagePullSecrets=none' \
  --set 'control-plane-api.controlPlane.imagePullSecrets=none'
assert_pull_secrets "$out390none" control-plane-app "" \
  "controlPlane imagePullSecrets=none suppresses app pull secrets"
assert_pull_secrets "$out390none" control-plane-api "" \
  "controlPlane imagePullSecrets=none suppresses api pull secrets"
assert_pull_secrets "$out390none" mcp-signing-key "" \
  "controlPlane none suppresses signing-key Job pull secrets"

out390noneroot="$TMP/scenario-aut390-none-root.yaml"
render_default "$out390noneroot" --set global.deploymentMode=external \
  --set 'control-plane-app.imagePullSecrets=none' \
  --set 'control-plane-api.imagePullSecrets=none'
assert_pull_secrets "$out390noneroot" control-plane-app "" \
  "root imagePullSecrets=none suppresses app pull secrets"
assert_pull_secrets "$out390noneroot" mcp-signing-key "" \
  "root none suppresses signing-key Job pull secrets"

out390noneglob="$TMP/scenario-aut390-none-global.yaml"
render_default "$out390noneglob" --set global.deploymentMode=external \
  --set 'global.imagePullSecrets[0]=none'
assert_pull_secrets "$out390noneglob" control-plane-app "" \
  "global imagePullSecrets [none] suppresses app pull secrets"
assert_pull_secrets "$out390noneglob" mcp-signing-key "" \
  "global none suppresses signing-key Job pull secrets"

# Most-specific wins when several levels are set.
out390win="$TMP/scenario-aut390-precedence-wins.yaml"
render_default "$out390win" --set global.deploymentMode=external \
  --set 'global.imagePullSecrets[0].name=global-creds' \
  --set 'control-plane-app.imagePullSecrets=root-creds' \
  --set 'control-plane-app.controlPlane.imagePullSecrets=cp-creds'
assert_pull_secrets "$out390win" control-plane-app "cp-creds" \
  "controlPlane wins over root and global"
assert_pull_secrets "$out390win" mcp-signing-key "cp-creds" \
  "signing-key Job follows the winning app level"

# The embedded script ships as a string, so a syntax error would surface as a
# CrashLoopBackOff during an upgrade rather than at render time.
if command -v node >/dev/null 2>&1; then
  ruby -ryaml -e '
    docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
    job = docs.find { |d| d["kind"] == "Job" && d.dig("metadata", "labels", "app.kubernetes.io/component") == "mcp-signing-key" }
    File.write(ARGV.fetch(1), job.dig("spec", "template", "spec", "containers", 0, "command").last)
  ' "$out12ext" "$TMP/mcp-generator.js"
  node --check "$TMP/mcp-generator.js" \
    || { red "FAIL: the generator script is not valid JavaScript"; exit 1; }
  green "ok  - the generator script parses under the Node it runs on"
else
  yellow "skip - node not available to syntax-check the generator script"
fi

# Turning the generator off leaves the operator in charge, and with no key of
# their own the feature must stay off rather than half-work.
out12nogen_mcp="$TMP/scenario-mcp-oauth-no-generator.yaml"
render_default "$out12nogen_mcp" --set global.deploymentMode=external \
  --set global.mcpOAuth.generateSigningKey=false
assert_not_contains "$out12nogen_mcp" 'component: mcp-signing-key' \
  "generateSigningKey=false: no Job, no RBAC"
assert_not_contains "$out12nogen_mcp" 'MCP_DEFAULT_IDP_|name: MCP_OAUTH_CLIENT_ID' \
  "generateSigningKey=false with no key: MCP OAuth stays off"
# An explicit false must not leave a Job minting a key for a disabled feature.
assert_not_contains "$out12mcpoff" 'component: mcp-signing-key' \
  "mcpOAuth.enabled=false: the generator does not run"
# Hybrid has no authorization server, so it must carry none of this.
for f in "$out12hyb" "$out12hybkey"; do
  assert_not_contains "$f" 'component: mcp-signing-key' \
    "hybrid: no signing key generator is rendered"
done

blue "==> Scenario 12b: control-plane-app no longer couples to backend Secrets"
for legacy in agentgateway-secrets trustguard-secrets datacore-secrets alertengine-secrets; do
  ruby -ryaml -e '
    docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
    app = docs.find { |d| d["kind"] == "Deployment" && d.dig("metadata", "name") == "control-plane-app" }
    abort "control-plane-app not rendered" if app.nil?
    pod = app.dig("spec", "template", "spec")
    hits = ((pod["containers"] || []) + (pod["initContainers"] || [])).flat_map { |c|
      (c["env"] || []).select { |e| e.dig("valueFrom", "secretKeyRef", "name") == ARGV.fetch(1) }.map { |e| e["name"] }
    }
    abort "control-plane-app still reads #{ARGV.fetch(1)}: #{hits.join(", ")}" unless hits.empty?
  ' "$out12ext" "$legacy" || { red "FAIL: control-plane-app still couples to $legacy"; exit 1; }
done
green "ok  - control-plane-app reads no backend service Secret directly"

# Opt-outs must leave existing installs on the legacy contract untouched.
blue "==> Scenario 12c: shared Secret opt-outs (external, where the coupling lived)"
out12off="$TMP/scenario-shared-secret-disabled.yaml"
render_default "$out12off" --set global.deploymentMode=external --set global.platformSecret.enabled=false
assert_not_contains "$out12off" '^  name: platform-secrets$' \
  "platformSecret.enabled=false: Secret not rendered"
assert_not_contains "$out12off" 'name: "platform-secrets"' \
  "platformSecret.enabled=false: no workload references it"
assert_contains "$out12off" 'name: "control-plane-secrets"' \
  "platformSecret.enabled=false: refs fall back to the legacy Secret"

out12own="$TMP/scenario-shared-secret-operator-owned.yaml"
render_default "$out12own" --set global.deploymentMode=external --set global.platformSecret.existingSecret.name=my-platform-secrets
assert_not_contains "$out12own" '^  name: platform-secrets$' \
  "existingSecret.name: chart does not render its own Secret"
assert_contains "$out12own" 'name: "my-platform-secrets"' \
  "existingSecret.name: refs point at the operator Secret"

out12pres="$TMP/scenario-shared-secret-preserve.yaml"
render_default "$out12pres" --set global.deploymentMode=external --set global.preserveExistingSecrets=true
assert_not_contains "$out12pres" 'name: "platform-secrets"' \
  "preserveExistingSecrets: refs stay on the legacy per-service Secrets"

# A pinned value must reach the Secret verbatim.
blue "==> Scenario 12d: pinned credential"
out12pin="$TMP/scenario-shared-secret-pinned.yaml"
render_default "$out12pin" --set global.deploymentMode=external --set global.platformSecret.values.CONTROL_PLANE_JWT_SECRET=pinned-value-abc
ruby -ryaml -rbase64 -e '
  docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
  s = docs.find { |d| d["kind"] == "Secret" && d.dig("metadata", "name") == "platform-secrets" }
  got = Base64.decode64(s["data"].fetch("CONTROL_PLANE_JWT_SECRET"))
  abort "expected pinned value, got #{got}" unless got == "pinned-value-abc"
' "$out12pin" || { red "FAIL: pinned value not honored"; exit 1; }
green "ok  - global.platformSecret.values pins a credential verbatim"
