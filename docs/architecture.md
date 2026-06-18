# Headroom Gateway — Architecture

## Problem

LLM coding agents (Claude Code, Codex, Copilot) generate massive context through
tool calls — file reads, build logs, API responses, search results. A typical
coding session reaches 150K+ tokens, of which **80% is tool output**. Every request
sends the full conversation history. Token costs scale linearly.

[Headroom](https://github.com/chopratejas/headroom) (Apache 2.0, 28k+ stars)
compresses old tool outputs by 50-70% with zero quality loss. But it runs as a
local proxy — each user installs it individually.

**Goal**: Deploy headroom centrally on OpenShift so all users get compression
automatically. No client-side installation. Integrated with MaaS auth, metering,
and per-model pricing.

## Proven Compression Results

| Content Type | Savings | Engine | Latency |
|---|---|---|---|
| JSON arrays (K8s pods, API responses) | **70-74%** | SmartCrusher (Rust) | <50ms |
| Build logs, grep output | **80%** | SearchCompressor | <50ms |
| Source code | **32-36%** | Kompress ML (ModernBERT + ONNX) | ~3s CPU, <100ms GPU |
| Free text (docs, meeting notes) | **10-17%** | Kompress ML | ~3s CPU, <100ms GPU |
| Error logs | **0%** (protected) | — | — |

Cost impact at Opus pricing ($15/MTok): ~$31K saved per 1M requests.

## Architecture

```
Client (Claude Code / Codex / Cursor)
  │
  ▼
MaaS Gateway (Envoy + Istio)
  ├─ Kuadrant: API key validation
  ├─ ext_proc (payload-processing / BBR):
  │   ├─ body-field-to-header: model → X-Gateway-Model-Name
  │   ├─ model-provider-resolver: resolve ExternalModel → provider
  │   ├─ headroom plugin ─────────────────────────┐
  │   │                                           │
  │   │   POST /v1/compress                       ▼
  │   │   {messages, model}          ┌──────────────────────────┐
  │   │                              │  Headroom Service        │
  │   │   ◄── compressed messages ── │  (this repo)             │
  │   │                              │                          │
  │   │                              │  Per-user session cache  │
  │   │                              │  ├─ apply_cached()       │
  │   │                              │  ├─ compress()           │
  │   │                              │  └─ update_from_result() │
  │   │                              │                          │
  │   │                              │  SQLite stats (PVC)      │
  │   │                              │  Per-model pricing (PG)  │
  │   │                              │  Prometheus /metrics     │
  │   │                              │  Dashboard + Playground  │
  │   │                              └──────────────────────────┘
  │   │
  │   ├─ api-translation: passthrough (PR #301)
  │   ├─ apikey-injection: inject provider key
  │   └─ external-metering: report usage
  │
  ▼
Provider (api.anthropic.com / api.openai.com)
```

**User config**: Same as MaaS today — no changes required.

```bash
ANTHROPIC_BASE_URL=https://maas.company.com/llm/ext-opus
ANTHROPIC_API_KEY=<MaaS-key>
claude --model claude-opus-4-8
```

### How It Works

1. User sends request to MaaS (exactly as today)
2. BBR headroom plugin sends full messages array to headroom service `POST /v1/compress`
3. Headroom service checks per-user `CompressionCache`:
   - Tool content seen before → use cached compressed version (instant, no re-compression)
   - New content → compress via headroom's `compress()` pipeline → cache result
4. Returns compressed messages + stats to plugin
5. Plugin replaces messages in request body, writes savings to CycleState
6. BBR continues: api-translation, apikey-injection, metering
7. Request goes to provider with compressed input

### Compression Pipeline (headroom internals)

ContentRouter detects content type and routes to the best compressor:

```
Tool output content
  │
  ContentRouter (auto-detect)
  │
  ├─ JSON array? ──────── SmartCrusher (Rust, instant)
  │                       Deduplicates structure, keeps important items + anomalies
  │
  ├─ Log/grep output? ── SearchCompressor (instant)
  │                       Compresses repetitive lines, preserves errors + timestamps
  │
  ├─ Source code? ─────── CodeCompressor (tree-sitter, optional)
  │                       AST-aware compression preserving structure
  │
  ├─ Free text? ─────── Kompress ML (ModernBERT + ONNX)
  │                       Scores token importance, removes low-value tokens
  │
  └─ Error output? ──── PROTECTED (no compression)
                         Tracebacks, stack traces, error messages preserved verbatim
```

### Per-User Session Cache

Each user gets their own `CompressionCache` (headroom's built-in content-addressed
cache). This avoids re-compressing the same tool output across requests in a session.

```
Request #1: User reads file A (2000 tokens) → compressed to 800 tokens → cached
Request #2: User reads file B + file A still in history → file A served from cache (instant),
            only file B compressed
Request #3: User reads file C + files A,B in history → both from cache, only C compressed
```

| Setting | Default | Purpose |
|---------|---------|---------|
| `HEADROOM_MAX_USER_SESSIONS` | 200 | Max concurrent user sessions in memory |
| `HEADROOM_MAX_CACHE_ENTRIES` | 5000 | Max cached compressions per user |
| `HEADROOM_SESSION_TTL` | 7200 (2h) | Idle session eviction time |

## Local Proxy vs Centralized Service — Gap Analysis

| Capability | Local headroom proxy (per-user) | Centralized service (deployed) | Gap |
|---|---|---|---|
| **SmartCrusher** (JSON) | YES | YES | None |
| **Kompress ML** (text) | YES | YES | None |
| **SearchCompressor** (logs) | YES | YES | None |
| **CodeCompressor** (AST) | YES | YES (if tree-sitter installed) | None |
| **CacheAligner** (prefix stability) | YES | YES (per-call) | None |
| **Cross-request compression cache** | YES (proxy session) | YES (per-user CompressionCache) | **Closed** |
| **CCR** (retrieve compressed originals) | YES — LLM calls `headroom_retrieve` | NO — LLM talks to provider, not headroom | **Open** |
| **MCP tools** (compress, retrieve, stats) | YES — headroom as MCP server | NO — BBR plugin architecture | **Open** |
| **Session-aware turn distance** | YES — proxy tracks full conversation | Partial — `compress()` infers from message array | **Minor** |
| **Per-user stats** | YES (local) | YES (SQLite, per-model pricing from Postgres) | None |
| **Multi-user** | N/A (single user) | YES (200 concurrent sessions) | **Advantage** |
| **Zero install** | NO (user installs headroom) | YES (transparent via MaaS) | **Advantage** |
| **Centralized dashboard** | NO | YES (KPIs, per-user, playground) | **Advantage** |
| **Auth/metering integration** | NO | YES (MaaS Kuadrant + metering) | **Advantage** |
| **GPU sharing** | Per-user GPU or CPU | Shared GPU pool | **Advantage** |

### Open Gaps — Detail

**CCR (Compress-Cache-Retrieve):**
When headroom compresses a JSON array from 50 items to 5, it stores the originals
locally. If the LLM later needs item #37, it calls `headroom_retrieve(hash)` to get
it back without re-reading the source. In our architecture, the LLM talks to the
provider (Anthropic/OpenAI), not to headroom — so it can't call retrieve. The LLM
would need to re-read the file instead.

Impact: Low for coding agents. Claude Code can re-read files via its Read tool.
The compressed summary gives it enough context to know WHAT to re-read. For
RAG/search use cases where the original source isn't re-readable, this gap matters more.

Fix path: Add headroom as an MCP server alongside the BBR flow. Claude Code already
supports MCP servers — headroom ships `headroom mcp serve`. This would require
users to configure headroom as an MCP server in their Claude Code settings, which
partially defeats the "zero install" advantage. A transparent solution would require
the BBR plugin to inject `headroom_retrieve` as a tool in the request, which is
architecturally complex.

**MCP Tools:**
Headroom ships three MCP tools: `headroom_compress` (on-demand compression),
`headroom_retrieve` (CCR), `headroom_stats` (session stats). These are available
in local proxy mode but not in our centralized architecture. Same root cause as
the CCR gap — the LLM doesn't talk to headroom directly.

**Session-aware turn distance:**
The local proxy sees every request in sequence and tracks which tool outputs are
"old" (many turns ago) vs "recent" (last 1-2 turns). Our service receives the full
message array each time and infers age from position — this is what `compress()` does
internally. The inference is correct but slightly less precise than explicit turn tracking.
In practice, the `protect_recent` parameter handles this well enough.

## Deployment

### Prerequisites

- MaaS gateway deployed (Envoy + Istio + Kuadrant)
- payload-processing (BBR) deployed with headroom plugin registered
- metering-service with `model_pricing` table in Postgres (for per-model pricing)
- ipp-config ConfigMap (headroom plugin entry added after deployment)

### Deploy

```bash
./scripts/deploy-headroom.sh --hf-token hf_xxx
```

The script is idempotent (safe to run multiple times), validates all prerequisites
before starting, skips image builds when source is unchanged, and runs a smoke test
after deployment.

### What Gets Deployed

| Resource | Purpose |
|----------|---------|
| `headroom-service` Deployment | Compression service (FastAPI + headroom `compress()`) |
| `headroom-stats` PVC (1Gi) | SQLite stats persistence across pod restarts |
| `headroom-service` Service | ClusterIP on port 8787 |
| `headroom-service` Route | External HTTPS route (TLS edge termination) |
| `headroom-dashboard` Deployment | Standalone dashboard (nginx + HTML) |
| `headroom-dashboard` Route | External HTTPS route |
| Compression tab in MaaS dashboard | Embedded at `/compression` on metering-service |

### BBR Plugin Configuration

After deployment, add to ipp-config ConfigMap:

```yaml
- name: headroom
  type: headroom
  parameters:
    headroomURL: "http://headroom-service.openshift-ingress.svc:8787"
    timeoutSeconds: 10
    failOpen: true
```

Then restart payload-processing: `oc rollout restart deployment/payload-processing`

### GPU Support

GPU is auto-detected at runtime — `onnxruntime-gpu` is installed by default and
falls back to CPU if no NVIDIA GPU is available. No flags or configuration needed.

| Resource | CPU-only | With GPU |
|----------|----------|----------|
| Kompress ML latency | ~3s | <100ms |
| CPU | 4 cores | 1-2 cores |
| Memory | 4Gi | 4Gi |
| GPU | — | 1x NVIDIA L4/T4 |
| Concurrent users | ~20-50 | ~200+ |

## Endpoints

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/v1/compress` | POST | Compress messages (BBR plugin calls this) |
| `/stats` | GET | Stats for dashboard (aggregates, per-user, recent) |
| `/stats-history` | GET | Lifetime stats with history |
| `/pricing` | GET | Per-model pricing from metering Postgres |
| `/sessions` | GET | Active user sessions and cache hit rates |
| `/readyz` | GET | Readiness probe (checks SQLite) |
| `/health` | GET | Liveness probe |
| `/metrics` | GET | Prometheus counters |

## Test Suite

37 tests (35 fast + 2 slow) run against the live deployed service:

```bash
HEADROOM_TEST_URL=https://headroom-service-... pytest tests/ -v           # Fast tests
HEADROOM_TEST_URL=https://headroom-service-... pytest tests/ -v --run-slow # + persistence
```

| File | Tests | Coverage |
|------|-------|----------|
| `test_compress.py` | 14 | JSON, logs, code, errors, user tracking, model propagation |
| `test_stats.py` | 9 | Aggregation, per-user, cost math, history |
| `test_dashboard.py` | 7 | Dashboard contract, per-model pricing, transforms |
| `test_health.py` | 5 | readyz, metrics format, counter increments |
| `test_persistence.py` | 2 (slow) | Stats survive pod restart, DB rebuild |

## Related Repos

| Repo | Purpose |
|------|---------|
| `yossiovadia/headroom-gateway` | This repo — service, dashboard, deploy, tests |
| `yossiovadia/ai-gateway-payload-processing` branch `feat/headroom-on-metering` | Go plugin |
| `noyitz/ai-gateway-metering-service` | MaaS dashboard (compression tab embedded) |
| `chopratejas/headroom` | Upstream headroom library |
