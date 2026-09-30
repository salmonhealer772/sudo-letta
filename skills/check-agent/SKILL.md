---
name: check-agent
description: Read a sibling agent's trail — what it has been doing and what it is doing right now, from the same trail. Use when you want to catch up on a sibling before messaging it, or to see its current state (idle vs active). This is the ONE observability read for the fleet.
---

# check-agent

> **THIS IS A START, NOT A FULL PRODUCT.** It contains the critical info — what the tool does and every way to call it — so it is immediately usable. It is not yet the polished procedural guidance (when-to-use nuance, examples, gotchas) a finished skill will have.

## What it does

Reads a sibling's **trail**, and it is the ONE observability read: it answers BOTH **what has it been doing** and **what is it doing right now** from that same trail. The what-is-it-doing-now answer falls out of the **freshest entries** — a small `n` returns the newest events, which carry the current conversation and the latest `process_state` (idle vs active). There is **no separate `/status` or `/ps` surface** to call any more.

**This is the merged tool.** It replaces the former `check-agent-logs` AND `check-what-agent-is-doing` — one tool, one depth knob, two modes.

It works **identically on Letta planners and Hermes engineers** — they keep their transcripts at different paths, and the tool picks the right one per sibling kind.

Load this skill **before messaging a sibling you want to catch up on** — read the trail first so your prompt lands in context.

## Every way to call it

One required argument; two optional flags.

```python
check_agent(sibling, n=None, mode="full")
```

- `sibling` (required) — which agent to read. Bare name, e.g. `ya-glm-l`.

```python
check_agent("ya-glm-l")                          # full trail, default depth (100)
check_agent("ya-glm-l", n=10)                    # full trail, the last 10 events
check_agent("ya-glm-l", n=-1)                    # full trail, the ENTIRE events file
check_agent("ya-glm-l", mode="compressed")       # the plain chat log, default depth
check_agent("ya-glm-l", n=-1, mode="compressed") # the ENTIRE transcript
```

## The flags

| flag | required | default | what it does |
|---|---|---|---|
| `sibling` | yes | — | which sibling to read, by bare name. |
| `n` | no | `None` | trailing depth, **identical in both modes**: `k>0` = the last k entries; `n=-1` = the ENTIRE file (no depth cap, so you never guess a huge number); omitted = the default depth of `100`. Anything else — `0`, or a negative other than `-1` — is rejected as invalid. |
| `mode` | no | `"full"` | `"full"` = `GET /events?n=N` over HTTP — the raw trail (`user`/`thinking`/`assistant`/`tool_call`/`tool_result`/`session`/`process_state`). `"compressed"` = read `transcript.txt` directly — plain `You:`/`Agent:` chat, reasoning and tool calls stripped. |

There is no `fleet` argument to pass — the live roster and transport are wired in by the harness, not chosen by you. There is no `stream` flag (retired — to follow along, call again with a small `n`) and no `/status` or `/ps` facet flag. That is the complete public surface: `sibling`, `n`, `mode`.

## Full vs compressed (the one behavioral split)

- **full mode (default)** — `GET /events?n=N` on the sibling's `-watch` sidecar. Every event: thinking, tool calls, tool results, sessions, process states. The raw, unabridged trail of everything the agent has thought and done. Omit `n` and the request is plain `/events`, so the depth is the sidecar's own default of 100; `n=-1` returns the entire events file.
- **compressed mode** — reads the sibling's `transcript.txt` file directly over the bridge (`kubectl exec deploy/sudo-<sibling> -c watch -- tail -n N <transcript>`, or `cat` for `n=-1`), the plain chat log: only real user prompts and assistant replies. Thinking, tool calls/results, sessions, process states and system reminders are stripped. The tool picks the kind-correct path: a Letta planner's transcript is at `/home/node/.letta/watch/transcript.txt`, a Hermes engineer's at `/opt/data/watch/transcript.txt`.

Full goes over the HTTP tap; compressed reads the file on disk. Both take the same `n`.

Two things to know before you rely on a read:

- **A down sidecar is reported as down, not faked.** If the `-watch` sidecar answers with no valid event at all (a 503 page, an HTML error, a proxy in front of a dead port) or cannot be reached at all (refused/reset), the read fails with "…appears down" rather than handing you a pile of raw pseudo-events. A genuinely MIXED stream — valid events with a stray trailing line — is kept, and the stray line stays visible as `event: raw`.
- **An empty trail is annotated, not blank.** Zero events (full) and "no spoken lines" (compressed) both come back with an explicit "the sibling has not spoken yet" note, instead of an empty result you might misread as a failure.

In full mode, `tool_result` events are capped at 4096 bytes, with `truncated` true and `full_bytes` reporting the untruncated size.

## Name resolution (how `sibling` is matched)

Exact match → case-insensitive → unique substring → **ambiguous** (errors, listing candidates) → **not found** (errors). If unsure of the exact name, call `list-siblings` first.

## When to reach for it first

- **Before you message a sibling** you want to catch up on — read the trail so your prompt lands in context instead of cold.
- **When you need to know what a sibling is doing right now** — a small `n` (say `10`) gives the freshest events; the newest `process_state` says idle vs active, and the current conversation is the one those events belong to.
- **When you want the gist rather than the machinery** — `mode="compressed"` is the plain chat log (prompts + replies only); use it to see what was actually said, and full mode when the thinking/tool detail is the point.
- **When you need the whole history** — `n=-1` returns the entire file in either mode, with no depth cap to guess at.
