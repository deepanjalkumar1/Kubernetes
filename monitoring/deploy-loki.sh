#!/usr/bin/env bash
# =============================================================================
#  deploy-loki.sh
#
#  Deploys Loki + Promtail on the existing monitoring stack.
#  Tailored for this exact cluster:
#    Master  : ip-172-31-47-215  Ubuntu 24.04  control-plane taint
#    Worker  : ip-172-31-40-9    Ubuntu 24.04  7.4G free disk  2.4G free RAM
#    K8s     : v1.29.15  containerd 1.7.28
#    Grafana : already running in 'monitoring' namespace
#
#  What this does:
#    1. Adds grafana helm repo
#    2. Deploys Loki in SingleBinary (monolithic) mode — simplest, least RAM
#       Local filesystem storage — 2Gi PVC on worker
#    3. Deploys Promtail as DaemonSet on BOTH nodes (master + worker)
#       Tails /var/log/pods/** — every container log automatically
#    4. Adds Loki as a datasource in Grafana automatically
#    5. No IAM role required — uses local disk
#
#  LIMITATION: Logs stored locally on worker. If worker is terminated, logs lost.
#  To fix this later: attach IAM role to worker + rerun with S3 backend.
#
#  HOW TO RUN (on master node):
#    chmod +x deploy-loki.sh
#    ./deploy-loki.sh
#
#  TO UNINSTALL:
#    ./deploy-loki.sh --uninstall
# =============================================================================

set -euo pipefail

# ─── CONFIGURATION ────────────────────────────────────────────────────────────
NAMESPACE="monitoring"
LOKI_RELEASE="loki"
PROMTAIL_RELEASE="promtail"
LOKI_CHART="grafana/loki"
PROMTAIL_CHART="grafana/promtail"
LOKI_CHART_VERSION="6.6.2"       # Pinned — do not use latest in production
PROMTAIL_CHART_VERSION="6.15.5"  # Pinned
LOKI_PVC_SIZE="2Gi"              # Safe for 7.4G free worker disk
LOKI_VALUES="/tmp/loki-values.yaml"
PROMTAIL_VALUES="/tmp/promtail-values.yaml"
STORAGE_CLASS="local-path"       # Already installed from monitoring deploy
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

# ─── UNINSTALL ────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--uninstall" ]]; then
  log_section "UNINSTALL Loki + Promtail"
  helm uninstall "$LOKI_RELEASE" -n "$NAMESPACE" 2>/dev/null \
    && log_info "Loki removed." || log_warn "Loki not found."
  helm uninstall "$PROMTAIL_RELEASE" -n "$NAMESPACE" 2>/dev/null \
    && log_info "Promtail removed." || log_warn "Promtail not found."
  kubectl delete pvc -n "$NAMESPACE" \
    -l "app.kubernetes.io/name=loki" --ignore-not-found=true
  log_info "Done. Grafana datasource must be removed manually in the UI."
  exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════════
log_section "STEP 1: Pre-flight checks"
# ═══════════════════════════════════════════════════════════════════════════════

## kubeconfig
if [[ -z "${KUBECONFIG:-}" ]]; then
  if [[ -f "$HOME/.kube/config" ]]; then
    export KUBECONFIG="$HOME/.kube/config"
  elif [[ -f "/etc/kubernetes/admin.conf" ]]; then
    export KUBECONFIG="/etc/kubernetes/admin.conf"
  fi
fi
kubectl cluster-info &>/dev/null || {
  log_error "Cannot reach cluster. Run:"
  echo "  mkdir -p \$HOME/.kube"
  echo "  sudo cp /etc/kubernetes/admin.conf \$HOME/.kube/config"
  echo "  sudo chown \$(id -u):\$(id -g) \$HOME/.kube/config"
  exit 1
}
log_info "Cluster reachable ✔"

## Helm
command -v helm &>/dev/null || {
  log_error "Helm not found. Run deploy-monitoring.sh first — it installs Helm."
  exit 1
}
log_info "Helm $(helm version --short) ✔"

## Monitoring namespace exists
kubectl get namespace "$NAMESPACE" &>/dev/null || {
  log_error "Namespace '$NAMESPACE' not found."
  log_error "Run deploy-monitoring.sh first."
  exit 1
}
log_info "Namespace '$NAMESPACE' exists ✔"

## Grafana is running
GRAFANA_POD=$(kubectl get pod -n "$NAMESPACE" \
  -l "app.kubernetes.io/name=grafana" \
  --no-headers 2>/dev/null | awk 'NR==1{print $1}')
if [[ -z "$GRAFANA_POD" ]]; then
  log_error "Grafana pod not found in '$NAMESPACE'."
  log_error "Run deploy-monitoring.sh first."
  exit 1
fi
log_info "Grafana pod: $GRAFANA_POD ✔"

## StorageClass exists
kubectl get storageclass "$STORAGE_CLASS" &>/dev/null || {
  log_error "StorageClass '$STORAGE_CLASS' not found."
  log_error "Run deploy-monitoring.sh first — it installs local-path-provisioner."
  exit 1
}
log_info "StorageClass '$STORAGE_CLASS' ✔"

## Worker disk — need at least 3G free
WORKER_NODE=$(kubectl get nodes --no-headers \
  -l '!node-role.kubernetes.io/control-plane,!node-role.kubernetes.io/master' \
  2>/dev/null | awk 'NR==1{print $1}')
WORKER_DISK=$(kubectl get node "$WORKER_NODE" \
  -o jsonpath='{.status.allocatable.ephemeral-storage}' 2>/dev/null)
WORKER_DISK_GB=$(( ${WORKER_DISK:-0} / 1024 / 1024 / 1024 ))
log_info "Worker allocatable disk: ~${WORKER_DISK_GB}Gi"
if [[ "$WORKER_DISK_GB" -lt 3 ]]; then
  log_error "Worker only has ~${WORKER_DISK_GB}Gi free. Need at least 3Gi for Loki."
  exit 1
fi

## Check Loki not already installed
if helm status "$LOKI_RELEASE" -n "$NAMESPACE" &>/dev/null; then
  log_warn "Loki already installed. To reinstall: ./deploy-loki.sh --uninstall first."
  exit 0
fi

log_info "All pre-flight checks passed ✔"

# ═══════════════════════════════════════════════════════════════════════════════
log_section "STEP 2: Add Grafana Helm repo"
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
log_section "STEP 3: Generate Loki values"
# ═══════════════════════════════════════════════════════════════════════════════

cat > "$LOKI_VALUES" << 'YAML'
loki:
  commonConfig:
    replication_factor: 1

  auth_enabled: false

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

log_info "Loki values written to $LOKI_VALUES ✔"

# ═══════════════════════════════════════════════════════════════════════════════
log_section "STEP 4: Generate Promtail values"
# ═══════════════════════════════════════════════════════════════════════════════

cat > "$PROMTAIL_VALUES" << YAML
config:
  clients:
    - url: http://${LOKI_RELEASE}.${NAMESPACE}.svc.cluster.local:3100/loki/api/v1/push

  snippets:
    pipelineStages:
      - cri: {}

    scrapeConfigs: |
      - job_name: kubernetes-pods
        kubernetes_sd_configs:
          - role: pod
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

log_info "Promtail values written to $PROMTAIL_VALUES ✔"

# ═══════════════════════════════════════════════════════════════════════════════
log_section "STEP 5: Deploy Loki"
# ═══════════════════════════════════════════════════════════════════════════════

log_info "Installing Loki $LOKI_CHART_VERSION..."
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
        url: http://${LOKI_RELEASE}.${NAMESPACE}.svc.cluster.local:3100
        isDefault: false
        version: 1
        editable: true
        jsonData:
          maxLines: 1000
          timeout: 60
YAML

log_info "Loki datasource ConfigMap applied ✔"
log_info "Grafana sidecar will pick it up within ~30s — no pod restart needed."

# ═══════════════════════════════════════════════════════════════════════════════
log_section "STEP 8: Wait for pods"
# ═══════════════════════════════════════════════════════════════════════════════

log_info "Watching pods in namespace '$NAMESPACE'..."
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
    | awk '{printf "    %-60s  %-15s  %s\n", $1, $3, $4}' || true

  if [[ "$NOT_READY" -eq 0 && "$TOTAL" -gt 0 ]]; then
    echo ""
    log_info "All $TOTAL pods are Running ✔"
    break
  fi

  if (( ELAPSED - LAST_DIAG >= 60 )); then
    LAST_DIAG=$ELAPSED
    WARN=$(kubectl get events -n "$NAMESPACE" \
      --field-selector type=Warning --sort-by='.lastTimestamp' 2>/dev/null \
      | tail -5 || true)
    if [[ -n "$WARN" ]]; then
      echo -e "\n  ${YELLOW}Warning events:${NC}"
      echo "$WARN" | sed 's/^/    /'
    fi
  fi

  if [[ "$ELAPSED" -gt 300 ]]; then
    echo ""
    log_warn "Timeout — pods may still be pulling images."
    log_warn "Keep watching: watch -n10 'kubectl get pods -n $NAMESPACE'"
    break
  fi

  sleep 15
done

# ═══════════════════════════════════════════════════════════════════════════════
log_section "STEP 9: Verify Loki is receiving logs"
# ═══════════════════════════════════════════════════════════════════════════════

LOKI_POD=$(kubectl get pod -n "$NAMESPACE" \
  -l "app.kubernetes.io/name=loki" \
  --no-headers 2>/dev/null | awk 'NR==1{print $1}')

if [[ -n "$LOKI_POD" ]]; then
  log_info "Testing Loki API from inside cluster..."
  sleep 10
  kubectl exec -n "$NAMESPACE" "$LOKI_POD" -- \
    wget -qO- "http://localhost:3100/ready" 2>/dev/null \
    && log_info "Loki is ready and accepting logs ✔" \
    || log_warn "Loki not ready yet — wait 1-2 min and check again."
fi

# ═══════════════════════════════════════════════════════════════════════════════
log_section "HOW TO VIEW LOGS IN GRAFANA"
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}${BOLD}  Grafana is at: http://<master-public-ip>:32000${NC}"
echo ""
echo -e "${BOLD}  To see your FastAPI pod logs:${NC}"
echo -e "  1. Left sidebar → Explore (compass icon)"
echo -e "  2. Top left dropdown → select 'Loki'"
echo -e "  3. Click 'Label filters'"
echo -e "  4. Set: namespace = default"
echo -e "  5. Set: pod = <your-fastapi-pod-name>"
echo -e "  6. Click 'Run query'"
echo ""
echo -e "${BOLD}  Useful LogQL queries:${NC}"
echo -e '  All logs from default namespace:'
echo -e '    {namespace="default"}'
echo -e ""
echo -e '  Logs from a specific pod:'
echo -e '    {namespace="default", pod=~"fastapi.*"}'
echo -e ""
echo -e '  Filter for errors only:'
echo -e '    {namespace="default", pod=~"fastapi.*"} |= "error"'
echo -e ""
echo -e '  Filter for HTTP 5xx:'
echo -e '    {namespace="default", pod=~"fastapi.*"} |= "500"'
echo -e ""
echo -e '  Error rate over time:'
echo -e '    sum(rate({namespace="default"} |= "error" [5m]))'
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${YELLOW}${BOLD}  Limitations:${NC}"
echo -e "  • Logs on worker local disk — lost if worker terminated"
echo -e "  • 7 days retention (2Gi PVC)"
echo ""
echo -e "${BOLD}  Useful commands:${NC}"
echo -e "  kubectl logs -n default <pod-name> -f"
echo -e "  kubectl logs -n default <pod-name> --previous"
echo -e "  helm status loki -n monitoring"
echo -e "  helm status promtail -n monitoring"
echo -e "  ./deploy-loki.sh --uninstall"
echo ""
