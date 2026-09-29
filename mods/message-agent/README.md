# @letta-ai/message-agent

A Letta Code mod package that gives an agent one extra tool: **`message_agent`** --
message any sibling agent in the sudo-fleet by bare name and read its reply.

## What it does

Resolves a sibling from the live cluster roster, opens an MCP session against
its `-mcp` door, and calls its prompt tool (`letta_prompt` for a planner,
`hermes_prompt` for an engineer -- auto-detected from the tool list), then
returns the reply.

## Usage

Ask the agent to message a sibling:

- "message fa-glm-h: say hi"
- "ask ms-glm-l who it is, and report the reply"
- "message fa-glm-h 'run the build' with mode=inbox"

## Delivery modes

- `direct` (default) -- send and WAIT for the full reply (no timeout).
- `inbox` -- enqueue and return a message id immediately; fetch the reply
  later via the sibling's `*_queue_status` tool.

## Install (per agent pod)

The package directory lives under the agent's mods root and is declared in
`packages.json`:

    ~/.letta/mods/packages/npm/@letta-ai/message-agent/
      package.json
      MOD.md
      README.md
      mods/index.mjs

    ~/.letta/mods/packages.json  ->  packages[] entry, enabled: true

No build step is needed: the entry is plain ESM (`mods/index.mjs`), and the
Letta Code CLI activates mods on process start.

## Requirements

- The pod must be privileged with `/var/run/docker.sock` mounted and `docker` on
  `$PATH` (the standard sudo-letta pod shape).
- The host must have `kubectl` + `/etc/rancher/k3s/k3s.yaml` (k3s default).

## Scope

Sends prompts to sibling agents via their `-mcp` service. It reads the Service
list (read-only) to resolve the sibling's ClusterIP and never touches pods,
secrets, or writable cluster state directly.
