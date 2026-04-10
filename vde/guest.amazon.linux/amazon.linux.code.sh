#!/bin/bash
set -euo pipefail

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

# ===== Detect architecture =====
ARCH=$(uname -m)
echo "Detected architecture: $ARCH"
case "$ARCH" in
  x86_64)
    echo "Environment: x86_64 (Hyper-V)"
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

# ===== Install the JDK =====
echo ""
echo -e "\e[1;36m>>> Installing JDK (Amazon Corretto)...\e[0m"
# Amazon Corretto provides both x86_64 and aarch64 packages
sudo dnf install -y java-21-amazon-corretto-devel
java -version
javac -version
export JAVA_HOME=/etc/alternatives/java_sdk
if ! grep -q 'export JAVA_HOME=/etc/alternatives/java_sdk' /etc/bashrc 2>/dev/null; then
  echo 'export JAVA_HOME=/etc/alternatives/java_sdk' | sudo tee -a /etc/bashrc
fi
echo -e "\e[1;32m<<< JDK (Amazon Corretto) installation complete.\e[0m"

# ===== Install .NET SDK =====
echo ""
echo -e "\e[1;36m>>> Installing .NET SDK...\e[0m"
# Use Microsoft's official dotnet-install.sh script instead of RPM repos.
# The CentOS 8/9 repo configs are incompatible with Amazon Linux 2023 (Fedora-based).
# dotnet-install.sh auto-detects architecture (x86_64/aarch64) and works reliably.
# Install libicu dependency required by .NET for globalization support.
sudo dnf install -y libicu
sudo mkdir -p /usr/local/dotnet
curl -sSL "https://dot.net/v1/dotnet-install.sh?nocache=$(date +%s)" -o /tmp/dotnet-install.sh
chmod +x /tmp/dotnet-install.sh
sudo bash /tmp/dotnet-install.sh --channel LTS --install-dir /usr/local/dotnet
rm -f /tmp/dotnet-install.sh

# Make dotnet available system-wide
sudo ln -sf /usr/local/dotnet/dotnet /usr/local/bin/dotnet
if ! grep -q 'export DOTNET_ROOT=/usr/local/dotnet' /etc/bashrc 2>/dev/null; then
  echo 'export DOTNET_ROOT=/usr/local/dotnet' | sudo tee -a /etc/bashrc
fi
dotnet --version
echo -e "\e[1;32m<<< .NET SDK installation complete.\e[0m"

# ===== Install Git =====
echo ""
echo -e "\e[1;36m>>> Installing Git...\e[0m"
sudo dnf -y install git
git --version
echo -e "\e[1;32m<<< Git installation complete.\e[0m"

# ===== Install Visual Studio Code =====
echo ""
echo -e "\e[1;36m>>> Installing Visual Studio Code...\e[0m"
# The VS Code yum repo provides both x86_64 and aarch64 packages
sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc 2>/dev/null || true
sudo sh -c 'echo -e "[code]\nname=Visual Studio Code\nbaseurl=https://packages.microsoft.com/yumrepos/vscode\nenabled=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc" > /etc/yum.repos.d/vscode.repo'
sudo dnf -y install code
echo -e "\e[1;32m<<< Visual Studio Code installation complete.\e[0m"

# ===== Show installed versions =====
echo ""
echo "DotNet: $(dotnet --version)"
echo "Git: $(git --version)"
echo "Java: $(javac -version)"
if [ -z "${TMPDIR:-}" ]; then
	TMPDIR=$(mktemp -d)
    export TMPDIR
	echo "TMPDIR not set. Created and set TMPDIR to $TMPDIR"
fi
echo "Visual Studio Code: $(code --version --no-sandbox --user-data-dir "$TMPDIR")"
