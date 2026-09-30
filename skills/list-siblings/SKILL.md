---
name: list-siblings
description: See every sibling agent in the fleet and how to reach them. Use when you need to know who else exists, confirm a sibling's exact name, or get the message/watch addresses to reach or observe another agent. Call this FIRST before messaging or checking on a sibling whose name you are not sure of.
---

# list-siblings

> **THIS IS A START, NOT A FULL PRODUCT.** It contains the critical info — what the tool does and every way to call it — so it is immediately usable. It is not yet the polished procedural guidance (when-to-use nuance, examples, gotchas) a finished skill will have.

## What it does

Returns the **live fleet roster**: every sibling agent, with its bare name and its two reach addresses. It is the discovery half of the mesh — read it when you're not sure who exists or what a sibling's exact name is, before you message or check on them.

Each entry is one agent with three fields:

| field | meaning |
|---|---|
| `sibling` | the bare name — what you pass to `message-agent` / `check-agent` |
| `mcp_host` | where to **send a prompt** (`sudo-<name>-mcp:8000`) |
| `watch_host` | where to **observe** it (`sudo-<name>-watch:8000`) |

The roster is **live**, not cached — it re-reads the fleet every call (`kubectl get services -n default` on the HOST, over the docker-socket + nsenter bridge every agent pod already has; no in-pod kubectl needed). A newly-spawned sibling appears and a removed one drops off automatically, with no edit to anything. A sibling only shows up once BOTH its `-mcp` and `-watch` services exist — `-redis` and every non-agent service are skipped.

## Every way to call it

One optional flag; no required arguments.

```python
list_siblings(filter=None)
```

- `filter` (optional) — substring to narrow the roster by bare name. Omit for the full fleet.

### 1. Full roster (no args)

```python
list_siblings()
```

Returns everyone. Each entry: `{sibling, mcp_host, watch_host}` — e.g. `fa-glm-l` → `sudo-fa-glm-l-mcp:8000` / `sudo-fa-glm-l-watch:8000`.

### 2. Filtered by substring

```python
list_siblings(filter="glm")
```

Narrows the roster to siblings whose bare name contains the substring. The flag has exactly three outcomes:

| filter result | returns |
|---|---|
| unique match | one entry |
| multiple matches | all matching entries |
| no match | empty list `[]` (clean empty — not an error, not a hang) |

An empty fleet gives the same clean empty list; the table form says so in words ("no sibling agents in the fleet" / "no matching siblings for filter …").

## Syntax reference (all the flags)

| flag | required | meaning |
|---|---|---|
| `filter` | no | substring to narrow the roster by bare name. Omit for the full fleet. |

There is no `fleet` argument to pass — the live roster and transport are wired in by the harness, not chosen by you. That is the complete public surface: `filter`. There are no other flags.

## Name resolution (how the roster's names are derived)

The `sibling` field is the **bare name**: the service name minus ONE leading `sudo-` and minus the trailing `-mcp`/`-watch` suffix. It maps by suffix, never by prefix-stripping, so a bare name that itself legitimately starts with `sudo-` (the maintainer pair) survives intact — deploy `sudo-sudo-agent-maintainer-h` → bare `sudo-agent-maintainer-h`.

That bare name is exactly what you hand to `message-agent` and `check-agent`, and the `mcp_host` on the same row is the address `message-agent` will reach. So the roster is not just a list — it is the phonebook the other two tools resolve against.

`filter` is a plain substring test against the bare name (case-sensitive). If you are unsure of the exact name, call this first and copy the name straight out of the roster.

## When to reach for it first

- **Before you message or check on a sibling whose name you are not sure of.** It is the fastest way to confirm the exact bare name — the other two tools error on an unknown name instead of guessing.
- **When you need to know who exists at all** — a name was handed to you and you want to confirm it is live, or you want to fan work out and need the candidate list.
- **When you need an address rather than a name** — the `mcp_host`/`watch_host` on the row are the live reach for messaging or observing that sibling.

Don't keep a phonebook in your head: the roster is read live on every call, so the answer it gives is the fleet right now.
