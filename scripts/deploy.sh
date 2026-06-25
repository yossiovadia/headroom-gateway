#!/bin/bash
# deploy.sh — Deploy headroom-gateway to OpenShift
#
# Usage:
#   ./scripts/deploy.sh                          # deploy to current namespace
#   ./scripts/deploy.sh -n my-namespace          # deploy to specific namespace
#   ./scripts/deploy.sh --mode ipp               # deploy with IPP/MaaS routing
#   ./scripts/deploy.sh --build                  # build image on cluster first

set -euo pipefail

NAMESPACE="${NAMESPACE:-$(oc project -q 2>/dev/null || echo 'default')}"
MODE="standalone"
BUILD=false
IMAGE="headroom-gateway:latest"

while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--namespace) NAMESPACE="$2"; shift 2 ;;
        --mode) MODE="$2"; shift 2 ;;
        --build) BUILD=true; shift ;;
        --image) IMAGE="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

echo "Deploying headroom-gateway to namespace: $NAMESPACE (mode: $MODE)"

# Build image on cluster if requested
if [ "$BUILD" = true ]; then
    echo "Building image on cluster..."
    oc new-build --binary --strategy=docker --name=headroom-gateway -n "$NAMESPACE" 2>/dev/null || true
    oc start-build headroom-gateway -n "$NAMESPACE" --from-dir=deploy/docker --follow
    IMAGE="image-registry.openshift-image-registry.svc:5000/$NAMESPACE/headroom-gateway:latest"
    echo "Image built: $IMAGE"
fi

# Apply manifests
echo "Applying manifests..."
oc apply -k deploy/openshift -n "$NAMESPACE"

# Set the image
oc set image deployment/headroom-gateway headroom="$IMAGE" -n "$NAMESPACE"

# Set imagePullPolicy for cluster-built images
if [ "$BUILD" = true ]; then
    oc patch deployment headroom-gateway -n "$NAMESPACE" --type=json \
        -p='[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"Always"}]'
fi

# Configure mode
if [ "$MODE" = "ipp" ]; then
    echo "Configuring IPP mode..."
    echo "Set ANTHROPIC_TARGET_API_URL in the configmap to your MaaS gateway URL"
fi

# Wait for rollout
oc rollout status deployment/headroom-gateway -n "$NAMESPACE" --timeout=120s

# Show route
ROUTE=$(oc get route headroom-gateway -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -n "$ROUTE" ]; then
    echo ""
    echo "============================================"
    echo "  Headroom Gateway deployed!"
    echo ""
    echo "  URL: https://$ROUTE"
    echo ""
    echo "  For Claude Code:"
    echo "    export ANTHROPIC_BASE_URL=https://$ROUTE"
    echo "    export ANTHROPIC_API_KEY=<your-key>"
    echo "    claude"
    echo "============================================"
fi
