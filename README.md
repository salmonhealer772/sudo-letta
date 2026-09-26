# sudo-letta

**One command. Letta Code with full root inside a privileged container.**

## What It Does

- **Native memory** — Letta Code remembers everything out of the box. No patches, no hacks. MemFS tracks all context in git.
- **Auto-learning** — agents rewrite their own memory blocks, skills, and prompts over time. They actually get smarter with use.
- **Full sudo** — the agent has root access inside its own container. Can `apt install`, `sudo` anything, edit configs, do whatever it wants.
- **Privileged mode** — containers run with `--privileged` so the agent can do anything inside its box (mount, kernel features, etc.).
- **Caveat emptor** — privileged containers have a direct path to the host kernel. This is by design (agent needs full control), but if the agent goes rogue it could potentially escape. The Docker cgroup is the only barrier.
- **Multi-agent** — run alice, bob, charlie in parallel. Each gets its own container, brain, memory, and sudo password.
- **CLI in the container** — git, docker-cli, openssh, python, node, ripgrep, ffmpeg, curl. Full terminal.

## Quick Start

```bash
git clone https://github.com/salmonhealer772/sudo-letta.git && cd sudo-letta
bash setup.sh              # builds image, asks for API key once
```

```bash
bash scripts/up.sh --alice      # create or restart "alice" (generates sudo password)
bash scripts/talk.sh --alice   # talk to "alice" (opens Letta Code TUI)
bash scripts/ssh.sh --alice     # root shell — no password needed
bash scripts/down.sh --alice    # stop "alice" (memory persists)
bash scripts/rm-containers.sh --ALL  # kill all sudo-* containers
```

Multiple agents:

```bash
bash scripts/up.sh --alice
bash scripts/up.sh --bob
bash scripts/talk.sh --alice   # talks to alice
bash scripts/talk.sh --bob     # talks to bob
```

Each name → own container, own volume, own memory, own sudo.
Bring it down → remembers everything. Bring it up → where you left off.

## Security Model

| Boundary | Access | Risk |
|---|---|---|
| Inside container | Full root. `sudo` anything, install packages, mount filesystems, load kernel modules. | By design — agent needs full control. |
| Outside (host) | **Soft barrier.** Docker + `--privileged` = the kernel is the only separation. A compromised agent could exploit kernel CVEs, use `--pid=host`-style escapes, or abuse cgroup bypasses. | **Real.** This is not a hardened sandbox. |
| Between containers | **None.** alice can't see bob's volume or processes (separate containers). | Low — but a privileged agent could attack the host and reach others. |

The sudo password is random 16-char alphanumeric, generated on first `up.sh`, saved to `.sudo-letta/.env` (inside the repo directory). The agent gets it via env var.

`--ALL` is reserved for `rm-containers.sh`. No script accepts `--all` as a container name.

## API Key Setup

On first run, `setup.sh` (or `up.sh`) prompts you for an API key. Supported providers (via Letta Code's `/connect`):

- **OpenAI** — `https://api.openai.com/v1`
- **Anthropic** — `https://api.anthropic.com`
- **DeepSeek** — `https://api.deepseek.com/v1` (OpenAI-compatible)
- **Z.ai** — coding plan models
- **Any OpenAI-compatible endpoint** — set your own base URL

You can also run `/connect` inside the agent to change providers later.

## Why Letta Code instead of Hermes?

Letta Code has native, well-tested memory that actually works — agents rewrite their own memory blocks, learn from experience, and get better over time. Hermes needed a hacky patch (`patch_memory_review.py`) to achieve basic auto-save. Letta ships this built-in, plus:

- MemFS (git-tracked memory)
- Skill learning (agents create their own skills)
- Subagents & multi-agent orchestration
- Native permissions system
- Built-in hooks and scheduling

## MCP Service (every pod)

Every sudo-letta pod runs a per-pod **MCP (Model Context Protocol) server** that
exposes the `letta-p.py` prompt surface over HTTP — a thin wrapper with the same
flags and nothing more. It is fronted by a Kubernetes Service named
`sudo-<name>-mcp`.

- **Endpoint** (streamable HTTP, from inside the cluster):
  `http://sudo-<name>-mcp:8000/mcp`
- **Tool**: `letta_prompt`
  - `prompt` (string, required) — the message to send
  - `stream` (bool, default false) — maps to `--stream` (stream-json path)
  - `json` (bool, default false) — maps to `--json` (`--output-format json`)
  - `new_chat` (bool, default false) — maps to `--new-chat` (`--new`)
- **Semantics**: a one-shot prompt to *that pod's own* agent. By default it
  resumes the agent's persisted conversation; `new_chat` starts a fresh one.
  The MCP server invokes the Letta CLI directly inside the pod (no kubectl).
- **Port**: the Service exposes a stable port `8000`; internally each pod
  listens on a unique per-agent port (auto-derived from the agent name) because
  every sudo-letta pod runs `hostNetwork: true` and a fixed port would collide.
- **Not exposed**: `--list` / cross-agent name resolution — that requires
  `kubectl`/kubeconfig and remains host-side (`kube-scripts/letta-p.py --list`).

## Stack

- [Letta Code](https://github.com/letta-ai/letta-code) by Letta AI — stateful agent harness with native memory
- Docker — each agent gets its own cage
- Node.js 22+ — Letta Code runtime

## Observer sidecar (every pod)

Every sudo-letta pod ships a second container, `watch`, that runs the observer-sidecar daemon (`kube-scripts/watch_sidecar.py`) alongside the agent:

- **Monitors** the agent container: is it up, what processes are running, and idle<->active transitions (a process is letta activity if its cmdline references letta). The pod runs `shareProcessNamespace: true`, so the sidecar sees the agent container's processes (PID 1 is the pause container; the agent CMD is unaffected).
- **Captures** everything the agent does — every prompt in, every reply out, all reasoning, every tool call + result — into `events.jsonl` on the agent PVC (`/home/node/.letta/watch/events.jsonl`), tailed from the Letta message store with persisted byte-offset watermarks.
- **Serves a live HTTP tap** so an operator can watch an agent's stream of consciousness in real time:
  - `GET /healthz` — liveness
  - `GET /status` — JSON: {agent, deploy, uptime_s, agent_container_up, active, current_conversation, last_event_ts, events_logged, watch_port}
  - `GET /ps` — JSON list of {pid,ppid,uid,age_s,cmdline} for every non-self process
  - `GET /events?n=100` — the last N event lines verbatim (JSONL)
  - `GET /stream` — live chunked tail of new events as they're appended (flush per event, stops on client disconnect)
- **Event schema** — one JSON object per line in `events.jsonl`, common `{"ts": <epoch>, "conversation": <decoded id>, "event": <type>}`; types: `user` {text}, `thinking` {text}, `assistant` {text}, `tool_call` {name,args}, `tool_result` {text,truncated,full_bytes}, `session` {id,cwd}, `process_state` {state,processes}.
- **Service** — `sudo-<name>-watch` (ClusterIP, port 8000 name "watch" -> targetPort WATCH_PORT, a unique per-agent port derived from `<name>-watch` for the same hostNetwork reason as MCP_PORT).
- **Tap it**:
  `kubectl exec deploy/sudo-<name> -c watch -- tail -f /home/node/.letta/watch/events.jsonl`
  and from the node: `curl http://$(kubectl get svc sudo-<name>-watch -o jsonpath='{.spec.clusterIP}'):8000/stream`
- **PRIVACY NOTE**: `events.jsonl` contains full prompts + reasoning + tool results. It lives on the agent PVC and the tap endpoints are in-cluster only. Treat the PVC as sensitive — anyone with cluster access can read an agent's entire stream of consciousness.
- The sidecar is unprivileged (no docker socket, no privileged securityContext — /proc reads work fine in the shared PID namespace), writes ONLY under `/home/node/.letta/watch`, and runs as `node`, same uid as the rest of the PVC.
