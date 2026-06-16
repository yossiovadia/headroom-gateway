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

| Aspect | A: Before MaaS | B: After MaaS | C: Standalone | D: BBR Sidecar | E: Shared Service |
|--------|----------------|---------------|---------------|----------------|-------------------|
| **Compression** | YES | YES | YES | YES (53%) | YES (full pipeline) |
| **CacheAligner** | YES | YES | YES | **NO** | **YES** |
| **Session tracking** | YES (proxy) | YES | YES | NO (turn heuristic) | **YES** |
| **Auth/key mgmt** | MaaS | MaaS | Manual | MaaS | **MaaS** |
| **Per-user tracking** | Needs header | Native | Needs header | Native | **Native** |
| **Metering** | Compressed tokens | Original tokens | Own dashboard | Compressed | **Compressed** |
| **Routing complexity** | Low | HIGH | None | None (localhost) | **None (service)** |
| **User changes** | New URL | New path | New URL + key | **None** | **None** |
| **Custom code** | None | None | None | Go + Python | **Go + Python (simpler)** |
| **Resource per pod** | None | None | None | 4Gi + 4CPU each | **Shared pool** |
| **GPU sharing** | Own pool | N/A | Own pool | Per-pod (expensive) | **Shared pool** |
| **Scale to 50 users** | Good | Good | Good | OK | **Best** |

## Recommendation

**Option E (Shared Headroom Compression Service)** is the recommended architecture.

Rationale:
- Full headroom pipeline including CacheAligner (10x cache savings), session tracking, CCR cache
- Shared GPU pool scales efficiently (3-5 replicas serve 50+ users vs per-pod sidecars)
- Zero user changes — same MaaS URL, same key
- MaaS handles auth, metering, per-user tracking — no new user-facing services
- Simpler Go plugin than Option D — no custom selection logic, headroom handles it
- No routing complexity — plugin calls service directly over cluster network

**Option A (Headroom Before MaaS)** is the cleanest separation of concerns but requires
users to change their URL and doesn't integrate with MaaS auth/metering natively.
Good for standalone deployments without MaaS.

**Option D (BBR Sidecar)** is a proven fallback but misses CacheAligner and session
tracking, duplicates resources per pod, and requires custom `/v1/compress-raw` endpoint.

**Option B (After MaaS)** is not recommended — MaaS modifies the request before headroom
sees it, interfering with headroom's compression logic.

### Suggested plan:
1. **Week 1**: Deploy headroom service on sandbox659 (Python wrapper, ~20 lines)
2. **Week 1**: Update Go plugin to call `/v1/compress` with full message array
3. **Week 1**: Add to ConfigMap, rebuild image, verify e2e
4. **Week 2**: Pilot with 5-10 users (Claude Code + Codex) — monitor dashboards
5. **Week 3**: Evaluate compression + cache savings, decide on GPU for production

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

1. **Vertex AI compression** — headroom's LiteLLM backend bypasses compression.
   Needs upstream headroom fix or wrapper. Anthropic + OpenAI work today.
2. **Streaming + metering** — can't coexist due to SSE parsing issue in BBR.
   Waiting on PR #138. Not a headroom issue.
3. **Per-user header** — Claude Code doesn't natively set x-headroom-user-id.
   Options: apiKeyHelper injects it, or use API key as user identifier.
4. **Test on sandbox659** — re-evaluate Option B and D on Noy's newer cluster
   where PR #301 and body-based routing are deployed.
