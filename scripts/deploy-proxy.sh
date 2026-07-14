#!/bin/bash
# deploy-proxy.sh — Deploy headroom proxy (Option A: transparent proxy before MaaS)
#
# Idempotent — safe to run multiple times. Skips image build if source unchanged.
#
# Prerequisites:
#   - oc logged into the target OpenShift cluster
#   - MaaS gateway deployed and accessible
#   - At least one GPU node available (nvidia.com/gpu)
#
# Usage:
#   ./scripts/deploy-proxy.sh                                    # auto-detect from cluster
#   ./scripts/deploy-proxy.sh -n my-namespace                    # specific namespace
#   ./scripts/deploy-proxy.sh --maas-url https://maas.../llm/ext-opus  # Anthropic MaaS route
#   ./scripts/deploy-proxy.sh --maas-openai-url https://maas.../llm/ext-openai  # OpenAI MaaS route
#   ./scripts/deploy-proxy.sh --hf-token hf_xxx                  # faster model download
#   ./scripts/deploy-proxy.sh --force-build                      # rebuild even if unchanged

set -euo pipefail

NAMESPACE="${NAMESPACE:-openshift-ingress}"
HF_TOKEN="${HF_TOKEN:-}"
MAAS_URL="${MAAS_URL:-}"
MAAS_OPENAI_URL="${MAAS_OPENAI_URL:-}"
FORCE_BUILD=false

while [[ $# -gt 0 ]]; do
  case $1 in
    -n) NAMESPACE="$2"; shift 2 ;;
    --hf-token) HF_TOKEN="$2"; shift 2 ;;
    --maas-url) MAAS_URL="$2"; shift 2 ;;
    --maas-openai-url) MAAS_OPENAI_URL="$2"; shift 2 ;;
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

# Check GPU nodes
GPU_NODES=$(oc get nodes -o jsonpath='{range .items[*]}{.status.capacity.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null | grep -c '^[1-9]' || echo "0")
if [ "$GPU_NODES" -eq 0 ]; then
  echo "FAIL: no GPU nodes found (nvidia.com/gpu). Headroom proxy requires GPU for Kompress ML."
  echo "      Without GPU, Kompress runs on CPU (~3s per compression) causing request timeouts."
  exit 1
fi
echo "  GPU nodes: $GPU_NODES"

# Check MaaS gateway URLs
if [ -z "$MAAS_URL" ]; then
  echo "FAIL: MaaS Anthropic URL not set."
  echo "      Pass --maas-url or set MAAS_URL env var."
  echo "      Example: --maas-url https://maas.<cluster-domain>/llm/ext-opus"
  exit 1
fi
echo "  MaaS Anthropic URL: $MAAS_URL"

if [ -z "$MAAS_OPENAI_URL" ]; then
  echo "  WARN: MaaS OpenAI URL not set — Codex/OpenAI requests will route directly to api.openai.com"
  echo "        Pass --maas-openai-url to route through MaaS (auth + metering)"
fi
if [ -n "$MAAS_OPENAI_URL" ]; then
  echo "  MaaS OpenAI URL:    $MAAS_OPENAI_URL"
fi

MAAS_STATUS=$(curl -sk -o /dev/null -w "%{http_code}" "$MAAS_URL/v1/messages" -X POST -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "000")
if [ "$MAAS_STATUS" = "000" ]; then
  echo "  WARN: MaaS not reachable at $MAAS_URL (may work from inside cluster)"
else
  echo "  MaaS: reachable (HTTP $MAAS_STATUS)"
fi

# Check IPP is deployed
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
echo "  GPU:       required (nvidia.com/gpu: 1)"
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
  strategy:
    type: Recreate
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
        - name: HEADROOM_NO_CCR
          value: "1"
        - name: HEADROOM_COMPRESSION_STABLE_AFTER_TURN
          value: "1"
        - name: HEADROOM_STALE_READ_COMPRESS_AFTER_TURNS
          value: "1"
        - name: HEADROOM_KOMPRESS_BACKEND
          value: "pytorch"
        resources:
          requests:
            cpu: "4"
            memory: 4Gi
          limits:
            cpu: "8"
            memory: 8Gi
            nvidia.com/gpu: "1"
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
  name: headroom-service
spec:
  ports:
  - port: 8787
  selector:
    app: headroom-proxy
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: headroom-service
spec:
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
  to:
    kind: Service
    name: headroom-service
  port:
    targetPort: 8787
EOF

# Step 3b: Deploy dashboard nginx (reverse proxy to headroom's built-in /dashboard)
echo "=== Step 3b: Deploy headroom-dashboard ==="
oc apply -n "$NAMESPACE" -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: headroom-dashboard
data:
  default.conf: |
    server {
        listen 8080;
        location = / {
            return 302 /dashboard;
        }
        location / {
            proxy_pass http://headroom-service.$NAMESPACE.svc:8787;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_read_timeout 120s;
            add_header Access-Control-Expose-Headers "x-headroom-tokens-before, x-headroom-tokens-after, x-headroom-tokens-saved, x-headroom-model, x-headroom-transforms" always;
        }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: headroom-dashboard
  labels:
    app: headroom-dashboard
spec:
  replicas: 1
  selector:
    matchLabels:
      app: headroom-dashboard
  template:
    metadata:
      labels:
        app: headroom-dashboard
    spec:
      containers:
      - name: nginx
        image: nginxinc/nginx-unprivileged:alpine
        ports:
        - containerPort: 8080
        volumeMounts:
        - name: nginx-conf
          mountPath: /etc/nginx/conf.d
      volumes:
      - name: nginx-conf
        configMap:
          name: headroom-dashboard
          items:
          - key: default.conf
            path: default.conf
---
apiVersion: v1
kind: Service
metadata:
  name: headroom-dashboard
spec:
  ports:
  - port: 8080
  selector:
    app: headroom-dashboard
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: headroom-dashboard
spec:
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
  to:
    kind: Service
    name: headroom-dashboard
  port:
    targetPort: 8080
EOF
echo ""

# Set OpenAI upstream if provided
if [ -n "$MAAS_OPENAI_URL" ]; then
  oc set env deployment/headroom-proxy -n "$NAMESPACE" \
    OPENAI_TARGET_API_URL="$MAAS_OPENAI_URL" 2>/dev/null
fi

# Clean up old headroom-proxy Service+Route if they exist (renamed to headroom-service)
oc delete service headroom-proxy -n "$NAMESPACE" 2>/dev/null || true
oc delete route headroom-proxy -n "$NAMESPACE" 2>/dev/null || true
echo ""

# Step 4: Rollout
echo "=== Step 4: Wait for rollout ==="
if [ "$SOURCE_HASH" != "$LAST_HASH" ] || [ "$FORCE_BUILD" = true ]; then
  oc rollout restart deployment/headroom-proxy -n "$NAMESPACE"
fi
oc rollout status deployment/headroom-proxy -n "$NAMESPACE" --timeout=300s
echo ""

# Step 5: Smoke test
echo "=== Step 5: Smoke test ==="
PROXY_HOST=$(oc get route headroom-service -n "$NAMESPACE" -o jsonpath='{.spec.host}')

echo "Health:"
curl -sk "https://$PROXY_HOST/readyz" | python3 -m json.tool 2>/dev/null || echo "  not ready yet (may need 30s)"

echo ""
echo "Dashboard:"
echo "  HTTP $(curl -sk -o /dev/null -w '%{http_code}' "https://$PROXY_HOST/dashboard")"

echo ""
echo "Stats:"
echo "  HTTP $(curl -sk -o /dev/null -w '%{http_code}' "https://$PROXY_HOST/stats")"

# Step 6: Verify GPU
echo ""
echo "=== Step 6: Verify GPU ==="
POD_NAME=$(oc get pods -n "$NAMESPACE" -l app=headroom-proxy -o jsonpath='{.items[0].metadata.name}')
GPU_CHECK=$(oc exec "$POD_NAME" -n "$NAMESPACE" -- python3 -c "
import onnxruntime as ort
providers = ort.get_available_providers()
has_cuda = 'CUDAExecutionProvider' in providers
print(f'providers: {providers}')
print(f'cuda: {has_cuda}')
" 2>&1)
echo "$GPU_CHECK"

if echo "$GPU_CHECK" | grep -q "cuda: True"; then
  echo "  GPU: VERIFIED"
else
  echo ""
  echo "  WARNING: CUDAExecutionProvider not available!"
  echo "  Kompress ML will run on CPU (~3s per compression)."
  echo "  This will cause request timeouts under load."
  echo ""
  echo "  Debug: oc exec $POD_NAME -n $NAMESPACE -- python3 -c \"import onnxruntime; print(onnxruntime.get_available_providers())\""
fi

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
