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
   sudo -v || { echo "Failed to obtain sudo privileges."; exit 1; }
   # Keep sudo credentials fresh for long-running installations
   while true; do sudo -n -v 2>/dev/null; sleep 50; done &
   SUDO_KEEPALIVE_PID=$!
   trap 'kill $SUDO_KEEPALIVE_PID 2>/dev/null' EXIT
fi

# Determine the real user (even when running with sudo)
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

echo "=== Installing yuruna requirements for Ubuntu ==="

# ===== Basic Tools =====
echo "=== Installing basic tools ==="
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

echo "✓ Basic tools installed"

# ===== PowerShell =====
echo "=== Installing PowerShell ==="
ARCH=$(dpkg --print-architecture)
if [ "$ARCH" = "amd64" ]; then
    source /etc/os-release
    wget -q https://packages.microsoft.com/config/ubuntu/$VERSION_ID/packages-microsoft-prod.deb
    sudo dpkg -i packages-microsoft-prod.deb
    rm packages-microsoft-prod.deb
    sudo apt-get update -y
    sudo apt-get install -y powershell
else
    # Microsoft does not publish PowerShell apt packages for arm64;
    # install via snap which supports both architectures
    sudo snap install powershell --classic || echo "Note: PowerShell snap installation attempted"
fi
echo "✓ PowerShell installed"

# ===== Cloud CLIs =====
echo "=== Installing Cloud CLIs ==="

# Azure CLI (using new DEB-822 format)
sudo mkdir -p /etc/apt/keyrings
curl -sLS https://packages.microsoft.com/keys/microsoft.asc |
    gpg --dearmor |
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
echo "✓ Azure CLI installed"

# AWS CLI (official installer — supports amd64 and arm64)
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
    curl -fsSL "$AWS_CLI_URL" -o /tmp/awscliv2.zip
    unzip -qo /tmp/awscliv2.zip -d /tmp
    sudo /tmp/aws/install --update || true
    rm -rf /tmp/aws /tmp/awscliv2.zip
    echo "✓ AWS CLI installed"
fi

# Google Cloud SDK
sudo snap install google-cloud-sdk --classic || echo "Google Cloud SDK snap installation attempted"
echo "✓ Google Cloud SDK installed"

echo "✓ Cloud CLIs installed"

# ===== Docker =====
echo "=== Installing Docker ==="
# Add Docker's official repository
sudo install -m 0755 -d /etc/apt/keyrings
echo "✓ keyrings directory created with correct permissions"
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
echo "✓ gpg key for Docker downloaded"
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "✓ Certificate for Docker repository added"

sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
echo "✓ Source for Docker repository added"

sudo apt-get update -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
echo "✓ Packages installed"

# Docker service starts automatically after installation;
# enable + start as a safety net, tolerating errors in environments where systemd is not fully available
sudo systemctl enable docker 2>/dev/null || echo "Note: systemctl enable docker skipped (systemd may not be available)"
sudo systemctl start docker 2>/dev/null || echo "Note: systemctl start docker skipped (systemd may not be available)"
sudo systemctl is-active docker > /dev/null 2>&1 || echo "Note: Docker service status unknown"
echo "✓ Service for Docker enabled and started (if systemd is available)"

# Configure Docker user permissions
if ! getent group docker > /dev/null 2>&1; then
    sudo groupadd docker
fi
sudo usermod -aG docker "$REAL_USER" 2>/dev/null || echo "Note: Could not add user to docker group"
echo "✓ Permissions for Docker configured (log out and back in for group membership to take effect)"

# Test Docker
docker version > /dev/null 2>&1 && echo "Docker engine is responding" || echo "Note: Docker engine not responding yet - may need service restart or reboot"
echo "✓ Docker installed"

# ===== Docker Desktop =====
echo "=== Installing Docker Desktop ==="
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
    curl -fsSL "$DOCKER_DESKTOP_URL" -o /tmp/docker-desktop.deb
    sudo apt-get install -y /tmp/docker-desktop.deb
    rm -f /tmp/docker-desktop.deb
    echo "✓ Docker Desktop installed"
fi

# ===== Disable Swap =====
echo "=== Disabling swap ==="
sudo sed -i '/ swap / s/^/#/' /etc/fstab
sudo swapoff -a || true
echo "✓ Swap disabled"

# ===== Kubernetes =====
echo "=== Installing Kubernetes ==="
# Add Kubernetes official repository (new pkgs.k8s.io, deprecated apt.kubernetes.io)
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.35/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.35/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null

sudo apt-get update -y
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo kubeadm config images pull || echo "Note: kubeadm images pull may need to be run after kubeadm init"

echo "✓ Kubernetes tools installed"
echo "  NOTE: Run 'sudo kubeadm init --pod-network-cidr=10.244.0.0/16' to initialize the cluster"
echo "  Then configure ~/.kube/config and install networking plugin"

# ===== Other Requirements =====
echo "=== Installing other requirements ==="

# Helm (official install script)
echo "--- Installing Helm ---"
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash || true
echo "✓ Helm installed"

# OpenTofu (official install script, deb method)
echo "--- Installing OpenTofu ---"
curl --proto '=https' --tlsv1.2 -fsSL https://get.opentofu.org/install-opentofu.sh -o /tmp/install-opentofu.sh
chmod +x /tmp/install-opentofu.sh
/tmp/install-opentofu.sh --install-method deb || true
rm -f /tmp/install-opentofu.sh
echo "✓ OpenTofu installed"

# mkcert (download pre-built binary from GitHub)
echo "--- Installing mkcert ---"
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
    curl -fsSL "https://dl.filippo.io/mkcert/latest?for=${MKCERT_ARCH}" -o /tmp/mkcert
    chmod +x /tmp/mkcert
    sudo mv /tmp/mkcert /usr/local/bin/mkcert
    mkcert -install || true
    echo "✓ mkcert installed"
fi

# graphviz (available in Ubuntu repositories)
echo "--- Installing graphviz ---"
sudo apt-get install -y graphviz
echo "✓ graphviz installed"

echo "✓ Other requirements installed"

# ===== Version Check =====
echo ""
echo "=== Installation Summary ==="
echo "✓ SSH enabled"
docker --version
git --version
kubeadm version || true
kubectl version --client || true
powershell --version 2>/dev/null || echo "PowerShell - run: powershell --version"
helm version --short 2>/dev/null || echo "Helm - run: helm version --short"
tofu version 2>/dev/null | head -1 || echo "OpenTofu - run: tofu version"
mkcert -version 2>/dev/null || echo "mkcert - run: mkcert -version"
az --version 2>/dev/null | head -1 || true
aws --version || true
gcloud --version || echo "Google Cloud SDK - run: gcloud --version"

echo ""
echo "=== Manual Steps Required ==="
echo "1. Set hostname: sudo hostnamectl set-hostname [desired-hostname]"
echo "2. Initialize Kubernetes: sudo kubeadm init --pod-network-cidr=10.244.0.0/16"
echo "3. Configure kubectl config:"
echo "   mkdir -p \$HOME/.kube"
echo "   sudo cp -i /etc/kubernetes/admin.conf \$HOME/.kube/config"
echo "   sudo chown \$(id -u):\$(id -g) \$HOME/.kube/config"
echo "4. Install networking plugin (e.g., Flannel):"
echo "   kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml"
echo "5. Remove taints from nodes (if needed for single-node cluster)"
echo "6. Rename kubectl context: kubectl config rename-context kubernetes-admin@kubernetes docker-desktop"
echo "7. Terminal restart may be needed for group permissions to take effect"
