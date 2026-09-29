---
name: "@letta-ai/message-agent"
description: "Agent-callable tool to message any sibling agent in the sudo-fleet by name and read its reply."
---

# message-agent mod semantics

## When to use

Use `message_agent` whenever you need another agent in the fleet to do or
answer something: delegate, ask, coordinate, hand off. It is the primary way
agents work together -- address a sibling by bare name, hand it a prompt, read
the reply. Call `list_siblings` first if you are unsure of a sibling's exact
name.

## Tool

This package registers one tool:

- `message_agent(sibling, prompt, mode="direct", new_chat=false, json=false, source=null)`

## How it reaches the sibling

The tool resolves the sibling from the live cluster roster (via the
docker-socket + nsenter host bridge, `kubectl get services -n default`), then
opens an MCP session against the sibling's `-mcp` service:

    initialize -> notifications/initialized -> tools/list -> tools/call

Because the k8s DNS name `sudo-<name>-mcp` does NOT resolve from inside a pod,
the tool uses the sibling's ClusterIP (read from the CLUSTER-IP column of
`kubectl get services`), not the DNS name.

The sibling's kind is learned from its MCP tool list at initialize:

- a Letta planner exposes `letta_prompt` (stateful: resumes its persisted
  conversation unless `new_chat=true`)
- a Hermes engineer exposes `hermes_prompt` (stateless one-shot; `new_chat` is
  ignored and not sent)

## Parameters

- `sibling` (required string) -- bare name, e.g. `fa-glm-h`, `ms-glm-l`.
  Resolved exact -> case-insensitive -> unique substring -> error.
- `prompt` (required string) -- the message.
- `mode` (optional, "direct" | "inbox") -- "direct" (default) sends and waits
  for the full reply (no timeout); "inbox" enqueues and returns a message id
  immediately.
- `new_chat` (optional bool) -- planners only; true = fresh conversation.
- `json` (optional bool) -- true = structured reply.
- `source` (optional string) -- a stable tag grouping your messages in the
  recipient's queue.

## Important behavior

- The sender only sends; the recipient's Redis-backed distributor does all
  ordering/concurrency (queues and feeds one at a time, drops nothing).
- Direct mode imposes no client-side timeout, so long jobs are not cut.
- `requiresApproval: false`, `parallelSafe: true`.
- The tool never throws: roster/bridge/MCP failures are returned as an error
  result with the underlying detail.
