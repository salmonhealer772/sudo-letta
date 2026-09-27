#!/usr/bin/env python3
"""Per-pod MCP (Model Context Protocol) server for sudo-letta.

A thin wrapper over the ``letta-p.py`` prompt surface: it exposes the
``letta_prompt`` tool whose arguments map 1:1 to letta-p.py's flags, and it
invokes the Letta CLI *directly* against THIS pod's own agent (already pinned via
settings.json) — no kubectl, no kubeconfig, no cross-agent routing.

It runs INSIDE a sudo-letta pod (as the ``node`` user, HOME=/home/node) and
serves streamable HTTP (the modern MCP-over-HTTP transport) on ``MCP_PORT``
(default 8000). The endpoint path is ``/mcp``.

PROMPT DISTRIBUTOR (queue) LAYER
--------------------------------
Between the agent's MCP door and the agent's brain sits a Redis-backed queue.
The ``letta_prompt`` tool NO LONGER spawns the Letta CLI immediately; it
ENQUEUES the prompt and a single in-pod drain worker feeds the agent ONE
prompt at a time. N rapid prompts = N queued runs, never N parallel runs
racing the same agent state.

Tool surface:
    letta_prompt(prompt, stream=False, json=False, new_chat=False,
                 mode="direct", source="")
        mode "direct": enqueue and WAIT for the reply (synchronous, no
                       timeout — long jobs are fine).
        mode "inbox":  enqueue and return a message id immediately.
        source:        id of the MCP client/session that enqueued (used for
                       the group-by-source ordering rule; defaults to "default").

    letta_queue_status()
        Pending queue + recent processed results (ids, sources, timestamps)
        — the operator's observability window into the distributor.

ORDERING RULES (implement verbatim, see DESIGN.md):
    a. first message in = processed first
    b. then drain ALL remaining messages from that same source before anyone else
    c. when empty, move to the NEXT MOST RECENT source and drain it fully
    d. FIFO within a source
    (source = the MCP client/session that enqueued; each enqueued message is
     tagged with a source id.)

Backing store: standard OSS Redis (``REDIS_URL``, default
redis://127.0.0.1:6379/0 — see kube-scripts/redis.yaml). Each agent has its
own queue namespace, keyed by this pod's unique MCP_PORT (every sudo-letta pod
runs hostNetwork:true, so ports are unique per pod).

Flag mapping (unchanged from letta-p.py):
    prompt    -> letta-p.py positional prompt
    stream    -> --stream     (stream-json deltas, collected & returned joined)
    json      -> --json       (--output-format json)
    new_chat  -> --new-chat   (--new)

NOT exposed here (host-side only — needs kubectl/kubeconfig):
    --list / cross-agent name resolution. Inside a pod there is no apiserver
    access; this pod IS the agent. See DESIGN.md and letta_prompt.py.
"""

import json as _json
import os
import subprocess
import threading
import time
import uuid

import redis
from fastmcp import FastMCP

import letta_prompt as lp

SETTINGS_PATH = "/home/node/.letta/settings.json"
DEFAULT_PORT = 8000

# ---------------------------------------------------------------------------
# Queue / Redis wiring
# ---------------------------------------------------------------------------
REDIS_URL = os.environ.get("REDIS_URL", "redis://127.0.0.1:6379/0")

# Per-agent namespace: unique because every sudo-letta pod is hostNetwork and
# gets a unique MCP_PORT injected by up.sh. POD_NAME is used when present
# (clearer in redis) — k3s does not inject it by default, hence the fallback.
QUEUE_BASE = os.environ.get(
    "QUEUE_NAME",
    "sudo-letta:q:" + (os.environ.get("POD_NAME") or os.environ.get("MCP_PORT", "8000")),
)
ITEMS_KEY = QUEUE_BASE + ":items"


def _res_key(msg_id):
    return QUEUE_BASE + ":res:" + msg_id


def _redis_client():
    """Single Redis connection factory (redis-py, decode_responses=True)."""
    return redis.Redis.from_url(REDIS_URL, decode_responses=True)


mcp = FastMCP("sudo-letta")

# ---------------------------------------------------------------------------
# Letta invocation (unchanged semantics from the pre-queue implementation)
# ---------------------------------------------------------------------------


def _read_settings_text():
    """Best-effort read of this pod's settings.json (resume source of truth)."""
    try:
        with open(SETTINGS_PATH, "r", encoding="utf-8") as fh:
            return fh.read()
    except OSError:
        return ""


def _run_collect(cmd):
    """Run a letta command and return (exit_code, stdout, stderr)."""
    proc = subprocess.run(cmd, capture_output=True, text=True, shell=True)
    return proc.returncode, proc.stdout, proc.stderr


def _run_stream(cmd):
    """Run a letta command in stream-json mode; return (exit_code, joined_deltas, stderr)."""
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, shell=True)
    deltas = list(lp.iter_assistant_deltas(proc.stdout))
    proc.wait()
    return proc.returncode, "".join(deltas), proc.stderr.read().strip()


def _execute_prompt(prompt, stream=False, json_mode=False, new_chat=False):
    """Run ONE prompt against this agent. Returns (ok, output, error)."""
    conv_id = lp.get_conversation_id_from_settings(_read_settings_text())
    resume = lp.resume_fragment(conv_id, new_chat)

    try:
        if stream:
            cmd = lp.build_letta_command(prompt, resume, "stream-json")
            rc, text, stderr = _run_stream(cmd)
            if rc != 0:
                return False, "", f"letta failed (rc={rc}): {stderr}"
            return True, text, ""

        if json_mode:
            cmd = lp.build_letta_command(prompt, resume, "json")
            rc, out, stderr = _run_collect(cmd)
            if rc != 0:
                return False, "", f"letta failed (rc={rc}): {stderr or out}"
            out = out.strip()
            parsed = lp.parse_json_output(out)
            if parsed is None:
                return True, out, ""
            if isinstance(parsed, dict) and "result" in parsed:
                return True, _json.dumps(parsed, indent=2), ""
            return True, out, ""

        cmd = lp.build_letta_command(prompt, resume)
        rc, out, stderr = _run_collect(cmd)
        if rc != 0:
            return False, "", f"letta failed (rc={rc}): {stderr or out}"
        return True, out.strip(), ""
    except Exception as exc:  # never lose the reply to a harness error
        return False, "", f"internal error: {exc}"


# ---------------------------------------------------------------------------
# Distributor: enqueue + one-at-a-time drain worker
# ---------------------------------------------------------------------------


def _enqueue(r, prompt, stream, json_mode, new_chat, source):
    """Append one message to this agent's queue; return its message id."""
    msg_id = "msg-" + uuid.uuid4().hex[:12]
    item = {
        "id": msg_id,
        "source": source or "default",
        "prompt": prompt,
        "stream": bool(stream),
        "json": bool(json_mode),
        "new_chat": bool(new_chat),
        "enqueued_at": time.time(),
    }
    r.rpush(ITEMS_KEY, _json.dumps(item))
    return msg_id


def _load_items(r):
    """All pending items in arrival (FIFO) order."""
    return [_json.loads(raw) for raw in r.lrange(ITEMS_KEY, 0, -1)]


def _pick_next(items, last_source):
    """Apply the ordering rule to the pending list; return one item or None.

    a. no last_source (fresh start) -> the FIRST message in (items[0])
    b. else, if the last-processed source still has messages -> its earliest
    c. else -> the source of the MOST RECENTLY arrived message, earliest of it
    d. within a source: always earliest first (FIFO)
    """
    if not items:
        return None
    if last_source is not None:
        for it in items:
            if it["source"] == last_source:
                return it
        most_recent_source = items[-1]["source"]
        for it in items:
            if it["source"] == most_recent_source:
                return it
    return items[0]


def _store_result(r, item, ok, output, error, started_at, finished_at):
    record = {
        "id": item["id"],
        "source": item["source"],
        "prompt": item["prompt"],
        "ok": ok,
        "output": output,
        "error": error,
        "enqueued_at": item["enqueued_at"],
        "started_at": started_at,
        "finished_at": finished_at,
    }
    # 7-day TTL: results are for delivery/inspection, not archival.
    r.set(_res_key(item["id"]), _json.dumps(record), ex=7 * 24 * 3600)


def _drain_worker():
    """Single consumer: feeds the agent ONE prompt at a time, forever."""
    last_source = None
    while True:
        try:
            r = _redis_client()
            while True:
                item = None
                raw_items = r.lrange(ITEMS_KEY, 0, -1)
                items = [_json.loads(x) for x in raw_items]
                item = _pick_next(items, last_source)
                if item is None:
                    time.sleep(0.25)
                    continue
                started_at = time.time()
                ok, output, error = _execute_prompt(
                    item["prompt"], item["stream"], item["json"], item["new_chat"]
                )
                finished_at = time.time()
                _store_result(r, item, ok, output, error, started_at, finished_at)
                r.lrem(ITEMS_KEY, 1, _json.dumps(item))
                last_source = item["source"]
        except Exception:
            # Redis hiccup / restart: back off, then reconnect and keep going.
            time.sleep(1.0)


# ---------------------------------------------------------------------------
# MCP tools
# ---------------------------------------------------------------------------


def _session_source():
    """Best-effort FastMCP session id as the implicit source tag."""
    try:
        from fastmcp.server.dependencies import get_context

        ctx = get_context()
        return getattr(ctx, "session_id", None) or None
    except Exception:
        return None


@mcp.tool()
def letta_prompt(
    prompt: str,
    stream: bool = False,
    json: bool = False,
    new_chat: bool = False,
    mode: str = "direct",
    source: str = "",
) -> str:
    """Send a prompt to THIS sudo-letta agent through the prompt distributor.

    The prompt is enqueued in Redis and fed to the agent by a single drain
    worker — at most ONE prompt runs against the agent at any moment; extra
    prompts are held in the queue (never dropped, never concurrent).

    Args:
        prompt: The message to send.
        stream: Select the --stream path (stream-json deltas, returned joined).
        json: Return the raw JSON object from --output-format json.
        new_chat: Start a fresh conversation (--new) instead of resuming.
        mode: "direct" (default) — enqueue and WAIT for the reply (no timeout,
            safe for long jobs). "inbox" — enqueue and return the message id
            immediately; fetch the reply later via letta_queue_status.
        source: Id of the enqueuing MCP client/session (ordering rule b/c
            groups by source). Defaults to the FastMCP session id, or
            "default" when none is available.
    """
    r = _redis_client()
    src = source or _session_source() or "default"
    msg_id = _enqueue(r, prompt, stream, json, new_chat, src)

    if mode == "inbox":
        return _json.dumps({"id": msg_id, "queued": True, "status": "pending", "source": src})

    if mode != "direct":
        raise ValueError(f"unknown mode {mode!r} (expected 'direct' or 'inbox')")

    # direct: enqueue + WAIT for the reply. No timeout — long jobs are fine.
    while True:
        raw = r.get(_res_key(msg_id))
        if raw:
            record = _json.loads(raw)
            if not record["ok"]:
                raise RuntimeError(record["error"])
            return record["output"]
        time.sleep(0.25)


@mcp.tool()
def letta_queue_status() -> str:
    """Return the pending prompt queue and the most recent processed results.

    Each result carries: id, source, ok, started_at, finished_at, error
    (output elided to 200 chars to keep the payload small). Use this to watch
    the one-at-a-time / group-by-source drain order, and to fetch inbox-mode
    replies by message id.
    """
    r = _redis_client()
    items = _load_items(r)
    results = []
    for key in r.scan_iter(_res_key("*")):
        raw = r.get(key)
        if raw:
            results.append(_json.loads(raw))
    results.sort(key=lambda rec: rec.get("started_at") or 0)
    trimmed = []
    for rec in results[-20:]:
        out = rec.get("output", "")
        rec = dict(rec)
        rec["output"] = out[:200] + ("…" if len(out) > 200 else "")
        trimmed.append(rec)
    return _json.dumps(
        {
            "queue": {"key": QUEUE_BASE, "pending": [{"id": it["id"], "source": it["source"]} for it in items]},
            "results": trimmed,
        },
        indent=2,
    )


def main():
    port = int(os.environ.get("MCP_PORT", str(DEFAULT_PORT)))

    # Redis sanity check: fail FAST and LOUD at startup, not on first prompt.
    try:
        _redis_client().ping()
    except Exception as exc:
        raise SystemExit(
            f"[mcp_server] FATAL: cannot reach Redis at {REDIS_URL} ({exc}). "
            "The prompt distributor requires it — see kube-scripts/redis.yaml."
        )

    worker = threading.Thread(target=_drain_worker, name="drain-worker", daemon=True)
    worker.start()
    mcp.run(transport="http", host="0.0.0.0", port=port)


if __name__ == "__main__":
    main()
