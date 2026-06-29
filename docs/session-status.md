# Headroom Gateway — Session Status (June 29, 2026)

## Current State: Option A Deployed (Proxy Before MaaS)

We migrated from Option E (BBR/IPP plugin calling custom Python service) to Option A
(headroom proxy as transparent proxy before MaaS). Option A is live on sandbox311.

### What's Running

| Component | Status | URL |
|-----------|--------|-----|
| **headroom-proxy** (Option A) | Running, 1 pod, CPU mode | `https://headroom-proxy-openshift-ingress.apps.ocp.nrt9w.sandbox311.opentlc.com` |
| **headroom-proxy /dashboard** | Built-in headroom dashboard | `https://headroom-proxy-.../dashboard` |
| **headroom-dashboard** (custom) | Running, has Playground tab | `https://headroom-dashboard-openshift-ingress.apps.ocp.nrt9w.sandbox311.opentlc.com/?url=https://headroom-proxy-...` |
| **headroom-service** (Option E) | Scaled to 0 | Was the custom Python service, no longer needed |
| **IPP headroom plugin** | Disabled | Removed from ipp-config, IPP restarted |
| **Metering dashboard** | Running, has Compression tab (iframe) | `https://metering-dashboard-openshift-ingress.apps.ocp.nrt9w.sandbox311.opentlc.com/compression` |

### Cluster

- **Cluster:** sandbox311 (`api.ocp.nrt9w.sandbox311.opentlc.com`)
- **Namespace:** openshift-ingress
- **GPU:** NVIDIA L4 (23GB) — allocated to headroom-proxy but CUDA provider init failing (CPU fallback active)
- **PVCs:** `headroom-proxy-data` (1Gi, mounted at `/opt/app/.headroom` — CCR store + savings persistence), `headroom-stats` (1Gi, from Option E, unused)

### User Setup (Option A)

```bash
export ANTHROPIC_BASE_URL="https://headroom-proxy-openshift-ingress.apps.ocp.nrt9w.sandbox311.opentlc.com"
export ANTHROPIC_API_KEY="sk-oai-t5EzCrkazNHUzHru_KzkcIxOcMU7Cbdu8vgM1ln99v4FHkeFsaUFav6THoqR"
export NODE_TLS_REJECT_UNAUTHORIZED=0
unset CLAUDE_CODE_USE_VERTEX
unset ANTHROPIC_VERTEX_PROJECT_ID
claude --model claude-opus-4-8
```

### Architecture

```
User → Headroom Proxy → MaaS Gateway → IPP (metering, model-resolver, api-translation, apikey-injection) → Provider
       ↑ compresses      ↑ auth/metering
       ↑ CCR store        
       ↑ /dashboard
       ↑ session tracking
```

Headroom forwards to: `ANTHROPIC_TARGET_API_URL=https://maas.apps.ocp.nrt9w.sandbox311.opentlc.com/llm/ext-opus`

## What Works

- **Compression:** SmartCrusher (JSON 60-74%), Kompress ML (text 10-35%), LogCompressor, SearchCompressor, DiffCompressor, HTMLExtractor — all active on CPU
- **CCR (Compress-Cache-Retrieve):** Enabled (`ccr_inject_tool: True`). Proxy injects `headroom_retrieve` tool, stores originals in SQLite on PVC, handles retrieval automatically. 1 entry confirmed in store.
- **Built-in dashboard:** `/dashboard` shows compression stats, cache hits, agent usage, savings breakdown, throughput
- **Persistent savings:** `proxy_savings.json` on PVC — lifetime stats survive pod restarts
- **Cache tracking:** 85% cache hit rate observed, $2.20 cache savings shown in dashboard
- **Per-model pricing:** Via LiteLLM's pricing database (Opus $5/MTok, Haiku $1/MTok, Sonnet $6/MTok)
- **Streaming:** Claude Code works normally through proxy
- **Image passthrough:** Images flow through to MaaS/provider without issues
- **MaaS auth:** API key forwarded as-is, MaaS validates via Kuadrant

## Known Issues

### GPU not active
`onnxruntime-gpu` installed but `CUDAExecutionProvider` fails to initialize. All CUDA libs load individually (`libcudart.so.13`, `libcudnn.so.9`, `libcublasLt.so.13`) but onnxruntime doesn't register CUDA. Kompress ML runs on CPU (~3s instead of <100ms). Follow-up task.

### Non-streaming responses return empty body
MaaS returns `content-length: 0` for non-streaming requests. Streaming works fine. Likely IPP response handler consuming the body. Only affects curl tests — Claude Code uses streaming. Not a headroom issue.

### Per-user identification
Headroom proxy doesn't identify users by name. It sees API keys but doesn't resolve them to usernames. The metering dashboard (Noy's) handles per-user tracking via Kuadrant auth. For headroom's dashboard, users show by API key hash. Acceptable for pilot — metering dashboard has the user data.

### Output Shaper not applicable
`HEADROOM_OUTPUT_SHAPER` is a client-side feature requiring `headroom learn` on user's local machine. Not applicable to centralized deployment. Env var removed.

## Repos

| Repo | Branch | Purpose |
|------|--------|---------|
| [yossiovadia/headroom-gateway](https://github.com/yossiovadia/headroom-gateway) | main | Service, dashboard, deploy scripts, tests, docs |
| [yossiovadia/ai-gateway-payload-processing](https://github.com/yossiovadia/ai-gateway-payload-processing) | feat/headroom-on-metering | Go IPP plugin (Option E, currently disabled) |
| [noyitz/ai-gateway-metering-service](https://github.com/noyitz/ai-gateway-metering-service) | main | MaaS dashboard with compression tab |
| [chopratejas/headroom](https://github.com/chopratejas/headroom) | — | Upstream headroom library (cloned at /private/tmp/headroom) |

## Key Files

| File | Purpose |
|------|---------|
| `service/Dockerfile.proxy` | Option A image — headroom proxy with GPU + image support |
| `service/Dockerfile` | Option E image — custom Python service (legacy) |
| `service/headroom_service.py` | Option E service code (legacy) |
| `dashboard/index.html` | Custom dashboard with Playground tab |
| `scripts/deploy-proxy.sh` | Deploy Option A proxy |
| `scripts/deploy-headroom.sh` | Deploy Option E service (legacy) |
| `docs/architecture.md` | Design doc (still describes Option E — needs update for Option A) |
| `docs/option-a-migration-plan.md` | Migration plan with phases and risk analysis |

## Compression Engines

| Engine | Active | Triggers On |
|--------|--------|-------------|
| SmartCrusher | YES | JSON arrays (`[{...}, {...}]`) |
| Kompress ML | YES | Free text, prose, documentation |
| SearchCompressor | YES | Grep/ripgrep results |
| LogCompressor | YES | Build logs, test output with timestamps |
| DiffCompressor | YES | Git diffs (unified format) |
| HTMLExtractor | YES | HTML content |
| CodeAwareCompressor | NO | Disabled by headroom upstream |
| ImageCompressor | Available | Images (requires `[image]` extra, installed) |

## Content Protection

Read/Write/Edit/Grep/Glob tool outputs are excluded by default. ReadLifecycle catches stale reads (67%) and superseded reads (12%). Fresh reads (20%) stay verbatim. With CCR now available in Option A, this exclusion is less critical — the LLM can retrieve originals.

## What Changed from Option E to Option A

| Aspect | Option E (disabled) | Option A (active) |
|--------|--------------------|--------------------|
| How headroom runs | Custom Python wrapping `compress()` | Stock `headroom proxy` binary |
| CCR | Not available | Available — tool injection + retrieval |
| Image compression | Not available | Available |
| Dashboard | Custom HTML + nginx | Built-in `/dashboard` + custom playground |
| Stats persistence | Custom SQLite on PVC | `proxy_savings.json` on PVC (lifetime stats) |
| Session stats | Per-request in DB | Session-scoped (resets on restart, lifetime persists) |
| Custom code | ~400 lines Python + Go plugin | Zero |
| GPU | Was working (CUDA) | Broken (follow-up) |

## Next Steps / Open Items

1. **CCR demo** — build a visual demo page showing CCR in action (compress → markers → retrieve original)
2. **GPU fix** — debug CUDA provider initialization in Dockerfile.proxy
3. **Architecture doc update** — update docs/architecture.md for Option A
4. **Playground integration** — make playground accessible from proxy dashboard or add CCR demo
5. **Test suite update** — adapt tests for Option A proxy endpoints
6. **Option E cleanup** — once Option A is proven, delete legacy service code and PVC
