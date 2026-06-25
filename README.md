# Headroom Gateway

Centralized context compression service for enterprise LLM usage. Reduces token
costs across all users automatically — no client-side installation, no user changes.

Powered by [headroom](https://github.com/chopratejas/headroom) (Apache 2.0, 28k+ stars).

## The Problem

LLM coding agents (Claude Code, Codex, Copilot) generate massive context through
tool calls — file reads, build logs, API responses, search results. A typical
coding session reaches 150K+ tokens, of which **80% is tool output**. Every request
sends the full conversation history. Token costs scale linearly.

Most of that tool output is old, repetitive, and compressible without affecting
the model's reasoning. But compression must happen transparently — users shouldn't
have to think about it.

## How It Works

The headroom compression service integrates with the MaaS platform via a BBR plugin.
Users point at MaaS as they do today — compression is automatic.

```
Client (Claude Code / Codex / Cursor)
  │
  ▼
MaaS Gateway (Envoy + Istio)
  ├─ Kuadrant: API key validation, user identification
  ├─ BBR ext-proc (payload-processing):
  │   ├─ model-extractor: model → X-Gateway-Model-Name
  │   ├─ metering-check: balance check, user tracking
  │   ├─ model-provider-resolver: resolve ExternalModel → provider
  │   ├─ headroom plugin ──── POST /v1/compress ──▶ Headroom Service
  │   │                    ◀── compressed messages ─┘  (this repo)
  │   ├─ api-translation: passthrough
  │   └─ apikey-injection: inject provider key
  │
  ▼
Provider (api.anthropic.com / api.openai.com)
```

**Zero user changes.** Same MaaS URL, same API key:

```bash
export ANTHROPIC_BASE_URL=https://maas.company.com/llm/ext-opus
export ANTHROPIC_API_KEY=<MaaS-key>
claude --model claude-opus-4-8
```

## Compression Results

From production deployment on OpenShift:

| Content Type | Savings | Engine |
|---|---|---|
| Kubernetes API responses (JSON) | **60-74%** | SmartCrusher |
| Build/test logs | **65-80%** | LogCompressor / SearchCompressor |
| Search/grep results | **70-80%** | SearchCompressor |
| Free text / documentation | **10-35%** | Kompress ML |
| Git diffs | **40-60%** | DiffCompressor |
| Code editing sessions (mixed) | **5-15%** | Kompress ML (most content is excluded — see below) |

## Compression Engines

Headroom's `ContentRouter` auto-detects content type and routes to the best compressor:

| Engine | Active | What It Does | Typical Savings |
|--------|--------|-------------|-----------------|
| **SmartCrusher** | YES | Compresses JSON arrays — deduplicates structure, keeps important items and anomalies. Rust-backed via PyO3. | 60-74% |
| **Kompress ML** | YES | Custom ML model (ModernBERT tokenizer + ONNX) trained on AI agent traces. Scores token importance, removes low-value tokens. | 10-35% |
| **SearchCompressor** | YES | Compresses grep/ripgrep results — keeps matching lines, deduplicates context. | 70-80% |
| **LogCompressor** | YES | Compresses build logs and test output — keeps errors/failures, deduplicates repetitive lines. | 65-80% |
| **DiffCompressor** | YES | Compresses git diffs — keeps hunks, deduplicates similar changes. | 40-60% |
| **HTMLExtractor** | YES | Extracts meaningful text from HTML, strips tags and boilerplate. | varies |
| **CodeAwareCompressor** | NO | AST-based code compression (Python, JS, Go, Rust, Java, C++). Disabled by default upstream — headroom recommends code graph MCP tools instead. | 30-50% |
| **ImageCompressor** | N/A | ML router for image size reduction. Not applicable in our text-only pipeline. | 40-90% |

### Content Protection

Not everything gets compressed. Headroom protects content that must remain exact:

| Content | Action | Reason |
|---------|--------|--------|
| User messages | Protected | Model needs exact user input |
| System prompts | Protected | Cache-hot instruction bytes |
| Read tool outputs (fresh) | Excluded | Exact file content needed for code editing |
| Write/Edit tool outputs | Excluded | Mutation records must be exact to prevent duplicate edits |
| Error outputs | Protected | Tracebacks and stack traces preserved verbatim for debugging |
| Recent tool outputs | Protected | Last N turns kept verbatim |
| Stale Read outputs | Compressed | File was edited after reading — content is factually wrong |
| Superseded Read outputs | Compressed | File was re-read later — content is redundant |

### Why Code Editing Sessions Show Lower Savings

Coding sessions are dominated by Read/Edit tool outputs which headroom deliberately
excludes. Without retrieval support (CCR), compressing a file read would mean the LLM
works from a summary instead of exact code — risking wrong edits. Headroom's
ReadLifecycle catches stale reads (67% of all reads) and superseded reads (12%),
but fresh reads (20%) stay verbatim. DevOps/debugging sessions with logs, JSON, and
command output see much higher savings (40-70%).

## Features

- **Per-user session cache** — avoids re-compressing content seen in earlier requests (same user, same session)
- **Per-model pricing** — real costs from metering Postgres, not hardcoded estimates
- **SQLite stats persistence** — survives pod restarts (PVC-backed)
- **GPU acceleration** — onnxruntime-gpu auto-detects NVIDIA GPUs, falls back to CPU
- **4 gunicorn workers** — handles 50+ concurrent users
- **Dashboard** — KPIs, per-user breakdown, compression engine breakdown, hourly trends, playground
- **Playground tab** — interactive compression demo with pre-defined samples
- **Prometheus metrics** — `/metrics` endpoint with token counters
- **Idempotent deploy script** — preflight checks, skip-if-unchanged builds

## Deployment

### Prerequisites

- MaaS gateway deployed (Envoy + Istio + Kuadrant)
- payload-processing (BBR) deployed with headroom plugin registered
- metering-service with `model_pricing` table in Postgres
- ipp-config ConfigMap with headroom plugin entry

### Deploy

```bash
./scripts/deploy-headroom.sh --hf-token hf_xxx
```

The script validates prerequisites, builds the image on-cluster, creates a PVC for
stats persistence, deploys the service + dashboard, and runs a smoke test.

### BBR Plugin Configuration

Add to ipp-config ConfigMap (after model-provider-resolver, before api-translation):

```yaml
- name: headroom
  type: headroom
  parameters:
    headroomURL: "http://headroom-service.openshift-ingress.svc:8787"
    timeoutSeconds: 10
    failOpen: true
```

### GPU Support

GPU is auto-detected at runtime. No flags needed.

| Resource | CPU-only | With GPU |
|----------|----------|----------|
| Kompress ML latency | ~3s | <100ms |
| Concurrent users | ~50 | ~200+ |
| GPU required | — | 1x NVIDIA L4/T4 |
| Memory | 4-8Gi | 4-8Gi |

### Emergency Controls

**Kill switch** — remove headroom from ipp-config and restart payload-processing (~30 seconds):
```bash
oc edit configmap ipp-config -n openshift-ingress  # delete headroom block
oc rollout restart deployment/payload-processing
```

**Automatic fail-open** — if the headroom service is down or slow (>10s timeout),
requests pass through uncompressed automatically. No user impact.

## API Endpoints

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/v1/compress` | POST | Compress messages (BBR plugin calls this) |
| `/stats` | GET | Stats for dashboard (aggregates, per-user, recent) |
| `/stats/insights` | GET | Engine breakdown, by-model, hourly trends |
| `/stats-history` | GET | Lifetime stats with history |
| `/pricing` | GET | Per-model pricing from metering Postgres |
| `/sessions` | GET | Active user sessions and cache hit rates |
| `/readyz` | GET | Readiness probe (checks SQLite) |
| `/health` | GET | Liveness probe |
| `/metrics` | GET | Prometheus counters |

## Testing

37 tests run against the live deployed service:

```bash
# Fast tests (compression, stats, health, dashboard)
HEADROOM_TEST_URL=https://headroom-service-... pytest tests/ -v

# Including persistence tests (restarts pod, ~60s)
HEADROOM_TEST_URL=https://headroom-service-... pytest tests/ -v --run-slow

# Benchmark compression latency
./scripts/benchmark-compression.sh --requests 10
```

## Project Structure

```
headroom-gateway/
├── service/
│   ├── headroom_service.py     # FastAPI compression service
│   └── Dockerfile              # CUDA + headroom-ai + onnxruntime-gpu
├── dashboard/
│   └── index.html              # Dashboard + Playground (stats, per-user, pipeline viz)
├── scripts/
│   ├── deploy-headroom.sh      # Idempotent OpenShift deployment
│   ├── benchmark-compression.sh # Latency benchmark
│   └── ab-cache-test.py        # A/B cache hit comparison
├── tests/
│   ├── test_compress.py        # 14 compression tests
│   ├── test_stats.py           # 9 stats tests
│   ├── test_dashboard.py       # 7 dashboard contract tests
│   ├── test_health.py          # 5 health/metrics tests
│   └── test_persistence.py     # 2 persistence tests (pod restart)
├── docs/
│   └── architecture.md         # Full design doc with gap analysis
├── LICENSE                     # Apache 2.0
└── NOTICE                      # Third-party attributions
```

## Related Repos

| Repo | Purpose |
|------|---------|
| [headroom](https://github.com/chopratejas/headroom) | Upstream compression library (Apache 2.0) |
| [ai-gateway-payload-processing](https://github.com/yossiovadia/ai-gateway-payload-processing) branch `feat/headroom-on-metering` | BBR Go plugin |
| [ai-gateway-metering-service](https://github.com/noyitz/ai-gateway-metering-service) | MaaS dashboard (compression tab embedded) |
