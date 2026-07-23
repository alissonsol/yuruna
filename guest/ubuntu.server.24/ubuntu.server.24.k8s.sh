#!/bin/bash
# Version: 2026.07.22
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NONINTERACTIVE=1

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

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

# --- REGION: https://yuruna.link/network#defining-yuruna-retry-lib
. /usr/local/lib/yuruna/yuruna-retry.sh
# Baked retry libs may default apt attempts to a wall-clock bound -- the
# wrapped-apt teardown-hang trap class (apt blocks at end-of-transaction
# under a timeout(1) parent). Force unbounded regardless of the image's
# lib vintage; remove once no image predates the lib's unbounded default.
export YURUNA_APT_STALL_TIMEOUT=0

# A tool that is present but not runnable is more dangerous than a missing one,
# because the usual checks all pass it: `command -v` only tests for a directory
# entry, and bash runs a ZERO-LENGTH file carrying the +x bit as an empty script
# -- exit 0, no output -- so even a `<tool> --version` probe succeeds. The
# breakage then travels: it survives into a saved image and only surfaces much
# later under PowerShell (which execve()s directly) as "Exec format error", in a
# step far from the install. Assert the binary is on PATH, NON-EMPTY, and prints
# a version, so a truncated or half-written tool fails here instead.
assert_tool_runnable() {
    local name="$1"; shift
    local path
    path="$(command -v "$name" 2>/dev/null || true)"
    if [ -z "$path" ]; then
        echo "ERROR: '$name' is not on PATH after install." >&2
        return 1
    fi
    if [ ! -s "$path" ]; then
        echo "ERROR: '$name' at $path is a ZERO-LENGTH file (truncated download, or a lost write)." >&2
        return 1
    fi
    if [ -z "$("$name" "$@" 2>/dev/null | head -c 1)" ]; then
        echo "ERROR: '$name' at $path produced no output for: $name $*" >&2
        return 1
    fi
    return 0
}

echo "== Installing Kubernetes requirements for Ubuntu =="

echo ""
echo -e "\e[1;36m==== Basic tools ====\e[0m"
apt_retry sudo apt-get update -y
apt_retry sudo apt-get install -y \
    ssh net-tools apt-transport-https curl git \
    build-essential procps file \
    wget software-properties-common \
    ca-certificates lsb-release gnupg gpg \
    libnss3-tools unzip

sudo systemctl enable --now ssh
sudo systemctl is-active ssh > /dev/null 2>&1 || echo "Note: SSH service status unknown"

# --- REGION: https://yuruna.link/network#apt-signing-key-fingerprint-verification
# arg1 = key file; remaining args = ALLOWED primary fingerprints, FIRST also required.
_yuruna_verify_key_fpr() {
    local keyfile="$1"; shift
    local required="${1^^}" allowed=("$@") present a fpr ok found=0
    present="$(gpg --show-keys --with-colons "$keyfile" 2>/dev/null \
              | awk -F: '/^pub:/{p=1} /^fpr:/{if(p){print toupper($10); p=0}}')"
    [ -n "$present" ] || { echo "!! key verify: no primary key fingerprints in $keyfile (is gpg installed?)" >&2; return 1; }
    while IFS= read -r fpr; do
        fpr="${fpr//[$'\r\n\t ']/}"; [ -z "$fpr" ] && continue
        ok=0; for a in "${allowed[@]}"; do [ "${a^^}" = "$fpr" ] && { ok=1; break; }; done
        [ "$ok" = 1 ] || { echo "!! key verify: unexpected fingerprint $fpr in $keyfile (not in the pinned allow-set)" >&2; return 1; }
        [ "$fpr" = "$required" ] && found=1
    done <<< "$present"
    [ "$found" = 1 ] || { echo "!! key verify: required fingerprint $required missing from $keyfile" >&2; return 1; }
    echo "  key verify: OK ($keyfile)"
}

echo ""
echo -e "\e[1;36m==== Docker ====\e[0m"
sudo install -m 0755 -d /etc/apt/keyrings
_dk="$(mktemp)"
curl_retry -fsSL "https://download.docker.com/linux/ubuntu/gpg${YurunaCacheContent:+?nocache=${YurunaCacheContent}}" -o "$_dk"
_yuruna_verify_key_fpr "$_dk" 9DC858229FC7DD38854AE2D88D81803C0EBFCD88 \
    || { echo "NONZERO SCRIPT EXIT: docker apt key fingerprint mismatch" >&2; rm -f "$_dk"; exit 1; }
sudo install -m 0644 "$_dk" /etc/apt/keyrings/docker.asc
rm -f "$_dk"

sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

# --- REGION: https://yuruna.link/memory#why-the-k8s-guest-configures-the-docker-registry-mirror-before-installing-docker-ce
# CACHE_HOST is parsed from $http_proxy (set system-wide by the
# guest's cloud-init late-commands). Fallback: the well-known cache
# VM hostname, resolvable on the LAN where Start-CachingProxy ran.
CACHE_HOST=$(echo "${http_proxy:-}" | sed -E 's|^https?://([^:/]+).*|\1|')
[ -z "$CACHE_HOST" ] && CACHE_HOST="yuruna-caching-proxy"
sudo install -d -m 0755 /etc/docker
sudo tee /etc/docker/daemon.json >/dev/null <<EOF
{
  "registry-mirrors": ["http://${CACHE_HOST}:5000"],
  "insecure-registries": ["${CACHE_HOST}:5000"]
}
EOF

# Write the Kubernetes repo HERE so the single `apt-get update` below
# refreshes both Docker and K8s indices in one shot. K8s packages are
# installed later but the index is cheap to carry.
_kk="$(mktemp)"
curl_retry -fsSL "https://pkgs.k8s.io/core:/stable:/v${YURUNA_K8S_MINOR}/deb/Release.key${YurunaCacheContent:+?nocache=${YurunaCacheContent}}" -o "$_kk"
_yuruna_verify_key_fpr "$_kk" DE15B14486CD377B9E876E1A234654DA9A296436 \
    || { echo "NONZERO SCRIPT EXIT: kubernetes apt key fingerprint mismatch" >&2; rm -f "$_kk"; exit 1; }
sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg "$_kk"
rm -f "$_kk"
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${YURUNA_K8S_MINOR}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null

apt_retry sudo apt-get update -y
apt_retry sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Docker service starts automatically after installation;
# enable + start as a safety net, tolerating errors in environments where systemd is not fully available
sudo systemctl enable docker 2>/dev/null || echo "Note: systemctl enable docker skipped (systemd may not be available)"
sudo systemctl start docker 2>/dev/null || echo "Note: systemctl start docker skipped (systemd may not be available)"
sudo systemctl is-active docker > /dev/null 2>&1 || echo "Note: Docker service status unknown"

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

docker version > /dev/null 2>&1 && echo "Docker engine is responding" || echo "Note: Docker engine not responding yet - may need service restart or reboot"

echo ""
echo -e "\e[1;36m==== Swap disabled ====\e[0m"
sudo sed -i '/ swap / s/^/#/' /etc/fstab
sudo swapoff -a || true

echo ""
echo -e "\e[1;36m==== Docker up ====\e[0m"
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

echo ""
echo -e "\e[1;36m==== K8S ====\e[0m"
# K8s repo + keyring already written next to the Docker source above so a
# single apt-get update covers both.
apt_retry sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

# --- REGION: https://yuruna.link/definition#defining-containerd-hoststoml-cache-mirror
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo sed -i 's|^\(\s*config_path\s*=\s*\)""|\1"/etc/containerd/certs.d"|' /etc/containerd/config.toml
sudo mkdir -p /etc/containerd/certs.d/docker.io \
              /etc/containerd/certs.d/registry.k8s.io \
              /etc/containerd/certs.d/public.ecr.aws
sudo tee /etc/containerd/certs.d/docker.io/hosts.toml > /dev/null <<HOSTSEOF
server = "https://docker.io"

[host."http://${CACHE_HOST}:5000"]
  capabilities = ["pull", "resolve"]
HOSTSEOF
sudo tee /etc/containerd/certs.d/registry.k8s.io/hosts.toml > /dev/null <<HOSTSEOF
server = "https://registry.k8s.io"

[host."http://${CACHE_HOST}:5000"]
  capabilities = ["pull", "resolve"]
HOSTSEOF
# public.ecr.aws can return transient HTTP errors that bubble up as 4xx
# from `registry:2`. Mirroring it via zot means the cached copy is served
# whenever the upstream has an image-specific hiccup, instead of fronting
# the upstream's failure.
sudo tee /etc/containerd/certs.d/public.ecr.aws/hosts.toml > /dev/null <<HOSTSEOF
server = "https://public.ecr.aws"

[host."http://${CACHE_HOST}:5000"]
  capabilities = ["pull", "resolve"]
HOSTSEOF
sudo systemctl enable containerd
sudo systemctl restart containerd

# Pre-pull the kubeadm control-plane images through the zot mirror so the
# subsequent `kubeadm init` lands fully cache-warm. Must run AFTER the
# containerd mirror config above; otherwise the pulls bypass the cache
# and hit upstream directly.
# Best-effort: `kubeadm init` does its own pull check if this fails.
sudo kubeadm config images pull || echo "Note: kubeadm images pull may need to be run after kubeadm init"

# Reset any existing kubeadm state so the script can be re-run safely
# Reference: https://k8s.io/docs/reference/setup-tools/kubeadm/kubeadm-reset/
if [ -f /etc/kubernetes/manifests/kube-apiserver.yaml ] || [ -d /etc/kubernetes/pki ]; then
    echo "Existing Kubernetes cluster detected — resetting before re-initialization"
    sudo kubeadm reset -f --cri-socket unix:///var/run/containerd/containerd.sock
    sudo rm -rf /etc/cni/net.d
    # Clean up network filtering rules left by the previous cluster
    sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X || true
    if command -v ipvsadm &>/dev/null; then
        sudo ipvsadm --clear || true
    fi
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

# kubeadm init is the most failure-prone step (control-plane image pulls, etcd
# bring-up, kubelet handshake): a single transient blip on a shared-NAT guest
# can leave a half-initialized control plane and abort the whole sequence.
# Retry with a full reset between attempts so a transient failure self-heals.
kubeadm_init_ok=false
for kubeadm_attempt in 1 2 3; do
    if sudo kubeadm init --pod-network-cidr=10.244.0.0/16; then
        kubeadm_init_ok=true
        break
    fi
    echo "kubeadm init attempt ${kubeadm_attempt}/3 failed."
    if [ "$kubeadm_attempt" -lt 3 ]; then
        echo "Resetting kubeadm state before retry..."
        sudo kubeadm reset -f --cri-socket unix:///var/run/containerd/containerd.sock || true
        sudo rm -rf /etc/cni/net.d
        sudo systemctl restart containerd || true
        for i in $(seq 1 30); do
            if sudo crictl --runtime-endpoint unix:///var/run/containerd/containerd.sock info &>/dev/null; then break; fi
            sleep 1
        done
        sleep $((kubeadm_attempt * 10))
    fi
done
if [ "$kubeadm_init_ok" != true ]; then
    echo "ERROR: kubeadm init failed after 3 attempts; aborting." >&2
    exit 1
fi

mkdir -p "${REAL_HOME}/.kube"
sudo cp /etc/kubernetes/admin.conf "${REAL_HOME}/.kube/config"
sudo chown "$REAL_USER:$REAL_USER" "${REAL_HOME}/.kube/config"
export KUBECONFIG="${REAL_HOME}/.kube/config"

FLANNEL_MANIFEST=/tmp/kube-flannel.yml
# --- REGION: https://yuruna.link/memory#why-the-k8s-guest-fetches-the-flannel-manifest-from-the-in-tree-path-at-the-latest-release-tag
FLANNEL_TAG="$(curl_retry -fsSI "https://github.com/flannel-io/flannel/releases/latest${YurunaCacheContent:+?nocache=${YurunaCacheContent}}" \
    | tr -d '\r' | awk 'tolower($1)=="location:"{n=split($2,a,"/"); print a[n]}')"
if [ -z "$FLANNEL_TAG" ]; then
    echo "ERROR: Could not resolve the latest flannel release tag from github.com/flannel-io/flannel" >&2
    exit 1
fi
if ! curl_retry -fsSL "https://raw.githubusercontent.com/flannel-io/flannel/${FLANNEL_TAG}/Documentation/kube-flannel.yml" -o "$FLANNEL_MANIFEST"; then
    echo "ERROR: Failed to download kube-flannel.yml for flannel ${FLANNEL_TAG} from raw.githubusercontent.com" >&2
    exit 1
fi
if [ ! -s "$FLANNEL_MANIFEST" ]; then
    echo "ERROR: Downloaded kube-flannel.yml at $FLANNEL_MANIFEST is missing or empty" >&2
    exit 1
fi
if ! kubectl --kubeconfig="${REAL_HOME}/.kube/config" apply -f "$FLANNEL_MANIFEST"; then
    echo "ERROR: Failed to apply Flannel manifest $FLANNEL_MANIFEST to the cluster" >&2
    exit 1
fi

# Wait for Flannel DaemonSet pods to be ready before proceeding
echo ""
echo "==== Flannel DaemonSet Status ===="
echo "Waiting for Flannel pods to be ready..."
sleep 15
kubectl --kubeconfig="${REAL_HOME}/.kube/config" -n kube-flannel rollout status daemonset/kube-flannel-ds --timeout=180s \
    || echo "Note: Flannel rollout status check timed out — pods may still be starting"

# Wait for the node to report Ready (networking must be up for this to succeed)
echo "Waiting for node to be Ready..."
kubectl --kubeconfig="${REAL_HOME}/.kube/config" wait --for=condition=ready node --all --timeout=180s \
    || echo "Note: Node ready wait timed out — node may still be initializing"

# Remove control-plane taint for single-node cluster
kubectl --kubeconfig="${REAL_HOME}/.kube/config" taint nodes --all node-role.kubernetes.io/control-plane- || true

kubectl --kubeconfig="${REAL_HOME}/.kube/config" config rename-context kubernetes-admin@kubernetes docker-desktop || true

echo ""
echo -e "\e[1;36m==== Helm ====\e[0m"
# --- REGION: https://yuruna.link/network#helm-installer-fetch
# get-helm-4, never get-helm-3 (the v3 installer can only ever land a 3.x binary).
curl_retry -fsSL "https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4${YurunaCacheContent:+?nocache=${YurunaCacheContent}}" -o /tmp/get-helm-4.sh
chmod +x /tmp/get-helm-4.sh
DESIRED_VERSION="v${YURUNA_HELM_VERSION}" _yuruna_retry helm_install /tmp/get-helm-4.sh || true
rm -f /tmp/get-helm-4.sh
if ! assert_tool_runnable helm version --short; then
    echo "ERROR: Helm install failed; downstream chart-based workloads (helm repo add / upgrade) will fail at Set-Workload." >&2
    exit 1
fi

# --- REGION: https://yuruna.link/memory#why-the-k8s-guest-wraps-the-opentofu-install-in-a-retry-with-a-pinned-version
echo ""
echo -e "\e[1;36m==== OpenTofu ====\e[0m"
curl_retry --proto '=https' --tlsv1.2 -fsSL "https://get.opentofu.org/install-opentofu.sh${YurunaCacheContent:+?nocache=${YurunaCacheContent}}" -o /tmp/install-opentofu.sh
chmod +x /tmp/install-opentofu.sh
if ! _yuruna_retry opentofu_deb /tmp/install-opentofu.sh --install-method deb --opentofu-version "$YURUNA_OPENTOFU_VERSION"; then
    echo "WARNING: OpenTofu deb install failed (often a GPG-key fetch from get.opentofu.org). Falling back to standalone method..."
    _yuruna_retry opentofu_standalone /tmp/install-opentofu.sh --install-method standalone --opentofu-version "$YURUNA_OPENTOFU_VERSION" || true
fi
rm -f /tmp/install-opentofu.sh
if ! command -v tofu >/dev/null 2>&1; then
    echo "ERROR: OpenTofu install failed via both deb and standalone methods."
    echo "Downstream Set-Resource steps rely on 'tofu'; aborting early rather than failing silently at the ingress check."
    exit 1
fi

# mkcert: prefer the upstream binary from dl.filippo.io (302-redirector to
# github.com/FiloSottile/mkcert releases). That endpoint can return transient
# 5xx responses that, under `set -euo pipefail`, would abort the entire
# k8s.website sequence. Retry 3x with backoff, then fall back to Ubuntu
# universe's mkcert package, and only exit if both paths fail.
echo ""
echo -e "\e[1;36m==== mkcert ====\e[0m"
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
    MKCERT_URL="https://dl.filippo.io/mkcert/latest?for=${MKCERT_ARCH}${YurunaCacheContent:+&nocache=${YurunaCacheContent}}"
    MKCERT_INSTALLED=false
    if curl_retry -fsSL "$MKCERT_URL" -o /tmp/mkcert && [ -s /tmp/mkcert ]; then
        chmod +x /tmp/mkcert
        sudo mv /tmp/mkcert /usr/local/bin/mkcert
        MKCERT_INSTALLED=true
    else
        rm -f /tmp/mkcert
        echo "WARNING: dl.filippo.io fetch failed. Falling back to apt mkcert (Ubuntu universe)..."
        if apt_retry sudo apt-get install -y mkcert; then
            MKCERT_INSTALLED=true
        fi
    fi
    if [ "$MKCERT_INSTALLED" = false ]; then
        echo "ERROR: mkcert install failed via both dl.filippo.io fetch and apt fallback." >&2
        exit 1
    fi
    if ! assert_tool_runnable mkcert -version; then
        echo "ERROR: mkcert installed but is not runnable; Set-Resource/Set-Workload's runtime pre-flight will refuse to deploy." >&2
        exit 1
    fi
    # Run mkcert -install as the actual user (not root) so rootCA.pem
    # lands in their $HOME/.local/share/mkcert, regardless of whether
    # this script was invoked directly or via sudo.
    TARGET_USER="${SUDO_USER:-$USER}"
    sudo -u "$TARGET_USER" -H mkcert -install || true
fi

echo ""
echo -e "\e[1;36m==== HTTPS development certificate ====\e[0m"
PFX_DIR="${REAL_HOME}/.aspnet/https"
mkdir -p "$PFX_DIR"
openssl req -x509 -newkey rsa:4096 -keyout "$PFX_DIR/aspnetapp.key" -out "$PFX_DIR/aspnetapp.crt" -days 365 -nodes -subj '/CN=localhost' 2>/dev/null
openssl pkcs12 -export -out "$PFX_DIR/aspnetapp.pfx" -inkey "$PFX_DIR/aspnetapp.key" -in "$PFX_DIR/aspnetapp.crt" -password pass:password
rm -f "$PFX_DIR/aspnetapp.key" "$PFX_DIR/aspnetapp.crt"
# Ensure the real user owns the certificate files (not root)
chown -R "$REAL_USER:$REAL_USER" "$PFX_DIR"

echo ""
echo "== Installation Summary =="
docker --version
git --version
kubeadm version || true
kubectl version --client || true
pwsh --version 2>/dev/null || echo "PowerShell - run: pwsh --version"
helm version --short 2>/dev/null || echo "Helm - run: helm version --short"
tofu version | head -1 || true
mkcert -version 2>/dev/null || echo "mkcert - run: mkcert -version"

echo ""
echo "== Optional Steps =="
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

