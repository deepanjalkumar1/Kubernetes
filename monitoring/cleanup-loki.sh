#!/usr/bin/env bash
# =============================================================================
#  cleanup-loki.sh
#  Removes ALL Loki and Promtail resources completely.
#  Run this on the MASTER node.
#  After this script completes successfully, run deploy-loki.sh fresh.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_section() {
  echo -e "\n${BLUE}${BOLD}══════════════════════════════════════════════════════${NC}"
  echo -e "${BLUE}${BOLD}  $*${NC}"
  echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════════${NC}"
}

# ─── kubeconfig ───────────────────────────────────────────────────────────────
if [[ -z "${KUBECONFIG:-}" ]]; then
  if [[ -f "$HOME/.kube/config" ]]; then
    export KUBECONFIG="$HOME/.kube/config"
  elif [[ -f "/etc/kubernetes/admin.conf" ]]; then
    export KUBECONFIG="/etc/kubernetes/admin.conf"
  fi
fi
kubectl cluster-info &>/dev/null || {
  echo "Cannot reach cluster. Fix kubeconfig first:"
  echo "  mkdir -p \$HOME/.kube"
  echo "  sudo cp /etc/kubernetes/admin.conf \$HOME/.kube/config"
  echo "  sudo chown \$(id -u):\$(id -g) \$HOME/.kube/config"
  exit 1
}

log_section "Removing Helm releases"
helm uninstall loki     -n monitoring 2>/dev/null && log_info "loki removed"     || log_warn "loki not found"
helm uninstall promtail -n monitoring 2>/dev/null && log_info "promtail removed" || log_warn "promtail not found"

log_section "Removing PVCs"
kubectl delete pvc -n monitoring \
  -l "app.kubernetes.io/name=loki" \
  --ignore-not-found=true && log_info "Loki PVCs deleted"

# Also delete any PVCs not caught by label (distributed mode creates differently named PVCs)
for pvc in $(kubectl get pvc -n monitoring --no-headers 2>/dev/null | grep loki | awk '{print $1}'); do
  kubectl delete pvc "$pvc" -n monitoring --ignore-not-found=true
  log_info "Deleted PVC: $pvc"
done

log_section "Removing ConfigMaps"
kubectl delete configmap loki-datasource -n monitoring --ignore-not-found=true
log_info "loki-datasource ConfigMap deleted"

log_section "Force-deleting any stuck pods"
for pod in $(kubectl get pods -n monitoring --no-headers 2>/dev/null | grep -E "loki|promtail" | awk '{print $1}'); do
  kubectl delete pod "$pod" -n monitoring --force --grace-period=0 --ignore-not-found=true
  log_info "Force deleted pod: $pod"
done

log_section "Removing temp value files"
rm -f /tmp/loki-values.yaml /tmp/promtail-values.yaml
log_info "Temp files cleaned"

log_section "Final state — confirm clean"
echo ""
echo "=== Pods (should show NO loki or promtail) ==="
kubectl get pods -n monitoring
echo ""
echo "=== PVCs (should show NO loki PVCs) ==="
kubectl get pvc -n monitoring
echo ""
echo "=== Services (should show NO loki services) ==="
kubectl get svc -n monitoring | grep -E "loki|promtail" || echo "  None — clean ✔"
echo ""
echo "=== Helm releases (should show only kube-prom-stack) ==="
helm list -n monitoring
echo ""
log_info "Cleanup complete. Now run: ./deploy-loki.sh"
