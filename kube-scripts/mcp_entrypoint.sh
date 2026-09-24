#!/bin/sh
# Per-pod MCP supervisor: keep the MCP HTTP server running and the pod alive.
#
# This is the sudo-letta container CMD. It starts the MCP server (the FastMCP
# streamable-HTTP wrapper over letta-p) in the background, then execs
# `tail -f /dev/null` so the container stays up for the other exec-based flows
# (up.sh's `letta connect`, interactive shells, `kubectl exec ... letta`).
#
# The MCP server is (re)started in a loop so a crash doesn't take the endpoint
# down permanently. MCP_PORT is the per-agent port (unique because every
# sudo-letta pod runs hostNetwork:true and would otherwise collide); it defaults
# to 8000 and is normally injected by up.sh.

set -u

PORT="${MCP_PORT:-8000}"

(
  while :; do
    HOME=/home/node MCP_PORT="$PORT" python3 /opt/letta-mcp/mcp_server.py || true
    sleep 2
  done
) &

exec tail -f /dev/null
