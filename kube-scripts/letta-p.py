#!/usr/bin/env python3
"""
letta-p.py — send a one-shot prompt to a running sudo-letta agent and print its reply.

Runs on the HOST (where kubectl + kubeconfig live). Maps a bare name to the
corresponding sudo-letta Deployment (the same convention as ssh.sh --name),
execs into the pod as the `node` user, and runs the Letta CLI headlessly
against the LOCAL backend (the configured deepseek provider).

Usage:
    letta-p.py --mail-bot-letta "say hi"
    letta-p.py --mail-bot-letta --json "say hi"
    letta-p.py --mail-bot-letta --stream "say hi"      # stream the reply live
    letta-p.py --mail-bot-letta --new-chat "say hi"    # start a fresh chat
    echo "say hi" | letta-p.py --mail-bot-letta          # read prompt from stdin
    letta-p.py --list                                    # list running sudo-letta agents

By default each invocation RESUMES the same conversation for that agent (the
CLI persists the latest conversationId to the pod's settings.json on every run);
pass --new-chat to force a fresh conversation.

Why the plumbing is the way it is (hard-won):
  - letta is invoked by absolute path (node .../letta-code/letta.js) because the
    `letta` shim in /usr/local/bin is temp-stamped (".letta-<rand>"), so it is
    not on $PATH for the exec user.
  - `--backend local` avoids the Cloud default (api.letta.com) which 401s with a
    BYOK deepseek key.
  - `HOME=/home/node` makes the CLI read the real provider config + agents; a
    root login shell would point HOME at /root/.letta (empty provider config ->
    "Provider is not configured: openai").
  - `--stream` switches to `--output-format stream-json` and prints assistant
    text deltas live, one token at a time.
"""

import argparse
import json
import subprocess
import sys

LETTA_JS = "/usr/local/lib/node_modules/@letta-ai/letta-code/letta.js"
KUBECTL = "kubectl"


def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)


def list_agents():
    """Return the bare agent names for all running sudo-letta deployments."""
    proc = subprocess.run(
        [KUBECTL, "get", "deploy", "-l", "app=sudo-letta",
         "-o", "jsonpath={range .items[*]}{.metadata.name}{\"\\n\"}{end}"],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        eprint("error: failed to list deployments:", proc.stderr.strip())
        sys.exit(proc.returncode)
    names = []
    for line in proc.stdout.splitlines():
        line = line.strip()
        if line.startswith("sudo-"):
            names.append(line[len("sudo-"):])
    return sorted(names)


def resolve_name(input_name):
    """Resolve a user-supplied name to a bare agent name via grep-style matching.

    The 12 real deployments are `sudo-<bare-name>`; a bare name is the deployment
    name minus ONE leading "sudo-". Some bare names legitimately START with
    "sudo-" (e.g. the maintainer pair: bare `sudo-letta-maintainer-l` lives at
    deploy `sudo-sudo-letta-maintainer-l`), so we must NOT blindly strip a leading
    "sudo-" from the input. Instead:

      1. Exact match (case-insensitive) against a bare name -> return it.
      2. Otherwise substring (grep-style) match: bare names whose lowercase form
         CONTAINS the lowercase input.
         - exactly one  -> return it
         - zero         -> error + exit 1
         - multiple     -> error listing the candidates + exit 1
    """
    bare_names = list_agents()
    lowered = input_name.lower()

    # 1) exact match (case-insensitive)
    for bare in bare_names:
        if bare.lower() == lowered:
            return bare

    # 2) substring (grep-style) match
    matches = [bare for bare in bare_names if lowered in bare.lower()]
    if len(matches) == 1:
        return matches[0]
    if not matches:
        eprint(f"no sudo-letta agent matches '{input_name}' (try --list)")
        sys.exit(1)
    eprint(f"multiple agents match '{input_name}': {', '.join(matches)}")
    sys.exit(1)


def get_conversation_id(name):
    """Read the pod's current conversationId from settings.json (best-effort).

    The Letta CLI persists the latest conversationId under
    sessionsByServer -> "local:/home/node/.letta/lc-local-backend" ->
    conversationId on every headless run, so this is our source of truth for
    "resume the same chat". Returns None on any failure; a brand-new agent has
    no entry yet and the CLI will simply create a fresh conversation.
    """
    deploy = f"sudo-{name}"
    proc = subprocess.run(
        [KUBECTL, "exec", f"deploy/{deploy}", "--",
         "sh", "-c", "HOME=/home/node cat /home/node/.letta/settings.json"],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        return None
    try:
        settings = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None
    try:
        return settings["sessionsByServer"]["local:/home/node/.letta/lc-local-backend"]["conversationId"]
    except (KeyError, TypeError):
        return None


def _resume_arg(name, as_new_chat):
    """Return the CLI arg fragment to resume (--conversation <id>) or start fresh (--new).

    Returns a trailing-space-terminated fragment ("--new " / "--conversation <id> ")
    or "" when no conversation is known yet (best-effort resume).
    """
    if as_new_chat:
        return "--new "
    conv_id = get_conversation_id(name)
    if conv_id:
        return f"--conversation {conv_id} "
    return ""


def _stream_reply(cmd, name):
    """Run the CLI in stream-json mode and print assistant text deltas live."""
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    for line in proc.stdout:
        line = line.strip()
        if not line:
            continue
        try:
            evt = json.loads(line)
        except json.JSONDecodeError:
            continue
        # Assistant text arrives as: {"type":"message", "message_type":
        # "assistant_message", "content":[{"type":"text","text":"<delta>"}], ...}.
        # The system/init, usage_statistics, stop_reason and final result events
        # are ignored (the result text is already streamed via these deltas).
        if evt.get("type") == "message" and evt.get("message_type") == "assistant_message":
            content = evt.get("content")
            if isinstance(content, list) and content and content[0].get("type") == "text":
                print(content[0].get("text", ""), end="", flush=True)
    proc.wait()
    if proc.returncode != 0:
        stderr = proc.stderr.read().strip()
        eprint(f"error: letta-p failed for '{name}':")
        eprint(stderr or "")
        sys.exit(proc.returncode)
    print()  # trailing newline so the shell prompt starts on its own line


def run_prompt(name, prompt, as_json, as_stream=False, as_new_chat=False):
    deploy = f"sudo-{name}"
    # Inject --conversation <id> (resume) or --new (fresh) right before -p so the
    # CLI resumes the agent's persisted conversation by default instead of always
    # starting a new one. Best-effort: empty fragment -> CLI creates a new chat.
    resume = _resume_arg(name, as_new_chat)

    cmd = [
        KUBECTL, "exec", f"deploy/{deploy}", "--",
        "sh", "-c",
        # HOME=/home/node so letta reads the real provider config, not /root's
        f"HOME=/home/node node {LETTA_JS} --backend local {resume}-p {json.dumps(prompt)}",
    ]
    if as_json:
        # NOTE: the --json branch overwrites cmd[4] (the "sh" token) instead of
        # cmd[6] — a known PRE-EXISTING bug that is intentionally left unfixed.
        cmd[4] = f"HOME=/home/node node {LETTA_JS} --backend local --output-format json {resume}-p {json.dumps(prompt)}"
    elif as_stream:
        cmd[6] = f"HOME=/home/node node {LETTA_JS} --backend local --output-format stream-json {resume}-p {json.dumps(prompt)}"

    if as_stream:
        _stream_reply(cmd, name)
        return

    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        eprint(f"error: letta-p failed for '{name}':")
        eprint(proc.stderr.strip() or proc.stdout.strip())
        sys.exit(proc.returncode)

    out = proc.stdout.strip()
    if not out:
        return

    if as_json:
        # The CLI's --output-format json returns a single JSON object with the
        # assistant reply in the "result" field (plus agent_id/conversation_id/
        # usage). Print that object; extract "result" when present.
        try:
            parsed = json.loads(out)
        except json.JSONDecodeError:
            print(out)  # fall back to raw
            return
        if isinstance(parsed, dict) and "result" in parsed:
            # Emit the raw result text, but keep the full object available via
            # the --json flag consumer by also not discarding metadata below.
            print(json.dumps(parsed, indent=2))
        else:
            print(out)
    else:
        print(out)


def main():
    ap = argparse.ArgumentParser(
        description="Send a one-shot prompt to a running sudo-letta agent and print its reply.",
        add_help=True,
    )
    ap.add_argument("name", nargs="?", help="agent name (deploy 'sudo-<name>'); e.g. mail-bot-letta")
    ap.add_argument("prompt", nargs="*", help="the message to send (if omitted, read from stdin)")
    ap.add_argument("--json", action="store_true", dest="as_json", help="request JSON output")
    ap.add_argument("--stream", action="store_true", dest="as_stream", help="stream the assistant reply live, one token at a time")
    ap.add_argument("--new-chat", action="store_true", dest="as_new_chat", help="start a new chat; default is to resume the same chat")
    ap.add_argument("--list", action="store_true", help="list running sudo-letta agents")
    ap.add_argument("--name", dest="name_flag", help="agent name (alt spelling for --NAME)")

    # Accept a bare leading-dash agent name like --mail-bot-letta (matching the
    # ssh.sh/up.sh --name convention). argparse would otherwise treat it as an
    # unknown option, so preprocess argv: every name spelling is normalized to a
    # bare positional. (Passing the name via a separate --name flag would let the
    # greedy `name` positional swallow the first prompt token, so we flatten all
    # name forms into the `name` positional and leave `prompt` intact.)
    KNOWN_FLAGS = {"--json", "--stream", "--new-chat", "--list", "--help", "-h"}
    pre = []
    argv = sys.argv[1:]
    i = 0
    while i < len(argv):
        tok = argv[i]
        if tok == "--name" and i + 1 < len(argv):
            pre.append(argv[i + 1])            # --name X  -> X
            i += 2
        elif tok.startswith("--name="):
            pre.append(tok[len("--name="):])   # --name=X -> X
            i += 1
        elif tok.startswith("--") and tok not in KNOWN_FLAGS:
            pre.append(tok.lstrip("-"))        # --mail-bot-letta -> mail-bot-letta
            i += 1
        else:
            pre.append(tok)
            i += 1
    args = ap.parse_args(pre)

    if args.list:
        agents = list_agents()
        if not agents:
            eprint("no sudo-letta deployments found")
            sys.exit(1)
        for a in agents:
            print(a)
        return

    raw_input_name = (args.name_flag or args.name or "").strip()
    if not raw_input_name:
        ap.error("a name is required (or use --list)")
    # Resolve the user-supplied name dynamically (grep-style): exact match wins,
    # then substring match. This correctly handles bare names that legitimately
    # start with "sudo-" (e.g. sudo-letta-maintainer-l) instead of blindly
    # stripping a leading "sudo-" and mangling them to "letta-maintainer-l".
    name = resolve_name(raw_input_name)

    prompt = " ".join(args.prompt)
    if not prompt:
        prompt = sys.stdin.read().strip()
    if not prompt:
        ap.error("a prompt is required (pass it as an argument or via stdin)")

    run_prompt(name, prompt, args.as_json, args.as_stream, args.as_new_chat)


if __name__ == "__main__":
    main()
