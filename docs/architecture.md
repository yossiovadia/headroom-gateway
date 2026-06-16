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

## Comparison Matrix

| Aspect | A: Before MaaS | B: After MaaS | C: Standalone | D: BBR Plugin |
|--------|----------------|---------------|---------------|---------------|
| **Compression** | YES | YES (if routing fixed) | YES | YES (proven 53%) |
| **Auth/key mgmt** | MaaS handles | MaaS handles | Manual / shared key | MaaS handles |
| **Per-user tracking** | Needs header | Native (x-maas-username) | Needs header | Native (metering plugin) |
| **Metering shows savings** | YES (compressed) | NO (original) | N/A (own dashboard) | YES (compressed) |
| **Routing complexity** | Low | HIGH (blocker) | None | **None (localhost)** |
| **Multi-provider** | YES | Depends on MaaS routes | YES | What MaaS supports |
| **MaaS dependency** | Optional | Required | None | Required |
| **User changes** | New URL | New path | New URL + key | **None** |
| **Time to pilot** | Days | Weeks | Now | **Days (code exists)** |
| **Failover** | Bypass → MaaS | Bypass → provider | No service | failOpen=true (pass through) |

## Recommendation

**Option A (Headroom Before MaaS)** is the recommended architecture.

Rationale:
- Uses headroom exactly as designed — transparent proxy with session-aware compression
- No custom code — deploy upstream headroom image, no Go plugins or custom Python endpoints
- Separation of concerns — compression and auth/metering are independent services with
  independent scaling, lifecycle, and updates
- No resource overhead on BBR pods (headroom runs in its own pods)
- Multi-provider native — headroom routes by API format without any MaaS configuration
- MaaS sees compressed tokens — metering reflects actual cost

**Option D (BBR Plugin)** is a viable fallback if Option A routing proves difficult on
a specific cluster. It works but introduces custom code, couples compression to the
BBR lifecycle, and adds significant sidecar resource overhead (4Gi + 4 CPU per pod).

**Option B (After MaaS)** is not recommended — MaaS modifies the request before headroom
sees it (format translation, key injection), which interferes with headroom's session
tracking and compression logic.

### Suggested plan:
1. **Week 1**: Deploy Option A on sandbox659 — headroom as a Service, MaaS forwards to it
2. **Week 1**: Verify: user → headroom (compress) → MaaS (auth, meter) → provider
3. **Week 2**: Pilot with 3-5 users (Claude Code + Codex) — monitor both dashboards
4. **Week 3**: Evaluate compression savings, latency impact, decide on GPU for production
5. **Fallback**: If Option A routing doesn't work, deploy Option D (code exists, proven)

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
