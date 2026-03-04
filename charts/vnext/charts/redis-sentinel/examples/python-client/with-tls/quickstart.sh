#!/bin/bash

# Redis Sentinel Client - Quick Start Script
# This script helps you quickly test the Redis Sentinel Python client

set -e

echo "=========================================="
echo "Redis Sentinel Client - Quick Start"
echo "=========================================="
echo ""

# Default values
RELEASE_NAME="${RELEASE_NAME:-redis-sentinel}"
NAMESPACE="${NAMESPACE:-default}"
USE_TLS="${USE_TLS:-false}"
EXTERNAL_ACCESS="${EXTERNAL_ACCESS:-false}"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check prerequisites
echo "[1/6] Checking prerequisites..."
if ! command_exists kubectl; then
    print_error "kubectl not found. Please install kubectl."
    exit 1
fi
print_success "kubectl found"

if ! command_exists python3; then
    print_error "python3 not found. Please install python3."
    exit 1
fi
print_success "python3 found"

echo ""

# Get Redis password
echo "[2/6] Retrieving Redis password..."
if ! REDIS_PASSWORD=$(kubectl get secret ${RELEASE_NAME} -n ${NAMESPACE} -o jsonpath="{.data.redis-password}" 2>/dev/null | base64 -d); then
    print_error "Could not retrieve Redis password"
    print_warning "Make sure Redis Sentinel is deployed: helm list -n ${NAMESPACE}"
    exit 1
fi
print_success "Redis password retrieved"

# Get Sentinel password
echo "[3/6] Retrieving Sentinel password..."
if ! SENTINEL_PASSWORD=$(kubectl get secret ${RELEASE_NAME} -n ${NAMESPACE} -o jsonpath="{.data.sentinel-password}" 2>/dev/null | base64 -d); then
    print_warning "Could not retrieve Sentinel password (may not be set)"
    SENTINEL_PASSWORD=""
else
    print_success "Sentinel password retrieved"
fi

echo ""

# Determine Sentinel hosts
echo "[4/6] Determining Sentinel configuration..."
if [ "${EXTERNAL_ACCESS}" = "true" ]; then
    print_warning "External access mode - you need to provide external IPs"
    echo "Please set SENTINEL_HOSTS environment variable manually:"
    echo "  export SENTINEL_HOSTS=\"IP1:26379,IP2:26379,IP3:26379\""
    echo ""
    read -p "Enter Sentinel hosts (comma-separated): " SENTINEL_HOSTS
    
    if [ -z "$SENTINEL_HOSTS" ]; then
        print_error "SENTINEL_HOSTS cannot be empty"
        exit 1
    fi
else
    # Internal access - use Kubernetes service names
    REPLICAS=$(kubectl get statefulset ${RELEASE_NAME} -n ${NAMESPACE} -o jsonpath="{.spec.replicas}" 2>/dev/null || echo "3")
    SENTINEL_HOSTS=""
    for i in $(seq 0 $((REPLICAS - 1))); do
        if [ -n "$SENTINEL_HOSTS" ]; then
            SENTINEL_HOSTS="${SENTINEL_HOSTS},"
        fi
        SENTINEL_HOSTS="${SENTINEL_HOSTS}${RELEASE_NAME}-${i}.${RELEASE_NAME}-headless.${NAMESPACE}.svc.cluster.local:26379"
    done
    print_success "Using internal Sentinel hosts: ${SENTINEL_HOSTS}"
fi

echo ""

# Handle TLS
echo "[5/6] Handling TLS configuration..."
if [ "${USE_TLS}" = "true" ]; then
    print_warning "TLS enabled - extracting certificates..."
    
    # Extract ca.crt
    if kubectl get secret ${RELEASE_NAME}-tls -n ${NAMESPACE} -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d > ca.crt; then
        print_success "CA certificate extracted to ca.crt"
    else
        print_error "Could not extract CA certificate"
        exit 1
    fi
    
    # Extract tls.crt
    if kubectl get secret ${RELEASE_NAME}-tls -n ${NAMESPACE} -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d > tls.crt; then
        print_success "Client certificate extracted to tls.crt"
    else
        print_warning "Could not extract client certificate (may not be required)"
    fi
    
    # Extract tls.key
    if kubectl get secret ${RELEASE_NAME}-tls -n ${NAMESPACE} -o jsonpath='{.data.tls\.key}' 2>/dev/null | base64 -d > tls.key; then
        print_success "Client key extracted to tls.key"
    else
        print_warning "Could not extract client key (may not be required)"
    fi
    
    TLS_CA_CERT="./ca.crt"
    TLS_CERT="./tls.crt"
    TLS_KEY="./tls.key"
else
    print_success "TLS disabled"
fi

echo ""

# Detect container runtime
echo "[6/8] Detecting container runtime..."
CONTAINER_CMD=""
if command_exists docker; then
  CONTAINER_CMD="docker"
  print_success "Docker detected"
elif command_exists podman; then
  CONTAINER_CMD="podman"
  print_success "Podman detected"
else
  print_warning "Neither Docker nor Podman detected"
fi

echo ""
echo "=========================================="
echo "Configuration Summary"
echo "=========================================="
echo "Release Name:     ${RELEASE_NAME}"
echo "Namespace:        ${NAMESPACE}"
echo "Sentinel Hosts:   ${SENTINEL_HOSTS}"
echo "TLS Enabled:      ${USE_TLS}"
echo "External Access:  ${EXTERNAL_ACCESS}"
echo "=========================================="
echo ""

# Export environment variables
export SENTINEL_HOSTS
export MASTER_NAME="mymaster"
export REDIS_PASSWORD
export SENTINEL_PASSWORD
export USE_TLS

if [ "${USE_TLS}" = "true" ]; then
    export TLS_CA_CERT
    export TLS_CERT
    export TLS_KEY
fi

# Choose how to run
echo "[7/8] Choose how to run:"
echo "  1) Locally with Python"
if [ -n "$CONTAINER_CMD" ]; then
  echo "  2) With $CONTAINER_CMD (detected)"
else
  echo "  2) With Docker/Podman (not detected - will check)"
fi
echo "  3) On Kubernetes"
echo ""
read -p "Enter choice [1-3]: " CHOICE
echo ""

case $CHOICE in
  1)
    echo "[8/8] Running locally with Python..."
    
    # Install Python dependencies
    echo "  Installing Python dependencies..."
    if [ -f "requirements.txt" ]; then
        if pip3 install -q -r requirements.txt; then
            print_success "Python dependencies installed"
        else
            print_error "Failed to install Python dependencies"
            exit 1
        fi
    else
        print_error "requirements.txt not found"
        exit 1
    fi
    
    echo ""
    echo "=========================================="
    echo "Running Redis Sentinel Client"
    echo "=========================================="
    echo ""
    
    if [ -f "app.py" ]; then
        python3 app.py
    else
        print_error "app.py not found"
        exit 1
    fi
    ;;
    
  2)
    echo "[8/8] Running with container..."
    
    # Auto-detect container runtime if not already detected
    if [ -z "$CONTAINER_CMD" ]; then
      if command_exists docker; then
        CONTAINER_CMD="docker"
      elif command_exists podman; then
        CONTAINER_CMD="podman"
      else
        print_error "Neither Docker nor Podman is installed!"
        echo ""
        echo "Please install one of:"
        echo "  - Docker: https://docs.docker.com/get-docker/"
        echo "  - Podman: https://podman.io/getting-started/installation"
        exit 1
      fi
    fi
    
    echo "  Using: $CONTAINER_CMD"
    echo ""
    
    # Build image
    IMAGE_NAME="redis-sentinel-client:latest"
    echo "  Building container image..."
    $CONTAINER_CMD build -t $IMAGE_NAME . > /dev/null 2>&1
    print_success "Image built: $IMAGE_NAME"
    echo ""
    
    # Run container
    echo "  Starting container..."
    echo ""
    
    if [ "${USE_TLS}" = "true" ]; then
      # Mount TLS certificates
      $CONTAINER_CMD run --rm \
        -v $(pwd)/ca.crt:/certs/ca.crt:ro \
        -v $(pwd)/tls.crt:/certs/tls.crt:ro \
        -v $(pwd)/tls.key:/certs/tls.key:ro \
        -e SENTINEL_HOSTS="$SENTINEL_HOSTS" \
        -e MASTER_NAME="mymaster" \
        -e REDIS_PASSWORD="$REDIS_PASSWORD" \
        -e SENTINEL_PASSWORD="$SENTINEL_PASSWORD" \
        -e USE_TLS="true" \
        -e TLS_CA_CERT="/certs/ca.crt" \
        -e TLS_CERT="/certs/tls.crt" \
        -e TLS_KEY="/certs/tls.key" \
        $IMAGE_NAME
    else
      # No TLS
      $CONTAINER_CMD run --rm \
        -e SENTINEL_HOSTS="$SENTINEL_HOSTS" \
        -e MASTER_NAME="mymaster" \
        -e REDIS_PASSWORD="$REDIS_PASSWORD" \
        -e SENTINEL_PASSWORD="$SENTINEL_PASSWORD" \
        -e USE_TLS="false" \
        $IMAGE_NAME
    fi
    ;;
    
  3)
    echo "[8/8] Deploying to Kubernetes..."
    
    if [ ! -f "k8s-deployment.yaml" ]; then
      print_error "k8s-deployment.yaml not found"
      exit 1
    fi
    
    # Apply deployment
    echo "  Applying deployment..."
    kubectl apply -f k8s-deployment.yaml -n ${NAMESPACE}
    
    print_success "Deployed to namespace: ${NAMESPACE}"
    echo ""
    echo "View logs with:"
    echo "  kubectl logs -f deployment/redis-sentinel-client -n ${NAMESPACE}"
    echo ""
    ;;
    
  *)
    print_error "Invalid choice!"
    exit 1
    ;;
esac

echo ""
print_success "Quick start completed!"

