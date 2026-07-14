#!/usr/bin/env bash
set -uo pipefail

# scripts/up.sh — Start a named Sudo Letta container
# Usage: bash scripts/up.sh --name

NAME=""

echo ""
echo "┌─────────────────────────────────────────────┐"
echo "│  sudo-letta — starting up                    │"
echo "└─────────────────────────────────────────────┘"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name|--*)  NAME="${1#--}"; shift ;;
    *)           echo "Usage: bash scripts/up.sh --name" >&2; exit 1 ;;
  esac
done

if [[ -z "$NAME" ]]; then
  echo "Usage: bash scripts/up.sh --name" >&2
  echo "Example: bash scripts/up.sh --alice" >&2
  exit 1
fi

# bash 4.0+ feature guard
if [[ "${NAME,,}" == "all" ]]; then
  echo "'--ALL' is reserved for rm-containers.sh. Pick a different name." >&2
  exit 1
fi

CONTAINER="sudo-$NAME"
VOLUME="sudo-$NAME-data"
ENV_FILE="$HOME/.sudo-letta/.env"
SETTINGS_FILE="$HOME/.sudo-letta/settings.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$HOME/.sudo-letta"

# Guard: if settings.json is somehow a directory, remove it
if [[ -d "$SETTINGS_FILE" ]]; then
  rm -rf "$SETTINGS_FILE"
fi

# --- 0. Prompt for API key if .env doesn't exist ---
if [[ ! -f "$ENV_FILE" ]]; then
  echo ""
  echo "No API key configured yet."
  echo "Run setup.sh first, or enter details now."
  echo ""
  read -r -p "Provider (e.g. openai, anthropic, deepseek): " PROVIDER
  read -r -p "Paste your API key: " API_KEY

  if [[ -z "$PROVIDER" || -z "$API_KEY" ]]; then
    echo "No provider or key entered. Exiting."
    exit 1
  fi

  echo "LLM_PROVIDER=$PROVIDER" > "$ENV_FILE"
  echo "API_KEY=$API_KEY" >> "$ENV_FILE"

  if [[ "$PROVIDER" != "anthropic" && "$PROVIDER" != "chatgpt" ]]; then
    read -r -p "Base URL (e.g. https://api.deepseek.com/v1) [leave blank for default]: " BASE_URL
    if [[ -n "$BASE_URL" ]]; then
      echo "LLM_BASE_URL=$BASE_URL" >> "$ENV_FILE"
    fi
  fi
fi

# --- Load env vars ---
source <(grep -v '^\s*#' "$ENV_FILE" | grep '=' | grep -v '=\s*$')

# --- Generate sudo password if not set ---
SUDO_PASS=""
if grep -q '^SUDO_PASSWORD=' "$ENV_FILE" 2>/dev/null; then
  SUDO_PASS=$(grep '^SUDO_PASSWORD=' "$ENV_FILE" | cut -d'=' -f2)
fi
if [[ -z "$SUDO_PASS" ]]; then
  SUDO_PASS=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 16)
  echo "" >> "$ENV_FILE"
  echo "# Sudo password (set by up.sh)" >> "$ENV_FILE"
  echo "SUDO_PASSWORD=$SUDO_PASS" >> "$ENV_FILE"
  echo "✓ Sudo password generated: $SUDO_PASS"
  echo ""
fi

# --- 1. Build sudo-letta image ---
if ! docker image inspect sudo-letta:latest &>/dev/null; then
  REPO_DIR="$(cd "$SCRIPT_DIR" && cd .. && pwd)"
  echo "→ Building sudo-letta image..."
  docker build -t sudo-letta:latest -f "$REPO_DIR/Dockerfile" "$REPO_DIR" || {
    echo "Sudo-letta build failed." >&2
    exit 1
  }
  echo "✓ sudo-letta image built"
fi

# --- 2. Ensure volume exists ---
if ! docker volume inspect "$VOLUME" &>/dev/null; then
  docker volume create "$VOLUME" >/dev/null || { echo "Volume create failed"; exit 1; }
  # Fix ownership to match container's node user (UID 1000 in node image)
  docker run --rm -v "$VOLUME:/data" --user root node:22-bookworm-slim chown -R 1000:1000 /data 2>/dev/null || true
fi

# --- 3. Remove existing container ---
docker container inspect "$CONTAINER" &>/dev/null && docker rm -f "$CONTAINER" >/dev/null

# --- 4. Setup auto-connect script for first run ---
# We'll create an init script that runs inside the container on first boot
# to configure Letta with the API key
INIT_SCRIPT="/tmp/init-letta.sh"
cat > "$INIT_SCRIPT" << 'INITSCRIPT'
#!/bin/bash
# First-run init: configure Letta with API key
ENV_FILE="/env/.env"
SETTINGS_DIR="/home/node/.letta"
INIT_FLAG="/home/node/.letta-initialized"

# Skip if already initialized
if [[ -f "$INIT_FLAG" ]]; then
  exit 0
fi

# Pre-seed settings with permissive permissions
mkdir -p "$SETTINGS_DIR"

# Source the env vars (file is mounted read-only, so safe)
if [[ -f "$ENV_FILE" ]]; then
  source "$ENV_FILE"
fi

# Configure Letta provider based on env vars using non-interactive connect
if [[ -n "${LLM_PROVIDER:-}" && -n "${API_KEY:-}" ]]; then
  CONNECT_CMD="letta connect $LLM_PROVIDER --api-key $API_KEY"
  if [[ -n "${LLM_BASE_URL:-}" ]]; then
    CONNECT_CMD="$CONNECT_CMD --base-url $LLM_BASE_URL"
  fi
  echo "→ Auto-configuring Letta with $LLM_PROVIDER..."
  eval "$CONNECT_CMD" 2>&1 | tail -5 || true
fi

# Mark initialized so restarting doesn't re-run
touch "$INIT_FLAG"
echo "✓ Letta configured"
INITSCRIPT
chmod +x "$INIT_SCRIPT"

# --- 5. Build env args ---
ENV_OPTS=""
if [[ -f "$ENV_FILE" ]]; then
  while IFS='=' read -r key val; do
    [[ "$key" =~ ^#.*$ || -z "$key" || -z "$val" ]] && continue
    ENV_OPTS+=" -e ${key}=${val}"
  done < <(grep -v '^\s*#' "$ENV_FILE" | grep '=' | grep -v '=\s*$')
fi

ENV_OPTS+=" -e USER=node -e HOME=/home/node"

# --- 6. Run container ---
echo "→ Starting $CONTAINER..."

docker run -d \
  --name "$CONTAINER" \
  --restart unless-stopped \
  --network host \
  -v "$VOLUME:/home/node/.letta" \
  -v "$ENV_FILE:/env/.env:ro" \
  $ENV_OPTS \
  sudo-letta:latest

# Fix any root-owned files in the volume
docker exec "$CONTAINER" chown -R node:node /home/node/.letta 2>/dev/null || true

# --- 7. Run the init script inside the container to auto-configure Letta ---
echo "→ Configuring Letta provider..."
docker cp "$INIT_SCRIPT" "$CONTAINER:/tmp/init-letta.sh"
docker exec "$CONTAINER" bash /tmp/init-letta.sh 2>&1 || true

rm -f "$INIT_SCRIPT"

# --- 8. Create the first agent if none exists ---
echo "→ Setting up initial agent..."
docker exec "$CONTAINER" bash -c '
  SETTINGS_FILE="/home/node/.letta/settings.json"
  # Create a simple settings file with perms
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
  fi
  chown node:node "$SETTINGS_FILE"
' 2>/dev/null || true

echo "✓ $CONTAINER is running"
echo ""
echo "  Talk:   bash $SCRIPT_DIR/talk.sh --$NAME"
echo "  Shell:  bash $SCRIPT_DIR/ssh.sh --$NAME"
echo "  Stop:   bash $SCRIPT_DIR/down.sh --$NAME"
echo "  Logs:   docker logs $CONTAINER -f"
echo ""
echo "  Agent has full sudo inside its container."
echo "  Letta Code with native persistent memory."
echo "  It cannot escape the container."
echo ""
