# Template Fixes Required

The subchart templates access `.Values.controlPlane.*` and `.Values.dataPlane.*` without defensive checks. Since these values are provided at the root level of the parent chart's values.yaml, they should be available, but the templates need defensive checks to handle cases where values might be missing.

## Fixed Templates

1. ✅ `charts/neuraltrust-control-plane/templates/_helpers.tpl` - Fixed `preserveExistingSecrets` checks
2. ✅ `charts/neuraltrust-control-plane/templates/app/service.yaml` - Fixed `ingress.enabled` check
3. ✅ `charts/neuraltrust-control-plane/templates/app/deployment.yaml` - Fixed `replicaCount` and `imagePullSecrets` checks
4. ✅ `charts/neuraltrust-data-plane/templates/trusttest-configmap.yaml` - Fixed `trustTestConfig` check

## Remaining Fixes Needed

The following templates still need defensive checks added:

### control-plane/app/deployment.yaml
- Line 31-32: `image.repository`, `image.tag`, `image.pullPolicy`
- Line 113-114: `image.repository`, `image.tag`, `image.pullPolicy` (main container)
- Line 116: `config.port`
- Line 119: `config.nodeEnv`
- Line 121: `config.port`
- Line 177: `host`
- Line 189: `config.openaiModel`
- Line 191-233: Various `config.*` values
- Line 260-262: `config.kafkaHost`, `config.kafkaPort`
- Line 264: `resources`

### Other Templates
- `control-plane/api/deployment.yaml`
- `control-plane/scheduler/deployment.yaml`
- `control-plane/postgresql/*.yaml`

## Solution

The root-level `controlPlane` and `dataPlane` structures in values.yaml should provide all necessary values. The templates need defensive checks like:

```yaml
{{- if and .Values.controlPlane .Values.controlPlane.components .Values.controlPlane.components.app .Values.controlPlane.components.app.image .Values.controlPlane.components.app.image.repository }}
  image: "{{ .Values.controlPlane.components.app.image.repository }}:{{ .Values.controlPlane.components.app.image.tag }}"
{{- else }}
  image: "default-image:latest"
{{- end }}
```

Or use variables with defaults:

```yaml
{{- $imageRepo := "default-repo" }}
{{- if and .Values.controlPlane .Values.controlPlane.components .Values.controlPlane.components.app .Values.controlPlane.components.app.image .Values.controlPlane.components.app.image.repository }}
  {{- $imageRepo = .Values.controlPlane.components.app.image.repository }}
{{- end }}
image: "{{ $imageRepo }}:{{ $imageTag }}"
```

## Quick Fix

For now, ensure all required values are present in the root-level `controlPlane` and `dataPlane` sections of values.yaml, which they are. The templates should work once all defensive checks are added.

