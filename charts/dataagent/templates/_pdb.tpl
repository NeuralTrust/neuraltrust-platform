{{- define "dataagent.pdb" -}}
{{- if .Values.pdb.enabled }}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ include "dataagent.fullname" . }}
  labels:
    {{- include "dataagent.labels" . | nindent 4 }}
    app.kubernetes.io/component: data-plane
spec:
  minAvailable: {{ .Values.pdb.minAvailable }}
  selector:
    matchLabels:
      {{- include "dataagent.selectorLabels" . | nindent 6 }}
      app.kubernetes.io/component: data-plane
{{- end }}
{{- end }}
