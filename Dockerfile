# sudo-letta — Letta Code with root access inside Docker
# Each agent gets its own container with full sudo and zero host escape.
# Uses Letta Code (`@letta-ai/letta-code`) as the agent harness.
#
# Unlike sudo-agent (which patches Hermes' background_review.py for memory),
# Letta Code has native persistent memory — MemFS, memory blocks, skill learning.
# No patches needed.

FROM node:22-bookworm-slim

LABEL sudo-letta="true" description="Letta Code with sudo + native memory"

# Install system deps: sudo, common tools
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    sudo \
    ca-certificates \
    curl \
    git \
    python3 \
    python-is-python3 \
    ripgrep \
    ffmpeg \
    openssh-client \
    docker-cli \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Set up passwordless sudo for the node user (created by node base image)
RUN echo "node ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/node && \
    chmod 0440 /etc/sudoers.d/node

# Install Letta Code globally via npm
RUN npm install -g @letta-ai/letta-code && \
    npm cache clean --force

# Create home directory and pre-seed Letta settings
RUN mkdir -p /home/node/.letta

# Pre-seed the startup flow: skip auto-connect on first run
# The agent will be configured via /connect or env vars at runtime
RUN echo '{"lastAgent":null,"tokenStreaming":false,"globalSharedBlockIds":{},"preferredBackendMode":"local"}' > /home/node/.letta/settings.json

# Set up the user home and ensure node owns everything
RUN chown -R node:node /home/node

# Switch to the node user for runtime.
# talk.sh execs `letta --resume` as the node user.
USER node

# Use `tail -f /dev/null` as the no-op init so the container stays alive.
# s6-overlay is overkill here — Letta doesn't need a background gateway.
CMD ["sh", "-c", "tail -f /dev/null"]
