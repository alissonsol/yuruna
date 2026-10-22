#!/bin/bash
# Version: 2026.10.22
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# --- REGION: Initialize environment
set -euo pipefail

# --- REGION: Detect architecture
ARCH=$(uname -m)
echo "Detected architecture: $ARCH"
# See https://yuruna.link/42e220c4-0005
case "$ARCH" in
  arm64)
    echo "Environment: arm64 (Apple Silicon)"
    ;;
  *)
    echo "WARNING: Unsupported architecture for macOS 26 guest: $ARCH"
    echo "macOS 26 only runs on arm64 (Apple Silicon)."
    exit 1
    ;;
esac

# --- REGION: Re-read host coordinates per use
# See https://yuruna.link/4220a755-004d
# Match the retry library's four spaced host probes; LAN requests bypass proxies.
yuruna_host_livecheck() {
    local livecheck_url="http://${YURUNA_STATUS_SERVICE_IP:-}:${YURUNA_STATUS_SERVICE_PORT:-}/livecheck"
    local rounds=4 gap=3 round=1
    while [ "$round" -le "$rounds" ]; do
        if curl -fsS --noproxy '*' --max-time 2 -o /dev/null "$livecheck_url" 2>/dev/null; then
            if [ "$round" -gt 1 ]; then
                echo "yuruna: host status service answered on probe ${round}/${rounds} at ${YURUNA_STATUS_SERVICE_IP:-}:${YURUNA_STATUS_SERVICE_PORT:-}"
            fi
            return 0
        fi
        if [ "$round" -lt "$rounds" ]; then sleep "$gap"; fi
        round=$((round + 1))
    done
    return 1
}

# --- REGION: Ensure PowerShell is installed
# See https://yuruna.link/42d69dfa-0036
# Base macOS has curl and installer, so the release .pkg can precede developer tools.
echo ""
echo -e "\e[1;36m==== Ensure PowerShell is installed ====\e[0m"
if ! command -v pwsh >/dev/null 2>&1; then
  # Follow the latest-release redirect without consuming GitHub API quota.
  PS_TAG=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
    "https://github.com/PowerShell/PowerShell/releases/latest")
  PS_TAG="${PS_TAG##*/}"
  if [[ ! "$PS_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "PowerShell version discovery failed (got: '$PS_TAG')" >&2
    exit 1
  fi
  PWSH_VERSION="${PS_TAG#v}"
  PKG_URL="https://github.com/PowerShell/PowerShell/releases/download/${PS_TAG}/powershell-${PWSH_VERSION}-osx-arm64.pkg"
  PWSH_TMP=$(mktemp -d "${TMPDIR:-/tmp}/yuruna-pwsh.XXXXXX")
  trap 'rm -rf "$PWSH_TMP"' EXIT
  PKG_NAME="powershell-${PWSH_VERSION}-osx-arm64.pkg"
  PKG_PATH="$PWSH_TMP/$PKG_NAME"
  echo "Installing PowerShell ${PWSH_VERSION} (osx-arm64) from ${PKG_URL}"
  curl -fSL --retry 3 -o "$PKG_PATH" \
    "${PKG_URL}${YurunaCacheContent:+?nocache=${YurunaCacheContent}}"
  curl -fsSL --retry 3 -o "$PWSH_TMP/hashes.sha256" \
    "https://github.com/PowerShell/PowerShell/releases/download/${PS_TAG}/hashes.sha256"
  PS_BOM=$(od -An -tx1 -N2 "$PWSH_TMP/hashes.sha256" | tr -d ' \n')
  if [[ "$PS_BOM" == "fffe" || "$PS_BOM" == "feff" ]]; then
    iconv -f UTF-16 -t UTF-8 "$PWSH_TMP/hashes.sha256" | tr -d '\r' > "$PWSH_TMP/hashes.norm"
  else
    tr -d '\r' < "$PWSH_TMP/hashes.sha256" > "$PWSH_TMP/hashes.norm"
  fi
  PS_WANT=$(LC_ALL=C awk -v p="$PKG_NAME" '$2 == p || $2 == "*" p {print $1; exit}' "$PWSH_TMP/hashes.norm" | tr 'A-F' 'a-f')
  PS_GOT=$(shasum -a 256 "$PKG_PATH" | awk '{print $1}')
  if [[ ! "$PS_WANT" =~ ^[0-9a-fA-F]{64}$ ]] || [[ "$PS_GOT" != "$PS_WANT" ]]; then
    echo "PowerShell package checksum verification failed for $PKG_NAME" >&2
    exit 1
  fi
  sudo installer -pkg "$PKG_PATH" -target /
  rm -rf "$PWSH_TMP"
  trap - EXIT
fi
pwsh --version

# --- REGION: Install powershell-yaml module
# See https://yuruna.link/42d69dfa-0038
# macOS lacks pwsh_retry; use an inline retry and verify the import.
echo ""
echo -e "\e[1;36m==== Install powershell-yaml module ====\e[0m"
for attempt in 1 2 3; do
  sudo pwsh -NoProfile -Command "Install-Module -Name powershell-yaml -Scope AllUsers -Force" && break
  echo "powershell-yaml install attempt $attempt failed"
  [ $attempt -lt 3 ] && sleep 60
done
sudo pwsh -NoProfile -Command "\$ErrorActionPreference = 'Stop'; Import-Module powershell-yaml -ErrorAction Stop; if ((ConvertFrom-Yaml 'k: v').k -cne 'v') { throw 'powershell-yaml smoke check failed' }"

# --- REGION: Early yuruna framework extraction
# See https://yuruna.link/42d69dfa-0037
# Use curl here; the Git fallback follows the developer-tools install.
echo ""
echo -e "\e[1;36m==== Early yuruna framework extraction ====\e[0m"
REAL_USER="${SUDO_USER:-$USER}"
# Account home paths can contain spaces; strip only Directory Services' key.
REAL_HOME=$(dscl . -read "/Users/$REAL_USER" NFSHomeDirectory | sed -n 's/^NFSHomeDirectory: //p')
case "$REAL_HOME" in
  /*) ;;
  *) echo "Cannot resolve an absolute home directory for $REAL_USER." >&2; exit 1 ;;
esac
# macOS accounts commonly use staff rather than a same-named private group.
REAL_GROUP=$(id -gn "$REAL_USER")
[ -n "$REAL_GROUP" ] || { echo "Cannot resolve the primary group for $REAL_USER." >&2; exit 1; }
if [ -r /etc/yuruna/host.env ]; then
  # shellcheck disable=SC1091
  . /etc/yuruna/host.env
fi
if [ -n "${YURUNA_STATUS_SERVICE_IP:-}" ] && [ -n "${YURUNA_STATUS_SERVICE_PORT:-}" ] && [ ! -d "$REAL_HOME/yuruna" ]; then
  TARBALL_URL="http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}/yuruna-archive.tar.gz"
  if yuruna_host_livecheck; then
    mkdir -p "$REAL_HOME/yuruna"
    # --- REGION: https://yuruna.link/42e220c4-0005
    if curl -fsSL --noproxy '*' --connect-timeout 30 --speed-limit 1024 --speed-time 60 \
         "$TARBALL_URL" | tar -xz -C "$REAL_HOME/yuruna" && [ -f "$REAL_HOME/yuruna/VERSION" ] && [ -s "$REAL_HOME/yuruna/VERSION" ]; then
      sudo chown -R "$REAL_USER:$REAL_GROUP" "$REAL_HOME/yuruna" 2>/dev/null || true
      echo -e "\e[1;32m---- Yuruna framework available at $REAL_HOME/yuruna (early extract). ----\e[0m"
    else
      rm -rf "$REAL_HOME/yuruna"
      echo "yuruna: early tarball fetch failed."
    fi
  else
    echo "yuruna: host status service livecheck failed -- skipping early extract."
  fi
fi

# --- REGION: Disable services that may suspend the machine
# Match the host no-sleep contract; password rotation makes sudo noninteractive.
echo "TESTHACK: Disabling services that may suspend the machine."
sudo pmset -a displaysleep 0 sleep 0 disksleep 0 || true

# --- REGION: Update system packages
# See https://yuruna.link/42e220c4-0005
# Accept the license so unattended update checks cannot prompt.
echo ""
echo -e "\e[1;36m==== macOS update list ====\e[0m"
sudo softwareupdate -l || true

echo ""
echo -e "\e[1;36m==== Update system packages ====\e[0m"
sudo softwareupdate -i -a --agree-to-license || true

# --- REGION: Ensure Git is installed
# macOS supplies Git and Swift through Command Line Developer Tools.
echo ""
echo -e "\e[1;36m==== Ensure Git is installed (Command Line Developer Tools) ====\e[0m"
if ! xcode-select -p >/dev/null 2>&1; then
  # Publish the on-demand developer-tools label for softwareupdate.
  sudo touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  PROD=$(softwareupdate -l 2>/dev/null \
    | grep -E 'Label: Command Line Tools' \
    | tail -1 \
    | sed -E 's/.*Label: //' || true)
  if [ -n "$PROD" ]; then
    sudo softwareupdate -i "$PROD" --verbose --agree-to-license || true
  fi
  sudo rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
fi
if ! xcode-select -p; then
  echo 'Command Line Developer Tools are unavailable; Git cannot run noninteractively.' >&2
  exit 1
fi
git --version

# --- REGION: Resolve framework and project URLs
# See https://yuruna.link/42fa6f45-000c
echo -e "\e[1;32m==== Resolve framework and project URLs ====\e[0m"
FRAMEWORK_URL=""
PROJECT_URL=""
if [ -n "${YURUNA_STATUS_SERVICE_IP:-}" ] && [ -n "${YURUNA_STATUS_SERVICE_PORT:-}" ]; then
  CFG_URL="http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}/control/test-config"
  if cfg_body=$(curl -fsS --noproxy '*' --max-time 5 "$CFG_URL" 2>/dev/null); then
    FRAMEWORK_URL=$(printf '%s' "$cfg_body" | python3 -c $'import json,sys\ntry: print((json.load(sys.stdin).get("repositories") or {}).get("frameworkUrl",""))\nexcept Exception: print("")' 2>/dev/null || true)
    PROJECT_URL=$(printf '%s' "$cfg_body" | python3 -c $'import json,sys\ntry: print((json.load(sys.stdin).get("repositories") or {}).get("projectUrl",""))\nexcept Exception: print("")' 2>/dev/null || true)
  fi
fi

# host.env keeps clone URLs available while the status service is unreachable.
: "${FRAMEWORK_URL:=${YURUNA_FRAMEWORK_URL:-}}"
: "${PROJECT_URL:=${YURUNA_PROJECT_URL:-}}"

# --- REGION: Keep git non-interactive
# See https://yuruna.link/4220a755-004f
export GIT_TERMINAL_PROMPT=0
if [ -x /usr/local/lib/yuruna/git-askpass.sh ]; then
    export GIT_ASKPASS=/usr/local/lib/yuruna/git-askpass.sh
fi

# --- REGION: yuruna_materialize_framework_pin
# This complete helper is embedded in standalone updaters. Python's process
# groups provide the same finite Git deadline on Linux and macOS.
yuruna_materialize_framework_pin() {
    local destination="$1" repository="$2" revision="$3" mirror_ip="${4:-}" mirror_url=''
    [[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
        && [[ "$revision" =~ ^[[:xdigit:]]{40}$ ]] || return 1
    command -v python3 >/dev/null 2>&1 || { echo 'yuruna: Python 3 is required for bounded pinned Git materialization' >&2; return 1; }
    if [[ "$mirror_ip" =~ ^[A-Za-z0-9.-]+$ ]]; then
        if command -v wget >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
            if timeout --kill-after=1 2 wget --no-config --no-proxy --max-redirect=0 --tries=1 --timeout=2 -qO /dev/null \
                "http://${mirror_ip}/git-mirror/status.json" 2>/dev/null; then mirror_url="http://${mirror_ip}/git/${repository}.git"; fi
        elif curl -q --noproxy '*' --max-time 2 --max-redirs 0 -fsS -o /dev/null \
            "http://${mirror_ip}/git-mirror/status.json" 2>/dev/null; then mirror_url="http://${mirror_ip}/git/${repository}.git"; fi
    fi
    python3 - "$destination" "$repository" "$revision" "$mirror_url" <<'YURUNA_PINNED_GIT'
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time

destination, repository, revision, mirror = sys.argv[1:]
revision = revision.lower()
origin = "https://github.com/" + repository + ".git"
if os.path.lexists(destination):
    print("yuruna: pinned materialization refuses to replace existing content", file=sys.stderr)
    sys.exit(1)
sources = ([(mirror, "lan-mirror")] if mirror else []) + [(origin, "github")]

def cancel(signum, _frame):
    raise SystemExit(128 + signum)

signal.signal(signal.SIGTERM, cancel)
signal.signal(signal.SIGINT, cancel)
for url, source in sources:
    stage = tempfile.mkdtemp(prefix=".yuruna-pin.", dir=os.path.dirname(destination))
    deadline = time.monotonic() + 120
    environment = os.environ.copy()
    environment["GIT_TERMINAL_PROMPT"] = "0"
    if source == "lan-mirror":
        # A LAN reader must never receive an inherited GitHub credential, proxy,
        # URL rewrite, extra header, netrc or per-user Git configuration.
        for key in list(environment):
            if key.startswith("GIT_") or key in ("GH_TOKEN", "GITHUB_TOKEN", "SSH_ASKPASS") or key.lower().endswith("_proxy"):
                environment.pop(key)
        private_home = os.path.join(stage, ".empty-home")
        os.mkdir(private_home)
        environment.update(HOME=private_home, XDG_CONFIG_HOME=private_home,
                           GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null",
                           GIT_CONFIG_SYSTEM="/dev/null", GIT_TERMINAL_PROMPT="0")
    options = ["git", "-c", "http.lowSpeedLimit=1024", "-c", "http.lowSpeedTime=60"]
    if source == "lan-mirror":
        options += ["-c", "http.proxy=", "-c", "http.extraHeader=", "-c", "credential.helper=",
                    "-c", "core.askPass=", "-c", "http.followRedirects=false"]

    def run(*arguments, capture=False):
        process = subprocess.Popen(options + list(arguments), env=environment,
                                   stdin=subprocess.DEVNULL, stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, start_new_session=True)
        try:
            output, _ = process.communicate(timeout=max(0.01, deadline - time.monotonic()))
        except BaseException:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.communicate(timeout=2)
            except subprocess.TimeoutExpired:
                pass
            # Git can exit on TERM while a credential or transport child
            # ignores it. The group still needs its unconditional backstop.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate()
            raise
        if process.returncode:
            raise RuntimeError("Git command failed")
        return output.decode("ascii").strip() if capture else ""

    try:
        run("init", "-q", stage)
        run("-C", stage, "fetch", "--no-tags", "--depth=1", url, revision)
        run("-C", stage, "checkout", "--detach", "FETCH_HEAD")
        if run("-C", stage, "rev-parse", "HEAD", capture=True) != revision:
            raise RuntimeError("selected commit did not match HEAD")
        version = pathlib.Path(stage, "VERSION")
        if not version.is_file() or version.stat().st_size == 0:
            raise RuntimeError("framework VERSION is absent or empty")
        for name in (".git", ".empty-home", "dev-only", "docs"):
            path = pathlib.Path(stage, name)
            if path.is_dir() and not path.is_symlink():
                shutil.rmtree(path)
            elif path.exists() or path.is_symlink():
                path.unlink()
        pathlib.Path(stage, ".yuruna-revision").write_text(revision + "\n", encoding="ascii")
        pathlib.Path(stage, ".yuruna-origin").write_text(origin + "\n", encoding="ascii")
        # Another installer winning this destination is never permission to
        # replace it. Rename only after all checks and exclusions have finished.
        if os.path.lexists(destination):
            raise RuntimeError("destination appeared during materialization")
        os.rename(stage, destination)
        print("yuruna: framework source=" + source + " commit=" + revision)
        sys.exit(0)
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print("yuruna: pinned " + source + " materialization failed (" + str(error) + ")", file=sys.stderr)
    finally:
        if os.path.isdir(stage):
            shutil.rmtree(stage)
sys.exit(1)
YURUNA_PINNED_GIT
}

# --- REGION: Materialize the yuruna framework and project repos
# See https://yuruna.link/42e220c4-000e
if [ ! -d "$REAL_HOME/yuruna" ]; then
  HOST_OK=false
  if [ -n "${YURUNA_STATUS_SERVICE_IP:-}" ] && [ -n "${YURUNA_STATUS_SERVICE_PORT:-}" ]; then
    TARBALL_URL="http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}/yuruna-archive.tar.gz"
    if yuruna_host_livecheck; then
      echo "yuruna: fetching committed tarball from $TARBALL_URL"
      mkdir -p "$REAL_HOME/yuruna"
      if curl -fsSL --noproxy '*' --connect-timeout 30 --speed-limit 1024 --speed-time 60 \
           "$TARBALL_URL" | tar -xz -C "$REAL_HOME/yuruna" && [ -f "$REAL_HOME/yuruna/VERSION" ] && [ -s "$REAL_HOME/yuruna/VERSION" ]; then
        HOST_OK=true
      else
        echo "yuruna: tarball fetch/extract failed - falling back to git clone"
        rm -rf "$REAL_HOME/yuruna"
      fi
    fi
  fi
  if [ "$HOST_OK" = "false" ]; then
    PIN_REPO="${E_FB_REPO:-${EXEC_FALLBACK_REPO:-${YURUNA_GITHUB_REPO:-}}}"
    PIN_SHA="${E_FB_REF:-${EXEC_FALLBACK_REF:-${YURUNA_GITHUB_REF:-}}}"
    if [ -n "$PIN_REPO" ] || [ -n "$PIN_SHA" ]; then
      if ! yuruna_materialize_framework_pin "$REAL_HOME/yuruna" "$PIN_REPO" "$PIN_SHA" "${YURUNA_CACHING_PROXY_SERVICE_IP:-}"; then
        echo 'yuruna: pinned framework unavailable; refusing an unpinned clone' >&2
        exit 1
      fi
      HOST_OK=true
    fi
  fi
  if [ "$HOST_OK" = "false" ]; then
    echo 'yuruna: legacy framework fallback is unpinned (no immutable invocation identity)'
    if [ -z "$FRAMEWORK_URL" ]; then
      echo "yuruna: repositories.frameworkUrl missing from test.config.yml - cannot clone framework" >&2
      exit 1
    fi
    for attempt in 1 2 3; do
      git -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=60 clone "$FRAMEWORK_URL" "$REAL_HOME/yuruna" && [ -f "$REAL_HOME/yuruna/VERSION" ] && [ -s "$REAL_HOME/yuruna/VERSION" ] && break
      echo "git clone attempt $attempt failed"
      rm -rf "$REAL_HOME/yuruna"
      [ $attempt -lt 3 ] && sleep 60
    done
    if [ ! -f "$REAL_HOME/yuruna/VERSION" ] || [ ! -s "$REAL_HOME/yuruna/VERSION" ]; then
      echo "git clone failed after 3 attempts" >&2
      exit 1
    fi
  fi
fi

if [ ! -d "$REAL_HOME/yuruna/project" ]; then
  PROJECT_HOST_OK=false
  if [ -n "${YURUNA_STATUS_SERVICE_IP:-}" ] && [ -n "${YURUNA_STATUS_SERVICE_PORT:-}" ]; then
    if ! yuruna_host_livecheck; then
      echo "yuruna: host status service did not answer at ${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}"
    else
      PROJECT_TARBALL_URL="http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}/yuruna-project-archive.tar.gz"
      echo "yuruna: trying project tarball at $PROJECT_TARBALL_URL"
      mkdir -p "$REAL_HOME/yuruna/project"
      if curl -fsSL --noproxy '*' --connect-timeout 5 --speed-limit 1024 --speed-time 5 \
           "$PROJECT_TARBALL_URL" 2>/dev/null \
           | tar -xz -C "$REAL_HOME/yuruna/project" 2>/dev/null \
           && [ -n "$(ls -A "$REAL_HOME/yuruna/project" 2>/dev/null)" ]; then
        PROJECT_HOST_OK=true
      else
        echo "yuruna: project tarball not served (or empty) - falling back to git clone"
        rm -rf "$REAL_HOME/yuruna/project"
      fi
    fi
  fi
  if [ "$PROJECT_HOST_OK" = "false" ] && [ -n "$PROJECT_URL" ]; then
    for attempt in 1 2 3; do
      git -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=60 clone "$PROJECT_URL" "$REAL_HOME/yuruna/project" && break
      echo "project git clone attempt $attempt failed"
      rm -rf "$REAL_HOME/yuruna/project"
      [ $attempt -lt 3 ] && sleep 60
    done
    if [ ! -d "$REAL_HOME/yuruna/project" ]; then
      echo "project git clone failed after 3 attempts" >&2
      exit 1
    fi
  fi
fi

# --- REGION: Restore operator file ownership
# Tarball extraction and any sudo'd cleanup may have left root-owned files.
sudo chown -R "$REAL_USER:$REAL_GROUP" "$REAL_HOME/yuruna" 2>/dev/null || true

echo ""
# --- REGION: https://yuruna.link/42e220c4-0005
echo -e "\e[1;32m==== Update complete. ====\e[0m"
