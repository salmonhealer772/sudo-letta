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

# Install Letta Code globally (cache layer)
RUN npm install -g @letta-ai/letta-code && \
    npm cache clean --force

# Pre-seed Letta config
RUN mkdir -p /home/node/.letta && \
    echo '{"lastAgent":null,"tokenStreaming":false,"globalSharedBlockIds":{},"preferredBackendMode":"local"}' > /home/node/.letta/settings.json && \
    chown -R node:node /home/node

# Create /.letta so the process can write local project settings without EACCES
RUN mkdir -p /.letta && chown -R node:node /.letta

USER node

WORKDIR /home/node/.letta

CMD ["sh", "-c", "tail -f /dev/null"]
