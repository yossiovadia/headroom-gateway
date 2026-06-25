# Headroom Gateway

A centralized context compression service for enterprise LLM usage. Deploy once on
OpenShift/Kubernetes, point all users at it, automatically reduce token costs by
50-70% on tool-heavy workloads (coding agents, RAG, API calls) — with zero impact
on response quality.

Powered by [headroom](https://github.com/chopratejas/headroom) (28k+ stars).

## The Problem

LLM-powered coding agents (Claude Code, Codex, Copilot) generate enormous context
through tool calls — file reads, build logs, API responses, search results. A typical
coding session hits 150K+ tokens, of which **80% is tool output**. Every request
sends the full conversation history, and you pay per token.

Most of that tool output is repetitive, verbose, and compressible without affecting
the model's ability to reason about it. But compression needs to happen transparently
— users shouldn't have to think about it.

## The Solution

Headroom Gateway sits between your users and the LLM provider. It intercepts
requests, compresses old tool outputs using ML-based compression (Kompress) and
rule-based compression (smart_crusher), and forwards the smaller request to the
provider. The model sees compressed context and produces the same quality response.

```
Without:  User → Provider (150K tokens, full price)
With:     User → Headroom Gateway → Provider (50K tokens, 67% less)
```

Users change one environment variable:

```bash
export ANTHROPIC_BASE_URL=https://headroom.apps.company.com
claude  # that's it
```

## Why This Architecture

We explored several approaches before landing here:

1. **BBR ext-proc plugin** — Forced headroom into Envoy's ext-proc pipeline.
   Required custom Go plugins, custom Python endpoints, and fought the buffering
   model. Works but wrong abstraction.

2. **Client-side proxy** — Each user runs headroom locally. Works great but isn't
   centralized — no org-wide visibility or control.

3. **Centralized proxy service** (this) — Deploy headroom as a standalone K8s
   service. Uses headroom exactly as designed: a transparent HTTP proxy with
   session-aware compression. No custom code needed. One deployment serves all users.

## Proven Results

From our POC testing on OpenShift:

| Content Type | Compression | Quality Impact |
|---|---|---|
| Search/RAG results (50 docs) | **61.5%** | None |
| K8s API responses (30 pods) | **70.3%** | None |
| Log output (50 lines) | **65%** | None |
| Code files | **53%** | None |
| A/B test (real Claude response) | **55%** | Identical correct answer |

Cost impact at Claude Opus pricing ($15/M input tokens):
- Per request with tool outputs: ~$0.03 saved
- Per 1M requests: ~$31,000 saved

## Compression Engines

Headroom's `ContentRouter` auto-detects content type and routes to the best compressor:

| Engine | Active | What It Does | When It Fires | Typical Savings |
|--------|--------|-------------|---------------|-----------------|
| **SmartCrusher** | YES | Compresses JSON arrays — deduplicates structure, keeps important items and anomalies. Rust-backed via PyO3. | JSON arrays: kubectl output, API responses, search results | 60-74% |
| **Kompress ML** | YES | Custom ML model (ModernBERT tokenizer + ONNX) trained on AI agent traces. Scores token importance and removes low-value tokens. | Free text, prose, documentation — anything that doesn't match other engines | 10-35% |
| **SearchCompressor** | YES | Compresses grep/ripgrep results — keeps matching lines, deduplicates surrounding context | Tool outputs that look like search/grep results | 70-80% |
| **LogCompressor** | YES | Compresses build logs and test output — keeps errors/failures, deduplicates repetitive timestamp lines | Structured log output with timestamps | 65-80% |
| **DiffCompressor** | YES | Compresses git diffs — keeps diff hunks, deduplicates similar changes | Content matching unified diff format | 40-60% |
| **HTMLExtractor** | YES | Extracts meaningful text from HTML content, strips tags and boilerplate | HTML content in tool outputs | varies |
| **CodeAwareCompressor** | NO | AST-based code compression — preserves function signatures, removes bodies. Supports Python, JS, Go, Rust, Java, C++ | Source code. **Disabled by default** by headroom upstream — they recommend code graph MCP tools instead | 30-50% |
| **ImageCompressor** | N/A | ML router for image size reduction | Images — not applicable in our text-only pipeline | 40-90% |

### Content Protection (not compressed)

Not everything gets compressed. Headroom protects content that must remain exact:

| Content | Action | Reason |
|---------|--------|--------|
| **User messages** | Protected | Model needs exact user input |
| **System prompts** | Protected | Cache-hot instruction bytes |
| **Read tool outputs** (fresh) | Excluded | Exact file content needed for code editing |
| **Write/Edit tool outputs** | Excluded | Mutation records must be exact to prevent duplicate edits |
| **Error outputs** | Protected | Tracebacks and stack traces preserved verbatim for debugging |
| **Recent tool outputs** | Protected | Last N turns kept verbatim (configurable via `protect_recent`) |
| **Stale Read outputs** | Compressed | File was edited after reading — content is factually wrong (ReadLifecycle) |
| **Superseded Read outputs** | Compressed | File was re-read later — content is redundant (ReadLifecycle) |

## Quick Start

### Local Development

```bash
# Start headroom locally
docker compose up -d

# Point Claude Code at it
export ANTHROPIC_BASE_URL=http://localhost:8787
export ANTHROPIC_API_KEY=<your-key>
claude

# Check compression stats
curl http://localhost:8787/stats
```

### OpenShift Deployment

```bash
# One-command deploy (builds image on cluster)
./scripts/deploy.sh --build -n my-namespace

# Point users at the route
export ANTHROPIC_BASE_URL=https://headroom-gateway-my-namespace.apps.cluster.com
```

See [deployment guide](docs/deployment-guide.md) for detailed instructions.

## Two Modes

### Mode A: Standalone (Direct to Provider)

```
Users → Headroom Gateway → Anthropic / OpenAI / Vertex AI
```

Users bring their own API keys. Headroom passes them through, compresses context,
forwards to the provider. Built-in Prometheus metrics track per-user token savings.

### Mode B: With BBR/MaaS Platform

```
Users → Headroom Gateway → MaaS Gateway (metering + auth) → Provider
```

Headroom compresses, then forwards to the MaaS gateway which handles metering,
API key management, rate limiting, and provider auth. The metering dashboard
shows compressed token counts — reflecting actual cost savings.

Switch modes with one env var:

```bash
# Mode A (default): direct to provider
# (no config needed)

# Mode B: route through MaaS gateway
ANTHROPIC_TARGET_API_URL=https://maas-gateway.company.com/llm/ext-claude-sonnet
```

## Multi-Provider Support

Headroom routes by API format — one instance handles all providers:

| Path | Provider |
|------|----------|
| `/v1/messages` | Anthropic |
| `/v1/chat/completions` | OpenAI |
| `/v1/projects/.../publishers/...` | Vertex AI |
| Bedrock format | AWS Bedrock |

## Observability

### Without BBR

- **Prometheus** `/metrics` — token savings, compression ratios, request counts
- **Stats** `/stats` — real-time compression dashboard
- **Savings tracker** — cumulative savings persisted to disk
- **Per-user** — set `x-headroom-user-id` header for per-user breakdown

### With BBR/MaaS

All of the above, plus:
- MaaS metering dashboard with compressed token counts
- CloudEvents audit trail per user/group/subscription

## Capacity Planning

| Setup | Concurrent Users | Latency Overhead |
|-------|-----------------|-----------------|
| CPU-only (4 cores) | ~20 | ~3s per compression |
| GPU (NVIDIA L4/T4) | ~200 | <100ms per compression |
| JSON-only (no ML) | ~500 | <50ms |

Headroom is stateless per-request — scale horizontally with replicas.
HPA included in the deployment manifests.

## Project Structure

```
headroom-gateway/
├── deploy/
│   ├── openshift/          # K8s/OpenShift manifests (kustomize)
│   └── docker/             # Dockerfile
├── docs/                   # Guides and architecture docs
├── scripts/                # Deploy and test scripts
├── monitoring/             # Grafana dashboard + alerts
├── docker-compose.yaml     # Local development
└── README.md
```

## Related

- [headroom](https://github.com/chopratejas/headroom) — upstream context compression library
- [ai-gateway-payload-processing](https://github.com/opendatahub-io/ai-gateway-payload-processing) — BBR plugin system (MaaS platform)
- [Issue #324](https://github.com/opendatahub-io/ai-gateway-payload-processing/issues/324) — original exploration issue
