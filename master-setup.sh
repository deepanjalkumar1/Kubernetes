#!/usr/bin/env bash
# =============================================================================
# Kubernetes MASTER NODE Setup Script
# Tested on: Ubuntu 20.04 / 22.04
# K8s version: 1.29 | CRI: containerd | CNI: Calico
# =============================================================================
set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

LOG_FILE="/var/log/k8s-master-setup.log"
K8S_VERSION="1.29"
POD_CIDR="192.168.0.0/16"        # Calico default — do NOT overlap with your VPC CIDR
CALICO_VERSION="v3.27.3"
JOIN_CMD_FILE="/root/k8s-join-command.sh"

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

# =============================================================================
# SECTION 0 — Pre-flight checks
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
[[ "$CPU_COUNT" -ge 2 ]] || fail "Kubernetes master needs at least 2 CPUs. Found: $CPU_COUNT"
[[ "$MEM_KB" -ge 1900000 ]] || fail "Kubernetes master needs at least 2 GB RAM. Found: ${MEM_GB}GB"
log "Resources: ${CPU_COUNT} CPUs, ${MEM_GB}GB RAM — OK"

# Unique hostname
HOSTNAME=$(hostname)
[[ -n "$HOSTNAME" ]] || fail "Hostname is empty. Set it with: sudo hostnamectl set-hostname master-node"
log "Hostname: $HOSTNAME"

# Detect primary IP (works on AWS, GCP, bare-metal)
# On AWS, always use the private IP (not the public one)
ADVERTISE_IP=""
if curl -sf --connect-timeout 2 http://169.254.169.254/latest/meta-data/local-ipv4 &>/dev/null; then
  ADVERTISE_IP=$(curl -sf http://169.254.169.254/latest/meta-data/local-ipv4)
  info "Detected AWS environment. Using private IP: $ADVERTISE_IP"
else
  ADVERTISE_IP=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
  info "Using detected IP: $ADVERTISE_IP"
fi
[[ -n "$ADVERTISE_IP" ]] || fail "Could not determine node IP address."

# Check POD_CIDR does NOT overlap with node IP
NODE_SUBNET=$(echo "$ADVERTISE_IP" | cut -d. -f1-2)
POD_SUBNET=$(echo "$POD_CIDR" | cut -d. -f1-2)
[[ "$NODE_SUBNET" == "$POD_SUBNET" ]] \
  && fail "POD_CIDR ($POD_CIDR) overlaps with your node subnet ($ADVERTISE_IP). Edit POD_CIDR in this script."
log "Pod CIDR ($POD_CIDR) does not overlap with node IP — OK"

# Port availability (critical ports for master)
REQUIRED_PORTS=(6443 2379 2380 10250 10251 10252)
for port in "${REQUIRED_PORTS[@]}"; do
  if ss -tlnp | grep -q ":${port} "; then
    warn "Port $port is already in use — this may cause kubeadm init to fail"
  fi
done
log "Port pre-check complete"

# =============================================================================
# SECTION 1 — System Preparation
# =============================================================================
section "SECTION 1: System Preparation"

info "Updating apt packages..."
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
  apt-transport-https ca-certificates curl gpg \
  socat conntrack ipset jq bc
log "Dependencies installed"

# Disable swap — Kubernetes WILL fail if swap is on
info "Disabling swap..."
swapoff -a
# Remove any swap entries from fstab (comments them out)
sed -i.bak '/\bswap\b/s/^/#/' /etc/fstab
# Double-check
if swapon --show | grep -q .; then
  fail "Swap is still active after swapoff. Check /etc/fstab manually."
fi
log "Swap disabled (persistent across reboots)"

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

# Verify modules loaded
lsmod | grep -q overlay    || fail "overlay module failed to load"
lsmod | grep -q br_netfilter || fail "br_netfilter module failed to load"
log "Kernel modules loaded: overlay, br_netfilter"

info "Setting sysctl networking parameters..."
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system -q
# Verify key settings
[[ "$(sysctl -n net.ipv4.ip_forward)" == "1" ]] || fail "ip_forward not set to 1"
log "Sysctl parameters applied"

# =============================================================================
# SECTION 3 — Install containerd
# =============================================================================
section "SECTION 3: Container Runtime (containerd)"

info "Installing containerd..."
apt-get install -y -qq containerd
log "containerd installed"

info "Generating containerd default config..."
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml

# CRITICAL: Set SystemdCgroup = true
# Without this, kubelet and containerd use different cgroup drivers and the node will fail
if grep -q "SystemdCgroup = false" /etc/containerd/config.toml; then
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  log "Set SystemdCgroup = true in containerd config"
else
  warn "SystemdCgroup entry not found where expected — verifying manually..."
  grep -i "SystemdCgroup" /etc/containerd/config.toml || true
fi

# Fix the sandbox (pause) image to match what k8s 1.29 expects
# Mismatched pause image = containers stuck in ContainerCreating
PAUSE_IMAGE="registry.k8s.io/pause:3.9"
sed -i "s|sandbox_image = .*|sandbox_image = \"${PAUSE_IMAGE}\"|" /etc/containerd/config.toml
log "Set sandbox_image to $PAUSE_IMAGE"

# Verify the config changes
grep "SystemdCgroup" /etc/containerd/config.toml | grep -q "true" \
  || fail "SystemdCgroup is NOT true in containerd config — check /etc/containerd/config.toml"
grep "sandbox_image" /etc/containerd/config.toml | grep -q "pause:3.9" \
  || fail "sandbox_image not set correctly — check /etc/containerd/config.toml"

systemctl restart containerd
systemctl enable containerd
sleep 3

systemctl is-active --quiet containerd || fail "containerd failed to start. Run: journalctl -xeu containerd"
log "containerd is running and enabled"

# Configure crictl to use containerd (prevents annoying warnings)
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

# Remove old key/repo if exists to avoid conflicts
rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
rm -f /etc/apt/sources.list.d/kubernetes.list

curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

apt-get update -qq
apt-get install -y -qq kubelet kubeadm kubectl

# Pin versions so apt upgrade doesn't break your cluster
apt-mark hold kubelet kubeadm kubectl
log "kubelet, kubeadm, kubectl installed and held at version 1.${K8S_VERSION}.x"

# Enable kubelet service (don't start yet — kubeadm init will start it)
systemctl enable kubelet
log "kubelet enabled (will start after kubeadm init)"

# =============================================================================
# SECTION 5 — Initialize the Cluster
# =============================================================================
section "SECTION 5: kubeadm init (Cluster Initialization)"

info "Running kubeadm init — this takes 2-4 minutes..."
info "  Advertise IP : $ADVERTISE_IP"
info "  Pod CIDR     : $POD_CIDR"

# Run kubeadm init and save full output for debugging
KUBEADM_OUTPUT=$(kubeadm init \
  --apiserver-advertise-address="$ADVERTISE_IP" \
  --pod-network-cidr="$POD_CIDR" \
  2>&1) || {
    echo "$KUBEADM_OUTPUT"
    fail "kubeadm init failed. See above output and $LOG_FILE"
  }

echo "$KUBEADM_OUTPUT"
log "kubeadm init completed"

# =============================================================================
# SECTION 6 — Configure kubectl
# =============================================================================
section "SECTION 6: kubectl Configuration"

# For root
mkdir -p /root/.kube
cp -f /etc/kubernetes/admin.conf /root/.kube/config
chown root:root /root/.kube/config
log "kubectl configured for root user"

# Also configure for the sudo user who invoked this script (if not root)
SUDO_USER_HOME=""
if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
  SUDO_USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
  mkdir -p "$SUDO_USER_HOME/.kube"
  cp -f /etc/kubernetes/admin.conf "$SUDO_USER_HOME/.kube/config"
  chown -R "$SUDO_USER:$SUDO_USER" "$SUDO_USER_HOME/.kube"
  log "kubectl configured for user: $SUDO_USER"
fi

# Verify kubectl works
sleep 5
kubectl get nodes &>/dev/null || fail "kubectl cannot connect to API server after init"
log "kubectl is working"

# =============================================================================
# SECTION 7 — Install Calico CNI
# =============================================================================
section "SECTION 7: Calico CNI (Pod Networking)"

# Wait for API server to be ready
info "Waiting for API server to be ready..."
for i in $(seq 1 20); do
  kubectl get nodes &>/dev/null && break
  sleep 5
  info "  Attempt $i/20..."
done
kubectl get nodes &>/dev/null || fail "API server not ready after 100 seconds"

info "Applying Calico CNI manifests..."
CALICO_URL="https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"

# Download first so we can verify
curl -fsSL "$CALICO_URL" -o /tmp/calico.yaml \
  || fail "Could not download Calico manifest from $CALICO_URL"

kubectl apply -f /tmp/calico.yaml \
  || fail "kubectl apply for Calico failed"
log "Calico CNI applied"

# =============================================================================
# SECTION 8 — Wait for Master Node Ready
# =============================================================================
section "SECTION 8: Waiting for Master Node to Become Ready"

info "Waiting for master node to reach Ready state (can take 3-5 minutes)..."
for i in $(seq 1 36); do
  STATUS=$(kubectl get node "$HOSTNAME" -o jsonpath='{.status.conditions[-1:].type}={.status.conditions[-1:].status}' 2>/dev/null || echo "unknown")
  if [[ "$STATUS" == "Ready=True" ]]; then
    log "Master node is Ready!"
    break
  fi
  if [[ "$i" -eq 36 ]]; then
    warn "Master node did not reach Ready state in 3 minutes."
    warn "Check: kubectl get pods -n kube-system"
    warn "Check: kubectl describe node $HOSTNAME"
  fi
  echo -n "  [$i/36] Status: $STATUS — waiting 5s..."$'\r'
  sleep 5
done
echo ""

# =============================================================================
# SECTION 9 — Generate Worker Join Command
# =============================================================================
section "SECTION 9: Generating Worker Node Join Command"

info "Generating join command..."
JOIN_CMD=$(kubeadm token create --print-join-command 2>/dev/null)
[[ -n "$JOIN_CMD" ]] || fail "Failed to generate join command"

# Save to file
cat > "$JOIN_CMD_FILE" <<EOF
#!/usr/bin/env bash
# Generated on $(date)
# Run this on your WORKER node(s) with: sudo bash k8s-join-command.sh
# NOTE: Token expires in 24 hours. Regenerate with:
#   sudo kubeadm token create --print-join-command
sudo $JOIN_CMD
EOF
chmod 600 "$JOIN_CMD_FILE"

log "Join command saved to: $JOIN_CMD_FILE"

# =============================================================================
# SECTION 10 — Final Status & Summary
# =============================================================================
section "SECTION 10: Final Status"

echo ""
kubectl get nodes -o wide
echo ""
kubectl get pods -n kube-system
echo ""

echo -e "${BOLD}${GREEN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           MASTER NODE SETUP COMPLETE ✔                      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "${BOLD}Master IP    :${NC} $ADVERTISE_IP"
echo -e "${BOLD}Log file     :${NC} $LOG_FILE"
echo -e "${BOLD}kubeconfig   :${NC} /root/.kube/config"
[[ -n "$SUDO_USER_HOME" ]] && echo -e "${BOLD}             :${NC} $SUDO_USER_HOME/.kube/config"
echo ""
echo -e "${BOLD}${YELLOW}══ NEXT STEP: Copy & run this on your WORKER node ══${NC}"
echo ""
echo -e "${CYAN}  sudo $JOIN_CMD${NC}"
echo ""
echo -e "${BOLD}Join command also saved to:${NC} $JOIN_CMD_FILE"
echo -e "${YELLOW}⚠  Token expires in 24 hours. To regenerate:${NC}"
echo "   sudo kubeadm token create --print-join-command"
echo ""
echo -e "${BOLD}Useful commands:${NC}"
echo "  kubectl get nodes -o wide"
echo "  kubectl get pods -n kube-system"
echo "  kubectl cluster-info"
echo ""
