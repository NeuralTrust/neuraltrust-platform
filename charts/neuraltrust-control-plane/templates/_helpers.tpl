{{/*
Helper to construct image path with optional registry prefix
Usage: {{ include "control-plane.image" (dict "repository" .Values.controlPlane.components.api.image.repository "tag" .Values.controlPlane.components.api.image.tag "global" .Values.global) }}
*/}}
{{- define "control-plane.image" -}}
{{- $registry := "" }}
{{- $repository := .repository }}
{{- $tag := .tag }}
{{- $defaultRegistry := "europe-west1-docker.pkg.dev/neuraltrust-app-prod/nt-docker" }}
{{- if and .global .global.imageRegistry }}
  {{- $registry = .global.imageRegistry }}
{{- end }}
{{- if $registry }}
  {{- if hasPrefix $registry $repository }}
    {{- printf "%s:%s" $repository $tag }}
  {{- else if hasPrefix (printf "%s/" $defaultRegistry) $repository }}
    {{- $shortName := trimPrefix (printf "%s/" $defaultRegistry) $repository }}
    {{- printf "%s/%s:%s" $registry $shortName $tag }}
  {{- else }}
    {{- printf "%s/%s:%s" $registry $repository $tag }}
  {{- end }}
{{- else }}
  {{- printf "%s:%s" $repository $tag }}
{{- end }}
{{- end }}

{{/*
Create the name of the service account to use for control-plane workloads.
*/}}
{{- define "control-plane.serviceAccountName" -}}
{{- $sa := default dict (default dict .Values.controlPlane).serviceAccount -}}
{{- if hasKey $sa "name" -}}
{{- default "control-plane" $sa.name -}}
{{- else -}}
control-plane
{{- end -}}
{{- end }}

{{/*
Whether the product control-plane stack (api + app + supporting resources) is
active. In v2 the console is SaaS-side EXCEPT in external mode, where it runs
on-prem regardless of controlPlane.enabled (flag-driven, not values). In v1 it
keeps the explicit controlPlane.enabled opt-in. The scheduler is force-off in
v2 via its own `not isV2` guard and is NOT covered by this helper.
Usage: {{- if eq (include "neuraltrust-control-plane.controlPlaneEnabled" .) "true" }}
*/}}
{{- define "neuraltrust-control-plane.controlPlaneEnabled" -}}
{{- if eq (include "neuraltrust-platform.isV2" .) "true" -}}
  {{- /* v2: console is SaaS-side except in external mode, where it auto-enables
         regardless of controlPlane.enabled. controlPlane.enabled is ignored in v2. */ -}}
  {{- if eq (include "neuraltrust-platform.isExternal" .) "true" -}}true{{- end -}}
{{- else if and .Values.controlPlane .Values.controlPlane.enabled -}}true
{{- end -}}
{{- end }}

{{/*
Helper to get secret value - supports both direct values and secret references
Usage: {{ include "control-plane.getSecretValue" (dict "value" .Values.controlPlane.secrets.openaiApiKey "secretName" "my-secret" "secretKey" "OPENAI_API_KEY" "context" $) }}
*/}}
{{- define "control-plane.getSecretValue" -}}
{{- $value := .value }}
{{- $secretName := .secretName }}
{{- $secretKey := .secretKey }}
{{- $context := .context }}
{{- $preserveSecrets := false }}
{{- if $context.Values.global }}
  {{- if hasKey $context.Values.global "preserveExistingSecrets" }}
    {{- if $context.Values.global.preserveExistingSecrets }}
      {{- $preserveSecrets = true }}
    {{- end }}
  {{- end }}
{{- end }}

{{- if kindIs "map" $value }}
  {{- /* Value is a secret reference object */}}
  {{- if and (hasKey $value "secretName") (hasKey $value "secretKey") }}
    {{- $refSecretName := $value.secretName }}
    {{- $refSecretKey := $value.secretKey }}
    {{- $refSecret := (lookup "v1" "Secret" $context.Release.Namespace $refSecretName) }}
    {{- if and $refSecret (hasKey $refSecret.data $refSecretKey) }}
      {{- /* Use value from referenced secret */}}
      {{- index $refSecret.data $refSecretKey | quote }}
    {{- else }}
      {{- /* Referenced secret doesn't exist, use empty string */}}
      {{- "" | b64enc | quote }}
    {{- end }}
  {{- else }}
    {{- /* Invalid secret reference format */}}
    {{- "" | b64enc | quote }}
  {{- end }}
{{- else }}
  {{- /* Value is a direct string - check if we should preserve existing secret */}}
  {{- $existingSecret := (lookup "v1" "Secret" $context.Release.Namespace $secretName) }}
  {{- if and $preserveSecrets $existingSecret (hasKey $existingSecret.data $secretKey) }}
    {{- /* Preserve existing value */}}
    {{- index $existingSecret.data $secretKey | quote }}
  {{- else if $value }}
    {{- /* Use provided value */}}
    {{- $value | b64enc }}
  {{- else }}
    {{- /* Empty value */}}
    {{- "" | b64enc | quote }}
  {{- end }}
{{- end }}
{{- end }}

{{/*
Helper to get secret value as raw string (decoded) - for use in connection strings
Usage: {{ include "control-plane.getSecretValueRaw" (dict "value" .Values.controlPlane.components.postgresql.secrets.password "secretName" "my-secret" "secretKey" "POSTGRES_PASSWORD" "context" $) }}
*/}}
{{- define "control-plane.getSecretValueRaw" -}}
{{- $value := .value }}
{{- $secretName := .secretName }}
{{- $secretKey := .secretKey }}
{{- $context := .context }}
{{- $preserveSecrets := false }}
{{- if $context.Values.global }}
  {{- if hasKey $context.Values.global "preserveExistingSecrets" }}
    {{- if $context.Values.global.preserveExistingSecrets }}
      {{- $preserveSecrets = true }}
    {{- end }}
  {{- end }}
{{- end }}

{{- if kindIs "map" $value }}
  {{- /* Value is a secret reference object */}}
  {{- if and (hasKey $value "secretName") (hasKey $value "secretKey") }}
    {{- $refSecretName := $value.secretName }}
    {{- $refSecretKey := $value.secretKey }}
    {{- $refSecret := (lookup "v1" "Secret" $context.Release.Namespace $refSecretName) }}
    {{- if and $refSecret (hasKey $refSecret.data $refSecretKey) }}
      {{- /* Use value from referenced secret - decode from base64 */}}
      {{- index $refSecret.data $refSecretKey | b64dec }}
    {{- else }}
      {{- /* Referenced secret doesn't exist, use empty string */}}
      {{- "" }}
    {{- end }}
  {{- else }}
    {{- /* Invalid secret reference format */}}
    {{- "" }}
  {{- end }}
{{- else }}
  {{- /* Value is a direct string - check if we should preserve existing secret */}}
  {{- $existingSecret := (lookup "v1" "Secret" $context.Release.Namespace $secretName) }}
  {{- if and $preserveSecrets $existingSecret (hasKey $existingSecret.data $secretKey) }}
    {{- /* Preserve existing value - decode from base64 */}}
    {{- index $existingSecret.data $secretKey | b64dec }}
  {{- else if $value }}
    {{- /* Use provided value directly */}}
    {{- $value }}
  {{- else }}
    {{- /* Empty value */}}
    {{- "" }}
  {{- end }}
{{- end }}
{{- end }}

{{/*
Helper to check if PostgreSQL should be deployed
Checks infrastructure.postgresql.deploy from parent chart first, then subchart values
Also supports legacy installInCluster variable for backward compatibility
Explicitly respects deploy: false to disable deployment
Usage: {{ include "control-plane.postgresql.deploy" . }}
*/}}
{{- define "control-plane.postgresql.deploy" -}}
{{- $deploy := true }}
{{- $found := false }}
{{- /* Check if passed via subchart values (when parent passes infrastructure to subchart via neuraltrust-control-plane.infrastructure.postgresql.deploy) */}}
{{- if and .Values.infrastructure .Values.infrastructure.postgresql }}
  {{- if hasKey .Values.infrastructure.postgresql "deploy" }}
    {{- $deploy = .Values.infrastructure.postgresql.deploy }}
    {{- $found = true }}
  {{- else if hasKey .Values.infrastructure.postgresql "installInCluster" }}
    {{- /* Legacy support: installInCluster as alternative to deploy */}}
    {{- $deploy = .Values.infrastructure.postgresql.installInCluster }}
    {{- $found = true }}
  {{- end }}
{{- end }}
{{- /* Fallback: Try to get from parent chart values (infrastructure.postgresql.deploy or installInCluster) */}}
{{- if and (not $found) .Release.Parent }}
  {{- if and .Release.Parent.Values.infrastructure .Release.Parent.Values.infrastructure.postgresql }}
    {{- if hasKey .Release.Parent.Values.infrastructure.postgresql "deploy" }}
      {{- $deploy = .Release.Parent.Values.infrastructure.postgresql.deploy }}
    {{- else if hasKey .Release.Parent.Values.infrastructure.postgresql "installInCluster" }}
      {{- /* Legacy support: installInCluster as alternative to deploy */}}
      {{- $deploy = .Release.Parent.Values.infrastructure.postgresql.installInCluster }}
    {{- end }}
  {{- end }}
{{- end }}
{{- /* Legacy component-level false remains authoritative even though the newer
       infrastructure.deploy default is present in the subchart values. */}}
{{- if and .Values.controlPlane .Values.controlPlane.components .Values.controlPlane.components.postgresql (hasKey .Values.controlPlane.components.postgresql "installInCluster") (not .Values.controlPlane.components.postgresql.installInCluster) }}
  {{- $deploy = false }}
{{- end }}
{{- /* Umbrella-wide override (propagated to subcharts): an explicit global.postgresql.deploy=false
       forces external Postgres regardless of the infrastructure default, so the postgres image is
       never pulled. Either flag set to false disables in-cluster Postgres. */}}
{{- if and .Values.global .Values.global.postgresql (hasKey .Values.global.postgresql "deploy") (not .Values.global.postgresql.deploy) }}
  {{- $deploy = false }}
{{- end }}
{{- /* Return empty string for false, non-empty for true - Helm's include returns strings, and empty string is falsy */}}
{{- if $deploy }}{{- "true" }}{{- end }}
{{- end }}

{{/*
Helper that returns the resolved OTel collector endpoint for control-plane
components. Resolution order:
  1. global.observability.collector.endpoint (umbrella-wide override)
  2. controlPlane.components.<name>.config.otelExporterOtlpEndpoint
The returned string is empty when neither is set, in which case no OTel
env vars should be rendered (preserves backward compat — the chart was
never wiring these before).
Usage: {{ include "control-plane.otelEndpoint" (dict "component" "api" "context" .) }}
*/}}
{{- define "control-plane.otelEndpoint" -}}
{{- $ctx := .context -}}
{{- $component := .component -}}
{{- $endpoint := "" -}}
{{- if and $ctx.Values.controlPlane $ctx.Values.controlPlane.components -}}
  {{- $cmp := index $ctx.Values.controlPlane.components $component -}}
  {{- if and $cmp $cmp.config $cmp.config.otelExporterOtlpEndpoint -}}
    {{- $endpoint = $cmp.config.otelExporterOtlpEndpoint -}}
  {{- end -}}
{{- end -}}
{{- $globalObs := default dict (default dict $ctx.Values.global).observability -}}
{{- $globalColl := default dict $globalObs.collector -}}
{{- if $globalColl.endpoint -}}
  {{- $endpoint = $globalColl.endpoint -}}
{{- end -}}
{{- $endpoint -}}
{{- end }}

{{/*
Helper that emits the merged envFrom list for a control-plane component:
the OTel ConfigMap (when an endpoint is resolved) plus any per-component
extraEnvFrom items. Emits nothing when the list is empty (so the
deployment renders without a trailing `envFrom:` key).
Usage: {{- include "control-plane.envFrom" (dict "component" "api" "extraEnvFrom" .Values.controlPlane.components.api.extraEnvFrom "context" .) | nindent 8 }}
*/}}
{{- define "control-plane.envFrom" -}}
{{- $component := .component -}}
{{- $extra := .extraEnvFrom -}}
{{- $context := .context -}}
{{- $items := list -}}
{{- $endpoint := include "control-plane.otelEndpoint" (dict "component" $component "context" $context) -}}
{{- if $endpoint -}}
  {{- $items = append $items (dict "configMapRef" (dict "name" (printf "control-plane-%s-otel" $component))) -}}
{{- end -}}
{{- if $extra -}}
  {{- range $extra -}}
    {{- $items = append $items . -}}
  {{- end -}}
{{- end -}}
{{- if $items -}}
envFrom:
{{ toYaml $items }}
{{- end -}}
{{- end }}

{{/*
Resolve the control-plane app's public origin (scheme + host). Used for APP_URL
and NEXTAUTH_URL so magic links / auth callbacks match the real ingress host
instead of the in-cluster service name.
Priority:
  1. OpenShift: control-plane-app.<domain> (matches the OpenShift Route naming)
  2. explicit controlPlane.components.app.host
  3. <app.hostPrefix|"app">.<global.domain> (matches the app Ingress)
  4. bare "control-plane-app" (no domain/host configured)
Usage: {{ include "control-plane.appPublicUrl" . }}
*/}}
{{- define "control-plane.appPublicUrl" -}}
{{- $app := dict -}}
{{- if and .Values.controlPlane .Values.controlPlane.components .Values.controlPlane.components.app -}}
  {{- $app = .Values.controlPlane.components.app -}}
{{- end -}}
{{- $host := "" -}}
{{- if eq (include "neuraltrust-platform.isOpenshift" .) "true" -}}
  {{- $domain := include "neuraltrust-platform.domain" . -}}
  {{- if $domain -}}{{- $host = printf "control-plane-app.%s" $domain -}}{{- end -}}
{{- else -}}
  {{- $prefix := "app" -}}
  {{- if hasKey $app "hostPrefix" -}}{{- $prefix = $app.hostPrefix -}}{{- end -}}
  {{- $host = include "neuraltrust-platform.ingress.host" (dict "host" ($app.host | default "") "prefix" $prefix "global" .Values.global) -}}
{{- end -}}
{{- if not $host -}}{{- $host = "control-plane-app" -}}{{- end -}}
{{- printf "https://%s" $host -}}
{{- end }}

