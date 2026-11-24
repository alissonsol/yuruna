#!/bin/bash
# Version: 2026.11.23
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# GUID: 42a41911-ddd8-4ff6-be45-dca2d7fc173f
# --- REGION: Initialize environment
set -euo pipefail
# The downloaded key and the folder of the headless check go on every path out,
# an aborted install included; the guest is snapshotted after.
_yuruna_browser_key=""
_yuruna_browser_check=""
trap '[ -z "${_yuruna_browser_key:-}" ] || rm -f -- "$_yuruna_browser_key"; [ -z "${_yuruna_browser_check:-}" ] || rm -rf -- "$_yuruna_browser_check"' EXIT

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
DEB_ARCH=$(dpkg --print-architecture)
case "$DEB_ARCH" in
  amd64|arm64) ;;
  *)
    echo "NONZERO SCRIPT EXIT: unsupported package architecture ${DEB_ARCH}" >&2
    exit 1
    ;;
esac

# --- REGION: Load retry helpers
# See https://yuruna.link/4220a755-0003
. /usr/local/lib/yuruna/yuruna-retry.sh
declare -F _yuruna_verify_key_fpr >/dev/null || { echo "ERROR: this guest's /usr/local/lib/yuruna/yuruna-retry.sh predates key fingerprint checks; rebuild the guest." >&2; exit 1; }
# --- REGION: https://yuruna.link/4220a755-0005
# Re-asserted here because a baked retry lib may still carry a wall-clock bound.
export YURUNA_APT_STALL_TIMEOUT_SECONDS=0

# --- REGION: Install the browser
# See https://yuruna.link/4220a755-001e
# Google Chrome from Google's signed apt repository: one package for both releases and
# both architectures. The key is trusted by its pinned primary fingerprint, never by TLS,
# because the lab proxy re-signs HTTPS.
if dpkg-query -W -f='${db:Status-Status}' google-chrome-stable 2>/dev/null | grep -qx installed; then
    echo "google-chrome-stable is installed; keeping it."
else
    command -v gpg >/dev/null 2>&1 || apt_retry sudo apt-get install -y gnupg
    _yuruna_browser_key="$(mktemp)"
    curl_retry -fsSL \
        "https://dl.google.com/linux/linux_signing_key.pub${YurunaCacheContent:+?nocache=${YurunaCacheContent}}" \
        -o "$_yuruna_browser_key"
    _yuruna_verify_key_fpr "$_yuruna_browser_key" EB4C1BFD4F042F6DDDCCEC917721F63BD38B4796 \
        || { echo "NONZERO SCRIPT EXIT: google apt key fingerprint mismatch" >&2; exit 1; }
    sudo install -d -m 755 /etc/apt/keyrings
    gpg --dearmor < "$_yuruna_browser_key" \
        | sudo tee /etc/apt/keyrings/google-linux.gpg > /dev/null
    rm -f -- "$_yuruna_browser_key"
    # Written before the install, so the package's post-installation script adds no
    # second source of its own. The source file is not named google-chrome.list:
    # the package deletes a file of that name.
    printf 'repo_add_once="false"\nrepo_reenable_on_distupgrade="false"\n' \
        | sudo tee /etc/default/google-chrome > /dev/null
    echo "deb [arch=${DEB_ARCH} signed-by=/etc/apt/keyrings/google-linux.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
        | sudo tee /etc/apt/sources.list.d/yuruna-google-chrome.list > /dev/null
    apt_retry sudo apt-get update
    apt_retry sudo apt-get install -y --no-install-recommends google-chrome-stable
fi

# --- REGION: Verify the browser
# The browser must start headless from the session this script runs in, which has no
# terminal and no display. The sandbox stays on: a release where it cannot start is
# not verified, and no flag weakens it.
BROWSER_PATH=$(command -v google-chrome-stable) \
    || { echo "NONZERO SCRIPT EXIT: google-chrome-stable is not on PATH" >&2; exit 1; }
BROWSER_VERSION=$("$BROWSER_PATH" --version)
_yuruna_browser_check="$(mktemp -d)"
mkdir "$_yuruna_browser_check/home"
if ! HOME="$_yuruna_browser_check/home" TMPDIR="$_yuruna_browser_check" \
        timeout --kill-after=5s 60s "$BROWSER_PATH" --headless=new --no-first-run --disable-gpu \
        "--user-data-dir=$_yuruna_browser_check/profile" --dump-dom about:blank \
        > "$_yuruna_browser_check/dom.txt" 2> "$_yuruna_browser_check/err.txt" \
    || ! grep -q '<body>' "$_yuruna_browser_check/dom.txt"; then
    tail -n 20 "$_yuruna_browser_check/err.txt" >&2 || true
    echo "NONZERO SCRIPT EXIT: the browser did not render about:blank headless" >&2
    exit 1
fi

# --- REGION: Installation summary
echo ""
echo "== Installation Summary =="
echo "Browser: ${BROWSER_PATH}"
echo "Browser version: ${BROWSER_VERSION}"
echo "Browser architecture: ${DEB_ARCH}"
