#!/usr/bin/env bash
# Render scenarios 2d. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

# ---------------------------------------------------------------------------
# 2d. The schema runner connects exactly as the API does.
#
# The runner succeeds only when it reaches Postgres the way the API does, so
# every connection-affecting input the api container gets — custom CA, proxy
# (the Entra token call is outbound HTTPS), mounted secrets, extraEnvFrom —
# must reach the initContainer too, under the same hardening.
# ---------------------------------------------------------------------------
blue "==> Scenario 2d: data-plane schema runner parity with the api container"
parity_values="$TMP/pg-runner-parity.yaml"
cat > "$parity_values" <<'EOF'
global:
  customCaCert:
    enabled: true
    secretName: corp-ca
  proxy:
    enabled: true
    httpsProxy: "http://proxy.corp.example:3128"
data-plane-api:
  dataPlane:
    components:
      api:
        extraEnvFrom:
          - secretRef:
              name: operator-pg-tuning
        extraVolumes:
          - name: secrets-store
            emptyDir: {}
        extraVolumeMounts:
          - name: secrets-store
            mountPath: /etc/secrets
            readOnly: true
EOF
out2d="$TMP/scenario-pg-runner-parity.yaml"
render_default "$out2d" -f "$parity_values"
ruby -ryaml -e '
  docs = []
  YAML.load_stream(File.read(ARGV[0])) { |d| docs << d if d.is_a?(Hash) }
  spec = docs.find { |x| x["kind"] == "Deployment" && x.dig("metadata", "name") == "data-plane-api" }.dig("spec", "template", "spec")
  api = spec["containers"].find { |c| c["name"] == "api" }
  init = spec["initContainers"].find { |c| c["name"] == "postgres-migrations" }
  names = ->(c) { (c["env"] || []).map { |e| e["name"] } }
  missing = %w[PGSSLROOTCERT SSL_CERT_FILE REQUESTS_CA_BUNDLE HTTPS_PROXY NO_PROXY] - names.(init)
  abort "env missing on initContainer: #{missing}" unless missing.empty?
  mounts = ->(c) { (c["volumeMounts"] || []).map { |m| [m["name"], m["mountPath"]] } }
  gap = mounts.(api) - mounts.(init)
  abort "api mounts absent from initContainer: #{gap}" unless gap.empty?
  from = ->(c) { (c["envFrom"] || []).map { |e| (e["secretRef"] || e["configMapRef"])["name"] } }
  abort "extraEnvFrom not on initContainer: #{from.(init)}" unless from.(init).include?("operator-pg-tuning")
  abort "initContainer rootfs is writable" unless init.dig("securityContext", "readOnlyRootFilesystem") == true
' "$out2d" \
  && green "ok  - schema runner: CA, proxy, mounts, envFrom and hardening match the api container" \
  || { red "FAIL: schema runner diverges from the api container"; exit 1; }

# Resources: migration.resources, then api.initContainerResources, then a
# Python-sized default. The old psql-sized 64Mi/128Mi default would OOM-kill it.
out2d_res="$TMP/scenario-pg-runner-resources.yaml"
render_default "$out2d_res" \
  --set data-plane-api.dataPlane.components.api.initContainerResources.limits.memory=700Mi
pg_runner_memory_limit() {
  ruby -ryaml -e '
    docs = []
    YAML.load_stream(File.read(ARGV[0])) { |d| docs << d if d.is_a?(Hash) }
    spec = docs.find { |x| x["kind"] == "Deployment" && x.dig("metadata", "name") == "data-plane-api" }.dig("spec", "template", "spec")
    puts spec["initContainers"].find { |c| c["name"] == "postgres-migrations" }.dig("resources", "limits", "memory")
  ' "$1"
}
out2d_res2="$TMP/scenario-pg-runner-resources-explicit.yaml"
render_default "$out2d_res2" \
  --set data-plane-api.dataPlane.components.api.initContainerResources.limits.memory=700Mi \
  --set data-plane-api.dataPlane.components.api.database.postgresql.migration.resources.limits.memory=900Mi
for case in "$out2d:512Mi:Python-sized default" \
            "$out2d_res:700Mi:api.initContainerResources applies when migration.resources is empty" \
            "$out2d_res2:900Mi:migration.resources wins over api.initContainerResources"; do
  file="${case%%:*}"; rest="${case#*:}"; want="${rest%%:*}"; what="${rest#*:}"
  got="$(pg_runner_memory_limit "$file")"
  [[ "$got" == "$want" ]] && green "ok  - schema runner resources: $what" \
    || { red "FAIL: schema runner resources: $what (want $want, got $got)"; exit 1; }
done

out2d_off="$TMP/scenario-pg-runner-off.yaml"
render_default "$out2d_off" \
  --set data-plane-api.dataPlane.components.api.database.postgresql.migration.enabled=false
assert_not_contains "$out2d_off" 'name: postgres-migrations' \
  "schema runner: migration.enabled=false still opts out"
out2d_ch="$TMP/scenario-pg-runner-clickhouse.yaml"
render_default "$out2d_ch" --set global.deploymentMode=external
assert_not_contains "$out2d_ch" 'name: postgres-migrations' \
  "schema runner: ClickHouse backend renders no Postgres migration"
assert_contains "$out2d_ch" 'name: clickhouse-migrations' \
  "schema runner: ClickHouse backend keeps its own migration"
