#!/usr/bin/env python3
"""Shared single source of truth for prompting a sudo-letta (Letta Code) agent.

Both ``kube-scripts/letta-p.py`` (host-side CLI) and the per-pod MCP server
(``kube-scripts/mcp_server.py``) import this module, so the hard-won details of
how to invoke the Letta CLI and parse its output live in exactly ONE place.

Two execution contexts
-----------------------
- **Host CLI** (``letta-p.py``): runs where ``kubectl`` + kubeconfig live. It
  resolves an agent by name, then shells out via
  ``kubectl exec deploy/sudo-<name> -- sh -c "<command>"``.
- **In-pod MCP** (``mcp_server.py``): runs *inside* a given sudo-letta pod, so
  it *is* that agent. It runs ``"<command>"`` directly with ``subprocess`` — no
  kubectl, no kubeconfig, no name resolution.

  Consequence: the ``--list`` / cross-agent name-resolution feature of
  ``letta-p.py`` cannot work from inside a pod (there is no apiserver access).
  The per-pod MCP exposes only the single-agent prompt surface; ``--list``
  remains a host-side concern (letta-p.py, or a future cluster-level MCP).

What this module owns (single source of truth)
----------------------------------------------
- the absolute path to ``letta.js`` (the ``letta`` shim on $PATH is temp-stamped
  and therefore not reliably on $PATH for the exec user),
- the settings.json key that holds the persisted conversationId (the resume
  source of truth),
- resume-vs-new argument construction,
- the letta CLI command-string builder,
- stream-json delta parsing,
- ``--output-format json`` result parsing.

Conventions that MUST NOT drift (all hard-won, do not change lightly)
---------------------------------------------------------------------
- letta is always invoked by absolute path (``node .../letta-code/letta.js``).
- always ``--backend local`` (avoids the Cloud default api.letta.com, which 401s
  with a BYOK deepseek key).
- always ``HOME=/home/node`` so the CLI reads the real provider config + agents
  (a root login shell would point HOME at /root/.letta -> empty provider config
  -> "Provider is not configured").
- resume-by-default: read the persisted conversationId and inject
  ``--conversation <id>``; ``--new`` forces a fresh chat; no id known -> the CLI
  creates a new chat on its own.
"""

import json

# Absolute path to the Letta Code CLI entry point. The ``letta`` shim installed
# to /usr/local/bin is temp-stamped (".letta-<rand>") so it is not reliably on
# $PATH for a non-login exec user; use the module path directly.
LETTA_JS = "/usr/local/lib/node_modules/@letta-ai/letta-code/letta.js"

# Key under settings.json's sessionsByServer that holds {agentId, conversationId}
# for the local backend. The CLI persists the latest conversationId here on every
# headless run, making it our source of truth for "resume the same chat".
SETTINGS_KEY = "local:/home/node/.letta/lc-local-backend"


def get_conversation_id_from_settings(settings_text):
    """Parse a settings.json string and return the current conversationId (or None).

    Best-effort: returns None on any parse/structure failure. A brand-new agent
    has no entry yet, and the CLI will simply create a fresh conversation.
    """
    if not settings_text:
        return None
    try:
        settings = json.loads(settings_text)
    except (json.JSONDecodeError, TypeError):
        return None
    try:
        return settings["sessionsByServer"][SETTINGS_KEY]["conversationId"]
    except (KeyError, TypeError):
        return None


def resume_fragment(conversation_id, as_new_chat):
    """Return the CLI arg fragment to resume (--conversation <id>) or start fresh (--new).

    Returns a trailing-space-terminated fragment ("--new " / "--conversation <id> ")
    or "" when no conversation is known yet (best-effort resume).
    """
    if as_new_chat:
        return "--new "
    if conversation_id:
        return f"--conversation {conversation_id} "
    return ""


def build_letta_command(prompt, resume="", output_format=None):
    """Build the shell command string that invokes letta.js headlessly.

    Args:
        prompt: the message text (JSON-escaped into the command).
        resume: an already-built resume fragment from ``resume_fragment``.
        output_format: None (default text), ``"json"``, or ``"stream-json"``.

    Returns a single shell command string (run via ``sh -c``)::

        HOME=/home/node node <LETTA_JS> --backend local [--output-format X] <resume>-p "<prompt>"
    """
    fmt = f"--output-format {output_format} " if output_format else ""
    return (
        f"HOME=/home/node node {LETTA_JS} --backend local "
        f"{fmt}{resume}-p {json.dumps(prompt)}"
    )


def iter_assistant_deltas(line_stream):
    """Yield assistant text deltas from a stream-json line stream.

    Each line is a JSON object. Assistant text arrives as events shaped like::

        {"type":"message", ..., "message_type":"assistant_message",
         "content":[{"type":"text","text":"<delta>"}], "seq_id":N, ...}

    The system/init, usage_statistics, stop_reason and final result events are
    ignored (the result text is already delivered via these deltas).
    """
    for line in line_stream:
        line = line.strip()
        if not line:
            continue
        try:
            evt = json.loads(line)
        except json.JSONDecodeError:
            continue
        if evt.get("type") == "message" and evt.get("message_type") == "assistant_message":
            content = evt.get("content")
            if isinstance(content, list) and content and content[0].get("type") == "text":
                yield content[0].get("text", "")


def parse_json_output(out):
    """Parse ``--output-format json`` stdout.

    Returns the decoded object, or None if ``out`` is not valid JSON.
    """
    try:
        return json.loads(out)
    except (json.JSONDecodeError, TypeError):
        return None
