#!/usr/bin/env bash
# =============================================================================
#  deploy-monitoring.sh  —  v3 (complete rewrite)
#
#  Target cluster (hard-coded facts, do not assume anything else):
#    Master  : ip-172-31-47-215  Ubuntu 24.04  19G disk  control-plane taint
#    Worker  : ip-172-31-40-9    Ubuntu 24.04  6.8G disk  NO taints  3.8G RAM
#    K8s     : v1.29.15  containerd 1.7.28
#
#  What changed vs all previous versions:
#    ✔ local-path-provisioner installed from the OFFICIAL Rancher manifest
#      (pinned tag) — no hand-rolled RBAC, no missing verbs
#    ✔ PVC sizes fit the 6.8G worker disk: Prometheus 2Gi, Alertmanager 500Mi
#    ✔ Grafana persistence DISABLED — 6.8G disk cannot safely hold more PVCs
#    ✔ --atomic removed permanently — it deletes everything on any timeout
#    ✔ Resource requests sized for 3.8G RAM worker (total ~850Mi requests)
#    ✔ Pre-flight aborts if worker disk < 4G free
#    ✔ Control-plane metrics patched inline (running on master)
#    ✔ kubeconfig auto-detected for root and non-root users
#    ✔ Helm 3 auto-installed if missing
#
#  HOW TO RUN (on the master node):
#    chmod +x deploy-monitoring.sh
#    sudo ./deploy-monitoring.sh
#
#  TO UNINSTALL:
#    sudo ./deploy-monitoring.sh --uninstall
# =============================================================================

set -euo pipefail

# ─── CONFIGURATION ────────────────────────────────────────────────────────────
NAMESPACE="monitoring"
HELM_RELEASE="kube-prom-stack"
HELM_CHART="prometheus-community/kube-prometheus-stack"
HELM_CHART_VERSION="58.2.2"

GRAFANA_NODEPORT=32000
PROMETHEUS_NODEPORT=32001
ALERTMANAGER_NODEPORT=32002
GRAFANA_ADMIN_PASSWORD="ChangeMe@123"   # ← CHANGE THIS before running

# Official Rancher local-path-provisioner — pinned, correct RBAC built in
LOCAL_PATH_MANIFEST="https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.28/deploy/local-path-storage.yaml"
LOCAL_PATH_VERSION="v0.0.28"

VALUES_FILE="/tmp/kube-prom-values.yaml"
MANIFEST_DIR="/etc/kubernetes/manifests"

# Worker disk: 6.8G total. PVC budget must leave room for OS + container images.
# Images alone are ~800MB. OS uses ~1.5G. Safe PVC budget: ~2.5G max.
PROMETHEUS_PVC="2Gi"
ALERTMANAGER_PVC="500Mi"
GRAFANA_PERSISTENCE=false   # disabled — disk too small

WAIT_TIMEOUT=600   # 10 minutes for image pulls
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

# ─── KUBECONFIG ───────────────────────────────────────────────────────────────
resolve_kubeconfig() {
  # Already working
  if [[ -n "${KUBECONFIG:-}" ]] && kubectl cluster-info &>/dev/null 2>&1; then
    log_info "KUBECONFIG: $KUBECONFIG"; return
  fi
  # Standard user location
  if [[ -f "$HOME/.kube/config" ]]; then
    export KUBECONFIG="$HOME/.kube/config"
    kubectl cluster-info &>/dev/null 2>&1 && { log_info "KUBECONFIG: $HOME/.kube/config"; return; }
  fi
  # kubeadm admin config (always present on master)
  if [[ -f "/etc/kubernetes/admin.conf" ]]; then
    export KUBECONFIG="/etc/kubernetes/admin.conf"
    if kubectl cluster-info &>/dev/null 2>&1; then
      if [[ "$EUID" -ne 0 ]]; then
        mkdir -p "$HOME/.kube"
        sudo cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
        sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
        export KUBECONFIG="$HOME/.kube/config"
      fi
      log_info "KUBECONFIG: /etc/kubernetes/admin.conf"; return
    fi
  fi
  log_error "No working kubeconfig found. Run:"
  echo "  mkdir -p \$HOME/.kube"
  echo "  sudo cp /etc/kubernetes/admin.conf \$HOME/.kube/config"
  echo "  sudo chown \$(id -u):\$(id -g) \$HOME/.kube/config"
  exit 1
}

# ─── UNINSTALL ────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--uninstall" ]]; then
  log_section "UNINSTALL"
  resolve_kubeconfig
  helm uninstall "$HELM_RELEASE" -n "$NAMESPACE" 2>/dev/null \
    && log_info "Helm release removed." || log_warn "Helm release not found."
  kubectl delete namespace "$NAMESPACE" --ignore-not-found=true
  kubectl delete -f "$LOCAL_PATH_MANIFEST" --ignore-not-found=true 2>/dev/null || true
  kubectl delete namespace local-path-storage --ignore-not-found=true
  log_info "Done."
  exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════════
log_section "STEP 1: Pre-flight checks"
# ═══════════════════════════════════════════════════════════════════════════════

## kubectl
if ! command -v kubectl &>/dev/null; then
  log_error "kubectl not found."; exit 1
fi
log_info "kubectl $(kubectl version --client --short 2>/dev/null | head -1)"

## Helm — auto-install if missing
if ! command -v helm &>/dev/null; then
  log_warn "Helm not found — installing..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
HELM_MAJOR=$(helm version --short 2>/dev/null | grep -oP 'v\K[0-9]+' | head -1)
[[ "$HELM_MAJOR" -lt 3 ]] && { log_error "Helm v3 required."; exit 1; }
log_info "Helm $(helm version --short)"

## kubeconfig
resolve_kubeconfig

## Cluster reachable
kubectl cluster-info &>/dev/null || { log_error "Cannot reach cluster."; exit 1; }
log_info "Cluster is reachable."

## Nodes
log_info "Nodes:"
kubectl get nodes -o wide
READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready ")
[[ "$READY_NODES" -lt 2 ]] && log_warn "Only $READY_NODES Ready node(s) found — expected 2."

## Is this the master?
IS_MASTER=false
[[ -f "$MANIFEST_DIR/kube-apiserver.yaml" ]] && IS_MASTER=true \
  && log_info "Running on master node ✔" \
  || log_warn "kube-apiserver.yaml not found — control-plane patch will be skipped."

# ═══════════════════════════════════════════════════════════════════════════════
log_section "STEP 2: Detect node IPs"
# ═══════════════════════════════════════════════════════════════════════════════

WORKER_NODE=$(kubectl get nodes --no-headers \
  -l '!node-role.kubernetes.io/control-plane,!node-role.kubernetes.io/master' \
  2>/dev/null | awk 'NR==1{print $1}')
[[ -z "$WORKER_NODE" ]] && WORKER_NODE=$(kubectl get nodes --no-headers | awk 'NR==1{print $1}')

# Try ExternalIP first, fall back to InternalIP
NODE_IP=$(kubectl get node "$WORKER_NODE" \
  -o jsonpath='{.status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null)
[[ -z "$NODE_IP" ]] && NODE_IP=$(kubectl get node "$WORKER_NODE" \
  -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
[[ -z "$NODE_IP" ]] && { log_error "Cannot determine worker IP."; exit 1; }

# Master internal IP (for control-plane scrape endpoints)
MASTER_NODE=$(kubectl get nodes --no-headers \
  -l 'node-role.kubernetes.io/control-plane' 2>/dev/null | awk 'NR==1{print $1}')
MASTER_IP=""
[[ -n "$MASTER_NODE" ]] && MASTER_IP=$(kubectl get node "$MASTER_NODE" \
  -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)

log_info "Worker : $WORKER_NODE | IP : $NODE_IP"
log_info "Master : ${MASTER_NODE:-unknown} | IP : ${MASTER_IP:-unknown}"

# ═══════════════════════════════════════════════════════════════════════════════
log_section "STEP 3: Worker node health checks"
# ═══════════════════════════════════════════════════════════════════════════════

## Worker must be Ready
WORKER_STATUS=$(kubectl get node "$WORKER_NODE" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
[[ "$WORKER_STATUS" != "True" ]] && {
  log_error "Worker '$WORKER_NODE' is NOT Ready. Fix it first."
  kubectl describe node "$WORKER_NODE" | grep -A5 "Conditions:"
  exit 1
}
log_info "Worker is Ready ✔"

## Worker disk — abort if less than 4G free (need ~2.5G PVCs + ~800M images + headroom)
WORKER_DISK_FREE_KB=$(kubectl get node "$WORKER_NODE" \
  -o jsonpath='{.status.allocatable.ephemeral-storage}' 2>/dev/null)
# Value is in bytes from API
WORKER_DISK_FREE_GB=$(( ${WORKER_DISK_FREE_KB:-0} / 1024 / 1024 / 1024 ))
log_info "Worker allocatable ephemeral storage: ~${WORKER_DISK_FREE_GB}Gi"
if [[ "$WORKER_DISK_FREE_GB" -lt 4 ]]; then
  log_error "Worker has only ~${WORKER_DISK_FREE_GB}Gi ephemeral storage."
  log_error "Need at least 4Gi free (2.5Gi PVCs + container images + headroom)."
  log_error "Free up space on the worker or use a larger instance."
  exit 1
fi

## Worker memory
WORKER_MEM_KB=$(kubectl get node "$WORKER_NODE" \
  -o jsonpath='{.status.allocatable.memory}' 2>/dev/null | grep -oP '[0-9]+')
WORKER_MEM_MB=$(( ${WORKER_MEM_KB:-0} / 1024 ))
log_info "Worker allocatable memory: ~${WORKER_MEM_MB}Mi"
if [[ "$WORKER_MEM_MB" -lt 1800 ]]; then
  log_error "Worker has only ~${WORKER_MEM_MB}Mi RAM. Need at least 1800Mi."
  exit 1
fi

## NodePort conflicts
for PORT in $GRAFANA_NODEPORT $PROMETHEUS_NODEPORT $ALERTMANAGER_NODEPORT; do
  IN_USE=$(kubectl get svc -A --no-headers 2>/dev/null \
    | awk '{print $6}' | grep -o "[0-9]*:${PORT}" | head -1 || true)
  [[ -n "$IN_USE" ]] && {
    log_error "NodePort $PORT already in use. Edit the port variables at the top of this script."
    exit 1
  }
done
log_info "NodePorts $GRAFANA_NODEPORT / $PROMETHEUS_NODEPORT / $ALERTMANAGER_NODEPORT are free ✔"

## Master disk
MASTER_FREE=$(df -BG / 2>/dev/null | awk 'NR==2{gsub("G","",$4); print $4}')
log_info "Master disk free: ${MASTER_FREE}Gi"
[[ "$MASTER_FREE" -lt 3 ]] && {
  log_error "Master only has ${MASTER_FREE}Gi free. Need at least 3Gi."
  log_error "Run: sudo journalctl --vacuum-size=100M && sudo crictl rmi --prune"
  exit 1
}

# ═══════════════════════════════════════════════════════════════════════════════
log_section "STEP 4: Patch control-plane metrics endpoints"
# ═══════════════════════════════════════════════════════════════════════════════
# kubeadm binds scheduler and controller-manager to 127.0.0.1 by default.
# etcd metrics port also defaults to 127.0.0.1.
# Prometheus pods cannot reach 127.0.0.1 on the master — they need 0.0.0.0.

patch_static_pod() {
  local FILE="$1" COMPONENT="$2" OLD="$3" NEW="$4"
  [[ ! -f "$FILE" ]] && { log_warn "$COMPONENT: $FILE not found — skipping."; return; }
  local BAK="${FILE}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$FILE" "$BAK" && log_info "$COMPONENT: backup → $BAK"
  if grep -q "$OLD" "$FILE"; then
    sed -i "s|${OLD}|${NEW}|g" "$FILE"
    log_info "$COMPONENT: patched ✔"
  else
    log_info "$COMPONENT: already patched or pattern not found — skipping."
  fi
}

if [[ "$IS_MASTER" == true ]]; then
  patch_static_pod "$MANIFEST_DIR/kube-scheduler.yaml" \
    "kube-scheduler" "--bind-address=127.0.0.1" "--bind-address=0.0.0.0"
  patch_static_pod "$MANIFEST_DIR/kube-controller-manager.yaml" \
    "kube-controller-manager" "--bind-address=127.0.0.1" "--bind-address=0.0.0.0"
  patch_static_pod "$MANIFEST_DIR/etcd.yaml" \
    "etcd" "--listen-metrics-urls=http://127.0.0.1" "--listen-metrics-urls=http://0.0.0.0"

  log_info "Waiting 25s for kubelet to restart patched static pods..."
  sleep 25
  log_info "Control-plane pods after patch:"
  kubectl get pods -n kube-system \
    | grep -E "etcd|scheduler|controller-manager" || true
else
  log_warn "Skipping control-plane patch (not on master)."
fi

# ═══════════════════════════════════════════════════════════════════════════════
log_section "STEP 5: Install local-path-provisioner (official Rancher manifest)"
# ═══════════════════════════════════════════════════════════════════════════════
# Using the OFFICIAL manifest, not hand-rolled RBAC.
# This has correct permissions including pod create/delete for helper pods.
# Pinned to v0.0.28 — do not change to 'latest'.

EXISTING_SC=$(kubectl get storageclass --no-headers 2>/dev/null | awk '{print $1}' | head -1)
if [[ -n "$EXISTING_SC" ]]; then
  log_info "StorageClass '$EXISTING_SC' already exists — skipping provisioner install."
  STORAGE_CLASS_NAME="$EXISTING_SC"
else
  log_info "Installing local-path-provisioner $LOCAL_PATH_VERSION..."
  kubectl apply -f "$LOCAL_PATH_MANIFEST"

  log_info "Waiting for provisioner pod to be Running..."
  kubectl rollout status deployment/local-path-provisioner \
    -n local-path-storage --timeout=90s

  # Patch StorageClass to use Immediate binding mode.
  # WaitForFirstConsumer can deadlock when pod scheduling and PVC binding
  # wait on each other. Immediate binds the PVC before the pod schedules,
  # which is safe and simple for a single-worker-node cluster.
  log_info "Patching StorageClass to Immediate binding mode..."
  kubectl patch storageclass local-path \
    -p '{"volumeBindingMode": "Immediate"}' 2>/dev/null \
    && log_info "StorageClass binding mode → Immediate ✔" \
    || log_warn "Could not patch binding mode (may already be Immediate)."

  STORAGE_CLASS_NAME="local-path"
  log_info "StorageClass '$STORAGE_CLASS_NAME' ready ✔"
fi

# ═══════════════════════════════════════════════════════════════════════════════
log_section "STEP 6: Helm repo"
# ═══════════════════════════════════════════════════════════════════════════════

if ! helm repo list 2>/dev/null | grep -q "prometheus-community"; then
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
  log_info "prometheus-community repo added."
else
  log_info "prometheus-community repo already present."
fi
helm repo update
log_info "Repos updated ✔"

# ═══════════════════════════════════════════════════════════════════════════════
log_section "STEP 7: Generate Helm values"
# ═══════════════════════════════════════════════════════════════════════════════
# Resource sizing rationale for this cluster:
#   Worker RAM: 3803Mi allocatable
#   Our total requests: ~850Mi  (leaves ~2950Mi for OS + other pods)
#   Our total limits:   ~2Gi    (hard ceiling, prevents OOM kill cascade)
#
# PVC sizing rationale for this cluster:
#   Worker disk: 6.8G total
#   OS + K8s system: ~1.5G
#   Container images: ~800M
#   PVCs: Prometheus 2G + Alertmanager 500M = 2.5G
#   Headroom: ~2G
#   Grafana persistence: DISABLED (no room left)

if [[ -n "$MASTER_IP" ]]; then
  CP_ENDPOINTS="[\"${MASTER_IP}\"]"
else
  CP_ENDPOINTS="[]"
fi

cat > "$VALUES_FILE" << YAML
# kube-prometheus-stack values
# Generated: $(date)
# Cluster: kubeadm k8s v1.29  master=${MASTER_IP:-?}  worker=${NODE_IP}
# Worker disk: 6.8G  RAM: 3.8G

# ── Prometheus ────────────────────────────────────────────────────────────────
prometheus:
  prometheusSpec:
    retention: 7d
    # 2Gi PVC on 6.8G worker disk — safe with headroom
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: ${STORAGE_CLASS_NAME}
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: ${PROMETHEUS_PVC}
    resources:
      requests:
        cpu: 150m
        memory: 400Mi
      limits:
        cpu: 800m
        memory: 1Gi
    scrapeInterval: "30s"
    evaluationInterval: "30s"
    # Do not try to scrape kube-proxy — port not open on manual clusters
    additionalScrapeConfigsSecret: {}
  service:
    type: NodePort
    nodePort: ${PROMETHEUS_NODEPORT}

# ── Grafana ───────────────────────────────────────────────────────────────────
grafana:
  adminPassword: "${GRAFANA_ADMIN_PASSWORD}"
  # Persistence DISABLED — worker disk is 6.8G and already has 2.5G in PVCs
  # Dashboards load from ConfigMaps on every start — no data loss risk
  persistence:
    enabled: false
  service:
    type: NodePort
    nodePort: ${GRAFANA_NODEPORT}
  resources:
    requests:
      cpu: 80m
      memory: 128Mi
    limits:
      cpu: 300m
      memory: 256Mi
  # Pre-load useful dashboards from Grafana.com
  dashboardProviders:
    dashboardproviders.yaml:
      apiVersion: 1
      providers:
        - name: default
          orgId: 1
          folder: "Kubernetes"
          type: file
          disableDeletion: false
          editable: true
          options:
            path: /var/lib/grafana/dashboards/default
  dashboards:
    default:
      kubernetes-cluster-overview:
        gnetId: 7249
        revision: 1
        datasource: Prometheus
      node-exporter-full:
        gnetId: 1860
        revision: 37
        datasource: Prometheus
      kubernetes-pods:
        gnetId: 6781
        revision: 1
        datasource: Prometheus
  grafana.ini:
    server:
      root_url: "http://${NODE_IP}:${GRAFANA_NODEPORT}"
    analytics:
      check_for_updates: false
    log:
      mode: console
      level: warn

# ── Alertmanager ──────────────────────────────────────────────────────────────
alertmanager:
  alertmanagerSpec:
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: ${STORAGE_CLASS_NAME}
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: ${ALERTMANAGER_PVC}
    resources:
      requests:
        cpu: 30m
        memory: 64Mi
      limits:
        cpu: 100m
        memory: 128Mi
  service:
    type: NodePort
    nodePort: ${ALERTMANAGER_NODEPORT}

# ── Node Exporter ─────────────────────────────────────────────────────────────
# DaemonSet — must tolerate master taint to collect master host metrics
nodeExporter:
  enabled: true
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
    - key: node-role.kubernetes.io/master
      operator: Exists
      effect: NoSchedule

# ── kube-state-metrics ────────────────────────────────────────────────────────
kubeStateMetrics:
  enabled: true

# ── Prometheus Operator ───────────────────────────────────────────────────────
prometheusOperator:
  resources:
    requests:
      cpu: 80m
      memory: 128Mi
    limits:
      cpu: 200m
      memory: 256Mi
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
    - key: node-role.kubernetes.io/master
      operator: Exists
      effect: NoSchedule

# ── Control-plane component scraping ─────────────────────────────────────────
# Pass master IP explicitly — auto-discovery fails on manual kubeadm clusters
kubeEtcd:
  enabled: true
  endpoints: ${CP_ENDPOINTS}

kubeScheduler:
  enabled: true
  endpoints: ${CP_ENDPOINTS}

kubeControllerManager:
  enabled: true
  endpoints: ${CP_ENDPOINTS}

# kube-proxy metrics port is not open on this cluster
kubeProxy:
  enabled: false
YAML

log_info "Values written to $VALUES_FILE ✔"

# ═══════════════════════════════════════════════════════════════════════════════
log_section "STEP 8: Create namespace"
# ═══════════════════════════════════════════════════════════════════════════════

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
log_info "Namespace '$NAMESPACE' ready ✔"

# ═══════════════════════════════════════════════════════════════════════════════
log_section "STEP 9: Helm deploy"
# ═══════════════════════════════════════════════════════════════════════════════
# --wait=false : Helm applies manifests and returns immediately.
#                Pods start pulling images in the background.
#                No timeout possible, no silent rollback.
# No --atomic  : --atomic deletes everything if any pod isn't Ready in time.
#                On a slow EC2 internet connection this causes total data loss.
# We manage the wait ourselves in Step 10 with full visibility.

log_info "Chart   : $HELM_CHART"
log_info "Version : $HELM_CHART_VERSION"
log_info "Applying manifests now (pods will pull images in background)..."

helm upgrade --install "$HELM_RELEASE" "$HELM_CHART" \
  --namespace "$NAMESPACE" \
  --version "$HELM_CHART_VERSION" \
  --values "$VALUES_FILE" \
  --wait=false

log_info "Manifests applied ✔. Pods are now starting..."

# ═══════════════════════════════════════════════════════════════════════════════
log_section "STEP 10: Wait for pods"
# ═══════════════════════════════════════════════════════════════════════════════
# Prints full pod table every 15s.
# Prints Warning events every 60s so you see image pull errors immediately.
# Does NOT hard-fail on timeout — shows diagnostics instead.

START_TIME=$(date +%s)
LAST_DIAG=0

while true; do
  ELAPSED=$(( $(date +%s) - START_TIME ))

  TOTAL=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
    | grep -c "." || true)
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

  # Diagnostics every 60s
  if (( ELAPSED - LAST_DIAG >= 60 )); then
    LAST_DIAG=$ELAPSED

    # Warning events
    WARN=$(kubectl get events -n "$NAMESPACE" \
      --field-selector type=Warning --sort-by='.lastTimestamp' 2>/dev/null \
      | tail -6 || true)
    if [[ -n "$WARN" ]]; then
      echo -e "\n  ${YELLOW}Warning events:${NC}"
      echo "$WARN" | sed 's/^/    /'
    fi

    # PVC status
    PVC_PENDING=$(kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null \
      | grep -v " Bound " | awk '{print $1}' || true)
    if [[ -n "$PVC_PENDING" ]]; then
      echo -e "\n  ${YELLOW}PVCs not yet Bound:${NC}"
      echo "$PVC_PENDING" | sed 's/^/    /'
      echo ""
      log_warn "Run: kubectl describe pvc <name> -n $NAMESPACE"
    fi

    # ImagePullBackOff
    IMG_FAIL=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
      | grep -E "ImagePullBackOff|ErrImagePull" | awk '{print $1}' || true)
    if [[ -n "$IMG_FAIL" ]]; then
      echo -e "\n  ${RED}Image pull failures:${NC}"
      echo "$IMG_FAIL" | sed 's/^/    /'
      log_warn "Check outbound internet access from the worker node:"
      log_warn "  ssh ubuntu@${NODE_IP} 'curl -s https://registry-1.docker.io' "
    fi
  fi

  if [[ "$ELAPSED" -gt "$WAIT_TIMEOUT" ]]; then
    echo ""
    log_warn "Timeout after ${WAIT_TIMEOUT}s — pods may still be pulling images."
    log_warn "Keep watching: watch -n10 'kubectl get pods -n $NAMESPACE'"
    log_warn "For any stuck pod: kubectl describe pod <name> -n $NAMESPACE"
    break
  fi

  sleep 15
done

# ═══════════════════════════════════════════════════════════════════════════════
log_section "STEP 11: Final state"
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
log_info "Pods:"
kubectl get pods -n "$NAMESPACE" -o wide
echo ""
log_info "Services:"
kubectl get svc -n "$NAMESPACE"
echo ""
log_info "PVCs:"
kubectl get pvc -n "$NAMESPACE"

# ═══════════════════════════════════════════════════════════════════════════════
log_section "ACCESS INFORMATION"
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}${BOLD}  GRAFANA${NC}"
echo -e "  URL      →  http://${NODE_IP}:${GRAFANA_NODEPORT}"
echo -e "  Username →  admin"
echo -e "  Password →  ${GRAFANA_ADMIN_PASSWORD}"
echo ""
echo -e "${GREEN}${BOLD}  PROMETHEUS${NC}"
echo -e "  URL      →  http://${NODE_IP}:${PROMETHEUS_NODEPORT}"
echo ""
echo -e "${GREEN}${BOLD}  ALERTMANAGER${NC}"
echo -e "  URL      →  http://${NODE_IP}:${ALERTMANAGER_NODEPORT}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${YELLOW}${BOLD}  AWS Security Group — required for browser access:${NC}"
echo -e "  Worker node (ip-172-31-40-9) security group → add inbound:"
echo -e "    TCP ${GRAFANA_NODEPORT}   from your laptop IP"
echo -e "    TCP ${PROMETHEUS_NODEPORT}   from your laptop IP"
echo -e "    TCP ${ALERTMANAGER_NODEPORT}   from your laptop IP"
echo ""
echo -e "${YELLOW}${BOLD}  No port changes? Use SSH tunnel instead:${NC}"
echo -e "  ssh -L ${GRAFANA_NODEPORT}:${NODE_IP}:${GRAFANA_NODEPORT} ubuntu@<master-public-ip>"
echo -e "  Then open http://localhost:${GRAFANA_NODEPORT} in your browser"
echo ""
echo -e "${BOLD}  Pre-loaded Grafana dashboards:${NC}"
echo -e "    ID 7249  — Kubernetes Cluster Overview"
echo -e "    ID 1860  — Node Exporter (CPU / memory / disk / network per host)"
echo -e "    ID 6781  — Kubernetes Pod Monitoring"
echo ""
echo -e "${BOLD}  Useful commands:${NC}"
echo -e "    kubectl get pods  -n ${NAMESPACE}            # health"
echo -e "    kubectl get pvc   -n ${NAMESPACE}            # storage"
echo -e "    kubectl get events -n ${NAMESPACE} --sort-by='.lastTimestamp'"
echo -e "    helm status ${HELM_RELEASE} -n ${NAMESPACE}"
echo -e "    ./deploy-monitoring.sh --uninstall"
echo ""
echo -e "${RED}${BOLD}  Known constraints on THIS cluster:${NC}"
echo -e "  • Grafana has NO persistent storage (6.8G worker disk is too small)."
echo -e "    Dashboard layouts reset on pod restart. Dashboards from ConfigMaps survive."
echo -e "  • Prometheus retains 7 days of metrics (2Gi PVC on 6.8G disk)."
echo -e "  • To get more storage: attach an EBS volume to the worker, mount it,"
echo -e "    and set LOCAL_PATH_DIR in the provisioner ConfigMap to that mount path."
echo ""
