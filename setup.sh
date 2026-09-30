#!/usr/bin/env bash
set -uo pipefail

# sudo-letta/setup.sh — One-time setup: builds Docker image, prompts for API key.

echo "┌─────────────────────────────────────────────┐"
echo "│  sudo-letta — Letta Code with root cage      │"
echo "└─────────────────────────────────────────────┘"
echo ""

# --- Check Docker ---
# Verifies the Docker daemon is reachable and this user is in the docker group,
# because every later step (build, image save, exec) needs a live daemon; if the
# check fails, print the fix and exit 1 before anything else is attempted.
if ! docker info &>/dev/null; then
  echo "Docker is not running or this user isn't in the docker group."
  echo "Fix: sudo usermod -aG docker \$USER && newgrp docker"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# _retry N "description" cmd [args...] — run cmd up to N times with backoff.
# Makes network/build steps survive transient failures instead of dying once.
_retry() {
  local n="$1" desc="$2"; shift 2
  local i=1
  while (( i <= n )); do
    if "$@"; then return 0; fi
    echo "⚠ ($desc) attempt $i/$n failed — retrying in ${i}s..." >&2
    sleep "$i"
    (( i++ ))
  done
  return 1
}

# --- Build image ---
# Builds sudo-letta:latest only if it is not already present locally, because an
# existing image is reused as-is to avoid a 2-3 min rebuild; if the image is
# absent, the build retries 3x (network/toolchain flakiness) and, if it still
# fails, exits 1 with a message rather than continuing to a broken deploy.
if ! docker image inspect sudo-letta:latest &>/dev/null; then
  echo "→ Building sudo-letta image (may take 2-3 min)..."
  _retry 3 "docker build sudo-letta" docker build -t sudo-letta:latest -f "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR" || {
    echo "Docker build failed." >&2
    exit 1
  }
  echo "✓ sudo-letta image built"
else
  echo "→ sudo-letta:latest image exists, skipping build"
fi

# --- Create config directory inside the repo ---
# Detect if dir is root-owned and use sudo if needed.
# _writable probes by appending a no-op line to the .env: a root-owned repo
# denies writes to a non-root user, so the probe's success/failure decides
# whether credential writes need sudo; if the probe fails, fall back to
# sudo mkdir/tee, and if sudo is itself unavailable the script errors out here
# before any credentials are written.
_writable() { echo "" >> "$1" 2>/dev/null; }

if ! _writable "$SCRIPT_DIR/.sudo-letta/.env"; then
  USE_SUDO=true
  echo "→ Repo is root-owned. Using sudo to save credentials..."
  sudo mkdir -p "$SCRIPT_DIR/.sudo-letta"
else
  USE_SUDO=false
  mkdir -p "$SCRIPT_DIR/.sudo-letta"
fi

# --- Prompt for API key ---
# The .sudo-letta/.env file is the pre-seed that skips prompts: provider + API
# key are prompted for ONLY when the file is missing an API_KEY line or holds
# an empty one, because a previously written key is reused verbatim on re-runs
# (non-interactive CI / unattended re-setup); if the user then enters an empty
# provider or key, exit 1 with "Setup incomplete" so nothing is half-written.
ENV_FILE="$SCRIPT_DIR/.sudo-letta/.env"

if ! grep -q '^API_KEY=' "$ENV_FILE" 2>/dev/null || \
     grep -q '^API_KEY=\s*$' "$ENV_FILE" 2>/dev/null; then
  echo ""
  echo "┌─────────────────────────────────────────────┐"
  echo "│  LLM API Key Required                        │"
  echo "├─────────────────────────────────────────────┤"
  echo "│  Supported providers:                       │"
  echo "│  - OpenAI:       platform.openai.com/api-keys│"
  echo "│  - Anthropic:    console.anthropic.com       │"
  echo "│  - DeepSeek:     platform.deepseek.com/api_keys│"
  echo "│  - OpenRouter:   openrouter.ai/keys          │"
  echo "│  - Or any OpenAI-compatible API              │"
  echo "└─────────────────────────────────────────────┘"
  echo ""
  read -r -p "Provider (e.g. openai, anthropic, deepseek): " PROVIDER
  read -r -p "Paste your API key: " API_KEY

  if [[ -z "$PROVIDER" || -z "$API_KEY" ]]; then
    echo "No provider or key entered. Setup incomplete — run setup.sh again."
    exit 1
  fi

  if $USE_SUDO; then
    {
      echo "# sudo-letta config (set by setup.sh)"
      echo "LLM_PROVIDER=$PROVIDER"
      echo "API_KEY=$API_KEY"
    } | sudo tee "$ENV_FILE" > /dev/null
  else
    {
      echo ""
      echo "# sudo-letta config (set by setup.sh)"
      echo "LLM_PROVIDER=$PROVIDER"
      echo "API_KEY=$API_KEY"
    } >> "$ENV_FILE"
  fi

  # If it's an OpenAI-compatible provider, ask for base URL
  if [[ "$PROVIDER" != "anthropic" && "$PROVIDER" != "chatgpt" ]]; then
    read -r -p "Base URL (e.g. https://api.deepseek.com/v1) [leave blank for default]: " BASE_URL
    if [[ -n "$BASE_URL" ]]; then
      if $USE_SUDO; then
        echo "LLM_BASE_URL=$BASE_URL" | sudo tee -a "$ENV_FILE" > /dev/null
      else
        echo "LLM_BASE_URL=$BASE_URL" >> "$ENV_FILE"
      fi
    fi
  fi

  echo "✓ Saved $ENV_FILE"
fi

# --- Create default settings.json template ---
# Writes a permissive default settings.json only if it does not already exist,
# because the file both enables token streaming and pre-grants bash/read/write
# so the agent starts without an interactive permission prompt; if the file
# already exists it is left untouched (preserving any operator edits).
SETTINGS_FILE="$SCRIPT_DIR/.sudo-letta/settings.json"
if [[ ! -f "$SETTINGS_FILE" ]]; then
  if $USE_SUDO; then
    sudo tee "$SETTINGS_FILE" > /dev/null << 'EOF'
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
EOF
  else
    cat > "$SETTINGS_FILE" << 'EOF'
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
EOF
  fi
  echo "✓ Created $SETTINGS_FILE"
fi

# --- Shared Redis for the prompt distributor queue ---
# Applies the shared Redis (prompt-distributor queue) immediately only if
# kubectl and a reachable cluster exist, because setup is often run before the
# cluster is up; if kubectl apply fails, abort loudly (the queue is required
# for agent deploys); if kubectl/cluster are absent, defer to the first up.sh.
if command -v kubectl >/dev/null 2>&1 && kubectl cluster-info >/dev/null 2>&1; then
  echo "→ Applying shared Redis (kube-scripts/redis.yaml)..."
  if ! kubectl apply -f "$SCRIPT_DIR/kube-scripts/redis.yaml" --validate=false; then
    echo "✗ FAILED to apply kube-scripts/redis.yaml (shared Redis for the prompt distributor queue). Setup aborted — fix Redis provisioning and re-run setup.sh." >&2
    exit 1
  fi
  echo "✓ Shared Redis applied"
else
  echo "⚠ kubectl/cluster not available yet — shared Redis (kube-scripts/redis.yaml) will be applied on the first up.sh agent deploy."
fi

echo ""
echo "✓ Setup complete"
echo ""
echo "  bash scripts/up.sh --fish      # start agent (generates sudo password)"
echo "  bash scripts/talk.sh --fish    # talk to agent"
echo "  bash scripts/down.sh --fish    # stop agent (memory persists)"
echo ""
