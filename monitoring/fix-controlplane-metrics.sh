#!/usr/bin/env bash
# =============================================================================
#  fix-controlplane-metrics.sh
#
#  On kubeadm clusters, etcd, kube-scheduler, and kube-controller-manager
#  bind to 127.0.0.1 by default — Prometheus CANNOT scrape them.
#  This script patches them to listen on 0.0.0.0 (all interfaces).
#
#  RUN THIS ON THE MASTER NODE as root or with sudo.
#  Then re-run on your local machine: kubectl get pods -n monitoring
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Must run on master
if ! kubectl get nodes &>/dev/null 2>&1 || [[ $(hostname) != *"master"* && $(hostname) != *"control"* ]]; then
  log_warn "This script should be run ON the master node, not from your local machine."
  log_warn "Copy it to the master: scp fix-controlplane-metrics.sh ubuntu@<master-ip>:~/"
  log_warn "Then SSH in and run: sudo bash fix-controlplane-metrics.sh"
  # Don't exit — user might have a different hostname
fi

MANIFEST_DIR="/etc/kubernetes/manifests"

if [[ ! -d "$MANIFEST_DIR" ]]; then
  log_error "Cannot find $MANIFEST_DIR — are you sure this is the master node?"
  exit 1
fi

log_info "Patching kube-scheduler to bind on 0.0.0.0..."
if grep -q "bind-address=127.0.0.1" "${MANIFEST_DIR}/kube-scheduler.yaml" 2>/dev/null; then
  sudo sed -i 's/--bind-address=127.0.0.1/--bind-address=0.0.0.0/' "${MANIFEST_DIR}/kube-scheduler.yaml"
  log_info "kube-scheduler patched."
else
  log_warn "kube-scheduler already uses 0.0.0.0 or file not found."
fi

log_info "Patching kube-controller-manager to bind on 0.0.0.0..."
if grep -q "bind-address=127.0.0.1" "${MANIFEST_DIR}/kube-controller-manager.yaml" 2>/dev/null; then
  sudo sed -i 's/--bind-address=127.0.0.1/--bind-address=0.0.0.0/' "${MANIFEST_DIR}/kube-controller-manager.yaml"
  log_info "kube-controller-manager patched."
else
  log_warn "kube-controller-manager already uses 0.0.0.0 or file not found."
fi

log_info "Patching etcd to listen on 0.0.0.0..."
# etcd uses --listen-metrics-urls
if grep -q "listen-metrics-urls=http://127.0.0.1" "${MANIFEST_DIR}/etcd.yaml" 2>/dev/null; then
  sudo sed -i 's|--listen-metrics-urls=http://127.0.0.1|--listen-metrics-urls=http://0.0.0.0|' "${MANIFEST_DIR}/etcd.yaml"
  log_info "etcd patched."
else
  log_warn "etcd already configured or file not found."
fi

log_info "Changes applied. Kubelet will automatically restart these static pods within ~30 seconds."
log_info "Wait 1 minute, then check from your local machine:"
echo ""
echo "  kubectl get pods -n kube-system | grep -E 'etcd|scheduler|controller'"
echo "  # Then check Prometheus targets at http://<worker-ip>:32001/targets"
echo ""
log_warn "NOTE: These files are regenerated on kubeadm upgrades. Re-run this script after upgrading."
