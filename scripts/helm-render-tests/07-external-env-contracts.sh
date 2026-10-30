#!/usr/bin/env bash
# Render scenarios 3-superadmin, 3-envnames, 3-email, 3-hybrid-envnames, 3-superadmin-secret, 3a. Run through scripts/test-helm-render.sh.

source "$(dirname "$0")/lib.sh"
suite_full || exit 0

blue "==> Scenario 3-superadmin: ONPREM_SUPERADMIN_* when global.superadmin set"
out3sa="$TMP/scenario-external-superadmin.yaml"
render_default "$out3sa" \
  --set global.deploymentMode=external \
  --set global.superadmin.email=admin@example.com \
  --set global.superadmin.password=s3cret
if ! grep -A4 -E '^        - name: ONPREM_SUPERADMIN_PASSWORD$' "$out3sa" \
  | grep -qE '^              name: control-plane-secrets$'; then
  red "FAIL: external+superadmin: ONPREM_SUPERADMIN_PASSWORD not sourced from control-plane-secrets"
  exit 1
fi
green "ok  - external+superadmin: ONPREM_SUPERADMIN_PASSWORD from control-plane-secrets"
assert_contains "$out3sa" 'ONPREM_SUPERADMIN_EMAIL: "YWRtaW5AZXhhbXBsZS5jb20="' \
  "external+superadmin: inline email rendered into control-plane-secrets"
assert_contains "$out3sa" 'ONPREM_SUPERADMIN_PASSWORD: "czNjcmV0"' \
  "external+superadmin: inline password rendered into control-plane-secrets"
# The password must never reach the Deployment spec as a literal value.
assert_not_contains "$out3sa" 'value: "s3cret"' \
  "external+superadmin: password never a plain container env value"

# Env var names must match what the apps actually read; a mismatch is silently
# ignored at runtime rather than failing loudly.
blue "==> Scenario 3-envnames: chart env names match the names the apps read"
out3en="$TMP/scenario-external-envnames.yaml"
render_default "$out3en" \
  --set global.deploymentMode=external \
  --set data-plane-api.dataPlane.components.api.k8sJobs.enabled=true \
  --set data-plane-api.dataPlane.components.api.k8sJobs.ttlSecondsAfterFinished=900 \
  --set data-plane-api.dataPlane.components.api.k8sJobs.maxConcurrentJobs=25 \
  --set control-plane-app.controlPlane.secrets.resendAlertSender=alerts@example.com \
  --set control-plane-app.controlPlane.secrets.resendReplyTo=support@example.com
# data-plane-api reads K8S_JOB_TTL_SECONDS / K8S_MAX_CONCURRENT_JOBS.
assert_contains "$out3en" '^          - name: K8S_JOB_TTL_SECONDS$' \
  "envnames: K8S_JOB_TTL_SECONDS set on data-plane-api"
assert_contains "$out3en" '^          - name: K8S_MAX_CONCURRENT_JOBS$' \
  "envnames: K8S_MAX_CONCURRENT_JOBS set on data-plane-api"
# control-plane-app reads SENDER / REPLY_TO_EMAIL, never RESEND_SENDER. Legacy
# controlPlane.secrets.resend* values must keep feeding them.
assert_contains "$out3en" '^        - name: SENDER$' \
  "envnames: SENDER set on control-plane-app"
assert_contains "$out3en" '^          value: "alerts@example.com"$' \
  "envnames: legacy resendAlertSender still feeds SENDER"
assert_contains "$out3en" '^        - name: REPLY_TO_EMAIL$' \
  "envnames: REPLY_TO_EMAIL set on control-plane-app"
assert_contains "$out3en" 'resend-reply-to:' \
  "envnames: control-plane-secrets carries resend-reply-to"
assert_contains "$out3en" '^        - name: POSTGRES_AUTH_MODE$' \
  "envnames: POSTGRES_AUTH_MODE still set on control-plane-app"

# The app supports resend | ses | smtp behind AUTH_EMAIL_PROVIDER. Addresses are
# public config (plain env); only credentials may come from a Secret.
blue "==> Scenario 3-email: provider-specific outbound email wiring"
out3em="$TMP/scenario-external-email-smtp.yaml"
render_default "$out3em" \
  --set global.deploymentMode=external \
  --set global.email.provider=smtp \
  --set global.email.from=noreply@example.com \
  --set global.email.replyTo=help@example.com \
  --set global.email.smtp.host=smtp.example.com \
  --set global.email.smtp.port=465 \
  --set global.email.smtp.user=mailer \
  --set global.email.smtp.password=s3cr3t
assert_contains "$out3em" '^          value: "smtp"$' \
  "email smtp: AUTH_EMAIL_PROVIDER is smtp"
assert_contains "$out3em" '^        - name: SMTP_HOST$' "email smtp: SMTP_HOST set"
assert_contains "$out3em" '^          value: "465"$' "email smtp: SMTP_PORT set"
assert_contains "$out3em" '^        - name: SMTP_SECURE$' "email smtp: SMTP_SECURE set"
assert_contains "$out3em" '^        - name: SMTP_USER$' "email smtp: SMTP_USER set"
# App reads SMTP_PASS; the chart Secret key is SMTP_PASSWORD.
assert_contains "$out3em" '^        - name: SMTP_PASS$' "email smtp: SMTP_PASS set"
assert_contains "$out3em" '^  SMTP_PASSWORD: ' "email smtp: password stored in a Secret"
assert_not_contains "$out3em" 'value: "s3cr3t"' \
  "email smtp: password never a plain env value"
# Addresses are public and must not be pushed into a Secret.
assert_contains "$out3em" '^          value: "noreply@example.com"$' \
  "email smtp: from address is plain env"
assert_not_contains "$out3em" '^  EMAIL_FROM: ' \
  "email smtp: from address not stored as a Secret key"
assert_not_contains "$out3em" '^        - name: AWS_SES_REGION$' \
  "email smtp: no SES env when provider is smtp"

out3ses="$TMP/scenario-external-email-ses.yaml"
render_default "$out3ses" \
  --set global.deploymentMode=external \
  --set global.email.provider=ses \
  --set global.email.ses.region=eu-west-1
assert_contains "$out3ses" '^        - name: AWS_SES_REGION$' "email ses: AWS_SES_REGION set"
# No static keys means the pod IAM role (IRSA) is used; injecting static creds
# would hijack the SDK credential chain for Postgres IAM auth too.
assert_not_contains "$out3ses" '^        - name: AWS_ACCESS_KEY_ID$' \
  "email ses: no static credentials when relying on IRSA"
assert_not_contains "$out3ses" '^        - name: SMTP_HOST$' \
  "email ses: no SMTP env when provider is ses"

# Misconfigured providers must fail at render time, not silently drop email.
# extraEnv was the only way to select a provider before global.email existed.
# Emitting the same env name twice makes the API server reject the
# strategic-merge patch, so the chart must yield to extraEnv on upgrade.
out3ex="$TMP/scenario-external-email-extraenv.yaml"
render_default "$out3ex" \
  --set global.deploymentMode=external \
  --set 'control-plane-app.controlPlane.components.app.extraEnv[0].name=AUTH_EMAIL_PROVIDER' \
  --set 'control-plane-app.controlPlane.components.app.extraEnv[0].value=ses' \
  --set 'control-plane-app.controlPlane.components.app.extraEnv[1].name=AWS_SES_REGION' \
  --set 'control-plane-app.controlPlane.components.app.extraEnv[1].value=eu-west-1' \
  --set 'control-plane-app.controlPlane.components.app.extraEnv[2].name=AUTH_EMAIL_FROM' \
  --set 'control-plane-app.controlPlane.components.app.extraEnv[2].value=no-reply@example.com'
assert_occurrences "$out3ex" '^        - name: AUTH_EMAIL_PROVIDER$' 1 \
  "email extraEnv: AUTH_EMAIL_PROVIDER emitted once, not duplicated"
assert_occurrences "$out3ex" '^        - name: AWS_SES_REGION$' 1 \
  "email extraEnv: AWS_SES_REGION emitted once, not duplicated"
assert_occurrences "$out3ex" '^        - name: AUTH_EMAIL_FROM$' 1 \
  "email extraEnv: AUTH_EMAIL_FROM emitted once, not duplicated"
# extraEnv goes through toYaml, so the value renders unquoted.
assert_contains "$out3ex" '^          value: ses$' \
  "email extraEnv: operator override wins over the chart default"
assert_not_contains "$out3ex" '^          value: "resend"$' \
  "email extraEnv: chart default provider not also emitted"

assert_render_fails "email: unknown provider fails render" \
  --set global.deploymentMode=external --set global.email.provider=mailgun
assert_render_fails "email: ses without a region fails render" \
  --set global.deploymentMode=external --set global.email.provider=ses
assert_render_fails "email: smtp without a host fails render" \
  --set global.deploymentMode=external --set global.email.provider=smtp
assert_render_fails "email: smtp user without a password source fails render" \
  --set global.deploymentMode=external --set global.email.provider=smtp \
  --set global.email.smtp.host=smtp.example.com --set global.email.smtp.user=mailer
assert_render_fails "email: existingSecret plus an inline credential fails render" \
  --set global.deploymentMode=external \
  --set global.email.existingSecret.name=my-email \
  --set global.email.resend.apiKey=re_123

# Hybrid is the primary customer topology, and it renders data-plane-api without
# any control plane, so the external-mode assertions above never exercise it.
blue "==> Scenario 3-hybrid-envnames: data-plane-api env names in hybrid mode"
out3hy="$TMP/scenario-hybrid-envnames.yaml"
render_default "$out3hy" \
  --set global.deploymentMode=hybrid \
  --set global.products.trustguard=true \
  --set global.products.dataPlane=true \
  --set data-plane-api.dataPlane.components.api.k8sJobs.enabled=true \
  --set data-plane-api.dataPlane.components.api.k8sJobs.ttlSecondsAfterFinished=900 \
  --set data-plane-api.dataPlane.components.api.k8sJobs.maxConcurrentJobs=25
assert_contains "$out3hy" '^          - name: K8S_JOB_TTL_SECONDS$' \
  "hybrid envnames: K8S_JOB_TTL_SECONDS set on data-plane-api"
assert_contains "$out3hy" '^          - name: K8S_MAX_CONCURRENT_JOBS$' \
  "hybrid envnames: K8S_MAX_CONCURRENT_JOBS set on data-plane-api"
# Hybrid has no control plane, so control-plane-app must not appear at all.
assert_not_contains "$out3hy" '^  name: control-plane-app$' \
  "hybrid envnames: no control-plane-app in hybrid"

# PR1 on the hybrid path: the data-plane-api Route is the only Route carrying a
# control-plane-facing TLS Secret here, and it must still avoid key material.
out3hytls="$TMP/scenario-hybrid-openshift-route-tls.yaml"
helm template test "$CHART_DIR" --namespace default \
  -f "$CHART_DIR/values-required.yaml" \
  "${CLICKSTACK_DEFAULT_ARGS[@]}" \
  --api-versions route.openshift.io/v1 \
  --set global.deploymentMode=hybrid \
  --set global.products.trustguard=true \
  --set global.products.dataPlane=true \
  --set global.platform=openshift \
  --set global.domain=apps.example.com \
  --set data-plane-api.dataPlane.components.api.ingress.enabled=false \
  --set data-plane-api.dataPlane.components.api.ingress.tls.secretName=dp-tls \
  > "$out3hytls"
validate_yaml "$out3hytls"
assert_contains "$out3hytls" '^    externalCertificate:$' \
  "hybrid Route TLS: data-plane-api Route references a TLS Secret"
assert_contains "$out3hytls" 'name: "dp-tls"' \
  "hybrid Route TLS: externalCertificate references dp-tls"
if awk '/^kind: Route$/{r=1} /^---$/{r=0} r' "$out3hytls" | grep -qE 'PRIVATE KEY|^ +key:'; then
  red "FAIL: hybrid Route TLS: a Route contains private key material"
  exit 1
fi
green "ok  - hybrid Route TLS: no Route contains private key material"

blue "==> Scenario 3-superadmin-secret: existingSecret wins over inline"
out3sas="$TMP/scenario-external-superadmin-secret.yaml"
render_default "$out3sas" \
  --set global.deploymentMode=external \
  --set global.superadmin.existingSecret.name=onprem-superadmin \
  --set global.superadmin.email=ignored@example.com \
  --set global.superadmin.password=ignored
assert_contains "$out3sas" 'name: ONPREM_SUPERADMIN_EMAIL'$'\n''          valueFrom:'$'\n''            secretKeyRef:'$'\n''              name: "onprem-superadmin"' \
  "external+superadmin secret: EMAIL from existingSecret"
assert_contains "$out3sas" 'key: "ONPREM_SUPERADMIN_EMAIL"' \
  "external+superadmin secret: default email key"
assert_contains "$out3sas" 'name: ONPREM_SUPERADMIN_PASSWORD'$'\n''          valueFrom:'$'\n''            secretKeyRef:'$'\n''              name: "onprem-superadmin"' \
  "external+superadmin secret: PASSWORD from existingSecret"
assert_contains "$out3sas" 'key: "ONPREM_SUPERADMIN_PASSWORD"' \
  "external+superadmin secret: default password key"
assert_not_contains "$out3sas" 'value: "ignored@example.com"' \
  "external+superadmin secret: inline email not used when existingSecret set"
assert_not_contains "$out3sas" 'value: "ignored"' \
  "external+superadmin secret: inline password not used when existingSecret set"

# External config-sync servers and clients must share each component's
# operator-owned credentials.
blue "==> Scenario 3a: external config-sync uses shared operator Secrets"
out3a="$TMP/scenario-external-config-sync.yaml"
render_default "$out3a" \
  --set global.deploymentMode=external \
  --set agentgateway.configSync.enabled=true \
  --set agentgateway.configSync.existingSecret.name=agentgateway-config-sync \
  --set trustguard.configSync.enabled=true \
  --set trustguard.configSync.existingSecret.name=trustguard-config-sync
# One reference per workload: the token only. The LKG key rides along on the
# chart-managed Secret through envFrom.
assert_occurrences "$out3a" 'name: "?agentgateway-config-sync"?' 3 \
  "external config-sync: AgentGateway proxy, MCP, and admin share the operator token"
assert_occurrences "$out3a" 'name: "?trustguard-config-sync"?' 2 \
  "external config-sync: TrustGuard data and control planes share the operator token"
