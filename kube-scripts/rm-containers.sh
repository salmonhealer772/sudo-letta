#!/usr/bin/env bash
set -euo pipefail

# kube-scripts/rm-containers.sh — Remove sudo-letta deployments + PVCs
# Usage:
#   bash kube-scripts/rm-containers.sh --name     Remove one
#   bash kube-scripts/rm-containers.sh --ALL       Nuke ALL sudo-*

# Auto-detect kubeconfig, probing known k3s/world15/user paths because this
# script is often run under sudo (swaps HOME) and an unset KUBECONFIG would
# target the wrong cluster; if none found, the kubectl deletes below fail loudly.
if [[ -z "${KUBECONFIG:-}" ]]; then
  for cfg in "/etc/rancher/k3s/k3s.yaml" "/home/world15/.kube/config" "$HOME/.kube/config"; do
    if [[ -f "$cfg" ]]; then export KUBECONFIG="$cfg"; break; fi
  done
fi

NAME=""
REMOVE_ALL=false

# Parses --name [<name>] (or --name=<name>) for single removal and --ALL/--all
# for bulk removal, because the two modes differ destructively (single removes
# one agent's deploy+PVC+YAML, --ALL wipes the whole fleet); an unknown flag
# prints usage + exit 1.
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
    *)            echo "Usage: bash kube-scripts/rm-containers.sh --name | --ALL" >&2; exit 1 ;;
  esac
  shift
done

# Bulk mode: deletes every sudo-letta Deployment and PVC by label and cleans
# the generated deployments/*.yaml, because --ALL is a full-fleet teardown and
# the PVCs (agent memory) must go too; failures are tolerated (|| true) so a
# partially-absent resource does not abort the teardown.
if $REMOVE_ALL; then
  echo "→ Nuking ALL sudo-* from Kubernetes..."
  kubectl delete deploy -l app=sudo-letta 2>/dev/null || true
  kubectl delete pvc -l app=sudo-letta 2>/dev/null || true
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
  rm -f "$REPO_DIR/deployments"/*.yaml 2>/dev/null || true
  echo "✓ Gone."
elif [[ -n "$NAME" ]]; then
  # Single mode: deletes one Deployment AND its PVC (memory is destroyed, unlike
  # down.sh which preserves it), then removes the generated YAML, because
  # rm-containers is the destructive path; a missing PVC/YAML is tolerated
  # (|| true), and a missing Deployment reports "not found" without erroring.
  DEPLOY="sudo-$NAME"
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
  if kubectl get deploy "$DEPLOY" &>/dev/null; then
    kubectl delete deploy "$DEPLOY"
    kubectl delete pvc "$DEPLOY-data" 2>/dev/null || true
    rm -f "$REPO_DIR/deployments/$NAME.yaml" 2>/dev/null || true
    echo "✓ $DEPLOY removed (deployment + volume)."
  else
    echo "→ $DEPLOY not found."
  fi
else
  echo "Usage: bash kube-scripts/rm-containers.sh --name | --ALL" >&2
  exit 1
fi
