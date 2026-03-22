#!/usr/bin/env bash
# =============================================================================
#  deploy-monitoring.sh
#  Automated Prometheus + Grafana setup on manually-deployed K8s on AWS
#  (kubeadm-style: 1 master + 1 worker, NO EKS, NO cloud controller manager)
#
#  What this script does:
#   1. Pre-flight checks (kubectl, helm, cluster access, node count, taints)
#   2. Creates a dedicated 'monitoring' namespace
#   3. Sets up a local-path StorageClass (if none exists) for persistent volumes
#   4. Deploys kube-prometheus-stack via Helm (Prometheus + Grafana + Alertmanager
#      + node-exporter + kube-state-metrics)
#   5. Exposes Grafana and Prometheus via NodePort (safe for manual K8s, no AWS LB needed)
#   6. Waits for all pods to be ready
#   7. Prints access instructions with real IP and ports
#
#  REQUIREMENTS (must exist on the machine you run this from):
#   - kubectl  (configured and pointing to YOUR cluster via kubeconfig)
#   - helm     (v3.x)
#   - curl     (for health checks)
#   - bash 4+
#
#  HOW TO RUN:
#   chmod +x deploy-monitoring.sh
#   ./deploy-monitoring.sh
#
#  TO UNINSTALL EVERYTHING:
#   ./deploy-monitoring.sh --uninstall
# =============================================================================

set -euo pipefail

# ─── CONFIGURATION (edit these if needed) ─────────────────────────────────────
NAMESPACE="monitoring"
HELM_RELEASE="kube-prom-stack"
HELM_CHART="prometheus-community/kube-prometheus-stack"
HELM_CHART_VERSION="58.2.2"          # Pinned — do not use 'latest' in production
GRAFANA_NODEPORT=32000               # Must be in range 30000-32767
PROMETHEUS_NODEPORT=32001
ALERTMANAGER_NODEPORT=32002
GRAFANA_ADMIN_PASSWORD="Admin@K8s2024!"  # CHANGE THIS before running in production
VALUES_FILE="./prometheus-grafana-values.yaml"
STORAGE_CLASS_MANIFEST="./local-path-storage.yaml"
WAIT_TIMEOUT=300   # seconds to wait for pods to be Ready
# ──────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_section() { echo -e "\n${BLUE}${BOLD}══════════════════════════════════════════${NC}"; \
                echo -e "${BLUE}${BOLD}  $*${NC}"; \
                echo -e "${BLUE}${BOLD}══════════════════════════════════════════${NC}"; }

# ─── UNINSTALL MODE ───────────────────────────────────────────────────────────
if [[ "${1:-}" == "--uninstall" ]]; then
  log_section "UNINSTALLING monitoring stack"
  helm uninstall "$HELM_RELEASE" -n "$NAMESPACE" 2>/dev/null && log_info "Helm release removed." || log_warn "Helm release not found."
  kubectl delete namespace "$NAMESPACE" --ignore-not-found=true
  kubectl delete storageclass local-path --ignore-not-found=true
  kubectl delete -f "$STORAGE_CLASS_MANIFEST" --ignore-not-found=true 2>/dev/null || true
  log_info "Uninstall complete."
  exit 0
fi

# ─── STEP 1: PRE-FLIGHT CHECKS ────────────────────────────────────────────────
log_section "STEP 1: Pre-flight checks"

## 1a. Check required binaries
MISSING_TOOLS=()
for tool in kubectl helm curl; do
  if ! command -v "$tool" &>/dev/null; then
    MISSING_TOOLS+=("$tool")
  fi
done

if [[ ${#MISSING_TOOLS[@]} -gt 0 ]]; then
  log_error "Missing required tools: ${MISSING_TOOLS[*]}"
  echo ""
  echo "  Install kubectl : https://kubernetes.io/docs/tasks/tools/"
  echo "  Install helm    : curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
  echo "  Install curl    : sudo apt-get install curl  (or yum install curl)"
  exit 1
fi
log_info "kubectl, helm, curl — all found."

## 1b. Check helm version is v3
HELM_VERSION=$(helm version --short 2>/dev/null | grep -oP 'v\K[0-9]+' | head -1)
if [[ "$HELM_VERSION" -lt 3 ]]; then
  log_error "Helm v3 required, found: $(helm version --short)"
  exit 1
fi
log_info "Helm v3 confirmed."

## 1c. Check kubectl can reach the cluster
log_info "Checking cluster connectivity..."
if ! kubectl cluster-info &>/dev/null; then
  log_error "kubectl cannot reach the cluster."
  echo ""
  echo "  Check that:"
  echo "  1. Your kubeconfig is correct:   echo \$KUBECONFIG  OR  cat ~/.kube/config"
  echo "  2. The master node is reachable (ping, security groups, VPN)"
  echo "  3. The API server is running:    sudo systemctl status kube-apiserver"
  exit 1
fi
log_info "Cluster is reachable."

## 1d. Check node count and print status
log_info "Cluster nodes:"
kubectl get nodes -o wide
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$NODE_COUNT" -lt 2 ]]; then
  log_warn "Only $NODE_COUNT node(s) detected. Expected at least 2 (1 master + 1 worker)."
  log_warn "Pods requiring untainted nodes might not schedule. Proceeding anyway..."
fi

## 1e. Detect master taint
MASTER_TAINT=$(kubectl get nodes -o jsonpath='{.items[*].spec.taints[*].key}' 2>/dev/null || true)
if echo "$MASTER_TAINT" | grep -q "node-role.kubernetes.io/control-plane\|node-role.kubernetes.io/master"; then
  log_info "Master taint detected (expected). Workloads will be scheduled on worker node(s)."
else
  log_warn "No control-plane taint found. This is unusual for kubeadm. Verify your cluster setup."
fi

## 1f. Check existing StorageClass
EXISTING_SC=$(kubectl get storageclass --no-headers 2>/dev/null | awk '{print $1}' | head -1)
if [[ -z "$EXISTING_SC" ]]; then
  log_warn "No StorageClass found. Will install 'local-path-provisioner' (Rancher) for persistent volumes."
  NEED_STORAGE_CLASS=true
else
  log_info "Existing StorageClass found: $EXISTING_SC. Will use it."
  NEED_STORAGE_CLASS=false
fi

## 1g. Check NodePort range isn't already in use
for PORT in $GRAFANA_NODEPORT $PROMETHEUS_NODEPORT $ALERTMANAGER_NODEPORT; do
  IN_USE=$(kubectl get svc -A --no-headers 2>/dev/null | awk '{print $6}' | grep -o "[0-9]*:${PORT}" | head -1 || true)
  if [[ -n "$IN_USE" ]]; then
    log_error "NodePort $PORT is already in use by another service. Edit the NodePort variables at the top of this script."
    exit 1
  fi
done
log_info "NodePorts $GRAFANA_NODEPORT, $PROMETHEUS_NODEPORT, $ALERTMANAGER_NODEPORT are available."

# ─── STEP 2: WORKER NODE IP ───────────────────────────────────────────────────
log_section "STEP 2: Detecting Worker Node IP"

# Get the external/internal IP of the first non-master node
WORKER_NODE=$(kubectl get nodes --no-headers \
  -l '!node-role.kubernetes.io/control-plane,!node-role.kubernetes.io/master' \
  2>/dev/null | awk 'NR==1{print $1}')

if [[ -z "$WORKER_NODE" ]]; then
  log_warn "No dedicated worker node found. Using master node (this is not recommended for production)."
  WORKER_NODE=$(kubectl get nodes --no-headers 2>/dev/null | awk 'NR==1{print $1}')
fi

# Try ExternalIP first, fall back to InternalIP
NODE_IP=$(kubectl get node "$WORKER_NODE" \
  -o jsonpath='{.status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null)

if [[ -z "$NODE_IP" ]]; then
  NODE_IP=$(kubectl get node "$WORKER_NODE" \
    -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
fi

if [[ -z "$NODE_IP" ]]; then
  log_error "Could not determine node IP. Set it manually: export NODE_IP=<your-worker-ip>"
  exit 1
fi

log_info "Worker node: $WORKER_NODE | IP: $NODE_IP"
log_warn "If accessing from outside AWS, ensure Security Group allows TCP $GRAFANA_NODEPORT, $PROMETHEUS_NODEPORT, $ALERTMANAGER_NODEPORT inbound."

# ─── STEP 3: INSTALL LOCAL-PATH STORAGE (if needed) ──────────────────────────
log_section "STEP 3: Storage Class"

if [[ "$NEED_STORAGE_CLASS" == true ]]; then
  log_info "Installing Rancher local-path-provisioner..."
  # This creates a StorageClass 'local-path' using the node's local disk.
  # Data is stored at /opt/local-path-provisioner on the node.
  # WARNING: This is NOT replicated. If the node dies, data is lost.
  # For production, use EBS CSI driver instead.
  cat > "$STORAGE_CLASS_MANIFEST" <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: local-path-storage
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: local-path-provisioner-service-account
  namespace: local-path-storage
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: local-path-provisioner-role
rules:
  - apiGroups: [""]
    resources: ["nodes", "persistentvolumeclaims", "configmaps", "pods", "pods/log"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["persistentvolumes"]
    verbs: ["get", "list", "watch", "create", "patch", "delete"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "patch"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: local-path-provisioner-bind
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: local-path-provisioner-role
subjects:
  - kind: ServiceAccount
    name: local-path-provisioner-service-account
    namespace: local-path-storage
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: local-path-provisioner
  namespace: local-path-storage
spec:
  replicas: 1
  selector:
    matchLabels:
      app: local-path-provisioner
  template:
    metadata:
      labels:
        app: local-path-provisioner
    spec:
      tolerations:
        - key: node-role.kubernetes.io/master
          operator: Exists
          effect: NoSchedule
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
      serviceAccountName: local-path-provisioner-service-account
      containers:
        - name: local-path-provisioner
          image: rancher/local-path-provisioner:v0.0.26
          imagePullPolicy: IfNotPresent
          command:
            - local-path-provisioner
            - --debug
            - start
            - --config
            - /etc/config/config.json
          volumeMounts:
            - name: config-volume
              mountPath: /etc/config/
          env:
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
      volumes:
        - name: config-volume
          configMap:
            name: local-path-config
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-path
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: rancher.io/local-path
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-path-config
  namespace: local-path-storage
data:
  config.json: |-
    {
      "nodePathMap": [
        {
          "node": "DEFAULT_PATH_FOR_NON_LISTED_NODES",
          "paths": ["/opt/local-path-provisioner"]
        }
      ]
    }
  setup: |-
    #!/bin/sh
    set -eu
    mkdir -m 0777 -p "$VOL_DIR"
  teardown: |-
    #!/bin/sh
    set -eu
    rm -rf "$VOL_DIR"
  helperPod.yaml: |-
    apiVersion: v1
    kind: Pod
    metadata:
      name: helper-pod
    spec:
      containers:
      - name: helper-pod
        image: busybox
        imagePullPolicy: IfNotPresent
YAML

  kubectl apply -f "$STORAGE_CLASS_MANIFEST"
  log_info "Waiting for local-path-provisioner to be ready..."
  kubectl rollout status deployment/local-path-provisioner -n local-path-storage --timeout=120s
  STORAGE_CLASS_NAME="local-path"
else
  STORAGE_CLASS_NAME="$EXISTING_SC"
fi

log_info "Using StorageClass: $STORAGE_CLASS_NAME"

# ─── STEP 4: ADD HELM REPO ────────────────────────────────────────────────────
log_section "STEP 4: Helm Repo Setup"

if helm repo list 2>/dev/null | grep -q "prometheus-community"; then
  log_info "prometheus-community repo already added."
else
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
  log_info "prometheus-community repo added."
fi
helm repo update
log_info "Helm repos updated."

# ─── STEP 5: GENERATE VALUES FILE ─────────────────────────────────────────────
log_section "STEP 5: Generating Helm values"

cat > "$VALUES_FILE" <<YAML
# =============================================================================
# kube-prometheus-stack Helm values
# Tuned for: manual K8s on AWS, 1 master + 1 worker, NodePort access
# =============================================================================

# ── Prometheus ──────────────────────────────────────────────────────────────
prometheus:
  prometheusSpec:
    # Retention: how long to keep metrics
    retention: 15d
    # Storage: persistent volume for metrics data
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: ${STORAGE_CLASS_NAME}
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 20Gi
    # Resource limits — sized for a small AWS instance (t3.medium equivalent)
    resources:
      requests:
        cpu: 200m
        memory: 512Mi
      limits:
        cpu: 1000m
        memory: 2Gi
    # Scrape interval
    scrapeInterval: "30s"
    evaluationInterval: "30s"
    # Ensure it doesn't land on the master
    tolerations: []
    nodeSelector: {}
  service:
    type: NodePort
    nodePort: ${PROMETHEUS_NODEPORT}

# ── Grafana ──────────────────────────────────────────────────────────────────
grafana:
  adminPassword: "${GRAFANA_ADMIN_PASSWORD}"
  persistence:
    enabled: true
    storageClassName: ${STORAGE_CLASS_NAME}
    size: 5Gi
    accessModes:
      - ReadWriteOnce
  service:
    type: NodePort
    nodePort: ${GRAFANA_NODEPORT}
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
  # Pre-load dashboards for K8s cluster monitoring
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
      # K8s cluster overview
      kubernetes-cluster:
        gnetId: 7249
        revision: 1
        datasource: Prometheus
      # Node exporter full
      node-exporter:
        gnetId: 1860
        revision: 37
        datasource: Prometheus
      # K8s pod monitoring
      k8s-pods:
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

# ── Alertmanager ─────────────────────────────────────────────────────────────
alertmanager:
  alertmanagerSpec:
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: ${STORAGE_CLASS_NAME}
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 2Gi
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 200m
        memory: 256Mi
  service:
    type: NodePort
    nodePort: ${ALERTMANAGER_NODEPORT}

# ── Node Exporter ─────────────────────────────────────────────────────────────
# Runs as DaemonSet on ALL nodes (including master) to collect host metrics
nodeExporter:
  enabled: true
  tolerations:
    - key: node-role.kubernetes.io/master
      operator: Exists
      effect: NoSchedule
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule

# ── kube-state-metrics ────────────────────────────────────────────────────────
# Exposes K8s object state as metrics (deployments, pods, etc.)
kubeStateMetrics:
  enabled: true

# ── Operator settings ─────────────────────────────────────────────────────────
prometheusOperator:
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 512Mi
  # Tolerations so the operator can run on either node
  tolerations:
    - key: node-role.kubernetes.io/master
      operator: Exists
      effect: NoSchedule
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule

# ── kubeEtcd / Scheduler / ControllerManager ─────────────────────────────────
# These scrape control-plane components. On manual kubeadm, these often need
# the correct endpoint. If metrics show as "down", see TROUBLESHOOTING section.
kubeEtcd:
  enabled: true
  endpoints: []   # leave empty — auto-discovered via pods

kubeScheduler:
  enabled: true
  endpoints: []

kubeControllerManager:
  enabled: true
  endpoints: []

# Disable proxy metrics unless you have kube-proxy metrics port open
kubeProxy:
  enabled: false
YAML

log_info "Values file written to: $VALUES_FILE"

# ─── STEP 6: CREATE NAMESPACE ─────────────────────────────────────────────────
log_section "STEP 6: Namespace"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
log_info "Namespace '$NAMESPACE' ready."

# ─── STEP 7: HELM INSTALL / UPGRADE ──────────────────────────────────────────
log_section "STEP 7: Deploying kube-prometheus-stack via Helm"

log_info "This may take 3-5 minutes for images to pull..."

helm upgrade --install "$HELM_RELEASE" "$HELM_CHART" \
  --namespace "$NAMESPACE" \
  --version "$HELM_CHART_VERSION" \
  --values "$VALUES_FILE" \
  --timeout 10m \
  --atomic \
  --cleanup-on-fail

log_info "Helm deployment complete."

# ─── STEP 8: WAIT FOR PODS ────────────────────────────────────────────────────
log_section "STEP 8: Waiting for all pods to be Ready"

echo ""
log_info "Watching pod status in namespace '$NAMESPACE'..."
START_TIME=$(date +%s)

while true; do
  NOT_READY=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
    | grep -v "Running\|Completed" | grep -c "." || true)
  TOTAL=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -c "." || true)
  ELAPSED=$(( $(date +%s) - START_TIME ))

  echo -ne "\r  Pods ready: $(( TOTAL - NOT_READY ))/$TOTAL  (${ELAPSED}s elapsed)"

  if [[ "$NOT_READY" -eq 0 && "$TOTAL" -gt 0 ]]; then
    echo ""
    log_info "All $TOTAL pods are Running."
    break
  fi

  if [[ "$ELAPSED" -gt "$WAIT_TIMEOUT" ]]; then
    echo ""
    log_warn "Timeout after ${WAIT_TIMEOUT}s. Some pods may still be starting."
    log_warn "Check status: kubectl get pods -n $NAMESPACE"
    log_warn "Check events: kubectl get events -n $NAMESPACE --sort-by='.lastTimestamp'"
    break
  fi

  sleep 5
done

echo ""
kubectl get pods -n "$NAMESPACE" -o wide

# ─── STEP 9: VERIFY NODEPORTS ARE EXPOSED ────────────────────────────────────
log_section "STEP 9: Service Verification"
kubectl get svc -n "$NAMESPACE"

# ─── STEP 10: ACCESS SUMMARY ─────────────────────────────────────────────────
log_section "DEPLOYMENT COMPLETE — ACCESS INFORMATION"

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}${BOLD}  GRAFANA${NC}"
echo -e "  URL:      http://${NODE_IP}:${GRAFANA_NODEPORT}"
echo -e "  Username: admin"
echo -e "  Password: ${GRAFANA_ADMIN_PASSWORD}"
echo ""
echo -e "${GREEN}${BOLD}  PROMETHEUS${NC}"
echo -e "  URL:      http://${NODE_IP}:${PROMETHEUS_NODEPORT}"
echo ""
echo -e "${GREEN}${BOLD}  ALERTMANAGER${NC}"
echo -e "  URL:      http://${NODE_IP}:${ALERTMANAGER_NODEPORT}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${YELLOW}${BOLD}  AWS SECURITY GROUP — CRITICAL:${NC}"
echo -e "  Add these INBOUND rules to your worker node's Security Group:"
echo -e "    TCP ${GRAFANA_NODEPORT}    from your IP (or 0.0.0.0/0 for testing only)"
echo -e "    TCP ${PROMETHEUS_NODEPORT}    from your IP"
echo -e "    TCP ${ALERTMANAGER_NODEPORT}    from your IP"
echo ""
echo -e "${YELLOW}${BOLD}  ALTERNATIVE (if you don't want to open ports):${NC}"
echo -e "  Use kubectl port-forward from your local machine:"
echo -e "    kubectl port-forward svc/${HELM_RELEASE}-grafana ${GRAFANA_NODEPORT}:80 -n ${NAMESPACE}"
echo ""
echo -e "${BOLD}  PRE-LOADED GRAFANA DASHBOARDS:${NC}"
echo -e "    - Kubernetes Cluster Overview  (Dashboard ID 7249)"
echo -e "    - Node Exporter Full           (Dashboard ID 1860)"
echo -e "    - Kubernetes Pod Monitoring    (Dashboard ID 6781)"
echo ""
echo -e "${BOLD}  USEFUL COMMANDS:${NC}"
echo -e "    kubectl get pods -n ${NAMESPACE}                       # pod health"
echo -e "    kubectl logs -n ${NAMESPACE} -l app=grafana            # grafana logs"
echo -e "    kubectl top nodes                                       # resource usage"
echo -e "    helm status ${HELM_RELEASE} -n ${NAMESPACE}           # helm status"
echo -e "    ./deploy-monitoring.sh --uninstall                      # remove everything"
echo ""
echo -e "${RED}${BOLD}  KNOWN LIMITATIONS (be aware):${NC}"
echo -e "    1. local-path storage is NOT replicated. Node failure = data loss."
echo -e "       For production: install AWS EBS CSI driver + use gp2/gp3 StorageClass."
echo -e "    2. No TLS/HTTPS. For production: add an ingress with cert-manager."
echo -e "    3. Control-plane metrics (etcd/scheduler) may show 'down' in Prometheus."
echo -e "       This is common on kubeadm — run ./fix-controlplane-metrics.sh to fix."
echo ""
