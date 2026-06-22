#!/bin/bash
# deploy-headroom.sh — Deploy headroom compression service to OpenShift
#
# Idempotent — safe to run multiple times. Skips image build if source unchanged.
#
# Prerequisites:
#   - oc logged into the target cluster (oc login ...)
#   - MaaS gateway deployed (Envoy + Istio + Kuadrant)
#   - payload-processing (BBR/IPP) deployed with headroom plugin registered
#     (from yossiovadia/ai-gateway-payload-processing branch feat/headroom-on-metering)
#   - metering-service deployed with model_pricing table in Postgres
#     (for per-model cost tracking — falls back to $15/MTok if unavailable)
#   - ipp-config ConfigMap exists (headroom plugin entry added after deployment)
#
# This script deploys ONLY the headroom compression service and dashboard.
# It does NOT touch MaaS, BBR, metering, or Envoy configuration.
#
# Usage:
#   ./scripts/deploy-headroom.sh                                    # deploy to openshift-ingress
#   ./scripts/deploy-headroom.sh -n my-namespace                    # deploy to specific namespace
#   ./scripts/deploy-headroom.sh --hf-token hf_xxx                  # faster model download
#   ./scripts/deploy-headroom.sh --force-build                      # rebuild even if source unchanged
#   HF_TOKEN=hf_xxx ./scripts/deploy-headroom.sh                    # env var also works
#
# GPU support is automatic — onnxruntime-gpu detects NVIDIA GPUs at runtime.
# No flag needed. If a GPU is available, it uses it. Otherwise falls back to CPU.

set -euo pipefail

NAMESPACE="openshift-ingress"
HF_TOKEN="${HF_TOKEN:-}"
FORCE_BUILD=false

while [[ $# -gt 0 ]]; do
  case $1 in
    -n) NAMESPACE="$2"; shift 2 ;;
    --hf-token) HF_TOKEN="$2"; shift 2 ;;
    --force-build) FORCE_BUILD=true; shift ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# --- Preflight checks ---
echo "=== Preflight checks ==="

if ! command -v oc &>/dev/null; then
  echo "FAIL: oc CLI not found. Install: https://mirror.openshift.com/pub/openshift-v4/clients/ocp/"
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

if ! oc get deployment payload-processing -n "$NAMESPACE" &>/dev/null; then
  echo "FAIL: payload-processing deployment not found in $NAMESPACE"
  echo "  The BBR/IPP must be deployed first with the headroom plugin registered."
  exit 1
fi
echo "  payload-processing: found"

if oc get configmap ipp-config -n "$NAMESPACE" &>/dev/null; then
  if oc get configmap ipp-config -n "$NAMESPACE" -o jsonpath='{.data}' | grep -q headroom; then
    echo "  ipp-config: headroom plugin registered"
  else
    echo "  WARN: ipp-config exists but headroom plugin not registered yet (will need manual step after deploy)"
  fi
else
  echo "  WARN: ipp-config configmap not found (will need manual step after deploy)"
fi

PG_PASSWORD=""
if oc get statefulset metering-postgresql -n "$NAMESPACE" &>/dev/null; then
  PG_PASSWORD=$(oc exec metering-postgresql-0 -n "$NAMESPACE" -- printenv POSTGRESQL_PASSWORD 2>/dev/null || echo "")
  if [ -n "$PG_PASSWORD" ]; then
    echo "  metering-postgresql: found (per-model pricing available)"
  else
    echo "  WARN: metering-postgresql found but couldn't read password — pricing will use fallback"
  fi
else
  echo "  WARN: metering-postgresql not found — cost tracking will use flat \$${HEADROOM_COST_PER_MTOK:-15}/MTok fallback"
fi

for f in service/Dockerfile service/headroom_service.py dashboard/index.html; do
  if [ ! -f "$REPO_DIR/$f" ]; then
    echo "FAIL: $f not found at $REPO_DIR/$f"
    exit 1
  fi
done
echo "  source files: found"
echo ""

echo "============================================"
echo "  Headroom Compression Service Deployment"
echo "  Namespace: $NAMESPACE"
echo "  GPU:       auto-detect (onnxruntime-gpu)"
echo "============================================"
echo ""

# Step 1: Build headroom service image (skip if source unchanged)
echo "=== Step 1: Build headroom-service image ==="
oc new-build --binary --strategy=docker --name=headroom-service -n "$NAMESPACE" 2>/dev/null || true

SOURCE_HASH=$(cat "$REPO_DIR/service/Dockerfile" "$REPO_DIR/service/headroom_service.py" | shasum -a 256 | cut -c1-12)
LAST_HASH=""
if oc get configmap headroom-build-hash -n "$NAMESPACE" &>/dev/null; then
  LAST_HASH=$(oc get configmap headroom-build-hash -n "$NAMESPACE" -o jsonpath='{.data.hash}' 2>/dev/null || echo "")
fi

if [ "$FORCE_BUILD" = true ] || [ "$SOURCE_HASH" != "$LAST_HASH" ]; then
  echo "  Source changed ($SOURCE_HASH != $LAST_HASH) — building..."
  if [ -n "$HF_TOKEN" ]; then
    oc start-build headroom-service -n "$NAMESPACE" \
      --from-dir="$REPO_DIR/service" --build-arg "HF_TOKEN=$HF_TOKEN" --follow
  else
    oc start-build headroom-service -n "$NAMESPACE" \
      --from-dir="$REPO_DIR/service" --follow
  fi

  oc create configmap headroom-build-hash --from-literal=hash="$SOURCE_HASH" \
    -n "$NAMESPACE" --dry-run=client -o yaml | oc apply -f -
else
  echo "  Source unchanged ($SOURCE_HASH) — skipping build"
fi
echo ""

# Step 2: Create PVC for stats persistence (idempotent — oc apply)
echo "=== Step 2: Create stats PVC ==="
oc apply -n "$NAMESPACE" -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: headroom-stats
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF
echo ""

# Step 3: Deploy headroom service (idempotent — oc apply)
echo "=== Step 3: Deploy headroom-service ==="
oc apply -n "$NAMESPACE" -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: headroom-service
  labels:
    app: headroom-service
spec:
  replicas: 1
  selector:
    matchLabels:
      app: headroom-service
  template:
    metadata:
      labels:
        app: headroom-service
    spec:
      containers:
      - name: headroom
        image: image-registry.openshift-image-registry.svc:5000/$NAMESPACE/headroom-service:latest
        imagePullPolicy: Always
        ports:
        - containerPort: 8787
        env:
        - name: HEADROOM_STATS_DB
          value: /data/headroom-stats.db
        - name: HEADROOM_PRICING_PG_HOST
          value: "metering-postgresql.$NAMESPACE.svc"
        - name: HEADROOM_PRICING_PG_DB
          value: "metering"
        - name: HEADROOM_PRICING_PG_USER
          value: "metering"
        - name: HEADROOM_PRICING_PG_PASSWORD
          value: "$PG_PASSWORD"
        - name: HEADROOM_COST_PER_MTOK
          value: "15.0"
        - name: HEADROOM_COMPRESSION_STABLE_AFTER_TURN
          value: "1"
        - name: HEADROOM_STALE_READ_COMPRESS_AFTER_TURNS
          value: "1"
        - name: HEADROOM_WORKERS
          value: "4"
        resources:
          requests:
            cpu: "4"
            memory: 4Gi
          limits:
            cpu: "8"
            memory: 8Gi
        livenessProbe:
          httpGet:
            path: /health
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
        - name: stats-data
          mountPath: /data
      volumes:
      - name: stats-data
        persistentVolumeClaim:
          claimName: headroom-stats
---
apiVersion: v1
kind: Service
metadata:
  name: headroom-service
spec:
  ports:
  - port: 8787
  selector:
    app: headroom-service
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
echo ""

# Step 4: Deploy dashboard (idempotent — oc apply + dry-run)
echo "=== Step 4: Deploy headroom dashboard ==="
oc create configmap headroom-dashboard \
  --from-file=index.html="$REPO_DIR/dashboard/index.html" \
  -n "$NAMESPACE" --dry-run=client -o yaml | oc apply -f -

oc apply -n "$NAMESPACE" -f - <<EOF
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
        - name: dashboard
          mountPath: /usr/share/nginx/html
          readOnly: true
      volumes:
      - name: dashboard
        configMap:
          name: headroom-dashboard
---
apiVersion: v1
kind: Service
metadata:
  name: headroom-dashboard
spec:
  selector:
    app: headroom-dashboard
  ports:
  - port: 8080
    targetPort: 8080
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

# Step 5: Rollout (only if build happened or deployment changed)
echo "=== Step 5: Wait for rollouts ==="
if [ "$SOURCE_HASH" != "$LAST_HASH" ] || [ "$FORCE_BUILD" = true ]; then
  oc rollout restart deployment/headroom-service -n "$NAMESPACE"
fi
oc rollout status deployment/headroom-service -n "$NAMESPACE" --timeout=180s
oc rollout status deployment/headroom-dashboard -n "$NAMESPACE" --timeout=60s
echo ""

# Step 6: Smoke test
echo "=== Step 6: Smoke test ==="
SVC_HOST=$(oc get route headroom-service -n "$NAMESPACE" -o jsonpath='{.spec.host}')
DASH_HOST=$(oc get route headroom-dashboard -n "$NAMESPACE" -o jsonpath='{.spec.host}')

echo "Health check:"
curl -sk "https://$SVC_HOST/readyz" | python3 -m json.tool
echo ""

echo "Compression test:"
curl -sk -X POST "https://$SVC_HOST/v1/compress" \
  -H "Content-Type: application/json" \
  -H "x-maas-username: deploy-test" \
  -d '{"messages": [{"role":"user","content":"list"},{"role":"assistant","content":"ok"},{"role":"tool","content":"[{\"a\":1,\"b\":2,\"c\":3},{\"a\":4,\"b\":5,\"c\":6},{\"a\":7,\"b\":8,\"c\":9},{\"a\":10,\"b\":11,\"c\":12},{\"a\":13,\"b\":14,\"c\":15}]"},{"role":"user","content":"done"}], "model": "test"}' \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'tokens: {d[\"tokens_before\"]} → {d[\"tokens_after\"]} (saved {d[\"tokens_saved\"]})')"
echo ""

echo "Stats check:"
curl -sk "https://$SVC_HOST/stats" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'requests: {d[\"summary\"][\"api_requests\"]}')"
echo ""

echo "============================================"
echo "  Deployment complete!"
echo ""
echo "  Headroom service: https://$SVC_HOST"
echo "  Dashboard:        https://$DASH_HOST/?url=https://$SVC_HOST"
echo "  Metrics:          https://$SVC_HOST/metrics"
echo "  Stats:            https://$SVC_HOST/stats"
echo ""
echo "  Next: add headroom plugin to ipp-config ConfigMap:"
echo "    - name: headroom"
echo "      type: headroom"
echo "      parameters:"
echo "        headroomURL: \"http://headroom-service.$NAMESPACE.svc:8787\""
echo "        timeoutSeconds: 10"
echo "        failOpen: true"
echo ""
echo "  Then restart payload-processing:"
echo "    oc rollout restart deployment/payload-processing -n $NAMESPACE"
echo "============================================"
