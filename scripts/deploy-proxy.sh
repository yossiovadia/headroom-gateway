#!/bin/bash
# deploy-proxy.sh — Deploy headroom proxy (Option A) alongside existing setup
#
# This deploys a SEPARATE headroom proxy that runs as a transparent proxy
# before MaaS. It does NOT touch the existing headroom-service (Option E).
#
# Prerequisites:
#   - oc logged in
#   - MaaS gateway deployed and accessible
#
# Usage:
#   ./scripts/deploy-proxy.sh
#   ./scripts/deploy-proxy.sh --hf-token hf_xxx

set -euo pipefail

NAMESPACE="openshift-ingress"
HF_TOKEN="${HF_TOKEN:-}"
MAAS_URL="${MAAS_URL:-https://maas.apps.ocp.nrt9w.sandbox311.opentlc.com/llm/ext-opus}"

while [[ $# -gt 0 ]]; do
  case $1 in
    -n) NAMESPACE="$2"; shift 2 ;;
    --hf-token) HF_TOKEN="$2"; shift 2 ;;
    --maas-url) MAAS_URL="$2"; shift 2 ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# --- Preflight ---
echo "=== Preflight ==="

if ! oc whoami &>/dev/null; then
  echo "FAIL: not logged into OpenShift"
  exit 1
fi
echo "  oc: $(oc whoami)"

if ! oc get namespace "$NAMESPACE" &>/dev/null; then
  echo "FAIL: namespace '$NAMESPACE' does not exist"
  exit 1
fi
echo "  namespace: $NAMESPACE"

# Verify MaaS is reachable
MAAS_STATUS=$(curl -sk -o /dev/null -w "%{http_code}" "$MAAS_URL/v1/messages" -X POST -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "000")
if [ "$MAAS_STATUS" = "000" ]; then
  echo "  WARN: MaaS not reachable at $MAAS_URL (may work from inside cluster)"
else
  echo "  MaaS: reachable (HTTP $MAAS_STATUS)"
fi

echo ""
echo "============================================"
echo "  Headroom Proxy (Option A) Deployment"
echo "  Namespace: $NAMESPACE"
echo "  MaaS URL:  $MAAS_URL"
echo "============================================"
echo ""

# Step 1: Build image
echo "=== Step 1: Build headroom-proxy image ==="
oc new-build --binary --strategy=docker --name=headroom-proxy -n "$NAMESPACE" 2>/dev/null || true

# Create temp build context with Dockerfile.proxy as Dockerfile
BUILD_DIR=$(mktemp -d)
cp "$REPO_DIR/service/Dockerfile.proxy" "$BUILD_DIR/Dockerfile"
trap "rm -rf $BUILD_DIR" EXIT

oc start-build headroom-proxy -n "$NAMESPACE" \
  --from-dir="$BUILD_DIR" --follow
echo ""

# Step 2: Deploy
echo "=== Step 2: Deploy headroom-proxy ==="
oc apply -n "$NAMESPACE" -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: headroom-proxy
  labels:
    app: headroom-proxy
spec:
  replicas: 1
  selector:
    matchLabels:
      app: headroom-proxy
  template:
    metadata:
      labels:
        app: headroom-proxy
    spec:
      containers:
      - name: headroom
        image: image-registry.openshift-image-registry.svc:5000/$NAMESPACE/headroom-proxy:latest
        imagePullPolicy: Always
        ports:
        - containerPort: 8787
        env:
        - name: ANTHROPIC_TARGET_API_URL
          value: "$MAAS_URL"
        - name: HEADROOM_HOST
          value: "0.0.0.0"
        - name: HEADROOM_PORT
          value: "8787"
        - name: HEADROOM_SKIP_UPSTREAM_CHECK
          value: "1"
        - name: HEADROOM_MODE
          value: "token"
        - name: HEADROOM_TELEMETRY
          value: "off"
        - name: HEADROOM_COMPRESSION_STABLE_AFTER_TURN
          value: "1"
        - name: HEADROOM_STALE_READ_COMPRESS_AFTER_TURNS
          value: "1"
        resources:
          requests:
            cpu: "4"
            memory: 4Gi
          limits:
            cpu: "8"
            memory: 8Gi
        livenessProbe:
          httpGet:
            path: /livez
            port: 8787
          initialDelaySeconds: 60
          periodSeconds: 30
        readinessProbe:
          httpGet:
            path: /readyz
            port: 8787
          initialDelaySeconds: 30
          periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: headroom-proxy
spec:
  ports:
  - port: 8787
  selector:
    app: headroom-proxy
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: headroom-proxy
spec:
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
  to:
    kind: Service
    name: headroom-proxy
  port:
    targetPort: 8787
EOF
echo ""

# Step 3: Wait
echo "=== Step 3: Wait for rollout ==="
oc rollout status deployment/headroom-proxy -n "$NAMESPACE" --timeout=180s
echo ""

# Step 4: Smoke test
echo "=== Step 4: Smoke test ==="
PROXY_HOST=$(oc get route headroom-proxy -n "$NAMESPACE" -o jsonpath='{.spec.host}')

echo "Readiness:"
curl -sk "https://$PROXY_HOST/readyz" | python3 -m json.tool 2>/dev/null || echo "  readyz not available yet"

echo ""
echo "Dashboard:"
DASH_STATUS=$(curl -sk -o /dev/null -w "%{http_code}" "https://$PROXY_HOST/dashboard")
echo "  HTTP $DASH_STATUS"

echo ""
echo "============================================"
echo "  Headroom Proxy deployed!"
echo ""
echo "  Proxy URL:  https://$PROXY_HOST"
echo "  Dashboard:  https://$PROXY_HOST/dashboard"
echo "  Stats:      https://$PROXY_HOST/stats"
echo ""
echo "  Test with Claude Code:"
echo "    export ANTHROPIC_BASE_URL=https://$PROXY_HOST"
echo "    export ANTHROPIC_API_KEY=<MaaS-key>"
echo "    export NODE_TLS_REJECT_UNAUTHORIZED=0"
echo "    claude --model claude-opus-4-8"
echo ""
echo "  Option E (headroom-service) is still running."
echo "  This is a parallel deployment — no user impact."
echo "============================================"
