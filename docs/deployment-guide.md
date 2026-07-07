# Headroom Gateway — Deployment Guide

Step-by-step guide to deploy the headroom context compression proxy on an
OpenShift cluster with MaaS already running.

## Prerequisites

Before deploying headroom, verify these MaaS components are up:

```bash
# 1. Logged into the cluster
oc whoami

# 2. MaaS gateway is running
oc get pods -n openshift-ingress | grep maas-default-gateway

# 3. IPP (payload-processing) is running
oc get deployment payload-processing -n openshift-ingress

# 4. Auth (Kuadrant) is configured
oc get authpolicy -A

# 5. At least one ExternalModel exists (shows what models are routed)
oc get externalmodel -A

# 6. MaaS API responds (expect 401 — that means auth is enforced)
curl -sk -o /dev/null -w "HTTP %{http_code}\n" \
  "https://maas.$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')/v1/messages" \
  -X POST -H "Content-Type: application/json" -d '{}'
```

**Optional but recommended:**
- GPU node with `nvidia.com/gpu` (speeds up Kompress ML from ~1s to ~134ms)
- Metering service + PostgreSQL (for usage tracking dashboard)

## Step 1: Find your MaaS URL

Headroom needs to know where MaaS is. The URL depends on how your cluster's
routing is configured:

```bash
# Get the cluster domain
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
echo "Cluster domain: $CLUSTER_DOMAIN"

# The MaaS URL is typically:
echo "https://maas.$CLUSTER_DOMAIN"

# Verify it responds
curl -sk -o /dev/null -w "HTTP %{http_code}\n" \
  "https://maas.$CLUSTER_DOMAIN/v1/messages" \
  -X POST -H "Content-Type: application/json" -d '{}'
# Expect: HTTP 401 (auth enforced) or HTTP 404 (model not found)
# If HTTP 000: MaaS is not reachable at this URL
```

If your MaaS uses a different URL pattern (e.g., path-based routing like
`/llm/ext-opus`), ask your MaaS admin for the correct base URL.

## Step 2: Clone and deploy

```bash
git clone https://github.com/yossiovadia/headroom-gateway.git
cd headroom-gateway

# Deploy (replace with your actual MaaS URL)
./scripts/deploy-proxy.sh \
  --maas-url https://maas.<cluster-domain> \
  --maas-openai-url https://maas.<cluster-domain>
```

The script will:
1. Check prerequisites (oc login, namespace, GPU nodes)
2. Build the headroom proxy image on-cluster (~5 min)
3. Create a PVC for persistent stats and CCR store
4. Deploy the proxy pod with GPU resource request
5. Create Service + Route (`headroom-service`)
6. Verify GPU provider is available
7. Run smoke tests

**Common flags:**
```bash
# Deploy to a specific namespace (default: openshift-ingress)
./scripts/deploy-proxy.sh -n my-namespace --maas-url ...

# Faster model download with HuggingFace token
./scripts/deploy-proxy.sh --hf-token hf_xxx --maas-url ...

# Force rebuild even if Dockerfile hasn't changed
./scripts/deploy-proxy.sh --force-build --maas-url ...
```

### Deploy without GPU

If no GPU nodes are available, the deploy script will fail at the preflight
check. To deploy without GPU:

1. Edit `scripts/deploy-proxy.sh`: remove the GPU preflight check and
   `nvidia.com/gpu: "1"` from the deployment YAML resource limits
2. Remove `HEADROOM_KOMPRESS_BACKEND=pytorch` from the deployment env vars
   (or set it to `onnx` explicitly)
3. Deploy as usual

Without GPU, all compression engines work the same except Kompress ML which
runs on CPU (~1s per compression instead of ~134ms). For a pilot with a few
users this is fine. JSON, logs, grep, diffs — the most common content types —
use CPU-only engines that run in <20ms regardless.

## Step 3: Verify the deployment

```bash
# Get the headroom URL
HEADROOM_URL="https://$(oc get route headroom-service -n openshift-ingress -o jsonpath='{.spec.host}')"
echo "Headroom URL: $HEADROOM_URL"

# Health check
curl -sk "$HEADROOM_URL/readyz" | python3 -m json.tool

# Check GPU (if deployed with GPU)
POD=$(oc get pods -n openshift-ingress -l app=headroom-proxy -o jsonpath='{.items[0].metadata.name}')
oc exec "$POD" -n openshift-ingress -- python3 -c "
import onnxruntime as ort
print('Providers:', ort.get_available_providers())
"
# Should include CUDAExecutionProvider if GPU is working

# End-to-end test (replace with a valid MaaS API key)
curl -sk "$HEADROOM_URL/v1/messages" \
  -H "x-api-key: <your-maas-key>" \
  -H "Content-Type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d '{"model":"claude-opus-4-8","max_tokens":10,"messages":[{"role":"user","content":"hi"}]}'
# Should return a model response (200 with JSON body)

# Check compression stats
curl -sk "$HEADROOM_URL/stats" | python3 -c "
import json,sys
d = json.load(sys.stdin)
print(f'Requests: {d[\"requests\"][\"total\"]}')
print(f'Tokens saved: {d[\"tokens\"][\"saved\"]}')
"

# Dashboard
echo "Dashboard: $HEADROOM_URL/dashboard"
```

## Step 4: Point users at headroom

Users change one environment variable. Everything else (API key, model names)
stays the same.

### Claude Code

```bash
export ANTHROPIC_BASE_URL="https://headroom-service-<namespace>.apps.<cluster-domain>"
export ANTHROPIC_API_KEY="<maas-api-key>"
export NODE_TLS_REJECT_UNAUTHORIZED=0  # sandbox only — production uses a trusted cert
claude --model claude-opus-4-8
```

Note: no `/v1` suffix — Claude Code appends it automatically.

### Codex

```toml
# ~/.codex/config.toml
model = "gpt-5.5"
model_provider = "maas"

[model_providers.maas]
name = "MaaS Gateway"
base_url = "https://headroom-service-<namespace>.apps.<cluster-domain>/v1"
wire_api = "responses"
env_key = "MAAS_API_KEY"
```

```bash
export MAAS_API_KEY="<maas-api-key>"
export NODE_TLS_REJECT_UNAUTHORIZED=0  # sandbox only
codex
```

Note: Codex needs `/v1` in the base_url.

### Available models

The models available through headroom are the same models configured in MaaS
as ExternalModel CRDs. Check with:

```bash
oc get externalmodel -A -o custom-columns='NAME:.metadata.name,MODEL:.spec.modelName'
```

## Step 5: Verify metering still works

Headroom is transparent to metering — MaaS still records usage events because
the request flows through the IPP pipeline after headroom.

```bash
# Check metering database for recent events
PG_POD=$(oc get pods -n openshift-ingress -l app=metering-postgresql -o jsonpath='{.items[0].metadata.name}')
oc exec "$PG_POD" -n openshift-ingress -- psql -U postgres -d metering -c "
SELECT timestamp, model, username, prompt_tokens, completion_tokens
FROM usage_events
ORDER BY timestamp DESC
LIMIT 5;"
```

If metering events are missing for OpenAI Responses API (Codex), see
[PR #332](https://github.com/opendatahub-io/ai-gateway-payload-processing/pull/332)
— the metering plugin needs the `parsed["response"]["usage"]` extraction path.

## Emergency controls

### Bypass headroom (per user)

Users change one env var to skip headroom and go directly to MaaS:

```bash
# Claude Code
export ANTHROPIC_BASE_URL="https://maas.<cluster-domain>"

# Codex — edit ~/.codex/config.toml
base_url = "https://maas.<cluster-domain>/v1"
```

No deployment changes needed. Compression stops, everything else works.

### Scale to zero

```bash
oc scale deployment/headroom-proxy -n openshift-ingress --replicas=0
```

### Full rollback

```bash
# Delete headroom resources (does not affect MaaS)
oc delete deployment headroom-proxy -n openshift-ingress
oc delete service headroom-service -n openshift-ingress
oc delete route headroom-service -n openshift-ingress
oc delete pvc headroom-proxy-data -n openshift-ingress  # deletes stats + CCR store
```

## Troubleshooting

### "API error · Retrying" in Claude Code / Codex

Check headroom stats for error breakdown:
```bash
curl -sk "$HEADROOM_URL/stats" | python3 -c "
import json,sys
d = json.load(sys.stdin)
print('By status:', json.dumps(d['proxy_inbound']['by_status']))
print('Failed (headroom-side):', d['requests']['failed'])
"
```

- **400** — request body parse error (see [#209](https://github.com/llm-d/llm-d-inference-payload-processor/issues/209))
- **502** — headroom can't reach MaaS (check `ANTHROPIC_TARGET_API_URL` env var)
- **500** — upstream provider error (OpenAI/Anthropic flakiness, auto-retried)
- **503** — timeout (large request + slow compression on CPU → consider GPU)

### Kompress ML is slow (~3s)

Kompress is running on CPU. Set `HEADROOM_KOMPRESS_BACKEND=pytorch` and add
`nvidia.com/gpu: "1"` to the deployment. First request after restart takes
~3.5s (model load to GPU), then ~134ms.

### Headroom dashboard shows no compression

First few requests in a new session won't compress — headroom protects fresh
content. Compression kicks in after tool outputs become "stale" (older than
`HEADROOM_STALE_READ_COMPRESS_AFTER_TURNS` turns, default 1). Keep using the
client for a multi-turn session and savings will appear.

### GPU shows 0MiB used

The Kompress model loads lazily on first compression request. Send a request
with enough content to trigger compression (not just "hi"), then check
`nvidia-smi` again.
