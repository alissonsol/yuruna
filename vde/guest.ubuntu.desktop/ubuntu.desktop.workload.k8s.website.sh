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

# Fix kube permissions
sudo chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.kube"

# Install mkcert CA
mkcert -install 2>/dev/null || true

# Start Docker registry if not running
docker start registry 2>/dev/null || docker run -d -p 5000:5000 --restart=always --name registry registry:2

# Clone yuruna if not present
if [ ! -d "$REAL_HOME/yuruna" ]; then
    for attempt in 1 2 3; do
        git clone https://github.com/alissonsol/yuruna.git "$REAL_HOME/yuruna" && break
        echo "git clone attempt $attempt failed"
        rm -rf "$REAL_HOME/yuruna"
        [ $attempt -lt 3 ] && sleep 60
    done
    if [ ! -d "$REAL_HOME/yuruna" ]; then
        echo "git clone failed after 3 attempts" >&2
        exit 1
    fi
fi

# Run Set-Resource
cd "$REAL_HOME/yuruna/examples"
pwsh ../automation/Set-Resource.ps1 website localhost

# Rename kubectl context to match runId
CONTEXT=$(grep 'clusterDnsPrefix' "$REAL_HOME/yuruna/examples/website/config/localhost/resources.output.yml" | awk '{print $2}' | tr -d '"')
kubectl config rename-context docker-desktop "localhost-${CONTEXT}" 2>/dev/null || true

# Build and push Docker image
cd "$REAL_HOME/yuruna/examples/website/components/frontend/website"
cp "$REAL_HOME/.aspnet/https/aspnetapp.pfx" .
docker build --progress=plain --rm --build-arg DEV=1 --no-cache -f Dockerfile -t "website/website:latest" .
docker tag website/website:latest localhost:5000/website/website:latest
docker push localhost:5000/website/website:latest

# Run Set-Component and Set-Workload
cd "$REAL_HOME/yuruna/examples"
pwsh ../automation/Set-Component.ps1 website localhost
pwsh ../automation/Set-Workload.ps1 website localhost
