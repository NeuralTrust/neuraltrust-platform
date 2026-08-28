{{- define "dataagent.egressService" -}}
{{- /* ClusterIP for TrustGate/TrustGuard → DataAgent OTLP sidecar.
     Name stays clickstack-egress-collector by default for stable OTEL URLs.
     Only the primary DataAgent instance owns this Service. */ -}}
{{- if .Values.egressPrimary }}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "neuraltrust-platform.clickstackEgress.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "dataagent.labels" . | nindent 4 }}
    app.kubernetes.io/component: clickstack-egress-collector
spec:
  type: ClusterIP
  {{- /* Keep the collector reachable when the dataagent container is unready.
         This Service selects the DataAgent pod, and Kubernetes marks a pod Ready
         only when EVERY container is, so a control-plane blip used to strip the
         endpoints of a perfectly healthy collector — turning a DataBridge outage
         into a local telemetry outage at the moment telemetry is most needed, and
         costing the collector its ability to buffer and retry (AUT-538).

         The root fix is DataAgent no longer failing readiness on a downed stream,
         but that needs an image release; this works on the chart alone and also
         covers any future readiness regression. Trade-off: endpoints are published
         while the collector itself is still starting, so a sender can get a refused
         connection instead of "no endpoints". Both are retryable, and the exporter
         now has a disk-backed sending_queue behind it. */}}
  publishNotReadyAddresses: true
  selector:
    {{- include "dataagent.selectorLabels" . | nindent 4 }}
    app.kubernetes.io/component: data-plane
  ports:
    - name: otlp-grpc
      port: 4317
      targetPort: otlp-grpc
      protocol: TCP
    - name: otlp-http
      port: 4318
      targetPort: otlp-http
      protocol: TCP
{{- end }}
{{- end }}
