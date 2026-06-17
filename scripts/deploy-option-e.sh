#!/bin/bash
# deploy-option-e.sh — Deploy headroom Option E (shared compression service)
#
# Prerequisites:
#   - oc logged into the target cluster
#   - payload-processing image already deployed with headroom plugin registered
#
# Usage:
#   ./scripts/deploy-option-e.sh                    # deploy to openshift-ingress
#   ./scripts/deploy-option-e.sh -n my-namespace    # deploy to specific namespace

set -euo pipefail

NAMESPACE="${1:---}"
if [ "$NAMESPACE" = "--" ]; then NAMESPACE="openshift-ingress"; fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

echo "============================================"
echo "  Headroom Option E Deployment"
echo "  Namespace: $NAMESPACE"
echo "============================================"
echo ""

# Step 1: Build headroom service image
echo "=== Step 1: Build headroom-service image ==="
oc new-build --binary --strategy=docker --name=headroom-service -n "$NAMESPACE" 2>/dev/null || true
oc start-build headroom-service -n "$NAMESPACE" --from-dir="$REPO_DIR/service" --follow
echo ""

# Step 2: Deploy headroom service
echo "=== Step 2: Deploy headroom-service ==="
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
          initialDelaySeconds: 30
          periodSeconds: 30
        readinessProbe:
          httpGet:
            path: /health
            port: 8787
          initialDelaySeconds: 15
          periodSeconds: 10
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

# Step 3: Deploy dashboard
echo "=== Step 3: Deploy headroom dashboard ==="
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

# Step 4: Wait for rollouts
echo "=== Step 4: Wait for rollouts ==="
oc rollout status deployment/headroom-service -n "$NAMESPACE" --timeout=180s
oc rollout status deployment/headroom-dashboard -n "$NAMESPACE" --timeout=60s
echo ""

# Step 5: Smoke test
echo "=== Step 5: Smoke test ==="
SVC_HOST=$(oc get route headroom-service -n "$NAMESPACE" -o jsonpath='{.spec.host}')
DASH_HOST=$(oc get route headroom-dashboard -n "$NAMESPACE" -o jsonpath='{.spec.host}')

curl -sk "https://$SVC_HOST/health" | python3 -m json.tool
echo ""

echo "============================================"
echo "  Deployment complete!"
echo ""
echo "  Headroom service: https://$SVC_HOST"
echo "  Dashboard:        https://$DASH_HOST/?url=https://$SVC_HOST"
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
