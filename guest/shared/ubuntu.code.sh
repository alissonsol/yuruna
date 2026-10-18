#!/bin/bash
# Version: 2026.10.18
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# --- REGION: Initialize environment
set -euo pipefail
# Fixed-name downloads and the version probe's throwaway VS Code profile go on
# every path out, an aborted install included; the guest is snapshotted after.
_yuruna_code_profile=""
trap 'rm -f /tmp/dotnet-install.sh /tmp/microsoft.asc; [ -z "${_yuruna_code_profile:-}" ] || rm -rf -- "$_yuruna_code_profile"' EXIT

export DEBIAN_FRONTEND=noninteractive
export NONINTERACTIVE=1

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

# --- REGION: Install JDK
echo ""
echo -e "\e[1;36m==== JDK ====\e[0m"
# default-jdk-headless tracks the distro's current OpenJDK LTS and provides
# both amd64 and arm64 packages (javac included).
apt_retry sudo apt-get install -y default-jdk-headless
java -version
javac -version
if ! grep -q 'export JAVA_HOME=/usr/lib/jvm/default-java' /etc/bash.bashrc 2>/dev/null; then
  echo 'export JAVA_HOME=/usr/lib/jvm/default-java' | sudo tee -a /etc/bash.bashrc
fi

# --- REGION: Install .NET SDK
echo ""
echo -e "\e[1;36m==== .NET SDK ====\e[0m"
# See https://yuruna.link/42e220c4-0005
# Use dotnet-install.sh because Ubuntu has no current-LTS SDK metapackage.
sudo mkdir -p /usr/local/dotnet
curl_retry -fsSL "https://dot.net/v1/dotnet-install.sh${YurunaCacheContent:+?nocache=${YurunaCacheContent}}" -o /tmp/dotnet-install.sh
chmod +x /tmp/dotnet-install.sh
sudo bash /tmp/dotnet-install.sh --channel LTS --install-dir /usr/local/dotnet
rm -f /tmp/dotnet-install.sh
sudo ln -sf /usr/local/dotnet/dotnet /usr/local/bin/dotnet
if ! grep -q 'export DOTNET_ROOT=/usr/local/dotnet' /etc/bash.bashrc 2>/dev/null; then
  echo 'export DOTNET_ROOT=/usr/local/dotnet' | sudo tee -a /etc/bash.bashrc
fi
dotnet --version || echo "dotnet: version probe failed (non-fatal)"

# --- REGION: Install Visual Studio Code
echo ""
echo -e "\e[1;36m==== VS Code ====\e[0m"
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
# The VS Code apt repo provides both amd64 and arm64 packages
curl_retry -fsSL "https://packages.microsoft.com/keys/microsoft.asc${YurunaCacheContent:+?nocache=${YurunaCacheContent}}" -o /tmp/microsoft.asc
sudo install -d -m 755 /etc/apt/keyrings
_yuruna_verify_key_fpr /tmp/microsoft.asc BC528686B50D79E339D3721CEB3E94ADBE1229CF \
    || { echo "NONZERO SCRIPT EXIT: microsoft apt key fingerprint mismatch" >&2; rm -f /tmp/microsoft.asc; exit 1; }
gpg --dearmor < /tmp/microsoft.asc | sudo tee /etc/apt/keyrings/packages.microsoft.gpg > /dev/null
rm -f /tmp/microsoft.asc
echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" | sudo tee /etc/apt/sources.list.d/vscode.list > /dev/null
apt_retry sudo apt-get update
# --- REGION: https://yuruna.link/42e220c4-0005
apt_retry sudo apt-get install -y --no-install-recommends code libgl1 libgl1-mesa-dri

# --- REGION: Installation summary
echo ""
echo "== Installation Summary =="
# A benign non-zero from a version probe must never fail provisioning (the script runs under
# set -e); capture stderr too so the summary shows the real version line.
echo "DotNet: $(dotnet --version 2>&1 || echo 'version probe failed')"
echo "Git: $(git --version 2>&1 || echo 'version probe failed')"
echo "Java: $(javac -version 2>&1 || echo 'version probe failed')"
echo "PowerShell: $(pwsh --version 2>&1 || echo 'version probe failed')"
if [ -z "${TMPDIR:-}" ]; then
    TMPDIR=$(mktemp -d)
    _yuruna_code_profile="$TMPDIR"
    export TMPDIR
    echo "TMPDIR not set. Created and set TMPDIR to $TMPDIR"
fi
echo "Visual Studio Code: $(code --version --no-sandbox --user-data-dir "$TMPDIR" 2>&1 || echo 'installed, version probe failed')"
