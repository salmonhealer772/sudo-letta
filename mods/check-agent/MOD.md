---
name: "@letta-ai/check-agent"
description: "Agent-callable read of a sibling's trail — full event stream or compressed transcript, at any depth."
---

# check-agent mod semantics

## When to use

Use `check_agent` before messaging a sibling, or whenever you need to know
**what another agent has been doing** or **what it is doing right now**: it is
the ONE observability read for the fleet. It replaces the former
`check-agent-logs` and `check-what-agent-is-doing` tools; there is no separate
status/ps surface — the "what is it doing now" answer falls out of the freshest
trail entries (current conversation + latest `process_state`).

## Tool

This package registers one tool:

- `check_agent(sibling, n?, mode?)` — reads a sibling's trail.

## Inputs

| input     | required | meaning |
| --------- | -------- | ------- |
| `sibling` | yes      | agent name, resolved live: exact → case-insensitive → substring → ambiguous/not-found |
| `n`       | no       | trailing depth. `k>0` = last `k`; `-1` = the ENTIRE file (no cap); omitted = `100` |
| `mode`    | no       | `"full"` (default) = the raw event trail; `"compressed"` = the plain chat transcript |

## Modes

- **full (default)** → `GET http://<watch ClusterIP>:8000/events?n=N` on the
  sibling's `-watch` sidecar. Every event: `user`, `thinking`, `assistant`,
  `tool_call`, `tool_result`, `session`, `process_state`. Served as
  `application/x-ndjson` — one JSON object per line, schema
  `{ts, conversation, event, ...}`. `n=-1` → the entire events file; omitted →
  the sidecar's default of 100.
- **compressed** → reads the sibling's `transcript.txt` file **directly** (the
  same read `stream.sh -t` does): only real prompts (`You:`) and replies
  (`Agent:`), no thinking/tool noise. `n=-1` → `cat` the whole transcript;
  omitted → `tail -n 100`.

## How it reaches the sibling

Sibling `-watch` service **DNS does not resolve from inside an agent pod**, so
the tool resolves the live **ClusterIP** from the host instead:

    docker run --rm --privileged --pid=host --net=host -v /:/host \
      alpine:latest nsenter -t 1 -m -u -i -n -p -- \
      env KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get services -n default

and then GETs `http://<ClusterIP>:8000/events?n=N` (full mode) or runs
`kubectl exec deploy/sudo-{sibling} -c watch -- tail -n N <path>` through the
same bridge (compressed mode). Every call is live: no cache, no address book.

The transcript path depends on the sibling's kind, detected from the live
Deployment (`app` label / first container name):

- Letta planner (`app=sudo-letta`) → `/home/node/.letta/watch/transcript.txt`
- Hermes engineer (`app=sudo-agent`) → `/opt/data/watch/transcript.txt`
  (fallback `/home/node/.hermes/transcript.txt`)

## Resolution rules

- Only services named `sudo-<bare>-mcp` / `sudo-<bare>-watch` pair up; the
  header, `kubernetes`, `sudo-*-redis` and `sudo-*-svc` are skipped.
- Exactly ONE leading `sudo-` and ONE trailing `-mcp`/`-watch` are stripped, so
  the maintainer pair reports as `sudo-agent-maintainer-h`.
- An unknown name yields a clear `not found` error; a substring matching more
  than one sibling yields an `ambiguous` error listing the candidates.

## Important behavior

- Read-only, `parallelSafe: true`, `requiresApproval: false`.
- The tool never throws: bridge, HTTP, and exec failures come back as an error
  result carrying the underlying stderr/message.
- Nothing outside the roster Services, the target Deployment label, the
  `-watch` HTTP tap, and the sibling transcript file is read.
