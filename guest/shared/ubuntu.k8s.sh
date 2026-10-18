#!/bin/bash
# Version: 2026.10.14
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# --- REGION: Initialize environment
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NONINTERACTIVE=1

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

# --- REGION: Detect architecture
ARCH=$(uname -m)
echo "Detected architecture: $ARCH"
# See https://yuruna.link/42e220c4-0005
# Detect virtualization independently from CPU architecture.
echo "Detected virtualization: $(systemd-detect-virt 2>/dev/null || echo unknown)"
case "$ARCH" in
  x86_64)
    echo "Environment: x86_64/amd64"
    ;;
  aarch64)
    echo "Environment: aarch64/arm64"
    ;;
  *)
    echo "WARNING: Unsupported architecture: $ARCH"
    echo "This script supports x86_64/amd64 and aarch64/arm64."
    exit 1
    ;;
esac

# --- REGION: Load retry helpers
# See https://yuruna.link/4220a755-0003
. /usr/local/lib/yuruna/yuruna-retry.sh
# --- REGION: https://yuruna.link/4220a755-0005
# Re-asserted here because a baked retry lib may still carry a wall-clock bound.
export YURUNA_APT_STALL_TIMEOUT_SECONDS=0

# --- REGION: Assert an installed tool is runnable
# See https://yuruna.link/42e220c4-0005
assert_tool_runnable() {
    local name="$1"; shift
    local path version
    path="$(command -v "$name" 2>/dev/null || true)"
    if [ -z "$path" ]; then
        echo "ERROR: '$name' is not on PATH after install." >&2
        return 1
    fi
    if [ ! -s "$path" ]; then
        echo "ERROR: '$name' at $path is a ZERO-LENGTH file (truncated download, or a lost write)." >&2
        return 1
    fi
    if ! version=$("$name" "$@" 2>/dev/null) || [ -z "$version" ]; then
        echo "ERROR: '$name' at $path failed or produced no output for: $name $*" >&2
        return 1
    fi
    return 0
}

# --- REGION: Wait for the containerd CRI API
wait_for_containerd() {
    local wait_seconds="${1:-30}" crictl_path timeout_path probe_log
    local deadline remaining probe_seconds last_rc=0
    crictl_path="$(command -v crictl 2>/dev/null || true)"
    timeout_path="$(command -v timeout 2>/dev/null || true)"
    if [ -z "$crictl_path" ] || [ -z "$timeout_path" ]; then
        echo "ERROR: containerd readiness requires installed cri-tools (crictl) and coreutils (timeout)." >&2
        return 1
    fi
    probe_log="$(mktemp)" || return 1
    deadline=$((SECONDS + wait_seconds))
    while [ "$SECONDS" -lt "$deadline" ]; do
        remaining=$((deadline - SECONDS))
        [ "$remaining" -gt 0 ] || break
        probe_seconds=$remaining
        [ "$probe_seconds" -le 5 ] || probe_seconds=5
        # Resolve both paths before sudo; a restricted root PATH must not hide the probe.
        # timeout owns the probe process group so a stalled CRI call cannot outlive the wait.
        # The caller owns this temporary diagnostic file; only the probe needs root.
        # shellcheck disable=SC2024
        if sudo "$timeout_path" --kill-after=1 "$probe_seconds" "$crictl_path" \
            --runtime-endpoint unix:///var/run/containerd/containerd.sock info >"$probe_log" 2>&1; then
            rm -f "$probe_log"
            echo "containerd CRI API is ready"
            return 0
        else
            last_rc=$?
        fi
        remaining=$((deadline - SECONDS))
        [ "$remaining" -gt 0 ] || break
        echo "Waiting for containerd CRI API... (${remaining}s left)"
        sleep 1
    done
    echo "ERROR: containerd CRI API did not become ready within ${wait_seconds}s (last probe exit: ${last_rc})." >&2
    tail -c 8192 "$probe_log" >&2 || true
    rm -f "$probe_log"
    return 1
}

# --- REGION: Wait for Kubernetes networking
wait_for_kubernetes_network() {
    echo ""
    echo "==== Flannel DaemonSet Status ===="
    echo "Waiting for Flannel pods to be ready..."
    kubectl --kubeconfig="${REAL_HOME}/.kube/config" -n kube-flannel rollout status daemonset/kube-flannel-ds --timeout=180s \
        || echo "Note: Flannel rollout status check timed out -- pods may still be starting"

    # A NotReady node cannot run downstream workloads; fail in this script.
    echo "Waiting for node to be Ready..."
    if ! kubectl --kubeconfig="${REAL_HOME}/.kube/config" wait --for=condition=ready node --all --timeout=180s; then
        echo "ERROR: node did not reach Ready within 180s; the CNI plugin never initialized." >&2
        # The three facts that identify the usual cause (a stalled flannel image
        # pull) without needing a post-mortem diagnostic dump.
        kubectl --kubeconfig="${REAL_HOME}/.kube/config" get nodes -o wide >&2 || true
        kubectl --kubeconfig="${REAL_HOME}/.kube/config" -n kube-flannel get pods -o wide >&2 || true
        echo "Contents of /etc/cni/net.d (empty means no CNI config was installed):" >&2
        ls -A /etc/cni/net.d >&2 || true
        exit 1
    fi
}

echo "== Installing Kubernetes requirements for Ubuntu =="

# --- REGION: Install basic tools
echo ""
echo -e "\e[1;36m==== Basic tools ====\e[0m"
apt_retry sudo apt-get update -y
# See https://yuruna.link/42e220c4-000e
# Install Kubernetes prerequisites directly; packaged binaries need no compiler toolchain.
apt_retry sudo apt-get install -y \
    ssh net-tools apt-transport-https curl git \
    procps file \
    wget software-properties-common \
    ca-certificates lsb-release gnupg gpg \
    libnss3-tools unzip socat

sudo systemctl enable --now ssh
sudo systemctl is-active ssh > /dev/null 2>&1 || echo "Note: SSH service status unknown"

# --- REGION: https://yuruna.link/4220a755-001e
# arg1 = key file; remaining args = ALLOWED primary fingerprints, FIRST also required.
if ! command -v _yuruna_verify_key_fpr >/dev/null 2>&1; then
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
fi

# --- REGION: Install Docker
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

# --- REGION: https://yuruna.link/42d69dfa-0042
# See https://yuruna.link/42e220c4-0005
CACHE_HOST=$(echo "${http_proxy:-}" | sed -E 's|^https?://([^:/]+).*|\1|')
if [ -z "$CACHE_HOST" ] && [ -r /etc/yuruna/host.env ]; then
    CACHE_HOST=$(sed -nE 's/^YURUNA_CACHING_PROXY_SERVICE_IP=([^[:space:]]+).*/\1/p' /etc/yuruna/host.env | head -n1)
fi
if [ -z "$CACHE_HOST" ] \
   && curl -fsS --max-time 10 -o /dev/null "http://yuruna-caching-proxy-service:5000/v2/" 2>/dev/null; then
    CACHE_HOST="yuruna-caching-proxy-service"
fi
if [ -n "$CACHE_HOST" ]; then
    echo "Caching proxy: ${CACHE_HOST} -- container image pulls are mirrored through it."
    sudo install -d -m 0755 /etc/docker
    sudo tee /etc/docker/daemon.json >/dev/null <<EOF
{
  "registry-mirrors": ["http://${CACHE_HOST}:5000"],
  "insecure-registries": ["${CACHE_HOST}:5000"]
}
EOF
else
    echo "Caching proxy: none in this lab -- container image pulls go to the upstreams directly."
fi

# See https://yuruna.link/42e220c4-000e
# Write both package sources before the shared index refresh.
_kk="$(mktemp)"
curl_retry -fsSL "https://pkgs.k8s.io/core:/stable:/v${YURUNA_K8S_MINOR}/deb/Release.key${YurunaCacheContent:+?nocache=${YurunaCacheContent}}" -o "$_kk"
_yuruna_verify_key_fpr "$_kk" DE15B14486CD377B9E876E1A234654DA9A296436 \
    || { echo "NONZERO SCRIPT EXIT: kubernetes apt key fingerprint mismatch" >&2; rm -f "$_kk"; exit 1; }
sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg "$_kk"
rm -f "$_kk"
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${YURUNA_K8S_MINOR}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null

apt_retry sudo apt-get update -y
apt_retry sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Docker starts automatically after install; enable + start as a safety net,
# tolerating environments where systemd is not fully available.
sudo systemctl enable docker 2>/dev/null || echo "Note: systemctl enable docker skipped (systemd may not be available)"
sudo systemctl start docker 2>/dev/null || echo "Note: systemctl start docker skipped (systemd may not be available)"
sudo systemctl is-active docker > /dev/null 2>&1 || echo "Note: Docker service status unknown"

if ! getent group docker > /dev/null 2>&1; then
    sudo groupadd docker
fi
sudo usermod -aG docker "$REAL_USER" 2>/dev/null || echo "Note: Could not add user to docker group"

# See https://yuruna.link/42e220c4-0005
# Activate Docker membership once per shell; the group guard prevents recursive newgrp.
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

# --- REGION: Disable swap
echo ""
echo -e "\e[1;36m==== Swap disabled ====\e[0m"
sudo sed -i '/ swap / s/^/#/' /etc/fstab
sudo swapoff -a || true

# --- REGION: Wait for Docker
echo ""
echo -e "\e[1;36m==== Docker up ====\e[0m"
DOCKER_WAIT_SECONDS=60
DOCKER_READY=false
# See https://yuruna.link/42e220c4-000e
# Use a deadline so probe execution time counts toward the wait budget.
docker_deadline=$(( $(date +%s) + DOCKER_WAIT_SECONDS ))
while true; do
    if sudo systemctl is-active docker &>/dev/null; then
        DOCKER_READY=true
        echo "Docker is up and running."
        break
    fi
    _now=$(date +%s)
    [ "$_now" -ge "$docker_deadline" ] && break
    echo "Waiting for Docker daemon to be ready... ($(( docker_deadline - _now ))s left)"
    sleep 1
done

if [ "$DOCKER_READY" = false ]; then
    echo ""
    echo -e "\e[1;31m+========+\e[0m"
    echo -e "\e[1;31m|  ERROR: Docker daemon is not responding after ${DOCKER_WAIT_SECONDS}s               |\e[0m"
    echo -e "\e[1;31m+========+\e[0m"
    echo -e "\e[1;31m|  Kubernetes requires Docker to be running. Try the following:      |\e[0m"
    echo -e "\e[1;31m|                                                                    |\e[0m"
    echo -e "\e[1;31m|  1. Start Docker manually:                                         |\e[0m"
    echo -e "\e[1;31m|     sudo systemctl start docker                                    |\e[0m"
    echo -e "\e[1;31m|                                                                    |\e[0m"
    echo -e "\e[1;31m|  2. Check Docker status and logs:                                  |\e[0m"
    echo -e "\e[1;31m|     sudo systemctl status docker                                   |\e[0m"
    echo -e "\e[1;31m|     sudo journalctl -xeu docker.service                            |\e[0m"
    echo -e "\e[1;31m|                                                                    |\e[0m"
    echo -e "\e[1;31m|  3. If systemd is not available (e.g. WSL), start dockerd:         |\e[0m"
    echo -e "\e[1;31m|     sudo dockerd &                                                 |\e[0m"
    echo -e "\e[1;31m|                                                                    |\e[0m"
    echo -e "\e[1;31m|  Once Docker is running, re-run this script to continue setup.     |\e[0m"
    echo -e "\e[1;31m+========+\e[0m"
    echo ""
    exit 1
fi

# --- REGION: Install Kubernetes
echo ""
echo -e "\e[1;36m==== K8S ====\e[0m"
# K8s repo + keyring already written next to the Docker source above so a
# single apt-get update covers both.
apt_retry sudo apt-get install -y kubelet kubeadm kubectl cri-tools
sudo apt-mark hold kubelet kubeadm kubectl cri-tools
assert_tool_runnable crictl --version

# --- REGION: https://yuruna.link/42fa6f45-0011
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
# See https://yuruna.link/42e220c4-000e
# Assert the cgroup driver; containerd#12101 omitted the generated key.
if ! grep -q 'SystemdCgroup = true' /etc/containerd/config.toml; then
    echo "ERROR: containerd SystemdCgroup was not set to true; the cgroup driver would not match kubelet." >&2
    exit 1
fi
# See https://yuruna.link/42d69dfa-0042
# Configure cache-only pulls only when a caching proxy is selected.
if [ -n "$CACHE_HOST" ]; then
    # --- REGION: https://yuruna.link/42e220c4-0005
    sudo sed -i "s|^\(\s*config_path\s*=\s*\).*|\1'/etc/containerd/certs.d'|" /etc/containerd/config.toml
    if ! grep -qE "^\s*config_path\s*=\s*'/etc/containerd/certs.d'\s*$" /etc/containerd/config.toml; then
        echo "ERROR: containerd registry config_path was not set to /etc/containerd/certs.d; pulls would bypass the cache." >&2
        exit 1
    fi
    sudo mkdir -p /etc/containerd/certs.d/docker.io \
                  /etc/containerd/certs.d/registry.k8s.io \
                  /etc/containerd/certs.d/public.ecr.aws \
                  /etc/containerd/certs.d/ghcr.io \
                  /etc/containerd/certs.d/mcr.microsoft.com
    # See https://yuruna.link/42d69dfa-0042
    # Both server and [host] must name the cache to preserve namespace routing.
    sudo tee /etc/containerd/certs.d/docker.io/hosts.toml > /dev/null <<HOSTSEOF
server = "http://${CACHE_HOST}:5000"

[host."http://${CACHE_HOST}:5000"]
  capabilities = ["pull", "resolve"]
HOSTSEOF
    sudo tee /etc/containerd/certs.d/registry.k8s.io/hosts.toml > /dev/null <<HOSTSEOF
server = "http://${CACHE_HOST}:5000"

[host."http://${CACHE_HOST}:5000"]
  capabilities = ["pull", "resolve"]
HOSTSEOF
    # See https://yuruna.link/42d69dfa-0042
    # Serve cached ECR images through upstream HTTP failures.
    sudo tee /etc/containerd/certs.d/public.ecr.aws/hosts.toml > /dev/null <<HOSTSEOF
server = "http://${CACHE_HOST}:5000"

[host."http://${CACHE_HOST}:5000"]
  capabilities = ["pull", "resolve"]
HOSTSEOF
    # Route Flannel's ghcr.io images through the same cache.
    sudo tee /etc/containerd/certs.d/ghcr.io/hosts.toml > /dev/null <<HOSTSEOF
server = "http://${CACHE_HOST}:5000"

[host."http://${CACHE_HOST}:5000"]
  capabilities = ["pull", "resolve"]
HOSTSEOF
    # --- REGION: https://yuruna.link/42e220c4-0005
    sudo tee /etc/containerd/certs.d/mcr.microsoft.com/hosts.toml > /dev/null <<HOSTSEOF
server = "http://${CACHE_HOST}:5000"

[host."http://${CACHE_HOST}:5000"]
  capabilities = ["pull", "resolve"]
HOSTSEOF
    # See https://yuruna.link/42e220c4-0005
    cache_wait="${YURUNA_CACHE_WAIT_SECONDS:-180}"
    cache_started=$SECONDS
    cache_err=""
    # Vary progress output so console OCR can distinguish progress from a wedge.
    until cache_err=$(curl -fsS --max-time 15 -o /dev/null "http://${CACHE_HOST}:5000/v2/" 2>&1); do
        cache_elapsed=$(( SECONDS - cache_started ))
        if [ "$cache_elapsed" -ge "$cache_wait" ]; then
            echo "ERROR: the caching proxy's registry did not answer at ${CACHE_HOST}:5000" >&2
            echo "       within ${cache_wait}s: ${cache_err}" >&2
            echo "       containerd is configured to pull only from it -- reaching the" >&2
            echo "       upstreams directly from a guest is rate limited and fails anyway." >&2
            echo "       Check that the caching proxy VM is up and zot is serving:" >&2
            echo "           curl -fsS http://${CACHE_HOST}:5000/v2/" >&2
            exit 1
        fi
        echo "  ${CACHE_HOST}:5000 not answering after ${cache_elapsed}s; it may be restarting (waiting up to ${cache_wait}s)"
        sleep 15
    done
    # --- REGION: https://yuruna.link/42f6b05f-0020
    # Read published cache health without spending an upstream pull; advisory only.
    if cache_health=$(curl -fsS --max-time 5 "http://${CACHE_HOST}/cache-health" 2>/dev/null); then
        echo "Cache health, as published by ${CACHE_HOST}:"
        printf '%s\n' "$cache_health" | sed 's/^/  /'
    else
        echo "Note: ${CACHE_HOST} publishes no cache-health page; only its /v2/ liveness was checked here,"
        echo "      which stays green through a manifest stall."
    fi
fi
# Bound no-progress pulls so kubelet can retry within the rollout window.
CONTAINERD_PULL_PROGRESS_TIMEOUT="120s"
if grep -q 'image_pull_progress_timeout' /etc/containerd/config.toml; then
    sudo sed -i "s|^\(\s*image_pull_progress_timeout\s*=\s*\).*|\1'${CONTAINERD_PULL_PROGRESS_TIMEOUT}'|" /etc/containerd/config.toml
else
    echo "Note: containerd config has no image_pull_progress_timeout key; leaving the built-in default in place"
fi
sudo systemctl enable containerd
sudo systemctl restart containerd

# --- REGION: https://yuruna.link/42f6b05f-0020
YURUNA_IMAGE_WARM_BUDGET="${YURUNA_IMAGE_WARM_BUDGET:-900}"
# See https://yuruna.link/42f6b05f-0020
# Capture one HTTP status per attempt; the shared wrapper would concatenate them.
YURUNA_IMAGE_WARM_ATTEMPTS="${YURUNA_IMAGE_WARM_ATTEMPTS:-3}"
YURUNA_IMAGE_WARM_RETRY_PAUSE="${YURUNA_IMAGE_WARM_RETRY_PAUSE:-2}"
# The digest of this guest's platform in a manifest index; nothing for a
# single-platform manifest, an error body, or a body that does not parse.
yuruna_warm_child() {
    python3 -c 'import json, sys
try:
    manifests = json.load(open(sys.argv[1])).get("manifests") or []
except Exception:
    manifests = []
for entry in manifests:
    platform = entry.get("platform") or {}
    if platform.get("os") == "linux" and platform.get("architecture") == sys.argv[2]:
        print(entry.get("digest", ""))
        break' "$1" "$_wr_arch" 2>/dev/null || true
}
yuruna_warm_refs() {
    _wr_label=$1
    shift
    yuruna_warm_total=0
    yuruna_warm_missing=0
    # Keep budget exhaustion separate from attempted-request errors.
    yuruna_warm_unattempted=0
    yuruna_warm_errored=0
    # A response status is cache evidence; a silent transport failure is not.
    yuruna_warm_silent=0
    _wr_start=$(date +%s)
    _wr_deadline=$(( _wr_start + YURUNA_IMAGE_WARM_BUDGET ))
    # Preserve curl transport text for per-reference diagnostics.
    _wr_errlog=$(mktemp)
    _wr_body=$(mktemp)
    _wr_arch=$(dpkg --print-architecture 2>/dev/null || echo amd64)
    # See https://yuruna.link/42f6b05f-0020
    # Request image indexes and manifests explicitly so the warm pass covers real pulls.
    _wr_accept='application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'
    echo "== Warming the ${_wr_label} image set through ${CACHE_HOST}:5000 (budget ${YURUNA_IMAGE_WARM_BUDGET}s) =="
    for _wr_ref in "$@"; do
        yuruna_warm_total=$((yuruna_warm_total + 1))
        _wr_upstream=${_wr_ref%%/*}
        _wr_rest=${_wr_ref#*/}
        _wr_tag=${_wr_rest##*:}
        _wr_repo=${_wr_rest%:*}
        _wr_left=$(( _wr_deadline - $(date +%s) ))
        if [ "$_wr_left" -le 0 ]; then
            yuruna_warm_missing=$((yuruna_warm_missing + 1))
            yuruna_warm_unattempted=$((yuruna_warm_unattempted + 1))
            printf '  %-52s       not attempted (warm budget spent)\n' "${_wr_repo}:${_wr_tag}"
            continue
        fi
        _wr_t0=$(date +%s)
        # Exclude intentional retry sleeps from measured cache latency.
        _wr_slept=0
        : > "$_wr_errlog"
        # First the tag, then this guest's platform in it. On-demand sync
        # stores a multi-arch tag as its index alone and copies a platform's
        # manifest and layers only when that child is asked for by digest, so
        # an answered tag says nothing about the layers kubeadm pulls next.
        _wr_reference=$_wr_tag
        _wr_leg=''
        _wr_attempt_max=0
        while :; do
            : > "$_wr_body"
            _wr_attempt=0
            _wr_code=''
            _wr_rc=0
            while [ "$_wr_attempt" -lt "$YURUNA_IMAGE_WARM_ATTEMPTS" ]; do
                _wr_attempt=$((_wr_attempt + 1))
                # Recomputed every attempt, so the ladder is charged against the
                # same budget the caller was promised and cannot outlive it.
                _wr_left=$(( _wr_deadline - $(date +%s) ))
                if [ "$_wr_left" -le 0 ]; then break; fi
                _wr_rc=0
                # --- REGION: https://yuruna.link/42e220c4-0005
                _wr_code=$(curl -sS -o "$_wr_body" --max-time "$_wr_left" -w '%{http_code}' \
                    -H "Accept: ${_wr_accept}" \
                    "http://${CACHE_HOST}:5000/v2/${_wr_repo}/manifests/${_wr_reference}?ns=${_wr_upstream}" 2>>"$_wr_errlog") || _wr_rc=$?
                # Retry only silent transport failures; a received status is definitive.
                if [ -n "$_wr_code" ] && [ "$_wr_code" != "000" ]; then break; fi
                if [ "$_wr_attempt" -ge "$YURUNA_IMAGE_WARM_ATTEMPTS" ]; then break; fi
                _wr_left=$(( _wr_deadline - $(date +%s) ))
                if [ "$_wr_left" -le "$YURUNA_IMAGE_WARM_RETRY_PAUSE" ]; then break; fi
                sleep "$YURUNA_IMAGE_WARM_RETRY_PAUSE"
                _wr_slept=$(( _wr_slept + YURUNA_IMAGE_WARM_RETRY_PAUSE ))
            done
            if [ "$_wr_attempt" -gt "$_wr_attempt_max" ]; then _wr_attempt_max=$_wr_attempt; fi
            if [ -z "$_wr_leg" ] && [ "$_wr_code" = "200" ]; then
                _wr_child=$(yuruna_warm_child "$_wr_body")
                if [ -n "$_wr_child" ]; then
                    _wr_reference=$_wr_child
                    _wr_leg="linux/${_wr_arch} manifest "
                    continue
                fi
            fi
            break
        done
        _wr_el=$(( $(date +%s) - _wr_t0 - _wr_slept ))
        if [ "$_wr_code" = "200" ]; then
            # Local storage answers in milliseconds, so whole seconds already
            # mean the upstream leg ran and this guest paid for the copy.
            if [ "$_wr_el" -lt 5 ]; then _wr_state="already cached"; else _wr_state="cold, now cached"; fi
            # See https://yuruna.link/42f6b05f-0020
            # Report recovered transport failures beside successful cache results.
            if [ "$_wr_attempt_max" -gt 1 ]; then _wr_state="${_wr_state}, answered on attempt ${_wr_attempt_max}"; fi
            printf '  %-52s %5ss (%s)\n' "${_wr_repo}:${_wr_tag}" "$_wr_el" "$_wr_state"
        else
            yuruna_warm_missing=$((yuruna_warm_missing + 1))
            yuruna_warm_errored=$((yuruna_warm_errored + 1))
            # See https://yuruna.link/42f6b05f-0020
            # Keep a missing status distinct from curl reporting HTTP 000.
            if [ -z "$_wr_code" ]; then
                _wr_status="${_wr_leg}no status captured"
                yuruna_warm_silent=$((yuruna_warm_silent + 1))
            elif [ "$_wr_code" = "000" ]; then
                _wr_status="${_wr_leg}HTTP 000 (no response)"
                yuruna_warm_silent=$((yuruna_warm_silent + 1))
            else
                _wr_status="${_wr_leg}HTTP ${_wr_code}"
            fi
            printf '  %-52s %5ss (NOT CACHED -- %s, curl exit %s, %s attempt(s))\n' "${_wr_repo}:${_wr_tag}" "$_wr_el" "$_wr_status" "$_wr_rc" "$_wr_attempt"
        fi
        # --- REGION: https://yuruna.link/42e220c4-0005
        if [ -s "$_wr_errlog" ]; then
            while IFS= read -r _wr_errline; do
                printf '      %s\n' "$_wr_errline"
            done < "$_wr_errlog"
        fi
    done
    rm -f "$_wr_errlog" "$_wr_body"
    yuruna_warm_spent=$(( $(date +%s) - _wr_start ))
    echo "== ${_wr_label}: $((yuruna_warm_total - yuruna_warm_missing)) of ${yuruna_warm_total} images cached =="
}

# See https://yuruna.link/42f6b05f-0020
# Use kubeadm image references; etcd, pause, and CoreDNS have independent versions.
mapfile -t _k8s_refs < <(sudo kubeadm config images list 2>/dev/null || true)
if [ -z "$CACHE_HOST" ]; then
    echo "No caching proxy: skipping the warm pass -- there is nothing to warm, and the kubeadm pull below fetches the set from the upstreams."
elif [ "${#_k8s_refs[@]}" -eq 0 ]; then
    echo "Note: kubeadm could not list its images; skipping the warm pass and letting the pull below discover the set."
else
    yuruna_warm_refs "control-plane" "${_k8s_refs[@]}"
    if [ "$yuruna_warm_missing" -gt 0 ]; then
        # An HTTP error status is the cache's answer, not a copy in progress.
        yuruna_warm_refused=$((yuruna_warm_errored - yuruna_warm_silent))
        # See https://yuruna.link/42f6b05f-0020
        # A silent transport failure leaves cache contents unmeasured.
        if [ "$yuruna_warm_errored" -gt 0 ] && [ "$yuruna_warm_errored" -eq "$yuruna_warm_silent" ] && [ "$yuruna_warm_unattempted" -eq 0 ]; then
            echo "ERROR: the cache was not reached -- ${yuruna_warm_missing} of ${yuruna_warm_total} control-plane requests got no HTTP status back, so what the cache holds is unmeasured." >&2
            echo "       Look at this guest's path to it first: name resolution for ${CACHE_HOST}, a route to port 5000, and the curl exit codes in the column above." >&2
        elif [ "$yuruna_warm_refused" -eq "$yuruna_warm_missing" ]; then
            echo "ERROR: the cache refused ${yuruna_warm_refused} of ${yuruna_warm_total} control-plane images -- each answered with an HTTP error (column above)." >&2
        else
            echo "ERROR: the cache is still cold -- ${yuruna_warm_missing} of ${yuruna_warm_total} control-plane images did not reach the cache." >&2
        fi
        # --- REGION: https://yuruna.link/42e220c4-0005
        if [ "$yuruna_warm_errored" -gt 0 ]; then
            echo "       ${yuruna_warm_errored} answered with an error or not at all (HTTP column above); ${yuruna_warm_spent}s of the ${YURUNA_IMAGE_WARM_BUDGET}s budget was spent." >&2
        fi
        if [ "$yuruna_warm_unattempted" -gt 0 ]; then
            echo "       ${yuruna_warm_unattempted} were never requested: the ${YURUNA_IMAGE_WARM_BUDGET}s warm budget ran out first." >&2
        fi
        echo "       kubeadm would spend its entire step budget re-requesting them and end as a bare" >&2
        echo "       timeout naming no image, so stop here while the cause is still on screen." >&2
        if [ "$yuruna_warm_silent" -gt 0 ] || [ "$yuruna_warm_unattempted" -gt 0 ]; then
            echo "       The cache continues each interrupted sync in the background, so a re-run lands warm." >&2
        fi
        if [ "$yuruna_warm_refused" -gt 0 ]; then
            echo "       A refused image is not an interrupted copy: a re-run lands warm only if the" >&2
            echo "       refusal was transient upstream trouble. The cache's sync log names the cause." >&2
            # The cache syncs probe images through its own zot release; when that
            # release cannot serve these registries, its verdict says so and lists
            # the fixes, which belong next to the failure rather than one page away.
            yuruna_selftest=$(curl -fsS --noproxy '*' --max-time 10 "http://${CACHE_HOST}/cache-health" 2>/dev/null \
                | awk '/^zot sync self-test/ { shown = 1; print; next } shown && /^  / { print; next } { shown = 0 }' || true)
            if [ -n "$yuruna_selftest" ]; then
                echo "       The cache's own verdict on its zot release:" >&2
                printf '%s\n' "$yuruna_selftest" | sed 's/^/         /' >&2
            fi
        fi
        echo "       Cache condition: http://${CACHE_HOST}/cache-health" >&2
        exit 1
    fi
fi

# See https://yuruna.link/42d69dfa-0042
# Warm pulls follow mirror configuration; kubeadm retries a failed pre-pull.
sudo kubeadm config images pull || echo "Note: kubeadm images pull may need to be run after kubeadm init"

# Reset any existing kubeadm state so the script can be re-run safely
# Reference: https://k8s.io/docs/reference/setup-tools/kubeadm/kubeadm-reset/
docker_network_needs_restore=false
if [ -f /etc/kubernetes/manifests/kube-apiserver.yaml ] || [ -d /etc/kubernetes/pki ]; then
    echo "Existing Kubernetes cluster detected -- resetting before re-initialization"
    sudo kubeadm reset -f --cri-socket unix:///var/run/containerd/containerd.sock
    sudo rm -rf /etc/cni/net.d
    # See https://yuruna.link/42e220c4-000e
    # Flush each rule table independently so one failure cannot skip the remaining cleanup.
    sudo iptables -F || true
    sudo iptables -t nat -F || true
    sudo iptables -t mangle -F || true
    sudo iptables -X || true
    if command -v ipvsadm &>/dev/null; then
        sudo ipvsadm --clear || true
    fi
    sudo rm -f "${REAL_HOME}/.kube/config"
    docker_network_needs_restore=true
fi

# Reset can disrupt containerd; require a working CRI API before initialization.
sudo systemctl restart containerd
wait_for_containerd 30

if [ "$docker_network_needs_restore" = true ]; then
    # Firewall cleanup also removes Docker's bridge forwarding and NAT rules.
    # Restore them after containerd recovery so later builds retain network access.
    echo "Restoring Docker networking after Kubernetes firewall cleanup"
    if ! sudo timeout --kill-after=1 60 systemctl restart docker; then
        echo "ERROR: Docker restart failed after Kubernetes firewall cleanup." >&2
        exit 1
    fi
    if ! sudo timeout --kill-after=1 10 docker info >/dev/null; then
        echo "ERROR: Docker engine did not answer after Kubernetes firewall cleanup." >&2
        exit 1
    fi
fi

# Load kernel modules required by Kubernetes networking (Flannel uses vxlan which needs overlay + br_netfilter)
sudo modprobe overlay
sudo modprobe br_netfilter

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

# See https://yuruna.link/42e220c4-000e
# Reset incomplete control-plane state between transient init failures.
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
        wait_for_containerd 30
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
# --- REGION: https://yuruna.link/42d69dfa-0043
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
# --- REGION: https://yuruna.link/42f6b05f-0020
mapfile -t _cni_refs < <(awk '$1=="image:"{print $2}' "$FLANNEL_MANIFEST" | sort -u || true)
if [ -n "$CACHE_HOST" ] && [ "${#_cni_refs[@]}" -gt 0 ]; then
    yuruna_warm_refs "flannel" "${_cni_refs[@]}"
    if [ "$yuruna_warm_missing" -gt 0 ]; then
        echo "Note: ${yuruna_warm_missing} of ${yuruna_warm_total} flannel images are not cached; the rollout wait below is likely to time out." >&2
    fi
fi
if ! kubectl --kubeconfig="${REAL_HOME}/.kube/config" apply -f "$FLANNEL_MANIFEST"; then
    echo "ERROR: Failed to apply Flannel manifest $FLANNEL_MANIFEST to the cluster" >&2
    exit 1
fi

# --- REGION: Install Helm
# See https://yuruna.link/4220a755-001f
echo ""
echo -e "\e[1;36m==== Helm ====\e[0m"
# get-helm-4, never get-helm-3 (the v3 installer can only ever land a 3.x binary).
curl_retry -fsSL "https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4${YurunaCacheContent:+?nocache=${YurunaCacheContent}}" -o /tmp/get-helm-4.sh
chmod +x /tmp/get-helm-4.sh
DESIRED_VERSION="v${YURUNA_HELM_VERSION}" _yuruna_retry helm_install /tmp/get-helm-4.sh || true
rm -f /tmp/get-helm-4.sh
if ! assert_tool_runnable helm version --short; then
    echo "ERROR: Helm install failed; downstream chart-based workloads (helm repo add / upgrade) will fail at Set-Workload." >&2
    exit 1
fi

# --- REGION: Install OpenTofu
# See https://yuruna.link/42d69dfa-0044
echo ""
echo -e "\e[1;36m==== OpenTofu ====\e[0m"
# The signed standalone release avoids refreshing every apt repository twice.
# Unlike the deb installer, this method honors the exact requested version.
opentofu_matches_version() {
    local path version
    path="$(command -v tofu 2>/dev/null || true)"
    [ -n "$path" ] && [ -f "$path" ] && [ -s "$path" ] && [ -x "$path" ] || return 1
    version="$("$path" version 2>/dev/null)" || return 1
    [ "${version%%$'\n'*}" = "OpenTofu v${YURUNA_OPENTOFU_VERSION}" ]
}
if opentofu_matches_version; then
    echo "OpenTofu ${YURUNA_OPENTOFU_VERSION} is already installed and runnable."
else
    OPENTOFU_INSTALLER="$(mktemp /tmp/yuruna-opentofu.XXXXXX)"
    if ! curl_retry --proto '=https' --tlsv1.2 -fsSL "https://get.opentofu.org/install-opentofu.sh${YurunaCacheContent:+?nocache=${YurunaCacheContent}}" -o "$OPENTOFU_INSTALLER"; then
        rm -f "$OPENTOFU_INSTALLER"
        echo "ERROR: Could not download the OpenTofu installer." >&2
        exit 1
    fi
    chmod +x "$OPENTOFU_INSTALLER"
    # Keep checksum and GPG/cosign signature verification enabled. Both shells
    # and new PowerShell processes resolve the installed binary through this link.
    if ! _yuruna_retry opentofu_standalone "$OPENTOFU_INSTALLER" --install-method standalone \
        --opentofu-version "$YURUNA_OPENTOFU_VERSION" --install-path /opt/opentofu --symlink-path /usr/local/bin; then
        rm -f "$OPENTOFU_INSTALLER"
        echo "ERROR: OpenTofu standalone installation or integrity verification failed." >&2
        exit 1
    fi
    rm -f "$OPENTOFU_INSTALLER"
    # A previous /usr/bin/tofu lookup must not hide the new /usr/local/bin link.
    hash -r
    if ! opentofu_matches_version; then
        echo "ERROR: OpenTofu ${YURUNA_OPENTOFU_VERSION} is not runnable on PATH after installation." >&2
        exit 1
    fi
fi

# --- REGION: Install mkcert
# Retry the upstream redirector, then fall back to Ubuntu's package.
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
    # See https://yuruna.link/42e220c4-0005
    # Install the root CA in the real user home, including when invoked through sudo.
    TARGET_USER="${SUDO_USER:-$USER}"
    sudo -u "$TARGET_USER" -H mkcert -install || true
fi

# --- REGION: Create the HTTPS development certificate
echo ""
echo -e "\e[1;36m==== HTTPS development certificate ====\e[0m"
PFX_DIR="${REAL_HOME}/.aspnet/https"
PFX_FILE="$PFX_DIR/aspnetapp.pfx"
mkdir -p "$PFX_DIR"
openssl req -x509 -newkey rsa:4096 -keyout "$PFX_DIR/aspnetapp.key" -out "$PFX_DIR/aspnetapp.crt" -days 365 -nodes -subj '/CN=localhost' 2>/dev/null
# See https://yuruna.link/42e220c4-0005
# Keep the random PFX password out of argv, tracing, and public files.
case $- in *x*) PFX_XTRACE=1 ;; *) PFX_XTRACE=0 ;; esac
set +x
PFX_PASSWORD="$(openssl rand -hex 32)"
PFX_PASSWORD="$PFX_PASSWORD" openssl pkcs12 -export -out "$PFX_FILE" -inkey "$PFX_DIR/aspnetapp.key" -in "$PFX_DIR/aspnetapp.crt" -passout env:PFX_PASSWORD
rm -f "$PFX_FILE.password"
(umask 077; printf '%s\n' "$PFX_PASSWORD" > "$PFX_FILE.password")
unset PFX_PASSWORD
if [ "$PFX_XTRACE" = 1 ]; then set -x; fi
rm -f "$PFX_DIR/aspnetapp.key" "$PFX_DIR/aspnetapp.crt"
# Ensure the real user owns the certificate files (not root)
chown -R "$REAL_USER:$REAL_USER" "$PFX_DIR"

# Cluster networking starts while the independent tools and certificates install.
# Keep the readiness gate before the summary and every downstream workload.
wait_for_kubernetes_network

# Remove control-plane taint for single-node cluster
kubectl --kubeconfig="${REAL_HOME}/.kube/config" taint nodes --all node-role.kubernetes.io/control-plane- || true

kubectl --kubeconfig="${REAL_HOME}/.kube/config" config rename-context kubernetes-admin@kubernetes docker-desktop || true

# --- REGION: Installation summary
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

# --- REGION: Optional steps
echo ""
echo "== Optional Steps =="
echo "Current hostname: $(hostnamectl hostname)"
echo "1. Change hostname: sudo hostnamectl set-hostname [desired-hostname]"
echo ""
echo -e "\e[1;33m+========+\e[0m"
echo -e "\e[1;33m|  IMPORTANT: Docker group permissions                               |\e[0m"
echo -e "\e[1;33m|                                                                    |\e[0m"
echo -e "\e[1;33m|  Your user was added to the 'docker' group, but the current shell  |\e[0m"
echo -e "\e[1;33m|  does not have the updated group membership yet.                   |\e[0m"
echo -e "\e[1;33m|                                                                    |\e[0m"
echo -e "\e[1;33m|  To enable docker commands in this terminal, run:                  |\e[0m"
echo -e "\e[1;33m|      newgrp docker                                                 |\e[0m"
echo -e "\e[1;33m|                                                                    |\e[0m"
echo -e "\e[1;33m|  New terminals will activate the docker group automatically        |\e[0m"
echo -e "\e[1;33m|  via the .bashrc snippet. A full logout/login also works.          |\e[0m"
echo -e "\e[1;33m+========+\e[0m"
