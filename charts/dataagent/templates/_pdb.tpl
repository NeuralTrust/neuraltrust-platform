{{- define "dataagent.pdb" -}}
{{- $pdb := default dict .Values.pdb -}}
{{- $replicas := default 1 .Values.replicas -}}
{{- /*
Suppressed below 2 replicas. DataAgent is a single outbound stream, so the
default deployment is one pod, where any PDB pins disruptionsAllowed at 0 and
blocks every node drain in a customer cluster with no operator to diagnose it.
*/ -}}
{{- if and $pdb.enabled (gt ($replicas | int) 1) }}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ include "dataagent.fullname" . }}
  labels:
    {{- include "dataagent.labels" . | nindent 4 }}
    app.kubernetes.io/component: data-plane
spec:
  {{- if hasKey $pdb "maxUnavailable" }}
  maxUnavailable: {{ $pdb.maxUnavailable }}
  {{- else if hasKey $pdb "minAvailable" }}
  minAvailable: {{ $pdb.minAvailable }}
  {{- else }}
  maxUnavailable: 1
  {{- end }}
  selector:
    matchLabels:
      {{- include "dataagent.selectorLabels" . | nindent 6 }}
      app.kubernetes.io/component: data-plane
{{- end }}
{{- end }}
