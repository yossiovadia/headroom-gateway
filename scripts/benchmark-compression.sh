#!/bin/bash
# benchmark-compression.sh — Measure headroom compression latency and throughput
#
# Usage:
#   ./scripts/benchmark-compression.sh                              # default URL
#   HEADROOM_URL=https://headroom.example.com ./scripts/benchmark-compression.sh
#   ./scripts/benchmark-compression.sh --requests 20                # more requests

set -euo pipefail

HEADROOM_URL="${HEADROOM_URL:-https://headroom-service-openshift-ingress.apps.ocp.d4fcj.sandbox659.opentlc.com}"
NUM_REQUESTS=10

while [[ $# -gt 0 ]]; do
  case $1 in
    --requests) NUM_REQUESTS="$2"; shift 2 ;;
    *) shift ;;
  esac
done

echo "============================================"
echo "  Headroom Compression Benchmark"
echo "  URL:      $HEADROOM_URL"
echo "  Requests: $NUM_REQUESTS"
echo "============================================"
echo ""

# Check service is up
echo "=== Health check ==="
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "$HEADROOM_URL/readyz")
if [ "$HTTP_CODE" != "200" ]; then
  echo "FAIL: /readyz returned $HTTP_CODE"
  exit 1
fi
echo "OK"
echo ""

# Check GPU status from pod logs (if oc is available)
echo "=== Runtime detection ==="
if command -v oc &>/dev/null; then
  ORT=$(oc logs deploy/headroom-service -n openshift-ingress 2>/dev/null | grep -i "onnxruntime\|ExecutionProvider\|CUDA\|GPU\|PyTorch" | tail -3 || true)
  if [ -n "$ORT" ]; then
    echo "$ORT"
  else
    echo "No GPU/ONNX log lines found (likely CPU mode)"
  fi
else
  echo "oc not available, skipping runtime detection"
fi
echo ""

# Generate test payloads of different sizes
generate_payload() {
  local size=$1
  python3 -c "
import json
pods = [
    {'name': f'pod-{i}', 'ns': f'ns-{i%5}', 'status': 'Running',
     'ip': f'10.0.{i}.1', 'node': f'w-{i%3}', 'restarts': i%4,
     'age': f'{i}d', 'cpu': f'{i*5}m', 'mem': f'{64+i*8}Mi',
     'labels': {'app': f'a-{i%5}', 'v': f'{i%3}'}}
    for i in range($size)
]
msgs = [
    {'role': 'user', 'content': 'list pods'},
    {'role': 'assistant', 'content': None, 'tool_calls': [
        {'id': 'c1', 'type': 'function', 'function': {'name': 'kubectl', 'arguments': '{}'}}
    ]},
    {'role': 'tool', 'tool_call_id': 'c1', 'content': json.dumps(pods)},
    {'role': 'user', 'content': 'which are failing?'},
    {'role': 'assistant', 'content': 'checking...'},
    {'role': 'user', 'content': 'fix them'},
]
print(json.dumps({'messages': msgs, 'model': 'benchmark'}))
"
}

# Run benchmarks
echo "=== Benchmark: Small (5 items, ~200 tokens) ==="
SMALL_PAYLOAD=$(generate_payload 5)
SMALL_TIMES=()
for i in $(seq 1 "$NUM_REQUESTS"); do
  TIME=$(curl -sk -X POST "$HEADROOM_URL/v1/compress" \
    -H "Content-Type: application/json" \
    -H "x-maas-username: benchmark" \
    -d "$SMALL_PAYLOAD" \
    -w "%{time_total}" -o /tmp/bench_resp.json 2>&1)
  SMALL_TIMES+=("$TIME")
  printf "."
done
echo ""
SMALL_RESULT=$(python3 -c "
import json
with open('/tmp/bench_resp.json') as f: d=json.load(f)
print(f'  tokens: {d[\"tokens_before\"]} → {d[\"tokens_after\"]} (saved {d[\"tokens_saved\"]})')
")
echo "$SMALL_RESULT"
python3 -c "
times = [float(t) for t in '${SMALL_TIMES[*]}'.split()]
times.sort()
n = len(times)
print(f'  p50: {times[n//2]*1000:.0f}ms  p95: {times[int(n*0.95)]*1000:.0f}ms  p99: {times[min(int(n*0.99),n-1)]*1000:.0f}ms  avg: {sum(times)/n*1000:.0f}ms')
"
echo ""

echo "=== Benchmark: Medium (30 items, ~1500 tokens) ==="
MED_PAYLOAD=$(generate_payload 30)
MED_TIMES=()
for i in $(seq 1 "$NUM_REQUESTS"); do
  TIME=$(curl -sk -X POST "$HEADROOM_URL/v1/compress" \
    -H "Content-Type: application/json" \
    -H "x-maas-username: benchmark" \
    -d "$MED_PAYLOAD" \
    -w "%{time_total}" -o /tmp/bench_resp.json 2>&1)
  MED_TIMES+=("$TIME")
  printf "."
done
echo ""
MED_RESULT=$(python3 -c "
import json
with open('/tmp/bench_resp.json') as f: d=json.load(f)
print(f'  tokens: {d[\"tokens_before\"]} → {d[\"tokens_after\"]} (saved {d[\"tokens_saved\"]}, {round(d[\"tokens_saved\"]/d[\"tokens_before\"]*100,1) if d[\"tokens_before\"]>0 else 0}%)')
")
echo "$MED_RESULT"
python3 -c "
times = [float(t) for t in '${MED_TIMES[*]}'.split()]
times.sort()
n = len(times)
print(f'  p50: {times[n//2]*1000:.0f}ms  p95: {times[int(n*0.95)]*1000:.0f}ms  p99: {times[min(int(n*0.99),n-1)]*1000:.0f}ms  avg: {sum(times)/n*1000:.0f}ms')
"
echo ""

echo "=== Benchmark: Large (100 items, ~5000 tokens) ==="
LARGE_PAYLOAD=$(generate_payload 100)
LARGE_TIMES=()
for i in $(seq 1 "$NUM_REQUESTS"); do
  TIME=$(curl -sk -X POST "$HEADROOM_URL/v1/compress" \
    -H "Content-Type: application/json" \
    -H "x-maas-username: benchmark" \
    -d "$LARGE_PAYLOAD" \
    -w "%{time_total}" -o /tmp/bench_resp.json 2>&1)
  LARGE_TIMES+=("$TIME")
  printf "."
done
echo ""
LARGE_RESULT=$(python3 -c "
import json
with open('/tmp/bench_resp.json') as f: d=json.load(f)
print(f'  tokens: {d[\"tokens_before\"]} → {d[\"tokens_after\"]} (saved {d[\"tokens_saved\"]}, {round(d[\"tokens_saved\"]/d[\"tokens_before\"]*100,1) if d[\"tokens_before\"]>0 else 0}%)')
")
echo "$LARGE_RESULT"
python3 -c "
times = [float(t) for t in '${LARGE_TIMES[*]}'.split()]
times.sort()
n = len(times)
print(f'  p50: {times[n//2]*1000:.0f}ms  p95: {times[int(n*0.95)]*1000:.0f}ms  p99: {times[min(int(n*0.99),n-1)]*1000:.0f}ms  avg: {sum(times)/n*1000:.0f}ms')
"
echo ""

echo "=== Benchmark: Logs (50 lines, text — triggers Kompress ML) ==="
LOG_PAYLOAD=$(python3 -c "
import json
lines = []
for i in range(50):
    ts = f'2026-06-17T08:{i//60:02d}:{i%60:02d}Z'
    if i < 15:
        lines.append(f'{ts} [INFO] Installing package-{i}=={i}.0.{i}')
    elif i < 35:
        lines.append(f'{ts} [TEST] test_api_{[\"health\",\"auth\",\"users\",\"orders\",\"payments\"][i%5]}_{[\"list\",\"create\",\"update\",\"delete\"][i%4]} ... PASSED ({0.02+i*0.03:.2f}s)')
    else:
        lines.append(f'{ts} [BUILD] STEP {i-35+1}/15: Building layer {i}')
log_content = chr(10).join(lines)
msgs = [
    {'role': 'user', 'content': 'show logs'},
    {'role': 'assistant', 'content': None, 'tool_calls': [{'id': 'c1', 'type': 'function', 'function': {'name': 'logs', 'arguments': '{}'}}]},
    {'role': 'tool', 'tool_call_id': 'c1', 'content': log_content},
    {'role': 'user', 'content': 'any errors?'},
    {'role': 'assistant', 'content': 'no errors'},
    {'role': 'user', 'content': 'deploy'},
    {'role': 'assistant', 'content': 'deploying'},
    {'role': 'user', 'content': 'status?'},
]
print(json.dumps({'messages': msgs, 'model': 'benchmark-logs'}))
")
LOG_TIMES=()
for i in $(seq 1 "$NUM_REQUESTS"); do
  TIME=$(curl -sk -X POST "$HEADROOM_URL/v1/compress" \
    -H "Content-Type: application/json" \
    -H "x-maas-username: benchmark" \
    -d "$LOG_PAYLOAD" \
    -w "%{time_total}" -o /tmp/bench_resp.json 2>&1)
  LOG_TIMES+=("$TIME")
  printf "."
done
echo ""
LOG_RESULT=$(python3 -c "
import json
with open('/tmp/bench_resp.json') as f: d=json.load(f)
print(f'  tokens: {d[\"tokens_before\"]} → {d[\"tokens_after\"]} (saved {d[\"tokens_saved\"]}, {round(d[\"tokens_saved\"]/d[\"tokens_before\"]*100,1) if d[\"tokens_before\"]>0 else 0}%)')
")
echo "$LOG_RESULT"
python3 -c "
times = [float(t) for t in '${LOG_TIMES[*]}'.split()]
times.sort()
n = len(times)
print(f'  p50: {times[n//2]*1000:.0f}ms  p95: {times[int(n*0.95)]*1000:.0f}ms  p99: {times[min(int(n*0.99),n-1)]*1000:.0f}ms  avg: {sum(times)/n*1000:.0f}ms')
"
echo ""

echo "=== Reference baselines ==="
echo "  CPU (onnxruntime):     SmartCrusher <50ms, Kompress ~3s"
echo "  GPU (onnxruntime-gpu): SmartCrusher <50ms, Kompress <100ms"
echo ""
echo "  Note: JSON array payloads primarily use SmartCrusher (instant)."
echo "  Kompress ML fires on text/log content. To benchmark Kompress,"
echo "  send tool outputs with log lines or prose instead of JSON arrays."
echo "============================================"
