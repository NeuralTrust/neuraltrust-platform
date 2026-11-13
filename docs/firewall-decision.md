# Firewall decision models and double checks

The in-cluster Firewall gateway can call a hosted decision model or a general
LLM. Configure it under `firewall.firewall.gateway.decision` in umbrella values.
The first `firewall` selects the subchart. Settings and credentials go only to
the gateway, not to the local model workers.

The chart pins Firewall v2.52.0. Keep the gateway and worker image versions
aligned when overriding them. The `google` decision provider requires v2.52.0
or later.

This requires `global.firewall.deploy: true` and the TrustGuard product enabled.
These values cannot configure the NeuralTrust-hosted Firewall or a Firewall
running outside this release. The default is disabled, with no
`DECISION_SERVICE_*` variables added by this configuration.

## Enable a decision model

Create a Secret in the release namespace containing the provider's API key.
For example, read a local credential file without putting the key in values:

```bash
kubectl create secret generic firewall-decision -n neuraltrust \
  --from-file=DECISION_SERVICE_API_KEY=/path/to/provider-api-key
```

Save the following as `firewall-decision-values.yaml` and include it alongside
your existing install values with `helm upgrade --install ... -f
firewall-decision-values.yaml`:

```yaml
global:
  products:
    trustguard: true
  firewall:
    deploy: true
firewall:
  firewall:
    gateway:
      decision:
        enabled: true
        provider: liquid
        model: d1
        doubleCheck: true
        apiKeyExistingSecret:
          name: firewall-decision
          key: DECISION_SERVICE_API_KEY
```

`enabled: true` configures `/v1/decision`, `/v1/decision/checks`, and
`/v1/decision/health`. `doubleCheck: true` also sends texts flagged by
`/v1/jailbreak`, `/v1/toxicity`, and `/v1/indirect-prompt-injections` for a second
opinion. `/v1/topic-guard` re-checks only blocked topics. Texts the local models
allow are never sent. The hosted verdict replaces the local score and decision,
and can clear a flag. Results include `double_check` metadata with the original
score and the backend model.

If the provider refuses the text, the local flag stays in place. A provider
timeout or other failed call fails the detector request with the decision
error, rather than returning an unchecked result. This adds latency and sends
flagged text to the selected provider. Allow gateway egress to that provider's
endpoint. The local workers still need to run.

Set `doubleCheck: false` to use the decision routes without changing detector
behavior. Helm rejects double checks with `enabled: false` and incomplete
provider credentials or required settings.

## Choose a provider

These names match the Firewall application's `DECISION_SERVICE_PROVIDER`
contract. System One providers supply probabilities. General LLMs return
verdicts that the gateway maps to fixed probabilities, so changing a threshold
between 0.01 and 0.99 does not tune an LLM's verdict.

| Provider | Backend | Configuration |
| --- | --- | --- |
| `typesafe` | System One | API key; default model `jev-latest` |
| `liquid` | System One | API key; model `d1`, default, or `d1-ultra` |
| `cloudflare` | System One | API key; `cloudflareAccountId` unless `url` is set; model `clef`, default, or `clef-flash` |
| `openai` | System One Decisions | API key; default model `gpt-6-luna` |
| `microsoft` | System One | API key or `auth: entra`; default model `Decision-1`; set `url` for your resource's full System One endpoint |
| `google` | Gemini Decision | API key; default model `gemini-decision-1` |
| `azure_foundry` | General LLM | `model` deployment and `url` resource endpoint; API key or `auth: entra` |
| `vertex` | General LLM | `model` and `project`; Google application default credentials, no API key; optional `location` |
| `gemini` | General LLM | API key and `model` |
| `openai_chat` | General LLM | API key and `model`; optional `url` base including `/v1` |
| `anthropic` | General LLM | API key and `model`; optional `url` base without `/v1` |

For a general LLM with an API key, keep the Secret reference above and replace
the provider settings, for example:

```yaml
firewall:
  firewall:
    gateway:
      decision:
        enabled: true
        doubleCheck: true
        provider: azure_foundry
        url: https://your-resource.openai.azure.com
        model: your-deployment-name
        timeoutSeconds: 30
        apiKeyExistingSecret:
          name: firewall-decision
```

An LLM can need a longer timeout than the default 5 seconds. For `azure_foundry`,
the gateway appends `/openai/v1/chat/completions` to the resource endpoint. For
`gemini` and `vertex`, `url` overrides the full `generateContent` endpoint.
For System One providers, it overrides the full decision endpoint.

## Authenticate with a cloud identity

For Microsoft or Azure AI Foundry, set `auth: entra` and omit
`apiKeyExistingSecret.name`. The gateway reuses `global.azureIdentity` for a
managed identity or a service principal, including its existing client-secret
reference. With AKS workload identity, it receives the pod label that triggers
the identity webhook. Annotate the Firewall ServiceAccount, or set
`global.azureIdentity.applyGlobally: true` to use the global client ID.

```yaml
global:
  azureIdentity:
    method: workload-identity
    clientId: your-managed-identity-client-id
    applyGlobally: true
firewall:
  firewall:
    gateway:
      decision:
        enabled: true
        doubleCheck: true
        provider: azure_foundry
        auth: entra
        url: https://your-resource.openai.azure.com
        model: your-deployment-name
        timeoutSeconds: 30
```

Configure the identity's federated credential for the release namespace and
Firewall ServiceAccount. The Microsoft System One backend uses the
`https://ai.azure.com/.default` scope and needs the Foundry User role. Azure AI
Foundry LLMs use `entraScope`, default
`https://cognitiveservices.azure.com/.default`, and need the Cognitive Services
OpenAI User role. The gateway uses `DefaultAzureCredential`, so a separately
configured pod identity also works without `global.azureIdentity`.

Vertex AI uses the pod's Google credentials. Omit the API-key Secret and set
`project` and `model`:

```yaml
global:
  gcpIdentity:
    method: workload-identity
    serviceAccount: firewall@your-project.iam.gserviceaccount.com
    applyGlobally: true
firewall:
  firewall:
    gateway:
      decision:
        enabled: true
        doubleCheck: true
        provider: vertex
        project: your-project
        location: global
        model: your-gemini-model
        timeoutSeconds: 30
```

Configure the GKE identity binding and grant the Google service account Vertex
AI User access to the project. For a per-service identity, use
`firewall.firewall.serviceAccount.annotations` instead of `applyGlobally`. To
use a pre-created Kubernetes ServiceAccount, set `serviceAccount.create: false`
and `serviceAccount.name` to that account.

## Values reference

All paths below are relative to `firewall.firewall.gateway.decision`.

| Value | Default | Gateway environment variable |
| --- | --- | --- |
| `enabled` | `false` | Helm switch for emitting the configuration |
| `doubleCheck` | `false` | `DECISION_SERVICE_DOUBLE_CHECK` |
| `provider` | `typesafe` | `DECISION_SERVICE_PROVIDER` |
| `model` | empty, provider default | `DECISION_SERVICE_MODEL` |
| `url` | empty, provider default | `DECISION_SERVICE_URL` |
| `auth` | `api_key` | `DECISION_SERVICE_AUTH` |
| `apiKeyExistingSecret.name` | empty | Secret supplying `DECISION_SERVICE_API_KEY` |
| `apiKeyExistingSecret.key` | `DECISION_SERVICE_API_KEY` | Key in that Secret |
| `cloudflareAccountId` | empty | `DECISION_SERVICE_CLOUDFLARE_ACCOUNT_ID` |
| `entraScope` | `https://cognitiveservices.azure.com/.default` | `DECISION_SERVICE_ENTRA_SCOPE`, Azure AI Foundry only |
| `project` | empty | `DECISION_SERVICE_PROJECT` |
| `location` | `global` | `DECISION_SERVICE_LOCATION` |
| `timeoutSeconds` | `5` | `DECISION_SERVICE_TIMEOUT_S` |
| `maxRetries` | `1` | `DECISION_SERVICE_MAX_RETRIES` |
| `retryBackoffSeconds` | `0.25` | `DECISION_SERVICE_RETRY_BACKOFF_S` |
| `healthCacheSeconds` | `30` | `DECISION_SERVICE_HEALTH_CACHE_S` |

Zero retries and zero backoff are preserved. Health checks to
`/v1/decision/health` call the provider and can incur charges; the gateway caches
the result for `healthCacheSeconds`. Kubernetes probes still use `/health`.

The API key stays in the referenced Secret and never enters a ConfigMap or a
chart-generated Secret. Secret changes require restarting the gateway, for
example `kubectl rollout restart deployment/firewall -n neuraltrust`.

Existing `gateway.extraEnv`, `gateway.extraEnvFrom`, and `config.extraEnv`
configuration continues to work with `decision.enabled: false`. When enabling
this block, remove the old `DECISION_SERVICE_*` settings from those locations
so this block owns the decision configuration. Helm rejects duplicate decision
variables in `gateway.extraEnv`. Do not put API keys in `config.extraEnv`, which
is a shared ConfigMap.
