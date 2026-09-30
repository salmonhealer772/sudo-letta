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

# Resolves the listen port from MCP_PORT (injected by up.sh as a unique
# per-agent port) with an 8000 fallback, because every pod runs
# hostNetwork:true and a hardcoded port would collide across agents on the same
# node; if MCP_PORT is unset, the 8000 default keeps the server reachable in
# simple/docker runs.
PORT="${MCP_PORT:-8000}"

# Runs the MCP server in a background restart loop, because a single crash
# would otherwise take the endpoint down for the rest of the pod's life; if the
# server exits (crash or config error), the `|| true` prevents the loop from
# dying and it sleeps 2s before retrying. HOME is forced to /home/node so
# Letta's state resolves against the PVC, not /root.
(
  while :; do
    HOME=/home/node MCP_PORT="$PORT" python3 /opt/letta-mcp/mcp_server.py || true
    sleep 2
  done
) &

# Keeps the container alive as PID 1 after the MCP loop is backgrounded,
# because the pod's other flows (letta connect, interactive exec shells,
# kubectl exec letta) all require a running container; if this tail ever
# exited, the pod would terminate and Kubernetes would restart it.
exec tail -f /dev/null
