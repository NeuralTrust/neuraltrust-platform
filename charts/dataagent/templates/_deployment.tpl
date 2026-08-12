{{- define "dataagent.deployment" -}}
{{- $img := include "dataagent.image" (dict "repository" .Values.image.repository "tag" .Values.image.tag "global" .Values.global) }}
{{- $egressEnabled := .Values.egressPrimary | default false }}
{{- $egressCfg := default dict (default dict (default dict .Values.global).clickstack).egress -}}
{{- $egressImg := default dict $egressCfg.image -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "dataagent.fullname" . }}
  labels:
    {{- include "dataagent.labels" . | nindent 4 }}
    app.kubernetes.io/component: data-plane
spec:
  replicas: {{ .Values.replicas }}
  strategy:
    type: Recreate
  selector:
    matchLabels:
      {{- include "dataagent.selectorLabels" . | nindent 6 }}
      app.kubernetes.io/component: data-plane
  template:
    metadata:
      labels:
        {{- include "dataagent.labels" . | nindent 8 }}
        app.kubernetes.io/component: data-plane
      annotations:
        {{- /* AUT-403: library chart templates are named defines, not BasePath files. */}}
        checksum/env-configmap: {{ include "dataagent.envConfigMap" . | sha256sum }}
        {{- $dataSecret := default dict .Values.existingSecret }}
        {{- $managedDataSecret := and (eq (include "neuraltrust-platform.autoGenerateSecrets" .) "true") (not .Values.global.preserveExistingSecrets) }}
        {{- if and (not $dataSecret.name) $managedDataSecret }}
        checksum/secrets: {{ include "dataagent.secrets" . | sha256sum }}
        {{- end }}
        {{- /* existingSecret is operator-owned — no chart content to checksum. */}}
        {{- if $egressEnabled }}
        checksum/egress-config: {{ include "dataagent.egressConfigmapData" . | sha256sum }}
        {{- end }}
    spec:
      serviceAccountName: {{ include "dataagent.serviceAccountName" . }}
      {{- include "dataagent.imagePullSecrets" . | nindent 6 }}
      {{- if .Values.securityHardening }}
      securityContext:
        seccompProfile:
          type: RuntimeDefault
      {{- end }}
      volumes:
      - name: tmp
        emptyDir: {}
      {{- if $egressEnabled }}
      - name: egress-config
        configMap:
          name: {{ include "neuraltrust-platform.clickstackEgress.fullname" . }}-config
      {{- with (include "neuraltrust-platform.clickstackEgress.tlsCaSecretName" .) }}
      - name: egress-ca-bundle
        secret:
          secretName: {{ . | quote }}
          items:
          - key: ca.crt
            path: ca.crt
      {{- end }}
      {{- end }}
      {{- include "neuraltrust-platform.customCaCert.volume" . | nindent 6 }}
      containers:
      - name: dataagent
        image: {{ $img | quote }}
        imagePullPolicy: {{ .Values.image.pullPolicy }}
        envFrom:
        - configMapRef:
            name: {{ include "dataagent.envConfigMapName" . }}
        {{- $dataSecret := default dict .Values.existingSecret }}
        {{- $managedDataSecret := and (eq (include "neuraltrust-platform.autoGenerateSecrets" .) "true") (not .Values.global.preserveExistingSecrets) }}
        {{- if or $dataSecret.name $managedDataSecret }}
        - secretRef:
            name: {{ include "dataagent.secretName" . | quote }}
        {{- end }}
        env:
        {{- if eq (include "neuraltrust-platform.isHybrid" .) "true" }}
        {{- /* Discrete POSTGRES_* parts (RUN-1093). DataAgent builds a libpq
               keyword connection string in-process, so the chart no longer
               composes SENSIBLE_PG_DSN. Requires a DataAgent image that reads
               these vars when DATABASE_URL is unset. */}}
        {{- $pgSecret := include "neuraltrust-platform.v2.hybridPg.secretName" . }}
        - name: POSTGRES_HOST
          valueFrom:
            secretKeyRef:
              name: {{ $pgSecret | quote }}
              key: POSTGRES_HOST
        - name: POSTGRES_PORT
          valueFrom:
            secretKeyRef:
              name: {{ $pgSecret | quote }}
              key: POSTGRES_PORT
        - name: POSTGRES_USER
          valueFrom:
            secretKeyRef:
              name: {{ $pgSecret | quote }}
              key: POSTGRES_USER
        - name: POSTGRES_DB
          valueFrom:
            secretKeyRef:
              name: {{ $pgSecret | quote }}
              key: POSTGRES_DB
        - name: POSTGRES_SSLMODE
          valueFrom:
            secretKeyRef:
              name: {{ $pgSecret | quote }}
              key: POSTGRES_SSLMODE
        {{- include "neuraltrust-platform.postgresql.passwordEnv" (dict "ctx" . "secret" $pgSecret) | nindent 8 }}
        {{- end }}
        {{- if $egressEnabled }}
        - name: OAUTH_BROKER_ADDR
          value: "127.0.0.1:9465"
        {{- end }}
        {{- $enrolmentExisting := default dict (default dict .Values.enrolment).existingSecret }}
        {{- with $enrolmentExisting.name }}
        - name: ENROLMENT_TOKEN
          valueFrom:
            secretKeyRef:
              name: {{ . | quote }}
              key: {{ $enrolmentExisting.key | default "ENROLMENT_TOKEN" | quote }}
        {{- end }}
        {{- with .Values.extraEnv }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
        {{- include "neuraltrust-platform.proxy-env" . | nindent 8 }}
        {{- include "neuraltrust-platform.customCaCert.env" (dict "runtime" "go" "ctx" .) | nindent 8 }}
        {{- include "neuraltrust-platform.appVersionEnv" (dict "tag" .Values.image.tag) | nindent 8 }}
        {{- if .Values.securityHardening }}
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: ["ALL"]
        {{- end }}
        ports:
        - containerPort: {{ .Values.ports.health }}
          name: health
        volumeMounts:
        - name: tmp
          mountPath: /tmp
        {{- include "neuraltrust-platform.customCaCert.volumeMount" . | nindent 8 }}
        resources:
          {{- toYaml .Values.resources | nindent 10 }}
        startupProbe:
          httpGet:
            path: /healthz
            port: health
          periodSeconds: 5
          failureThreshold: 30
        readinessProbe:
          httpGet:
            path: /readyz
            port: health
          initialDelaySeconds: 5
          periodSeconds: 10
        livenessProbe:
          httpGet:
            path: /healthz
            port: health
          initialDelaySeconds: 15
          periodSeconds: 20
      {{- if $egressEnabled }}
      - name: clickstack-egress-collector
        image: {{ include "neuraltrust-platform.clickstackEgress.image" . | quote }}
        imagePullPolicy: {{ default "IfNotPresent" $egressImg.pullPolicy }}
        args:
          - --config=/etc/otelcol/config.yaml
        {{- /* No SSL_CERT_FILE here on purpose. Go's crypto/x509 treats it as a
               REPLACEMENT for the system bundle, so setting it would also empty
               x509.SystemCertPool() and silently defeat the exporter's
               include_system_ca_certs_pool. The collector gets its private
               anchor declaratively via exporter tls.ca_file instead, so a chart
               CA and a publicly-terminated telemetry endpoint can both be
               trusted at once. */}}
        ports:
          - name: otlp-grpc
            containerPort: 4317
          - name: otlp-http
            containerPort: 4318
          - name: egress-health
            containerPort: 13133
        readinessProbe:
          httpGet:
            path: /
            port: egress-health
          initialDelaySeconds: 5
          periodSeconds: 10
        livenessProbe:
          httpGet:
            path: /
            port: egress-health
          initialDelaySeconds: 15
          periodSeconds: 20
        resources:
          {{- toYaml (default (dict "requests" (dict "cpu" "50m" "memory" "128Mi") "limits" (dict "cpu" "500m" "memory" "512Mi")) $egressCfg.resources) | nindent 10 }}
        volumeMounts:
          - name: egress-config
            mountPath: /etc/otelcol
            readOnly: true
          {{- with (include "neuraltrust-platform.clickstackEgress.tlsCaSecretName" .) }}
          - name: egress-ca-bundle
            mountPath: /etc/otelcol/ca
            readOnly: true
          {{- end }}
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: ["ALL"]
      {{- end }}
      {{- include "neuraltrust-platform.nodeSelector" (dict "ctx" . "local" .Values.nodeSelector) | nindent 6 }}
      {{- include "neuraltrust-platform.tolerations" (dict "ctx" . "local" .Values.tolerations) | nindent 6 }}
{{- end }}
