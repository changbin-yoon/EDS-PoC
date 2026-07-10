#!/usr/bin/env bash
#
# Rolling kubeadm PKI certificate renewal for a stacked-etcd, multi-control-plane
# cluster. Processes one control-plane node at a time: check -> backup -> renew ->
# restart static pods -> wait for Ready -> verify, before moving to the next node.
# This keeps etcd quorum intact (only 1/N members ever restarting at once).
#
# Usage:
#   ./renew-control-plane-certs.sh --check-only
#   ./renew-control-plane-certs.sh --apply
#   ./renew-control-plane-certs.sh --apply --yes          # skip confirmation prompt
#   ./renew-control-plane-certs.sh --apply --node <host>  # limit to one node
#
# Requires: KUBECONFIG pointing at the target cluster (for health checks between
# nodes) and SSH key access to every control-plane node as SSH_USER.

set -euo pipefail

# ---- Config: edit for your cluster -----------------------------------------
CP_NODES=(
  "cp-node-1.example.internal"
  "cp-node-2.example.internal"
  "cp-node-3.example.internal"
)
SSH_USER="${SSH_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$HOME/eds-poc/dev-cluster.kubeconfig}"
# System ssh_config on this host has invalid directives; bypass it.
SSH_OPTS=(-F /dev/null -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
READY_TIMEOUT_SECONDS=180
POLL_INTERVAL_SECONDS=5
# ------------------------------------------------------------------------------

MODE=""
AUTO_YES=false
ONLY_NODE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-only) MODE="check" ;;
    --apply) MODE="apply" ;;
    --yes) AUTO_YES=true ;;
    --node) ONLY_NODE="$2"; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
  shift
done

if [[ -z "$MODE" ]]; then
  echo "Usage: $0 (--check-only|--apply) [--yes] [--node <host>]" >&2
  exit 1
fi

log() { printf '[%(%Y-%m-%dT%H:%M:%S%z)T] %s\n' -1 "$1"; }

ssh_run() {
  local node="$1"; shift
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${node}" "$@"
}

check_expiration() {
  local node="$1"
  log "=== [$node] certificate expiration ==="
  ssh_run "$node" "sudo kubeadm certs check-expiration"
}

backup_certs() {
  local node="$1"
  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  log "[$node] backing up /etc/kubernetes/pki to /etc/kubernetes/pki-backup-${ts}.tar.gz"
  ssh_run "$node" "sudo tar czf /etc/kubernetes/pki-backup-${ts}.tar.gz -C /etc/kubernetes pki"
}

renew_certs() {
  local node="$1"
  log "[$node] renewing all kubeadm-managed certificates"
  ssh_run "$node" "sudo kubeadm certs renew all"
}

restart_static_pods() {
  local node="$1"
  log "[$node] restarting control-plane static pods (etcd, apiserver, controller-manager, scheduler)"
  ssh_run "$node" '
    set -e
    tmp="/tmp/manifests-backup-$(date +%s)"
    sudo mv /etc/kubernetes/manifests "$tmp"
    sleep 20
    sudo mv "$tmp" /etc/kubernetes/manifests
  '
}

wait_node_ready() {
  local node_name="$1"
  local elapsed=0
  log "[$node_name] waiting for kubelet + control-plane pods to report Ready"
  while (( elapsed < READY_TIMEOUT_SECONDS )); do
    local node_ready pod_status
    node_ready=$(kubectl --kubeconfig "$KUBECONFIG_PATH" get node "$node_name" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    pod_status=$(kubectl --kubeconfig "$KUBECONFIG_PATH" get pods -n kube-system \
      --field-selector spec.nodeName="$node_name" \
      -l 'tier=control-plane' \
      -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null || echo "")
    if [[ "$node_ready" == "True" ]] && ! grep -qv '^Running$' <<<"$pod_status"; then
      log "[$node_name] Ready, control-plane pods Running"
      return 0
    fi
    sleep "$POLL_INTERVAL_SECONDS"
    (( elapsed += POLL_INTERVAL_SECONDS ))
  done
  log "[$node_name] TIMEOUT waiting for Ready state after ${READY_TIMEOUT_SECONDS}s"
  return 1
}

confirm_or_abort() {
  local node="$1"
  $AUTO_YES && return 0
  read -r -p "Renew certs and restart control-plane pods on ${node}? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || { log "Skipped ${node}"; return 1; }
}

nodes=("${CP_NODES[@]}")
if [[ -n "$ONLY_NODE" ]]; then
  nodes=("$ONLY_NODE")
fi

for node in "${nodes[@]}"; do
  check_expiration "$node"

  if [[ "$MODE" == "check" ]]; then
    continue
  fi

  confirm_or_abort "$node" || continue

  backup_certs "$node"
  renew_certs "$node"
  restart_static_pods "$node"

  # node_name in the cluster may differ from the SSH host; override via
  # `kubectl get nodes -o wide` mapping if needed.
  wait_node_ready "$node" || {
    log "[$node] ABORTING remaining nodes — investigate before continuing."
    exit 1
  }

  check_expiration "$node"
  log "[$node] done. Moving to next node only after confirming this one is healthy."
done

log "All requested nodes processed."
