#!/bin/bash
# Version: 2026.11.16
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# GUID: 42c18f3d-326c-467e-a500-0668e518bf56
# Yuruna Ubuntu KVM/libvirt bootstrap installer.
# See https://yuruna.link/429fb30b
# One-liner: bash <(curl -fsSL https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/ubuntu.kvm.sh)
# Supported target: Ubuntu 26.04 (Resolute) or newer on x86_64 (aarch64 supported but UNTESTED -- see preflight).

set -Eeuo pipefail

YURUNA_REPO_PUBLIC="https://github.com/alissonsol/yuruna.git"
YURUNA_REPO_PRIVATE="https://github.com/alissonsol/yurunadev.git"
YURUNA_REPO="${YURUNA_REPO:-$YURUNA_REPO_PUBLIC}"
# --- REGION: https://yuruna.link/429fb30b-0008
YURUNA_BRANCH_EXPLICIT=0
[[ -n "${YURUNA_BRANCH:-}" ]] && YURUNA_BRANCH_EXPLICIT=1
YURUNA_BRANCH="${YURUNA_BRANCH:-main}"
# --- REGION: https://yuruna.link/429fb30b-0006
PIN_VERSION="${PIN_VERSION:-0}"
for _yuruna_arg in "$@"; do
  [[ "$_yuruna_arg" == "--pin-version" ]] && PIN_VERSION=1
done
YURUNA_DIR="${YURUNA_DIR:-$HOME/git/yuruna}"

# Pinned apt signing-key fingerprints, verified before each key is trusted as
# an apt anchor (a MITM that swaps the key fetch otherwise plants a permanent
# trust root). Refresh on a vendor key rotation: re-fetch the key, confirm the
# new fingerprint with `gpg --show-keys --with-colons`, and update the value.
MS_APT_KEY_FPR="AA86F75E427A19DD33346403EE4D7792F748182B"       # Microsoft 2025 General GPG Signer (Ubuntu >= 25.10 prod repo)
MS_APT_KEY_FPR_NOBLE="BC528686B50D79E339D3721CEB3E94ADBE1229CF" # Microsoft (Release signing), microsoft.asc: signs the Ubuntu 24.04 prod repo
GH_APT_KEY_FPR_NEW="7F38BBB59D064DBCB3D84D725612B36462313325"   # GitHub CLI (current)
GH_APT_KEY_FPR_OLD="2C6106201985B60E6C7AC87323F3D4EA75716059"   # GitHub CLI (legacy, expires 2026-09-05)

_yuruna_step="<starting up>"
log()  { _yuruna_step="$*"; printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mXX \033[0m %s\n' "$*" >&2; exit 1; }

# --- REGION: Deferred issues
# Every non-fatal problem is recorded here as well as printed where it happens:
# hundreds of lines scroll past, and the closing summary is what survives.
# Nothing here stops the run, but a problem must not pass unmentioned either.
YURUNA_ISSUES=()
note_issue() { YURUNA_ISSUES+=("$*"); warn "$*"; }

# --- REGION: https://yuruna.link/429fb30b-0003
if [[ -z "${YURUNA_INSTALL_LOG:-}" ]]; then
  _yuruna_log_dir="${XDG_STATE_HOME:-$HOME/.local/state}/yuruna/logs"
  mkdir -p "$_yuruna_log_dir" 2>/dev/null || _yuruna_log_dir="${TMPDIR:-/tmp}"
  YURUNA_INSTALL_LOG="$_yuruna_log_dir/ubuntu.kvm.install.$(date +%Y%m%d-%H%M%S).log"
fi
export YURUNA_INSTALL_LOG
_yuruna_tee_pid=""
_yuruna_logfifo="$(mktemp -u 2>/dev/null || echo "${TMPDIR:-/tmp}/yuruna-logfifo.$$")"
if mkfifo "$_yuruna_logfifo" 2>/dev/null; then
  tee -a "$YURUNA_INSTALL_LOG" < "$_yuruna_logfifo" &
  _yuruna_tee_pid=$!
  exec > "$_yuruna_logfifo" 2>&1
  rm -f "$_yuruna_logfifo"        # fds keep the unlinked pipe alive
fi
# Flush + reap tee at exit so the on-disk log is complete. Called LAST from the
# EXIT trap, after the sudo keepalive (another holder of the pipe) is killed.
_yuruna_flush_log() {
  if [[ -n "${_yuruna_tee_pid:-}" ]]; then
    exec >&- 2>&- || true        # close the write end so tee sees EOF
    wait "$_yuruna_tee_pid" 2>/dev/null || true
  fi
}
if [[ -n "$_yuruna_tee_pid" ]]; then
  log "Install log: $YURUNA_INSTALL_LOG"
  log "  (inspect this file if the installer stops midway)"
else
  warn "Could not create an install log file; output goes to this terminal only."
fi

# --- REGION: https://yuruna.link/4220a755-001e
# Verify a downloaded apt signing key before trusting it as an apt anchor (a
# MITM that swaps the key fetch would otherwise plant a permanent trust root).
# Works on armored .asc and binary .gpg key files.
verify_key_fingerprints() {
  local keyfile="$1"; shift
  local required="${1^^}"
  local allowed=("$@")
  local present a fpr ok found_required=0
  present="$(gpg --show-keys --with-colons "$keyfile" 2>/dev/null \
            | awk -F: '/^pub:/{p=1} /^fpr:/{if(p){print toupper($10); p=0}}')"
  [[ -n "$present" ]] || die "No primary key fingerprints in $keyfile (is gpg installed?)"
  while IFS= read -r fpr; do
    fpr="${fpr//[$'\r\n\t ']/}"
    [[ -z "$fpr" ]] && continue
    ok=0
    for a in "${allowed[@]}"; do [[ "${a^^}" == "$fpr" ]] && { ok=1; break; }; done
    (( ok )) || die "Unexpected key fingerprint in $keyfile: $fpr (not in the pinned allow-set)"
    [[ "$fpr" == "$required" ]] && found_required=1
  done <<<"$present"
  (( found_required )) || die "Required key fingerprint $required missing from $keyfile"
}

# A --recv-keys against a throwaway GnuPG home starts dirmngr (and gpg-agent
# or keyboxd as needed) for that home; deleting the home does not stop them,
# and on a systemd host their sockets live under /run/user, outside it.
stop_gpg_home() {
  command -v gpgconf >/dev/null 2>&1 || return 0
  gpgconf --homedir "$1" --kill all >/dev/null 2>&1 || true
  gpgconf --homedir "$1" --remove-socketdir >/dev/null 2>&1 || true
}

# --- REGION: ERR trap
# See https://yuruna.link/429fb30b-002e
_yuruna_on_err() {
    local rc=$?
    printf '\n\033[1;31mXX \033[0m installer aborted (exit %d)\n' "$rc" >&2
    printf '   step    : %s\n' "$_yuruna_step" >&2
    printf '   line    : %s\n' "${BASH_LINENO[0]:-?}" >&2
    printf '   command : %s\n' "${BASH_COMMAND:-?}" >&2
    printf '   log     : %s\n' "${YURUNA_INSTALL_LOG:-<none>}" >&2
    printf '\n   Re-run with `bash -x <script>` to trace every command,\n' >&2
    printf   '   or `sudo apt-get update` directly to see apt errors verbatim.\n' >&2
    exit "$rc"
}
trap _yuruna_on_err ERR

# --- REGION: Preflight: Linux only
[[ "$(uname -s)" == "Linux" ]] || die "This installer only supports Linux."
[[ -r /etc/os-release ]] || die "/etc/os-release missing -- not a recognized Linux."
. /etc/os-release
[[ $EUID -ne 0 ]] || die "Do not run as root. The script will call sudo when needed."

# --- REGION: Preflight: this account can elevate
# See https://yuruna.link/42e220c4-0015
# Check the running session before any interactive elevation prompt.
group_names() {
  { id -Gn ${1:+"$1"} 2>/dev/null || true; } | tr ' ' '\n'
}
_yuruna_whoami="${USER:-$(id -un)}"
if ! sudo -n -v 2>/dev/null && ! group_names | grep -xE 'sudo|wheel' >/dev/null; then
  die "$_yuruna_whoami cannot elevate: this session is in neither the 'sudo' nor the 'wheel' group, so sudo will refuse and the installer cannot continue.

   From an account that can already elevate, run:
       sudo usermod -aG sudo $_yuruna_whoami

   Then sign $_yuruna_whoami out and back in -- the group list is fixed when a
   session starts, so an already-open one stays refused -- and start the
   installer again."
fi

# --- REGION: Preflight: host architecture
# Recorded here and judged by the system requirements below; aarch64 is supported
# but untested.
ARCH="$(uname -m)"

# The AMD Ryzen AI Developer Platform is Debian trixie underneath; regions
# further down adjust to it. Matched on the release name it ships.
is_amd_ryzen_ai_platform() {
  [[ "${PRETTY_NAME:-}" == "AMD Ryzen AI Developer"* ]]
}

log "Yuruna Ubuntu KVM installer starting"
log "  distro : ${PRETTY_NAME:-${ID:-unknown} ${VERSION_ID:-unknown}}"
log "  arch   : $ARCH"
log "  repo   : $YURUNA_REPO ($YURUNA_BRANCH)"
log "  target : $YURUNA_DIR"

# --- REGION: Preflight: system requirements
preflight_system_requirements() {
  local issues=()
  local cores mem_kb mem_gb disk_kb disk_gb ubuntu_major ubuntu_minor ubuntu_num
  if [[ "${ID:-unknown}" != "ubuntu" ]]; then
    issues+=("distro '${PRETTY_NAME:-$ID}' detected (need Ubuntu 26+)")
  fi
  local os_version="${VERSION_ID:-0}"
  ubuntu_major="${os_version%%.*}"
  ubuntu_minor="${os_version#*.}"
  ubuntu_num=$(( 10#${ubuntu_major:-0} * 100 + 10#${ubuntu_minor:-0} ))
  if (( ubuntu_num < 2604 )); then
    issues+=("Ubuntu ${VERSION_ID:-?} detected (need 26.04+)")
  fi
  if [[ "$ARCH" != "x86_64" ]]; then
    issues+=("architecture '$ARCH' detected (need amd64/x86_64)")
  fi
  cores=$(nproc --all 2>/dev/null || echo 0)
  if (( cores < 16 )); then
    issues+=("$cores cores detected (need 16+)")
  fi
  mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
  # Round to nearest GB (add half the divisor) so a box a fraction under the
  # boundary -- e.g. 32 GB reporting 31.6 GB MemTotal -- is not warned as 31.
  mem_gb=$(( (${mem_kb:-0} + 512 * 1024) / (1024 * 1024) ))
  if (( mem_gb < 32 )); then
    issues+=("${mem_gb}GB RAM detected (need 32GB+)")
  fi
  disk_kb=$(df -k / 2>/dev/null | awk 'NR==2 {print $4}')
  disk_gb=$(( (${disk_kb:-0} + 512 * 1024) / (1024 * 1024) ))
  if (( disk_gb < 512 )); then
    issues+=("${disk_gb}GB free on / (need 512GB+)")
  fi
  if (( ${#issues[@]} == 0 )); then
    log "System OK: $cores cores, ${mem_gb}GB RAM, ${disk_gb}GB free on /"
    return 0
  fi
  warn ''
  warn '========'
  warn '  System does not meet Yuruna TESTED requirements:'
  local i; for i in "${issues[@]}"; do warn "    - $i"; done
  warn ''
  warn '  Tested baseline (Ubuntu host):'
  warn '    32GB RAM, 512GB free, Ubuntu 26+ on amd64, 16+ cores.'
  warn ''
  warn '  Continuing is permitted but UNTESTED; the test harness may'
  warn '  fail in ways the core development team cannot reproduce.'
  warn '========'
  warn ''
  local ans
  read -r -p 'Continue anyway? [y/N]: ' ans
  case "$(printf '%s' "${ans:-}" | tr '[:upper:]' '[:lower:]')" in
    y|yes) log 'Proceeding despite unmet requirements.' ;;
    *)     die 'Aborted by user (system requirements not met).' ;;
  esac
}
preflight_system_requirements

# --- REGION: Elevation announcement
# Prime sudo once and keep its timestamp alive for the whole run.
# See https://yuruna.link/429fb30b-002b
cat <<'SUDO_NOTICE'

  +---------------------------------------------------------------+
  |  This installer needs sudo for:                               |
  |    * apt-get install (qemu/libvirt/virt-install/pwsh/...)     |
  |    * usermod -aG libvirt,kvm <you>                            |
  |    * systemctl enable --now libvirtd virtlogd                 |
  |    * cloud-init ISO build (genisoimage / cloud-localds)       |
  |  You will be prompted for your sudo password ONCE, below.     |
  +---------------------------------------------------------------+

SUDO_NOTICE
sudo -v || die "sudo did not authorize this run; the installer needs root for apt-get, usermod and the libvirt services."
export YURUNA_SUDO_PRIMED=1
( while true; do sudo -n true 2>/dev/null || true; sleep 30; kill -0 "$$" 2>/dev/null || exit; done ) &
SUDO_KEEPALIVE_PID=$!

# --- REGION: EXIT trap
YURUNA_STATUS_BACKUP=""
# Every temp path this installer creates is registered here and removed by the
# EXIT trap, whatever ends the run: a die(), a set -e abort, the ERR trap, or a
# signal. Removing a path on each function's own success path is not enough --
# those paths are exactly the ones a failure skips. A subshell that may exit
# early sets yuruna_cleanup_tmp_paths as its own EXIT trap, because the parent's
# registry never sees what the subshell adds. The ${arr[@]+...} form keeps an
# empty array safe under set -u on bash 3.2, which macOS still ships.
YURUNA_TMP_PATHS=()
yuruna_track_tmp() {
  [[ -n "${1:-}" ]] && YURUNA_TMP_PATHS+=("$1")
  return 0
}
yuruna_cleanup_tmp_paths() {
  local p
  for p in ${YURUNA_TMP_PATHS[@]+"${YURUNA_TMP_PATHS[@]}"}; do
    [[ -n "$p" && ( -e "$p" || -L "$p" ) ]] || continue
    # Completed recovery capsules survive until the operator removes them:
    # restart and rollback can happen after this installer process exits.
    if [[ "$p" == "${YURUNA_INSTALLER_STATE_DIR:-}" && "${YURUNA_INSTALLER_STATE_RETAINED:-0}" -eq 1 ]]; then continue; fi
    # A build tree can hold root-owned files; sudo is primed for the whole run.
    rm -rf -- "$p" 2>/dev/null || sudo -n rm -rf -- "$p" 2>/dev/null || true
  done
  YURUNA_TMP_PATHS=()
}
# --- REGION: Machine-readable outcome
# One JSON record of how the run ended, at a fixed path and beside the log, so a
# caller (automation, a nested host) reads the outcome instead of parsing the
# closing text: outcome succeeded | succeeded-with-issues | failed, the exit code,
# the last step, every deferred issue, the installed VERSION and the log path.
# Best-effort: it runs from the EXIT trap and never changes the exit code.
yuruna_json_string() {
  # A character loop rather than ${s//...}: bash 3.2 (macOS) and 5.x treat a
  # backslash in a pattern replacement differently, while double-quote escaping
  # below means the same in every version.
  local s="$1" out="" c i
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      '\') out="$out\\\\" ;;
      '"') out="$out\\\"" ;;
      $'\n') out="$out\\n" ;;
      $'\r') out="$out\\r" ;;
      $'\t') out="$out\\t" ;;
      *) out="$out$c" ;;
    esac
  done
  out="$(printf '%s' "$out" | LC_ALL=C tr -d '\000-\010\013\014\016-\037')"
  printf '"%s"' "$out"
}
write_install_result() {
  local rc="$1" installer="$2" outcome dir file issues_json="" issue version=""
  if [[ "$rc" -ne 0 ]]; then
    outcome="failed"
  elif [[ ${#YURUNA_ISSUES[@]} -gt 0 ]]; then
    outcome="succeeded-with-issues"
  else
    outcome="succeeded"
  fi
  if [[ ${#YURUNA_ISSUES[@]} -gt 0 ]]; then
    for issue in "${YURUNA_ISSUES[@]}"; do
      [[ -z "$issues_json" ]] || issues_json="$issues_json,"
      issues_json="$issues_json$(yuruna_json_string "$issue")"
    done
  fi
  if [[ -n "${YURUNA_DIR:-}" && -r "${YURUNA_DIR:-}/VERSION" ]]; then
    version="$(tr -d '[:space:]' < "$YURUNA_DIR/VERSION" 2>/dev/null || true)"
  fi
  dir="${XDG_STATE_HOME:-$HOME/.local/state}/yuruna"
  mkdir -p "$dir" 2>/dev/null || return 0
  file="$dir/install-result.json"
  if printf '{"schema":1,"installer":%s,"version":%s,"outcome":"%s","exitCode":%d,"step":%s,"issues":[%s],"log":%s,"finishedUtc":"%s"}\n' \
       "$(yuruna_json_string "$installer")" "$(yuruna_json_string "$version")" "$outcome" "$rc" \
       "$(yuruna_json_string "${_yuruna_step:-}")" "$issues_json" "$(yuruna_json_string "${YURUNA_INSTALL_LOG:-}")" \
       "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$file.tmp" 2>/dev/null && mv -f "$file.tmp" "$file" 2>/dev/null; then
    if [[ -n "${YURUNA_INSTALL_LOG:-}" ]]; then cp -f "$file" "${YURUNA_INSTALL_LOG%.log}.result.json" 2>/dev/null || true; fi
  fi
  return 0
}

yuruna_install_cleanup() {
  local rc=$? command="${BASH_COMMAND:-?}"
  kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  if [[ -n "${YURUNA_STATUS_BACKUP:-}" && -d "${YURUNA_STATUS_BACKUP:-}" ]]; then
    rm -rf "$YURUNA_STATUS_BACKUP" 2>/dev/null || true
  fi
  yuruna_cleanup_tmp_paths
  if [[ $rc -ne 0 ]]; then
    printf '\n\033[1;31mXX \033[0m installer exited with code %d.\n' "$rc" >&2
    printf '   step    : %s\n' "${_yuruna_step:-?}" >&2
    printf '   command : %s\n' "$command" >&2
    printf '   log     : %s\n' "${YURUNA_INSTALL_LOG:-<none>}" >&2
  fi
  write_install_result "$rc" "ubuntu.kvm"
  _yuruna_flush_log
}
trap yuruna_install_cleanup EXIT

# --- REGION: Preflight: CPU virtualization
# See https://yuruna.link/429fb30b-002f
HAVE_VMX=0
if grep -qE '(vmx|svm)' /proc/cpuinfo 2>/dev/null; then
  HAVE_VMX=1
elif [[ "$ARCH" == "aarch64" ]]; then
  HAVE_VMX=1
fi
if [[ $HAVE_VMX -eq 0 ]]; then
  die "CPU virtualization extensions (vmx/svm) not detected in /proc/cpuinfo.
       Either virtualization is disabled in firmware (enable Intel VT-x or
       AMD-V in BIOS/UEFI) or this is a guest VM without nested
       virtualization. Without KVM acceleration the test harness is
       unusable -- aborting before installing anything."
fi

# --- REGION: Private installer recovery state
# This capsule also lives in Test.SingleInstance; the standalone installer must
# keep working when no checkout modules can be loaded.
YURUNA_INSTALLER_STATE_DIR=""
YURUNA_INSTALLER_CONFIG_ONLY=0
YURUNA_INSTALLER_STATE_RETAINED=0
invoke_yuruna_installer_state() {
  YURUNA_INSTALLER_ACTION="$1" YURUNA_INSTALLER_ROOT="$YURUNA_DIR" \
    YURUNA_INSTALLER_SNAPSHOT="$YURUNA_INSTALLER_STATE_DIR/state.json" \
    pwsh -NoProfile -NonInteractive -Command - <<'YURUNA_INSTALLER_STATE_PS'
function Invoke-YurunaInstallerState {
    <#
    .SYNOPSIS
        Capture or restore private installer recovery state without a module dependency.
    .DESCRIPTION
        Embedded verbatim in each standalone installer. Capture runs before
        stopping a runner; restore validates the candidate runner before any
        config seeding. Existing different files are never overwritten. The
        frozen launch record is retained for an explicit operator start, and
        never changes the live record's cleanExit flag.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Installer transaction helper; capture and restore are explicit actions with fail-closed validation.')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][ValidateSet('Capture', 'Restore', 'Read')][string]$Action,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$SnapshotPath,
        [string]$RuntimeDir,
        [string]$PrivateRoot
    )
    $ErrorActionPreference = 'Stop'
    $comparison = if ($IsLinux) { [StringComparison]::Ordinal } else { [StringComparison]::OrdinalIgnoreCase }
    $repo = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('/', '\')
    $runtimeExplicit = -not [string]::IsNullOrEmpty($RuntimeDir) -or -not [string]::IsNullOrEmpty($env:YURUNA_RUNTIME_DIR)
    if (-not $RuntimeDir) { $RuntimeDir = if ($env:YURUNA_RUNTIME_DIR) { $env:YURUNA_RUNTIME_DIR } else { Join-Path $repo 'test/status/runtime' } }
    $runtime = [IO.Path]::GetFullPath($RuntimeDir).TrimEnd('/', '\')
    $snapshot = [IO.Path]::GetFullPath($SnapshotPath)
    foreach ($served in @($repo, $runtime)) {
        if ($snapshot.StartsWith($served + [IO.Path]::DirectorySeparatorChar, $comparison)) {
            throw 'Installer recovery state must be outside the checkout and runtime directory.'
        }
    }
    $hashBytes = { param([byte[]]$Value) [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Value)).ToLowerInvariant() }
    $readBytes = {
        param([string]$Path, [long]$Limit)
        $info = [IO.FileInfo]::new($Path)
        if ($info.LinkTarget -or -not $info.Exists -or $info.Length -gt $Limit) { throw "Installer state file is missing, linked, or too large: $Path" }
        [byte[]]$value = [IO.File]::ReadAllBytes($Path)
        if ($value.Length -gt $Limit) { throw "Installer state file grew beyond its limit: $Path" }
        return ,$value
    }
    $jsonOption = @{}
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $jsonOption.DateKind = 'String' }
    $validateLaunch = {
        param($Launch)
        if ($null -eq $Launch) { return }
        if ($Launch -isnot [Collections.IDictionary] -or $Launch.schemaVersion -ne 1 -or $Launch.runnerProtocolVersion -ne 1) {
            throw 'Installer launch record has an unsupported schema or runner protocol.'
        }
        $scriptPath = Join-Path $repo 'test/Start-TestRunner.ps1'
        if (-not [string]::Equals([IO.Path]::GetFullPath([string]$Launch.scriptPath), $scriptPath, $comparison) -or
            -not [string]::Equals([IO.Path]::GetFullPath([string]$Launch.repoRoot).TrimEnd('/', '\'), $repo, $comparison)) {
            throw 'Installer launch record belongs to another checkout.'
        }
        if ($Launch.parameters -isnot [Collections.IDictionary] -or $Launch.environment -isnot [Collections.IDictionary]) {
            throw 'Installer launch record has no validated parameters or environment.'
        }
        $names = @('ConfigPath', 'NoGitPull', 'NoStatusService', 'NoConfigGate', 'CycleDelaySeconds', 'logLevel')
        if ($Launch.parameters.Count -ne $names.Count) { throw 'Installer launch record has an incomplete option set.' }
        $command = Get-Command -Name $scriptPath -CommandType ExternalScript -ErrorAction Stop
        foreach ($name in $names) {
            if (-not $Launch.parameters.Contains($name)) { throw "Installer launch record lacks option $name." }
            $meta = $null
            try { $meta = $command.ResolveParameter($name) } catch { $meta = $null }
            if (-not $meta -or $meta.Name -cne $name) { throw "Candidate runner does not accept recorded option $name." }
            $value = $Launch.parameters[$name]
            if ($null -eq $value) { continue }
            if ($meta.SwitchParameter) {
                if ($value -isnot [bool]) { throw "Recorded option $name must be Boolean." }
                continue
            }
            $converted = [Management.Automation.LanguagePrimitives]::ConvertTo($value, $meta.ParameterType)
            foreach ($attribute in @($meta.Attributes)) {
                $valid = $true
                if ($attribute -is [Management.Automation.ValidateSetAttribute]) {
                    $comparer = if ($attribute.IgnoreCase) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
                    $valid = @($attribute.ValidValues | Where-Object { $comparer.Equals([string]$_, [string]$converted) }).Count -gt 0
                } elseif ($attribute -is [Management.Automation.ValidateRangeAttribute]) {
                    $valid = ($null -eq $attribute.MinRange -or $converted -ge $attribute.MinRange) -and
                        ($null -eq $attribute.MaxRange -or $converted -le $attribute.MaxRange)
                } elseif ($attribute -is [Management.Automation.ValidatePatternAttribute]) {
                    $valid = [regex]::IsMatch([string]$converted, $attribute.RegexPattern, $attribute.Options)
                } elseif ($attribute -is [Management.Automation.ValidateNotNullOrEmptyAttribute]) {
                    $valid = -not [string]::IsNullOrEmpty([string]$converted)
                }
                if (-not $valid) { throw "Recorded option $name is invalid for the candidate runner." }
            }
        }
        if (-not [IO.Path]::IsPathRooted([string]$Launch.parameters.ConfigPath)) { throw 'Recorded ConfigPath is not absolute.' }
        foreach ($name in $Launch.environment.Keys) {
            if ([string]$name -cnotmatch '^YURUNA_[A-Z0-9_]+$' -or $Launch.environment[$name] -isnot [string]) {
                throw 'Installer launch record has an invalid environment entry.'
            }
        }
    }
    $readLaunch = {
        param([string]$Path)
        # The public protocol is a bounded ASCII header plus UTF-8 JSON.
        # Refuse damaged evidence instead of inferring launch defaults.
        $raw = & $readBytes $Path 1048576
        $lineEnd = [Array]::IndexOf($raw, [byte]10)
        if ($lineEnd -lt 1 -or $lineEnd -gt 4096) { throw 'Installer launch record has a malformed header.' }
        $header = [Text.Encoding]::ASCII.GetString($raw, 0, $lineEnd) | ConvertFrom-Json -AsHashtable @jsonOption
        if ($header.format -cne 'yuruna.critical-record' -or $header.version -ne 1 -or $header.kind -cne 'runner-launch' -or $header.generation -lt 1) {
            throw 'Installer launch record has an unsupported header.'
        }
        $payload = [byte[]]::new($raw.Length - $lineEnd - 1)
        [Array]::Copy($raw, $lineEnd + 1, $payload, 0, $payload.Length)
        if ($header.payloadBytes -ne $payload.Length -or $header.payloadSha256 -cne (& $hashBytes $payload)) {
            throw 'Installer launch record checksum failed.'
        }
        return [Text.UTF8Encoding]::new($false, $true).GetString($payload) | ConvertFrom-Json -AsHashtable -Depth 64 @jsonOption
    }
    if ($Action -eq 'Capture') {
        if ([IO.File]::Exists($snapshot)) { throw "Installer snapshot already exists: $snapshot" }
        $launch = $null
        if (-not $PrivateRoot) { $PrivateRoot = Join-Path $HOME '.yuruna/host-refresh' }
        if (([IO.DirectoryInfo]::new($PrivateRoot)).LinkTarget) { throw 'Installer launch state root is linked.' }
        if (-not $runtimeExplicit -and [IO.Directory]::Exists($PrivateRoot)) {
            $recordMatches = @()
            $records = @([IO.Directory]::EnumerateFiles($PrivateRoot, 'runner-launch.*.record'))
            if ($records.Count -gt 128) { throw 'Too many runner launch records; select YURUNA_RUNTIME_DIR explicitly.' }
            foreach ($candidatePath in $records) {
                $candidate = & $readLaunch $candidatePath
                if (-not [string]::Equals([string]$candidate.repoRoot, $repo, $comparison)) { continue }
                $alive = $false
                try {
                    $process = [Diagnostics.Process]::GetProcessById([int]$candidate.runner.pid)
                    $started = [DateTimeOffset]::new($process.StartTime.ToUniversalTime()).ToUnixTimeMilliseconds()
                    $alive = $started -eq [long]$candidate.runner.startTimeUnixMs
                    $process.Dispose()
                } catch { $alive = $false }
                $recordMatches += @{ record = $candidate; alive = $alive }
            }
            $live = @($recordMatches | Where-Object { $_.alive })
            if ($live.Count -eq 1) { $recordMatches = $live }
            if ($recordMatches.Count -gt 1) { throw 'Multiple recorded runtimes use this checkout; select YURUNA_RUNTIME_DIR explicitly before upgrade.' }
            if ($recordMatches.Count -eq 1) { $runtime = [IO.Path]::GetFullPath([string]$recordMatches[0].record.runtimeDir).TrimEnd('/', '\') }
            if ($snapshot.StartsWith($runtime + [IO.Path]::DirectorySeparatorChar, $comparison)) {
                throw 'Installer recovery state must be outside the recorded runtime directory.'
            }
        }
        $keyPath = if ($IsLinux) { $runtime } else { $runtime.ToLowerInvariant() }
        $key = (& $hashBytes ([Text.Encoding]::UTF8.GetBytes($keyPath))).Substring(0, 16)
        $recordPath = Join-Path $PrivateRoot "runner-launch.$key.record"
        if ([IO.File]::Exists($recordPath)) {
            $launch = & $readLaunch $recordPath
            & $validateLaunch $launch
            if (-not [string]::Equals([IO.Path]::GetFullPath([string]$launch.runtimeDir).TrimEnd('/', '\'), $runtime, $comparison)) {
                throw 'Installer launch record belongs to another runtime directory.'
            }
        } elseif ([IO.File]::Exists("$recordPath.prev") -or [IO.File]::Exists((Join-Path $runtime 'runner.pid'))) {
            throw 'Runner launch evidence is missing; choose the configuration and launch options before stopping or upgrading this runner.'
        }
        $configPath = if ($launch) { [string]$launch.parameters.ConfigPath } else { Join-Path $repo 'test/test.config.yml' }
        $configs = @()
        foreach ($path in @($configPath, (Join-Path $repo 'test/test.config.yml')) | Select-Object -Unique) {
            if (-not [IO.File]::Exists($path)) {
                if ($launch -and $path -eq $configPath) { throw "Recorded configuration is missing: $path" }
                continue
            }
            $bytes = & $readBytes $path 4194304
            $config = @{ path = $path; bytes = [Convert]::ToBase64String($bytes); sha256 = (& $hashBytes $bytes) }
            if ($IsWindows) { $config.sddl = (Get-Acl -LiteralPath $path).Sddl }
            else { $config.unixMode = [int][IO.File]::GetUnixFileMode($path) }
            $configs += $config
        }
        if (-not $launch -and $configs.Count -eq 0) { return $null }
        $state = @{ schema = 'yuruna.installer-state/v1'; repoRoot = $repo; configPath = $configPath; privateRoot = $PrivateRoot
            launchRecord = $launch; configurations = $configs; capturedUtc = [DateTime]::UtcNow.ToString('o') }
        $parent = Split-Path $snapshot -Parent
        $directory = [IO.DirectoryInfo]::new($parent)
        if ($directory.LinkTarget) { throw 'Installer snapshot directory is linked.' }
        if ($directory.Exists -and @($directory.EnumerateFileSystemInfos()).Count -ne 0) {
            throw 'Installer snapshot requires a dedicated empty directory.'
        }
        if ($IsWindows) {
            $null = [IO.Directory]::CreateDirectory($parent)
            $acl = [Security.AccessControl.DirectorySecurity]::new()
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
            $acl.SetOwner($identity)
            $acl.SetAccessRuleProtection($true, $false)
            $rule = [Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')
            $acl.AddAccessRule($rule)
            Set-Acl -LiteralPath $parent -AclObject $acl
        } else {
            $null = [IO.Directory]::CreateDirectory($parent, [IO.UnixFileMode]448)
            [IO.File]::SetUnixFileMode($parent, [IO.UnixFileMode]448)
        }
        [IO.File]::WriteAllText($snapshot, ($state | ConvertTo-Json -Depth 64), [Text.UTF8Encoding]::new($false))
        if (-not $IsWindows) { [IO.File]::SetUnixFileMode($snapshot, [IO.UnixFileMode]384) }
        return $state
    }
    $snapshotDirectory = [IO.DirectoryInfo]::new((Split-Path $snapshot -Parent))
    if ($snapshotDirectory.LinkTarget) { throw 'Installer snapshot directory is linked.' }
    if (-not $IsWindows -and (([int][IO.File]::GetUnixFileMode($snapshotDirectory.FullName) -band 63) -ne 0 -or
            ([int][IO.File]::GetUnixFileMode($snapshot) -band 63) -ne 0)) {
        throw 'Installer snapshot permissions must restrict access to its owner.'
    }
    $savedBytes = & $readBytes $snapshot 16777216
    $state = [Text.UTF8Encoding]::new($false, $true).GetString($savedBytes) | ConvertFrom-Json -AsHashtable -Depth 64 @jsonOption
    if ($state.schema -cne 'yuruna.installer-state/v1' -or -not [string]::Equals([string]$state.repoRoot, $repo, $comparison)) {
        throw "Installer snapshot does not identify this checkout: $snapshot"
    }
    & $validateLaunch $state.launchRecord
    if (@($state.configurations).Count -eq 0) { throw 'Installer snapshot has no saved configuration.' }
    # Validate every file before the first write, so an incompatible runner or
    # changed external configuration cannot leave a partially restored setup.
    foreach ($config in @($state.configurations)) {
        $fullConfig = [IO.Path]::GetFullPath([string]$config.path)
        if (-not [string]::Equals($fullConfig, [string]$state.configPath, $comparison) -and
            -not [string]::Equals($fullConfig, (Join-Path $repo 'test/test.config.yml'), $comparison)) {
            throw 'Installer snapshot contains an unrelated configuration path.'
        }
        $bytes = [Convert]::FromBase64String([string]$config.bytes)
        if ((& $hashBytes $bytes) -cne [string]$config.sha256) { throw "Installer configuration snapshot hash failed: $snapshot" }
        if ($Action -eq 'Restore' -and [IO.File]::Exists([string]$config.path)) {
            $present = & $readBytes ([string]$config.path) 4194304
            if ((& $hashBytes $present) -cne [string]$config.sha256) { throw "Configuration changed after capture; recovery snapshot retained at $snapshot" }
        } elseif ($Action -eq 'Restore' -and -not [IO.File]::Exists([string]$config.path) -and -not ([string]$config.path).StartsWith($repo + [IO.Path]::DirectorySeparatorChar, $comparison)) {
            throw "External configuration is missing; recovery snapshot retained at $snapshot"
        }
    }
    if ($Action -eq 'Restore') {
        foreach ($config in @($state.configurations)) {
            if (-not [IO.File]::Exists([string]$config.path)) {
                $options = [IO.FileStreamOptions]::new()
                $options.Mode = [IO.FileMode]::CreateNew
                $options.Access = [IO.FileAccess]::Write
                $options.Share = [IO.FileShare]::None
                if (-not $IsWindows) { $options.UnixCreateMode = [IO.UnixFileMode][int]$config.unixMode }
                $stream = [IO.FileStream]::new([string]$config.path, $options)
                $stream.Dispose()
                if ($IsWindows) {
                    $acl = [Security.AccessControl.FileSecurity]::new()
                    $acl.SetSecurityDescriptorSddlForm([string]$config.sddl)
                    Set-Acl -LiteralPath ([string]$config.path) -AclObject $acl
                }
                [IO.File]::WriteAllBytes([string]$config.path, [Convert]::FromBase64String([string]$config.bytes))
            }
        }
    }
    return $state
}

try {
    Invoke-YurunaInstallerState -Action $env:YURUNA_INSTALLER_ACTION -RepoRoot $env:YURUNA_INSTALLER_ROOT -SnapshotPath $env:YURUNA_INSTALLER_SNAPSHOT | Out-Null
} catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
}
YURUNA_INSTALLER_STATE_PS
}

capture_installer_state() {
  [[ -d "$YURUNA_DIR" ]] || return 0
  local state_root="$HOME/.yuruna/installer-state"
  [[ ! -L "$HOME/.yuruna" && ! -L "$state_root" ]] || die "Installer recovery storage must not be a symbolic link."
  ( umask 077; mkdir -p "$state_root" ) || die "Cannot create private installer recovery storage."
  chmod 700 "$state_root" || die "Cannot protect installer recovery storage."
  YURUNA_INSTALLER_STATE_DIR="$(mktemp -d "$state_root/capture.XXXXXXXX")"
  yuruna_track_tmp "$YURUNA_INSTALLER_STATE_DIR"
  if command -v pwsh >/dev/null 2>&1; then
    invoke_yuruna_installer_state Capture || die "Cannot capture existing runner/configuration; installer stopped before stopping processes. Recovery directory: $YURUNA_INSTALLER_STATE_DIR"
  else
    # A configured checkout without PowerShell can still preserve its default
    # config, but an existing launch record must never be replaced by guesses.
    if [[ -f "${YURUNA_RUNTIME_DIR:-$YURUNA_DIR/test/status/runtime}/runner.pid" ]] || \
       compgen -G "$HOME/.yuruna/host-refresh/runner-launch.*.record*" >/dev/null; then
      die "PowerShell is required to validate the existing runner launch record before upgrade."
    fi
    if [[ -f "$YURUNA_DIR/test/test.config.yml" ]]; then
      [[ ! -L "$YURUNA_DIR/test/test.config.yml" ]] || die "Cannot snapshot a linked configuration."
      cp "$YURUNA_DIR/test/test.config.yml" "$YURUNA_INSTALLER_STATE_DIR/config.yml" || die "Cannot preserve existing configuration."
      chmod 600 "$YURUNA_INSTALLER_STATE_DIR/config.yml"
      YURUNA_INSTALLER_CONFIG_ONLY=1
    fi
  fi
  if [[ -f "$YURUNA_INSTALLER_STATE_DIR/state.json" || -f "$YURUNA_INSTALLER_STATE_DIR/config.yml" ]]; then
    YURUNA_INSTALLER_STATE_RETAINED=1
    log "Private installer recovery state: $YURUNA_INSTALLER_STATE_DIR (retain for restart/rollback; remove when no longer needed)"
  fi
}

restore_installer_state() {
  [[ -n "$YURUNA_INSTALLER_STATE_DIR" ]] || return 0
  if [[ "$YURUNA_INSTALLER_CONFIG_ONLY" -eq 1 ]]; then
    if [[ -e "$YURUNA_DIR/test/test.config.yml" || -L "$YURUNA_DIR/test/test.config.yml" ]]; then
      if [[ -L "$YURUNA_DIR/test/test.config.yml" ]] || ! cmp -s "$YURUNA_INSTALLER_STATE_DIR/config.yml" "$YURUNA_DIR/test/test.config.yml"; then
        die "Configuration changed during upgrade; preserved copy: $YURUNA_INSTALLER_STATE_DIR/config.yml"
      fi
    else
      cp "$YURUNA_INSTALLER_STATE_DIR/config.yml" "$YURUNA_DIR/test/test.config.yml" || die "Cannot restore configuration; preserved copy: $YURUNA_INSTALLER_STATE_DIR/config.yml"
    fi
  elif [[ -f "$YURUNA_INSTALLER_STATE_DIR/state.json" ]]; then
    invoke_yuruna_installer_state Restore || die "Cannot verify restored configuration and launch options; setup stopped. Recovery snapshot: $YURUNA_INSTALLER_STATE_DIR/state.json"
    log "Recorded runner options retained. To explicitly start this runner after setup, run: pwsh '$YURUNA_DIR/test/lab/Start-RecordedTestRunner.ps1' -SnapshotPath '$YURUNA_INSTALLER_STATE_DIR/state.json'"
  fi
}

# --- REGION: https://yuruna.link/429fb30b-000a
# A recycled PID can pass the comm check below, so a PID-file entry must also run
# a Yuruna script or have started within two seconds of its .start record (ps -o
# lstart= has one-second precision).
# See https://yuruna.link/429fb30b-000b
yuruna_epoch_from_utc() {
  local stamp="${1%Z}"
  stamp="${stamp%%.*}"
  [[ "$stamp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] || return 1
  if date --version >/dev/null 2>&1; then
    date -u -d "$stamp" +%s 2>/dev/null
  else
    date -j -u -f '%Y-%m-%dT%H:%M:%S' "$stamp" +%s 2>/dev/null
  fi
}

yuruna_process_start_epoch() {
  local started
  started="$(LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null || true)"
  [[ -n "$started" ]] || return 1
  if date --version >/dev/null 2>&1; then
    LC_ALL=C date -d "$started" +%s 2>/dev/null
  else
    LC_ALL=C date -j -f '%a %b %d %T %Y' "$started" +%s 2>/dev/null
  fi
}

# pid_file_owner_ok <pid> <start-record> <script pattern>...
pid_file_owner_ok() {
  local pid="$1" start_file="$2" args pat recorded live delta
  shift 2
  args="$(ps -ww -p "$pid" -o args= 2>/dev/null || true)"
  if [[ -n "$args" ]]; then
    for pat in "$@"; do
      case "$args" in *"$pat"*) return 0 ;; esac
    done
  fi
  [[ -f "$start_file" ]] || return 1
  recorded="$(yuruna_epoch_from_utc "$(tr -d ' \r\n' < "$start_file" 2>/dev/null || true)")" || return 1
  live="$(yuruna_process_start_epoch "$pid")" || return 1
  [[ -n "$recorded" && -n "$live" ]] || return 1
  delta=$((live - recorded))
  [[ ${delta#-} -le 2 ]]
}

# Stop the runner/inner/status-service and WAIT before the checkout rename.
stop_yuruna_processes() {
  local runtime_dir="${YURUNA_RUNTIME_DIR:-$YURUNA_DIR/test/status/runtime}"
  local -a target_pids=()
  local pid

  # The scripts a Yuruna runner or service runs; (1) and (2) both read them.
  local -a patterns=(
    "Start-TestRunner.ps1"
    "Invoke-TestRunnerInnerLoop.ps1"
    "Debug-TestSequence.ps1"
    "Start-StatusService.ps1"
    ".status-service.ps1"
  )

  # (1) PID files -- readable even when a process's command line is not. A
  # PID read from one counts only while its process is still the owner.
  local pidname pidfile raw
  for pidname in runner.pid inner.pid server.pid; do
    pidfile="$runtime_dir/$pidname"
    if [[ -f "$pidfile" ]]; then
      raw=$(tr -dc '0-9' < "$pidfile" 2>/dev/null || true)
      if [[ -n "$raw" ]] && pid_file_owner_ok "$raw" "$runtime_dir/${pidname%.pid}.start" "${patterns[@]}"; then
        target_pids+=("$raw")
      fi
    fi
  done

  # (2) Command-line pattern match.
  local pat p
  for pat in "${patterns[@]}"; do
    while IFS= read -r p; do
      if [[ -n "$p" ]]; then target_pids+=("$p"); fi
    done < <(pgrep -f "$pat" 2>/dev/null || true)
  done

  # (3) Status-port listener(s): configured port + the 8080 default.
  local -a ports=("8080")
  local cfg="$YURUNA_DIR/test/test.config.yml"
  if [[ -f "$cfg" ]]; then
    local cport
    cport=$(awk '
      /^statusService:[[:space:]]*$/ { inblk=1; next }
      inblk && /^[^[:space:]]/        { exit }
      inblk && /^[[:space:]]+port:[[:space:]]*[0-9]+/ { gsub(/[^0-9]/,""); print; exit }
    ' "$cfg" 2>/dev/null || true)
    if [[ -n "$cport" && "$cport" != "8080" ]]; then ports+=("$cport"); fi
  fi
  local port plist pp
  for port in "${ports[@]}"; do
    plist=""
    if command -v lsof >/dev/null 2>&1; then
      plist=$(lsof -ti "tcp:$port" 2>/dev/null || true)
    elif command -v ss >/dev/null 2>&1; then
      plist=$(ss -ltnpH "sport = :$port" 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 || true)
    fi
    if [[ -n "$plist" ]]; then
      while IFS= read -r pp; do
        if [[ -n "$pp" ]]; then target_pids+=("$pp"); fi
      done <<< "$plist"
    fi
  done

  # --- REGION: https://yuruna.link/429fb30b-000b
  # Keep only pids whose executable (comm) is pwsh; never kill a recycled or self-matched pid.
  local -a uniq_pids=()
  local seen=" " pcomm
  for pid in "${target_pids[@]:-}"; do
    if [[ -z "$pid" || "$pid" == "$$" ]]; then continue; fi
    case "$seen" in *" $pid "*) continue ;; esac
    seen="$seen$pid "
    kill -0 "$pid" 2>/dev/null || continue   # dead or not ours -- nothing to stop
    # Match the executable name (comm), NOT argv -- the script text contaminates
    # argv with the .ps1 pattern names on the bash <(...) / -c launch. -ww so
    # BSD/macOS ps does not truncate the path.
    # Empty comm on a LIVE pid means ps could not report it: keep the pid rather
    # than silently disabling the stop (degrade to the pre-validation behavior).
    pcomm="$(ps -ww -p "$pid" -o comm= 2>/dev/null || ps -p "$pid" -o comm= 2>/dev/null || true)"
    case "$pcomm" in
      ''|*pwsh*|*powershell*|*PowerShell*) uniq_pids+=("$pid") ;;
      *) ;;   # alive and provably NOT a PowerShell process -- stale/recycled, skip
    esac
  done

  if [[ ${#uniq_pids[@]} -eq 0 ]]; then
    log "  no running Yuruna runner / status service found"
    return 0
  fi

  log "  stopping Yuruna services and waiting for exit (pids: ${uniq_pids[*]})"
  kill "${uniq_pids[@]}" 2>/dev/null || true

  # Wait up to 15s for a clean exit, then SIGKILL any straggler.
  local waited alive
  waited=0
  while [[ $waited -lt 15 ]]; do
    alive=0
    for pid in "${uniq_pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then alive=1; break; fi
    done
    if [[ $alive -eq 0 ]]; then break; fi
    sleep 1
    waited=$((waited + 1))
  done
  for pid in "${uniq_pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null || true; fi
  done

  # Final settle so the caller's checkout rename does not race a dying tree.
  waited=0
  while [[ $waited -lt 5 ]]; do
    alive=0
    for pid in "${uniq_pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then alive=1; break; fi
    done
    if [[ $alive -eq 0 ]]; then return 0; fi
    sleep 1
    waited=$((waited + 1))
  done
  warn "  some Yuruna service PIDs did not exit; re-run the installer if the repo update reports the checkout is busy."
}

# --- REGION: Preserve running service VMs
# See https://yuruna.link/429fb30b-000c
# VMs (the yuruna-caching-proxy-service cache, a libvirt domain) are never touched
# here: this installer issues no domain stop/destroy.
log "Stopping anything that would block a repo update (runner + status service; VMs preserved)"
capture_installer_state
stop_yuruna_processes

# --- REGION: Microsoft's Ubuntu 24.04 suite for PowerShell
# Restrict the fallback suite to PowerShell and remove only this installer's
# files when a native source becomes usable; operator sources stay intact.
# See https://yuruna.link/429fb30b-0034
PWSH_NOBLE_URL="https://packages.microsoft.com/ubuntu/24.04/prod"
PWSH_NOBLE_ORIGIN="microsoft-ubuntu-noble-prod noble"
PWSH_NOBLE_LIST="/etc/apt/sources.list.d/yuruna-powershell-noble.sources"
PWSH_NOBLE_PREF="/etc/apt/preferences.d/yuruna-powershell-noble.pref"
PWSH_NOBLE_KEYRING="/etc/apt/keyrings/yuruna-powershell-noble.gpg"

# Whether a configured apt source offers powershell; with an argument, a source other
# than that URI. apt-cache madison lists what sources carry, never the dpkg status
# entry that apt otherwise reports as the candidate of an installed package.
apt_offers_powershell() {
  LC_ALL=C apt-cache madison powershell 2>/dev/null \
    | awk -F'|' -v skip="${1:-}" '
        { gsub(/^[ \t]+|[ \t]+$/, "", $3) }
        $3 != "" && (skip == "" || index($3, skip " ") != 1) { found = 1 }
        END { exit !found }'
}

remove_pwsh_noble_source() {
  sudo rm -f -- "$PWSH_NOBLE_LIST" "$PWSH_NOBLE_PREF" "$PWSH_NOBLE_KEYRING"
}

# The pin lands before the source, so apt never reads that suite unpinned, and a
# suite apt cannot verify or that offers no powershell is removed before this returns.
add_pwsh_noble_source() {
  local tmp
  log "No apt source offers powershell -- adding Microsoft's Ubuntu 24.04 suite for that package alone ($PWSH_NOBLE_LIST)"
  tmp="$(mktemp -d)" || return 1
  yuruna_track_tmp "$tmp"
  curl -fsSL --connect-timeout 10 --max-time 60 "https://packages.microsoft.com/keys/microsoft.asc" -o "$tmp/microsoft.asc" \
    || return 1
  verify_key_fingerprints "$tmp/microsoft.asc" "$MS_APT_KEY_FPR_NOBLE"
  if sudo install -d -m 0755 /etc/apt/keyrings \
     && sudo gpg --dearmor --yes -o "$PWSH_NOBLE_KEYRING" "$tmp/microsoft.asc" \
     && sudo chmod 0644 "$PWSH_NOBLE_KEYRING" \
     && printf '%s\n' 'Package: *' "Pin: release o=$PWSH_NOBLE_ORIGIN" 'Pin-Priority: -1' '' \
          'Package: powershell' "Pin: release o=$PWSH_NOBLE_ORIGIN" 'Pin-Priority: 500' \
          | sudo tee "$PWSH_NOBLE_PREF" >/dev/null \
     && printf '%s\n' 'Types: deb' "URIs: $PWSH_NOBLE_URL" 'Suites: noble' 'Components: main' \
          'Architectures: amd64' "Signed-By: $PWSH_NOBLE_KEYRING" \
          | sudo tee "$PWSH_NOBLE_LIST" >/dev/null \
     && sudo apt-get update -qq && apt_offers_powershell; then
    rm -rf -- "$tmp"
    return 0
  fi
  warn "  Microsoft's Ubuntu 24.04 suite could not be used -- removing the files this attempt wrote"
  remove_pwsh_noble_source || true
  sudo apt-get update -qq || true
  return 1
}

# Once another source offers powershell, the 24.04 suite this installer added goes.
retire_pwsh_noble_source() {
  [[ -e "$PWSH_NOBLE_LIST" ]] || return 0
  apt_offers_powershell "$PWSH_NOBLE_URL" || return 0
  log "Another apt source offers powershell -- removing Microsoft's Ubuntu 24.04 suite this installer added for it"
  remove_pwsh_noble_source || { warn "  could not remove $PWSH_NOBLE_LIST, $PWSH_NOBLE_PREF and $PWSH_NOBLE_KEYRING"; return 0; }
  sudo apt-get update -q || warn "  'apt-get update' failed after that removal; apt reads the change on its next run"
}

# Runs when the index refresh failed. The 24.04 suite this installer added must never
# be what stops a run -- Microsoft can change the key that signs it -- so with that
# suite configured it is removed and the refresh runs once more. Without it, apt's
# failure ends the install as it always has.
retry_apt_update_without_pwsh_noble_source() {
  local rc=$?
  [[ -e "$PWSH_NOBLE_LIST" ]] || return "$rc"
  warn "'apt-get update' failed with Microsoft's Ubuntu 24.04 suite configured -- removing that suite, which this installer added for powershell alone, and refreshing again"
  remove_pwsh_noble_source || return "$rc"
  sudo apt-get update -q
}

# --- REGION: Install platform packages
log "Refreshing apt index"
sudo apt-get update -q || retry_apt_update_without_pwsh_noble_source
retire_pwsh_noble_source

case "$ARCH" in
  x86_64)   qemu_default="qemu-system-x86"   ;;
  aarch64)  qemu_default="qemu-system-arm"   ;;
esac
qemu_kvm_pkg="${YURUNA_QEMU_PKG:-$qemu_default}"
log "  qemu pkg : $qemu_kvm_pkg (override with YURUNA_QEMU_PKG=... if needed)"

APT_PACKAGES=(
  "$qemu_kvm_pkg"
  qemu-utils
  libvirt-daemon-system
  libvirt-clients
  virtinst
  osinfo-db
  osinfo-db-tools
  bridge-utils
  dnsmasq-base
  acl
  cifs-utils       # mount.cifs helper for the optional networkStorage pool (ypool-nas) SMB share
  cpu-checker
  swtpm swtpm-tools
  genisoimage
  whois
  cloud-image-utils
  sshpass
  git
  wget curl ca-certificates
  tesseract-ocr
  imagemagick
  virt-viewer
  xwayland
  python3 python3-pip
  jq
  unzip
)
case "$ARCH" in
  x86_64)   APT_PACKAGES+=(ovmf) ;;
  aarch64)  APT_PACKAGES+=(qemu-efi-aarch64) ;;
esac

# Whether Microsoft's powershell package is installed. That package and a tarball
# this installer unpacked share /opt/microsoft/powershell/7, so dpkg, not the path,
# says which source owns the copy. A package held with apt-mark reads "hold ok
# installed"; whether it is held is apt_package_held's answer.
powershell_deb_installed() {
  case "$(dpkg-query -W -f='${Status}' powershell 2>/dev/null || true)" in
    "install ok installed"|"hold ok installed") return 0 ;;
  esac
  return 1
}
# grep reads all of its input: with pipefail, a grep -q that stops at the first match
# can fail the producer with SIGPIPE, and a held package would read as not held.
apt_package_held() {
  apt-mark showhold 2>/dev/null | grep -x -- "$1" >/dev/null
}
# Leave held or uninstallable PowerShell packages out of this transaction.
# The later source repair and closing report handle them independently.
# See https://yuruna.link/4213a0b3-01b1
PWSH_APT_UNINSTALLABLE=0
if powershell_deb_installed && ! apt_package_held powershell; then
  if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --simulate powershell >/dev/null 2>&1; then
    APT_PACKAGES+=(powershell)
  else
    PWSH_APT_UNINSTALLABLE=1
    warn "apt cannot install the powershell its sources offer here ('apt-cache policy powershell' names it), so this run leaves it out of the package list."
  fi
fi

log "Resolving apt dependencies (dry-run)"
if ! apt_sim_out="$(sudo DEBIAN_FRONTEND=noninteractive \
        apt-get install -y --no-install-recommends --simulate \
        "${APT_PACKAGES[@]}" 2>&1)"; then
    printf '%s\n' "$apt_sim_out" >&2
    warn ""
    warn "apt's solver rejected the package set above. Common causes:"
    warn "  * YURUNA_QEMU_PKG points at an -hwe variant that conflicts"
    warn "    with the rest of the virt stack (ubuntu-virt vs ubuntu-virt-hwe)"
    warn "  * universe / multiverse pocket disabled in /etc/apt/sources.list*"
    warn "  * a third-party PPA is pinning an older libvirt -- check"
    warn "    'apt-cache policy libvirt-daemon-system' for the Candidate."
    die "Dependency resolution failed; see solver output above."
fi

log "Installing / upgrading required apt packages"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${APT_PACKAGES[@]}"

# --- REGION: virt-manager
# The operator's libvirt GUI, in its own apt call WITH Recommends: its console widgets
# live in typelibs it only Recommends, so without them it lists domains but cannot open
# any. Non-fatal: the harness drives consoles through virt-viewer.
# See https://yuruna.link/4213a0b3-01b6
log "Installing virt-manager (with recommends, so its console works)"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y virt-manager \
  || note_issue "Installing virt-manager failed; guest consoles remain available through virt-viewer."

# --- REGION: Remove a shadowing python3
# See https://yuruna.link/429fb30b-0035
# A standalone python3 ahead of /usr/bin/python3 breaks virt-install. Remove only the
# python3 symlink into /opt/cpython and its owned version tree.
# Preserve unrelated interpreters and environments; libvirt needs system Python.
remove_standalone_python() {
  local bin_dir="${1:-/usr/local/bin}" opt_dir="${2:-/opt/cpython}" target ver link
  [[ -L "$bin_dir/python3" ]] || return 0
  target="$(readlink "$bin_dir/python3")"
  [[ "$target" == "$opt_dir"/* ]] || return 0
  ver="${target#"$opt_dir"/}"; ver="${ver%%/*}"
  if ! sudo rm -f "$bin_dir/python3"; then
    note_issue "Could not remove $bin_dir/python3, which points at $target; virt-install cannot run while it shadows /usr/bin/python3. Remove it with: sudo rm $bin_dir/python3"
    return 0
  fi
  log "  removed $bin_dir/python3 (it pointed at $target)"
  for link in "$bin_dir"/python3.[0-9]*; do
    [[ -L "$link" && "$(readlink "$link")" == "$opt_dir/$ver/"* ]] || continue
    sudo rm -f "$link" && log "  removed $link"
  done
  [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && -d "$opt_dir/$ver" && ! -L "$opt_dir/$ver" ]] || return 0
  if sudo rm -rf "$opt_dir/$ver"; then
    log "  removed $opt_dir/$ver"
    sudo rmdir "$opt_dir" 2>/dev/null || true
  else
    warn "  could not remove $opt_dir/$ver; the links into it are gone, so it can be deleted by hand."
  fi
}
if is_amd_ryzen_ai_platform; then
  remove_standalone_python
  hash -r
fi

# --- REGION: osinfo-db refresh
# See https://yuruna.link/429fb30b-0033
osinfo_has_variant() {
  local v="$1"
  local re="${v//./\\.}"
  virt-install --osinfo list 2>/dev/null \
    | grep -E "(^|[[:space:],])${re}([[:space:],]|$)" >/dev/null
}
# Succeeds when virt-install starts. It runs through `python3` from PATH
# (`#!/usr/bin/env python3`), so a python3 ahead of /usr/bin/python3 that lacks
# the system's gi and libvirt modules stops it, and every VM build with it. On
# failure, prints the last line it reported.
virt_install_runs() {
  local out
  if out="$(virt-install --version 2>&1)"; then return 0; fi
  printf '%s\n' "${out##*$'\n'}"
  return 1
}
osinfo_db_diag() {
  local label="$1" listing ubu d rc=0
  log "    [$label] osinfo-db package: $(dpkg-query -W -f='${Version}' osinfo-db 2>/dev/null || echo 'not installed')"
  # Diagnostics only, so nothing here may end the run: under pipefail a
  # virt-install that fails, or a listing with no ubuntu entry, fails the
  # pipeline, and an assignment from it would take the installer down. Every
  # substitution is guarded, not only the assignments: errtrace carries the ERR
  # trap into a command substitution, where an unguarded failure prints the
  # installer's abort banner even though the run goes on.
  listing="$(virt-install --osinfo list 2>&1)" || rc=$?
  if (( rc != 0 )); then
    log "    [$label] virt-install --osinfo list exited $rc: ${listing##*$'\n'}"
  else
    log "    [$label] virt-install --osinfo list count: $(printf '%s\n' "$listing" | wc -l || true) lines"
    ubu="$(printf '%s\n' "$listing" | grep -iE '^ubuntu' | tr '\n' ' ' || true)"
    log "    [$label] ubuntu* short-ids visible: ${ubu:-<none>}"
  fi
  for d in /usr/share/osinfo /usr/local/share/osinfo "$HOME/.local/share/osinfo"; do
    log "    [$label] $d exists: $(test -d "$d" && echo yes || echo no); ubuntu-24.04*.xml: $(find "$d" -name 'ubuntu-24.04*.xml' 2>/dev/null | head -3 | tr '\n' ' ' || true)"
  done
}

ensure_osinfo_db_has_ubuntu24() {
  if ! command -v virt-install >/dev/null 2>&1; then
    warn "  virt-install missing -- skipping osinfo-db ubuntu24.04 check."
    return
  fi
  log "Checking osinfo-db for 'ubuntu24.04' variant"
  # A virt-install that cannot start lists nothing, which reads as missing data
  # and would send the refresh below after a database that is not the problem.
  local why
  if ! why="$(virt_install_runs)"; then
    warn "  virt-install does not run ($why) -- skipping the osinfo-db check; the final preflight reports it."
    return
  fi
  if osinfo_has_variant 'ubuntu24.04'; then
    log "  ubuntu24.04 already present in osinfo-db (no refresh needed)"
    return
  fi
  log "  ubuntu24.04 missing -- diagnostics before refresh:"
  osinfo_db_diag pre

  if ! command -v osinfo-db-import >/dev/null 2>&1; then
    warn "  osinfo-db-tools not on PATH after apt install -- skipping upstream refresh."
    return
  fi

  log "  attempting upstream refresh from pagure.org"
  local listing latest tmpdir tarball_url
  if ! listing=$(curl -fsSL --max-time 10 'https://releases.pagure.org/libosinfo/' 2>/dev/null); then
    warn "  could not list pagure.org libosinfo releases -- staying on apt-shipped data."
    return
  fi
  latest=$(printf '%s' "$listing" | grep -oE 'osinfo-db-[0-9]+\.tar\.xz' | sort -V | tail -1 || true)
  if [[ -z "$latest" ]]; then
    warn "  pagure.org index parsing returned no tarballs (HTML format change?) -- staying on apt-shipped data."
    return
  fi
  log "  latest upstream tarball: $latest"
  tmpdir=$(mktemp -d)
  yuruna_track_tmp "$tmpdir"
  tarball_url="https://releases.pagure.org/libosinfo/$latest"
  log "  downloading $tarball_url"
  if ! curl -fsSL --max-time 60 "$tarball_url" -o "$tmpdir/$latest"; then
    warn "  could not download $tarball_url -- staying on apt-shipped data."
    rm -rf "$tmpdir"
    return
  fi

  # Verify the tarball's detached GPG signature against the pinned libosinfo
  # release key before importing it: pagure serves over HTTPS but publishes no
  # checksum, so the .asc is the integrity control. FAIL CLOSED -- a tarball we
  # cannot verify is never imported; the apt-shipped osinfo-db stays in place.
  # Refresh on a signing-key rotation: confirm the new primary fingerprint with
  # `gpg --list-packets <tarball>.asc` and update LIBOSINFO_KEY_FPR.
  local LIBOSINFO_KEY_FPR='4252D86A52041137C291CADFC85C5E957062A701'  # Pavel Hrdina (osinfo-db releases)
  if ! command -v gpg >/dev/null 2>&1; then
    warn "  gpg unavailable -- not importing unverified upstream osinfo-db; staying on apt-shipped data."
    rm -rf "$tmpdir"; return
  fi
  if ! curl -fsSL --max-time 30 "${tarball_url}.asc" -o "$tmpdir/$latest.asc"; then
    warn "  no detached signature for $latest -- not importing unverified data; staying on apt-shipped data."
    rm -rf "$tmpdir"; return
  fi
  local gpghome="$tmpdir/gnupg"
  mkdir -p "$gpghome"; chmod 700 "$gpghome"
  if ! gpg --homedir "$gpghome" --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys "$LIBOSINFO_KEY_FPR" >/dev/null 2>&1; then
    warn "  could not fetch the libosinfo signing key -- not importing unverified data; staying on apt-shipped data."
    stop_gpg_home "$gpghome"; rm -rf "$tmpdir"; return
  fi
  local vstatus
  if ! vstatus=$(gpg --homedir "$gpghome" --batch --status-fd 1 --verify "$tmpdir/$latest.asc" "$tmpdir/$latest" 2>/dev/null); then
    warn "  GPG verification failed -- retaining apt-shipped osinfo-db."
    stop_gpg_home "$gpghome"; rm -rf "$tmpdir"; return
  fi
  if printf '%s\n' "$vstatus" | grep -qE '^\[GNUPG:\] BADSIG ' \
     || ! printf '%s\n' "$vstatus" | grep -qE "^\[GNUPG:\] VALIDSIG .*${LIBOSINFO_KEY_FPR}"; then
    warn "  GPG verification FAILED for $latest -- not importing; staying on apt-shipped data."
    stop_gpg_home "$gpghome"; rm -rf "$tmpdir"; return
  fi
  log "  GPG signature verified (libosinfo release key $LIBOSINFO_KEY_FPR)"
  stop_gpg_home "$gpghome"

  log "  importing into /usr/local/share/osinfo (system-local, needs sudo)"
  local imported=0
  if sudo osinfo-db-import --local "$tmpdir/$latest"; then
    log "  imported $latest into /usr/local/share/osinfo"
    imported=1
  else
    warn "  osinfo-db-import --local failed -- trying --user fallback"
    if osinfo-db-import --user "$tmpdir/$latest"; then
      log "  imported $latest into ~/.local/share/osinfo"
      imported=1
    else
      warn "  osinfo-db-import --user also failed -- giving up."
    fi
  fi
  rm -rf "$tmpdir"
  if [[ $imported -eq 0 ]]; then return; fi

  if osinfo_has_variant 'ubuntu24.04'; then
    log "  ubuntu24.04 is now present in osinfo-db"
  else
    warn "  ubuntu24.04 STILL missing after import -- diagnostics after refresh:"
    osinfo_db_diag post
    warn "  The per-guest scripts' linux2022 fallback still works -- this"
    warn "  affects hypervisor tuning only, not bring-up."
  fi
}
ensure_osinfo_db_has_ubuntu24

# --- REGION: PowerShell
# On x86_64, Microsoft's apt repo for this release, then the release's .deb, then
# Microsoft's 24.04 suite, and the release tarball only where no package owns its
# tree; on aarch64, the release tarball, or the release's .deb for a host that already
# has Microsoft's package.
# See https://yuruna.link/429fb30b-0034
install_pwsh_apt() {
  local codename repo_url created_list=0
  codename="$(lsb_release -cs 2>/dev/null || echo noble)"
  repo_url="https://packages.microsoft.com/ubuntu/$(. /etc/os-release; echo "$VERSION_ID")/prod"
  # Refuse unsupported releases before changing apt's persistent sources.
  curl -fsI --connect-timeout 10 --max-time 30 "$repo_url/dists/$codename/Release" >/dev/null || return 1
  if [[ ! -f /etc/apt/keyrings/microsoft.gpg ]]; then
    sudo install -d -m 0755 /etc/apt/keyrings || return 1
    local ms_tmp; ms_tmp="$(mktemp -d)" || return 1
    yuruna_track_tmp "$ms_tmp"
    if ! curl -fsSL "https://packages.microsoft.com/keys/microsoft-2025.asc" -o "$ms_tmp/microsoft.asc"; then
      rm -rf "$ms_tmp"
      return 1
    fi
    verify_key_fingerprints "$ms_tmp/microsoft.asc" "$MS_APT_KEY_FPR"
    if ! sudo gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg "$ms_tmp/microsoft.asc"; then
      rm -rf "$ms_tmp"
      return 1
    fi
    rm -rf "$ms_tmp"
    sudo chmod 0644 /etc/apt/keyrings/microsoft.gpg || return 1
  fi
  if [[ ! -f /etc/apt/sources.list.d/microsoft-prod.list ]]; then
    log "Adding Microsoft apt repo (codename=$codename)"
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] $repo_url $codename main" \
      | sudo tee /etc/apt/sources.list.d/microsoft-prod.list >/dev/null || return 1
    created_list=1
  else
    log "Microsoft apt repo already listed in /etc/apt/sources.list.d/microsoft-prod.list (codename=$codename)"
  fi
  if sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y powershell; then
    return 0
  fi
  # Remove only the list created by this attempt; leave prior configuration alone.
  if [[ $created_list -eq 1 ]]; then
    sudo rm -f /etc/apt/sources.list.d/microsoft-prod.list || return 1
  fi
  return 1
}

# The newest stable PowerShell release, from the /releases/latest redirect, not the
# rate-limited API. Prints nothing and fails when GitHub does not answer with a tag;
# the time caps keep an offline host's closing report from waiting on it for minutes.
pwsh_latest_release() {
  local tag
  tag="$(curl -fsSLI --retry 3 --retry-delay 5 --retry-connrefused \
    --connect-timeout 15 --max-time 60 -o /dev/null -w '%{url_effective}' \
    "https://github.com/PowerShell/PowerShell/releases/latest")" || return 1
  tag="${tag##*/}"
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  printf '%s\n' "${tag#v}"
}

PWSH_RELEASE_ASSET=""
# --- REGION: fetch_pwsh_release_asset
# Verify assets in root-owned staging; root must never follow a caller-writable
# download. Leave the verified path in PWSH_RELEASE_ASSET.
# See https://yuruna.link/4213a0b3-01b7
fetch_pwsh_release_asset() {
  local ver="$1" asset="$2" url="https://github.com/PowerShell/PowerShell/releases/download/v$1" verified line expected actual
  local -a get=(curl -fsSL --retry 3 --retry-delay 5 --retry-connrefused --connect-timeout 15 --max-time 900 --retry-max-time 900)
  verified="$(sudo mktemp -d /tmp/yuruna-pwsh.XXXXXXXXXX)" || die "PowerShell $ver: could not create a directory only root can write"
  yuruna_track_tmp "$verified"
  sudo chmod 0755 "$verified" || die "PowerShell $ver: could not let the checks below read $verified"
  "${get[@]}" "$url/$asset" | sudo tee "$verified/$asset" >/dev/null \
    || die "PowerShell $ver: could not download $asset"
  "${get[@]}" "$url/hashes.sha256" | sudo tee "$verified/hashes.sha256" >/dev/null \
    || die "PowerShell $ver: could not fetch hashes.sha256 for verification"
  sudo chmod 0644 "$verified/$asset" "$verified/hashes.sha256" \
    || die "PowerShell $ver: could not let the checks below read $asset and hashes.sha256"
  # The release asset is UTF-16 LE with BOM and CRLF, generated on Windows. Read raw, awk
  # matches no filename (NUL bytes interleave every ASCII byte), so normalize to UTF-8/LF
  # first, transcoding only when a UTF-16 BOM is present.
  case "$(od -An -tx1 -N2 "$verified/hashes.sha256" | tr -d ' \n')" in
    fffe|feff) line="$(iconv -f UTF-16 -t UTF-8 "$verified/hashes.sha256" | tr -d '\r' | LC_ALL=C awk -v p="$asset" 'index($0,p){print}')" ;;
    *)         line="$(tr -d '\r' < "$verified/hashes.sha256" | LC_ALL=C awk -v p="$asset" 'index($0,p){print}')" ;;
  esac
  [[ -n "$line" && "$line" != *$'\n'* ]] \
    || die "PowerShell $ver: expected exactly one checksum line for $asset in hashes.sha256"
  expected="${line%% *}"
  actual="$(sha256sum "$verified/$asset")" || die "PowerShell $ver: could not read $verified/$asset"
  [[ "${actual%% *}" == "${expected,,}" ]] \
    || die "PowerShell $ver: $asset SHA-256 does not match hashes.sha256 (possible tamper)"
  PWSH_RELEASE_ASSET="$verified/$asset"
}

install_pwsh_tarball() {
  # Fallback PowerShell source for all downstream automation where no Microsoft
  # package serves: aarch64 without one, and x86_64 when neither apt, the release's
  # .deb nor Microsoft's 24.04 suite installed powershell. It unpacks into the tree
  # Microsoft's package installs, so callers run it only while no package owns that
  # tree. A step that fails ends the attempt before the link moves. PWSH_VERSION
  # overrides the discovery of the latest release.
  # See https://yuruna.link/4213a0b3-01b7
  local ver="${PWSH_VERSION:-}"
  if [[ -z "$ver" ]]; then
    ver="$(pwsh_latest_release)" || die "PowerShell latest-version discovery failed"
  fi
  local pkg
  case "$ARCH" in
    x86_64)  pkg="powershell-${ver}-linux-x64.tar.gz" ;;
    aarch64) pkg="powershell-${ver}-linux-arm64.tar.gz" ;;
    *)       die "no pwsh tarball for $ARCH" ;;
  esac
  log "Downloading PowerShell $ver tarball ($ARCH)"
  # Verified before it is unpacked as the interpreter for all downstream automation.
  fetch_pwsh_release_asset "$ver" "$pkg"
  sudo install -d -m 0755 /opt/microsoft/powershell/7 \
    || die "PowerShell $ver: could not create /opt/microsoft/powershell/7"
  sudo tar -xzf "$PWSH_RELEASE_ASSET" -C /opt/microsoft/powershell/7 \
    || die "PowerShell $ver: $pkg did not unpack into /opt/microsoft/powershell/7"
  sudo chmod +x /opt/microsoft/powershell/7/pwsh \
    || die "PowerShell $ver: /opt/microsoft/powershell/7/pwsh is missing after the unpack"
  sudo ln -sf /opt/microsoft/powershell/7/pwsh /usr/local/bin/pwsh \
    || die "PowerShell $ver: could not link /usr/local/bin/pwsh"
}

# --- REGION: install_pwsh_deb
# Preserve dpkg ownership and apt holds. Return 1 for an unavailable release
# asset, or 2 for a held package or an unsuccessful apt install.
# See https://yuruna.link/4213a0b3-01b7
install_pwsh_deb() {
  local ver="${PWSH_VERSION:-}" arch pkg
  if apt_package_held powershell; then
    warn "  Microsoft's powershell package is held with apt-mark hold, so no release .deb replaces it; 'sudo apt-mark unhold powershell' releases it"
    return 2
  fi
  if [[ -z "$ver" ]]; then
    ver="$(pwsh_latest_release)" || die "PowerShell latest-version discovery failed"
  fi
  case "$ARCH" in
    x86_64)  arch=amd64 ;;
    aarch64) arch=arm64 ;;
    *)       die "no PowerShell package for $ARCH" ;;
  esac
  pkg="powershell_${ver}-1.deb_${arch}.deb"
  log "Downloading the PowerShell $ver package ($ARCH)"
  fetch_pwsh_release_asset "$ver" "$pkg"
  if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall -o DPkg::Lock::Timeout=120 "$PWSH_RELEASE_ASSET"; then
    warn "  apt did not install $pkg"
    return 2
  fi
}

# Microsoft's powershell package from its apt sources, with Microsoft's Ubuntu 24.04
# suite added for it when no source the host has offers powershell (see the region
# that defines that suite). PWSH_VERSION, when the operator set it, names the version;
# otherwise apt takes the newest a source offers. x86_64 only: no Microsoft Ubuntu
# suite carries an arm64 powershell. Returns 1 when the suite could not be added, and
# 2 when apt did not install powershell.
install_pwsh_noble() {
  local want=powershell
  # The suite is Microsoft's Ubuntu 24.04 repository, so a host on another
  # distribution, such as the AMD Ryzen AI platform's Debian, never gets it added.
  if [[ "${ID:-}" != ubuntu ]]; then
    log "Not adding Microsoft's Ubuntu 24.04 suite: this host runs ${PRETTY_NAME:-${ID:-another distribution}}, not Ubuntu"
    return 3
  fi
  if [[ -n "${PWSH_VERSION:-}" ]]; then want="powershell=${PWSH_VERSION}-1.deb"; fi
  if ! apt_offers_powershell; then
    add_pwsh_noble_source || return 1
  fi
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$want" || return 2
}

# Runs one PowerShell source in a subshell with its own temp registry: errexit does not
# hold there, so each source checks its own steps, and a die() in one ends that source,
# never the run or the next source. The name is re-read afterward. A source succeeds by
# the version pwsh answers then, never by this status, which only tells the closing
# report why a source fell short.
run_pwsh_source() {
  local rc=0
  ( YURUNA_TMP_PATHS=(); trap yuruna_cleanup_tmp_paths EXIT; "$@" ) || rc=$?
  hash -r
  return "$rc"
}

# Presence only, deliberately: this runs before the checkout exists, so the
# floor it would have to compare against is not readable yet. An already-present
# pwsh is moved to the newest release and checked against the floor by the region
# further down, once the repo is on disk. On x86_64 each source runs only while pwsh
# is still absent; on aarch64 the tarball is the one source, and a release GitHub
# cannot name ends the run.
if ! command -v pwsh >/dev/null 2>&1; then
  case "$ARCH" in
    x86_64)
      run_pwsh_source install_pwsh_apt || true
      command -v pwsh >/dev/null 2>&1 || run_pwsh_source install_pwsh_deb || true
      command -v pwsh >/dev/null 2>&1 || run_pwsh_source install_pwsh_noble || true
      command -v pwsh >/dev/null 2>&1 || powershell_deb_installed || run_pwsh_source install_pwsh_tarball || true
      ;;
    aarch64) install_pwsh_tarball ;;
  esac
fi
command -v pwsh >/dev/null 2>&1 || die "pwsh not found after install."

# --- REGION: PowerShell modules
# The pinned version and the SHA-512 the gallery publishes for its package
# (PackageHash, base64): the bytes are checked before anything is unpacked.
# The same pin lives in test/modules/Test.HostGit.psm1, which installs it on a
# host set up without this script, and in the other host installers;
# Test.HostGitInstall keeps every copy equal.
POWERSHELL_YAML_VERSION="0.4.12"
POWERSHELL_YAML_SHA512="Vc5DLyw7hLsCL6yFlSvzsdUUWmgfqoM35XmRavtKOz37GHBg3p+vWxaO/9wS8MbptzWspdUBcVRGSqAdlJmtUg=="
log "Installing required PowerShell modules"
YURUNA_MODULE_VERSION="$POWERSHELL_YAML_VERSION" YURUNA_MODULE_SHA512="$POWERSHELL_YAML_SHA512" pwsh -NoProfile -Command '
    $name = "powershell-yaml"; $version = $env:YURUNA_MODULE_VERSION; $sha512 = $env:YURUNA_MODULE_SHA512
    # A copy older than the pin is replaced by it: the pinned copy installs beside
    # the old one, and the module loader picks the highest version. A newer copy
    # is left alone.
    $newest = Get-Module -ListAvailable -Name $name -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
    if ($newest -and $newest.Version -ge [version]$version) {
        Write-Output "  powershell-yaml $($newest.Version) already installed"
    } else {
        if ($newest) { Write-Output "  replacing powershell-yaml $($newest.Version) with the pinned $version (CurrentUser scope)" }
        else { Write-Output "  installing powershell-yaml $version (CurrentUser scope)" }
        $package = Join-Path ([IO.Path]::GetTempPath()) ("yuruna-$name-" + [guid]::NewGuid().ToString("N") + ".nupkg")
        try {
            Invoke-WebRequest -Uri "https://www.powershellgallery.com/api/v2/package/$name/$version" -OutFile $package -TimeoutSec 300 -ErrorAction Stop | Out-Null
            $actual = [Convert]::ToBase64String([Security.Cryptography.SHA512]::HashData([IO.File]::ReadAllBytes($package)))
            if ($actual -cne $sha512) { throw "the package SHA-512 $actual does not match the pinned $sha512" }
            $data = if ($env:XDG_DATA_HOME) { $env:XDG_DATA_HOME } else { Join-Path $HOME ".local/share" }
            $nameDir = Join-Path $data "powershell/Modules/$name"
            $staging = Join-Path $nameDir (".$version." + [guid]::NewGuid().ToString("N") + ".staging")
            $stagingFull = [IO.Path]::GetFullPath($staging) + [IO.Path]::DirectorySeparatorChar
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [IO.Compression.ZipFile]::OpenRead($package)
            try {
                foreach ($entry in $zip.Entries) {
                    $relative = [uri]::UnescapeDataString($entry.FullName)
                    if (-not $entry.Name -or $relative -eq "[Content_Types].xml" -or $relative -like "_rels/*" -or $relative -like "package/*" -or ($relative -notmatch "/" -and $relative -like "*.nuspec")) { continue }
                    $destination = [IO.Path]::GetFullPath((Join-Path $staging $relative))
                    if (-not $destination.StartsWith($stagingFull, [StringComparison]::Ordinal)) { throw "package entry $($entry.FullName) escapes the module directory" }
                    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destination, $false)
                }
            } finally { $zip.Dispose() }
            $target = Join-Path $nameDir $version
            if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
            [IO.Directory]::Move($staging, $target)
        } catch {
            if ($staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
            Write-Warning "  installing powershell-yaml $version failed: $($_.Exception.Message)"
            Write-Warning "  Invoke-TestProject.ps1 will refuse to run until this is fixed."
            exit 1
        } finally {
            Remove-Item -LiteralPath $package -Force -ErrorAction SilentlyContinue
        }
    }
' || note_issue "Installing the powershell-yaml module reported an error; the harness needs it to read any YAML config. Re-run this installer, or install it by hand with: pwsh -Command 'Install-Module powershell-yaml -RequiredVersion $POWERSHELL_YAML_VERSION -Scope CurrentUser'"

# --- REGION: libvirt configuration
# Services, group membership, the libvirt-qemu traverse ACL and the default network.
# See https://yuruna.link/429fb30b-0036 and https://yuruna.link/429fb30b-0037
log "Enabling libvirtd + virtlogd"
sudo systemctl enable --now libvirtd
sudo systemctl enable --now virtlogd

NEEDS_RELOG=0
for grp in libvirt kvm; do
  if ! group_names "$USER" | grep -x "$grp" >/dev/null; then
    log "  adding $USER to group $grp"
    sudo usermod -aG "$grp" "$USER"
    NEEDS_RELOG=1
  fi
done

if getent passwd libvirt-qemu >/dev/null 2>&1; then
  if command -v setfacl >/dev/null 2>&1; then
    log "Granting libvirt-qemu traverse on $HOME (POSIX ACL)"
    sudo setfacl -m 'u:libvirt-qemu:--x' "$HOME" || \
      warn "  setfacl failed -- preflight will retry / report"
  else
    warn "  setfacl absent -- 'sudo apt-get install acl' (already a hard apt dep, this should not happen)."
  fi
fi

ensure_default_network() {
  if ! sudo virsh net-info default >/dev/null 2>&1; then
    warn "  libvirt 'default' network missing -- not redefining (rare)."
    return
  fi
  if ! sudo virsh net-list --name | grep -qx default; then
    log "  starting libvirt 'default' network"
    sudo virsh net-start default >/dev/null 2>&1 || true
  fi
  sudo virsh net-autostart default >/dev/null 2>&1 || true
}
ensure_default_network

# --- REGION: Preserve test/status runtime state
TEST_STATUS_SUBDIRS=(runtime perf log extension captures ssh)
preserve_test_status() {
  local src="$YURUNA_DIR/test/status"
  [[ -d "$src" ]] || return 0
  local has_runtime=""
  local sub
  for sub in "${TEST_STATUS_SUBDIRS[@]}"; do
    [[ -d "$src/$sub" ]] || continue
    if find "$src/$sub" -mindepth 1 -not -name '.gitkeep' -print -quit 2>/dev/null | grep -q .; then
      has_runtime=1; break
    fi
  done
  [[ -n "$has_runtime" ]] || return 0
  YURUNA_STATUS_BACKUP=$(mktemp -d) || { warn "  could not create temp dir; skipping test/status preservation"; return 0; }
  log "Preserving test/status runtime state (cycle history, logs, perf, vault, captures, ssh keys)"
  log "  source : $src"
  log "  backup : $YURUNA_STATUS_BACKUP"
  for sub in "${TEST_STATUS_SUBDIRS[@]}"; do
    if [[ -d "$src/$sub" ]]; then
      mkdir -p "$YURUNA_STATUS_BACKUP/$sub"
      cp -a "$src/$sub/." "$YURUNA_STATUS_BACKUP/$sub/" 2>/dev/null || true
    fi
  done
}
restore_test_status() {
  [[ -n "${YURUNA_STATUS_BACKUP:-}" && -d "${YURUNA_STATUS_BACKUP:-}" ]] || return 0
  local dst="$YURUNA_DIR/test/status"
  log "Restoring preserved test/status runtime state"
  local sub
  for sub in "${TEST_STATUS_SUBDIRS[@]}"; do
    if [[ -d "$YURUNA_STATUS_BACKUP/$sub" ]]; then
      mkdir -p "$dst/$sub"
      cp -a "$YURUNA_STATUS_BACKUP/$sub/." "$dst/$sub/" 2>/dev/null || true
    fi
  done
  rm -rf "$YURUNA_STATUS_BACKUP"
  YURUNA_STATUS_BACKUP=""
}

# --- REGION: Tolerate a v / no-v tag mismatch
# See https://yuruna.link/429fb30b-0007
# Echoes the ref on stdout; warn -> stderr, so a warning never pollutes the
# captured stdout used to set YURUNA_BRANCH.
resolve_yuruna_ref() {
  local remote="$1" ref="$2" variant=""
  if [[ -z "$remote" || -z "$ref" ]]; then printf '%s' "$ref"; return 0; fi
  if   [[ "$ref" =~ ^v([0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?)$ ]]; then variant="${BASH_REMATCH[1]}"
  elif [[ "$ref" =~ ^([0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?)$  ]]; then variant="v$ref"
  else printf '%s' "$ref"; return 0; fi
  if GIT_TERMINAL_PROMPT=0 git ls-remote --exit-code "$remote" "refs/tags/$ref" "refs/heads/$ref" >/dev/null 2>&1; then
    printf '%s' "$ref"; return 0
  fi
  if GIT_TERMINAL_PROMPT=0 git ls-remote --exit-code "$remote" "refs/tags/$variant" "refs/heads/$variant" >/dev/null 2>&1; then
    warn "Requested ref '$ref' not found on $remote; using existing variant '$variant' (canonical Yuruna release tags are bare CalVer, no 'v')."
    printf '%s' "$variant"; return 0
  fi
  # Neither form resolves -- for a CalVer ref the pinned release tag is likely
  # not published yet (the VERSION/installer pin ran ahead of the tag).
  warn "Neither '$ref' nor '$variant' resolves on $remote -- the pinned release tag may not be published yet. To install the latest unreleased code, re-run with YURUNA_BRANCH=main."
  printf '%s' "$ref"
}

# --- REGION: Development repo pulls latest main, not a release tag
# See https://yuruna.link/429fb30b-0008
use_dev_branch_if_needed() {
  local basename="$1"
  if [[ "$basename" == "yurunadev" && "$YURUNA_BRANCH_EXPLICIT" -eq 0 && "$YURUNA_BRANCH" != "main" ]]; then
    # The name is interpolated rather than written into the sentence. Shipped
    # text is copied verbatim into the generated translation catalogs, which
    # carry no allowlist for the private development source, so a literal name
    # here reaches a published artifact that may not carry it. The compared
    # value is the same name, so the line a reader sees does not change.
    log "  $basename is a development repo (tagged only at release) -- tracking latest 'main' instead of '$YURUNA_BRANCH'"
    YURUNA_BRANCH="main"
  fi
}

# --- REGION: Checkout repair helpers
# Shared word for word between the macOS and Ubuntu installers (a test holds the
# copies equal) and kept to bash 3.2. Both run where a checkout is already on
# disk, so a failure is recorded and the run goes on with what is there.

# A backup path for $1 that does not exist yet. The name is stamped to the
# second, and a numeric suffix covers the rest: `mv` onto a directory that is
# already there would move the checkout INSIDE it, and the put-back below would
# then restore the wrong tree.
unique_backup_path() {
  local base candidate n=1
  base="$1.backup.$(date +%Y-%m-%d.%H-%M-%S)"
  candidate="$base"
  while [[ -e "$candidate" || -L "$candidate" ]]; do
    candidate="$base.$n"
    n=$(( n + 1 ))
  done
  printf '%s\n' "$candidate"
}

# Re-clones into $YURUNA_DIR after the existing checkout was moved to $1. A clone
# that cannot finish (the remote unreachable, a pinned tag not published yet)
# would otherwise end the run with no checkout at all, and the exit trap would
# delete the preserved test status with it. The moved checkout goes back
# instead, and the run continues on it as it does when the pull is skipped.
reclone_checkout() {
  local backup="$1" remote="$2"
  log "Cloning fresh Yuruna into $YURUNA_DIR from $remote"
  if git clone --branch "$YURUNA_BRANCH" "$remote" "$YURUNA_DIR"; then
    return 0
  fi
  rm -rf "$YURUNA_DIR" 2>/dev/null || true
  # Something still at the path would take the moved checkout inside it.
  if [[ ! -e "$YURUNA_DIR" && ! -L "$YURUNA_DIR" ]] && mv "$backup" "$YURUNA_DIR"; then
    YURUNA_BACKUP_CREATED=""
    note_issue "Re-cloning from $remote ('$YURUNA_BRANCH') failed, so the previous checkout was put back at $YURUNA_DIR and used as-is. Re-run the installer once the remote and the ref are reachable."
    return 0
  fi
  die "Re-cloning from $remote failed and the previous checkout could not be put back. It is at $backup, with its test/status runtime state inside."
}

# Rebuilds the working tree under the current .gitattributes, best effort. A
# held .git/index.lock (left by a git that crashed, or taken by an editor's
# `git status` racing this step) fails `rm --cached` or `reset`, and the first
# may already have emptied the index; the index is put back from HEAD and the
# operator gets the one command that finishes the job. A held .git/config.lock
# fails the config writes the same way, and neither is worth ending the run.
renormalize_checkout() {
  log "Renormalizing repo line endings (per .gitattributes)"
  git -C "$YURUNA_DIR" config core.autocrlf input \
    || warn "  could not set core.autocrlf in $YURUNA_DIR -- continuing."
  if ! git -C "$YURUNA_DIR" config --get-all include.path 2>/dev/null \
       | grep -Fx '../.gitconfig.yuruna' >/dev/null; then
    if git -C "$YURUNA_DIR" config --local --add include.path '../.gitconfig.yuruna'; then
      log "  Enabled pull.rebase via .gitconfig.yuruna include"
    else
      warn "  could not add the .gitconfig.yuruna include to $YURUNA_DIR -- continuing."
    fi
  fi
  git -C "$YURUNA_DIR" update-index --refresh >/dev/null 2>&1 || true
  if ! git -C "$YURUNA_DIR" diff-index --quiet HEAD -- 2>/dev/null; then
    warn "  Working tree has uncommitted changes -- only renormalizing the index."
    git -C "$YURUNA_DIR" add --renormalize . || true
    warn "  After resolving local changes, run: git checkout HEAD -- ."
  elif git -C "$YURUNA_DIR" rm -r --cached --quiet . \
       && git -C "$YURUNA_DIR" reset --hard HEAD >/dev/null; then
    log "  Working tree rebuilt under current .gitattributes (LF for *.sh, etc.)"
  else
    git -C "$YURUNA_DIR" reset --quiet HEAD 2>/dev/null || true
    note_issue "Could not rebuild $YURUNA_DIR under .gitattributes; another git process may hold .git/index.lock, or a crashed one left it behind. Once it is free, run: git -C '$YURUNA_DIR' reset --hard HEAD"
  fi
}

# --- REGION: Clone / update the repo
YURUNA_BACKUP_CREATED=""
preserve_test_status
mkdir -p "$(dirname "$YURUNA_DIR")"
if [[ -d "$YURUNA_DIR/.git" ]]; then
  log "Updating existing Yuruna checkout at $YURUNA_DIR"
  actual_remote="$(git -C "$YURUNA_DIR" remote get-url origin 2>/dev/null || true)"
  remote_normalized="${actual_remote%/}"
  remote_basename="$(basename "${remote_normalized%.git}" 2>/dev/null || true)"
  log "  remote : ${actual_remote:-<none>}"

  skip_pull=0
  if [[ "$remote_basename" == "yurunadev" ]]; then
    if ! GIT_TERMINAL_PROMPT=0 git ls-remote --exit-code "$actual_remote" HEAD >/dev/null 2>&1; then
      warn ""
      warn "========"
      warn "  $actual_remote requires GitHub authentication to pull, and"
      warn "  the current credentials don't grant access (or no credentials"
      warn "  are configured)."
      warn ""
      warn "  Authenticate first, then re-run this installer:"
      warn "    gh auth login     # interactive GitHub CLI sign-in"
      warn "    # OR configure an SSH key with read access to the repo"
      warn ""
      warn "  Continuing this run WITHOUT updating $YURUNA_DIR --"
      warn "  existing on-disk content will be used as-is."
      warn "========"
      warn ""
      skip_pull=1
    fi
  fi

  if [[ $skip_pull -eq 0 ]]; then
    use_dev_branch_if_needed "$remote_basename"
    YURUNA_BRANCH="$(resolve_yuruna_ref "$actual_remote" "$YURUNA_BRANCH")"
    # --force so a remote-moved release tag overwrites the stale local one: a plain
    # `fetch --tags` exits non-zero when a CalVer tag points at a different commit in the
    # public and development repos, and under `set -e` that aborts before checkout. Any
    # remaining fetch error degrades to a warning so the pull --ff-only fallback still runs.
    if ! git -C "$YURUNA_DIR" fetch --tags --force origin; then
      warn "git fetch reported rejected/partial tag updates -- continuing; checkout/pull below will surface anything fatal."
    fi
    # Guard the checkout (not just the pull): under `set -e` an unguarded
    # `git checkout` that fails -- e.g. switching a dirty tree between the
    # moving 'main' branch and a pinned tag, which would overwrite local
    # changes -- aborts the whole installer before the move-aside-and-reclone
    # rescue below can run. Routing a failed checkout into the same rescue
    # keeps a mode flip (PIN_VERSION on/off) robust to a dirty working tree.
    if ! { git -C "$YURUNA_DIR" checkout "$YURUNA_BRANCH" \
           && git -C "$YURUNA_DIR" pull --ff-only origin "$YURUNA_BRANCH"; }; then
      YURUNA_BACKUP_DIR="$(unique_backup_path "$YURUNA_DIR")"
      warn "git pull --ff-only failed -- moving the existing checkout aside and re-cloning."
      warn "  from: $YURUNA_DIR"
      warn "  to:   $YURUNA_BACKUP_DIR"
      if ! mv "$YURUNA_DIR" "$YURUNA_BACKUP_DIR"; then
        die "Could not move '$YURUNA_DIR' to '$YURUNA_BACKUP_DIR'. Close any shells / editors / file managers holding the path open and re-run this installer."
      fi
      YURUNA_BACKUP_CREATED="$YURUNA_BACKUP_DIR"
      reclone_remote="${actual_remote:-$YURUNA_REPO}"
      reclone_checkout "$YURUNA_BACKUP_DIR" "$reclone_remote"
    fi
  fi
else
  clone_basename="$(basename "${YURUNA_REPO%/}" 2>/dev/null || true)"
  clone_basename="${clone_basename%.git}"
  use_dev_branch_if_needed "$clone_basename"
  YURUNA_BRANCH="$(resolve_yuruna_ref "$YURUNA_REPO" "$YURUNA_BRANCH")"
  log "Cloning Yuruna into $YURUNA_DIR from $YURUNA_REPO"
  git clone --branch "$YURUNA_BRANCH" "$YURUNA_REPO" "$YURUNA_DIR"
fi

# --- REGION: Renormalize line endings under .gitattributes
if [[ -d "$YURUNA_DIR/.git" ]]; then
  renormalize_checkout
fi

# --- REGION: Pin to the current release
# Opt-in through PIN_VERSION=1 or --pin-version.
# See https://yuruna.link/429fb30b-0006
if [[ "$PIN_VERSION" != "0" && "$YURUNA_BRANCH_EXPLICIT" -eq 0 && -d "$YURUNA_DIR/.git" ]]; then
  if [[ -f "$YURUNA_DIR/VERSION" ]]; then
    pin_tag="$(tr -d '[:space:]' < "$YURUNA_DIR/VERSION")"
    log "Pinning to release $pin_tag (from VERSION) -- this host will NOT auto-update"
    if ! git -C "$YURUNA_DIR" checkout "$pin_tag"; then
      warn "Could not check out '$pin_tag' (the release tag may not be published yet) -- leaving the host on 'main' (it will auto-update). Re-run with PIN_VERSION=1 after the tag is cut, or set YURUNA_BRANCH=<tag>."
    fi
  else
    warn "No VERSION file in $YURUNA_DIR -- cannot resolve a release to pin; leaving the host on 'main'."
  fi
fi
restore_test_status
restore_installer_state

# --- REGION: PowerShell floor repair
# The interpreter every later step runs on, moved to the newest release its own
# source offers and then checked against the floor in automation/Yuruna.Requirement.yml.
# Presence is not the question a floor asks, so this runs after the checkout, where
# the floor lives, not beside the install.
# See https://yuruna.link/4213a0b3-01b1
requirement_floor() {
  # A `version:` string carries vendor decoration around the number
  # ("7.6.4 (Core)"); the first dotted-number run is the version. Two keys at a
  # fixed indent, so awk reads them without a YAML parser this early in a run.
  local want="$1" yml="$YURUNA_DIR/automation/Yuruna.Requirement.yml"
  [[ -f "$yml" ]] || return 1
  awk -v want="$want" '
    $0 ~ "^[[:space:]]*-[[:space:]]+tool:[[:space:]]*\"" want "\"[[:space:]]*$" { seen = 1; next }
    seen && /^[[:space:]]*-[[:space:]]+tool:/ { exit }
    seen && /^[[:space:]]*version:/ {
      if (match($0, /[0-9]+(\.[0-9]+)+/)) { print substr($0, RSTART, RLENGTH); exit }
    }
  ' "$yml"
}

# A >= B, field by field as numbers: 7.6.10 is newer than 7.6.4, which both a
# string compare and a float compare get backwards.
version_ge() {
  [[ -n "$1" ]] || return 1
  [[ -n "$2" ]] || return 0
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | head -1)" == "$2" ]]
}

pwsh_version() {
  pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null \
    | grep -oE '[0-9]+(\.[0-9]+){1,3}' | head -1
}

# The source that owns the pwsh on PATH, or the one at the path given: snap, apt
# (Microsoft's package), tarball (a copy this installer unpacked under
# /opt/microsoft/powershell/7), other, or none.
pwsh_source() {
  local path="${1:-}" resolved
  if [[ -z "$path" ]]; then
    path="$(command -v pwsh 2>/dev/null)" || { printf 'none\n'; return 0; }
  fi
  case "$path" in /snap/*) printf 'snap\n'; return 0 ;; esac
  resolved="$(readlink -f "$path" 2>/dev/null || printf '%s' "$path")"
  if [[ "$resolved" == /opt/microsoft/powershell/7/pwsh ]]; then
    if powershell_deb_installed; then printf 'apt\n'; else printf 'tarball\n'; fi
    return 0
  fi
  printf 'other\n'
}

# Moves Microsoft's package until pwsh answers $1 or newer: through apt from the
# verified .deb of release $2 (the newest when empty), then, on x86_64, from Microsoft's
# apt sources, with its 24.04 suite added when the host's sources carry none. When it
# falls short it leaves why in PWSH_UPGRADE_WHY, for the floor issue and the closing
# report.
PWSH_UPGRADE_WHY=""
raise_pwsh_package() {
  local reach="$1" release="$2" rc=0 why
  PWSH_VERSION="$release" run_pwsh_source install_pwsh_deb || rc=$?
  if version_ge "$(pwsh_version || true)" "$reach"; then return 0; fi
  case "$rc" in
    0) why="$(command -v pwsh || echo pwsh) still answers below $reach after the release .deb installed" ;;
    2) why="apt did not install the release .deb" ;;
    *) why="the release .deb could not be fetched or verified" ;;
  esac
  if [[ "$ARCH" == x86_64 ]]; then
    rc=0
    run_pwsh_source install_pwsh_noble || rc=$?
    if version_ge "$(pwsh_version || true)" "$reach"; then return 0; fi
    case "$rc" in
      0) why="$why, and Microsoft's apt sources offer nothing at or past $reach" ;;
      2) why="$why, and apt did not install powershell from Microsoft's apt sources" ;;
      3) why="$why, and Microsoft's Ubuntu 24.04 suite is added only on Ubuntu hosts" ;;
      *) why="$why, and Microsoft's Ubuntu 24.04 suite could not be added" ;;
    esac
  fi
  PWSH_UPGRADE_WHY="$why"
}

# How many files of Microsoft's powershell package under /opt/microsoft/powershell/7,
# the tree a tarball unpacks into, dpkg -V finds changed or missing: 0 when every one
# matches what dpkg recorded, and when dpkg cannot tell. dpkg -V exits 0 whatever it
# finds, so its lines are what is counted. A file elsewhere does not count: dpkg -V also
# lists as missing a file that dpkg's own path-exclude setting kept from being unpacked,
# such as the package's manual page on a minimized Ubuntu install, and a reinstall
# leaves that file out again.
pwsh_package_mismatches() {
  { LC_ALL=C dpkg -V powershell 2>/dev/null || true; } \
    | awk '$NF ~ /^\/opt\/microsoft\/powershell\/7\// { n++ } END { print n + 0 }'
}

# --- REGION: bring_powershell_to_newest
# Upgrade through the interpreter's own source between pwsh calls, preserving
# holds and package ownership. A failed source ends its attempt, not the install.
# See https://yuruna.link/4213a0b3-01b8
bring_powershell_to_newest() {
  local have want source damaged
  have="$(pwsh_version || true)"
  source="$(pwsh_source)"
  case "$source" in
    snap)
      log "Refreshing the PowerShell snap to its channel's newest release"
      sudo snap refresh powershell || warn "  'snap refresh powershell' failed; the snap keeps ${have:-its version}"
      ;;
    apt)
      damaged="$(pwsh_package_mismatches)"
      if apt_package_held powershell; then
        if (( damaged > 0 )); then
          note_issue "Microsoft's powershell package has files that no longer match what dpkg recorded ('dpkg -V powershell' lists $damaged under /opt/microsoft/powershell/7), and it is held with apt-mark hold, so this installer leaves it; release it with 'sudo apt-mark unhold powershell' and re-run this installer, which reinstalls it."
        fi
        log "PowerShell ${have:-(unreadable)} is Microsoft's package, held with apt-mark hold -- leaving it"
        return 0
      fi
      want="${PWSH_VERSION:-}"
      if [[ -z "$want" ]] && ! want="$(pwsh_latest_release)"; then
        warn "GitHub did not name PowerShell's newest release; the package keeps ${have:-its version}"
        want=""
      fi
      if [[ -n "$want" ]] && ! { [[ -n "$have" ]] && version_ge "$have" "$want"; }; then
        log "Upgrading Microsoft's PowerShell package from ${have:-(unreadable)} to $want"
        raise_pwsh_package "$want" "$want"
        if ! version_ge "$(pwsh_version || true)" "$want"; then
          warn "  PowerShell $want could not be installed: $PWSH_UPGRADE_WHY; PowerShell stays at $(pwsh_version || echo "${have:-its version}")"
        fi
      elif (( damaged > 0 )) && [[ -n "$have" ]]; then
        log "Microsoft's PowerShell package has files that no longer match what dpkg recorded ('dpkg -V powershell' lists $damaged under /opt/microsoft/powershell/7) -- reinstalling PowerShell $have from the release's .deb"
        PWSH_VERSION="$have" run_pwsh_source install_pwsh_deb || true
      elif [[ -n "$want" ]]; then
        log "PowerShell $have is at or past $want, the release the package path would install"
      fi
      if (( damaged > 0 )); then
        damaged="$(pwsh_package_mismatches)"
        if (( damaged > 0 )); then
          note_issue "Microsoft's powershell package still has files that do not match what dpkg recorded ('dpkg -V powershell' lists $damaged under /opt/microsoft/powershell/7); the output above says why no release .deb replaced them, and re-running this installer tries again."
        else
          log "  every file of Microsoft's PowerShell package matches what dpkg recorded"
        fi
      fi
      ;;
    tarball)
      want="${PWSH_VERSION:-}"
      if [[ -z "$want" ]] && ! want="$(pwsh_latest_release)"; then
        warn "GitHub did not name PowerShell's newest release; the tarball copy keeps ${have:-its version}"
        return 0
      fi
      if [[ -n "$have" ]] && version_ge "$have" "$want"; then
        log "PowerShell $have is at or past $want, the release the tarball path would install"
        return 0
      fi
      log "Upgrading PowerShell ${have:-(unreadable)} to $want from the release tarball"
      PWSH_VERSION="$want" run_pwsh_source install_pwsh_tarball || true
      if ! version_ge "$(pwsh_version || true)" "$want"; then
        warn "  the PowerShell $want tarball could not be installed; PowerShell stays at ${have:-its version}"
      fi
      ;;
    *) ;;
  esac
  hash -r
}

bring_powershell_to_required_version() {
  local floor have target from
  floor="$(requirement_floor PowerShell || true)"
  have="$(pwsh_version || true)"
  if [[ -z "$floor" ]]; then
    warn "Could not read the PowerShell floor from $YURUNA_DIR/automation/Yuruna.Requirement.yml -- leaving the installed interpreter alone."
    return 0
  fi
  if [[ -z "$have" ]]; then
    note_issue "pwsh is on PATH but reported no version, so it could not be checked against the $floor floor."
    return 0
  fi
  if version_ge "$have" "$floor"; then
    log "PowerShell $have meets the $floor floor"
    return 0
  fi
  log "PowerShell $have is below the $floor floor -- upgrading"
  # A snap advances only through snapd; neither apt nor the tarball can touch
  # one. Ask snapd rather than inspecting the resolved path, so the answer comes
  # from the thing that owns the package: when it does carry a PowerShell,
  # refreshing in place keeps the provenance the operator chose, and only a
  # channel that cannot reach the floor falls through to the sources below.
  if command -v snap >/dev/null 2>&1 && snap list powershell >/dev/null 2>&1; then
    log "  refreshing the PowerShell snap"
    sudo snap refresh powershell || warn "  'snap refresh powershell' failed -- trying the sources this installer manages"
    hash -r
    have="$(pwsh_version || true)"
  fi
  if ! version_ge "$have" "$floor"; then
    # A package the operator holds is replaced from no source: apt refuses it, and a
    # tarball unpacked over it would defeat the hold.
    if powershell_deb_installed && apt_package_held powershell; then
      note_issue "PowerShell $have is below the $floor floor, and Microsoft's powershell package is held with apt-mark hold, so this installer leaves it; release it with 'sudo apt-mark unhold powershell' and re-run this installer."
      return 0
    fi
    # The release the .deb and the tarball install: PWSH_VERSION, or whatever GitHub
    # marks as the latest. One below the floor is never installed -- nor, since the
    # installed version is below the floor too, one below that -- so the repair then
    # installs nothing. When GitHub does not answer, each source asks it again.
    target="${PWSH_VERSION:-}"
    if [[ -z "$target" ]]; then target="$(pwsh_latest_release || true)"; fi
    if [[ -n "$target" ]] && ! version_ge "$target" "$floor"; then
      if [[ -n "${PWSH_VERSION:-}" ]]; then from="PWSH_VERSION names $target"; else from="GitHub's newest release is $target"; fi
      note_issue "PowerShell $have is below the $floor floor, and $from, which is below it too, so this installer installed nothing; re-run it with PWSH_VERSION set to $floor or later."
      return 0
    fi
    # Judge each source by the version pwsh answers afterward. A package owns
    # its tree even when its source cannot satisfy the floor, so never overwrite it.
    # See https://yuruna.link/4213a0b3-01b8
    if [[ "$ARCH" == x86_64 ]] && ! powershell_deb_installed; then
      run_pwsh_source install_pwsh_apt || true
    fi
    if ! version_ge "$(pwsh_version || true)" "$floor" \
       && { [[ "$ARCH" == x86_64 ]] || powershell_deb_installed; }; then
      raise_pwsh_package "$floor" "$target"
    fi
    if ! version_ge "$(pwsh_version || true)" "$floor" && ! powershell_deb_installed; then
      PWSH_VERSION="$target" run_pwsh_source install_pwsh_tarball \
        || PWSH_UPGRADE_WHY="${PWSH_UPGRADE_WHY:+$PWSH_UPGRADE_WHY, and }the release tarball could not be installed"
    fi
    have="$(pwsh_version || true)"
  fi
  if version_ge "$have" "$floor"; then
    log "  PowerShell is now $have"
  else
    note_issue "PowerShell is ${have:-unreadable} after the upgrade attempt, still below the $floor floor${PWSH_UPGRADE_WHY:+: $PWSH_UPGRADE_WHY}."
  fi
}
bring_powershell_to_newest
bring_powershell_to_required_version

# --- REGION: AMD Ryzen AI Developer Platform floor repair
# See https://yuruna.link/429fb30b-0035
# Repair tool floors without replacing platform libraries or its ABI-bound system Python.

# The first dotted number on the first line `<tool> --version` prints:
# "git version 2.47.3", "Python 3.13.5", "curl 8.14.1 (x86_64-pc-linux-gnu) ...",
# "qemu-img version 10.0.13 (Debian 1:10.0.13+ds-0+deb13u1)".
tool_version() {
  "$1" --version 2>/dev/null | head -1 | grep -oE '[0-9]+(\.[0-9]+)+' | head -1
}

# Succeeds when the tool answers below its floor. The requirement rows for these
# tools are named after the command itself. An absent tool or an unreadable floor
# is left to the closing check, which reports both.
tool_below_floor() {
  local tool="$1" floor have
  floor="$(requirement_floor "$tool" || true)"
  have="$(tool_version "$tool" || true)"
  [[ -n "$floor" && -n "$have" ]] || return 1
  if version_ge "$have" "$floor"; then
    log "  $tool $have meets the $floor floor"
    return 1
  fi
  log "  $tool $have is below the $floor floor"
  return 0
}

# After a repair, say what the command name answers with now. A shortfall left
# here also reaches the closing summary; naming the binary that answered is what
# that line cannot say, and it shows a copy elsewhere on PATH winning the name.
confirm_tool_floor() {
  local tool="$1" floor have
  floor="$(requirement_floor "$tool" || true)"
  have="$(tool_version "$tool" || true)"
  if version_ge "$have" "$floor"; then
    log "  $tool now answers $have"
  else
    warn "  $tool answers ${have:-nothing} after the repair, still below the $floor floor (resolved: $(command -v "$tool" || echo none))."
  fi
}

# Adds a Debian suite as an apt source unless one is already configured. The
# match skips commented lines and the -sloppy suite, and reads only the files apt
# reads, so a leftover .save copy does not count as configured.
enable_debian_backports() {
  local suite="$1" list="/etc/apt/sources.list.d/yuruna-$1.sources"
  local keyring=/usr/share/keyrings/debian-archive-keyring.gpg
  if grep -qsE "^[^#]*[[:space:]]${suite}([[:space:]]|\$)" \
       /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; then
    log "  $suite is already an apt source"
    return 0
  fi
  if [[ ! -r "$keyring" ]]; then
    warn "  $keyring is missing, so $suite could not be verified -- not adding it."
    return 1
  fi
  log "  adding $suite as an apt source ($list)"
  printf '%s\n' 'Types: deb' 'URIs: http://deb.debian.org/debian' "Suites: $suite" \
    'Components: main' "Signed-By: $keyring" | sudo tee "$list" >/dev/null || return 1
  if ! sudo apt-get update -q; then
    # Remove only the source this attempt created; leave prior configuration alone.
    sudo rm -f "$list" || true
    return 1
  fi
}

# Backports is NotAutomatic: apt never selects it on its own, so the target
# release is named for the packages that need it. ButAutomaticUpgrades keeps the
# installed backports current on an ordinary upgrade afterwards.
raise_tool_from_suite() {
  local suite="$1" tool="$2"; shift 2
  tool_below_floor "$tool" || return 0
  log "  installing $* from $suite"
  if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends -t "$suite" "$@"; then
    note_issue "Installing $* from $suite failed, so $tool stays below its floor -- see the apt output above."
    return 0
  fi
  confirm_tool_floor "$tool"
}

build_git_from_source() {
  local ver="$1" work="$2" suite="${3:-}"
  local base="https://www.kernel.org/pub/software/scm/git" tarball="$work/git-$ver.tar"
  # Junio C Hamano's key; the tarballs are signed by one of its subkeys. Refresh
  # on a key rotation: `gpg --list-packets git-<ver>.tar.sign` names the signing
  # subkey, and the key it belongs to is the new primary fingerprint.
  local GIT_RELEASE_KEY_FPR='96E07AF25771955980DAD10020D04E5A713660A7'
  local -a deps=(make gcc libc6-dev libcurl4-openssl-dev libexpat1-dev libssl-dev libpcre2-dev zlib1g-dev gettext gpg gpgv)
  log "  installing the packages git $ver builds against"
  # libcurl4-openssl-dev requires exactly the installed libcurl4t64, so once curl
  # comes from backports the headers have to come from there too.
  if [[ -n "$suite" ]]; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends -t "$suite" "${deps[@]}" || return 1
  else
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${deps[@]}" || return 1
  fi

  log "  downloading git $ver from kernel.org"
  curl -fsSL --retry 3 -o "$tarball.gz" "$base/git-$ver.tar.gz" || return 1
  curl -fsSL --retry 3 -o "$tarball.sign" "$base/git-$ver.tar.sign" || return 1
  # kernel.org signs the uncompressed tar, so the signature is checked against it
  # and the build unpacks those same verified bytes.
  gzip -dc "$tarball.gz" > "$tarball" || return 1

  # FAIL CLOSED: an unverified tarball is never built. The key is fetched over plain HTTPS
  # because `gpg --recv-keys` cannot reach a keyserver from some networks. Only a signature
  # by the pinned primary key passes, and gpgv checks it without an agent or trust database.
  local key="$work/git-release-key" vstatus
  if ! { curl -fsSL --retry 3 -o "$key.asc" \
           "https://git.kernel.org/pub/scm/docs/kernel/pgpkeys.git/plain/keys/${GIT_RELEASE_KEY_FPR: -16}.asc" \
         || curl -fsSL --retry 3 -o "$key.asc" \
           "https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x$GIT_RELEASE_KEY_FPR"; } \
     || ! gpg --batch --dearmor -o "$key.gpg" "$key.asc" >/dev/null 2>&1; then
    warn "  could not fetch the git release key $GIT_RELEASE_KEY_FPR -- not building unverified source."
    return 1
  fi
  vstatus="$(gpgv --keyring "$key.gpg" --status-fd 1 "$tarball.sign" "$tarball" 2>/dev/null || true)"
  # VALIDSIG names the signing subkey first and its primary key last.
  if ! printf '%s\n' "$vstatus" \
       | awk -v fpr="$GIT_RELEASE_KEY_FPR" '$2 == "VALIDSIG" && $NF == fpr { ok = 1 } END { exit !ok }'; then
    warn "  git-$ver.tar is not signed by the git release key $GIT_RELEASE_KEY_FPR -- not building it."
    return 1
  fi
  log "  GPG signature verified (git release key $GIT_RELEASE_KEY_FPR)"

  tar -xf "$tarball" -C "$work" || return 1
  log "  building git $ver"
  # Tcl/Tk is not installed, and gitk/git-gui are not what the floor asks about.
  # PCRE2 keeps `git grep -P` and --perl-regexp working, as they do with the
  # Debian git this build shadows.
  local -a knobs=(prefix=/usr/local NO_TCLTK=1 USE_LIBPCRE2=YesPlease)
  if ! make -C "$work/git-$ver" -j"$(nproc)" "${knobs[@]}" all > "$work/git-build.log" 2>&1 \
     || ! sudo make -C "$work/git-$ver" "${knobs[@]}" install >> "$work/git-build.log" 2>&1; then
    tail -n 40 "$work/git-build.log" >&2
    return 1
  fi
  log "  installed git $ver under /usr/local"
  # git-subtree lives in contrib, outside `make install`, but the Debian git
  # package ships it. Core git already meets the floor, so a failure here is a
  # warning rather than a failed build.
  if make -C "$work/git-$ver/contrib/subtree" "${knobs[@]}" >> "$work/git-build.log" 2>&1 \
     && sudo make -C "$work/git-$ver/contrib/subtree" "${knobs[@]}" install >> "$work/git-build.log" 2>&1; then
    log "  installed git-subtree beside it"
  else
    warn "  git-subtree could not be installed under /usr/local, so 'git subtree' is unavailable from this build."
  fi
}

# Succeeds when the git on PATH is the /usr/local build and lacks what the Debian git it
# shadows provides: PCRE2 (`git grep -P`) or git-subtree. The probe needs a Perl-only pattern
# and a real file, because git compiles nothing for a missing file. The argument is the
# build's path, so tests can point it elsewhere.
local_git_incomplete() {
  local git_bin="${1:-/usr/local/bin/git}" probe rc=0
  [[ "$(command -v git || true)" == "$git_bin" ]] || return 1
  [[ -x "$("$git_bin" --exec-path 2>/dev/null || true)/git-subtree" ]] || return 0
  probe="$(mktemp -d)" || return 1
  printf 'probe\n' > "$probe/probe"
  "$git_bin" -C "$probe" grep --no-index -P 'p(?=robe)' -- probe >/dev/null 2>&1 || rc=$?
  rm -rf "$probe"
  (( rc != 0 ))
}

bring_amd_ryzen_ai_platform_to_floors() {
  is_amd_ryzen_ai_platform || return 0
  local codename="${DEBIAN_CODENAME:-trixie}"
  local suite="${codename}-backports" work floor have
  log "AMD Ryzen AI Developer Platform detected (Debian $codename base) -- raising the tools its archive keeps below the floors"
  if enable_debian_backports "$suite"; then
    raise_tool_from_suite "$suite" curl curl
    # qemu-system moves with qemu-utils so the emulator and the image tool stay
    # on one release.
    raise_tool_from_suite "$suite" qemu-img qemu-utils "$qemu_kvm_pkg"
  else
    note_issue "Could not enable $suite as an apt source, so curl and qemu-img stay at the versions the $codename archive ships."
    suite=""
  fi
  # Said here once, because floor_check_tools leaves python3 out of the closing
  # check on this platform; the region comment above has the reasons.
  floor="$(requirement_floor python3 || true)"
  have="$(tool_version python3 || true)"
  if [[ -n "$floor" && -n "$have" ]] && ! version_ge "$have" "$floor"; then
    log "  python3 $have stays below the $floor floor: virt-install, virt-manager and the platform's own tools need its interpreter"
  fi
  # An incomplete /usr/local git is rebuilt only at exactly the floor, the one
  # version this region builds. A newer one is someone else's build, and
  # rebuilding it at the floor would downgrade it; an unreadable floor leaves
  # nothing to build.
  local build_git=0
  floor="$(requirement_floor git || true)"
  if tool_below_floor git; then
    build_git=1
  elif [[ -n "$floor" ]] && local_git_incomplete; then
    have="$(tool_version git || true)"
    if [[ "$have" == "$floor" ]]; then
      log "  the /usr/local git lacks PCRE2 or git-subtree, which the Debian git it shadows has -- rebuilding it"
      build_git=1
    else
      warn "  /usr/local/bin/git $have lacks PCRE2 or git-subtree but is newer than the $floor floor this installer builds, so it is left as it is."
    fi
  fi
  if (( build_git )); then
    if ! work="$(mktemp -d)"; then
      note_issue "Could not create a work directory, so git was not raised to its floor."
      return 0
    fi
    yuruna_track_tmp "$work"
    if build_git_from_source "$floor" "$work" "$suite"; then
      hash -r
      confirm_tool_floor git
    else
      note_issue "Building git $floor from its release tarball failed -- see the output above."
    fi
    # sudo: the git install step runs make as root inside the work tree.
    sudo rm -rf "$work" || true
  fi
}
bring_amd_ryzen_ai_platform_to_floors

# --- REGION: Seed test.config.yml from template
TEST_DIR="$YURUNA_DIR/test"
if [[ ! -f "$TEST_DIR/test.config.yml" && -f "$TEST_DIR/test.config.yml.template" ]]; then
  log "Creating test/test.config.yml from template (review before running tests)"
  cp "$TEST_DIR/test.config.yml.template" "$TEST_DIR/test.config.yml"
fi

# --- REGION: https://yuruna.link/4220a755-0027
# Substitute the runner account and validate the sudoers rule before installing it.
install_bridge_pin_sudoers() {
  local src="$YURUNA_DIR/host/ubuntu.kvm/yuruna-bridge-pin.sudoers"
  local dst="/etc/sudoers.d/yuruna-bridge-pin"
  if [[ ! -f "$src" ]]; then
    warn "  $src not found -- skipping the bridge-pin sudoers grant."
    return
  fi
  local tmp
  tmp="$(mktemp)"
  yuruna_track_tmp "$tmp"
  # awk, not sed: a username is substituted into a security-relevant file, and
  # awk compares the field literally where a sed pattern would interpret it.
  awk -v u="$USER" '$1 == "ytest" { $1 = u } { print }' "$src" > "$tmp"
  # Validate BEFORE installing. A malformed drop-in breaks sudo for every
  # command on the host, including the ones needed to remove it.
  if sudo visudo -cf "$tmp" >/dev/null 2>&1; then
    sudo install -m 0440 -o root -g root "$tmp" "$dst"
    log "  installed $dst (lets the health check pin the bridge DHCP identity)"
  else
    warn "  generated sudoers rule failed 'visudo -c'; NOT installed. Check $src."
  fi
  rm -f "$tmp"
}
log "Installing the bridge DHCP-identity sudoers grant"
install_bridge_pin_sudoers

# --- REGION: Baseline reset: remove test-* VMs
REMOVE_TEST_VMS="$YURUNA_DIR/test/Remove-TestVMFiles.ps1"
if [[ -f "$REMOVE_TEST_VMS" ]]; then
  log "Removing test-* VMs left over from previous cycles (cache VM preserved)"
  libvirt_members="$(getent group libvirt 2>/dev/null | awk -F: '{print $4}')"
  if command -v sg >/dev/null 2>&1 && \
     [[ ",${libvirt_members}," == *",${USER},"* ]]; then
    sg libvirt -c "pwsh -NoLogo -NoProfile -File '$REMOVE_TEST_VMS'" || \
      warn "Remove-TestVMFiles.ps1 (via sg libvirt) exited non-zero; continuing install."
  else
    pwsh -NoLogo -NoProfile -File "$REMOVE_TEST_VMS" || \
      warn "Remove-TestVMFiles.ps1 exited non-zero; continuing install."
  fi
else
  warn "Remove-TestVMFiles.ps1 not found at $REMOVE_TEST_VMS -- skipping test-VM cleanup."
fi

# --- REGION: Test modules
# Pester 6 and PSScriptAnalyzer. The version policy lives in tools/Install-TestModule.ps1,
# shared by the installer of every host platform, so it runs once the checkout exists.
# Each MODULE-ISSUE line it prints reaches the closing summary; a missing test module
# does not stop the install.
install_test_modules() {
  local script="$YURUNA_DIR/tools/Install-TestModule.ps1" out rc=0 line
  if [[ ! -f "$script" ]]; then
    warn "tools/Install-TestModule.ps1 not found under $YURUNA_DIR -- skipping the test modules."
    return 0
  fi
  log "Installing the PowerShell modules the tests need (Pester 6, PSScriptAnalyzer)"
  out="$(pwsh -NoLogo -NoProfile -File "$script" 2>&1)" || rc=$?
  while IFS= read -r line; do
    case "$line" in
      'MODULE-ISSUE: '*) note_issue "${line#MODULE-ISSUE: }" ;;
      *) if [[ -n "$line" ]]; then printf '%s\n' "$line"; fi ;;
    esac
  done <<< "$out"
  if (( rc != 0 )); then
    note_issue "tools/Install-TestModule.ps1 could not run (exit $rc), so Pester 6 and PSScriptAnalyzer may be missing -- see the output above."
  fi
}
install_test_modules

# --- REGION: Host configuration
# See https://yuruna.link/429fb30b-0015
# Ubuntu leaves host settings to the operator, so this names the command to run.
HOST_SETUP="$YURUNA_DIR/host/ubuntu.kvm/Enable-TestAutomation.ps1"
log ""
log "Host configuration (test-host setup) is NOT auto-applied."
log "To enable this machine as a test host, run:"
log "    pwsh '$HOST_SETUP'"

# --- REGION: GitHub CLI
# See https://yuruna.link/429fb30b-0039
install_gh_apt() {
  log "Installing GitHub CLI (gh) via cli.github.com apt repo"
  sudo install -d -m 0755 /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/githubcli-archive-keyring.gpg ]]; then
    # Fetch to a temp file and pin the fingerprints BEFORE installing the
    # keyring as the apt anchor. The keyring ships both the current and the
    # legacy (expiring) GitHub CLI keys during the rotation window; require the
    # current one present and reject any key outside the pinned allow-set.
    local gh_tmp; gh_tmp="$(mktemp -d)"
    yuruna_track_tmp "$gh_tmp"
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o "$gh_tmp/gh.gpg"
    verify_key_fingerprints "$gh_tmp/gh.gpg" "$GH_APT_KEY_FPR_NEW" "$GH_APT_KEY_FPR_OLD"
    sudo install -m 0644 "$gh_tmp/gh.gpg" /etc/apt/keyrings/githubcli-archive-keyring.gpg
    rm -rf "$gh_tmp"
  fi
  if [[ ! -f /etc/apt/sources.list.d/github-cli.list ]]; then
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  fi
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y gh
}
if ! command -v gh >/dev/null 2>&1; then
  install_gh_apt
fi
command -v gh >/dev/null 2>&1 || die "gh not found after install."

# --- REGION: Preflight: final host readiness
# See https://yuruna.link/429fb30b-0038
log "Running final preflight checks"

PREFLIGHT_ERRORS=()
PREFLIGHT_WARNINGS=()

if command -v kvm-ok >/dev/null 2>&1; then
  if ! sudo kvm-ok >/dev/null 2>&1; then
    PREFLIGHT_ERRORS+=("KVM hardware acceleration not available. Run 'sudo kvm-ok' for the diagnostic. Likely cause: VT-x/AMD-V disabled in firmware, or nested virtualization not enabled in the L1 hypervisor.")
  fi
fi

if [[ ! -c /dev/kvm ]]; then
  PREFLIGHT_ERRORS+=("/dev/kvm character device missing -- kvm.ko not loaded. Try: 'sudo modprobe kvm_intel' (Intel) or 'sudo modprobe kvm_amd' (AMD), then re-run.")
fi

for grp in libvirt kvm; do
  group_members="$(getent group "$grp" 2>/dev/null | awk -F: '{print $4}')"
  if [[ ",${group_members}," != *",${USER},"* ]]; then
    PREFLIGHT_ERRORS+=("$USER is not a member of '$grp' in /etc/group -- usermod -aG must have failed earlier. Run: 'sudo usermod -aG $grp $USER' manually.")
  fi
done

for svc in libvirtd virtlogd; do
  if ! systemctl is-active --quiet "$svc"; then
    PREFLIGHT_ERRORS+=("systemd service '$svc' is not active. 'sudo systemctl status $svc' for details.")
  fi
done

if ! getent passwd libvirt-qemu >/dev/null 2>&1; then
  PREFLIGHT_ERRORS+=("System user 'libvirt-qemu' missing -- libvirt-daemon-system postinst did not run. Try 'sudo dpkg-reconfigure libvirt-daemon-system'.")
fi

if ! sudo virsh net-list --name 2>/dev/null | grep -qx default; then
  PREFLIGHT_ERRORS+=("libvirt 'default' network is not running. 'sudo virsh net-start default' to retry.")
fi
if ! sudo virsh net-list --autostart --name 2>/dev/null | grep -qx default; then
  PREFLIGHT_ERRORS+=("libvirt 'default' network is not set to autostart. 'sudo virsh net-autostart default' to fix.")
fi

if getent passwd libvirt-qemu >/dev/null 2>&1; then
  TRAVERSE_PROBE=$(mktemp -p "$HOME" .yuruna-acl-probe.XXXXXX 2>/dev/null || true)
  if [[ -n "$TRAVERSE_PROBE" && -f "$TRAVERSE_PROBE" ]]; then
    chmod 644 "$TRAVERSE_PROBE"
    if ! sudo -u libvirt-qemu test -r "$TRAVERSE_PROBE"; then
      PREFLIGHT_ERRORS+=("libvirt-qemu cannot read '$TRAVERSE_PROBE' through \$HOME -- traverse ACL did not take. Try: 'sudo setfacl -m u:libvirt-qemu:--x $HOME' or fall back to 'chmod o+x $HOME'. Without this, virt-install errors with 'Cannot access storage file ... Permission denied'.")
    fi
    rm -f "$TRAVERSE_PROBE"
  else
    PREFLIGHT_WARNINGS+=("Could not create traverse-ACL probe under $HOME (skipping that check).")
  fi
fi

if ! command -v genisoimage >/dev/null 2>&1 && ! command -v cloud-localds >/dev/null 2>&1; then
  PREFLIGHT_ERRORS+=("Neither 'genisoimage' nor 'cloud-localds' on PATH -- cloud-init seed ISO build will fail.")
fi

if ! command -v pwsh >/dev/null 2>&1; then
  PREFLIGHT_ERRORS+=("pwsh missing from PATH after install.")
fi

if ! command -v virt-install >/dev/null 2>&1; then
  PREFLIGHT_ERRORS+=("'virt-install' not on PATH -- the 'virtinst' apt package did not install.")
fi

# Present is not the same as runnable, and a virt-install that cannot start
# lists no OS variants, so it is checked first rather than reported as missing
# osinfo data. Appends to PREFLIGHT_ERRORS / PREFLIGHT_WARNINGS; a virt-install
# that is absent is reported above.
check_virt_install_ready() {
  local why
  command -v virt-install >/dev/null 2>&1 || return 0
  if ! why="$(virt_install_runs)"; then
    PREFLIGHT_ERRORS+=("'virt-install' is on PATH but does not run: $why. It starts through the python3 found on PATH (now $(command -v python3 || echo 'none')), which must be /usr/bin/python3 or carry its gi and libvirt modules.")
    return 0
  fi
  if ! osinfo_has_variant 'linux2022'; then
    PREFLIGHT_WARNINGS+=("osinfo-db is missing variant 'linux2022' -- per-guest scripts may fail to find any usable variant.")
  fi
  if ! osinfo_has_variant 'ubuntu24.04' && ! osinfo_has_variant 'ubuntu22.04'; then
    PREFLIGHT_WARNINGS+=("osinfo-db has neither 'ubuntu24.04' nor 'ubuntu22.04' -- guest.ubuntu.server.24 New-VM.ps1 will fall back to the 'linux2022' generic profile (still boots, just less hypervisor tuning). Update the osinfo-db package on the host to silence this.")
  fi
}
check_virt_install_ready

case "$ARCH" in
  x86_64)
    [[ -r /usr/share/OVMF/OVMF_CODE.fd || -r /usr/share/OVMF/OVMF_CODE_4M.fd ]] || \
      PREFLIGHT_ERRORS+=("OVMF firmware images missing under /usr/share/OVMF/ -- Windows 11 guest cannot boot UEFI. Verify 'ovmf' apt package installed.")
    ;;
  aarch64)
    [[ -r /usr/share/AAVMF/AAVMF_CODE.fd ]] || \
      PREFLIGHT_ERRORS+=("AAVMF firmware missing under /usr/share/AAVMF/ -- aarch64 guests cannot boot UEFI. Verify 'qemu-efi-aarch64' apt package installed.")
    ;;
esac

for bin in swtpm swtpm_setup; do
  command -v "$bin" >/dev/null 2>&1 || \
    PREFLIGHT_ERRORS+=("'$bin' missing -- Windows 11 guest cannot satisfy TPM 2.0 requirement. Verify 'swtpm' / 'swtpm-tools' apt packages installed.")
done

if ! command -v gh >/dev/null 2>&1; then
  PREFLIGHT_ERRORS+=("'gh' missing from PATH after install -- check 'apt-cache policy gh' for the cli.github.com source, then re-run.")
fi

if (( ${#PREFLIGHT_WARNINGS[@]} > 0 )); then
  printf '\n'
  for w in "${PREFLIGHT_WARNINGS[@]}"; do warn "$w"; done
fi

if (( ${#PREFLIGHT_ERRORS[@]} > 0 )); then
  printf '\n'
  printf '\033[1;31mXX \033[0m %s\n' "Yuruna preflight failed -- ${#PREFLIGHT_ERRORS[@]} requirement(s) not met:" >&2
  for e in "${PREFLIGHT_ERRORS[@]}"; do
    printf '   - %s\n' "$e" >&2
  done
  printf '\n' >&2
  printf 'Resolve the items above and re-run this installer. The host is NOT\n' >&2
  printf 'ready for Start-TestRunner.ps1.\n' >&2
  exit 2
fi

# --- REGION: Done summary
NEEDS_RELOG_HINT=0
ACTIVE_GROUPS=$(group_names)
for grp in libvirt kvm; do
  group_members="$(getent group "$grp" 2>/dev/null | awk -F: '{print $4}')"
  if [[ ",${group_members}," == *",${USER},"* ]] && \
     ! echo "$ACTIVE_GROUPS" | grep -qx "$grp"; then
    NEEDS_RELOG_HINT=1
  fi
done

cat <<EOF

$(log "Yuruna is ready -- all preflight checks passed.")

Next steps (in order):
EOF
if (( NEEDS_RELOG_HINT == 1 )); then
  cat <<EOF

  0. THIS shell pre-dates the libvirt/kvm group membership added during
     install -- refresh it before running pwsh:
       Option A (recommended): log out and log back in
       Option B (one-off):     newgrp libvirt && newgrp kvm
     (The install itself is complete. This step only affects YOUR next
     interactive pwsh call.)
EOF
fi
cat <<EOF

  1. Review and edit the test config:
       \$EDITOR $TEST_DIR/test.config.yml

  2. (Optional) Enable this machine as a test host -- disables display sleep
     and tunes the libvirt image pool path. NOT run automatically; opt in
     only if this Ubuntu host will run Start-TestRunner:
       pwsh $YURUNA_DIR/host/ubuntu.kvm/Enable-TestAutomation.ps1

  3. Run the test runner:
       cd $TEST_DIR && pwsh ./Start-TestRunner.ps1

  4. (Optional, one-time) Authenticate the GitHub CLI so 'gh' can act on
     your behalf -- the installer installs the binary, but authentication
     requires an interactive web-or-token flow you have to drive:
       gh auth login

Re-running this installer is safe; it will refresh apt packages and
fast-forward the Yuruna checkout when possible.
EOF

# --- REGION: Version floor check
# See https://yuruna.link/429fb30b-0002 and https://yuruna.link/429fb30b-0035
# Check managed tools only; the AMD platform keeps its ABI-bound system Python.
# Report shortfalls without failing the completed installation.
floor_check_tools() {
  local tools="PowerShell,git,qemu-img,wget,tesseract,curl,python3"
  if is_amd_ryzen_ai_platform; then tools="${tools%,python3}"; fi
  printf '%s\n' "$tools"
}
# With -WarnOnly the check exits 0 whenever it ran, so any other status means it
# could not run -- a missing powershell-yaml module is the usual cause -- and its
# silence then says nothing about the versions. Its own output is printed whole,
# with NO_COLOR keeping pwsh's error text free of escape codes, because a last
# line cut from a wrapped error names nothing.
report_floor_check() {
  local out rc=0 line
  out="$(NO_COLOR=1 pwsh -NoProfile -File "$YURUNA_DIR/automation/Test-Requirement.ps1" \
           -Tool "$(floor_check_tools)" -WarnOnly 2>&1)" || rc=$?
  if (( rc != 0 )); then
    printf '%s\n' "$out" >&2
    note_issue "The version floors could not be checked: automation/Test-Requirement.ps1 exited $rc, with its output printed above. A missing powershell-yaml module is the usual cause; install it with: pwsh -Command 'Install-Module powershell-yaml -RequiredVersion $POWERSHELL_YAML_VERSION -Scope CurrentUser', then re-run this installer."
    return 0
  fi
  while IFS= read -r line; do
    if [[ -n "$line" ]]; then note_issue "$line"; fi
  done <<< "$(printf '%s\n' "$out" | sed -n 's/^REQUIREMENT-ISSUE: //p')"
}
if command -v pwsh >/dev/null 2>&1 && [[ -f "$YURUNA_DIR/automation/Test-Requirement.ps1" ]]; then
  log "Checking installed versions against the required floors"
  report_floor_check
fi

# --- REGION: Newer versions available
# Advisory, after the floor check: each tool this installer manages that its own
# source offers newer than what is installed, as `tool: installed -> available
# (source; why this run left it)`. A source that does not answer is reported as
# unknown, never as current, and nothing here fails the run. gh and the AMD
# platform's git are installed only when absent and at the floor, so they are
# reported, not upgraded.
# See https://yuruna.link/4213a0b3-01b1
apt_newer_lines() {
  local pkgs=("${APT_PACKAGES[@]}" virt-manager gh) policy pkg installed candidate why
  if powershell_deb_installed && ! printf '%s\n' "${pkgs[@]}" | grep -x powershell >/dev/null; then
    pkgs+=(powershell)
  fi
  if ! policy="$(LC_ALL=C apt-cache policy "${pkgs[@]}" 2>/dev/null)"; then
    printf 'apt packages: unknown (apt-cache policy did not answer)\n'
    return 0
  fi
  while read -r pkg installed candidate offered; do
    if [[ -z "$installed" || "$installed" == "(none)" ]]; then continue; fi
    # An installed package whose only origin is dpkg's own record has itself as apt's
    # candidate, so apt cannot say whether anything newer exists. PowerShell is left to
    # pwsh_newer_line, which asks GitHub.
    if [[ "$offered" == none ]]; then
      if [[ "$pkg" != powershell ]]; then
        printf '%s: %s -> unknown (no configured apt source offers %s)\n' "$pkg" "$installed" "$pkg"
      fi
      continue
    fi
    if [[ -z "$candidate" || "$candidate" == "(none)" ]]; then continue; fi
    if ! dpkg --compare-versions "$installed" lt "$candidate"; then continue; fi
    if apt_package_held "$pkg"; then why="held by apt-mark hold"
    elif [[ "$pkg" == gh ]]; then why="this installer installs gh only when it is absent"
    elif [[ "$pkg" == powershell && "${PWSH_APT_UNINSTALLABLE:-0}" -eq 1 ]]; then
      why="apt cannot install that candidate here, so this run left it out of the package list"
    else why="apt did not move it in this run"
    fi
    printf '%s: %s -> %s (apt; %s)\n' "$pkg" "$installed" "$candidate" "$why"
  done < <(printf '%s\n' "$policy" | awk '
    function flush() {
      if (pkg != "") print pkg, (installed == "" ? "(none)" : installed), (candidate == "" ? "(none)" : candidate), (status && !offered ? "none" : "some")
    }
    /^[^ ]/ { flush(); pkg = $1; sub(/:$/, "", pkg); installed = ""; candidate = ""; table = status = offered = 0; next }
    $1 == "Installed:" { installed = $2; next }
    $1 == "Candidate:" { candidate = $2; next }
    $1 == "Version" && $2 == "table:" { table = 1; next }
    # An origin line is a priority followed by where that version comes from.
    table && $1 ~ /^-?[0-9]+$/ && $2 !~ /^-?[0-9]+$/ {
      if ($2 ~ /\/var\/lib\/dpkg\/status$/) status = 1; else offered = 1
    }
    END { flush() }')
  return 0
}
# PowerShell is compared with GitHub's newest release whatever its source: a package no
# configured source carries has itself as apt's candidate, so the apt lines alone would
# call it current.
pwsh_newer_line() {
  local source have latest snaps why floor
  source="$(pwsh_source)"
  have="$(pwsh_version || true)"
  case "$source" in
    none) return 0 ;;
    snap)
      if ! snaps="$(snap refresh --list 2>/dev/null)"; then
        printf 'PowerShell: %s -> unknown (snapd did not list pending refreshes)\n' "${have:-unreadable}"
        return 0
      fi
      latest="$(printf '%s\n' "$snaps" | awk '$1 == "powershell" { print $2; exit }')"
      if [[ -n "$latest" ]]; then
        printf 'PowerShell: %s -> %s (snap; snapd has not refreshed it yet)\n' "${have:-unreadable}" "$latest"
      fi
      return 0
      ;;
  esac
  if ! latest="$(pwsh_latest_release)"; then
    printf 'PowerShell: %s -> unknown (GitHub did not name the newest release%s)\n' "${have:-unreadable}" "${PWSH_UPGRADE_WHY:+; $PWSH_UPGRADE_WHY}"
    return 0
  fi
  if [[ -n "$have" ]] && version_ge "$have" "$latest"; then
    # GitHub can mark an older line as the latest. A copy below the floor is then still
    # behind the floor's own release, which the floor check reports, so it is not current.
    floor="$(requirement_floor PowerShell || true)"
    if [[ -n "$floor" ]] && ! version_ge "$have" "$floor"; then
      printf "PowerShell: %s -> unknown (GitHub's newest release %s is below the %s floor)\n" "$have" "$latest" "$floor"
    fi
    return 0
  fi
  if [[ "$source" == apt ]]; then
    if apt_package_held powershell; then why="held by apt-mark hold; 'sudo apt-mark unhold powershell' releases it"
    elif [[ -n "${PWSH_UPGRADE_WHY:-}" ]]; then why="$PWSH_UPGRADE_WHY"
    elif [[ -n "${PWSH_VERSION:-}" ]]; then why="PWSH_VERSION is $PWSH_VERSION"
    else why="the package upgrade did not complete"
    fi
    printf "PowerShell: %s -> %s (Microsoft's package; %s)\n" "${have:-unreadable}" "$latest" "$why"
  elif [[ "$source" == tarball ]]; then
    if [[ -n "${PWSH_VERSION:-}" ]]; then why="PWSH_VERSION is $PWSH_VERSION"
    else why="the tarball upgrade did not complete"
    fi
    printf 'PowerShell: %s -> %s (release tarball; %s)\n' "${have:-unreadable}" "$latest" "$why"
  else
    printf 'PowerShell: %s -> %s (GitHub release; %s comes from a source this installer does not manage)\n' \
      "${have:-unreadable}" "$latest" "$(command -v pwsh)"
  fi
  return 0
}
module_newer_lines() {
  local listed name have pin
  if ! listed="$(pwsh -NoProfile -Command 'foreach ($n in "powershell-yaml", "PSScriptAnalyzer") { $m = Get-Module -ListAvailable -Name $n -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1; "$n $(if ($m) { $m.Version })" }' 2>/dev/null)"; then
    printf 'PowerShell modules: unknown (pwsh could not list them)\n'
    return 0
  fi
  while read -r name have; do
    case "$name" in
      powershell-yaml)  pin="$POWERSHELL_YAML_VERSION" ;;
      PSScriptAnalyzer) pin="$(sed -n "s/^[[:space:]]*'PSScriptAnalyzer'[[:space:]]*=[[:space:]]*@{ Version = '\([^']*\)'.*/\1/p" \
                          "$YURUNA_DIR/tools/Install-TestModule.ps1" 2>/dev/null | head -1)" ;;
      *) continue ;;
    esac
    if [[ -z "$have" || -z "$pin" ]] || version_ge "$have" "$pin"; then continue; fi
    printf '%s: %s -> %s (pinned in the PowerShell Gallery; the install of the pin did not complete)\n' "$name" "$have" "$pin"
  done <<< "$listed"
  return 0
}
amd_git_newer_line() {
  local have listing latest
  if ! is_amd_ryzen_ai_platform; then return 0; fi
  have="$(tool_version git || true)"
  if ! listing="$(curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 15 --max-time 60 \
                    "https://www.kernel.org/pub/software/scm/git/" 2>/dev/null)"; then
    printf 'git: %s -> unknown (kernel.org did not answer)\n' "${have:-unreadable}"
    return 0
  fi
  latest="$(printf '%s\n' "$listing" | grep -oE 'git-[0-9]+\.[0-9]+\.[0-9]+\.tar\.xz' \
    | sed -E 's/^git-//; s/\.tar\.xz$//' | sort -u -t. -k1,1n -k2,2n -k3,3n | tail -1 || true)"
  if [[ -z "$latest" ]]; then
    printf 'git: %s -> unknown (kernel.org listed no release)\n' "${have:-unreadable}"
    return 0
  fi
  if [[ -n "$have" ]] && version_ge "$have" "$latest"; then return 0; fi
  printf 'git: %s -> %s (kernel.org; this installer builds git at its %s floor)\n' \
    "${have:-unreadable}" "$latest" "$(requirement_floor git || printf 'unreadable')"
  return 0
}
report_newer_versions() {
  local lines line
  lines="$(pwsh_newer_line; apt_newer_lines; module_newer_lines; amd_git_newer_line)"
  log "Newer versions available"
  if [[ -z "$lines" ]]; then
    log "  none: every tool this installer manages is at the newest version its source offers"
    return 0
  fi
  while IFS= read -r line; do
    if [[ -n "$line" ]]; then log "  $line"; fi
  done <<< "$lines"
  return 0
}
if command -v pwsh >/dev/null 2>&1; then
  report_newer_versions || warn "The check for newer versions did not finish; it is advisory and the install is unaffected."
fi

# --- REGION: Backup notice
if [[ -n "$YURUNA_BACKUP_CREATED" ]]; then
  warn ""
  warn "========"
  warn "IMPORTANT: a backup of your previous Yuruna checkout was created"
  warn "  because 'git pull --ff-only' could not advance the local repo."
  warn ""
  warn "  Backup location: $YURUNA_BACKUP_CREATED"
  warn ""
  warn "Review the backup for any local edits you want to preserve."
  warn "When you no longer need it, delete it manually:"
  warn "  rm -rf '$YURUNA_BACKUP_CREATED'"
  warn "========"
fi

# --- REGION: Installation summary
# The last thing printed. Everything above scrolls; this does not.
if [[ ${#YURUNA_ISSUES[@]} -gt 0 ]]; then
  warn ""
  warn "========"
  warn "INSTALL FINISHED WITH ${#YURUNA_ISSUES[@]} ISSUE(S)"
  warn ""
  for issue in "${YURUNA_ISSUES[@]}"; do
    warn "  - $issue"
  done
  warn ""
  warn "The install completed and the machine is usable. Each line above is"
  warn "something that did not happen as intended -- re-running this installer"
  warn "is safe and retries every one of them."
  warn "========"
else
  log ""
  log "Install finished with no issues."
fi
