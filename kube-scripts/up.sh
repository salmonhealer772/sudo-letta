#!/usr/bin/env bash
set -uo pipefail

# kube-scripts/up.sh — Deploy a sudo-letta agent to Kubernetes
# Usage: bash kube-scripts/up.sh --name

NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name|--*)  NAME="${1#--}"; shift ;;
    *)           echo "Usage: bash kube-scripts/up.sh --name" >&2; exit 1 ;;
  esac
done

if [[ -z "$NAME" ]]; then
  echo "Usage: bash kube-scripts/up.sh --name" >&2
  echo "Example: bash kube-scripts/up.sh --alice" >&2
  exit 1
fi

if [[ "${NAME,,}" == "all" ]]; then
  echo "'--ALL' is reserved. Pick a different name." >&2; exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_DIR/.sudo-letta/.env"
YAML_DIR="$REPO_DIR/deployments"
DEPLOY="sudo-$NAME"
YAML="$YAML_DIR/$NAME.yaml"

# If repo is root-owned and we're not root, bail early
if [[ ! -w "$REPO_DIR" ]] && [[ "$(id -u)" != "0" ]]; then
  echo "Repo is root-owned. Run with: sudo bash kube-scripts/up.sh --$NAME" >&2
  exit 1
fi

mkdir -p "$YAML_DIR" 2>/dev/null || true

# Auto-detect kubeconfig (sudo changes HOME, kubectl can lose it)
if [[ -z "${KUBECONFIG:-}" ]]; then
  for cfg in "/etc/rancher/k3s/k3s.yaml" "/home/world15/.kube/config" "$HOME/.kube/config"; do
    if [[ -f "$cfg" ]]; then export KUBECONFIG="$cfg"; break; fi
  done
  if [[ -z "${KUBECONFIG:-}" ]]; then
    echo "No kubeconfig found. Is k3s running? Try: export KUBECONFIG=/etc/rancher/k3s/k3s.yaml" >&2
    exit 1
  fi
fi

echo "→ sudo-$NAME starting up..."

# ── Env vars ──
if [[ -f "$ENV_FILE" ]] && [[ -r "$ENV_FILE" ]]; then
  # Read env file for API key and provider
  LLM_PROVIDER=$(grep '^LLM_PROVIDER=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- | head -1 || true)
  API_KEY=$(grep '^API_KEY=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- | head -1 || true)
  LLM_BASE_URL=$(grep '^LLM_BASE_URL=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- | head -1 || true)
  SUDO_PASS=$(grep '^SUDO_PASSWORD=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- | head -1 || true)
fi

# Prompt for credentials if missing
if [[ -z "${LLM_PROVIDER:-}" || -z "${API_KEY:-}" ]]; then
  echo "No credentials found. Run setup.sh first." >&2
  exit 1
fi

# Generate sudo password if missing
if [[ -z "${SUDO_PASS:-}" ]]; then
  SUDO_PASS=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 16)
  mkdir -p "$(dirname "$ENV_FILE")"
  echo "SUDO_PASSWORD=$SUDO_PASS" >> "$ENV_FILE"
  echo "→ Generated sudo password: $SUDO_PASS"
fi

# ── Generate YAML ──
# Build env lines for YAML
ENV_YAML="        - name: LLM_PROVIDER
          value: \"${LLM_PROVIDER}\"
        - name: API_KEY
          value: \"${API_KEY}\""
[[ -n "${LLM_BASE_URL:-}" ]] && ENV_YAML+="
        - name: LLM_BASE_URL
          value: \"${LLM_BASE_URL}\""

ENV_YAML+="
        - name: SUDO_PASSWORD
          value: \"${SUDO_PASS}\"
        - name: USER
          value: \"node\"
        - name: HOME
          value: \"/home/node\"
        - name: LETTA_HOME
          value: \"/home/node/.letta\""

cat > "$YAML" <<YAMLEOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $DEPLOY-data
  labels:
    app: sudo-letta
    agent: $NAME
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $DEPLOY
  labels:
    app: sudo-letta
    agent: $NAME
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sudo-letta
      agent: $NAME
  template:
    metadata:
      labels:
        app: sudo-letta
        agent: $NAME
    spec:
      hostNetwork: true
      containers:
      - name: sudo-letta
        image: sudo-letta:latest
        imagePullPolicy: IfNotPresent
        securityContext:
          privileged: true
        env:
$ENV_YAML
        volumeMounts:
        - name: data
          mountPath: /home/node/.letta
        - name: docker-sock
          mountPath: /var/run/docker.sock
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: $DEPLOY-data
      - name: docker-sock
        hostPath:
          path: /var/run/docker.sock
          type: Socket
YAMLEOF

if [[ ! -s "$YAML" ]]; then
  echo "✗ Failed to write $YAML" >&2; exit 1
fi
echo "→ YAML written: $YAML"

# ── Import image into containerd ──
_import_image() {
  local img="$1"
  if docker save "$img" 2>/dev/null | sudo k3s ctr image import - 2>/dev/null; then
    echo "→ $img imported via k3s ctr"
  elif docker save "$img" 2>/dev/null | sudo ctr -n k8s.io image import - 2>/dev/null; then
    echo "→ $img imported via ctr"
  else
    echo "⚠ Could not import $img — it might already be present"
  fi
}

echo "→ Importing images..."
_import_image sudo-letta:latest

# ── Apply ──
echo "→ Deploying..."
if ! kubectl apply -f "$YAML" --validate=false; then
  echo "✗ kubectl apply failed. Check: kubectl cluster-info" >&2
  exit 1
fi

echo ""
echo "✓ $DEPLOY deployed"

# ── Wait for pod and configure Letta ──
echo "→ Waiting for pod to be ready..."
kubectl wait --for=condition=ready pod -l agent=$NAME --timeout=60s 2>/dev/null || true

echo "→ Configuring Letta provider..."
POD=$(kubectl get pods -l agent=$NAME -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -n "$POD" ]]; then
  # Source env for Letta connect
  CONNECT_CMD="letta --backend local connect $LLM_PROVIDER --api-key $API_KEY"
  [[ -n "${LLM_BASE_URL:-}" ]] && CONNECT_CMD="$CONNECT_CMD --base-url $LLM_BASE_URL"

  kubectl exec "$POD" -- bash -c "$CONNECT_CMD" 2>&1 | tail -3 || echo "⚠ Letta connect failed (may need manual config)"

  # Create settings with permissions
  kubectl exec "$POD" -- bash -c '
    SETTINGS_FILE="/home/node/.letta/settings.json"
    mkdir -p "$(dirname "$SETTINGS_FILE")"
    if [ ! -f "$SETTINGS_FILE" ] || [ ! -s "$SETTINGS_FILE" ]; then
      cat > "$SETTINGS_FILE" << "SETTINGS"
{
  "tokenStreaming": true,
  "preferredBackendMode": "local",
  "globalSharedBlockIds": {},
  "permissions": {
    "bash": "allow",
    "read": "allow",
    "write": "allow"
  }
}
SETTINGS
      chown node:node "$SETTINGS_FILE"
    fi
  ' 2>/dev/null || true

  echo "→ Letta configured"
fi
echo "  Talk:   kubectl exec -it deploy/$DEPLOY -- bash -c 'letta'"
echo "  Shell:  kubectl exec -it deploy/$DEPLOY -- bash"
echo "  Logs:   kubectl logs deploy/$DEPLOY -f"
echo "  Stop:   bash kube-scripts/down.sh --$NAME"
