{{/*
A pod or container securityContext with the chart's own fixed IDs removed on
OpenShift. restricted-v2 assigns runAsUser, runAsGroup and fsGroup from the
namespace's range and rejects any other value, so the chart default (defaultId)
is dropped there and the namespace-assigned IDs apply. A different value is
kept: an operator who set one chose it for an SCC that admits it. Renders YAML,
"{}" when nothing is left. Other platforms get the input unchanged.
Usage: {{- include "neuraltrust-platform.securityContext.openshift" (dict "ctx" . "sc" .Values.podSecurityContext "defaultId" 65532) | nindent 8 }}
*/}}
{{- define "neuraltrust-platform.securityContext.openshift" -}}
{{- $sc := deepCopy (default dict .sc) -}}
{{- if include "neuraltrust-platform.isOpenshift" .ctx -}}
{{- range $k := list "runAsUser" "runAsGroup" "fsGroup" -}}
{{- if and (hasKey $sc $k) (eq (toString (index $sc $k)) (toString $.defaultId)) -}}
{{- $_ := unset $sc $k -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- toYaml $sc -}}
{{- end }}
