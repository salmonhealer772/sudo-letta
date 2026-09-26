#!/usr/bin/env bash
set -uo pipefail

# kube-scripts/fix-agent-records.sh — one-shot ghost-record cleanup for a deployed agent
# Usage: bash kube-scripts/fix-agent-records.sh --name
#
# Agents' /home/node/.letta/settings.json accumulates GHOST agent records
# (memfs:false, unpinned duplicates left by historical CLI runs). When a session
# binds to a ghost, the official @letta-ai/web-search mod's tools never attach
# (agent reports no web_search). This script runs the SAME normalization as
# up.sh's hygiene step, on demand, for pods that are not being redeployed.
#
# Safe by design: leaves settings.json untouched if parsing fails; backs up to
# settings.json.bak-ghosts before writing; preserves sessionsByServer verbatim.

NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name|--*)  NAME="${1#--}"; shift ;;
    *)           echo "Usage: bash kube-scripts/fix-agent-records.sh --name" >&2; exit 1 ;;
  esac
done

if [[ -z "$NAME" ]]; then
  echo "Usage: bash kube-scripts/fix-agent-records.sh --name" >&2
  echo "Example: bash kube-scripts/fix-agent-records.sh --ya-glm-l" >&2
  exit 1
fi

if [[ "${NAME,,}" == "all" ]]; then
  echo "'--ALL' is reserved. Run per agent." >&2; exit 1
fi

# ── Resolve the name grep-style (same rules as letta-p.py) ──
BARES="$(kubectl get deploy -l app=sudo-letta -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | sed 's/^sudo-//')"

if [[ -z "$BARES" ]]; then
  echo "✗ No sudo-letta deployments found (is kubectl configured?)" >&2
  exit 1
fi

NAME_L="${NAME,,}"
MATCH=""

# exact match (case-insensitive)
while IFS= read -r bare; do
  [[ "${bare,,}" == "$NAME_L" ]] && MATCH="$bare" && break
done <<< "$BARES"

# substring (grep-style) match if no exact hit
if [[ -z "$MATCH" ]]; then
  HITS="$(grep -i -- "$NAME_L" <<< "$BARES" || true)"
  COUNT="$(grep -c . <<< "$HITS" || true)"
  if [[ "$COUNT" -eq 1 ]]; then
    MATCH="$HITS"
  elif [[ "$COUNT" -gt 1 ]]; then
    echo "✗ Multiple agents match '$NAME': $(echo "$HITS" | tr '\n' ' ')" >&2
    exit 1
  else
    echo "✗ No sudo-letta agent matches '$NAME' (try: $BARES | tr '\n' ' ')" >&2
    exit 1
  fi
fi

NAME="$MATCH"
DEPLOY="sudo-$NAME"
echo "→ Cleaning ghost agent records in $DEPLOY ..."

POD="$(kubectl get pods -l agent="$NAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
if [[ -z "$POD" ]]; then
  echo "✗ No running pod for $DEPLOY" >&2
  exit 1
fi

# ── Same normalization as up.sh hygiene (runs as node inside the pod) ──
kubectl exec "$POD" -- bash -c 'python3 - << "PYEOF"
import json, shutil, os, sys

path = "/home/node/.letta/settings.json"

try:
    with open(path) as f:
        data = json.load(f)
except Exception as exc:
    print("ghost-hygiene: parse failed, settings.json left untouched (%s)" % exc)
    sys.exit(0)

agents = data.get("agents") or []
if not agents:
    print("ghost-hygiene: no agents[] records — nothing to do (before=0 after=0)")
    sys.exit(0)

def is_pinned(rec):
    return isinstance(rec, dict) and (rec.get("memfs") is True or rec.get("pinned") is True)

keep = [a for a in agents if is_pinned(a)]
removed = len(agents) - len(keep)

if removed and not keep:
    print("ghost-hygiene: WARNING no pinned (memfs) record found — leaving settings.json untouched")
    sys.exit(0)

if removed:
    shutil.copy2(path, path + ".bak-ghosts")
    data["agents"] = keep
    # lastAgent: fall back to the pinned agent if it points at a removed ghost
    last = data.get("lastAgent")
    last_id = last if isinstance(last, str) else (last.get("id") if isinstance(last, dict) else None)
    keep_ids = {a.get("id") for a in keep}
    if last_id is not None and last_id not in keep_ids and keep[0].get("id") is not None:
        data["lastAgent"] = keep[0]["id"]
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, path)
    print("ghost-hygiene: removed %d ghost record(s), kept %d pinned (backup: settings.json.bak-ghosts)" % (removed, len(keep)))
else:
    print("ghost-hygiene: nothing to remove (before=%d after=%d, all pinned)" % (len(agents), len(keep)))
PYEOF' || { echo "✗ Ghost-record cleanup FAILED for $DEPLOY" >&2; exit 1; }

echo "✓ $DEPLOY agent records clean"
