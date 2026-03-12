#!/usr/bin/env bash
# =============================================================================
# Kubernetes WORKER NODE Setup Script
# Tested on: Ubuntu 20.04 / 22.04
# K8s version: 1.29 | CRI: containerd
# =============================================================================
# USAGE:
#   1. Run this script on the worker node
#   2. When prompted, paste the join command from the master node
#      (or pass it as an argument): sudo bash worker-setup.sh "<join-command>"
#   3. To get the join command from master: sudo kubeadm token create --print-join-command
# =============================================================================
set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

LOG_FILE="/var/log/k8s-worker-setup.log"
K8S_VERSION="1.29"

# ── Logging ───────────────────────────────────────────────────────────────────
exec > >(tee -a "$LOG_FILE") 2>&1

log()  { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✔  $*${NC}"; }
info() { echo -e "${CYAN}[$(date '+%H:%M:%S')] ℹ  $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠  $*${NC}"; }
fail() { echo -e "${RED}[$(date '+%H:%M:%S')] ✘  $*${NC}"; exit 1; }
section() { echo -e "\n${BOLD}${BLUE}══════════════════════════════════════${NC}"; \
            echo -e "${BOLD}${BLUE}  $*${NC}"; \
            echo -e "${BOLD}${BLUE}══════════════════════════════════════${NC}\n"; }

# ── Error trap ────────────────────────────────────────────────────────────────
trap 'fail "Script failed at line $LINENO. Check $LOG_FILE for details."' ERR

# ── Get Join Command ──────────────────────────────────────────────────────────
JOIN_CMD="${1:-}"

if [[ -z "$JOIN_CMD" ]]; then
  echo -e "${YELLOW}"
  echo "══════════════════════════════════════════════════════════"
  echo "  Paste your kubeadm join command from the MASTER node."
  echo "  It looks like:"
  echo "  kubeadm join <IP>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>"
  echo ""
  echo "  To get it, run on master: sudo kubeadm token create --print-join-command"
  echo "══════════════════════════════════════════════════════════"
  echo -e "${NC}"
  read -rp "Paste join command here: " JOIN_CMD
fi

[[ -z "$JOIN_CMD" ]] && fail "No join command provided. Cannot continue."

# Basic sanity check on join command format
echo "$JOIN_CMD" | grep -qE "kubeadm join .+ --token .+ --discovery-token-ca-cert-hash sha256:" \
  || fail "Join command format looks wrong. Expected: kubeadm join <IP>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>"

# Extract master IP and port from join command for connectivity check
MASTER_ENDPOINT=$(echo "$JOIN_CMD" | grep -oP '(?<=join )[^ ]+')
MASTER_IP=$(echo "$MASTER_ENDPOINT" | cut -d: -f1)
MASTER_PORT=$(echo "$MASTER_ENDPOINT" | cut -d: -f2)

# =============================================================================
# SECTION 0 — Pre-flight Checks
# =============================================================================
section "SECTION 0: Pre-flight Checks"

# Must run as root
[[ "$EUID" -eq 0 ]] || fail "Run this script as root: sudo bash $0"

# OS check
. /etc/os-release
[[ "$ID" == "ubuntu" ]] || fail "This script supports Ubuntu only. Detected: $ID"
[[ "$VERSION_ID" == "20.04" || "$VERSION_ID" == "22.04" ]] \
  || warn "Tested on Ubuntu 20.04/22.04. You're on $VERSION_ID — proceed with caution."
log "OS: Ubuntu $VERSION_ID"

# CPU / RAM
CPU_COUNT=$(nproc)
MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
MEM_GB=$(echo "scale=1; $MEM_KB/1048576" | bc)
[[ "$CPU_COUNT" -ge 1 ]] || fail "Need at least 1 CPU. Found: $CPU_COUNT"
[[ "$MEM_KB" -ge 900000 ]] || warn "Low memory (${MEM_GB}GB). Kubernetes worker recommends 2GB+"
log "Resources: ${CPU_COUNT} CPUs, ${MEM_GB}GB RAM"

# Unique hostname
HOSTNAME=$(hostname)
[[ -n "$HOSTNAME" ]] || fail "Hostname is empty. Set it: sudo hostnamectl set-hostname worker-node"
log "Hostname: $HOSTNAME"

# CRITICAL: Worker hostname must differ from master
# (Kubernetes uses hostname as node name — duplicates cause silent failures)
warn "Make sure this worker's hostname ($HOSTNAME) is DIFFERENT from the master's hostname."
warn "If not, run: sudo hostnamectl set-hostname worker-node   (and restart this script)"
sleep 3

# Detect worker node IP
if curl -sf --connect-timeout 2 http://169.254.169.254/latest/meta-data/local-ipv4 &>/dev/null; then
  WORKER_IP=$(curl -sf http://169.254.169.254/latest/meta-data/local-ipv4)
  info "Detected AWS environment. Worker IP: $WORKER_IP"
else
  WORKER_IP=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
  info "Worker IP: $WORKER_IP"
fi
[[ -n "$WORKER_IP" ]] || fail "Could not determine worker node IP address."

# Test connectivity to master
info "Testing connectivity to master ($MASTER_IP:$MASTER_PORT)..."
if ! nc -z -w 5 "$MASTER_IP" "$MASTER_PORT" 2>/dev/null; then
  fail "Cannot reach master at $MASTER_IP:$MASTER_PORT. Check:
  1. Master is running and kubeadm init completed
  2. Security group / firewall allows port $MASTER_PORT from this worker ($WORKER_IP)
  3. Both nodes are in the same network / VPC"
fi
log "Master reachable at $MASTER_IP:$MASTER_PORT"

# Port 10250 must be free on worker (kubelet)
if ss -tlnp | grep -q ":10250 "; then
  warn "Port 10250 is already in use on this worker — may cause kubelet failure"
fi
log "Port pre-check complete"

# Check if this node was already joined to a cluster
if [[ -f /etc/kubernetes/kubelet.conf ]]; then
  warn "/etc/kubernetes/kubelet.conf exists — this node may already be joined to a cluster."
  warn "If you want to re-join, run: sudo kubeadm reset -f && sudo rm -rf /etc/cni/net.d"
  read -rp "Continue anyway? (y/N): " CONFIRM
  [[ "$CONFIRM" =~ ^[Yy]$ ]] || fail "Aborted by user."
fi

# =============================================================================
# SECTION 1 — System Preparation
# =============================================================================
section "SECTION 1: System Preparation"

info "Updating apt packages..."
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
  apt-transport-https ca-certificates curl gpg \
  socat conntrack ipset jq bc netcat-openbsd
log "Dependencies installed"

# Disable swap
info "Disabling swap..."
swapoff -a
sed -i.bak '/\bswap\b/s/^/#/' /etc/fstab

if swapon --show | grep -q .; then
  fail "Swap still active after swapoff. Check /etc/fstab manually."
fi
log "Swap disabled (persistent)"

# =============================================================================
# SECTION 2 — Kernel Modules & Networking
# =============================================================================
section "SECTION 2: Kernel Modules & Networking"

info "Loading required kernel modules..."
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

lsmod | grep -q overlay      || fail "overlay module failed to load"
lsmod | grep -q br_netfilter || fail "br_netfilter module failed to load"
log "Kernel modules loaded"

info "Setting sysctl networking parameters..."
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system -q
[[ "$(sysctl -n net.ipv4.ip_forward)" == "1" ]] || fail "ip_forward not set to 1"
log "Sysctl parameters applied"

# =============================================================================
# SECTION 3 — Install containerd
# =============================================================================
section "SECTION 3: Container Runtime (containerd)"

info "Installing containerd..."
apt-get install -y -qq containerd
log "containerd installed"

info "Configuring containerd..."
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml

# CRITICAL: SystemdCgroup must be true — same as master
if grep -q "SystemdCgroup = false" /etc/containerd/config.toml; then
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  log "Set SystemdCgroup = true"
else
  warn "SystemdCgroup entry not found at expected location"
  grep -i "SystemdCgroup" /etc/containerd/config.toml || true
fi

# Match the same pause image version as master (MUST be consistent)
PAUSE_IMAGE="registry.k8s.io/pause:3.9"
sed -i "s|sandbox_image = .*|sandbox_image = \"${PAUSE_IMAGE}\"|" /etc/containerd/config.toml
log "Set sandbox_image to $PAUSE_IMAGE"

# Verify
grep "SystemdCgroup" /etc/containerd/config.toml | grep -q "true" \
  || fail "SystemdCgroup is NOT true in containerd config"
grep "sandbox_image" /etc/containerd/config.toml | grep -q "pause:3.9" \
  || fail "sandbox_image not set correctly"

systemctl restart containerd
systemctl enable containerd
sleep 3

systemctl is-active --quiet containerd || fail "containerd failed to start. Run: journalctl -xeu containerd"
log "containerd is running and enabled"

# Configure crictl
cat > /etc/crictl.yaml <<EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF
log "crictl configured"

# =============================================================================
# SECTION 4 — Install Kubernetes Binaries
# =============================================================================
section "SECTION 4: Kubernetes Binaries (kubeadm, kubelet, kubectl)"

info "Adding Kubernetes apt repository..."
mkdir -p /etc/apt/keyrings

rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
rm -f /etc/apt/sources.list.d/kubernetes.list

curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

apt-get update -qq
apt-get install -y -qq kubelet kubeadm kubectl

# MUST match master's version — version skew > 1 minor version is unsupported
apt-mark hold kubelet kubeadm kubectl
log "kubelet, kubeadm, kubectl installed and held"

systemctl enable kubelet
log "kubelet enabled"

# =============================================================================
# SECTION 5 — Join the Cluster
# =============================================================================
section "SECTION 5: Joining the Cluster"

info "Running: $JOIN_CMD"
echo ""

# Run the join command
eval "sudo $JOIN_CMD" || {
  fail "kubeadm join failed. Common reasons:
  1. Token expired (default TTL: 24h) — regenerate on master
  2. Wrong discovery-token-ca-cert-hash
  3. Master API server not reachable
  4. This node already joined — run: sudo kubeadm reset -f"
}

log "kubeadm join succeeded"

# =============================================================================
# SECTION 6 — Post-join Verification
# =============================================================================
section "SECTION 6: Post-join Verification"

info "Verifying kubelet is running..."
sleep 5

systemctl is-active --quiet kubelet || {
  warn "kubelet not active yet. Checking status..."
  systemctl status kubelet --no-pager | tail -20
  warn "kubelet may still be starting. Wait 30 seconds and check: systemctl status kubelet"
}
log "kubelet is active"

# =============================================================================
# SECTION 7 — Final Summary
# =============================================================================
section "SECTION 7: Complete"

echo -e "${BOLD}${GREEN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           WORKER NODE SETUP COMPLETE ✔                      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "${BOLD}Worker Hostname :${NC} $HOSTNAME"
echo -e "${BOLD}Worker IP       :${NC} $WORKER_IP"
echo -e "${BOLD}Master endpoint :${NC} $MASTER_IP:$MASTER_PORT"
echo -e "${BOLD}Log file        :${NC} $LOG_FILE"
echo ""
echo -e "${BOLD}${YELLOW}══ VERIFY from your MASTER node ══${NC}"
echo ""
echo "  kubectl get nodes -o wide"
echo ""
echo -e "${YELLOW}Note: Node may show 'NotReady' for 1-2 minutes while Calico CNI initialises.${NC}"
echo ""
echo -e "${BOLD}Troubleshooting (run on this worker):${NC}"
echo "  systemctl status kubelet"
echo "  journalctl -xeu kubelet --no-pager | tail -50"
echo "  sudo crictl ps -a"
echo ""
