#!/bin/bash
# Version: 2026.11.05
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# GUID: 42a2e15f-718a-4b8e-97d9-4b0c1aa172ab
# --- REGION: Initialize environment
set -euo pipefail
# Fixed-name downloads and the version probe's throwaway VS Code profile go on
# every path out, an aborted install included; the guest is snapshotted after.
_yuruna_code_profile=""
trap 'rm -f /tmp/dotnet-install.sh /tmp/microsoft.asc; [ -z "${_yuruna_code_profile:-}" ] || rm -rf -- "$_yuruna_code_profile"' EXIT

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
declare -F yuruna_verify_sha256 >/dev/null || { echo "ERROR: this guest's /usr/local/lib/yuruna/yuruna-retry.sh predates pinned-digest checks; rebuild the guest." >&2; exit 1; }
# --- REGION: https://yuruna.link/4220a755-0005
# Re-asserted here because a baked retry lib may still carry a wall-clock bound.
export YURUNA_DNF_STALL_TIMEOUT_SECONDS=0

# --- REGION: Install JDK
echo ""
echo -e "\e[1;36m==== JDK (Amazon Corretto) ====\e[0m"
# See https://yuruna.link/42e220c4-0005
# Discover the newest Corretto development package for this architecture.
CORRETTO_PKG=$(dnf_retry dnf -q repoquery --qf '%{name}\n' 'java-*-amazon-corretto-devel' | sort -Vu | tail -n1) || { echo 'ERROR: Corretto package discovery failed after retries' >&2; exit 1; }
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

# --- REGION: Install .NET SDK
echo ""
echo -e "\e[1;36m==== .NET SDK ====\e[0m"
# See https://yuruna.link/42e220c4-0005
# Microsoft's RPM repositories do not target AL2023; use dotnet-install.sh.
dnf_retry sudo dnf install -y libicu
sudo mkdir -p /usr/local/dotnet
# The installer comes from a pinned commit and runs only after it matches its
# pinned digest; dot.net serves a moving copy.
[ -n "${YURUNA_DOTNET_INSTALL_COMMIT:-}" ] || { echo "ERROR: no dotnet-install commit pin in /usr/local/lib/yuruna/yuruna-versions.sh; rebuild the guest." >&2; exit 1; }
curl_retry -fsSL "https://raw.githubusercontent.com/dotnet/install-scripts/${YURUNA_DOTNET_INSTALL_COMMIT}/src/dotnet-install.sh" -o /tmp/dotnet-install.sh
if ! yuruna_verify_sha256 /tmp/dotnet-install.sh "${YURUNA_DOTNET_INSTALL_SHA256:-}" "dotnet-install.sh at ${YURUNA_DOTNET_INSTALL_COMMIT}"; then
  rm -f /tmp/dotnet-install.sh
  echo "ERROR: dotnet-install.sh does not match its pinned digest; refusing to run it." >&2
  exit 1
fi
sudo bash /tmp/dotnet-install.sh --channel LTS --install-dir /usr/local/dotnet
rm -f /tmp/dotnet-install.sh

sudo ln -sf /usr/local/dotnet/dotnet /usr/local/bin/dotnet
if ! grep -q 'export DOTNET_ROOT=/usr/local/dotnet' /etc/bashrc 2>/dev/null; then
  echo 'export DOTNET_ROOT=/usr/local/dotnet' | sudo tee -a /etc/bashrc
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
# The VS Code yum repo provides both x86_64 and aarch64 packages.
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
# --- REGION: https://yuruna.link/42e220c4-0005
dnf_retry sudo dnf -y install code

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
