#!/bin/bash
set -euo pipefail

# Non-interactive mode for all installations
export DEBIAN_FRONTEND=noninteractive
export NONINTERACTIVE=1

# ===== Ensure sudo credentials are cached =====
if [[ $EUID -ne 0 ]]; then
   echo ""
   echo "╔════════════════════════════════════════════════════════════╗"
   echo "║  This script requires elevated privileges (sudo)           ║"
   echo "║  Please enter your password when prompted below            ║"
   echo "║  The script will pause until you provide your password     ║"
   echo "╚════════════════════════════════════════════════════════════╝"
   echo ""
   sudo -k
   sudo -v || { echo "Failed to obtain sudo privileges."; exit 1; }
   # Keep sudo credentials fresh for long-running installations
   while true; do sudo -n -v 2>/dev/null; sleep 50; done &
   SUDO_KEEPALIVE_PID=$!
   trap 'kill $SUDO_KEEPALIVE_PID 2>/dev/null' EXIT
fi

# Determine the real user (even when running with sudo)
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

# ===== Detect architecture =====
ARCH=$(uname -m)
echo "Detected architecture: $ARCH"
case "$ARCH" in
  x86_64)
    echo "Environment: x86_64/amd64 (Hyper-V)"
    ;;
  aarch64)
    echo "Environment: aarch64/arm64 (UTM on Apple Silicon)"
    ;;
  *)
    echo "WARNING: Unsupported architecture: $ARCH"
    echo "This script supports x86_64 (Hyper-V) and aarch64 (UTM on Apple Silicon)."
    exit 1
    ;;
esac

echo "=== Installing Kubernetes requirements for Ubuntu ==="

# ===== Basic Tools =====
echo ""
echo -e "\e[1;36m>>> Installing Basic Tools...\e[0m"
sudo apt-get update -y
sudo apt-get install -y \
    ssh net-tools apt-transport-https curl git \
    build-essential procps file \
    wget software-properties-common \
    ca-certificates lsb-release gnupg gpg \
    libnss3-tools unzip

# Enable and start SSH
sudo systemctl enable --now ssh
sudo systemctl is-active ssh > /dev/null 2>&1 || echo "Note: SSH service status unknown"
echo -e "\e[1;32m<<< Basic Tools installation complete.\e[0m"

# ===== PowerShell =====
echo ""
echo -e "\e[1;36m>>> Installing PowerShell...\e[0m"
# Install from GitHub tarball — works on both amd64 and arm64 without Microsoft repo
case "$ARCH" in
  x86_64)  PS_ARCH="x64" ;;
  aarch64) PS_ARCH="arm64" ;;
esac
wget -q -O /tmp/powershell.tar.gz \
  "https://github.com/PowerShell/PowerShell/releases/download/v7.5.4/powershell-7.5.4-linux-${PS_ARCH}.tar.gz?nocache=$(date +%s)"
sudo mkdir -p /opt/microsoft/powershell/7
sudo tar zxf /tmp/powershell.tar.gz -C /opt/microsoft/powershell/7
sudo chmod +x /opt/microsoft/powershell/7/pwsh
sudo ln -sf /opt/microsoft/powershell/7/pwsh /usr/bin/pwsh
rm -f /tmp/powershell.tar.gz
echo -e "\e[1;32m<<< PowerShell installation complete.\e[0m"

# Install powershell-yaml module for all users
echo ""
echo -e "\e[1;36m>>> Installing PowerShell module: powershell-yaml...\e[0m"
sudo pwsh -NoProfile -Command "Install-Module -Name powershell-yaml -Scope AllUsers -Force" || echo "Note: powershell-yaml module installation attempted"
echo -e "\e[1;32m<<< PowerShell module: powershell-yaml installation complete.\e[0m"

# ===== Cloud CLIs =====

# Azure CLI (using new DEB-822 format)
echo ""
echo -e "\e[1;36m>>> Installing Azure CLI...\e[0m"
sudo mkdir -p /etc/apt/keyrings
curl -sLS "https://packages.microsoft.com/keys/microsoft.asc?nocache=$(date +%s)" |
    gpg --batch --yes --dearmor |
    sudo tee /etc/apt/keyrings/microsoft.gpg > /dev/null
sudo chmod go+r /etc/apt/keyrings/microsoft.gpg

AZ_DIST=$(lsb_release -cs)
echo "Types: deb
URIs: https://packages.microsoft.com/repos/azure-cli/
Suites: ${AZ_DIST}
Components: main
Architectures: $(dpkg --print-architecture)
Signed-by: /etc/apt/keyrings/microsoft.gpg" | sudo tee /etc/apt/sources.list.d/azure-cli.sources > /dev/null

sudo apt-get update -y
sudo apt-get install -y azure-cli
echo -e "\e[1;32m<<< Azure CLI installation complete.\e[0m"

# AWS CLI (official installer — supports amd64 and arm64)
echo ""
echo -e "\e[1;36m>>> Installing AWS CLI...\e[0m"
ARCH=$(dpkg --print-architecture)
if [ "$ARCH" = "amd64" ]; then
    AWS_CLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
elif [ "$ARCH" = "arm64" ]; then
    AWS_CLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip"
else
    echo "WARNING: Unsupported architecture '$ARCH' for AWS CLI"
    AWS_CLI_URL=""
fi
if [ -n "$AWS_CLI_URL" ]; then
    curl -fsSL "${AWS_CLI_URL}?nocache=$(date +%s)" -o /tmp/awscliv2.zip
    unzip -qo /tmp/awscliv2.zip -d /tmp
    sudo /tmp/aws/install --update || true
    rm -rf /tmp/aws /tmp/awscliv2.zip
fi
echo -e "\e[1;32m<<< AWS CLI installation complete.\e[0m"

# Google Cloud SDK
echo ""
echo -e "\e[1;36m>>> Installing Google Cloud SDK...\e[0m"
sudo snap install google-cloud-sdk --classic || echo "Google Cloud SDK snap installation attempted"
echo -e "\e[1;32m<<< Google Cloud SDK installation complete.\e[0m"

# ===== Docker =====
echo ""
echo -e "\e[1;36m>>> Installing Docker...\e[0m"
# Add Docker's official repository
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL "https://download.docker.com/linux/ubuntu/gpg?nocache=$(date +%s)" -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
sudo apt-get update -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Docker service starts automatically after installation;
# enable + start as a safety net, tolerating errors in environments where systemd is not fully available
sudo systemctl enable docker 2>/dev/null || echo "Note: systemctl enable docker skipped (systemd may not be available)"
sudo systemctl start docker 2>/dev/null || echo "Note: systemctl start docker skipped (systemd may not be available)"
sudo systemctl is-active docker > /dev/null 2>&1 || echo "Note: Docker service status unknown"

# Configure Docker user permissions
if ! getent group docker > /dev/null 2>&1; then
    sudo groupadd docker
fi
sudo usermod -aG docker "$REAL_USER" 2>/dev/null || echo "Note: Could not add user to docker group"

# Add "newgrp docker" to .bashrc so the docker group is active in every terminal session.
# The guard (id -nG check) prevents an infinite loop: newgrp starts a new shell that
# re-sources .bashrc, but this time the group is already active so the guard is skipped.
# PowerShell (pwsh) launched from that shell inherits the docker group automatically.
BASHRC="${REAL_HOME}/.bashrc"
if ! grep -q 'newgrp docker' "$BASHRC" 2>/dev/null; then
    cat >> "$BASHRC" <<'DOCKER_GROUP'

# Activate docker group without requiring logout/login
# Only run newgrp if: user is in docker group in /etc/group BUT the current shell doesn't have it yet
if getent group docker 2>/dev/null | grep -qw "$(whoami)" && ! id -nG | grep -qw docker; then
    newgrp docker
fi
DOCKER_GROUP
    chown "$REAL_USER:$REAL_USER" "$BASHRC"
fi

# Test Docker
docker version > /dev/null 2>&1 && echo "Docker engine is responding" || echo "Note: Docker engine not responding yet - may need service restart or reboot"
echo -e "\e[1;32m<<< Docker installation complete.\e[0m"

# ===== KVM Virtualization Support (required by Docker Desktop) =====
echo ""
echo -e "\e[1;36m>>> Installing KVM Virtualization Support...\e[0m"
sudo apt-get install -y cpu-checker qemu-kvm libvirt-daemon-system libvirt-clients
sudo modprobe kvm
# Load the appropriate vendor-specific KVM module
if grep -q vmx /proc/cpuinfo 2>/dev/null; then
    sudo modprobe kvm_intel
elif grep -q svm /proc/cpuinfo 2>/dev/null; then
    sudo modprobe kvm_amd
fi
# Grant the current user access to /dev/kvm
sudo usermod -aG kvm "$REAL_USER" 2>/dev/null || echo "Note: Could not add user to kvm group"
# Verify /dev/kvm is available (requires nested virtualization on the host)
if [ -e /dev/kvm ]; then
    echo "KVM configured (/dev/kvm is available)"
else
    echo "WARNING: /dev/kvm not found. Nested virtualization may not be enabled on the host."
    echo "  Hyper-V host: Set-VMProcessor -VMName <name> -ExposeVirtualizationExtensions \$true"
    echo "  UTM host: Requires Apple Virtualization backend (not QEMU), macOS 15+, Apple M3+ chip, UTM v4.6+"
    echo "  Docker Desktop will not run without KVM support."
fi
echo -e "\e[1;32m<<< KVM Virtualization Support installation complete.\e[0m"

# ===== Docker Desktop =====
echo ""
echo -e "\e[1;36m>>> Installing Docker Desktop...\e[0m"
ARCH=$(dpkg --print-architecture)
if [ "$ARCH" = "amd64" ]; then
    DOCKER_DESKTOP_URL="https://desktop.docker.com/linux/main/amd64/docker-desktop-amd64.deb"
elif [ "$ARCH" = "arm64" ]; then
    DOCKER_DESKTOP_URL="https://desktop.docker.com/linux/main/arm64/docker-desktop-arm64.deb"
else
    DOCKER_DESKTOP_URL=""
    echo "WARNING: Unsupported architecture '$ARCH' for Docker Desktop"
fi
if [ -n "$DOCKER_DESKTOP_URL" ]; then
    curl -fsSL "${DOCKER_DESKTOP_URL}?nocache=$(date +%s)" -o /tmp/docker-desktop.deb
    sudo apt-get install -y /tmp/docker-desktop.deb
    rm -f /tmp/docker-desktop.deb
fi
echo -e "\e[1;32m<<< Docker Desktop installation complete.\e[0m"

# ===== Disable Swap =====
echo ""
echo -e "\e[1;36m>>> Disabling swap...\e[0m"
sudo sed -i '/ swap / s/^/#/' /etc/fstab
sudo swapoff -a || true
echo -e "\e[1;32m<<< Swap disabled.\e[0m"

# ===== Verify Docker is Ready =====
echo ""
echo -e "\e[1;36m>>> Verifying Docker is up and running...\e[0m"
DOCKER_WAIT_SECONDS=60
DOCKER_READY=false
for i in $(seq 1 "$DOCKER_WAIT_SECONDS"); do
    if sudo systemctl is-active docker &>/dev/null; then
        DOCKER_READY=true
        echo "Docker is up and running."
        break
    fi
    echo "Waiting for Docker daemon to be ready... ($i/${DOCKER_WAIT_SECONDS}s)"
    sleep 1
done

if [ "$DOCKER_READY" = false ]; then
    echo ""
    echo -e "\e[1;31m╔════════════════════════════════════════════════════════════════════╗\e[0m"
    echo -e "\e[1;31m║  ERROR: Docker daemon is not responding after ${DOCKER_WAIT_SECONDS}s               ║\e[0m"
    echo -e "\e[1;31m╠════════════════════════════════════════════════════════════════════╣\e[0m"
    echo -e "\e[1;31m║  Kubernetes requires Docker to be running. Try the following:      ║\e[0m"
    echo -e "\e[1;31m║                                                                    ║\e[0m"
    echo -e "\e[1;31m║  1. Start Docker manually:                                         ║\e[0m"
    echo -e "\e[1;31m║     sudo systemctl start docker                                    ║\e[0m"
    echo -e "\e[1;31m║                                                                    ║\e[0m"
    echo -e "\e[1;31m║  2. Check Docker status and logs:                                  ║\e[0m"
    echo -e "\e[1;31m║     sudo systemctl status docker                                   ║\e[0m"
    echo -e "\e[1;31m║     sudo journalctl -xeu docker.service                            ║\e[0m"
    echo -e "\e[1;31m║                                                                    ║\e[0m"
    echo -e "\e[1;31m║  3. If systemd is not available (e.g. WSL), start dockerd:         ║\e[0m"
    echo -e "\e[1;31m║     sudo dockerd &                                                 ║\e[0m"
    echo -e "\e[1;31m║                                                                    ║\e[0m"
    echo -e "\e[1;31m║  Once Docker is running, re-run this script to continue setup.     ║\e[0m"
    echo -e "\e[1;31m╚════════════════════════════════════════════════════════════════════╝\e[0m"
    echo ""
    exit 1
fi
echo -e "\e[1;32m<<< Docker is ready.\e[0m"

# ===== Kubernetes =====
echo ""
echo -e "\e[1;36m>>> Installing Kubernetes...\e[0m"
# Add Kubernetes official repository (new pkgs.k8s.io, deprecated apt.kubernetes.io)
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v1.35/deb/Release.key?nocache=$(date +%s)" | sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.35/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null

sudo apt-get update -y
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo kubeadm config images pull || echo "Note: kubeadm images pull may need to be run after kubeadm init"

# ===== Initialize Kubernetes Cluster =====

# Reconfigure containerd to enable CRI plugin (disabled by default in the containerd.io package)
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl enable containerd
sudo systemctl restart containerd

# Reset any existing kubeadm state so the script can be re-run safely
# Reference: https://k8s.io/docs/reference/setup-tools/kubeadm/kubeadm-reset/
if [ -f /etc/kubernetes/manifests/kube-apiserver.yaml ] || [ -d /etc/kubernetes/pki ]; then
    echo "Existing Kubernetes cluster detected — resetting before re-initialization"
    sudo kubeadm reset -f --cri-socket unix:///var/run/containerd/containerd.sock
    # Clean up CNI plugin configuration
    sudo rm -rf /etc/cni/net.d
    # Clean up network filtering rules left by the previous cluster
    sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X || true
    if command -v ipvsadm &>/dev/null; then
        sudo ipvsadm --clear || true
    fi
    # Clean up kubeconfig
    sudo rm -f "${REAL_HOME}/.kube/config"
fi

# Restart containerd after reset (reset can disrupt it) and wait for the socket
sudo systemctl restart containerd
for i in $(seq 1 30); do
    if sudo crictl --runtime-endpoint unix:///var/run/containerd/containerd.sock info &>/dev/null; then
        echo "containerd is ready"
        break
    fi
    echo "Waiting for containerd to be ready... ($i/30)"
    sleep 1
done

# Load kernel modules required by Kubernetes networking (Flannel uses vxlan which needs overlay + br_netfilter)
sudo modprobe overlay
sudo modprobe br_netfilter

# Persist modules across reboots
cat <<'EOF' | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

# Required sysctl settings: allow bridged traffic through iptables and enable IP forwarding
cat <<'EOF' | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

sudo systemctl enable --now kubelet 2>/dev/null || echo "Note: kubelet enable attempted"
sudo kubeadm init --pod-network-cidr=10.244.0.0/16

# Configure kubectl for the real user
mkdir -p "${REAL_HOME}/.kube"
sudo cp /etc/kubernetes/admin.conf "${REAL_HOME}/.kube/config"
sudo chown "$REAL_USER:$REAL_USER" "${REAL_HOME}/.kube/config"
export KUBECONFIG="${REAL_HOME}/.kube/config"

# Install Flannel networking plugin
kubectl --kubeconfig="${REAL_HOME}/.kube/config" apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

# Wait for Flannel DaemonSet pods to be ready before proceeding
echo "Waiting for Flannel pods to be ready..."
kubectl --kubeconfig="${REAL_HOME}/.kube/config" -n kube-flannel rollout status daemonset/kube-flannel-ds --timeout=180s \
    || echo "Note: Flannel rollout status check timed out — pods may still be starting"

# Wait for the node to report Ready (networking must be up for this to succeed)
echo "Waiting for node to be Ready..."
kubectl --kubeconfig="${REAL_HOME}/.kube/config" wait --for=condition=ready node --all --timeout=180s \
    || echo "Note: Node ready wait timed out — node may still be initializing"

# Remove control-plane taint for single-node cluster
kubectl --kubeconfig="${REAL_HOME}/.kube/config" taint nodes --all node-role.kubernetes.io/control-plane- || true

# Rename kubectl context to docker-desktop
kubectl --kubeconfig="${REAL_HOME}/.kube/config" config rename-context kubernetes-admin@kubernetes docker-desktop || true
echo -e "\e[1;32m<<< Kubernetes installation complete.\e[0m"

# ===== Other Requirements =====

# Helm (official install script)
echo ""
echo -e "\e[1;36m>>> Installing Helm...\e[0m"
curl -fsSL "https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3?nocache=$(date +%s)" | bash || true
echo -e "\e[1;32m<<< Helm installation complete.\e[0m"

# OpenTofu (official install script, deb method)
echo ""
echo -e "\e[1;36m>>> Installing OpenTofu...\e[0m"
curl --proto '=https' --tlsv1.2 -fsSL "https://get.opentofu.org/install-opentofu.sh?nocache=$(date +%s)" -o /tmp/install-opentofu.sh
chmod +x /tmp/install-opentofu.sh
/tmp/install-opentofu.sh --install-method deb || true
rm -f /tmp/install-opentofu.sh
echo -e "\e[1;32m<<< OpenTofu installation complete.\e[0m"

# mkcert (download pre-built binary from GitHub)
echo ""
echo -e "\e[1;36m>>> Installing mkcert...\e[0m"
ARCH=$(dpkg --print-architecture)
if [ "$ARCH" = "amd64" ]; then
    MKCERT_ARCH="linux/amd64"
elif [ "$ARCH" = "arm64" ]; then
    MKCERT_ARCH="linux/arm64"
else
    MKCERT_ARCH=""
    echo "WARNING: Unsupported architecture '$ARCH' for mkcert"
fi
if [ -n "$MKCERT_ARCH" ]; then
    curl -fsSL "https://dl.filippo.io/mkcert/latest?for=${MKCERT_ARCH}&nocache=$(date +%s)" -o /tmp/mkcert
    chmod +x /tmp/mkcert
    sudo mv /tmp/mkcert /usr/local/bin/mkcert
    mkcert -install || true
fi
echo -e "\e[1;32m<<< mkcert installation complete.\e[0m"

# graphviz (available in Ubuntu repositories)
echo ""
echo -e "\e[1;36m>>> Installing graphviz...\e[0m"
sudo apt-get install -y graphviz
echo -e "\e[1;32m<<< graphviz installation complete.\e[0m"

# ===== HTTPS Development Certificate =====
echo ""
echo -e "\e[1;36m>>> Creating HTTPS development certificate...\e[0m"
PFX_DIR="${REAL_HOME}/.aspnet/https"
mkdir -p "$PFX_DIR"
openssl req -x509 -newkey rsa:4096 -keyout "$PFX_DIR/aspnetapp.key" -out "$PFX_DIR/aspnetapp.crt" -days 365 -nodes -subj '/CN=localhost' 2>/dev/null
openssl pkcs12 -export -out "$PFX_DIR/aspnetapp.pfx" -inkey "$PFX_DIR/aspnetapp.key" -in "$PFX_DIR/aspnetapp.crt" -password pass:password
rm -f "$PFX_DIR/aspnetapp.key" "$PFX_DIR/aspnetapp.crt"
# Ensure the real user owns the certificate files (not root)
chown -R "$REAL_USER:$REAL_USER" "$PFX_DIR"
echo -e "\e[1;32m<<< HTTPS development certificate created at $PFX_DIR/aspnetapp.pfx\e[0m"

# ===== Version Check =====
echo ""
echo "=== Installation Summary ==="
docker --version
git --version
kubeadm version || true
kubectl version --client || true
pwsh --version 2>/dev/null || echo "PowerShell - run: pwsh --version"
helm version --short 2>/dev/null || echo "Helm - run: helm version --short"
tofu version 2>/dev/null | head -1 || echo "OpenTofu - run: tofu version"
mkcert -version 2>/dev/null || echo "mkcert - run: mkcert -version"
az --version 2>/dev/null | head -1 || true
aws --version || true
gcloud --version || echo "Google Cloud SDK - run: gcloud --version"

echo ""
echo "=== Optional Steps ==="
echo "Current hostname: $(hostnamectl hostname)"
echo "1. Change hostname: sudo hostnamectl set-hostname [desired-hostname]"
echo ""
echo -e "\e[1;33m╔════════════════════════════════════════════════════════════════════╗\e[0m"
echo -e "\e[1;33m║  IMPORTANT: Docker group permissions                               ║\e[0m"
echo -e "\e[1;33m║                                                                    ║\e[0m"
echo -e "\e[1;33m║  Your user was added to the 'docker' group, but the current shell  ║\e[0m"
echo -e "\e[1;33m║  does not have the updated group membership yet.                   ║\e[0m"
echo -e "\e[1;33m║                                                                    ║\e[0m"
echo -e "\e[1;33m║  To enable docker commands in this terminal, run:                  ║\e[0m"
echo -e "\e[1;33m║      newgrp docker                                                 ║\e[0m"
echo -e "\e[1;33m║                                                                    ║\e[0m"
echo -e "\e[1;33m║  New terminals will activate the docker group automatically        ║\e[0m"
echo -e "\e[1;33m║  via the .bashrc snippet. A full logout/login also works.          ║\e[0m"
echo -e "\e[1;33m╚════════════════════════════════════════════════════════════════════╝\e[0m"

