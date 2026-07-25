{{- define "dataagent.healthService" -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "dataagent.fullname" . }}
  labels:
    {{- include "dataagent.labels" . | nindent 4 }}
    app.kubernetes.io/component: data-plane
spec:
  type: ClusterIP
  selector:
    {{- include "dataagent.selectorLabels" . | nindent 4 }}
    app.kubernetes.io/component: data-plane
  ports:
    - name: health
      port: {{ .Values.ports.health }}
      targetPort: health
      protocol: TCP
{{- end }}
