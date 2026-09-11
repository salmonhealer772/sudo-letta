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
    echo "say hi" | letta-p.py --mail-bot-letta          # read prompt from stdin
    letta-p.py --list                                    # list running sudo-letta agents

Why the plumbing is the way it is (hard-won):
  - letta is invoked by absolute path (node .../letta-code/letta.js) because the
    `letta` shim in /usr/local/bin is temp-stamped (".letta-<rand>"), so it is
    not on $PATH for the exec user.
  - `--backend local` avoids the Cloud default (api.letta.com) which 401s with a
    BYOK deepseek key.
  - `HOME=/home/node` makes the CLI read the real provider config + agents; a
    root login shell would point HOME at /root/.letta (empty provider config ->
    "Provider is not configured: openai").
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


def run_prompt(name, prompt, as_json):
    deploy = f"sudo-{name}"
    cmd = [
        KUBECTL, "exec", f"deploy/{deploy}", "--",
        "sh", "-c",
        # HOME=/home/node so letta reads the real provider config, not /root's
        f"HOME=/home/node node {LETTA_JS} --backend local -p {json.dumps(prompt)}",
    ]
    if as_json:
        cmd[4] = f"HOME=/home/node node {LETTA_JS} --backend local --output-format json -p {json.dumps(prompt)}"

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
    ap.add_argument("--list", action="store_true", help="list running sudo-letta agents")
    ap.add_argument("--name", dest="name_flag", help="agent name (alt spelling for --NAME)")

    # Accept a bare leading-dash agent name like --mail-bot-letta (matching the
    # ssh.sh/up.sh --name convention). argparse would otherwise treat it as an
    # unknown option, so preprocess argv: every name spelling is normalized to a
    # bare positional. (Passing the name via a separate --name flag would let the
    # greedy `name` positional swallow the first prompt token, so we flatten all
    # name forms into the `name` positional and leave `prompt` intact.)
    KNOWN_FLAGS = {"--json", "--list", "--help", "-h"}
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

    name = (args.name_flag or args.name or "").strip()
    # Normalize away a single leading "sudo-" (users may type --sudo-mail-bot-letta);
    # run_prompt() prepends "sudo-" itself, so this avoids "sudo-sudo-<name>".
    if name.startswith("sudo-"):
        name = name[len("sudo-"):]
    if not name:
        ap.error("a name is required (or use --list)")

    prompt = " ".join(args.prompt)
    if not prompt:
        prompt = sys.stdin.read().strip()
    if not prompt:
        ap.error("a prompt is required (pass it as an argument or via stdin)")

    run_prompt(name, prompt, args.as_json)


if __name__ == "__main__":
    main()
