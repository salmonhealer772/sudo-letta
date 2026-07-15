# sudo-letta

**One command. Letta Code with root inside its container. Zero escape.**

## What It Does

- **Native memory** — Letta Code remembers everything out of the box. No patches, no hacks. MemFS tracks all context in git.
- **Auto-learning** — agents rewrite their own memory blocks, skills, and prompts over time. They actually get smarter with use.
- **Full sudo** — the agent has root access inside its own container. Can `apt install`, `sudo` anything, edit configs, do whatever it wants.
- **Zero escape** — cannot reach the host. Even with full sudo, Docker is the boundary. Nothing leaves the container.
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

| Boundary | Access |
|---|---|
| Inside container | Full root. `sudo` anything, install packages, modify configs, destroy itself. |
| Outside (host) | **None.** Docker is the cage. Agent cannot touch the host. |
| Between containers | **None.** alice can't see bob's volume or processes. |

The sudo password is random 16-char alphanumeric, generated on first `up.sh`, saved to `~/.sudo-letta/.env`. The agent gets it via env var.

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

## Stack

- [Letta Code](https://github.com/letta-ai/letta-code) by Letta AI — stateful agent harness with native memory
- Docker — each agent gets its own cage
- Node.js 22+ — Letta Code runtime
