# Headroom Gateway — Architecture

## Problem

LLM coding agents (Claude Code, Codex, Copilot) generate massive context through
tool calls — file reads, build logs, API responses, search results. A typical
coding session reaches 150K+ tokens, of which **80% is tool output**. Every request
sends the full conversation history. Token costs scale linearly.

[Headroom](https://github.com/headroomlabs-ai/headroom) (Apache 2.0, 28k+ stars)
compresses old tool outputs by 50-70% with zero quality loss. It runs as a
transparent proxy — intercepting LLM API requests, compressing the conversation
history, and forwarding the optimized payload upstream.

**Goal**: Deploy headroom as a centralized proxy on OpenShift so all users get
compression automatically. No client-side installation. Integrated with MaaS auth,
metering, and per-model pricing.

## Compression Results

From production deployment on OpenShift:

| Content Type | Savings | Engine | Latency |
|---|---|---|---|
| Build logs, grep output | **65-80%** | LogCompressor / SearchCompressor | <20ms |
| JSON arrays (K8s pods, API responses) | **60-74%** | SmartCrusher (Rust) | <15ms |
| Git diffs | **40-60%** | DiffCompressor | <15ms |
| Free text (docs, meeting notes) | **10-35%** | Kompress ML (ModernBERT + PyTorch) | ~134ms GPU |
| Code editing sessions (mixed) | **5-15%** | Kompress ML (most content is excluded) | ~134ms GPU |
| Error logs, stack traces | **0%** (protected) | — | — |

## Architecture (Option A — Transparent Proxy)

Headroom runs as a transparent proxy **before** MaaS. Users point at headroom
instead of MaaS directly. Headroom compresses the request, forwards to MaaS,
and returns the response unmodified.

```
Client (Claude Code / Codex / Cursor)
  │
  ▼
Headroom Proxy (this repo)
  ├─ Parse conversation history
  ├─ Identify stale/compressible tool outputs
  ├─ Compress via ContentRouter (SmartCrusher, LogCompressor, Kompress ML, etc.)
  ├─ Store originals in CCR (SQLite on PVC)
  ├─ Inject headroom_retrieve tool for CCR retrieval
  ├─ Track compression stats + savings
  │
  ▼
MaaS Gateway (Envoy + Istio)
  ├─ Kuadrant: API key validation, user identification
  ├─ ext_proc (payload-processing / IPP):
  │   ├─ model-extractor: model → X-Gateway-Model-Name
  │   ├─ metering: token usage tracking
  │   ├─ model-provider-resolver: resolve ExternalModel → provider
  │   ├─ api-translation: format passthrough
  │   └─ apikey-injection: inject provider API key
  │
  ▼
Provider (api.anthropic.com / api.openai.com)
```

### Why Option A (Proxy) Over Option E (IPP Plugin)

We initially built Option E — an IPP plugin that called a custom Python service
wrapping headroom's `compress()` function. We migrated to Option A because:

1. **CCR (Compress-Cache-Retrieve)** — headroom's retrieval system stores originals
   and lets the LLM retrieve them mid-conversation. Only works when headroom
   controls the full request/response lifecycle (proxy mode), not as a library call.

2. **No IPP rebuild needed** — headroom deploys independently. Updates to compression
   don't require rebuilding the payload-processing image.

3. **Built-in dashboard, stats, session tracking** — headroom proxy ships these
   natively. Option E required custom Python service code (~400 lines) reimplementing
   features headroom already had.

4. **Image compression, MCP tools, output shaping** — proxy-only features we get
   for free.

The old Option E architecture doc is preserved at `docs/architecture-option-e.md`.

### User Setup

Users change one environment variable to route through headroom:

**Claude Code:**
```bash
export ANTHROPIC_BASE_URL=https://headroom-service-<namespace>.apps.<cluster-domain>
export ANTHROPIC_API_KEY=<MaaS-key>       # same key as before
export NODE_TLS_REJECT_UNAUTHORIZED=0
claude --model claude-opus-4-8
```

**Codex:**
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
export MAAS_API_KEY=<MaaS-key>
export NODE_TLS_REJECT_UNAUTHORIZED=0
codex
```

**Bypass headroom (direct to MaaS):**
```bash
# Claude Code
export ANTHROPIC_BASE_URL=https://maas.<cluster-domain>

# Codex — change base_url in config.toml
base_url = "https://maas.<cluster-domain>/v1"
```

No deployment changes needed to bypass. Per-user choice.

### Request Flow

1. Client sends request to headroom proxy (same API format as the provider)
2. Headroom parses conversation history, identifies compressible content:
   - User/system messages → **protected** (never compressed)
   - Fresh tool outputs (recent turns) → **protected**
   - Stale tool outputs (older turns) → **compressed** via ContentRouter
   - Error outputs with stack traces → **protected**
3. ContentRouter auto-detects content type and routes to the best compressor
4. Compressed request forwarded to MaaS with `x-headroom-tokens-*` response headers
5. MaaS applies auth, metering, model resolution, API key injection
6. Request reaches provider, response flows back through MaaS → headroom → client
7. If the LLM calls `headroom_retrieve` (CCR), headroom intercepts the tool call,
   retrieves the original from SQLite, sends a continuation request, and returns
   the final response transparently

### Compression Pipeline (headroom internals)

```
Tool output content
  │
  ContentRouter (auto-detect)
  │
  ├─ JSON array? ──────── SmartCrusher (Rust, instant)
  │                       Deduplicates structure, keeps anomalies
  │
  ├─ Log/grep output? ── LogCompressor / SearchCompressor (instant)
  │                       Keeps errors + timestamps, deduplicates lines
  │
  ├─ Git diff? ────────── DiffCompressor (instant)
  │                       Keeps hunks, deduplicates similar changes
  │
  ├─ HTML? ────────────── HTMLExtractor (instant)
  │                       Strips tags, extracts meaningful text
  │
  └─ Free text? ───────── Kompress ML (GPU, ~134ms)
                          ModernBERT tokenizer + PyTorch ONNX model
                          Scores token importance, removes low-value tokens
```

### Content Protection

| Content | Action | Reason |
|---------|--------|--------|
| User messages | Protected | Model needs exact user input |
| System prompts | Protected | Cache-hot instruction bytes |
| Fresh Read/tool outputs | Excluded | Exact content needed for code editing |
| Write/Edit tool outputs | Excluded | Mutation records must stay exact |
| Error outputs | Protected | Tracebacks preserved for debugging |
| Recent tool outputs | Protected | Last N turns kept verbatim |
| Stale Read outputs | Compressed | File was edited after reading — content is stale |
| Superseded Read outputs | Compressed | File was re-read later — content is redundant |

### CCR (Compress-Cache-Retrieve)

When headroom compresses content, it stores the original in a SQLite database on
the PVC. A retrieval hash is embedded in the compressed output. If the LLM needs
the full original (e.g., to answer a question requiring exact details), it calls
the `headroom_retrieve` tool with the hash. Headroom intercepts this tool call in
the response, looks up the hash, sends a continuation request with the original
content, and returns the final answer to the user. The round-trip is transparent.

### GPU Acceleration

Kompress ML uses a ModernBERT model for token importance scoring. By default
headroom uses the ONNX CPU backend. Setting `HEADROOM_KOMPRESS_BACKEND=pytorch`
enables PyTorch with automatic CUDA detection.

| | CPU (ONNX) | GPU (PyTorch + CUDA) |
|---|---|---|
| Kompress latency | ~1,000ms | ~134ms |
| GPU memory | 0 | ~1GB |
| First request | instant | ~3.5s (model load) |

The GPU model loads on the first compression request and stays resident. After pod
restart, the next Kompress-triggering request takes ~3.5s (cold start), then
sub-200ms from there.

## Deployment

### Prerequisites (deployed by MaaS platform team)

| Component | Purpose | Verify |
|---|---|---|
| OpenShift cluster | Infrastructure | `oc whoami` |
| Istio / Envoy gateway | Traffic routing, TLS | Gateway pods running |
| Kuadrant | API key validation, auth | `oc get authpolicy -A` |
| MaaS controller + maas-api | API key management | `oc get pods -n opendatahub` |
| IPP / payload-processing | Plugin chain (metering, api-translation, apikey-injection) | `oc get deployment payload-processing` |
| Metering service + Postgres | Usage tracking, model pricing | `oc get statefulset metering-postgresql` |

Headroom does NOT require any IPP plugin or ConfigMap changes.

### Deploy

```bash
./scripts/deploy-proxy.sh \
  --maas-url https://maas.<cluster-domain> \
  --maas-openai-url https://maas.<cluster-domain>
```

The script:
1. Preflight checks (oc login, namespace, GPU nodes, MaaS reachability)
2. Builds the headroom proxy image on-cluster (CUDA base + headroom-ai + models)
3. Creates a PVC for persistent stats and CCR store
4. Deploys the proxy with GPU resource request (`nvidia.com/gpu: 1`)
5. Creates Service + Route (named `headroom-service`)
6. Verifies GPU (`CUDAExecutionProvider` available)
7. Runs smoke tests

### What Gets Deployed

```
headroom-proxy (Deployment)
  ├── image: headroom proxy with GPU + PyTorch
  ├── port: 8787
  ├── env:
  │   ├── ANTHROPIC_TARGET_API_URL → MaaS base URL
  │   ├── OPENAI_TARGET_API_URL → MaaS base URL
  │   ├── HEADROOM_KOMPRESS_BACKEND=pytorch (GPU)
  │   ├── HEADROOM_CCR_BACKEND=sqlite
  │   ├── HEADROOM_MODE=token
  │   └── HEADROOM_COMPRESSION_STABLE_AFTER_TURN=1
  ├── resources: 4-8 CPU, 4-8Gi RAM, 1x nvidia.com/gpu
  ├── strategy: Recreate (single GPU node constraint)
  └── volume: PVC at /opt/app/.headroom (savings + CCR store)

headroom-service (Service)
  └── ClusterIP port 8787 → app: headroom-proxy

headroom-service (Route)
  └── TLS edge → https://headroom-service-<namespace>.apps.<cluster>
```

### Persistent Data (PVC)

Survives pod restarts and redeployments:
- `/opt/app/.headroom/proxy_savings.json` — lifetime compression stats
- `/opt/app/.headroom/ccr_store.db` — CCR originals (SQLite)

In-memory (resets on restart):
- Session compression cache (per-user deduplication)
- Current session stats (flushed to lifetime on activity)
- Rate limiter state
- GPU-resident Kompress model (reloads on first request, ~3.5s)

## Capacity

Single pod with 1x NVIDIA L4 GPU:

| Metric | Value |
|---|---|
| Concurrent compressions | 8 (configurable) |
| Kompress ML latency (GPU) | ~134ms avg |
| Pipeline overhead | ~150-400ms avg |
| Estimated concurrent users | 50-100 comfortable, bursts to 200+ |
| GPU memory used | ~1GB of 23GB |

To scale beyond: add replicas (needs RWX PVC or disable CCR) or run without
GPU (CPU-only, higher Kompress latency).

## Emergency Controls

**Bypass headroom** — users change one env var:
```bash
export ANTHROPIC_BASE_URL=https://maas.<cluster-domain>
```

**Scale to zero:**
```bash
oc scale deployment/headroom-proxy --replicas=0
```

## Endpoints

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/v1/messages` | POST | Anthropic Messages API (compressed + forwarded) |
| `/v1/responses` | POST | OpenAI Responses API (compressed + forwarded) |
| `/v1/chat/completions` | POST | OpenAI Chat API (compressed + forwarded) |
| `/v1/compress` | POST | Standalone compression (no upstream forward) |
| `/v1/retrieve/stats` | GET | CCR store stats |
| `/stats` | GET | Compression stats for dashboard |
| `/stats-history` | GET | Lifetime stats with history |
| `/dashboard` | GET | Built-in headroom dashboard |
| `/readyz` | GET | Readiness probe |
| `/health` | GET | Liveness + runtime details |
| `/metrics` | GET | Prometheus counters |

## Related Repos

| Repo | Purpose |
|------|---------|
| [headroom](https://github.com/headroomlabs-ai/headroom) | Upstream compression library (Apache 2.0) |
| [ai-gateway-payload-processing](https://github.com/opendatahub-io/ai-gateway-payload-processing) | IPP ext_proc plugins (metering, model resolution, API translation) |
| [models-as-a-service](https://github.com/opendatahub-io/models-as-a-service) | MaaS controller, API key management, EnvoyFilter config |
| [llm-d-inference-payload-processor](https://github.com/llm-d/llm-d-inference-payload-processor) | ext_proc framework (body parsing, plugin interface) |
