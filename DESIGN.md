# Design — sudo-letta

## What It Is

One command. Letta Code on any API — contained in Docker. Multiple agents by name, each isolated in its own container with full root access and zero host escape.

## Scripts (`scripts/`)

| Script | What | Notes |
|---|---|---|
| `setup.sh` | One-time: builds Docker image, prompts for API key | Run once per machine |
| `scripts/up.sh --name` | Create or restart `sudo-{name}` container | Generates sudo password on first run |
| `scripts/talk.sh --name` | `docker exec -it sudo-{name} letta --resume` | Talks to the agent |
| `scripts/ssh.sh --name` | `docker exec -it sudo-{name} bash` | Root shell |
| `scripts/down.sh --name` | Stop `sudo-{name}`, volume persists | Memory survives |
| `scripts/rm-containers.sh --name` | Force-remove one container | — |
| `scripts/rm-containers.sh --ALL` | Force-remove **all** `sudo-*` containers | Nuke button |

## Naming

- Container: `sudo-{name}`
- Volume: `sudo-{name}-data`
- `--ALL` is reserved. Every script rejects `--all` as a container name.

## Config

- `~/.sudo-letta/.env` — API keys, sudo password
- `~/.sudo-letta/settings.json` — Letta settings (model, provider, perms)

## Inside Each Container

- Letta Code CLI installed globally
- Letta headless server running in background (serves the agent runtime)
- `sudo` access — agent can do anything inside its cage
- Native Letta memory (MemFS, memory blocks, auto-learning — no patch needed)
- Tools: bash, git, python, node, ripgrep, ffmpeg, docker-cli, curl, openssh
- **Cannot reach the host** — Docker security boundary

## How Memory Works (Letta Native)

Letta Code has built-in persistent memory. Agents programmatically rewrite their own memory blocks to learn and adapt over time. No patches needed — it ships with:
- **Memory blocks** — system prompt learning, auto-evolution
- **MemFS** — all context tracked via git, syncable to GitHub
- **Message search** — FTS5 across all conversations
- **Skills** — agents create and load their own skills

## MCP Service

Each `sudo-{name}` pod runs an MCP server (streamable HTTP) that wraps the
`letta-p` prompt surface. It is deployed by `up.sh` as part of the same generated
YAML, and runs inside the pod (as `node`, `HOME=/home/node`), so it prompts that
pod's own agent directly — no kubectl, no kubeconfig, no cross-agent routing.

- **Service**: `sudo-{name}-mcp` (ClusterIP). Stable client-facing port `8000`,
  targetPort a unique per-agent port (derived from the agent name) because every
  sudo-letta pod runs `hostNetwork: true` and a fixed port would collide.
- **URL**: `http://sudo-{name}-mcp:8000/mcp`
- **Tool**: `letta_prompt(prompt, stream=false, json=false, new_chat=false)` —
  a 1:1 mapping of letta-p.py's flags (prompt / `--stream` / `--json` /
  `--new-chat`). Default resumes the persisted conversation; `new_chat` forces a
  fresh one.
- **Single source of truth**: `kube-scripts/letta_prompt.py` holds the letta
  command construction, resume logic, settings.json conversationId parsing,
  stream-json delta parsing, and json-output parsing. Both `letta-p.py` (host
  CLI) and `mcp_server.py` (in-pod MCP) import it.
- **Image**: `letta_prompt.py`, `mcp_server.py`, and `mcp_entrypoint.sh` are
  copied into the image (plus `fastmcp` installed via pip); the container CMD is
  the entrypoint, which starts the MCP server in the background and keeps the
  pod alive with `tail -f /dev/null`.
- **Limitation**: `--list` / cross-agent name resolution is host-side only (needs
  `kubectl`/kubeconfig) and is intentionally not exposed by the per-pod MCP.

## Stack

Letta Code by Letta AI (TypeScript, Apache license). Docker. Alpine/busybox for volume chown. Any OpenAI-compatible API.
