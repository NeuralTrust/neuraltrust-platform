{{/*
Fully-qualified image path (subchart-local wrapper around
neuraltrust-platform.image).
*/}}
{{- define "control-plane.image" -}}
{{- include "neuraltrust-platform.image" (dict "repository" .repository "tag" .tag "global" .global) -}}
{{- end }}

{{/*
ServiceAccount name for control-plane workloads. Both API and App share the
stable `control-plane` SA rendered by the umbrella chart.
*/}}
{{- define "control-plane.serviceAccountName" -}}
{{- $sa := default dict (default dict .Values.controlPlane).serviceAccount -}}
{{- default "control-plane" $sa.name -}}
{{- end }}

{{/*
Whether the control-plane subchart should render its workloads. v2-only:
render only in external mode (control planes live in NeuralTrust SaaS in
hybrid).
*/}}
{{- define "control-plane-api.enabled" -}}
{{- if eq (include "neuraltrust-platform.isExternal" .) "true" -}}true{{- end -}}
{{- end }}

{{/*
Whether in-cluster PostgreSQL is deployed. Sole source of truth is
`global.postgresql.deploy` (v2 contract).
*/}}
{{- define "control-plane.postgresql.deploy" -}}
{{- $globalPg := default dict (default dict .Values.global).postgresql -}}
{{- $deploy := true -}}
{{- if hasKey $globalPg "deploy" -}}{{- $deploy = $globalPg.deploy -}}{{- end -}}
{{- if $deploy }}true{{- end -}}
{{- end }}

{{/*
Whether control-plane Postgres uses RDS IAM auth. Prefer the per-service
overlay (`controlPlane.components.postgresql.authMode`), then fall back to
`global.postgresql.authMode`. IAM is ignored for in-cluster Postgres.
*/}}
{{- define "control-plane.postgresql.iam" -}}
{{- if include "control-plane.postgresql.deploy" . -}}
{{- else -}}
{{- $authMode := "" -}}
{{- $cpPg := default dict (default dict (default dict .Values.controlPlane).components).postgresql -}}
{{- $globalPg := default dict (default dict .Values.global).postgresql -}}
{{- if and $cpPg.authMode (ne ($cpPg.authMode | toString) "") -}}
  {{- $authMode = $cpPg.authMode | toString | lower -}}
{{- else if and $globalPg.authMode (ne ($globalPg.authMode | toString) "") -}}
  {{- $authMode = $globalPg.authMode | toString | lower -}}
{{- end -}}
{{- if eq $authMode "iam" }}true{{- end -}}
{{- end -}}
{{- end }}

{{/*
AWS region for RDS IAM token minting. Prefer
`controlPlane.components.postgresql.awsRegion`, then
`global.postgresql.awsRegion`.
*/}}
{{- define "control-plane.postgresql.awsRegion" -}}
{{- $region := "" -}}
{{- $cpPg := default dict (default dict (default dict .Values.controlPlane).components).postgresql -}}
{{- $globalPg := default dict (default dict .Values.global).postgresql -}}
{{- if and $cpPg.awsRegion (ne ($cpPg.awsRegion | toString) "") -}}
  {{- $region = $cpPg.awsRegion | toString -}}
{{- else if and $globalPg.awsRegion (ne ($globalPg.awsRegion | toString) "") -}}
  {{- $region = $globalPg.awsRegion | toString -}}
{{- end -}}
{{- $region -}}
{{- end }}

{{/*
Resolve the OTel collector endpoint for control-plane components.
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
{{- if $globalColl.endpoint -}}{{- $endpoint = $globalColl.endpoint -}}{{- end -}}
{{- $endpoint -}}
{{- end }}

{{/*
envFrom entries: OTel ConfigMap (when endpoint resolved) + per-component
extraEnvFrom items.
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
  {{- range $extra -}}{{- $items = append $items . -}}{{- end -}}
{{- end -}}
{{- if $items -}}
envFrom:
{{ toYaml $items }}
{{- end -}}
{{- end }}
