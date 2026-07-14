#!/usr/bin/env bash
set -euo pipefail

# scripts/rm-containers.sh — Remove sudo-letta containers
#
# Usage:
#   bash scripts/rm-containers.sh --name    Remove container "name"
#   bash scripts/rm-containers.sh --ALL     Remove ALL sudo-* containers
#
# Volumes are NOT removed by default, so agent memory survives.
# To also remove the volume: docker volume rm sudo-name-data

NAME=""
REMOVE_ALL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name|--name=*)
      if [[ "$1" == --name=* ]]; then
        NAME="${1#--name=}"
      else
        shift; NAME="${1:-}"
      fi
      ;;
    --ALL|--all)  REMOVE_ALL=true ;;
    *) echo "Usage: bash scripts/rm-containers.sh --name | --ALL" >&2; exit 1 ;;
  esac
  shift
done

if $REMOVE_ALL; then
  echo "→ Removing ALL sudo-* containers..."
  IDS=$(docker ps -a --filter name='^/sudo-' -q)
  if [[ -n "$IDS" ]]; then
    docker rm -f $IDS
    echo "✓ Containers removed. Volumes preserved."
    echo "  To also remove volumes: docker volume rm \$(docker volume ls --filter name='sudo-' -q)"
  else
    echo "→ No sudo-* containers found."
  fi
elif [[ -n "$NAME" ]]; then
  CONTAINER="sudo-$NAME"
  if docker container inspect "$CONTAINER" &>/dev/null; then
    docker rm -f "$CONTAINER" >/dev/null
    echo "✓ $CONTAINER removed. Volume sudo-${NAME}-data preserved."
    echo "  To also remove the volume: docker volume rm sudo-${NAME}-data"
  else
    echo "→ Container $CONTAINER not found."
  fi
else
  echo "Usage: bash scripts/rm-containers.sh --name | --ALL" >&2
  exit 1
fi
