# Headroom Gateway — Session Status (June 29, 2026)

## Current Architecture: Option A (Proxy Before MaaS)

```
User → Headroom Proxy → MaaS Gateway → IPP → Provider
       (compress+CCR)    (auth+metering)
```

User sets: `ANTHROPIC_BASE_URL=https://headroom-service-openshift-ingress.apps.<cluster>`

## What's Running (sandbox311)

| Component | Name | Status |
|-----------|------|--------|
| Headroom proxy | `headroom-proxy` deployment | Running, CPU mode, 1 pod |
| Service + Route | `headroom-service` (points to proxy pods) | Active |
| Dashboard + Playground | `headroom-dashboard` deployment (nginx + reverse proxy) | Running |
| PVC | `headroom-proxy-data` (1Gi) at `/opt/app/.headroom` | Bound (CCR store + savings) |
| Option E service | `headroom-service` deployment | DELETED |
| IPP headroom plugin | Removed from ipp-config | Disabled |

## URLs

| URL | What |
|-----|------|
| `https://headroom-service-openshift-ingress.apps.ocp.nrt9w.sandbox311.opentlc.com` | Proxy (users point here) |
| `.../dashboard` | Built-in headroom dashboard |
| `.../stats` | Stats API |
| `https://headroom-dashboard-openshift-ingress.apps.ocp.nrt9w.sandbox311.opentlc.com` | Playground + CCR demo |
| `https://metering-dashboard-.../compression` | Noy's dashboard compression tab (iframe → playground) |

## Key: Service name = headroom-service

The proxy deployment is named `headroom-proxy` but the Service+Route are named `headroom-service`. This is intentional — Noy's dashboard auto-resolves `headroom-service-openshift-ingress.apps.<cluster>`.

## What Works

- All compression engines (SmartCrusher, Kompress ML, SearchCompressor, LogCompressor, DiffCompressor, HTMLExtractor, ImageCompressor)
- CCR enabled (`ccr_inject_tool: True`, `ccr_inject_marker: True`, SQLite on PVC)
- Built-in dashboard with cache hit tracking, agent usage, savings breakdown
- Persistent savings (`proxy_savings.json` on PVC)
- Per-model pricing via LiteLLM
- Streaming (Claude Code works normally)
- Playground with compression demo
- CCR live demo (requires API key)

## Known Issues

- **GPU**: CUDA provider init failing. CPU fallback active (~3s Kompress vs <100ms GPU)
- **Non-streaming empty body**: MaaS returns content-length:0 for non-streaming. Streaming works.
- **Intermittent 503s**: MaaS/Envoy occasionally returns HTML error pages. IPP logs show `invalid character '<'`. Not a headroom issue.
- **Per-user ID**: Proxy doesn't resolve API keys to usernames. Metering dashboard handles user tracking.

## Repos

| Repo | Purpose |
|------|---------|
| `yossiovadia/headroom-gateway` | Proxy Dockerfile, dashboard, deploy scripts, tests, docs |
| `yossiovadia/ai-gateway-payload-processing` branch `feat/headroom-on-metering` | Go IPP plugin (Option E, disabled) |
| `noyitz/ai-gateway-metering-service` | MaaS dashboard (compression tab) |
| `/private/tmp/headroom` | Upstream headroom (cloned for reference) |

## User Setup

```bash
export ANTHROPIC_BASE_URL="https://headroom-service-openshift-ingress.apps.ocp.nrt9w.sandbox311.opentlc.com"
export ANTHROPIC_API_KEY="sk-oai-..."
export NODE_TLS_REJECT_UNAUTHORIZED=0
unset CLAUDE_CODE_USE_VERTEX
unset ANTHROPIC_VERTEX_PROJECT_ID
claude --model claude-opus-4-8
```

## Deploy from Scratch

```bash
git clone https://github.com/yossiovadia/headroom-gateway.git
cd headroom-gateway
./scripts/deploy-proxy.sh --maas-url https://maas.<cluster>/llm/ext-opus
```

Prerequisites: oc logged in, MaaS gateway + IPP + metering deployed.
