#!/bin/bash
# deploy-option-e.sh — Deploy headroom compression service (Option E-Proxy)
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
#   ./scripts/deploy-option-e.sh                                    # deploy to openshift-ingress
#   ./scripts/deploy-option-e.sh -n my-namespace                    # deploy to specific namespace
#   ./scripts/deploy-option-e.sh --hf-token hf_xxx                  # faster model download
#   HF_TOKEN=hf_xxx ./scripts/deploy-option-e.sh                    # env var also works
#
# GPU support is automatic — onnxruntime-gpu detects NVIDIA GPUs at runtime.
# No flag needed. If a GPU is available, it uses it. Otherwise falls back to CPU.

set -euo pipefail

NAMESPACE="openshift-ingress"
HF_TOKEN="${HF_TOKEN:-}"

while [[ $# -gt 0 ]]; do
  case $1 in
    -n) NAMESPACE="$2"; shift 2 ;;
    --hf-token) HF_TOKEN="$2"; shift 2 ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

echo "============================================"
echo "  Headroom Compression Service Deployment"
echo "  Namespace: $NAMESPACE"
echo "  GPU:       auto-detect (onnxruntime-gpu)"
echo "============================================"
echo ""

# Step 1: Build headroom service image
echo "=== Step 1: Build headroom-service image ==="
oc new-build --binary --strategy=docker --name=headroom-service -n "$NAMESPACE" 2>/dev/null || true

BUILD_ARGS=""
if [ -n "$HF_TOKEN" ]; then
  BUILD_ARGS="--build-arg HF_TOKEN=$HF_TOKEN"
fi

oc start-build headroom-service -n "$NAMESPACE" \
  --from-dir="$REPO_DIR/service" $BUILD_ARGS --follow
echo ""

# Step 2: Create PVC for stats persistence
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

# Step 3: Deploy headroom service
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
        - name: HEADROOM_PRICING_DSN
          value: "postgresql://metering:metering-dev@metering-postgresql.$NAMESPACE.svc:5432/metering"
        - name: HEADROOM_COST_PER_MTOK
          value: "15.0"
        - name: HEADROOM_COMPRESSION_STABLE_AFTER_TURN
          value: "1"
        - name: HEADROOM_STALE_READ_COMPRESS_AFTER_TURNS
          value: "1"
        resources:
          requests:
            cpu: "2"
            memory: 2Gi
          limits:
            cpu: "4"
            memory: 4Gi
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

# Step 4: Deploy dashboard
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

# Step 5: Wait for rollouts
echo "=== Step 5: Wait for rollouts ==="
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
echo "  Proxy stats:      https://$SVC_HOST/stats"
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
