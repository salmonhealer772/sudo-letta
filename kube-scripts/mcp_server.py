#!/usr/bin/env python3
"""Per-pod MCP (Model Context Protocol) server for sudo-letta.

A thin wrapper over the ``letta-p.py`` prompt surface: it exposes a single
``letta_prompt`` tool whose arguments map 1:1 to letta-p.py's flags, and it
invokes the Letta CLI *directly* against THIS pod's own agent (already pinned via
settings.json) — no kubectl, no kubeconfig, no cross-agent routing.

It runs INSIDE a sudo-letta pod (as the ``node`` user, HOME=/home/node) and
serves streamable HTTP (the modern MCP-over-HTTP transport) on ``MCP_PORT``
(default 8000). The endpoint path is ``/mcp``.

Tool surface (== letta-p.py flags, nothing more, nothing less):
    letta_prompt(prompt, stream=False, json=False, new_chat=False)

Flag mapping:
    prompt    -> letta-p.py positional prompt
    stream    -> --stream     (stream-json deltas, collected & returned joined)
    json      -> --json       (--output-format json)
    new_chat  -> --new-chat   (--new)

NOT exposed here (host-side only — needs kubectl/kubeconfig):
    --list / cross-agent name resolution. Inside a pod there is no apiserver
    access; this pod IS the agent. See DESIGN.md and letta_prompt.py.

Note on ``stream``: letta-p.py's --stream prints deltas live to a terminal. Over
the MCP transport we run the same stream-json code path and return the full
concatenated reply text once complete. (Live per-token delivery over MCP
progress notifications is intentionally not implemented; the flag still selects
the stream-json path 1:1.)
"""

import json as _json
import os
import subprocess

from fastmcp import FastMCP

import letta_prompt as lp

SETTINGS_PATH = "/home/node/.letta/settings.json"
DEFAULT_PORT = 8000

mcp = FastMCP("sudo-letta")


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


@mcp.tool()
def letta_prompt(prompt: str, stream: bool = False, json: bool = False, new_chat: bool = False) -> str:
    """Send a one-shot prompt to THIS sudo-letta agent and return its reply.

    Args:
        prompt: The message to send.
        stream: Select the --stream path (stream-json deltas, returned joined).
        json: Return the raw JSON object from --output-format json.
        new_chat: Start a fresh conversation (--new) instead of resuming the
            agent's persisted conversation.
    """
    conv_id = lp.get_conversation_id_from_settings(_read_settings_text())
    resume = lp.resume_fragment(conv_id, new_chat)

    if stream:
        cmd = lp.build_letta_command(prompt, resume, "stream-json")
        rc, text, stderr = _run_stream(cmd)
        if rc != 0:
            raise RuntimeError(f"letta failed (rc={rc}): {stderr}")
        return text

    if json:
        cmd = lp.build_letta_command(prompt, resume, "json")
        rc, out, stderr = _run_collect(cmd)
        if rc != 0:
            raise RuntimeError(f"letta failed (rc={rc}): {stderr or out}")
        out = out.strip()
        parsed = lp.parse_json_output(out)
        if parsed is None:
            return out
        if isinstance(parsed, dict) and "result" in parsed:
            return _json.dumps(parsed, indent=2)
        return out

    cmd = lp.build_letta_command(prompt, resume)
    rc, out, stderr = _run_collect(cmd)
    if rc != 0:
        raise RuntimeError(f"letta failed (rc={rc}): {stderr or out}")
    return out.strip()


def main():
    port = int(os.environ.get("MCP_PORT", str(DEFAULT_PORT)))
    mcp.run(transport="http", host="0.0.0.0", port=port)


if __name__ == "__main__":
    main()
