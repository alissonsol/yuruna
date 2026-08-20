#!/bin/bash
# Version: 2026.08.20
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NONINTERACTIVE=1

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

# --- REGION: Detect architecture
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
# --- REGION: https://yuruna.link/network#why-apt-and-dnf-attempts-run-unbounded-by-default
# Re-asserted here because a baked retry lib may still carry a wall-clock bound.
export YURUNA_APT_STALL_TIMEOUT_SECONDS=0

echo "== Installing Kubernetes requirements for Ubuntu =="

# --- REGION: Install basic tools
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

# --- REGION: https://yuruna.link/memory#why-the-k8s-guest-configures-the-docker-registry-mirror-before-installing-docker-ce
# CACHE_HOST is parsed from $http_proxy (set system-wide by the
# guest's cloud-init late-commands).
#
# Fallbacks in order of how much they can be trusted. $http_proxy is absent
# whenever this runs in a shell that did not inherit the system environment
# (sudo without -E, a non-login shell), which is not rare and is not an error.
# /etc/yuruna/host.env carries the proxy's ADDRESS, seeded at build time and
# refreshed by yuruna-host-locate.timer, so it needs no name resolution at all.
# The bare hostname is last because it needs working DNS for a name the lab's
# resolver may not serve: when it fails, the error is "could not resolve host",
# which reads as a broken proxy and sends the reader to the wrong machine.
CACHE_HOST=$(echo "${http_proxy:-}" | sed -E 's|^https?://([^:/]+).*|\1|')
if [ -z "$CACHE_HOST" ] && [ -r /etc/yuruna/host.env ]; then
    CACHE_HOST=$(sed -nE 's/^YURUNA_CACHING_PROXY_SERVICE_IP=([^[:space:]]+).*/\1/p' /etc/yuruna/host.env | head -n1)
fi
[ -z "$CACHE_HOST" ] && CACHE_HOST="yuruna-caching-proxy-service"
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

# Docker starts automatically after install; enable + start as a safety net,
# tolerating environments where systemd is not fully available.
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
# Bound the wait on wall-clock: `systemctl is-active` can itself take a
# non-trivial slice of a second on a busy guest, so an iteration counter
# with per-iteration work would run well past the intended timeout.
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
    echo -e "\e[1;31m+====================================================================+\e[0m"
    echo -e "\e[1;31m|  ERROR: Docker daemon is not responding after ${DOCKER_WAIT_SECONDS}s               |\e[0m"
    echo -e "\e[1;31m+====================================================================+\e[0m"
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
    echo -e "\e[1;31m+====================================================================+\e[0m"
    echo ""
    exit 1
fi

# --- REGION: Install Kubernetes
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
# containerd omitted SystemdCgroup from the generated default once already
# (containerd#12101, restored in 2.0.x/2.1.x/2.2.x by #12244). If it goes
# missing again the substitution above matches nothing and containerd silently
# runs cgroupfs against a systemd-driver kubelet, so assert instead of trusting.
if ! grep -q 'SystemdCgroup = true' /etc/containerd/config.toml; then
    echo "ERROR: containerd SystemdCgroup was not set to true; the cgroup driver would not match kubelet." >&2
    exit 1
fi
# containerd 2.2 emits `config_path = '/etc/containerd/certs.d:/etc/docker/certs.d'`
# -- single-quoted, non-empty, colon-joined -- so a pattern anchored on the 1.x
# empty `""` matches nothing and leaves the default in place, which containerd
# 2.2 then ignores anyway (containerd#12808). Both failures are silent: every
# hosts.toml below goes inert and containerd pulls bypass zot entirely. Match
# whatever value is there, write the single supported path, and assert the
# result, so a future schema move fails HERE instead of going quiet again.
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
# Each hosts.toml below names the cache twice and both spellings are
# load-bearing: `server` must not fall back to the upstream, and the [host]
# form is what makes containerd send the ns=<namespace> parameter zot routes
# on. Full reasoning under the REGION anchor above.
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
# public.ecr.aws can return transient HTTP errors that bubble up as 4xx
# from `registry:2`. Mirroring it via zot means the cached copy is served
# whenever the upstream has an image-specific hiccup, instead of fronting
# the upstream's failure.
sudo tee /etc/containerd/certs.d/public.ecr.aws/hosts.toml > /dev/null <<HOSTSEOF
server = "http://${CACHE_HOST}:5000"

[host."http://${CACHE_HOST}:5000"]
  capabilities = ["pull", "resolve"]
HOSTSEOF
# Flannel's three images (flannel-cni-plugin + flannel, used by both init
# containers and the daemon) live on ghcr.io. Without this entry containerd
# bypasses zot and tunnels every flannel layer through squid's CONNECT port,
# which is uncached: a stalled tunnel leaves kube-flannel-ds at Init:1/2 with
# /etc/cni/net.d empty, so the node never leaves NotReady. zot's sync
# extension already lists ghcr.io as an on-demand upstream.
sudo tee /etc/containerd/certs.d/ghcr.io/hosts.toml > /dev/null <<HOSTSEOF
server = "http://${CACHE_HOST}:5000"

[host."http://${CACHE_HOST}:5000"]
  capabilities = ["pull", "resolve"]
HOSTSEOF
# The .NET base images (dotnet/sdk, dotnet/aspnet) live on
# mcr.microsoft.com. Without this entry containerd bypasses zot and pulls
# them straight from the upstream through squid's CONNECT port, which is
# uncached: every guest re-downloads the same multi-hundred-megabyte layers,
# and the cache's scheduled pre-warm of those two tags is never read. Routed
# here the request carries ns=mcr.microsoft.com, so zot resolves it against
# the MCR upstream instead of walking its list.
sudo tee /etc/containerd/certs.d/mcr.microsoft.com/hosts.toml > /dev/null <<HOSTSEOF
server = "http://${CACHE_HOST}:5000"

[host."http://${CACHE_HOST}:5000"]
  capabilities = ["pull", "resolve"]
HOSTSEOF
# A cache that is merely slow is fine -- containerd waits, and the pull
# progress cap below bounds a genuine wedge. A cache that is DOWN is now
# terminal for image pulls, since nothing else serves them, so surface that
# here rather than letting it read as a mystery ImagePullBackOff later.
# A cache being REBUILT is neither: it refuses connections for as long as the
# replacement VM takes to boot zot and then serves normally, so a single-shot
# probe reads a recoverable window as a dead cache. Wait that window out before
# calling it down -- on the liveness endpoint only, which costs nothing from the
# lab's shared pull budget.
cache_wait="${YURUNA_CACHE_WAIT_SECONDS:-180}"
cache_started=$SECONDS
cache_err=""
# Each waiting line carries its own elapsed count rather than repeating one
# fixed string. This runs on the VM console, where the host's OCR watcher reads
# a screen dominated by one identical line as a wedged guest -- and a bounded
# wait that is working looks exactly like that unless the lines differ. curl's
# own stderr is held back for the same reason and replayed once if the wait is
# ultimately lost, where it is the part worth reading.
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
# --- REGION: https://yuruna.link/caching#warm-sets-and-the-cold-sync-reading
# Read the cache's published reading rather than measuring from here: measuring
# would spend a pull from the budget the whole lab shares, every run. Advisory,
# never fatal -- its value is a before-picture in THIS guest's log.
if cache_health=$(curl -fsS --max-time 5 "http://${CACHE_HOST}/cache-health" 2>/dev/null); then
    echo "Cache health, as published by ${CACHE_HOST}:"
    printf '%s\n' "$cache_health" | sed 's/^/  /'
else
    echo "Note: ${CACHE_HOST} publishes no cache-health page; only its /v2/ liveness was checked here,"
    echo "      which stays green through a manifest stall."
fi
# Bound a stalled pull. containerd's default no-progress window is long enough
# that a dead tunnel parks the pod at Init:n/m past every downstream wait
# without ever handing kubelet an error to retry on -- the pull just hangs, so
# no ImagePullBackOff is recorded. Capping it makes a stalled pull fail fast and
# get retried inside the rollout window below. Applied only when the key exists,
# so a containerd whose config schema moved it gets no bogus line appended.
CONTAINERD_PULL_PROGRESS_TIMEOUT="120s"
if grep -q 'image_pull_progress_timeout' /etc/containerd/config.toml; then
    sudo sed -i "s|^\(\s*image_pull_progress_timeout\s*=\s*\).*|\1'${CONTAINERD_PULL_PROGRESS_TIMEOUT}'|" /etc/containerd/config.toml
else
    echo "Note: containerd config has no image_pull_progress_timeout key; leaving the built-in default in place"
fi
sudo systemctl enable containerd
sudo systemctl restart containerd

# --- REGION: https://yuruna.link/caching#warm-sets-and-the-cold-sync-reading
# Reports through yuruna_warm_missing / yuruna_warm_total rather than exiting,
# because the two callers owe different answers: a short control plane cannot
# proceed, while a CNI rollout has its own bounded wait and may still converge.
# Why a cold cache has to be paid for here at all: see the REGION anchor above.
YURUNA_IMAGE_WARM_BUDGET="${YURUNA_IMAGE_WARM_BUDGET:-900}"
yuruna_warm_refs() {
    _wr_label=$1
    shift
    yuruna_warm_total=0
    yuruna_warm_missing=0
    _wr_deadline=$(( $(date +%s) + YURUNA_IMAGE_WARM_BUDGET ))
    # Spelled out because a manifest request stating no preference gets the
    # registry's default, which for a multi-arch tag is not the index a pull
    # resolves -- warming the wrong document leaves the real pull still cold.
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
            printf '  %-52s       not attempted (warm budget spent)\n' "${_wr_repo}:${_wr_tag}"
            continue
        fi
        _wr_t0=$(date +%s)
        # ns= names the upstream this repository belongs to -- the same parameter
        # containerd's hosts.toml form sends on every pull, and how the cache
        # picks which upstream to sync from. Without it the cache walks its
        # configured registries in order, where Docker Hub is the catch-all, and
        # spends one of the metered lookups the whole lab shares on an image
        # Docker Hub never served.
        _wr_code=$(curl -s -o /dev/null --max-time "$_wr_left" -w '%{http_code}' \
            -H "Accept: ${_wr_accept}" \
            "http://${CACHE_HOST}:5000/v2/${_wr_repo}/manifests/${_wr_tag}?ns=${_wr_upstream}" 2>/dev/null || true)
        _wr_el=$(( $(date +%s) - _wr_t0 ))
        if [ "$_wr_code" = "200" ]; then
            # Local storage answers in milliseconds, so whole seconds already
            # mean the upstream leg ran and this guest paid for the copy.
            if [ "$_wr_el" -lt 5 ]; then _wr_state="already cached"; else _wr_state="cold, now cached"; fi
            printf '  %-52s %5ss (%s)\n' "${_wr_repo}:${_wr_tag}" "$_wr_el" "$_wr_state"
        else
            yuruna_warm_missing=$((yuruna_warm_missing + 1))
            printf '  %-52s %5ss (NOT CACHED -- HTTP %s)\n' "${_wr_repo}:${_wr_tag}" "$_wr_el" "${_wr_code:-000}"
        fi
    done
    echo "== ${_wr_label}: $((yuruna_warm_total - yuruna_warm_missing)) of ${yuruna_warm_total} images cached =="
}

# The set comes from kubeadm itself. It cannot be derived from the Kubernetes
# version: coredns, pause and etcd carry tags of their own, baked into this
# binary and moved on their own schedule, so any list built here would miss
# exactly the images that then arrive cold.
_k8s_refs=$(sudo kubeadm config images list 2>/dev/null || true)
if [ -z "$_k8s_refs" ]; then
    echo "Note: kubeadm could not list its images; skipping the warm pass and letting the pull below discover the set."
else
    yuruna_warm_refs "control-plane" $_k8s_refs
    if [ "$yuruna_warm_missing" -gt 0 ]; then
        echo "ERROR: the cache is still cold -- ${yuruna_warm_missing} of ${yuruna_warm_total} control-plane images did not arrive within the ${YURUNA_IMAGE_WARM_BUDGET}s warm budget." >&2
        echo "       kubeadm would spend its entire step budget re-requesting them and end as a bare" >&2
        echo "       timeout naming no image, so stop here while the cause is still on screen." >&2
        echo "       The cache continues each interrupted sync in the background, so a re-run lands warm." >&2
        echo "       Cache condition: http://${CACHE_HOST}/cache-health" >&2
        exit 1
    fi
fi

# Pre-pull the kubeadm control-plane images through the zot mirror so
# `kubeadm init` lands cache-warm. Must run AFTER the containerd mirror config
# above, or the pulls bypass the cache and hit upstream directly. Best-effort:
# `kubeadm init` does its own pull check if this fails.
sudo kubeadm config images pull || echo "Note: kubeadm images pull may need to be run after kubeadm init"

# Reset any existing kubeadm state so the script can be re-run safely
# Reference: https://k8s.io/docs/reference/setup-tools/kubeadm/kubeadm-reset/
if [ -f /etc/kubernetes/manifests/kube-apiserver.yaml ] || [ -d /etc/kubernetes/pki ]; then
    echo "Existing Kubernetes cluster detected -- resetting before re-initialization"
    sudo kubeadm reset -f --cri-socket unix:///var/run/containerd/containerd.sock
    sudo rm -rf /etc/cni/net.d
    # Clean up network filtering rules left by the previous cluster.
    # Each flush is independent: chaining with && would let one failing
    # flush short-circuit the rest, leaving stale rules that break the
    # new cluster. Guard each on its own so all four always run.
    sudo iptables -F || true
    sudo iptables -t nat -F || true
    sudo iptables -t mangle -F || true
    sudo iptables -X || true
    if command -v ipvsadm &>/dev/null; then
        sudo ipvsadm --clear || true
    fi
    sudo rm -f "${REAL_HOME}/.kube/config"
fi

# Restart containerd after reset (reset can disrupt it) and wait for the socket
sudo systemctl restart containerd
# `crictl ... info` can block for a good fraction of a second while the
# socket is still coming up, so bound the wait on wall-clock rather than
# on an iteration count with per-iteration work.
containerd_deadline=$(( $(date +%s) + 30 ))
while true; do
    if sudo crictl --runtime-endpoint unix:///var/run/containerd/containerd.sock info &>/dev/null; then
        echo "containerd is ready"
        break
    fi
    _now=$(date +%s)
    [ "$_now" -ge "$containerd_deadline" ] && break
    echo "Waiting for containerd to be ready... ($(( containerd_deadline - _now ))s left)"
    sleep 1
done

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
        containerd_deadline=$(( $(date +%s) + 30 ))
        while true; do
            if sudo crictl --runtime-endpoint unix:///var/run/containerd/containerd.sock info &>/dev/null; then break; fi
            [ "$(date +%s)" -ge "$containerd_deadline" ] && break
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
# Flannel's images gate the CNI: a stalled pull leaves kube-flannel-ds at
# Init:n/m with /etc/cni/net.d empty, so the node never leaves NotReady and the
# failure surfaces as a node-readiness timeout that says nothing about a
# registry. Warm them on the same patient path before the DaemonSet asks
# containerd for them. Advisory rather than fatal, unlike the control plane:
# the rollout wait below can still converge if an image lands moments later.
_cni_refs=$(awk '$1=="image:"{print $2}' "$FLANNEL_MANIFEST" | sort -u || true)
if [ -n "$_cni_refs" ]; then
    yuruna_warm_refs "flannel" $_cni_refs
    if [ "$yuruna_warm_missing" -gt 0 ]; then
        echo "Note: ${yuruna_warm_missing} of ${yuruna_warm_total} flannel images are not cached; the rollout wait below is likely to time out." >&2
    fi
fi
if ! kubectl --kubeconfig="${REAL_HOME}/.kube/config" apply -f "$FLANNEL_MANIFEST"; then
    echo "ERROR: Failed to apply Flannel manifest $FLANNEL_MANIFEST to the cluster" >&2
    exit 1
fi

echo ""
echo "==== Flannel DaemonSet Status ===="
echo "Waiting for Flannel pods to be ready..."
sleep 15
kubectl --kubeconfig="${REAL_HOME}/.kube/config" -n kube-flannel rollout status daemonset/kube-flannel-ds --timeout=180s \
    || echo "Note: Flannel rollout status check timed out -- pods may still be starting"

# Wait for the node to report Ready (networking must be up for this to succeed).
# Fatal, not a note: a NotReady node cannot schedule anything, so every
# downstream step is already lost. Exiting non-zero makes the fetch-and-execute
# wrapper print its NONZERO SCRIPT EXIT sentinel, which the sequence engine
# fast-fails on -- so the run is attributed to THIS script in seconds instead
# of surfacing minutes later as an unrelated workload/HTTP-probe timeout.
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

# Remove control-plane taint for single-node cluster
kubectl --kubeconfig="${REAL_HOME}/.kube/config" taint nodes --all node-role.kubernetes.io/control-plane- || true

kubectl --kubeconfig="${REAL_HOME}/.kube/config" config rename-context kubernetes-admin@kubernetes docker-desktop || true

# --- REGION: https://yuruna.link/network#helm-installer-fetch
echo ""
echo -e "\e[1;36m==== Helm ====\e[0m"
# get-helm-4, never get-helm-3 (the v3 installer can only ever land a 3.x binary).
curl_retry -fsSL "https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4${YurunaCacheContent:+?nocache=${YurunaCacheContent}}" -o /tmp/get-helm-4.sh
chmod +x /tmp/get-helm-4.sh
DESIRED_VERSION="v${YURUNA_HELM_VERSION}" _yuruna_retry helm_install /tmp/get-helm-4.sh || true
rm -f /tmp/get-helm-4.sh
if ! command -v helm >/dev/null 2>&1; then
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

# --- REGION: Install mkcert
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
    # Run mkcert -install as the actual user (not root) so rootCA.pem
    # lands in their $HOME/.local/share/mkcert, regardless of whether
    # this script was invoked directly or via sudo.
    TARGET_USER="${SUDO_USER:-$USER}"
    sudo -u "$TARGET_USER" -H mkcert -install || true
fi

# --- REGION: Create the HTTPS development certificate
echo ""
echo -e "\e[1;36m==== HTTPS development certificate ====\e[0m"
PFX_DIR="${REAL_HOME}/.aspnet/https"
mkdir -p "$PFX_DIR"
openssl req -x509 -newkey rsa:4096 -keyout "$PFX_DIR/aspnetapp.key" -out "$PFX_DIR/aspnetapp.crt" -days 365 -nodes -subj '/CN=localhost' 2>/dev/null
openssl pkcs12 -export -out "$PFX_DIR/aspnetapp.pfx" -inkey "$PFX_DIR/aspnetapp.key" -in "$PFX_DIR/aspnetapp.crt" -password pass:password
rm -f "$PFX_DIR/aspnetapp.key" "$PFX_DIR/aspnetapp.crt"
# Ensure the real user owns the certificate files (not root)
chown -R "$REAL_USER:$REAL_USER" "$PFX_DIR"

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
echo -e "\e[1;33m+====================================================================+\e[0m"
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
echo -e "\e[1;33m+====================================================================+\e[0m"
