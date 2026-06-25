# Migration Plan: Option E → Option A (Headroom Proxy Before MaaS)

## Why Migrate

Option E (BBR plugin calling `compress()`) works but reimplements features
headroom proxy ships natively. Every limitation we hit — no CCR, no image
compression, no MCP tools, custom stats/dashboard — is solved by running
headroom as a transparent proxy.

Option A puts headroom in its natural position: a proxy between the user
and the backend (in our case, MaaS). Headroom was designed for this. We
stop fighting its architecture and start using it.

## Architecture Comparison

### Current (Option E)
```
User → MaaS Gateway → BBR (headroom plugin → headroom service) → Provider
       (auth first)    (compress via API call)
```
- Headroom sees messages via `POST /v1/compress` — a utility endpoint
- BBR plugin is a Go shim that forwards messages and replaces them
- Custom Python service wraps `compress()` with stats, dashboard, persistence
- No CCR, no image compression, no MCP tools, no streaming awareness

### Target (Option A)
```
User → Headroom Proxy → MaaS Gateway → Provider
       (compress,         (auth,
        CCR,               metering,
        image,             rate limit,
        session tracking,  apikey inject)
        /dashboard,
        /stats,
        MCP tools)
```
- Headroom runs as designed — transparent proxy with full pipeline
- User points at headroom URL instead of MaaS URL
- Headroom forwards to MaaS, which handles auth/metering/injection
- All features available natively: CCR, image, MCP, dashboard, stats

## What Changes for Users

One environment variable:

```bash
# Before (Option E — user points at MaaS directly)
export ANTHROPIC_BASE_URL="https://maas.company.com/llm/ext-opus"

# After (Option A — user points at headroom, which forwards to MaaS)
export ANTHROPIC_BASE_URL="https://headroom.company.com"
```

Everything else stays the same: same API key, same model names, same tools.

## What Changes for Operators

| Aspect | Option E (current) | Option A (target) |
|--------|-------------------|-------------------|
| Headroom deployment | Custom Python service | `headroom proxy` binary (stock) |
| BBR plugin | Required (Go code in payload-processing) | Not needed — can be disabled |
| Dashboard | Custom HTML + nginx pod | Built into headroom proxy `/dashboard` |
| Stats persistence | Custom SQLite on PVC | Headroom's built-in storage (`store_url`) |
| Per-user tracking | Via `x-maas-username` header (auth pipeline issue) | Headroom reads API key or user header directly |
| Image compression | Not available | Built-in (requires `[image]` extra) |
| CCR retrieval | Not available | Built-in — LLM can retrieve compressed originals |
| MCP tools | Not available | Built-in — `headroom mcp serve` |
| Config | `headroom_service.py` + ipp-config | Environment variables only |
| Code to maintain | ~400 lines Python + Go plugin | Zero custom code |

## Risks and Concerns

### 1. User doesn't have MaaS authorization
**Concern:** If headroom sits before MaaS, what if the user's API key is invalid?

**Answer:** The request flows through headroom (compressed) to MaaS. MaaS validates
the API key via Kuadrant as it does today. If auth fails, MaaS returns 401/403 —
headroom passes the error back to the user. Headroom doesn't validate keys; it just
forwards them.

**Net effect:** Same auth behavior as today. MaaS is still the auth gate.

### 2. User doesn't have enough tokens / rate limited
**Concern:** Metering plugin checks balance before the request reaches the provider.
Does headroom before MaaS break this?

**Answer:** No. The request flows: User → Headroom → MaaS (metering check) → Provider.
The metering check still happens at MaaS. Headroom compresses the request BEFORE
metering sees it, which means metering counts COMPRESSED tokens (lower count = user's
balance lasts longer). This is actually better for users.

**Net effect:** Metering still works. Users get more requests per token budget because
input is compressed.

### 3. Per-user identification
**Concern:** We spent days debugging username flow in Option E. Does Option A have
the same problem?

**Answer:** Different but simpler. In Option A, headroom sees the raw request
including the API key. Headroom can be configured to read user identity from:
- A request header (if the user sets one)
- The API key itself (headroom can call a validation endpoint)
- Or the `x-forwarded-for` / source IP

For the MaaS flow, the API key is the user identifier. Headroom's built-in
per-user tracking can key on the API key hash — no auth pipeline dependency.
MaaS still identifies the user independently for metering.

**Net effect:** Simpler. No dependency on Kuadrant/AuthPolicy header injection.

### 4. Headroom becomes a single point of failure
**Concern:** If headroom is down, users can't reach MaaS at all.

**Answers:**
- Deploy headroom with multiple replicas (already doing this — 4 workers)
- Configure liveness/readiness probes (already doing this)
- DNS-based failover: if headroom is down, users can temporarily switch
  `ANTHROPIC_BASE_URL` back to MaaS directly (no compression, but works)
- Envoy-level failover: an Envoy route could try headroom first, fall back
  to MaaS direct if headroom returns 5xx. This requires an Envoy config
  but is a standard pattern.

**Net effect:** Manageable. Same reliability concern as any proxy. Standard
solutions exist.

### 5. Double network hop / latency
**Concern:** User → Headroom → MaaS → Provider is one more hop than
User → MaaS → Provider.

**Answer:** The extra hop is within the cluster (headroom and MaaS are both
in `openshift-ingress` namespace). Internal latency is <1ms. Compression
saves 3-10x more latency than it adds (smaller request = faster provider
processing). The current Option E also has an extra hop (BBR → headroom
service) so it's not a new cost.

**Net effect:** Negligible. Net positive due to smaller requests.

### 6. MaaS metering sees compressed tokens
**Concern:** Metering counts compressed input tokens. Cost reports will
show lower usage than what the user originally sent.

**Answer:** This is a FEATURE, not a bug. The user is actually sending
fewer tokens to the provider. Metering should reflect actual cost. If you
need "original token count" for billing, headroom can add a response header
with the pre-compression count that metering could capture separately.

**Net effect:** Metering is more accurate (reflects real provider cost).

### 7. What about the existing custom dashboard?
**Concern:** We built a custom dashboard with playground, insights, per-model
pricing. The headroom proxy's built-in dashboard is different.

**Answer:** The custom dashboard and playground are static HTML — they work
with any headroom service that exposes `/stats` and `/v1/compress`. In
Option A, the proxy exposes these endpoints natively. The dashboard can
remain as-is, just pointing at the proxy URL. Or we use headroom's built-in
`/dashboard` and embed the playground as a separate page.

**Net effect:** Dashboard migration is straightforward. Keep the playground.

### 8. Showstoppers?
None identified. Every concern above is manageable with standard infrastructure
patterns. The migration can be done incrementally with both options running
in parallel.

## Migration Plan

### Phase 0: Preparation (no user impact)
- [ ] Deploy headroom proxy alongside existing headroom-service
- [ ] Configure: `ANTHROPIC_TARGET_API_URL=https://maas.../llm/ext-opus`
- [ ] Verify proxy starts, `/readyz` healthy, `/dashboard` serves
- [ ] Create Route for headroom proxy (e.g., `headroom-proxy.apps.cluster.com`)
- [ ] Test with curl: send request through proxy → MaaS → provider → response
- [ ] Verify MaaS auth works (invalid key → 401)
- [ ] Verify metering works (usage event recorded)

### Phase 1: Parallel testing (no user impact)
- [ ] Disable headroom BBR plugin in ipp-config (remove the entry, restart BBR)
- [ ] Verify Claude Code works through MaaS directly (no compression — baseline)
- [ ] Point ONE test user at headroom proxy URL
- [ ] Verify: compression works, dashboard shows data, CCR available
- [ ] Test image compression (paste screenshot in Claude Code)
- [ ] Run A/B comparison: same session via MaaS direct vs via headroom proxy
- [ ] Measure: compression rate, cache hit impact, latency, error rate
- [ ] Run for 2-3 days, monitor for issues

### Phase 2: Pilot migration (select users)
- [ ] Move 3-5 pilot users to headroom proxy URL
- [ ] Monitor dashboard for per-user compression stats
- [ ] Collect user feedback: any quality issues? latency noticeable?
- [ ] Test emergency rollback: users switch back to MaaS URL directly
- [ ] Verify metering still tracks all users correctly
- [ ] Run for 1 week

### Phase 3: Full migration
- [ ] Move all users to headroom proxy URL
- [ ] Remove headroom BBR plugin from ipp-config
- [ ] Remove headroom-service deployment (Option E service)
- [ ] Keep headroom-dashboard deployment if custom dashboard preferred
- [ ] Update deploy script for Option A
- [ ] Update documentation

### Rollback at any phase
At any point, users can switch `ANTHROPIC_BASE_URL` back to the MaaS URL
directly. No deployment changes needed — just an env var. Compression stops
but everything else works.

## What We Keep

- **Tests** — adapt to test headroom proxy endpoints instead of custom service
- **Deploy script** — rewrite for proxy deployment (simpler: just env vars)
- **Dashboard/Playground** — can point at proxy's `/stats` and `/v1/compress`
- **Architecture doc** — update to reflect Option A
- **Benchmark script** — works against any headroom endpoint
- **Per-model pricing** — headroom proxy has its own cost tracking, or we
  keep the custom pricing endpoint as a sidecar

## What We Delete

- `service/headroom_service.py` — replaced by headroom proxy binary
- `service/Dockerfile` — replaced by stock headroom proxy image
- BBR headroom plugin (Go code) — no longer needed
- Custom SQLite stats code — headroom proxy has built-in persistence
- Per-user CompressionCache code — proxy handles session tracking natively

## Timeline

No rush. Option E works today. This migration happens when:
1. We're confident Option A works in parallel testing (Phase 1)
2. Users are comfortable with the URL change
3. We've verified all features work (CCR, image, MCP)

Estimated: 2-3 weeks from start to full migration, with rollback available
at every step.
