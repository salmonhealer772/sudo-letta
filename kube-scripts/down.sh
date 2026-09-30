#!/usr/bin/env bash
set -euo pipefail

# kube-scripts/down.sh — Stop a sudo-letta in Kubernetes (PVC = memory persists)
# Usage: bash kube-scripts/down.sh --name

NAME=""
# Parses --name (or any --flag) as the agent name and rejects bare args with
# usage, because the name maps to the `sudo-<name>` Deployment to stop; if no
# name is given, exit 1 with usage rather than deleting the wrong resource.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name|--*)  NAME="${1#--}"; shift ;;
    *)           echo "Usage: bash kube-scripts/down.sh --name" >&2; exit 1 ;;
  esac
done
if [[ -z "$NAME" ]]; then
  echo "Usage: bash kube-scripts/down.sh --name" >&2; exit 1
fi
# Rejects "all" because bulk removal (and PVC deletion) is rm-containers.sh's
# job, not this single-agent stop; if "all" is passed, exit 1 with a redirect.
if [[ "${NAME,,}" == "all" ]]; then
  echo "Use rm-containers.sh --ALL instead." >&2; exit 1
fi

# Auto-detect kubeconfig, probing the known k3s/world15/user paths in order,
# because this script is often run under sudo (which swaps HOME) and an unset
# KUBECONFIG would make kubectl target the wrong or no cluster; if no config is
# found, KUBECONFIG stays unset and the kubectl delete below fails loudly.
if [[ -z "${KUBECONFIG:-}" ]]; then
  for cfg in "/etc/rancher/k3s/k3s.yaml" "/home/world15/.kube/config" "$HOME/.kube/config"; do
    if [[ -f "$cfg" ]]; then export KUBECONFIG="$cfg"; break; fi
  done
fi

DEPLOY="sudo-$NAME"

# Deletes only the Deployment (leaving the PVC in place) so the agent's memory
# survives a stop and a later up.sh resumes it; if the Deployment does not
# exist, report that and exit 0 rather than erroring on an already-stopped
# agent. A failed delete propagates its non-zero exit (set -e).
if kubectl get deploy "$DEPLOY" &>/dev/null; then
  kubectl delete deploy "$DEPLOY"
  echo "✓ $DEPLOY stopped. Volume (PVC) preserved — memory persists."
else
  echo "→ Deployment $DEPLOY not found."
fi
