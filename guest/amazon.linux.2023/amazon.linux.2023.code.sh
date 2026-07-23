#!/bin/bash
# Version: 2026.07.22
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
set -euo pipefail

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
# Baked retry libs may default dnf attempts to a wall-clock bound -- the
# wrapped-apt teardown-hang trap class (the package manager blocks at
# end-of-transaction under a timeout(1) parent). Force unbounded regardless
# of the image's lib vintage; remove once no image predates the lib's
# unbounded default.
export YURUNA_DNF_STALL_TIMEOUT=0

echo ""
echo -e "\e[1;36m==== JDK (Amazon Corretto) ====\e[0m"
# Amazon Corretto provides both x86_64 and aarch64 packages. Install the
# newest Corretto devel package instead of a pinned major -- Corretto ships
# only LTS majors, so "highest available" is the current LTS.
CORRETTO_PKG=$(dnf -q repoquery --qf '%{name}\n' 'java-*-amazon-corretto-devel' 2>/dev/null | sort -Vu | tail -n1)
if [ -z "$CORRETTO_PKG" ]; then
  echo "ERROR: no java-*-amazon-corretto-devel package found in the repos" >&2
  exit 1
fi
dnf_retry sudo dnf install -y "$CORRETTO_PKG"
java -version
javac -version
export JAVA_HOME=/etc/alternatives/java_sdk
if ! grep -q 'export JAVA_HOME=/etc/alternatives/java_sdk' /etc/bashrc 2>/dev/null; then
  echo 'export JAVA_HOME=/etc/alternatives/java_sdk' | sudo tee -a /etc/bashrc
fi

echo ""
echo -e "\e[1;36m==== .NET SDK ====\e[0m"
# Use Microsoft's official dotnet-install.sh script instead of RPM repos.
# The CentOS 8/9 repo configs are incompatible with Amazon Linux 2023 (Fedora-based).
# dotnet-install.sh auto-detects architecture (x86_64/aarch64) and works reliably.
# Install libicu dependency required by .NET for globalization support.
dnf_retry sudo dnf install -y libicu
sudo mkdir -p /usr/local/dotnet
curl_retry -sSL "https://dot.net/v1/dotnet-install.sh${YurunaCacheContent:+?nocache=${YurunaCacheContent}}" -o /tmp/dotnet-install.sh
chmod +x /tmp/dotnet-install.sh
sudo bash /tmp/dotnet-install.sh --channel LTS --install-dir /usr/local/dotnet
rm -f /tmp/dotnet-install.sh

# Make dotnet available system-wide
sudo ln -sf /usr/local/dotnet/dotnet /usr/local/bin/dotnet
if ! grep -q 'export DOTNET_ROOT=/usr/local/dotnet' /etc/bashrc 2>/dev/null; then
  echo 'export DOTNET_ROOT=/usr/local/dotnet' | sudo tee -a /etc/bashrc
fi
dotnet --version || echo "dotnet: version probe failed (non-fatal)"

echo ""
echo -e "\e[1;36m==== VS Code ====\e[0m"
# The VS Code yum repo provides both x86_64 and aarch64 packages.
# --- REGION: https://yuruna.link/network#apt-signing-key-fingerprint-verification
# Fetch the Microsoft signing key, fingerprint-pin it BEFORE trusting it,
# then rpm --import the VERIFIED local copy and point the repo gpgkey at that
# local file -- instead of blindly `rpm --import`-ing the URL (swallowing failure
# with `|| true`) and letting gpgcheck=1 re-fetch the same unverified URL. Fail
# closed on a mismatch. Mirrors the ubuntu code.sh apt path.
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
# gpg is required for the fingerprint check; Amazon Linux 2023 may not ship it.
command -v gpg >/dev/null 2>&1 || dnf_retry sudo dnf install -y gnupg2
curl_retry -fsSL "https://packages.microsoft.com/keys/microsoft.asc${YurunaCacheContent:+?nocache=${YurunaCacheContent}}" -o /tmp/microsoft.asc
_yuruna_verify_key_fpr /tmp/microsoft.asc BC528686B50D79E339D3721CEB3E94ADBE1229CF \
    || { echo "NONZERO SCRIPT EXIT: microsoft rpm key fingerprint mismatch" >&2; rm -f /tmp/microsoft.asc; exit 1; }
sudo install -d -m 755 /etc/pki/rpm-gpg
sudo cp /tmp/microsoft.asc /etc/pki/rpm-gpg/microsoft.asc
sudo rpm --import /etc/pki/rpm-gpg/microsoft.asc
rm -f /tmp/microsoft.asc
sudo sh -c 'echo -e "[code]\nname=Visual Studio Code\nbaseurl=https://packages.microsoft.com/yumrepos/vscode\nenabled=1\ngpgcheck=1\ngpgkey=file:///etc/pki/rpm-gpg/microsoft.asc" > /etc/yum.repos.d/vscode.repo'
dnf_retry sudo dnf -y install code

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
