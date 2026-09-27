#!/usr/bin/env bash
set -euo pipefail

# kube-scripts/talk.sh — Talk to a sudo-letta running in Kubernetes
# Usage: bash kube-scripts/talk.sh --name

NAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name|--*)  NAME="${1#--}"; shift ;;
    *)           echo "Usage: bash kube-scripts/talk.sh --name" >&2; exit 1 ;;
  esac
done
if [[ -z "$NAME" ]]; then
  echo "Usage: bash kube-scripts/talk.sh --name" >&2; exit 1
fi
if [[ "${NAME,,}" == "all" ]]; then
  echo "Use rm-containers.sh --ALL instead." >&2; exit 1
fi

# Auto-detect kubeconfig
if [[ -z "${KUBECONFIG:-}" ]]; then
  for cfg in "/etc/rancher/k3s/k3s.yaml" "/home/world15/.kube/config" "$HOME/.kube/config"; do
    if [[ -f "$cfg" ]]; then export KUBECONFIG="$cfg"; break; fi
  done
fi

# NOTE: --new starts a FRESH conversation on every launch (agent identity and
# memory are unaffected - identity lives in MemFS, not in the conversation).
# Why not bare `letta` (auto-resume)? letta-code <=0.33.2 has a mod-loading
# bug (letta-ai/letta-code #3499 / PR #4697, unmerged as of 2026-09-27): the
# resume-path startup loads the global mods dir through TWO mod engines in
# one process; the second registration trips the "already registered by
# <same file>" shadowing check, aborting mods mid-activation. Result: a random
# ~2 of 4 official mods fail to attach (often web_search) and the agent
# truthfully reports the tool missing. `--new` takes the create-path, which
# only spins up one mod engine -> all 4 mods load cleanly (verified: 10+
# launches across ya-glm-l and clean-search-test, incl. 4 concurrent).
# To continue an older chat, use /resume INSIDE the session (verified safe:
# the clean 4/4 registry is kept). Revisit this flag when a letta-code
# release containing PR #4697 ships.
kubectl exec -it "deploy/sudo-$NAME" -- bash -c 'letta --new'
