#!/bin/bash
set -euo pipefail

# ===== Request sudo elevation if not already root =====
if [[ $EUID -ne 0 ]]; then
   echo ""
   echo "╔════════════════════════════════════════════════════════════╗"
   echo "║  This script requires elevated privileges (sudo)            ║"
   echo "║  Please enter your password when prompted below            ║"
   echo "║  The script will pause until you provide your password     ║"
   echo "╚════════════════════════════════════════════════════════════╝"
   echo ""
   sudo "$0" "$@"
   exit $?
fi

# Determine the real user (even when running with sudo)
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

echo "=== Installing yuruna requirements for Ubuntu ==="

# ===== Basic Tools =====
echo "=== Installing basic tools ==="
sudo apt-get update -y
sudo apt-get install -y ssh net-tools apt-transport-https curl git

# Enable and start SSH
sudo systemctl enable --now ssh
sudo systemctl status ssh || true

echo "✓ Basic tools installed"

# ===== Docker =====
echo "=== Installing Docker ==="
# Add Docker's official repository
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
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

sudo systemctl enable docker
sudo systemctl start docker
sudo systemctl status docker || true

# Configure Docker user permissions
sudo chmod 666 /var/run/docker.sock
sudo groupadd docker || true
sudo usermod -aG docker "$REAL_USER"
newgrp docker || true

# Test Docker
docker run hello-world || echo "Docker test - may need terminal restart for group permissions"
echo "✓ Docker installed"

# ===== Disable Swap =====
echo "=== Disabling swap ==="
sudo sed -i '/ swap / s/^/#/' /etc/fstab
sudo swapoff -a || true
echo "✓ Swap disabled"

# ===== Kubernetes =====
echo "=== Installing Kubernetes ==="
# Add Kubernetes official repository (new pkgs.k8s.io, deprecated apt.kubernetes.io)
sudo apt-get install -y apt-transport-https ca-certificates curl gpg
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

# ===== Homebrew =====
echo "=== Installing Homebrew ==="
sudo apt-get install -y build-essential curl file
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || true

# Add Homebrew to PATH for current session
eval $(/home/linuxbrew/.linuxbrew/bin/brew shellenv) || true

# Add Homebrew to shell profile for future sessions
echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' | sudo tee -a "$REAL_HOME/.bashrc" > /dev/null

echo "✓ Homebrew installed"

# ===== PowerShell =====
echo "=== Installing PowerShell ==="
sudo apt-get update -y
sudo apt-get install -y wget apt-transport-https software-properties-common
source /etc/os-release
wget -q https://packages.microsoft.com/config/ubuntu/$VERSION_ID/packages-microsoft-prod.deb
sudo dpkg -i packages-microsoft-prod.deb
rm packages-microsoft-prod.deb
sudo apt-get update -y
sudo apt-get install -y powershell
echo "✓ PowerShell installed"

# ===== Other Requirements =====
echo "=== Installing other requirements ==="
eval $(/home/linuxbrew/.linuxbrew/bin/brew shellenv) || true
/home/linuxbrew/.linuxbrew/bin/brew install helm || true
/home/linuxbrew/.linuxbrew/bin/brew install terraform || true
sudo apt-get install -y libnss3-tools
/home/linuxbrew/.linuxbrew/bin/brew install mkcert || true
/home/linuxbrew/.linuxbrew/bin/brew install graphviz || true

# Setup mkcert
mkcert -install || true

echo "✓ Other requirements installed"

# ===== Cloud CLIs =====
echo "=== Installing Cloud CLIs ==="
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl apt-transport-https lsb-release gnupg

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

# AWS CLI
eval $(/home/linuxbrew/.linuxbrew/bin/brew shellenv) || true
/home/linuxbrew/.linuxbrew/bin/brew install awscli || true

# Google Cloud SDK
sudo snap install google-cloud-sdk --classic || echo "Google Cloud SDK snap installation attempted"

echo "✓ Cloud CLIs installed"

# ===== Version Check =====
echo ""
echo "=== Installation Summary ==="
echo "✓ SSH enabled"
docker --version
git --version
kubeadm version || true
kubectl version --client || true
powershell --version 2>/dev/null || echo "PowerShell - run: powershell --version"
/home/linuxbrew/.linuxbrew/bin/brew --version || true
azure --version || true
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
