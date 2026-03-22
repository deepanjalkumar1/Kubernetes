#!/usr/bin/env bash
# =============================================================================
#  check-monitoring.sh
#  Runs a quick health check on the deployed monitoring stack.
#  Run from any machine that has kubectl access to the cluster.
# =============================================================================

set -euo pipefail

NAMESPACE="monitoring"
HELM_RELEASE="kube-prom-stack"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✔${NC}  $*"; }
fail() { echo -e "  ${RED}✘${NC}  $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $*"; }

echo -e "\n${BLUE}${BOLD}═══════════════════════════════════════════════${NC}"
echo -e "${BLUE}${BOLD}  Monitoring Stack Health Check${NC}"
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════${NC}\n"

# Pods
echo -e "${BOLD}Pods in '$NAMESPACE' namespace:${NC}"
kubectl get pods -n "$NAMESPACE" -o wide
echo ""

# Check for any non-running pods
NOT_RUNNING=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
  | grep -v "Running\|Completed" | awk '{print $1}' || true)
if [[ -z "$NOT_RUNNING" ]]; then
  ok "All pods are Running."
else
  fail "These pods are NOT running:"
  echo "$NOT_RUNNING" | sed 's/^/     /'
  echo ""
  echo "  Debug: kubectl describe pod <pod-name> -n $NAMESPACE"
  echo "         kubectl logs <pod-name> -n $NAMESPACE"
fi
echo ""

# Services
echo -e "${BOLD}Services:${NC}"
kubectl get svc -n "$NAMESPACE"
echo ""

# PVCs
echo -e "${BOLD}Persistent Volume Claims:${NC}"
kubectl get pvc -n "$NAMESPACE"
echo ""

# Helm release
echo -e "${BOLD}Helm Release Status:${NC}"
helm status "$HELM_RELEASE" -n "$NAMESPACE" 2>/dev/null || warn "Helm release not found."
echo ""

# Resource usage
echo -e "${BOLD}Node Resource Usage:${NC}"
kubectl top nodes 2>/dev/null || warn "metrics-server not running — 'kubectl top' unavailable."
echo ""
echo -e "${BOLD}Pod Resource Usage (monitoring namespace):${NC}"
kubectl top pods -n "$NAMESPACE" 2>/dev/null || warn "metrics-server not running — 'kubectl top' unavailable."
echo ""

# Events (last 10 warnings)
echo -e "${BOLD}Recent Warning Events in '$NAMESPACE':${NC}"
kubectl get events -n "$NAMESPACE" --field-selector type=Warning \
  --sort-by='.lastTimestamp' 2>/dev/null | tail -10 || echo "  None."
echo ""

echo -e "${BOLD}Useful Troubleshooting Commands:${NC}"
echo "  kubectl describe pod <pod>         -n $NAMESPACE    # full pod details"
echo "  kubectl logs <pod>                 -n $NAMESPACE    # pod logs"
echo "  kubectl logs <pod> --previous      -n $NAMESPACE    # logs of crashed container"
echo "  kubectl get events                 -n $NAMESPACE    # all events"
echo "  kubectl get pv                                       # cluster-wide PVs"
echo "  kubectl get storageclass                             # available storage classes"
echo ""
echo -e "${YELLOW}If Grafana dashboards show 'No Data':${NC}"
echo "  1. Check Prometheus targets: http://<worker-ip>:32001/targets"
echo "  2. Verify Prometheus is scraping your nodes"
echo "  3. In Grafana → Data Sources → Prometheus → Test & Save"
echo ""
