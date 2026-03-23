#!/usr/bin/env bash
# =============================================================================
#  deploy-loki.sh  — v4 complete rewrite
#
#  Deploys Loki + Promtail for log collection from ALL pods.
#  Run on the MASTER node only.
#
#  Cluster facts this script is built on:
#    Master  : ip-172-31-47-215  Ubuntu 24.04  control-plane taint
#    Worker  : ip-172-31-40-9    Ubuntu 24.04  ~7G free disk  ~2.4G free RAM
#    K8s     : v1.29.15  containerd 1.7.28
#    Grafana : running in 'monitoring' namespace on NodePort 32000
#
#  Key fixes vs all previous versions:
#    Chart 5.47.2 — last version that reliably runs in singleBinary mode
#    Chart 6.x ignores singleBinary and deploys distributed needing 8+ pods
#    Datasource URL points directly to loki:3100 — no gateway
#    Promtail has single clean client URL — no duplicate keys
#    Must run on MASTER — enforced by pre-flight check
#
#  HOW TO RUN:
#    chmod +x deploy-loki.sh
#    ./deploy-loki.sh
#
#  TO UNINSTALL:
#    ./cleanup-loki.sh
# =============================================================================

set -euo pipefail

# ─── CONFIGURATION ────────────────────────────────────────────────────────────
NAMESPACE="monitoring"
LOKI_RELEASE="loki"
PROMTAIL_RELEASE="promtail"
LOKI_CHART="grafana/loki"
PROMTAIL_CHART="grafana/promtail"
LOKI_CHART_VERSION="5.47.2"
PROMTAIL_CHART_VERSION="6.15.5"
LOKI_VALUES="/tmp/loki-values.yaml"
PROMTAIL_VALUES="/tmp/promtail-values.yaml"
STORAGE_CLASS="local-path"
# ──────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_section() {
  echo -e "\n${BLUE}${BOLD}══════════════════════════════════════════════════════${NC}"
  echo -e "${BLUE}${BOLD}  $*${NC}"
  echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════════${NC}"
}

# ═══════════════════════════════════════════════════════════════════════════════
log_section "STEP 1: Pre-flight checks"
# ═══════════════════════════════════════════════════════════════════════════════

# Must run on master
if [[ ! -f "/etc/kubernetes/manifests/kube-apiserver.yaml" ]]; then
  log_error "This script must run on the MASTER node."
  log_error "You are on the worker node. Run: exit   then re-run this script."
  exit 1
fi
log_info "Running on master node ✔"

# kubeconfig
if [[ -z "${KUBECONFIG:-}" ]]; then
  if [[ -f "$HOME/.kube/config" ]]; then
    export KUBECONFIG="$HOME/.kube/config"
  elif [[ -f "/etc/kubernetes/admin.conf" ]]; then
    export KUBECONFIG="/etc/kubernetes/admin.conf"
  fi
fi
kubectl cluster-info &>/dev/null || {
  log_error "Cannot reach cluster. Fix kubeconfig:"
  echo "  mkdir -p \$HOME/.kube"
  echo "  sudo cp /etc/kubernetes/admin.conf \$HOME/.kube/config"
  echo "  sudo chown \$(id -u):\$(id -g) \$HOME/.kube/config"
  exit 1
}
log_info "Cluster reachable ✔"

# Helm
command -v helm &>/dev/null || {
  log_error "Helm not found."
  echo "  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
  exit 1
}
log_info "Helm $(helm version --short) ✔"

# Namespace
kubectl get namespace "$NAMESPACE" &>/dev/null || {
  log_error "Namespace '$NAMESPACE' not found. Run deploy-monitoring.sh first."
  exit 1
}
log_info "Namespace '$NAMESPACE' ✔"

# Grafana running
GRAFANA_POD=$(kubectl get pod -n "$NAMESPACE" \
  -l "app.kubernetes.io/name=grafana" \
  --no-headers 2>/dev/null | grep "Running" | awk 'NR==1{print $1}')
[[ -z "$GRAFANA_POD" ]] && {
  log_error "Grafana not Running. Fix it first: kubectl get pods -n $NAMESPACE"
  exit 1
}
log_info "Grafana: $GRAFANA_POD ✔"

# StorageClass
kubectl get storageclass "$STORAGE_CLASS" &>/dev/null || {
  log_error "StorageClass '$STORAGE_CLASS' not found. Run deploy-monitoring.sh first."
  exit 1
}
log_info "StorageClass '$STORAGE_CLASS' ✔"

# Worker disk
WORKER_NODE=$(kubectl get nodes --no-headers \
  -l '!node-role.kubernetes.io/control-plane,!node-role.kubernetes.io/master' \
  2>/dev/null | awk 'NR==1{print $1}')
WORKER_DISK=$(kubectl get node "$WORKER_NODE" \
  -o jsonpath='{.status.allocatable.ephemeral-storage}' 2>/dev/null || echo "0")
WORKER_DISK_GB=$(( ${WORKER_DISK} / 1024 / 1024 / 1024 ))
log_info "Worker disk: ~${WORKER_DISK_GB}Gi allocatable"
[[ "$WORKER_DISK_GB" -lt 3 ]] && {
  log_error "Worker only has ~${WORKER_DISK_GB}Gi. Need at least 3Gi."
  exit 1
}

# Loki not already installed
if helm status "$LOKI_RELEASE" -n "$NAMESPACE" &>/dev/null; then
  log_error "Loki already installed. Run ./cleanup-loki.sh first."
  exit 1
fi

log_info "All pre-flight checks passed ✔"

# ═══════════════════════════════════════════════════════════════════════════════
log_section "STEP 2: Grafana Helm repo"
# ═══════════════════════════════════════════════════════════════════════════════

if ! helm repo list 2>/dev/null | grep -q "^grafana"; then
  helm repo add grafana https://grafana.github.io/helm-charts
  log_info "grafana repo added ✔"
else
  log_info "grafana repo already present ✔"
fi
helm repo update
log_info "Repos updated ✔"

# ═══════════════════════════════════════════════════════════════════════════════
log_section "STEP 3: Loki values"
# ═══════════════════════════════════════════════════════════════════════════════

cat > "$LOKI_VALUES" << 'YAML'
loki:
  auth_enabled: false

  commonConfig:
    replication_factor: 1

  storage:
    type: filesystem

  schemaConfig:
    configs:
      - from: "2024-01-01"
        store: tsdb
        object_store: filesystem
        schema: v13
        index:
          prefix: loki_index_
          period: 24h

  limits_config:
    retention_period: 168h
    ingestion_rate_mb: 4
    ingestion_burst_size_mb: 6
    max_streams_per_user: 0
    max_global_streams_per_user: 0

  compactor:
    working_directory: /var/loki/compactor
    retention_enabled: true
    retention_delete_delay: 2h

singleBinary:
  replicas: 1
  resources:
    requests:
      cpu: 100m
      memory: 200Mi
    limits:
      cpu: 300m
      memory: 400Mi
  persistence:
    enabled: true
    storageClass: local-path
    size: 2Gi
    accessModes:
      - ReadWriteOnce
  extraEnv:
    - name: GOMEMLIMIT
      value: "350MiB"

read:
  replicas: 0
write:
  replicas: 0
backend:
  replicas: 0

gateway:
  enabled: false

monitoring:
  selfMonitoring:
    enabled: false
    grafanaAgent:
      installOperator: false
  lokiCanary:
    enabled: false
  dashboards:
    enabled: false

grafana:
  enabled: false
prometheus:
  enabled: false
promtail:
  enabled: false

chunksCache:
  enabled: false
resultsCache:
  enabled: false
lokiCanary:
  enabled: false
test:
  enabled: false

serviceMonitor:
  enabled: true
  labels:
    release: kube-prom-stack
YAML

log_info "Loki values → $LOKI_VALUES ✔"

# ═══════════════════════════════════════════════════════════════════════════════
log_section "STEP 4: Promtail values"
# ═══════════════════════════════════════════════════════════════════════════════

cat > "$PROMTAIL_VALUES" << YAML
config:
  clients:
    - url: http://loki.${NAMESPACE}.svc.cluster.local:3100/loki/api/v1/push

  snippets:
    pipelineStages:
      - cri: {}

    scrapeConfigs: |
      - job_name: kubernetes-pods
        kubernetes_sd_configs:
          - role: pod
        pipeline_stages:
          - cri: {}
        relabel_configs:
          - source_labels: [__meta_kubernetes_namespace]
            target_label: namespace
          - source_labels: [__meta_kubernetes_pod_name]
            target_label: pod
          - source_labels: [__meta_kubernetes_pod_container_name]
            target_label: container
          - source_labels: [__meta_kubernetes_pod_label_app]
            target_label: app
          - source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_name]
            target_label: app
          - source_labels: [__meta_kubernetes_pod_node_name]
            target_label: node
          - source_labels:
              [__meta_kubernetes_pod_uid, __meta_kubernetes_pod_container_name]
            target_label: __path__
            separator: /
            replacement: /var/log/pods/*\$1*/*\$2*/*.log

resources:
  requests:
    cpu: 50m
    memory: 80Mi
  limits:
    cpu: 200m
    memory: 128Mi

tolerations:
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule
  - key: node-role.kubernetes.io/master
    operator: Exists
    effect: NoSchedule

volumeMounts:
  - name: pods-logs
    mountPath: /var/log/pods
    readOnly: true
  - name: containers-logs
    mountPath: /var/log/containers
    readOnly: true

volumes:
  - name: pods-logs
    hostPath:
      path: /var/log/pods
  - name: containers-logs
    hostPath:
      path: /var/log/containers

serviceMonitor:
  enabled: true
  labels:
    release: kube-prom-stack
YAML

log_info "Promtail values → $PROMTAIL_VALUES ✔"

# ═══════════════════════════════════════════════════════════════════════════════
log_section "STEP 5: Deploy Loki"
# ═══════════════════════════════════════════════════════════════════════════════

log_info "Installing Loki $LOKI_CHART_VERSION (singleBinary mode)..."
helm upgrade --install "$LOKI_RELEASE" "$LOKI_CHART" \
  --namespace "$NAMESPACE" \
  --version "$LOKI_CHART_VERSION" \
  --values "$LOKI_VALUES" \
  --wait=false

log_info "Loki manifests applied ✔"

# ═══════════════════════════════════════════════════════════════════════════════
log_section "STEP 6: Deploy Promtail"
# ═══════════════════════════════════════════════════════════════════════════════

log_info "Installing Promtail $PROMTAIL_CHART_VERSION..."
helm upgrade --install "$PROMTAIL_RELEASE" "$PROMTAIL_CHART" \
  --namespace "$NAMESPACE" \
  --version "$PROMTAIL_CHART_VERSION" \
  --values "$PROMTAIL_VALUES" \
  --wait=false

log_info "Promtail manifests applied ✔"

# ═══════════════════════════════════════════════════════════════════════════════
log_section "STEP 7: Add Loki datasource to Grafana"
# ═══════════════════════════════════════════════════════════════════════════════

kubectl apply -f - << YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-datasource
  namespace: ${NAMESPACE}
  labels:
    grafana_datasource: "1"
data:
  loki-datasource.yaml: |-
    apiVersion: 1
    datasources:
      - name: Loki
        type: loki
        uid: loki
        access: proxy
        url: http://loki.${NAMESPACE}.svc.cluster.local:3100
        isDefault: false
        version: 1
        editable: true
        jsonData:
          maxLines: 1000
          timeout: 60
YAML

log_info "Loki datasource ConfigMap applied ✔"
log_info "Grafana picks this up in ~30s — no restart needed."

# ═══════════════════════════════════════════════════════════════════════════════
log_section "STEP 8: Wait for pods"
# ═══════════════════════════════════════════════════════════════════════════════

log_info "Watching '$NAMESPACE' namespace..."
START_TIME=$(date +%s)
LAST_DIAG=0

while true; do
  ELAPSED=$(( $(date +%s) - START_TIME ))
  TOTAL=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -c "." || true)
  NOT_READY=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
    | grep -cv " Running \| Completed " || true)

  echo ""
  echo -e "  ${BOLD}[${ELAPSED}s]  Ready: $(( TOTAL - NOT_READY ))/${TOTAL}${NC}"
  kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
    | awk '{printf "    %-60s  %-12s  %s\n", $1, $3, $4}' || true

  [[ "$NOT_READY" -eq 0 && "$TOTAL" -gt 0 ]] && {
    echo ""
    log_info "All $TOTAL pods Running ✔"
    break
  }

  if (( ELAPSED - LAST_DIAG >= 60 )); then
    LAST_DIAG=$ELAPSED
    WARN=$(kubectl get events -n "$NAMESPACE" \
      --field-selector type=Warning \
      --sort-by='.lastTimestamp' 2>/dev/null | tail -5 || true)
    [[ -n "$WARN" ]] && {
      echo -e "\n  ${YELLOW}Warning events:${NC}"
      echo "$WARN" | sed 's/^/    /'
    }
  fi

  [[ "$ELAPSED" -gt 300 ]] && {
    echo ""
    log_warn "Timeout — pods may still be pulling images."
    log_warn "Watch: watch -n10 'kubectl get pods -n $NAMESPACE'"
    break
  }

  sleep 15
done

# ═══════════════════════════════════════════════════════════════════════════════
log_section "STEP 9: Verify"
# ═══════════════════════════════════════════════════════════════════════════════

log_info "Waiting 15s for Loki to initialise..."
sleep 15

LOKI_POD=$(kubectl get pod -n "$NAMESPACE" \
  -l "app.kubernetes.io/name=loki" \
  --no-headers 2>/dev/null | grep "Running" | awk 'NR==1{print $1}' || true)

if [[ -n "$LOKI_POD" ]]; then
  READY=$(kubectl exec -n "$NAMESPACE" "$LOKI_POD" -- \
    wget -qO- "http://localhost:3100/ready" 2>/dev/null || echo "not ready yet")
  echo "$READY" | grep -q "ready" \
    && log_info "Loki ready ✔" \
    || log_warn "Loki not ready yet — check: kubectl logs $LOKI_POD -n $NAMESPACE"
else
  log_warn "Loki pod not Running yet. Check: kubectl get pods -n $NAMESPACE"
fi

echo ""
log_info "Services:"
kubectl get svc -n "$NAMESPACE" | grep -E "NAME|loki|promtail"

# ═══════════════════════════════════════════════════════════════════════════════
log_section "DONE — How to view logs in Grafana"
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}${BOLD}  Grafana → http://<master-public-ip>:32000${NC}"
echo -e "${GREEN}${BOLD}  Login  → admin / ChangeMe@123${NC}"
echo ""
echo -e "${BOLD}  View FastAPI pod logs:${NC}"
echo -e "  1. Left sidebar → Explore (compass icon)"
echo -e "  2. Datasource dropdown → select Loki"
echo -e "  3. Label filters → namespace = default"
echo -e "  4. Add filter  → pod =~ fastapi.*"
echo -e "  5. Click Run query"
echo ""
echo -e "${BOLD}  LogQL queries:${NC}"
echo -e '    All default namespace   : {namespace="default"}'
echo -e '    FastAPI pods            : {namespace="default",pod=~"fastapi.*"}'
echo -e '    Errors only             : {namespace="default",pod=~"fastapi.*"} |= "error"'
echo -e '    HTTP 500s               : {namespace="default",pod=~"fastapi.*"} |= "500"'
echo ""
echo -e "${BOLD}  Terminal:${NC}"
echo -e "    kubectl logs -n default <pod> -f          # live tail"
echo -e "    kubectl logs -n default <pod> --previous  # last crashed container"
echo ""
echo -e "${YELLOW}  Limitation: Logs on worker local disk — lost if worker is terminated.${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
