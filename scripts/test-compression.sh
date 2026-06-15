#!/bin/bash
# test-compression.sh — Test headroom compression (locally or against a deployed instance)
#
# Usage:
#   ./scripts/test-compression.sh                        # test local (localhost:8787)
#   HEADROOM_URL=https://headroom.apps.company.com ./scripts/test-compression.sh

set -euo pipefail

HEADROOM_URL="${HEADROOM_URL:-http://localhost:8787}"

echo "============================================"
echo "  Headroom Compression Test"
echo "  Target: $HEADROOM_URL"
echo "============================================"
echo ""

# Check health
echo "=== Health Check ==="
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "$HEADROOM_URL/readyz" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" != "200" ]; then
    echo "FAIL: headroom not reachable at $HEADROOM_URL (HTTP $HTTP_CODE)"
    exit 1
fi
echo "OK (HTTP $HTTP_CODE)"
echo ""

# Check stats endpoint
echo "=== Stats ==="
curl -sk "$HEADROOM_URL/stats" 2>/dev/null | python3 -m json.tool 2>/dev/null | head -20
echo ""

# Check metrics endpoint
echo "=== Prometheus Metrics (sample) ==="
curl -sk "$HEADROOM_URL/metrics" 2>/dev/null | grep -E "headroom_tokens|headroom_requests|headroom_compression" | head -10
echo ""

echo "=== Compression Test ==="
echo "Sending a test request with tool output..."

# Send a request with tool output through the proxy
RESPONSE=$(curl -sk -X POST "$HEADROOM_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer test-key" \
    -d '{
        "model": "claude-opus-4-6",
        "max_tokens": 10,
        "messages": [
            {"role": "user", "content": "list items"},
            {"role": "assistant", "content": null, "tool_calls": [{"id": "c1", "type": "function", "function": {"name": "list", "arguments": "{}"}}]},
            {"role": "tool", "tool_call_id": "c1", "content": "[{\"id\":0,\"name\":\"Item 0\",\"desc\":\"Description for item 0 with detailed metadata\"},{\"id\":1,\"name\":\"Item 1\",\"desc\":\"Description for item 1 with detailed metadata\"},{\"id\":2,\"name\":\"Item 2\",\"desc\":\"Description for item 2 with detailed metadata\"},{\"id\":3,\"name\":\"Item 3\",\"desc\":\"Description for item 3 with detailed metadata\"},{\"id\":4,\"name\":\"Item 4\",\"desc\":\"Description for item 4 with detailed metadata\"}]"},
            {"role": "user", "content": "summarize"}
        ]
    }' 2>&1)

echo "Response (first 200 chars):"
echo "$RESPONSE" | head -c 200
echo ""
echo ""

# Check stats after the request
echo "=== Updated Stats ==="
curl -sk "$HEADROOM_URL/stats" 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print('Total requests:', d.get('total_requests', 'N/A'))
    print('Tokens saved:', d.get('total_tokens_saved', 'N/A'))
    print('Savings percent:', d.get('savings_percent', 'N/A'))
except:
    print('(stats not available in expected format)')
" 2>&1

echo ""
echo "============================================"
echo "  Done. Check $HEADROOM_URL/stats for details."
echo "============================================"
