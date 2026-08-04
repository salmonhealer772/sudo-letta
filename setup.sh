#!/usr/bin/env bash
set -uo pipefail

# sudo-letta/setup.sh — One-time setup: builds Docker image, prompts for API key.

echo "┌─────────────────────────────────────────────┐"
echo "│  sudo-letta — Letta Code with root cage      │"
echo "└─────────────────────────────────────────────┘"
echo ""

# --- Check Docker ---
if ! docker info &>/dev/null; then
  echo "Docker is not running or this user isn't in the docker group."
  echo "Fix: sudo usermod -aG docker \$USER && newgrp docker"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Build image ---
if ! docker image inspect sudo-letta:latest &>/dev/null; then
  echo "→ Building sudo-letta image (may take 2-3 min)..."
  docker build -t sudo-letta:latest -f "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR" || {
    echo "Docker build failed." >&2
    exit 1
  }
  echo "✓ sudo-letta image built"
else
  echo "→ sudo-letta:latest image exists, skipping build"
fi

# --- Create config directory inside the repo ---
# Detect if dir is root-owned and use sudo if needed
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
    echo "" >> "$ENV_FILE"
    echo "# sudo-letta config (set by setup.sh)" >> "$ENV_FILE"
    echo "LLM_PROVIDER=$PROVIDER" >> "$ENV_FILE"
    echo "API_KEY=$API_KEY" >> "$ENV_FILE"
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

echo ""
echo "✓ Setup complete"
echo ""
echo "  bash scripts/up.sh --fish      # start agent (generates sudo password)"
echo "  bash scripts/talk.sh --fish    # talk to agent"
echo "  bash scripts/down.sh --fish    # stop agent (memory persists)"
echo ""
