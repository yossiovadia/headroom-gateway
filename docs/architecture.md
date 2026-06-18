# Headroom Gateway — Architecture Design Doc

## Problem

LLM coding agents (Claude Code, Codex, Copilot) generate massive context through
tool calls — file reads, build logs, API responses, search results. A typical
coding session reaches 150K+ tokens, of which **80% is tool output**. Every request
sends the full conversation history. Token costs scale linearly.

Headroom (28k stars, https://github.com/chopratejas/headroom) compresses old tool
outputs by 50-70% with zero quality loss. But it runs as a local proxy — each user
installs it individually.

**Goal**: Deploy headroom centrally on OpenShift so all users get compression
automatically. No client-side installation. Support multiple LLM tools and providers.

## What Headroom Supports

### Tools / Clients
| Tool | API Format | Headroom Support |
|------|-----------|-----------------|
| Claude Code | Anthropic Messages (`/v1/messages`) | Native — primary use case |
| OpenAI Codex | OpenAI Responses (`/v1/responses`) | Native — supported |
| ChatGPT / OpenAI apps | OpenAI Chat (`/v1/chat/completions`) | Native — supported |
| Cursor, Continue | OpenAI Chat | Native — same path |

### Backend Providers
| Provider | Headroom Support | Compression |
|----------|-----------------|-------------|
| Anthropic direct | Native | YES — full compression pipeline |
| OpenAI direct | Native | YES — full compression pipeline |
| Vertex AI (Google) | Via LiteLLM | NO — LiteLLM bypasses compression |
| AWS Bedrock | Via LiteLLM | NO — same LiteLLM limitation |
| Azure OpenAI | Via LiteLLM | NO — same limitation |

**Key limitation**: Compression only works when headroom uses its native Anthropic
or OpenAI handlers. LiteLLM-backed providers (Vertex, Bedrock, Azure) bypass the
compression pipeline entirely. This is a headroom architectural issue.

## Proven Compression Results

| Content Type | Savings | Method |
|---|---|---|
| Search/RAG results (50 docs) | **61.5%** | smart_crusher (instant) |
| K8s API responses (30 pods) | **70.3%** | smart_crusher (instant) |
| Log output (50 lines) | **65%** | Kompress ML (~3s CPU, <100ms GPU) |
| Real Claude A/B test | **54.9%** | Zero quality loss proven |

Cost impact at $15/M input tokens (Opus): ~$31K saved per 1M requests.

---

## Architecture Options

### Option A: Headroom Before MaaS

```
                    ┌──────────────┐     ┌──────────────┐     ┌──────────┐
Users ──────────────│  Headroom    │────▶│  MaaS/BBR    │────▶│ Provider │
(Claude Code,       │  Gateway     │     │  Gateway     │     │ (Anthro- │
 Codex, etc.)       │              │     │              │     │  pic,    │
                    │ • Compress   │     │ • Auth       │     │  OpenAI) │
                    │ • Multi-prov │     │ • Metering   │     └──────────┘
                    │ • Per-user   │     │ • Rate limit │
                    │   stats      │     │ • API key    │
                    │ • Dashboard  │     │   injection  │
                    └──────────────┘     └──────────────┘
```

**User config:**
```bash
ANTHROPIC_BASE_URL=https://headroom.company.com
ANTHROPIC_API_KEY=<MaaS-key>    # passes through headroom to MaaS
```

**How it works:**
1. User sends request to headroom with MaaS API key
2. Headroom compresses old tool outputs (session-aware)
3. Headroom forwards to MaaS gateway (compressed request + MaaS key)
4. MaaS validates key, identifies user, meters COMPRESSED tokens, injects real provider key
5. Request goes to Anthropic/OpenAI

**Pros:**
- Headroom runs in native proxy mode — session-aware compression, no hacks
- MaaS sees compressed tokens — metering reflects actual cost savings
- Multi-provider: headroom routes by API format (Anthropic, OpenAI, etc.)
- Users only need one URL change
- Headroom and MaaS are fully independent services — different teams, different repos

**Cons:**
- MaaS key passes through headroom (headroom sees it but doesn't use it)
- Headroom can't identify users (MaaS key is opaque) — per-user stats need x-headroom-user-id header
- Extra network hop (user → headroom → MaaS → provider)
- If headroom is down, users can't reach MaaS (unless failover configured)

**Format compatibility — solved by PR #301 (merged):**
PR #301 adds passthrough mode to MaaS — when the client's API format matches the
provider's format, MaaS skips translation entirely. This means:
- Claude Code sends `/v1/messages` → headroom compresses → MaaS passes through → Anthropic
- Codex sends `/v1/responses` → headroom compresses → MaaS passes through → OpenAI
- Any OpenAI-compatible tool sends `/v1/chat/completions` → same flow

On sandbox659, body-based model resolution means a single URL per provider handles
all models. Headroom sets `ANTHROPIC_TARGET_API_URL=https://maas.../llm/ext-opus`
and all Anthropic models (Opus, Sonnet, Haiku) work through one route. Users switch
models in the request body — no URL changes needed.

---

### Option B: Headroom After MaaS

```
                    ┌──────────────┐     ┌──────────────┐     ┌──────────┐
Users ──────────────│  MaaS/BBR    │────▶│  Headroom    │────▶│ Provider │
(Claude Code,       │  Gateway     │     │  Gateway     │     │ (Anthro- │
 Codex, etc.)       │              │     │              │     │  pic,    │
                    │ • Auth       │     │ • Compress   │     │  OpenAI) │
                    │ • Metering   │     │ • Per-user   │     └──────────┘
                    │ • User ID    │     │   stats      │
                    │ • Rate limit │     │ • Dashboard  │
                    │ • API key    │     │              │
                    │   injection  │     └──────────────┘
                    └──────────────┘
```

**User config:**
```bash
ANTHROPIC_BASE_URL=https://maas.company.com/llm/ext-claude-headroom
ANTHROPIC_API_KEY=<MaaS-key>
```

**How it works:**
1. User sends request to MaaS with MaaS API key
2. MaaS validates key, identifies user, injects x-maas-username header
3. MaaS translates format, injects real provider API key
4. MaaS forwards to headroom (instead of directly to provider)
5. Headroom compresses, reads x-maas-username for per-user tracking
6. Headroom forwards to Anthropic/OpenAI with real provider key

**Pros:**
- MaaS handles auth first — headroom never sees MaaS keys or user credentials
- Per-user tracking works via x-maas-username header (injected by MaaS)
- Users point at MaaS (familiar) — just different path (/ext-claude-headroom)
- MaaS can meter ORIGINAL tokens (pre-compression) for billing accuracy

**Cons:**
- MaaS meters ORIGINAL tokens, not compressed — cost reports don't reflect savings
  (need separate headroom dashboard for savings visibility)
- Routing complexity: MaaS ext-proc modifies headers before Envoy routing, causing
  the wrong HTTPRoute to match. This is the blocker we hit — needs Envoy routing fix.
- Headroom receives post-translation request (already in Anthropic format with
  real API key) — session tracking might not work correctly since MaaS modifies
  the request format and headers
- MaaS and headroom are coupled — changes to MaaS routing affect headroom

**Known blocker:** Envoy ext-proc runs BEFORE the router. When BBR sets
X-Gateway-Model-Name header, the router matches the wrong HTTPRoute rule (ext-claude-sonnet
instead of ext-claude-headroom). Traffic goes to Anthropic directly, bypassing headroom.
This needs either Noy's help with the Envoy config or a different routing approach.

---

### Option C: Headroom Standalone (No MaaS)

```
                    ┌──────────────┐     ┌──────────┐
Users ──────────────│  Headroom    │────▶│ Provider │
(Claude Code,       │  Gateway     │     │ (Anthro- │
 Codex, etc.)       │              │     │  pic,    │
                    │ • Compress   │     │  OpenAI) │
                    │ • Per-user   │     └──────────┘
                    │   stats      │
                    │ • Dashboard  │
                    │ • Prometheus │
                    └──────────────┘
```

**User config:**
```bash
ANTHROPIC_BASE_URL=https://headroom.company.com
ANTHROPIC_API_KEY=<user's-own-key or shared-org-key>
```

**How it works:**
1. User sends request to headroom with API key (own or shared)
2. Headroom compresses old tool outputs
3. Headroom forwards to provider with the same key
4. Per-user tracking via x-headroom-user-id header or API key differentiation

**Pros:**
- Simplest deployment — one service, no MaaS dependency
- No routing complexity — headroom is a standard HTTP proxy
- Works today — proven on sandbox311
- Multi-provider out of the box (Anthropic, OpenAI)
- Fastest path to pilot

**Cons:**
- No centralized auth/key management (users bring own keys or share one)
- No metering integration — headroom's built-in Prometheus metrics are the only observability
- No rate limiting beyond headroom's built-in (basic)
- If org wants centralized billing/audit, needs separate solution

---

### Option D: BBR Plugin + Headroom Sidecar (Like Guardrails)

```
                    ┌─────────────────────────────────────────┐
                    │           MaaS/BBR Pod                  │
                    │                                         │
Users ──────────────│  ┌──────────────┐   ┌──────────────┐   │──▶ Provider
(Claude Code,       │  │  BBR ext-proc │   │  Headroom    │   │   (Anthropic,
 Codex, etc.)       │  │              │──▶│  Sidecar     │   │    OpenAI)
                    │  │ • Auth       │   │              │   │
                    │  │ • Metering   │   │ • Compress   │   │
                    │  │ • Headroom   │   │   /v1/       │   │
                    │  │   plugin     │   │   compress-  │   │
                    │  │ • API trans  │   │   raw        │   │
                    │  │ • Key inject │   │ • Kompress   │   │
                    │  └──────────────┘   │   ML model   │   │
                    │                     └──────────────┘   │
                    └─────────────────────────────────────────┘
```

**User config:** Same as MaaS today — no change.
```bash
ANTHROPIC_BASE_URL=https://maas.company.com/llm/ext-claude-sonnet
ANTHROPIC_API_KEY=<MaaS-key>
```

**How it works:**
1. User sends request to MaaS (exactly as today)
2. BBR metering plugin checks entitlement, identifies user
3. BBR headroom plugin walks the messages array:
   - Counts turns backwards from the end
   - Finds `role: "tool"` messages older than N turns (default 2)
   - Extracts content > 500 chars
   - Sends text blocks to sidecar `POST localhost:8788/v1/compress-raw`
   - Replaces tool content with compressed versions
4. BBR api-translation, apikey-injection run as normal
5. Compressed request goes to provider

**Same pattern as NeMo guardrails:**
The NeMo guardrails plugin calls a NeMo sidecar over HTTP to check
content. The headroom plugin calls a headroom sidecar to compress content.
Same architecture — different purpose.

**Pros:**
- **Zero routing complexity** — sidecar is localhost, same pod, no Envoy routing issues
- **Zero user changes** — same MaaS URL, same key, no new endpoints
- **MaaS handles everything** — auth, metering, per-user tracking, rate limiting
- **No new services** — headroom is a container in the existing pod, not a separate Deployment
- **Proven** — we built and tested this, 53% savings e2e through the full pipeline
- **Per-user tracking** — metering plugin already has user identity (x-maas-username)
- Selection logic is explicit in Go — configurable (protectRecentTurns, minCompressChars)

**Cons:**
- **Not using headroom as designed** — headroom is a proxy. This approach uses it as a
  compression API, requiring a custom `/v1/compress-raw` endpoint because the native
  `/v1/compress` API doesn't work for stateless calls
- **Custom code to maintain** — Go plugin (~80 lines) + Python sidecar (~30 lines)
  that replicate headroom's session-aware intelligence with a simpler turn-counting heuristic
- **Heavy sidecar per pod** — 4Gi memory + 4 CPU (or GPU) for Kompress ML inference.
  Scales with BBR replicas (3 replicas = 3 ML models loaded)
- **Coupling** — headroom updates require BBR pod restarts. Compression and auth/metering
  share the same scaling and lifecycle
- **Buffering** — ext-proc buffers the full request body. Sidecar call adds ~200-500ms
  (CPU) or <100ms (GPU) while the body is held in Envoy memory
- **Latency** — sidecar call adds to the request processing time before the LLM call
  even starts. On CPU this is ~3s for large tool outputs

**Smart content selection in the Go plugin:**

The plugin doesn't blindly send everything to the sidecar. It detects what's
worth compressing and skips the rest — reducing sidecar calls and latency.

| Content Type | Compresses? | Detection | Action |
|---|---|---|---|
| JSON arrays (API/search results) | **61-70%** | Starts with `[` or `{` with nested arrays | SEND to sidecar |
| Log output (structured, repetitive) | **65%** | Timestamp patterns, repeated line structure | SEND to sidecar |
| Code files (read via tool) | **53%** | Indentation, language keywords, function defs | SEND to sidecar |
| Plain text (short answers) | 0% | Short, no structure, < 500 chars | SKIP |
| Error messages / stack traces | 0% | `panic:`, `Error:`, `Traceback`, stack frames | SKIP |
| Small tool outputs | 0% | Below `minCompressChars` threshold | SKIP |
| Recent tool outputs | N/A | Within last `protectRecentTurns` turns | SKIP (protected) |

Selection logic flow:
```
For each message in conversation:
  1. Is role == "tool"?               → NO: skip (user/assistant/system protected)
  2. Is it within last N turns?       → YES: skip (recent, model may reference)
  3. Is content < 500 chars?          → YES: skip (too small, overhead not worth it)
  4. Does it look like an error?      → YES: skip (headroom protects errors anyway)
  5. Otherwise                        → SEND to sidecar for compression
```

This means the sidecar only processes content that's likely to yield 50%+ savings.
A typical 10-turn coding session might have 8 tool outputs, of which 3-4 are old
enough and large enough to compress — the sidecar handles only those, not all 8.

**What we already built (on feat/headroom-on-metering branch):**
- `pkg/plugins/headroom/plugin.go` — Go plugin with selection logic
- `pkg/plugins/headroom/client.go` — HTTP client for /v1/compress-raw
- `pkg/plugins/headroom/plugin_test.go` — 20 tests, all pass
- `deploy/examples/headroom/compress-raw-server.py` — Python sidecar
- `deploy/examples/headroom/Dockerfile` — Sidecar image with pre-downloaded Kompress model

---

---

### Option E: Shared Headroom Compression Service (Noy's Proposal)

```
                    ┌─────────────────────────┐     ┌──────────────┐
                    │    MaaS/BBR Pod          │     │  Headroom    │
                    │                         │     │  Service     │
Users ──────────────│  ┌──────────────┐       │     │  (shared)    │──▶ Provider
(Claude Code,       │  │  BBR ext-proc │──────────▶│              │   (Anthropic,
 Codex, etc.)       │  │              │◀──────────│ • compress() │    OpenAI)
                    │  │ • Auth       │       │     │ • CacheAlign│
                    │  │ • Headroom   │       │     │ • Session   │
                    │  │   plugin     │       │     │ • Kompress  │
                    │  │ • Metering   │       │     │ • GPU pool  │
                    │  │ • API trans  │       │     └──────────────┘
                    │  │ • Key inject │       │
                    │  └──────────────┘       │
                    └─────────────────────────┘
```

**User config:** Same as MaaS today — no change.
```bash
ANTHROPIC_BASE_URL=https://maas.company.com/llm/ext-opus
ANTHROPIC_API_KEY=<MaaS-key>
```

**How it works:**
1. User sends request to MaaS (exactly as today)
2. BBR headroom plugin sends the FULL messages array to headroom service
3. Headroom service runs `compress(messages, model)` — the library API, not the proxy
4. Returns compressed messages with stats
5. Plugin replaces messages in request body, writes savings to CycleState
6. BBR continues: api-translation, apikey-injection, metering

**Key difference from Option D:** Uses headroom's **library API** (`from headroom import compress`),
not the custom `/v1/compress-raw` endpoint. The library has the full pipeline:

| Feature | Option D (/v1/compress-raw) | Option E (library compress()) |
|---------|---------------------------|-------------------------------|
| ContentRouter (smart strategy) | Yes | Yes |
| SmartCrusher / Kompress / CodeCompressor | Yes (manual preload) | Yes (automatic) |
| **CacheAligner** (prefix stabilization for KV cache hits) | **No** | **Yes** |
| **Session tracking** (turn distance from history) | **No** (Go turn-counting) | **Yes** |
| **CCR cache** (skip re-compression of seen content) | **No** | **Yes** |

**CacheAligner is potentially more valuable than compression itself.**
Anthropic charges $1.88/MTok for cache reads vs $18.75/MTok for new input — 10x difference.
CacheAligner stabilizes prompt prefixes so the provider's KV cache hits consistently.
Without it, compressed text varies slightly each time → cache miss every request.

**Pros:**
- **Full headroom pipeline** — CacheAligner, session tracking, CCR cache, Kompress, all automatic
- **Shared GPU pool** — one headroom Deployment with GPU, shared across all users. Not per-pod
- **Zero user changes** — same MaaS URL, same key
- **Simpler Go plugin** — send full messages array, get compressed messages back. No selection
  logic, no turn-counting, no content detection in Go. Headroom handles it internally.
- **MaaS handles auth/metering** — same as Option D
- **Scales efficiently** — 3-5 headroom replicas with GPU serve 1000+ users vs 10× sidecar pods

**Cons:**
- **Network hop** — plugin calls headroom service over cluster network (not localhost like Option D).
  ~1-5ms latency, negligible vs compression time.
- **Service dependency** — headroom service must be up. `failOpen=true` mitigates this.
- **Requires plugin code change** — current plugin sends text blocks to `/v1/compress-raw`.
  Needs update to send full message array to `/v1/compress`. Simpler code though.

**Implementation:**
- Headroom service: ~20 lines of Python wrapping `from headroom import compress`
- Go plugin update: simplify to send `messages` + `model`, receive compressed `messages`
- Deploy as a Kubernetes Service in `openshift-ingress` namespace

---

## Comparison Matrix

| Aspect | A: Before MaaS | B: After MaaS | C: Standalone | D: BBR Sidecar | **E: Enhanced Service (Deployed)** |
|--------|----------------|---------------|---------------|----------------|--------------------------------------|
| **Compression** | YES | YES | YES | YES (53%) | **YES (full pipeline)** |
| **CacheAligner** | YES | YES | YES | NO | **YES** |
| **Per-user session cache** | YES (proxy) | YES | YES | NO | **YES (CompressionCache per user)** |
| **CCR (retrieve originals)** | YES | YES | YES | NO | NO (architecture limitation) |
| **Dashboard + Playground** | YES | N/A | YES | NO | **YES (custom + embedded in MaaS)** |
| **Prometheus metrics** | YES | N/A | YES | NO | **YES (`/metrics`)** |
| **Per-model pricing** | NO | NO | NO | NO | **YES (from metering Postgres)** |
| **Auth/key mgmt** | MaaS | MaaS | Manual | MaaS | **MaaS** |
| **Per-user tracking** | Needs header | Native | Needs header | Native | **YES (x-maas-username)** |
| **Stats persistence** | In-memory | N/A | In-memory | NO | **SQLite on PVC** |
| **Routing complexity** | Low | HIGH | None | None | **None** |
| **User changes** | New URL | New path | New URL + key | None | **None** |
| **GPU sharing** | Own pool | N/A | Own pool | Per-pod | **Shared pool (auto-detect)** |

### Option E-Proxy: Headroom Proxy as Shared Compression Service (Recommended)

```
                    ┌─────────────────────────┐     ┌──────────────────────────┐
                    │    MaaS/BBR Pod          │     │  Headroom Proxy          │
                    │                         │     │  (shared Deployment)     │
Users ──────────────│  ┌──────────────┐       │     │                          │
(Claude Code,       │  │  BBR ext-proc │───────────▶│  POST /v1/compress       │
 Codex, etc.)       │  │              │◀───────────│  (built-in endpoint)     │
                    │  │ • Auth       │       │     │                          │
                    │  │ • Headroom   │       │     │  All of this is FREE:    │
                    │  │   plugin     │       │     │  • /stats (rich summary) │
                    │  │ • Metering   │       │     │  • /dashboard (built-in) │
                    │  │ • API trans  │       │     │  • /metrics (Prometheus) │
                    │  │ • Key inject │       │     │  • /readyz, /livez       │
                    │  └──────────────┘       │     │  • CCR (retrieve orig.)  │
                    └─────────────────────────┘     │  • Session tracking      │
                                                    │  • CacheAligner          │
                                                    │  • CostTracker           │
                                                    │  • Kompress ML (GPU)     │
                                                    └──────────────────────────┘
```

**User config:** Same as MaaS today — no change.
```bash
ANTHROPIC_BASE_URL=https://maas.company.com/llm/ext-opus
ANTHROPIC_API_KEY=<MaaS-key>
```

**How it works:**
1. User sends request to MaaS (exactly as today)
2. BBR headroom plugin sends the FULL messages array to headroom proxy's `/v1/compress`
3. Headroom proxy runs the full `TransformPipeline`: ContentRouter → SmartCrusher,
   Kompress, CodeCompressor, CacheAligner — the exact same pipeline used in proxy mode
4. Returns compressed messages with stats + CCR hashes
5. Plugin replaces messages in request body, writes savings to CycleState
6. BBR continues: api-translation, apikey-injection, metering

**Why E-Proxy over original Option E:**

The original Option E wrapped headroom's `compress()` library function in a custom
FastAPI service (~120 lines). This worked but meant maintaining custom code for:
- Stats aggregation and persistence
- Dashboard HTML
- Health/readiness endpoints
- Per-user tracking
- Cost calculations
- Prometheus metrics

The headroom proxy already ships ALL of this. Its `/v1/compress` endpoint uses the
full `TransformPipeline` (not bare `compress()`) and the proxy has built-in:

| Feature | Original E (custom service) | E-Proxy (headroom proxy) |
|---------|----------------------------|--------------------------|
| `/v1/compress` endpoint | Custom 120-line FastAPI | Built-in, production-grade |
| Stats (`/stats`) | Custom, in-memory, lost on restart | Built-in, session summary, cost breakdown |
| Dashboard (`/dashboard`) | Custom HTML, manually deployed | Built-in, ships with headroom |
| Prometheus metrics (`/metrics`) | Not implemented | Built-in, per-strategy counters |
| Health checks (`/readyz`, `/livez`) | Custom `/health` only | Built-in, checks model load status |
| CCR (retrieve original content) | Not available | Built-in, LLM can retrieve compressed originals |
| Session tracking | Not available | Built-in, turn-distance aware |
| CacheAligner | Via `compress()` | Via `TransformPipeline` (full pipeline) |
| CostTracker with budgets | Not available | Built-in |
| Per-user tracking | Custom header parsing | Forward `x-maas-username`, proxy tracks |
| Code to maintain | ~120 lines Python + dashboard HTML | Zero — just env vars |

**The `/v1/compress` contract is identical.** The Go plugin sends
`{messages: [...], model: "..."}` and gets back
`{messages: [...], tokens_before, tokens_after, tokens_saved, compression_ratio}`.
No Go changes needed — swap the service, keep the plugin.

**Deployment:**
```dockerfile
FROM python:3.12-slim
RUN pip install --no-cache-dir "headroom-ai[ml]" onnxruntime
ENV HF_HOME=/opt/huggingface
ENV HOME=/opt/app
RUN mkdir -p /opt/huggingface /opt/app && \
    python -c "from huggingface_hub import snapshot_download; \
    snapshot_download('chopratejas/kompress-v2-base'); \
    snapshot_download('answerdotai/ModernBERT-base')" && \
    chmod -R 777 /opt/huggingface /opt/app
EXPOSE 8787
ENTRYPOINT ["headroom", "proxy", "--port", "8787", "--host", "0.0.0.0"]
```

No custom Python code. No custom dashboard. No custom stats.

**Build independence:** Yossi controls the headroom service image entirely.
Noy controls the BBR image. The only shared contract is `POST /v1/compress`.
One final ask from Noy: forward `x-maas-username` header in the Go plugin's
HTTP call to headroom service. After that, the Go plugin is frozen — all future
changes happen in the headroom service (which is just `headroom proxy`).

**Pros:**
- Everything from Option E, PLUS:
- **Zero custom code** — no service wrapper, no dashboard, no stats aggregation to maintain
- **Production-grade observability** — built-in `/stats`, `/metrics`, `/dashboard`
- **CCR** — compressed content retrievable by the LLM via hash
- **Session tracking** — turn-distance aware compression (knows which content is "old")
- **CostTracker** — budget limits, cost breakdown by provider
- **Upgrades for free** — `pip install --upgrade headroom-ai` gets new features without code changes
- **Same Go plugin contract** — zero changes to BBR side

**Cons:**
- Headroom proxy starts a forwarding backend (unused — we only use `/v1/compress`)
- Proxy startup is heavier than bare `compress()` (loads more subsystems) — ~10s vs ~5s
- Proxy mode settings need to be configured for the service use case:
  - `HEADROOM_SKIP_UPSTREAM_CHECK=1` — don't check provider connectivity on startup
  - `HEADROOM_HOST=0.0.0.0` — listen on all interfaces
  - `HEADROOM_MODE=token` — optimize for token savings
- Stats are in-memory by default (no persistence). CCR can persist via
  `HEADROOM_CCR_BACKEND=sqlite`. General stats need a PVC mount or
  are reset on pod restart (acceptable for MVP — proxy's `/stats` rebuilds
  from the request log if `HEADROOM_LOG_REQUESTS=true` + PVC for log dir)
- The proxy's `/stats` JSON schema is significantly richer than what our custom
  dashboard expects. Our dashboard will need to be adapted to the proxy's schema,
  OR we use the proxy's built-in `/dashboard` instead

**`/v1/compress` response format — compatible with Go plugin:**
```json
{
  "messages": [...],
  "tokens_before": 1000,
  "tokens_after": 500,
  "tokens_saved": 500,
  "compression_ratio": 0.5,
  "transforms_applied": ["SmartCrusher", "ContentRouter"],
  "transforms_summary": "...",
  "ccr_hashes": ["hash1", "hash2"]
}
```
The Go plugin reads `messages`, `tokens_before`, `tokens_after`, `tokens_saved`,
`compression_ratio` — all present. Extra fields (`transforms_summary`, `ccr_hashes`)
are ignored by the Go plugin. **No Go changes needed.**

---

## Recommendation

**Option E (Enhanced Custom Service)** is the deployed and recommended architecture.

We evaluated using the headroom proxy directly (E-Proxy) but found that its `/v1/compress`
endpoint doesn't feed into the proxy's stats pipeline — it only tracks proxied LLM requests.
Since our architecture uses `/v1/compress` as a utility API called by the BBR plugin (not
as a transparent proxy), we need our own stats, persistence, and session tracking.

**Why Enhanced E wins:**
- Full headroom compression pipeline (SmartCrusher, Kompress ML, CacheAligner) via `compress()`
- **Per-user session cache** — `CompressionCache` per user avoids re-compressing content seen
  in earlier requests. Same cross-request optimization as the local headroom proxy.
- **Per-model pricing** — real costs from metering Postgres, not hardcoded estimates
- **SQLite persistence** — stats survive pod restarts, stored on PVC
- **Prometheus metrics** + dashboard with playground for demos
- Shared GPU pool (auto-detect via `onnxruntime-gpu`)
- Zero user changes — same MaaS URL, same key
- 35 tests including security audit, persistence, all compression engines

**Known limitation: no CCR.** In our architecture, the LLM talks to the provider, not
to the headroom service. The LLM cannot call `headroom_retrieve` to get compressed
originals back. This would require either MCP integration (headroom as an MCP server
alongside the BBR flow) or switching to full proxy mode (Option A/C). For coding agent
use cases, this is acceptable — headroom's compression is lossy-safe and the LLM can
re-read files if needed.

**Multi-user scaling:**
Each user gets their own `CompressionCache` instance (bounded, LRU-evicted, TTL-based).
When user A sends request #5, tool content that was compressed in their earlier requests
is served from cache — no re-compression. This closes the main gap between centralized
deployment and per-user local proxy.

| Setting | Default | Purpose |
|---------|---------|---------|
| `HEADROOM_MAX_USER_SESSIONS` | 200 | Max concurrent user sessions in memory |
| `HEADROOM_MAX_CACHE_ENTRIES` | 5000 | Max cached compressions per user |
| `HEADROOM_SESSION_TTL` | 7200 (2h) | Idle session eviction time |

## Compression Stack: Kompress ML + Smart_Crusher

Headroom uses two compression methods:
- **smart_crusher** — rule-based, compresses JSON arrays by removing duplicate structure. Instant, no ML.
- **Kompress** — ML model (ModernBERT tokenizer + Kompress ONNX, ~274MB) that scores token
  importance and removes low-value tokens. Handles text, logs, code. ~3s on CPU, <100ms on GPU.

Both methods are always used together via the `ContentRouter`, which detects content type
and routes to the appropriate compressor.

| | Smart_crusher (JSON) | Kompress ML (text/logs/code) | ModernBERT tokenizer |
|---|---|---|---|
| **Options A, B, C** (proxy mode) | Automatic | Automatic — loaded on startup | Automatic |
| **Option D** (sidecar) | Requires custom endpoint | Requires manual pre-load | Requires pre-download in Dockerfile |

**Options A/B/C** — headroom's proxy loads the full compression stack on startup. Deploy the
Docker image and everything works. No custom code.

**Option D** — the native `/v1/compress` API doesn't work for stateless calls (protects
everything as "recent"). We built a custom `/v1/compress-raw` endpoint that calls
`ContentRouter.compress()` directly and manually pre-loads `KompressCompressor` into
the router. Without this wiring, only smart_crusher runs and Kompress is silently skipped.
This is custom code that reimplements what headroom's proxy does natively.

This is a meaningful architectural difference: Options A/B/C use headroom as designed
and get the full compression stack for free. Option D requires custom code to achieve
the same result.

## Resource Requirements

| Resource | CPU-only | With GPU |
|----------|----------|----------|
| CPU | 4 cores | 1 core |
| Memory | 4Gi | 4Gi |
| GPU | — | 1x NVIDIA L4/T4 |
| Kompress latency | ~3s | <100ms |
| Concurrent users | ~20 | ~200 |
| Replicas (100 users) | 3-5 | 1 |

## Updates from Noy's Dogfood Environment (sandbox659)

Noy has a newer cluster (sandbox659) with significant improvements over sandbox311.
This changes the viability of several options:

### What's new in sandbox659:
1. **PR #301 (passthrough) IS deployed** — `/v1/messages` works, multi-model works
   - Single URL per provider: `/llm/ext-opus` handles ALL Anthropic models
   - Users switch models via request body, not URL
   - Claude Code `/model` switching works
2. **Codex (OpenAI) support** — `ext-gpt55` route with `openai-responses` format
3. **Body-based model resolution** — model resolved from X-Gateway-Model-Name header
   (set from request body), not from URL path
4. **Lua filter for auth** — copies `x-api-key` → `Authorization: Bearer` for Anthropic SDK
5. **EnvoyFilter: INSERT_BEFORE router** (not INSERT_AFTER wasm) — this may fix
   the ext-proc routing ordering issue that blocked Option B
6. **Combined build image** — cherry-picks multiple PRs including headroom branch

### Impact on options:

**Option B (After MaaS)** — may now be viable. The `INSERT_BEFORE router` positioning
and body-based model resolution might solve the routing issue we hit on sandbox311.
Worth re-testing on sandbox659.

**Option D (BBR Plugin)** — even stronger. The combined build already includes
Yossi's headroom branch. The sidecar just needs to be added to the deployment.
Body-based model resolution means no model mismatch issues.

**Codex support** — headroom supports OpenAI Responses API (`/v1/responses`) natively.
Both Claude Code and Codex users would get compression through the same headroom
deployment.

### For Option D on sandbox659:
The headroom plugin code is already in the combined build image (`v2` tag). To enable:
1. Add headroom sidecar container to the payload-processing deployment
2. Add `headroom:headroom:{...}` to the plugin chain (after metering, before model-resolver)
3. No image rebuild needed — the plugin is registered

## Open Items

1. **Go plugin header forwarding** — One-time ask from Noy: forward `x-maas-username`
   header from the request to the headroom service call. After that, the Go plugin
   is frozen. All future changes happen in the headroom proxy service (image rebuild only).
2. **GPU support** — Deploy with `onnxruntime-gpu` for <100ms Kompress latency (currently
   ~3s on CPU). Requires NVIDIA GPU Operator on the OpenShift cluster.
3. **Stats persistence** — Headroom proxy stats are in-memory by default. Need to evaluate
   headroom's built-in `store_url` config (SQLite/JSONL) or mount a PVC for the proxy's
   data directory.
4. **Vertex AI compression** — headroom's LiteLLM backend bypasses compression.
   Needs upstream headroom fix or wrapper. Anthropic + OpenAI work today.
5. **Streaming + metering** — can't coexist due to SSE parsing issue in BBR.
   Waiting on PR #138. Not a headroom issue.
6. **Dashboard compatibility** — Verify headroom's built-in `/dashboard` shows the
   stats we need (per-user, cost savings, compression breakdown). If not, our custom
   dashboard can read from `/stats` which the proxy also exposes.
