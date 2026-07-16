# sudo-letta — Letta Code with root access inside Docker
FROM node:22-bookworm-slim

LABEL sudo-letta="true" description="Letta Code with sudo + native memory"

# Install ONLY what node-pty needs to compile + useful tools
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

# Passwordless sudo for node user
RUN echo "node ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/node && \
    chmod 0440 /etc/sudoers.d/node

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
