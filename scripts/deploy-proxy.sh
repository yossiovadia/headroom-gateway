#!/bin/bash
# deploy-proxy.sh — Deploy headroom proxy (Option A: transparent proxy before MaaS)
#
# Idempotent — safe to run multiple times. Skips image build if source unchanged.
#
# Prerequisites:
#   - oc logged into the target OpenShift cluster
#   - MaaS gateway deployed and accessible
#
# Usage:
#   ./scripts/deploy-proxy.sh                                    # deploy to openshift-ingress
#   ./scripts/deploy-proxy.sh -n my-namespace                    # specific namespace
#   ./scripts/deploy-proxy.sh --maas-url https://maas.../llm/ext-opus  # custom MaaS URL
#   ./scripts/deploy-proxy.sh --hf-token hf_xxx                  # faster model download
#   ./scripts/deploy-proxy.sh --force-build                      # rebuild even if unchanged

set -euo pipefail

NAMESPACE="openshift-ingress"
HF_TOKEN="${HF_TOKEN:-}"
MAAS_URL="${MAAS_URL:-}"
FORCE_BUILD=false

while [[ $# -gt 0 ]]; do
  case $1 in
    -n) NAMESPACE="$2"; shift 2 ;;
    --hf-token) HF_TOKEN="$2"; shift 2 ;;
    --maas-url) MAAS_URL="$2"; shift 2 ;;
    --force-build) FORCE_BUILD=true; shift ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# --- Preflight checks ---
echo "=== Preflight checks ==="

if ! command -v oc &>/dev/null; then
  echo "FAIL: oc CLI not found"
  exit 1
fi

if ! oc whoami &>/dev/null; then
  echo "FAIL: not logged into OpenShift. Run: oc login --server=<cluster-url>"
  exit 1
fi
echo "  oc logged in as: $(oc whoami)"

if ! oc get namespace "$NAMESPACE" &>/dev/null; then
  echo "FAIL: namespace '$NAMESPACE' does not exist"
  exit 1
fi
echo "  namespace: $NAMESPACE"

# Check MaaS gateway
if [ -z "$MAAS_URL" ]; then
  # Auto-detect from cluster
  CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "")
  if [ -n "$CLUSTER_DOMAIN" ]; then
    MAAS_URL="https://maas.$CLUSTER_DOMAIN/llm/ext-opus"
    echo "  MaaS URL auto-detected: $MAAS_URL"
  else
    echo "FAIL: could not detect MaaS URL. Pass --maas-url explicitly."
    exit 1
  fi
fi

MAAS_STATUS=$(curl -sk -o /dev/null -w "%{http_code}" "$MAAS_URL/v1/messages" -X POST -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "000")
if [ "$MAAS_STATUS" = "000" ]; then
  echo "  WARN: MaaS not reachable at $MAAS_URL (may work from inside cluster)"
else
  echo "  MaaS: reachable (HTTP $MAAS_STATUS)"
fi

# Check IPP is deployed (we don't configure it, but it must exist for MaaS to work)
if oc get deployment payload-processing -n "$NAMESPACE" &>/dev/null; then
  echo "  IPP (payload-processing): found"
else
  echo "  WARN: payload-processing not found — MaaS may not process requests correctly"
fi

if [ ! -f "$REPO_DIR/service/Dockerfile.proxy" ]; then
  echo "FAIL: service/Dockerfile.proxy not found"
  exit 1
fi
echo "  source files: found"
echo ""

echo "============================================"
echo "  Headroom Proxy Deployment"
echo "  Namespace: $NAMESPACE"
echo "  MaaS URL:  $MAAS_URL"
echo "============================================"
echo ""

# Step 1: Build image (skip if source unchanged)
echo "=== Step 1: Build headroom-proxy image ==="
oc new-build --binary --strategy=docker --name=headroom-proxy -n "$NAMESPACE" 2>/dev/null || true

SOURCE_HASH=$(shasum -a 256 "$REPO_DIR/service/Dockerfile.proxy" | cut -c1-12)
LAST_HASH=""
if oc get configmap headroom-proxy-build-hash -n "$NAMESPACE" &>/dev/null; then
  LAST_HASH=$(oc get configmap headroom-proxy-build-hash -n "$NAMESPACE" -o jsonpath='{.data.hash}' 2>/dev/null || echo "")
fi

if [ "$FORCE_BUILD" = true ] || [ "$SOURCE_HASH" != "$LAST_HASH" ]; then
  echo "  Source changed ($SOURCE_HASH != $LAST_HASH) — building..."

  BUILD_DIR=$(mktemp -d)
  cp "$REPO_DIR/service/Dockerfile.proxy" "$BUILD_DIR/Dockerfile"
  trap "rm -rf $BUILD_DIR" EXIT

  oc start-build headroom-proxy -n "$NAMESPACE" \
    --from-dir="$BUILD_DIR" --follow

  oc create configmap headroom-proxy-build-hash --from-literal=hash="$SOURCE_HASH" \
    -n "$NAMESPACE" --dry-run=client -o yaml | oc apply -f -
else
  echo "  Source unchanged ($SOURCE_HASH) — skipping build"
fi
echo ""

# Step 2: Create PVC for persistent stats and CCR store
echo "=== Step 2: Create PVC ==="
oc apply -n "$NAMESPACE" -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: headroom-proxy-data
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF
echo ""

# Step 3: Deploy
echo "=== Step 3: Deploy headroom-proxy ==="
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
        - name: HEADROOM_CCR_BACKEND
          value: "sqlite"
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
        volumeMounts:
        - name: proxy-data
          mountPath: /opt/app/.headroom
      volumes:
      - name: proxy-data
        persistentVolumeClaim:
          claimName: headroom-proxy-data
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

# Step 4: Rollout (only if build happened)
echo "=== Step 4: Wait for rollout ==="
if [ "$SOURCE_HASH" != "$LAST_HASH" ] || [ "$FORCE_BUILD" = true ]; then
  oc rollout restart deployment/headroom-proxy -n "$NAMESPACE"
fi
oc rollout status deployment/headroom-proxy -n "$NAMESPACE" --timeout=180s
echo ""

# Step 5: Smoke test
echo "=== Step 5: Smoke test ==="
PROXY_HOST=$(oc get route headroom-proxy -n "$NAMESPACE" -o jsonpath='{.spec.host}')

echo "Health:"
curl -sk "https://$PROXY_HOST/readyz" | python3 -m json.tool 2>/dev/null || echo "  not ready yet (may need 30s)"

echo ""
echo "Dashboard:"
echo "  HTTP $(curl -sk -o /dev/null -w '%{http_code}' "https://$PROXY_HOST/dashboard")"

echo ""
echo "Stats:"
echo "  HTTP $(curl -sk -o /dev/null -w '%{http_code}' "https://$PROXY_HOST/stats")"

echo ""
echo "============================================"
echo "  Headroom Proxy deployed!"
echo ""
echo "  Proxy:     https://$PROXY_HOST"
echo "  Dashboard: https://$PROXY_HOST/dashboard"
echo "  Stats:     https://$PROXY_HOST/stats"
echo "  Metrics:   https://$PROXY_HOST/metrics"
echo ""
echo "  Claude Code setup:"
echo "    export ANTHROPIC_BASE_URL=https://$PROXY_HOST"
echo "    export ANTHROPIC_API_KEY=<MaaS-key>"
echo "    export NODE_TLS_REJECT_UNAUTHORIZED=0"
echo "    claude --model claude-opus-4-8"
echo ""
echo "  Rollback (bypass headroom):"
echo "    export ANTHROPIC_BASE_URL=$MAAS_URL"
echo "============================================"
