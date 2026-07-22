{{- define "dataagent.serviceAccount" -}}
{{- if .Values.serviceAccount.create }}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "dataagent.serviceAccountName" . }}
  labels:
    {{- include "dataagent.labels" . | nindent 4 }}
  {{- $saAnn := include "neuraltrust-platform.serviceAccount.annotationsBlock" (dict "ctx" . "annotations" .Values.serviceAccount.annotations) }}
  {{- with $saAnn }}
  annotations:
    {{- . | nindent 4 }}
  {{- end }}
{{- end }}
{{- end }}
