#!/usr/bin/env bash
# =============================================================================
#  enable-ingress-metrics.sh
#
#  Enables Prometheus scraping of ingress-nginx metrics.
#  Without this, all ingress panels in the dashboard show no data.
#
#  Run on master node BEFORE importing the dashboard.
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
BOLD='\033[1m'; NC='\033[0m'
log_info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# kubeconfig
if [[ -z "${KUBECONFIG:-}" ]]; then
  [[ -f "$HOME/.kube/config" ]] && export KUBECONFIG="$HOME/.kube/config" \
    || export KUBECONFIG="/etc/kubernetes/admin.conf"
fi

# ── Step 1: Patch ingress-nginx to expose metrics port ────────────────────────
# ingress-nginx exposes metrics on port 10254 by default but the service
# does not expose it — we need to patch the controller service to add it.
log_info "Patching ingress-nginx controller to expose metrics port 10254..."

kubectl patch deployment ingress-nginx-controller \
  -n ingress-nginx \
  --type='json' \
  -p='[
    {
      "op": "add",
      "path": "/spec/template/spec/containers/0/args/-",
      "value": "--enable-metrics=true"
    }
  ]' 2>/dev/null || log_warn "Flag may already be set — continuing."

# ── Step 2: Create metrics Service for ingress-nginx ─────────────────────────
log_info "Creating ingress-nginx metrics Service..."
kubectl apply -f - << 'YAML'
apiVersion: v1
kind: Service
metadata:
  name: ingress-nginx-controller-metrics
  namespace: ingress-nginx
  labels:
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/component: controller
spec:
  selector:
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/component: controller
  ports:
    - name: metrics
      port: 10254
      targetPort: 10254
      protocol: TCP
  type: ClusterIP
YAML
log_info "Metrics service created ✔"

# ── Step 3: Create ServiceMonitor so Prometheus scrapes it ────────────────────
log_info "Creating ServiceMonitor for ingress-nginx..."
kubectl apply -f - << 'YAML'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: ingress-nginx-metrics
  namespace: monitoring
  labels:
    release: kube-prom-stack    # Must match Prometheus operator label selector
spec:
  namespaceSelector:
    matchNames:
      - ingress-nginx
  selector:
    matchLabels:
      app.kubernetes.io/name: ingress-nginx
      app.kubernetes.io/component: controller
  endpoints:
    - port: metrics
      interval: 30s
      path: /metrics
YAML
log_info "ServiceMonitor created ✔"

# ── Step 4: Verify ────────────────────────────────────────────────────────────
log_info "Waiting 15s for Prometheus to pick up the new target..."
sleep 15

log_info "Checking ingress-nginx metrics service:"
kubectl get svc -n ingress-nginx ingress-nginx-controller-metrics

log_info "Checking ServiceMonitor:"
kubectl get servicemonitor -n monitoring ingress-nginx-metrics

echo ""
log_info "Verify in Prometheus UI:"
log_info "  http://<master-public-ip>:32001/targets"
log_info "  Look for: ingress-nginx — should show State=UP within 1-2 min"
echo ""
log_info "Done. Now import the dashboard JSON into Grafana."
