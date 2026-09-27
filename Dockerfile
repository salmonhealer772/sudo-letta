# sudo-letta — Letta Code with full root inside a privileged container
FROM node:22-bookworm-slim

LABEL sudo-letta="true" description="Letta Code with sudo + native memory"

# Install build deps + tools (node-pty compile deps, etc.)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    sudo \
    ca-certificates \
    curl \
    git \
    make \
    g++ \
    python3 \
    python3-pip \
    ripgrep \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

# Docker CLI from Docker's own apt repo. Debian bookworm's docker.io is
# 20.10 / API 1.41, which is too old to talk to a modern host daemon
# (needs API >= 1.44). docker-ce-cli tracks the daemon so they always match.
RUN install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends docker-ce-cli && \
    rm -rf /var/lib/apt/lists/*

# Passwordless sudo for node user
RUN echo "node ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/node && \
    chmod 0440 /etc/sudoers.d/node

# Give node a supplementary group with gid 109 = the host's docker group, so it
# can open the mounted /var/run/docker.sock. (Name is irrelevant — only the
# numeric gid matters, and it must match the host's gid 109.)
RUN groupadd --gid 109 dockerhost && usermod -aG dockerhost node

# Install Letta Code globally.
# PINNED to 0.33.2 (exact pin, not ^/latest): letta-code 0.33.0 silently broke
# loading of .ts-entry mods - the official web-search mod's tool never
# registered, with zero diagnostics. 0.33.2 is verified working with
# web_search (verified live 2026-09). Do NOT unpin without testing web_search
# on a recreated pod after any CLI upgrade.
RUN npm install -g @letta-ai/letta-code@0.33.2 && \
    npm cache clean --force

# Pre-seed Letta config
RUN mkdir -p /home/node/.letta && \
    echo '{"lastAgent":null,"tokenStreaming":false,"globalSharedBlockIds":{},"preferredBackendMode":"local"}' > /home/node/.letta/settings.json && \
    chown -R node:node /home/node

# Pre-install the official web-search mod so every FRESH agent is born with it
# (tool: web_search). Existing agents' PVCs already carry the mod and the PVC
# mounts over image contents, so this matters for NEW agents/PVCs only.
# MOD PIN: the mod is installed at an EXACT version (@0.1.0), never
# latest/^, so a breaking upstream release cannot silently kill
# web_search across the fleet. Bump deliberately and re-test live.
RUN su node -c 'HOME=/home/node letta install npm:@letta-ai/web-search@0.1.0'

# Create /.letta so the process can write local project settings without EACCES
RUN mkdir -p /.letta && chown -R node:node /.letta

# Per-pod MCP server: a streamable-HTTP wrapper over letta-p's prompt logic.
# letta_prompt.py is the single source of truth shared with kube-scripts/letta-p.py;
# mcp_server.py runs inside the pod and prompts THIS agent directly (no kubectl).
# mcp_entrypoint.sh starts the MCP server and keeps the pod alive (the CMD below).
COPY kube-scripts/letta_prompt.py /opt/letta-mcp/letta_prompt.py
COPY kube-scripts/mcp_server.py /opt/letta-mcp/mcp_server.py
COPY kube-scripts/mcp_entrypoint.sh /opt/letta-mcp/mcp_entrypoint.sh
# Observer sidecar daemon: monitors the agent container's processes, captures
# every prompt/reply/thinking/tool event from the Letta message store into a
# durable JSONL log on the agent PVC, and serves a live HTTP tap.
COPY kube-scripts/watch_sidecar.py /opt/letta-watch/watch_sidecar.py
RUN chmod +x /opt/letta-mcp/mcp_entrypoint.sh && \
    pip3 install --no-cache-dir --break-system-packages fastmcp==4.0.9 redis==5.2.1 && \
    chown -R node:node /opt/letta-mcp

USER node

WORKDIR /home/node/.letta

CMD ["sh", "/opt/letta-mcp/mcp_entrypoint.sh"]
