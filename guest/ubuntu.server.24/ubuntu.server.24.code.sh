#!/bin/bash
# Version: 2026.07.14
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NONINTERACTIVE=1

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

echo ""
echo -e "\e[1;36m==== .NET SDK ====\e[0m"
# The dotnet-sdk package is available for both amd64 and arm64 via apt
apt_retry sudo apt-get install -y dotnet-sdk-10.0
dotnet --version

echo ""
# Verify a downloaded apt signing key against a pinned PRIMARY-key fingerprint
# allow-set before it is trusted, so a caching-proxy / CDN tamper cannot land an
# attacker key in apt's trust store (the key is fetched over the guest's SSL-bump
# proxy, which is a trust boundary). arg1 = key file; the remaining args are the
# ALLOWED primary fingerprints and the FIRST is also REQUIRED to be present. Only
# primary-key fingerprints are checked, so a vendor rotating a signing subkey
# under a stable primary stays trusted without a pin update. Fail-closed. Mirrors
# verify_key_fingerprints in install/ubuntu.kvm.sh.
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
echo -e "\e[1;36m==== VS Code ====\e[0m"
# The VS Code apt repo provides both amd64 and arm64 packages
curl_retry -fsSL "https://packages.microsoft.com/keys/microsoft.asc${YurunaCacheContent:+?nocache=${YurunaCacheContent}}" -o /tmp/microsoft.asc
sudo install -d -m 755 /etc/apt/keyrings
_yuruna_verify_key_fpr /tmp/microsoft.asc BC528686B50D79E339D3721CEB3E94ADBE1229CF \
    || { echo "NONZERO SCRIPT EXIT: microsoft apt key fingerprint mismatch" >&2; rm -f /tmp/microsoft.asc; exit 1; }
gpg --dearmor < /tmp/microsoft.asc | sudo tee /etc/apt/keyrings/packages.microsoft.gpg > /dev/null
rm -f /tmp/microsoft.asc
echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" | sudo tee /etc/apt/sources.list.d/vscode.list > /dev/null
apt_retry sudo apt-get update
apt_retry sudo apt-get install -y code

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
    export TMPDIR
	echo "TMPDIR not set. Created and set TMPDIR to $TMPDIR"
fi
echo "Visual Studio Code: $(code --version --no-sandbox --user-data-dir "$TMPDIR" 2>&1 || echo 'installed, version probe failed')"
