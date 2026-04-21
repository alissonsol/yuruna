<#PSScriptInfo
.VERSION 0.1
.GUID 42b5c6d7-e8f9-4a01-b234-5c6d7e8f9a01
.AUTHOR Alisson Sol
.COPYRIGHT (c) 2026 Alisson Sol et al.
.TAGS
.LICENSEURI http://www.yuruna.com
.PROJECTURI http://www.yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

param(
    [string]$VMName = "ubuntu-desktop01",
    # Forwarded by the test harness (Invoke-TestRunner → Invoke-NewVM) so
    # every guest in a run agrees on a single caching proxy URL. When bound
    # (even to ""), the local subnet probe is skipped and this value is
    # used verbatim: "" means "no cache, go direct"; a URL means "use this".
    # When NOT bound (standalone / manual run), fall back to the probe below.
    [string]$CachingProxyUrl
)

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Output "Invalid VMName '$VMName'. Only alphanumeric characters, dots, hyphens, and underscores are allowed."
    exit 1
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$MachineName = $(hostname -s)
$VdeDir = "$HOME/Desktop/Yuruna.VDE/$MachineName.nosync"
New-Item -ItemType Directory -Force -Path $VdeDir | Out-Null
$UtmDir = "$VdeDir/$VMName.utm"
$DataDir = "$UtmDir/Data"
$downloadDir = "$HOME/virtual/ubuntu.env"

# ===== Environment checks for nested virtualization (Docker Desktop / KVM) =====

# Check macOS version (requires macOS 15 Sequoia or later)
$macosVersion = & sw_vers -productVersion 2>$null
$macosMajor = [int]($macosVersion -split '\.')[0]
if ($macosMajor -lt 15) {
    Write-Error "macOS 15 Sequoia or later is required for nested virtualization (found macOS $macosVersion)."
    Write-Error "Docker Desktop inside the VM requires nested virtualization to expose /dev/kvm."
    exit 1
}
Write-Output "macOS version: $macosVersion (OK)"

# Check Apple Silicon chip (requires M3 or later for nested virtualization)
$chipName = (& system_profiler SPHardwareDataType 2>$null | Select-String "Chip" | ForEach-Object { $_ -replace '.*Chip:\s*', '' }).Trim()
if (-not $chipName) {
    Write-Error "Could not detect Apple Silicon chip. This script requires Apple Silicon (M3 or later)."
    exit 1
}
if ($chipName -notmatch 'Apple M([3-9]|[1-9]\d)') {
    Write-Error "Apple Silicon M3 or later is required for nested virtualization (found: $chipName)."
    Write-Error "M1 and M2 chips do not support nested virtualization. Docker Desktop will not work inside the VM."
    exit 1
}
Write-Output "Chip: $chipName (OK)"

# Check UTM version (requires v4.6.0 or later)
$utmPlist = "/Applications/UTM.app/Contents/Info.plist"
if (-not (Test-Path $utmPlist)) {
    Write-Error "UTM not found at /Applications/UTM.app. Install with: brew install --cask utm"
    exit 1
}
$utmVersion = (& /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $utmPlist 2>$null)
if ($utmVersion) {
    $utmParts = $utmVersion -split '\.'
    $utmMajor = [int]$utmParts[0]
    $utmMinor = $utmParts.Count -gt 1 ? [int]$utmParts[1] : 0
    if ($utmMajor -lt 4 -or ($utmMajor -eq 4 -and $utmMinor -lt 6)) {
        Write-Error "UTM v4.6.0 or later is required for nested virtualization (found v$utmVersion)."
        Write-Error "Update with: brew upgrade --cask utm"
        exit 1
    }
    Write-Output "UTM version: $utmVersion (OK)"
} else {
    Write-Warning "Could not determine UTM version. Ensure UTM v4.6.0 or later is installed."
}

Write-Output "All nested virtualization requirements met."
Write-Output ""

# === Seek the base image ===
$baseImageName = "host.macos.utm.guest.ubuntu.desktop"
$baseImageFile = Join-Path $downloadDir "$baseImageName.iso"
if (-not (Test-Path $baseImageFile)) {
    Write-Error "Base image not found at '$baseImageFile'. Run Get-Image.ps1 first."
    exit 1
}

# Find OpenSSL with SHA-512 passwd support (for autoinstall password hash)
$PasswordHash = $null
foreach ($path in @("/opt/homebrew/opt/openssl@3/bin/openssl", "/opt/homebrew/opt/openssl/bin/openssl", "/usr/local/opt/openssl@3/bin/openssl", "/usr/local/opt/openssl/bin/openssl", "openssl")) {
    try {
        $result = (& $path passwd -6 "password" 2>$null)
        if ($LASTEXITCODE -eq 0 -and $result) {
            $PasswordHash = $result.Trim()
            break
        }
    } catch {
        Write-Warning "Not found: $path"
    }
}
if (-not $PasswordHash) {
    Write-Error "OpenSSL with SHA-512 password support is required. Install with: brew install openssl"
    exit 1
}

Write-Output "Creating VM '$VMName' using image: $baseImageFile"
# Provenance side-channel for operators reading the transcript. Emits
# "Provenance: <url>" when the sidecar is healthy; warns otherwise.
Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'test/modules/Test.Provenance.psm1') -Force
Write-BaseImageProvenance -BaseImagePath $baseImageFile

# === Create copies and files for VM ===

# Load shared helpers (retry-on-EACCES bundle removal — handles the race
# where UTM.app / QEMUHelper.xpc still holds file handles on disk.img
# immediately after `utmctl delete`).
Import-Module (Join-Path (Split-Path -Parent $ScriptDir) "VM.common.psm1") -Force

# Create UTM bundle structure
if (-not (Remove-UtmBundleWithRetry -Path $UtmDir)) {
    Write-Error "Could not remove existing UTM bundle at '$UtmDir' after retries. Aborting."
    exit 1
}
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

# Create EFI variable store (required by Apple Virtualization UEFI boot)
$EfiVarsFile = "$DataDir/efi_vars.fd"
Write-Output "Creating EFI variable store..."
$swiftCode = @'
import Foundation
import Virtualization
let url = URL(fileURLWithPath: CommandLine.arguments[1])
do { _ = try VZEFIVariableStore(creatingVariableStoreAt: url) }
catch { fputs("Error: \(error.localizedDescription)\n", stderr); exit(1) }
'@
$swiftCode | & swift - "$EfiVarsFile"
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to create EFI variable store. Ensure Xcode command line tools are installed."
    exit 1
}
Write-Output "EFI variable store created."

# Copy base image ISO into the bundle (named after hostname)
$DestIso = "$DataDir/$VMName.iso"
Copy-Item -Path $baseImageFile -Destination $DestIso
Write-Output "Copied installer ISO as: $VMName.iso"

# Create blank disk for installation (512GB, sparse raw image for Apple Virtualization)
$DiskImage = "$DataDir/disk.img"
Write-Output "Creating 512GB disk image (raw format for Apple Virtualization)..."
& qemu-img create -f raw "$DiskImage" 512G
if ($LASTEXITCODE -ne 0) {
    Write-Error "qemu-img failed. Install QEMU tools with: brew install qemu"
    exit 1
}

# Generate autoinstall seed ISO
$SeedDir = Join-Path $downloadDir "seed_temp/$VMName"
if (Test-Path $SeedDir) { Remove-Item -Recurse -Force $SeedDir }
New-Item -ItemType Directory -Force -Path $SeedDir | Out-Null

$VmConfigDir = Join-Path $ScriptDir "vmconfig"
$UserDataTemplate = Join-Path $VmConfigDir "user-data"
$MetaDataTemplate = Join-Path $VmConfigDir "meta-data"
if (-not (Test-Path $UserDataTemplate)) {
    Write-Error "user-data template not found at '$UserDataTemplate'."
    exit 1
}

# Use .Replace() (literal) instead of -replace (regex) because the hash
# contains $ delimiters ($6$salt$hash) that regex would interpret as backreferences
# Load the SSH public key used by the test harness to drive the VM over SSH.
$TestSshModule = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))) "test/modules/Test.Ssh.psm1"
Import-Module $TestSshModule -Force
$SshAuthorizedKey = Get-YurunaSshPublicKey
if (-not $SshAuthorizedKey) { Write-Error "Get-YurunaSshPublicKey returned empty. Module path: $TestSshModule"; exit 1 }

# Detect the squid-cache forwarder and inject its URL if available.
# On macOS/VZ, guests cannot reach the squid-cache VM's IP directly --
# Apple Virtualization shared-NAT isolates guest-to-guest traffic.
# Instead, Start-CachingProxy.ps1 runs a TCP forwarder on the Mac
# HOST binding :3128, tunneling to the squid VM. Guests use the VZ
# gateway (192.168.64.1:3128), always reachable. So we only check
# the host's :3128 listener -- the cache VM's direct IP is no longer
# useful.
#
# Severity policy:
#   * Forwarder up          -> inject http://192.168.64.1:3128
#   * VM started, no :3128  -> ERROR exit 1 (Start-CachingProxy.ps1
#                              wasn't re-run; the forwarder is critical)
#   * VM not registered     -> WARNING, proceed direct (expect 429s)
if ($PSBoundParameters.ContainsKey('CachingProxyUrl')) {
    # URL forwarded by the caller (test runner). Skip the probe so the
    # runner and this script agree on a single cache URL.
    if ($CachingProxyUrl) {
        Write-Output "  caching proxy URL forwarded by caller: $CachingProxyUrl — skipping local probe."
    } else {
        Write-Output "  No proxy forwarded by caller — guest will download directly."
    }
} else {
$CachingProxyUrl = ""
# Resolve utmctl: brew cask puts it on PATH; plain UTM.app installs
# (App Store / .dmg) don't, so fall back to the bundle path.
$utmctl = (Get-Command utmctl -ErrorAction SilentlyContinue)?.Source
if (-not $utmctl -and (Test-Path "/Applications/UTM.app/Contents/MacOS/utmctl")) {
    $utmctl = "/Applications/UTM.app/Contents/MacOS/utmctl"
}

$squidStatus = $null
if ($utmctl) {
    try {
        $squidStatus = (& $utmctl status squid-cache 2>$null | Select-Object -First 1)
        if ($LASTEXITCODE -ne 0) { $squidStatus = $null }
    } catch {
        Write-Verbose "utmctl status squid-cache failed: $($_.Exception.Message)"
        $squidStatus = $null
    }
}

# Probe :3128 on loopback -- Start-CachingProxy.ps1's forwarder binds
# 0.0.0.0:3128 so 127.0.0.1 works and is portable.
$forwarderUp = $false
$tcp = New-Object System.Net.Sockets.TcpClient
try {
    $h = $tcp.BeginConnect("127.0.0.1", 3128, $null, $null)
    if ($h.AsyncWaitHandle.WaitOne(200) -and $tcp.Connected) { $forwarderUp = $true }
} catch {
    Write-Verbose "host :3128 probe failed: $($_.Exception.Message)"
} finally { $tcp.Close() }

if ($forwarderUp) {
    $CachingProxyUrl = "http://192.168.64.1:3128"
    Write-Output "  squid-cache forwarder detected on host — guest will use $CachingProxyUrl (→ squid VM)."
} elseif ($squidStatus -and $squidStatus.ToString().Trim() -match 'start') {
    # VM is up but the host-side forwarder isn't — that's a setup bug, not
    # a transient. On VZ the guest cannot reach the VM without the forwarder,
    # so failing direct would be slow and confusing. Abort loudly instead.
    $detail = @"

=========================================================================
ERROR: squid-cache VM is started but the host-side :3128 forwarder is
       not running.
=========================================================================
  utmctl status squid-cache  : $squidStatus
  probe 127.0.0.1:3128       : nothing listening on the host

Apple Virtualization shared-NAT blocks guest↔guest traffic, so guests
cannot reach the squid VM directly. Start-CachingProxy.ps1 normally
launches a host-side forwarder that bridges this gap. It appears to
have exited, been killed, or never ran after the forwarder fix landed.

Fix:
  test/Start-CachingProxy.ps1   (re-runs the forwarder; safe to re-invoke)

State to inspect:
  ~/virtual/squid-cache/forwarder.pid
  ~/virtual/squid-cache/forwarder.log
  ~/virtual/squid-cache/forwarder.stderr.log

=== Accessing the squid-cache VM for debugging ===
The REAL error, if the VM itself is unhealthy, lives in
/var/log/cloud-init-output.log INSIDE the cache VM (not in
`cloud-init status` or `systemctl status`). From the UTM window:

  sudo grep -E 'E:|429 |Hash Sum|Failed to fetch|Unable to locate|Exit code' /var/log/cloud-init-output.log | head -40
  systemctl status squid
  ss -ltn 'sport = :3128'

Common patterns:
  * '429 Too Many Requests'    -> Ubuntu's CDN rate-limited this host
                                  during the cache VM's own install.
                                  Wait 15-30 min, rebuild.
  * Nothing obvious            -> rebuild: test/Start-CachingProxy.ps1

To intentionally skip the cache for this install:
  test/Stop-CachingProxy.ps1     (guest will then WARN and download direct).
=========================================================================
"@
    $Host.UI.WriteLine([ConsoleColor]::Red, $Host.UI.RawUI.BackgroundColor, $detail)
    exit 1
} elseif ($squidStatus) {
    Write-Warning "  squid-cache VM exists (status: $squidStatus) but is not started. Guest will download directly (expect occasional 429s)."
    Write-Warning "  To enable caching: test/Start-CachingProxy.ps1"
} else {
    if (-not $utmctl) {
        Write-Warning "  utmctl not found (tried PATH and /Applications/UTM.app/Contents/MacOS/utmctl) — can't query UTM directly."
        Write-Warning "  Nothing listening on host :3128 either. Install UTM with 'brew install --cask utm' or add it to PATH."
    } else {
        Write-Warning "  No squid-cache VM registered with UTM and nothing listening on host :3128."
    }
    Write-Warning "  Guest will download directly — expect 429 rate-limit failures on linux-firmware under load."
    Write-Warning "  To enable caching, run: test/Start-CachingProxy.ps1"
}
}

# Autoinstall apt block. When a cache is reachable, inject a scoped
# `apt:` block under autoinstall so subiquity's in-installer apt-get
# (including the linux-firmware step that 429'd against
# security.ubuntu.com) routes through squid. When no cache, omit the
# block -- subiquity behaves as before.
#
# Kept in sync with guest.ubuntu.server/New-VM.ps1:
#   * primary: pin the arm64 mirror to ports.ubuntu.com. Apple Silicon
#              UTM is arm64-only; the amd64 default (archive.ubuntu.com)
#              would 404 behind the proxy.
#   * geoip: false -- skip the HTTPS geoip.ubuntu.com lookup. apt.proxy
#              exports http_proxy globally, so the lookup goes through
#              squid and can stall on CONNECT, keeping subiquity's
#              mirror-election retry loop alive ("_send_update CHANGE
#              enp0s1" console spam).
#   * preserve_sources_list: false -- curtin owns the sources, writes
#              what we specify instead of the installer's cdrom-only
#              ubuntu.sources.
#   * sources_list: legacy /etc/apt/sources.list with ports.ubuntu.com.
#              See `sources:` below for the deb822 sibling that actually
#              lands on noble 24.04 arm64.
#   * sources.yuruna-ports: curtin writes this to
#              /etc/apt/sources.list.d/yuruna-ports.list (curtin appends
#              .list; apt expects legacy one-liner format in *.list).
#              The 24.04 arm64 Desktop squashfs ships ubuntu.sources
#              with ONLY file:/cdrom, and curtin's `primary` modifymirrors
#              step can only *rewrite* an existing URI, not add one.
#              With no network URI in ubuntu.sources, curtin's mirror
#              config never reaches the target, so any non-cdrom package
#              added later 404s. A separate file under sources.list.d/
#              bypasses the no-op: apt merges ubuntu.sources (cdrom) +
#              yuruna-ports.list (network). An earlier revision used a
#              background early-commands watcher to overwrite
#              ubuntu.sources; the race lost on arm64 Server and the
#              install failed -- the watcher is gone. Curtin-owned
#              sources land synchronously and deterministically.
if ($CachingProxyUrl) {
    # `$PRIMARY / `$SECURITY / `$RELEASE are curtin template tokens —
    # the backtick escapes the `$` so the here-string doesn't expand them.
    $AptProxyBlock = @"
  apt:
    geoip: false
    primary:
      - arches: [default]
        uri: http://ports.ubuntu.com/ubuntu-ports
    proxy: $CachingProxyUrl
    preserve_sources_list: false
    sources_list: |
      deb `$PRIMARY `$RELEASE main restricted universe multiverse
      deb `$PRIMARY `$RELEASE-updates main restricted universe multiverse
      deb `$PRIMARY `$RELEASE-backports main restricted universe multiverse
      deb `$SECURITY `$RELEASE-security main restricted universe multiverse
    sources:
      yuruna-ports:
        source: |
          deb `$PRIMARY `$RELEASE main restricted universe multiverse
          deb `$PRIMARY `$RELEASE-updates main restricted universe multiverse
          deb `$PRIMARY `$RELEASE-backports main restricted universe multiverse
          deb `$SECURITY `$RELEASE-security main restricted universe multiverse
"@
} else {
    $AptProxyBlock = ""
}

# Fetch the squid-cache CA for base64 embedding in the autoinstall
# seed. Guests cannot reach the cache VM directly (VZ isolates guests),
# but this script runs on the HOST, which can. Start-CachingProxy.ps1
# persists the cache VM IP at $HOME/virtual/squid-cache/cache-ip.txt;
# if Apache serves the CA, we pull the bytes and hand them to user-data.
# Any failure leaves $CaCertBase64 empty; the guest's HTTPS proxy
# block becomes a no-op and HTTP-only caching still works.
$CaCertBase64 = ""
$cacheVmIp = $null
if ($Env:YURUNA_CACHING_PROXY_IP -and $Env:YURUNA_CACHING_PROXY_IP -match '^\d+\.\d+\.\d+\.\d+$') {
    # External cache: $CachingProxyUrl already points at the remote IP
    # (no VZ-gateway rewrite), remote image is identical (same Apache :80
    # serving /yuruna-squid-ca.crt). cache-ip.txt isn't written for
    # external caches, so read from the env var.
    $cacheVmIp = $Env:YURUNA_CACHING_PROXY_IP.Trim()
} elseif ($CachingProxyUrl) {
    $cacheIpFile = Join-Path $HOME "virtual/squid-cache/cache-ip.txt"
    if (Test-Path $cacheIpFile) {
        $candidate = (Get-Content -Raw $cacheIpFile).Trim()
        if ($candidate -match '^\d+\.\d+\.\d+\.\d+$') { $cacheVmIp = $candidate }
    }
}
if ($CachingProxyUrl -and $cacheVmIp) {
    try {
        $caResp = Invoke-WebRequest -Uri "http://${cacheVmIp}/yuruna-squid-ca.crt" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        if ($caResp.StatusCode -eq 200 -and $caResp.RawContentLength -gt 0) {
            $caBytes = if ($caResp.Content -is [byte[]]) { $caResp.Content } else { [System.Text.Encoding]::UTF8.GetBytes([string]$caResp.Content) }
            $CaCertBase64 = [Convert]::ToBase64String($caBytes)
            Write-Output "  Fetched squid-cache CA from http://${cacheVmIp}/yuruna-squid-ca.crt ($($caBytes.Length) bytes) — embedded in seed."
        }
    } catch {
        Write-Warning "  Could not fetch CA cert from http://${cacheVmIp}/yuruna-squid-ca.crt : $($_.Exception.Message)"
        Write-Warning "  Guest will skip HTTPS caching (Acquire::https::Proxy); HTTP caching via :3128 unaffected."
    }
}

$UserData = (Get-Content -Raw $UserDataTemplate).Replace('HOSTNAME_PLACEHOLDER', $VMName).Replace('HASH_PLACEHOLDER', $PasswordHash).Replace('SSH_AUTHORIZED_KEY_PLACEHOLDER', $SshAuthorizedKey).Replace('APT_PROXY_BLOCK_PLACEHOLDER', $AptProxyBlock).Replace('CACHING_PROXY_URL_PLACEHOLDER', $CachingProxyUrl).Replace('CA_CERT_BASE64_PLACEHOLDER', $CaCertBase64)

Set-Content -Path "$SeedDir/user-data" -Value $UserData -NoNewline
$MetaData = (Get-Content -Raw $MetaDataTemplate) `
    -replace 'HOSTNAME_PLACEHOLDER', $VMName
Set-Content -Path "$SeedDir/meta-data" -Value $MetaData -NoNewline

$SeedIso = "$DataDir/seed.iso"
Write-Output "Generating seed.iso with autoinstall configuration..."
& hdiutil makehybrid -o "$SeedIso" -joliet -iso -default-volume-name cidata "$SeedDir"
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to create seed.iso with hdiutil."
    exit 1
}

# === config.plist (Apple Virtualization backend) ===
$TemplatePath = Join-Path $ScriptDir "config.plist.template"
if (-not (Test-Path $TemplatePath)) {
    Write-Error "Template not found at '$TemplatePath'."
    exit 1
}

$VmUuid = [guid]::NewGuid().ToString().ToUpper()
$DiskId = [guid]::NewGuid().ToString().ToUpper()
$IsoId = [guid]::NewGuid().ToString().ToUpper()
$SeedId = [guid]::NewGuid().ToString().ToUpper()
$rng = [System.Random]::new()
$MacBytes = [byte[]]::new(6)
$rng.NextBytes($MacBytes)
$MacBytes[0] = ($MacBytes[0] -bor 0x02) -band 0xFE  # locally administered unicast
$MacAddress = ($MacBytes | ForEach-Object { $_.ToString("X2") }) -join ":"

# GenericPlatform.machineIdentifier: 16 random bytes, base64 (required
# by Apple Virtualization.framework for nested virtualization).
$MachineIdBytes = [byte[]]::new(16)
$rng.NextBytes($MachineIdBytes)
$MachineIdentifier = [Convert]::ToBase64String($MachineIdBytes)

$PlistContent = (Get-Content -Raw $TemplatePath) `
    -replace '__VM_NAME__',             $VMName `
    -replace '__VM_UUID__',             $VmUuid `
    -replace '__MAC_ADDRESS__',         $MacAddress `
    -replace '__DISK_IDENTIFIER__',     $DiskId `
    -replace '__DISK_IMAGE_NAME__',     'disk.img' `
    -replace '__ISO_IDENTIFIER__',      $IsoId `
    -replace '__ISO_IMAGE_NAME__',      "$VMName.iso" `
    -replace '__SEED_IDENTIFIER__',     $SeedId `
    -replace '__SEED_IMAGE_NAME__',     'seed.iso' `
    -replace '__MACHINE_IDENTIFIER__',  $MachineIdentifier `
    -replace '__CPU_COUNT__',           '4' `
    -replace '__MEMORY_SIZE__',         '16384'

Set-Content -Path "$UtmDir/config.plist" -Value $PlistContent

# === Cleanup temporary folders ===
Remove-Item -Recurse -Force $SeedDir -ErrorAction SilentlyContinue

# === Guidance ===
Write-Output ""
Write-Output "VM bundle created: $UtmDir"
Write-Output "Backend: Apple Virtualization (with nested virtualization / KVM support)"
Write-Output "Double-click '$VMName.utm' on your Desktop to import it into UTM."
Write-Output "The Ubuntu installer will start automatically with autoinstall."
Write-Output "Default credentials - username: ubuntu, password: password (must be changed on first login)"
