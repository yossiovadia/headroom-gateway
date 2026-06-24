#!/usr/bin/env python3
"""A/B test: measure Anthropic KV cache hit rates with and without headroom.

Sends the same growing conversation to two endpoints:
  A) Direct to Anthropic (no headroom)
  B) Through MaaS + headroom pipeline

Each turn adds a large tool output, simulating a real coding session.
After N turns, compares cache hit rates and costs.

Usage:
  # Set your keys
  export ANTHROPIC_API_KEY="sk-ant-..."           # Direct Anthropic key
  export MAAS_API_KEY="sk-oai-..."                 # MaaS API key
  export MAAS_URL="https://maas.apps.ocp.nrt9w.sandbox311.opentlc.com/llm/ext-opus"

  # Run (takes ~2-3 minutes)
  python3 scripts/ab-cache-test.py

  # Or with custom turns
  python3 scripts/ab-cache-test.py --turns 10
"""

import argparse
import json
import os
import ssl
import sys
import time
import urllib.request
from datetime import datetime

# Simulated tool outputs — realistic coding session content
TOOL_OUTPUTS = [
    # Turn 1: pip list output (JSON-like, SmartCrusher territory)
    "\n".join([f"package-{i}=={i}.{i%10}.{i%5}  (from requirements.txt)" for i in range(60)]),

    # Turn 2: test output (log-like, SearchCompressor territory)
    "\n".join([
        f"2026-06-24T{10+i//60:02d}:{i%60:02d}:00Z [{'PASS' if i != 37 else 'FAIL'}] test_{['auth','users','orders','payments','search','cache','metrics','rate','notify','health'][i%10]}_{['create','read','update','delete','list'][i%5]} ({0.02+i*0.03:.2f}s)"
        for i in range(50)
    ]),

    # Turn 3: file content (code, Kompress territory)
    "\n".join([
        f"def process_{i}(data, config=None, timeout=30):",
        f"    \"\"\"Process item {i} with validation.\"\"\"",
        f"    if data is None:",
        f"        raise ValueError('data required for process_{i}')",
        f"    result = transform(data, step={i})",
        f"    logger.info(f'process_{i} completed: {{result}}')",
        f"    return {{'value': result, 'step': {i}, 'status': 'ok'}}",
        ""
    ] for i in range(30)),

    # Turn 4: kubectl output (JSON, SmartCrusher territory)
    json.dumps([
        {"name": f"pod-{i}", "namespace": f"ns-{i%5}", "status": "Running",
         "ip": f"10.0.{i}.1", "node": f"worker-{i%3}", "restarts": i % 4,
         "cpu": f"{i*5}m", "memory": f"{64+i*8}Mi",
         "labels": {"app": f"app-{i%5}", "version": f"v{i%3}.{i%10}"}}
        for i in range(40)
    ], indent=2),

    # Turn 5: log file (text, Kompress territory)
    "\n".join([
        f"2026-06-24T{8+i//3600:02d}:{(i//60)%60:02d}:{i%60:02d}Z [{['INFO','DEBUG','WARN','INFO','INFO'][i%5]}] "
        f"Request {i}: method={'GET' if i%3==0 else 'POST'} path=/api/v1/{'users' if i%4==0 else 'orders'}/{i} "
        f"status={200 if i%7!=0 else 500} latency={10+i%100}ms client={f'10.0.{i%10}.{i%20}'}"
        for i in range(80)
    ]),

    # Turn 6: more code
    "\n".join([
        f"class Handler{i}(BaseHandler):",
        f"    def __init__(self, config):",
        f"        super().__init__(config)",
        f"        self.timeout = config.get('timeout', {30+i})",
        f"    ",
        f"    async def handle(self, request):",
        f"        data = await request.json()",
        f"        result = await self.process(data)",
        f"        return Response(json.dumps(result), status=200)",
        f"    ",
        f"    async def process(self, data):",
        f"        validated = self.validate(data)",
        f"        transformed = self.transform(validated)",
        f"        return {{'handler': 'Handler{i}', 'result': transformed}}",
        ""
    ] for i in range(20)),

    # Turn 7: API response (JSON)
    json.dumps({
        "results": [
            {"id": i, "title": f"Document {i}: {'Configuration' if i%3==0 else 'Architecture' if i%3==1 else 'Deployment'} Guide",
             "snippet": f"This document covers the {'setup' if i%2==0 else 'advanced'} configuration of component {i%5} "
                        f"including {'networking' if i%4==0 else 'storage' if i%4==1 else 'security' if i%4==2 else 'monitoring'} aspects.",
             "score": round(0.95 - i * 0.02, 3), "url": f"https://docs.example.com/guide-{i}"}
            for i in range(30)
        ],
        "total": 2847, "query": "deployment configuration guide"
    }, indent=2),
]

# Flatten nested lists
TOOL_OUTPUTS = [t if isinstance(t, str) else "\n".join(t) if isinstance(t, list) else str(t) for t in TOOL_OUTPUTS]


def send_request(url, headers, messages, max_tokens=20):
    """Send a request and return usage info."""
    body = json.dumps({
        "model": "claude-opus-4-8",
        "max_tokens": max_tokens,
        "messages": messages,
    }).encode()

    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        t0 = time.time()
        resp = urllib.request.urlopen(req, context=ctx, timeout=60)
        latency = time.time() - t0
        data = json.loads(resp.read())
        usage = data.get("usage", {})
        return {
            "input_tokens": usage.get("input_tokens", 0),
            "cache_creation": usage.get("cache_creation_input_tokens", 0),
            "cache_read": usage.get("cache_read_input_tokens", 0),
            "output_tokens": usage.get("output_tokens", 0),
            "latency_ms": round(latency * 1000),
            "error": None,
        }
    except Exception as e:
        return {"input_tokens": 0, "cache_creation": 0, "cache_read": 0,
                "output_tokens": 0, "latency_ms": 0, "error": str(e)[:100]}


def run_session(label, url, headers, num_turns):
    """Run a multi-turn session and collect cache stats."""
    messages = []
    results = []

    print(f"\n{'='*60}")
    print(f"  {label}")
    print(f"  URL: {url[:60]}...")
    print(f"  Turns: {num_turns}")
    print(f"{'='*60}")
    print(f"{'Turn':>4}  {'Input':>8}  {'Cached':>8}  {'Created':>8}  {'Cache%':>7}  {'Latency':>8}  Status")
    print(f"{'-'*4}  {'-'*8}  {'-'*8}  {'-'*8}  {'-'*7}  {'-'*8}  {'-'*10}")

    for turn in range(num_turns):
        # User asks something
        messages.append({"role": "user", "content": f"analyze the output from tool {turn + 1}"})

        # Assistant calls a tool
        messages.append({
            "role": "assistant",
            "content": None,
            "tool_calls": [{"id": f"call_{turn}", "type": "function",
                           "function": {"name": f"tool_{turn}", "arguments": "{}"}}]
        })

        # Tool returns large output
        tool_output = TOOL_OUTPUTS[turn % len(TOOL_OUTPUTS)]
        messages.append({
            "role": "tool",
            "tool_call_id": f"call_{turn}",
            "content": tool_output,
        })

        # User asks follow-up
        messages.append({"role": "user", "content": f"what are the key findings from tool {turn + 1}?"})

        # Send request
        r = send_request(url, headers, messages)
        results.append(r)

        total = r["input_tokens"] + r["cache_creation"] + r["cache_read"]
        cache_pct = round(r["cache_read"] / total * 100, 1) if total > 0 else 0

        status = "OK" if not r["error"] else f"ERR: {r['error'][:30]}"
        print(f"{turn+1:>4}  {r['input_tokens']:>8,}  {r['cache_read']:>8,}  {r['cache_creation']:>8,}  {cache_pct:>6.1f}%  {r['latency_ms']:>6}ms  {status}")

        # Add assistant response to conversation
        messages.append({"role": "assistant", "content": f"Analysis of tool {turn + 1} output complete."})

        # Small delay to not hit rate limits
        time.sleep(1)

    return results


def print_summary(label, results):
    """Print summary stats for a session."""
    valid = [r for r in results if not r["error"]]
    if not valid:
        print(f"\n{label}: ALL REQUESTS FAILED")
        return

    total_input = sum(r["input_tokens"] for r in valid)
    total_cached = sum(r["cache_read"] for r in valid)
    total_created = sum(r["cache_creation"] for r in valid)
    total_all = total_input + total_cached + total_created

    cache_pct = round(total_cached / total_all * 100, 1) if total_all > 0 else 0

    # Cost calculation (Anthropic Opus pricing)
    cost_uncached = total_all * 15.0 / 1_000_000  # all at full price
    cost_actual = (total_input * 15.0 + total_cached * 1.88 + total_created * 18.75) / 1_000_000
    cost_saved = cost_uncached - cost_actual

    print(f"\n--- {label} Summary ---")
    print(f"  Requests:       {len(valid)}")
    print(f"  New tokens:     {total_input:,}")
    print(f"  Cached tokens:  {total_cached:,}")
    print(f"  Created tokens: {total_created:,}")
    print(f"  Cache hit rate: {cache_pct}%")
    print(f"  Cost (all uncached): ${cost_uncached:.4f}")
    print(f"  Cost (with cache):   ${cost_actual:.4f}")
    print(f"  Cache savings:       ${cost_saved:.4f}")
    print(f"  Avg latency:    {sum(r['latency_ms'] for r in valid) // len(valid)}ms")

    return {
        "label": label,
        "requests": len(valid),
        "total_tokens": total_all,
        "cached_tokens": total_cached,
        "cache_pct": cache_pct,
        "cost_uncached": cost_uncached,
        "cost_actual": cost_actual,
        "cache_savings": cost_saved,
    }


def main():
    parser = argparse.ArgumentParser(description="A/B cache hit test: headroom vs direct")
    parser.add_argument("--turns", type=int, default=7, help="Number of conversation turns (default: 7)")
    parser.add_argument("--skip-direct", action="store_true", help="Skip direct Anthropic test (MaaS only)")
    parser.add_argument("--skip-maas", action="store_true", help="Skip MaaS test (direct only)")
    args = parser.parse_args()

    anthropic_key = os.environ.get("ANTHROPIC_API_KEY", "")
    maas_key = os.environ.get("MAAS_API_KEY", "")
    maas_url = os.environ.get("MAAS_URL", "https://maas.apps.ocp.nrt9w.sandbox311.opentlc.com/llm/ext-opus")

    results = {}

    # Test A: Direct to Anthropic (no headroom)
    if not args.skip_direct:
        if not anthropic_key:
            print("SKIP: ANTHROPIC_API_KEY not set (direct Anthropic test)")
        else:
            a_results = run_session(
                "A) Direct to Anthropic (no headroom)",
                "https://api.anthropic.com/v1/messages",
                {
                    "Content-Type": "application/json",
                    "x-api-key": anthropic_key,
                    "anthropic-version": "2023-06-01",
                },
                args.turns,
            )
            results["direct"] = print_summary("Direct (no headroom)", a_results)

    # Test B: Through MaaS + headroom
    if not args.skip_maas:
        if not maas_key:
            print("SKIP: MAAS_API_KEY not set (MaaS + headroom test)")
        else:
            b_results = run_session(
                "B) Through MaaS + headroom",
                f"{maas_url}/v1/messages",
                {
                    "Content-Type": "application/json",
                    "x-api-key": maas_key,
                    "anthropic-version": "2023-06-01",
                },
                args.turns,
            )
            results["maas"] = print_summary("MaaS + headroom", b_results)

    # Comparison
    if "direct" in results and "maas" in results and results["direct"] and results["maas"]:
        d, m = results["direct"], results["maas"]
        print(f"\n{'='*60}")
        print(f"  A/B COMPARISON")
        print(f"{'='*60}")
        print(f"  {'':25s} {'Direct':>12s}  {'MaaS+Headroom':>14s}  {'Delta':>10s}")
        print(f"  {'Cache hit rate':25s} {d['cache_pct']:>11.1f}%  {m['cache_pct']:>13.1f}%  {m['cache_pct']-d['cache_pct']:>+9.1f}%")
        print(f"  {'Cached tokens':25s} {d['cached_tokens']:>12,}  {m['cached_tokens']:>14,}  {m['cached_tokens']-d['cached_tokens']:>+10,}")
        print(f"  {'Cache $ savings':25s} ${d['cache_savings']:>10.4f}  ${m['cache_savings']:>12.4f}  ${m['cache_savings']-d['cache_savings']:>+8.4f}")
        print(f"  {'Total cost':25s} ${d['cost_actual']:>10.4f}  ${m['cost_actual']:>12.4f}  ${m['cost_actual']-d['cost_actual']:>+8.4f}")
        print()
        if m["cache_pct"] > d["cache_pct"]:
            print(f"  → Headroom IMPROVED cache hits by {m['cache_pct']-d['cache_pct']:.1f} percentage points")
        elif m["cache_pct"] < d["cache_pct"]:
            print(f"  → Headroom REDUCED cache hits by {d['cache_pct']-m['cache_pct']:.1f} percentage points")
        else:
            print(f"  → Cache hit rates are IDENTICAL (headroom has no cache impact)")

    # Save raw results
    output_file = "/tmp/ab-cache-results.json"
    with open(output_file, "w") as f:
        json.dump({"timestamp": datetime.now().isoformat(), "turns": args.turns, "results": results}, f, indent=2)
    print(f"\n  Raw results saved to {output_file}")


if __name__ == "__main__":
    main()
