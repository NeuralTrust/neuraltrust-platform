{{/*
Render-time warnings.

A check that would break a values file which renders today cannot be a `fail` in
a minor release, so it starts here instead: the install proceeds and NOTES.txt
prints the warning after it. A warning can be promoted to a `fail` in
validate-values.yaml only in a major release, after it has shipped as a warning.

Output is a YAML list of strings (empty when there is nothing to say), so
NOTES.txt and any other reader can consume it the same way. Each entry says what
is wrong, what breaks, and the key that fixes it.

Usage: {{ include "neuraltrust-platform.warnings" . }}
*/}}
{{- define "neuraltrust-platform.warnings" -}}
{{- $warnings := list -}}

{{- /* Weak sslMode under RDS IAM token auth, external and saas.
       validate-values.yaml already fails this for hybrid, where the shared Secret
       is the only source. Here each gateway resolves its own database block, so
       the check runs per gateway and only for the ones that actually log in with
       a token: a mixed-auth install (global authMode iam, one gateway on
       database.iamAuth=false) uses a password for that gateway, and TrustGate and
       TrustGuard accept a weak mode with a password. Both binaries refuse to start
       with token auth over anything weaker than require. */ -}}
{{- if eq (include "neuraltrust-platform.isExternal" .) "true" -}}
{{- $secureSsl := list "require" "verify-ca" "verify-full" -}}
{{- range $gw := list (dict "product" "trustgate" "key" "agentgateway" "name" "TrustGate") (dict "product" "trustguard" "key" "trustguard" "name" "TrustGuard") -}}
{{- if eq (include "neuraltrust-platform.product.enabled" (dict "ctx" $ "product" $gw.product)) "true" -}}
{{- $db := default dict (default dict (index $.Values $gw.key)).database -}}
{{- if eq (include "neuraltrust-platform.postgres.iamAuth" (dict "ctx" $ "database" $db)) "true" -}}
{{- $ssl := include "neuraltrust-platform.postgres.sslMode" (dict "ctx" $ "sslMode" $db.sslMode) | toString | trim | lower -}}
{{- if not (has $ssl $secureSsl) -}}
{{- $warnings = append $warnings (printf "%s uses PostgreSQL IAM token auth with sslMode %q. It refuses to start with a token over anything weaker than require. Fix: set %s.database.sslMode (or global.postgresql.sslMode) to require, verify-ca or verify-full." $gw.name $ssl $gw.key) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /* authMode: iam with the chart's own Postgres. IAM is ignored there
       (neuraltrust-platform.postgresql.iam), so every service logs in with a
       password; the operator almost always meant a managed instance and forgot
       deploy: false. */ -}}
{{- $pg := default dict (default dict .Values.global).postgresql -}}
{{- if and (eq ($pg.authMode | default "" | toString | lower) "iam") (eq (include "neuraltrust-platform.postgresql.deploy" .) "true") -}}
{{- $warnings = append $warnings "global.postgresql.authMode is iam, but the chart is deploying its own PostgreSQL, which has no token login, so IAM is ignored and every service uses a password. Fix: for a managed instance set global.postgresql.deploy: false and global.postgresql.host; otherwise remove authMode." -}}
{{- end -}}

{{- if $warnings -}}
{{- toYaml $warnings -}}
{{- end -}}
{{- end -}}
