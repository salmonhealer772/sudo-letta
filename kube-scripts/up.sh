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

# Hostname used for the pod's /etc/hosts hostAliases entry — lets sudo resolve the
# host's own hostname (avoids `sudo: unable to resolve host <name>` under hostNetwork).
NODE_HOSTNAME="$(hostname)"

# Per-agent MCP server port. Every sudo-letta pod runs hostNetwork:true, so all
# pods share the node's network namespace and a single fixed port would collide.
# Derive a stable, unique port from the agent name (stays below the ephemeral
# range, 32768+). The Service below exposes a stable port 8000 and forwards
# (targetPort) to this unique per-agent port.
MCP_PORT=$(( 8000 + $(printf '%s' "$NAME" | cksum | cut -d' ' -f1) % 24768 ))

# Per-agent WATCH (observer sidecar) port — same hostNetwork collision rules
# as MCP_PORT, but hashed from a DIFFERENT string ("$NAME-watch") so it never
# collides with the MCP port. Guard bumps by 1 in the (astronomically rare) case
# the two hashes land on the same port.
WATCH_PORT=$(( 8000 + $(printf '%s-watch' "$NAME" | cksum | cut -d' ' -f1) % 24768 ))
if [[ "$WATCH_PORT" == "$MCP_PORT" ]]; then
  WATCH_PORT=$(( MCP_PORT + 1 ))
fi

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
  # Optional web_search provider keys (read but never echoed/committed).
  # Any that are set AND non-empty are injected into the pod env below;
  # unset ones are skipped entirely (no empty-value env vars).
  for _opt in EXA_API_KEY TAVILY_API_KEY PARALLEL_API_KEY PERPLEXITY_API_KEY; do
    _val=$(grep "^${_opt}=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- | head -1 || true)
    [[ -n "${_val}" ]] && eval "${_opt}="\${_val}"" || true
  done
  unset _opt _val
fi

# Prompt for credentials if missing
if [[ -z "${LLM_PROVIDER:-}" || -z "${API_KEY:-}" ]]; then
  echo "No credentials found. Run setup.sh first." >&2
  exit 1
fi

# NOTE: SUDO_PASSWORD was intentional dead code and has been removed. The `node`
# account is locked and sudo elevation is via the NOPASSWD sudoers rule
# (/etc/sudoers.d/node) only — no password is ever set, so the SUDO_PASSWORD env
# var never did anything.

# ── Generate YAML ──
# Build env lines for YAML
ENV_YAML="        - name: LLM_PROVIDER
          value: \"${LLM_PROVIDER}\"
        - name: API_KEY
          value: \"${API_KEY}\"
        - name: LETTA_API_KEY
          value: \"${API_KEY}\""
[[ -n "${LLM_BASE_URL:-}" ]] && ENV_YAML+="
        - name: LLM_BASE_URL
          value: \"${LLM_BASE_URL}\""
# Optional web_search provider keys: inject only the ones that are set and
# non-empty (fleet-wide fallback; agent-scoped /secret takes precedence per
# the mod). Never echo the values.
for _opt in EXA_API_KEY TAVILY_API_KEY PARALLEL_API_KEY PERPLEXITY_API_KEY; do
  _val="${!_opt:-}"
  if [[ -n "$_val" ]]; then
    ENV_YAML+="
        - name: ${_opt}
          value: \"${_val}\""
  fi
done
unset _opt _val

ENV_YAML+="
        - name: USER
          value: \"node\"
        - name: HOME
          value: \"/home/node\"
        - name: LETTA_HOME
          value: \"/home/node/.letta\"
        - name: MCP_PORT
          value: \"${MCP_PORT}\""

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
      shareProcessNamespace: true
      hostNetwork: true
      hostAliases:
      - ip: "127.0.0.1"
        hostnames:
        - "$NODE_HOSTNAME"
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
      # ── Observer sidecar container ────────────────────────────────────────
      # Monitors the agent container (shared PID namespace), captures every
      # message from the Letta store into <PVC>/watch/events.jsonl, and serves
      # the HTTP tap on WATCH_PORT. Same image; no docker socket; unprivileged.
      - name: watch
        image: sudo-letta:latest
        imagePullPolicy: IfNotPresent
        command: ["python3", "/opt/letta-watch/watch_sidecar.py"]
        env:
        - name: WATCH_PORT
          value: "$WATCH_PORT"
        - name: AGENT_NAME
          value: "$NAME"
        - name: DEPLOY_NAME
          value: "$DEPLOY"
        - name: HOME
          value: "/home/node"
        volumeMounts:
        - name: data
          mountPath: /home/node/.letta
        - name: watch-config
          mountPath: /etc/watch-config
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: $DEPLOY-data
      - name: docker-sock
        hostPath:
          path: /var/run/docker.sock
          type: Socket
      - name: watch-config
        configMap:
          name: $DEPLOY-watch-config
---
# ── Observer sidecar (watch) ──────────────────────────────────────────────
# ConfigMap consumed by the watch container at /etc/watch-config/config.json.
apiVersion: v1
kind: ConfigMap
metadata:
  name: $DEPLOY-watch-config
  labels:
    app: sudo-letta
    agent: $NAME
data:
  config.json: |
    {
      "agent_name": "$NAME",
      "deploy_name": "$DEPLOY",
      "watch_port": $WATCH_PORT,
      "poll_interval_sec": 2,
      "log_dir": "/home/node/.letta/watch"
    }
---
apiVersion: v1
kind: Service
metadata:
  name: $DEPLOY-mcp
  labels:
    app: sudo-letta
    agent: $NAME
spec:
  type: ClusterIP
  selector:
    app: sudo-letta
    agent: $NAME
  ports:
  - name: mcp
    port: 8000
    targetPort: $MCP_PORT
---
# Observer sidecar Service: stable port 8000 -> per-agent WATCH_PORT
# (hostNetwork pods share the node's network namespace, so the sidecar itself
# listens on a unique per-agent port; the Service gives it a stable name).
apiVersion: v1
kind: Service
metadata:
  name: $DEPLOY-watch
  labels:
    app: sudo-letta
    agent: $NAME
spec:
  type: ClusterIP
  selector:
    app: sudo-letta
    agent: $NAME
  ports:
  - name: watch
    port: 8000
    targetPort: $WATCH_PORT
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

  # Agent-record hygiene: strip GHOST agent records (memfs:false, unpinned
  # duplicates left by historical CLI runs). When a session binds to a ghost,
  # the official web-search mod's tools never attach -> agent reports no
  # web_search. Runs on EVERY up.sh (create + recreate). Never bricks the
  # agent: parse failure leaves settings.json untouched; sessionsByServer
  # and all other keys are preserved verbatim; backup written to .bak-ghosts.
  kubectl exec "$POD" -- bash -c 'python3 - << "PYEOF"
import json, shutil, os, sys

path = "/home/node/.letta/settings.json"

try:
    with open(path) as f:
        data = json.load(f)
except Exception as exc:
    print("ghost-hygiene: parse failed, settings.json left untouched (%s)" % exc)
    sys.exit(0)

agents = data.get("agents") or []
if not agents:
    sys.exit(0)

def is_pinned(rec):
    return isinstance(rec, dict) and (rec.get("memfs") is True or rec.get("pinned") is True)

keep = [a for a in agents if is_pinned(a)]
removed = len(agents) - len(keep)

if removed and not keep:
    print("ghost-hygiene: WARNING no pinned (memfs) record found — leaving settings.json untouched")
    sys.exit(0)

if removed:
    shutil.copy2(path, path + ".bak-ghosts")
    data["agents"] = keep
    last = data.get("lastAgent")
    last_id = last if isinstance(last, str) else (last.get("id") if isinstance(last, dict) else None)
    keep_ids = {a.get("id") for a in keep}
    if last_id is not None and last_id not in keep_ids and keep[0].get("id") is not None:
        data["lastAgent"] = keep[0]["id"]
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, path)
    print("ghost-hygiene: removed %d ghost agent record(s), kept %d pinned" % (removed, len(keep)))
PYEOF' || true

  # Official web-search mod: install idempotently on EVERY deploy. The image
  # pre-installs it, but a fresh PVC shadows /home/node/.letta — brand-new
  # agents deploy WITHOUT the mod unless we install it here. Pinned exact
  # version; `letta install` is already idempotent (verified). Skipping when
  # present keeps redeploys fast.
  kubectl exec "$POD" -- bash -c '
    HOME=/home/node node /usr/local/lib/node_modules/@letta-ai/letta-code/letta.js mods list 2>/dev/null | grep -q "web-search" \
      || HOME=/home/node node /usr/local/lib/node_modules/@letta-ai/letta-code/letta.js install npm:@letta-ai/web-search@0.1.0
  ' 2>/dev/null || echo "⚠ web-search mod install failed (agent will lack web_search)"

  echo "→ Letta configured"
fi
echo "  Talk:   kubectl exec -it deploy/$DEPLOY -- bash -c 'letta'"
echo "  Shell:  kubectl exec -it deploy/$DEPLOY -- bash"
echo "  MCP:    http://$DEPLOY-mcp:8000/mcp"
echo "  Watch:  http://$DEPLOY-watch:8000/status  (also /ps /events /stream /healthz)"
echo "  Logs:   kubectl logs deploy/$DEPLOY -f"
echo "  Stop:   bash kube-scripts/down.sh --$NAME"
