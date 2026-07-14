#!/usr/bin/env bash
set -euo pipefail

# scripts/talk.sh — Jump into a running Sudo Letta container
# Usage: bash scripts/talk.sh --name
# Opens the Letta Code TUI — agent with full memory, tools, and sudo.

NAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name|--*)  NAME="${1#--}"; shift ;;
    *) echo "Usage: bash scripts/talk.sh --name" >&2; exit 1 ;;
  esac
done
if [[ -z "$NAME" ]]; then
  echo "Usage: bash scripts/talk.sh --name" >&2
  echo "Example: bash scripts/talk.sh --alice" >&2
  exit 1
fi

if [[ "${NAME,,}" == "all" ]]; then
  echo "Use rm-containers.sh --ALL instead." >&2
  exit 1
fi

# Check container is running
if ! docker container inspect "sudo-$NAME" &>/dev/null; then
  echo "Container sudo-$NAME not found. Start it first:" >&2
  echo "  bash scripts/up.sh --$NAME" >&2
  exit 1
fi

STATUS=$(docker inspect "sudo-$NAME" --format '{{.State.Status}}')
if [[ "$STATUS" != "running" ]]; then
  echo "Container sudo-$NAME is $STATUS. Start it:" >&2
  echo "  bash scripts/up.sh --$NAME" >&2
  exit 1
fi

# Exec into the container running Letta Code
# --resume picks up the last conversation or shows agent selector
docker exec -it -u node "sudo-$NAME" letta --resume
